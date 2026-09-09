defmodule Newbee.Collaboration.CrossHost.Extensions do
  @moduledoc """
  Registry for dynamically loaded cross-host capabilities.

  Remote code is accepted only after the target Worker opted in, and every
  module in the source must live below `Newbee.RemoteExtensions`.
  """

  use GenServer

  alias Newbee.Tools.HotReload

  @max_source_bytes 128 * 1024
  @name_re ~r/^[a-z][a-z0-9_.-]{0,79}$/
  @function_re ~r/^[a-z_][a-zA-Z0-9_!?]{0,79}$/
  @module_re ~r/^Newbee\.RemoteExtensions\.[A-Z][A-Za-z0-9_.]*$/

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, %{}, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "Load a local extension and publish its allowlisted callable manifest."
  def install(source, manifest, opts \\ [])

  def install(source, manifest, opts) when is_binary(source) and is_map(manifest) do
    GenServer.call(Keyword.get(opts, :server, __MODULE__), {:install, source, manifest}, 60_000)
  end

  def install(_, _, _), do: {:error, "bad_request", "扩展源码和能力清单格式无效"}

  @doc "Install code delivered by a Hub only when this Worker explicitly opted in."
  def install_remote(source, manifest, digest, allowed?, opts \\ []) do
    if allowed? == true do
      install(source, Map.put(manifest || %{}, "source_sha256", digest), opts)
    else
      {:error, "full_control_required", "本机没有授予群主完全控制权限"}
    end
  end

  @doc "Public manifests advertised to connected groups; source is never included."
  def manifests(server \\ __MODULE__), do: GenServer.call(server, :manifests)

  @doc "Invoke one explicitly registered capability."
  def invoke(name, args, server \\ __MODULE__)

  def invoke(name, args, server) when is_binary(name) and is_list(args) do
    GenServer.call(server, {:invoke, name, args}, 60_000)
  end

  def invoke(_, _, _), do: {:error, "bad_request", "能力名称和参数格式无效"}

  @impl true
  def init(_), do: {:ok, %{capabilities: %{}}}

  @impl true
  def handle_call(:manifests, _from, state) do
    manifests = state.capabilities |> Map.values() |> Enum.map(& &1.manifest) |> Enum.sort_by(& &1["name"])
    {:reply, manifests, state}
  end

  def handle_call({:install, source, manifest}, _from, state) do
    with {:ok, normalized} <- validate_manifest(manifest),
         :ok <- validate_source(source, normalized),
         %{ok: true} = loaded <- HotReload.replace(source, file: "remote_extension/#{normalized["name"]}.ex"),
         :ok <- verify_export(normalized) do
      public = Map.put(normalized, "source_sha256", sha256(source))
      next = put_in(state, [:capabilities, normalized["name"]], %{manifest: public, loaded: loaded})
      {:reply, {:ok, public}, next}
    else
      %{ok: false, error: reason} -> {:reply, {:error, "compile_failed", inspect(reason)}, state}
      {:error, _, _} = error -> {:reply, error, state}
    end
  end

  def handle_call({:invoke, name, args}, _from, state) do
    reply =
      with %{manifest: manifest} <- state.capabilities[name],
           true <- length(args) == manifest["arity"] do
        module = Module.concat([manifest["module"]])
        function = String.to_existing_atom(manifest["function"])

        try do
          {:ok, apply(module, function, args)}
        rescue
          error -> {:error, "capability_failed", Exception.message(error)}
        catch
          kind, reason -> {:error, "capability_failed", "#{kind}: #{inspect(reason)}"}
        end
      else
        nil -> {:error, "not_found", "目标机器没有声明这个能力"}
        false -> {:error, "bad_request", "能力参数数量不匹配"}
      end

    {:reply, reply, state}
  end

  defp validate_manifest(manifest) do
    name = text(manifest, "name")
    version = text(manifest, "version")
    module = text(manifest, "module")
    function = text(manifest, "function") || "call"
    arity = manifest["arity"]
    description = text(manifest, "description") || ""
    digest = text(manifest, "source_sha256") || ""

    cond do
      not is_binary(name) or not Regex.match?(@name_re, name) ->
        {:error, "bad_manifest", "能力名称无效"}

      not is_binary(version) or version == "" or byte_size(version) > 40 ->
        {:error, "bad_manifest", "能力版本无效"}

      not is_binary(module) or not Regex.match?(@module_re, module) ->
        {:error, "bad_manifest", "模块必须位于 Newbee.RemoteExtensions 命名空间"}

      not Regex.match?(@function_re, function) ->
        {:error, "bad_manifest", "能力函数名称无效"}

      not is_integer(arity) or arity < 0 or arity > 8 ->
        {:error, "bad_manifest", "能力参数数量必须是 0 到 8"}

      digest != "" and not Regex.match?(~r/^[0-9a-f]{64}$/, digest) ->
        {:error, "bad_manifest", "source_sha256 必须是 64 位十六进制摘要"}

      true ->
        {:ok,
         %{
           "name" => name,
           "version" => version,
           "module" => module,
           "function" => function,
           "arity" => arity,
           "description" => String.slice(description, 0, 240),
           "source_sha256" => digest
         }}
    end
  end

  defp validate_source(source, manifest) do
    cond do
      byte_size(source) == 0 ->
        {:error, "bad_source", "扩展源码为空"}

      byte_size(source) > @max_source_bytes ->
        {:error, "source_too_large", "扩展源码不能超过 128 KiB"}

      expected_digest?(manifest) and manifest["source_sha256"] != sha256(source) ->
        {:error, "digest_mismatch", "扩展源码 SHA-256 不匹配"}

      true ->
        with {:ok, ast} <- Code.string_to_quoted(source),
             modules when modules != [] <- declared_modules(ast),
             true <- Enum.all?(modules, &Regex.match?(@module_re, &1)),
             true <- manifest["module"] in modules do
          :ok
        else
          {:error, _} -> {:error, "bad_source", "扩展源码无法解析"}
          [] -> {:error, "bad_source", "扩展源码没有定义模块"}
          false -> {:error, "bad_source", "源码只能定义清单中的 Newbee.RemoteExtensions 模块"}
        end
    end
  end

  defp verify_export(manifest) do
    module = Module.concat([manifest["module"]])
    function = String.to_existing_atom(manifest["function"])

    if function_exported?(module, function, manifest["arity"]),
      do: :ok,
      else: {:error, "bad_manifest", "源码没有导出清单声明的函数"}
  rescue
    ArgumentError -> {:error, "bad_manifest", "能力函数不存在"}
  end

  defp declared_modules(ast) do
    {_ast, modules} =
      Macro.prewalk(ast, [], fn
        {:defmodule, _, [name_ast, _]} = node, acc -> {node, [Macro.to_string(name_ast) | acc]}
        node, acc -> {node, acc}
      end)

    Enum.uniq(modules)
  end

  defp expected_digest?(manifest), do: is_binary(manifest["source_sha256"]) and manifest["source_sha256"] != ""
  defp sha256(source), do: :crypto.hash(:sha256, source) |> Base.encode16(case: :lower)

  defp text(map, key) do
    case map[key] do
      value when is_binary(value) -> String.trim(value)
      _ -> nil
    end
  end
end
