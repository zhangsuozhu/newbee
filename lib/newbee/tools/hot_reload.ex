defmodule Newbee.Tools.HotReload do
  @moduledoc """
  Hot-swapping BEAM modules: load from full source or file.
  Targets the current node by default; pass `target: :main` to hit the newbee host node over RPC.

  ## Functions
  - `replace(source, opts \\\\ []) :: map()` — compile a full source text and swap the modules it defines. `opts` takes `file:`, `target:`, `force:`.
  - `load_file(path, opts \\\\ []) :: map()` — load an `.ex/.exs/.beam` file; same options as `replace/2`.
  - `status(module) :: map()` — returns `loaded?`, `source`, `md5`, `old_code?`.
  - `purge(module) :: map()` — force-drop old code versions; returns `purged?` and `old_code_remaining?`.
  - `unload(module) :: map()` — `delete + purge` unloads a module; returns `deleted?`, `purged?`, `loaded?`.

  `replace_local/2` and `load_file_local/2` are internal RPC entries (`@doc false`); never call them directly.

  ## Runnable example
      source = "defmodule Demo.Hot do\n  def hi, do: :ok\nend"
      %{ok: true} = Newbee.Tools.HotReload.replace(source)
      %{ok: true} = Newbee.Tools.HotReload.load_file("lib/demo/hot.ex", target: :main)
      %{ok: true, loaded?: loaded?} = Newbee.Tools.HotReload.status(Demo.Hot)
      %{ok: true, purged?: _} = Newbee.Tools.HotReload.purge(Demo.Hot)
      %{ok: true, loaded?: false} = Newbee.Tools.HotReload.unload(Demo.Hot)

  `force: true` and `purge/unload` can end old code paths; use only on reloadable temp or explicitly targeted modules.
  """

  @rpc_timeout 60_000

  @doc """
  Compile full source text and swap the modules it defines; the arg is source, not a module name.
  opts:
    - :file   source filename (for diagnostics, default "hot_reload.ex")
    - :target :local (default) | :main | node atom — which node to swap on
    - :force  purge old code even when processes still run it (default: refuse with an error)
  Returns `%{ok: true, file: _, modules: [...], warnings: [...]}`; compile/load failures return `%{ok: false, error: reason}`.
  """
  def replace(source, opts \\ []) when is_binary(source) do
    dispatch(:replace, [source, opts], opts)
  end

  @doc """
  Load modules from a file and swap them: .beam goes straight to load_binary; .ex/.exs are read, compiled, and swapped.
  Same opts as replace/2.
  """
  def load_file(path, opts \\ []) when is_binary(path) do
    dispatch(:load_file, [path, opts], opts)
  end

  @doc "Module status: loaded?/source/md5/old_code?. Module takes atom or text."
  def status(module) do
    mod = to_module(module)
    loaded = :code.is_loaded(mod)

    case loaded do
      false ->
        %{ok: true, module: mod, loaded?: false, md5: nil, old_code?: false}

      {:file, file} ->
        %{
          ok: true,
          module: mod,
          loaded?: true,
          source: List.to_string(file),
          md5: module_md5(mod),
          old_code?: :erlang.check_old_code(mod)
        }

      _other ->
        %{
          ok: true,
          module: mod,
          loaded?: true,
          source: nil,
          md5: module_md5(mod),
          old_code?: :erlang.check_old_code(mod)
        }
    end
  end

  @doc "Force-drop a module's old code versions; returns a map with purged? and old_code_remaining?."
  def purge(module) do
    mod = to_module(module)
    purged = :code.purge(mod)
    %{ok: true, module: mod, purged?: purged, old_code_remaining?: :erlang.check_old_code(mod)}
  end

  @doc "Unload a module (delete + purge); returns a map with deleted?/purged?/loaded?."
  def unload(module) do
    mod = to_module(module)
    deleted = :code.delete(mod)
    purged = :code.purge(mod)
    %{ok: true, module: mod, deleted?: deleted, purged?: purged, loaded?: :code.is_loaded(mod) != false}
  end

  # ── 本地实现（也可被 RPC 到目标节点执行）──

  @doc false
  def replace_local(source, opts \\ []) do
    file = Keyword.get(opts, :file, "hot_reload.ex")
    force? = Keyword.get(opts, :force, false)
    prev_ignore_conflict = Code.get_compiler_option(:ignore_module_conflict)
    Code.put_compiler_option(:ignore_module_conflict, true)

    try do
      # 热替换必然重定义已加载模块；屏蔽预期的 redefining module 噪音（与 PluginContract/PluginManager 一致），
      # 其它警告仍正常输出。after 恢复调用前的值，避免污染调用方编译选项。
      compiled = Code.compile_string(source, file)
      results = Enum.map(compiled, fn {mod, _bin} -> load_swap(%{mod: mod}, force?) end)

      warnings =
        results
        |> Enum.flat_map(fn r -> r[:warnings] || [] end)
        |> Enum.uniq()

      %{
        ok: true,
        file: file,
        modules:
          Enum.map(results, fn r ->
            Map.delete(Map.put(Map.take(r, [:mod, :new_md5, :old_code?]), :module, r[:mod]), :mod)
          end),
        warnings: warnings
      }
    rescue
      e -> %{ok: false, error: Exception.message(e)}
    catch
      kind, reason -> %{ok: false, error: "#{kind}: #{inspect(reason)}"}
    after
      Code.put_compiler_option(:ignore_module_conflict, prev_ignore_conflict)
    end
  end

  @doc false
  def load_file_local(path, opts \\ []) do
    cond do
      String.ends_with?(path, ".beam") ->
        case File.read(path) do
          {:ok, binary} ->
            case beam_module(path) do
              {:ok, mod} -> load_binary_swap(%{module: mod, source: path}, mod, path, binary, opts)
              {:error, reason} -> %{ok: false, error: {:invalid_beam, reason}}
            end

          {:error, reason} ->
            %{ok: false, error: {:read_failed, reason}}
        end

      true ->
        case File.read(path) do
          {:ok, source} -> replace_local(source, Keyword.put(opts, :file, path))
          {:error, reason} -> %{ok: false, error: {:read_failed, reason}}
        end
    end
  end

  # ── 路由：本地 / RPC 到目标节点 ──

  defp dispatch(fun, args, opts) do
    target = target_node(Keyword.get(opts, :target, :local))

    if target == Node.self() do
      apply(__MODULE__, :"#{fun}_local", args)
    else
      rpc_call(target, fun, args)
    end
  end

  defp rpc_call(node, fun, args) do
    case :rpc.call(node, __MODULE__, :"#{fun}_local", args, @rpc_timeout) do
      {:badrpc, reason} -> %{ok: false, error: {:badrpc, reason}}
      result -> result
    end
  rescue
    e -> %{ok: false, error: Exception.message(e)}
  end

  defp target_node(:local), do: Node.self()
  defp target_node(:main), do: Newbee.Host.main_node()
  defp target_node("local"), do: Node.self()
  defp target_node("main"), do: Newbee.Host.main_node()
  defp target_node(node) when is_atom(node), do: node
  defp target_node(node) when is_binary(node) and node != "", do: String.to_atom(node)

  # ── 加载细节 ──

  defp load_swap(%{mod: mod} = acc, force?) do
    # compile_string 已自动载入新代码；若旧版本仍被进程持有（old_code），
    # soft_purge 会失败——默认报错， force 则硬 purge。
    case :code.soft_purge(mod) do
      true ->
        Map.merge(acc, %{old_code?: false, new_md5: module_md5(mod)})

      false ->
        if force? do
          :code.purge(mod)
          Map.merge(acc, %{old_code?: false, new_md5: module_md5(mod), force_purged?: true})
        else
          %{ok: false, error: {:old_code_in_use, mod}, hint: "processes still run the old version; add force: true to hard-swap after confirming"}
        end
    end
  end

  defp load_binary_swap(acc, mod, path, binary, opts) do
    force? = Keyword.get(opts, :force, false)

    case :code.soft_purge(mod) do
      true ->
        case :code.load_binary(mod, String.to_charlist(path), binary) do
          {:module, ^mod} -> Map.merge(acc, %{ok: true, old_code?: false, new_md5: module_md5(mod)})
          other -> %{ok: false, error: {:load_binary_failed, other}}
        end

      false ->
        if force? do
          :code.purge(mod)

          case :code.load_binary(mod, String.to_charlist(path), binary) do
            {:module, ^mod} ->
              Map.merge(acc, %{ok: true, old_code?: false, new_md5: module_md5(mod), force_purged?: true})

            other ->
              %{ok: false, error: {:load_binary_failed, other}}
          end
        else
          %{ok: false, error: {:old_code_in_use, mod}, hint: "processes still run the old version; add force: true to hard-swap after confirming"}
        end
    end
  end

  defp module_md5(mod) do
    case Code.ensure_loaded(mod) do
      {:module, ^mod} -> mod.module_info(:md5) |> Base.encode16(case: :lower)
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp beam_module(path) do
    case :beam_lib.info(String.to_charlist(path))[:module] do
      module when is_atom(module) -> {:ok, module}
      _ -> {:error, :invalid_beam}
    end
  rescue
    _ -> {:error, :invalid_beam}
  end

  defp to_module(mod) when is_atom(mod), do: mod

  defp to_module(mod) when is_binary(mod) do
    mod = String.trim_leading(mod, "Elixir.")
    Module.concat([mod])
  end
end
