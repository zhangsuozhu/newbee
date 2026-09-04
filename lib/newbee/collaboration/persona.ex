defmodule Newbee.Collaboration.Persona do
  @moduledoc """
  子代理角色配置。角色只声明运行时能够真实兑现的字段：
  `provider`、`model`、`reasoning_effort` 与受信的 `instructions`。

  用户角色放在 `~/.newbee/personas/<name>.json`。未知字段、错误类型和过长指令
  都会被拒绝，避免“配置已接受但运行时忽略”的静默失败。
  """

  @roles ~w(worker tester reviewer observer)
  @efforts ~w(none minimal low medium high xhigh)
  @allowed_keys MapSet.new(~w(role provider model reasoning_effort instructions))

  @builtin %{
    "worker" => %{
      "role" => "worker",
      "instructions" => "Own one sharply scoped subtask; read the task contract and dependencies first, report facts as you go, finish with checkable evidence."
    },
    "tester" => %{
      "role" => "tester",
      "reasoning_effort" => "medium",
      "instructions" => "Work as an independent verifier; favor reproduction, edge cases, and regression tests — never take the implementer's word as evidence."
    },
    "reviewer" => %{
      "role" => "reviewer",
      "reasoning_effort" => "high",
      "instructions" => "Review behavioral regressions, security risks, and missing tests; every conclusion must cite files, command output, or reproducible steps."
    },
    "observer" => %{
      "role" => "observer",
      "instructions" => "Investigate and report only; don't touch the workspace."
    }
  }

  @doc "列出可解析的内置与用户 persona 名。"
  def list do
    user_names =
      persona_dir()
      |> Path.join("*.json")
      |> Path.wildcard()
      |> Enum.flat_map(fn path ->
        name = Path.basename(path, ".json")
        if match?({:ok, _}, load_user(path, name)), do: [name], else: []
      end)

    @builtin
    |> Map.keys()
    |> Kernel.++(user_names)
    |> Enum.uniq()
    |> Enum.sort()
  end

  @doc "解析并严格校验 persona。用户 JSON 与内置同名时，用户配置优先。"
  def resolve(name) when is_binary(name) do
    if Regex.match?(~r/\A[a-z0-9][a-z0-9_-]{0,63}\z/, name) do
      path = Path.join(persona_dir(), name <> ".json")

      cond do
        File.regular?(path) -> load_user(path, name)
        profile = @builtin[name] -> {:ok, Map.put(profile, "name", name)}
        true -> {:error, "unknown_persona", "unknown persona #{inspect(name)}; available: #{Enum.join(list(), ", ")}"}
      end
    else
        {:error, "bad_persona", "persona names take only lowercase letters, digits, underscores, and hyphens (64 chars max)"}
    end
  end

  def resolve(_), do: {:error, "bad_persona", "persona name must be a text"}

  @doc "把已解析 persona 转为可持久化的会话配置。"
  def session_profile(persona) when is_map(persona) do
    Map.take(persona, ["name", "role", "provider", "model", "reasoning_effort", "instructions"])
  end

  defp load_user(path, name) do
    with {:ok, body} <- File.read(path),
         {:ok, map} <- Jason.decode(body),
         true <- is_map(map) or {:error, "bad_persona", "#{path} must be a JSON object"},
         :ok <- validate_keys(map, path),
         :ok <- validate_profile(map, path) do
      {:ok, map |> Map.put_new("role", "worker") |> Map.put("name", name)}
    else
      {:error, %Jason.DecodeError{} = error} ->
        {:error, "bad_persona", "#{path} has invalid JSON: #{Exception.message(error)}"}

      {:error, code, message} ->
        {:error, code, message}

      {:error, reason} ->
        {:error, "persona_read_failed", "#{path}: #{inspect(reason)}"}
    end
  end

  defp validate_keys(map, path) do
    unknown = Map.keys(map) |> MapSet.new() |> MapSet.difference(@allowed_keys) |> MapSet.to_list()

    if unknown == [],
      do: :ok,
      else: {:error, "bad_persona", "#{path} holds unknown fields: #{Enum.join(Enum.sort(unknown), ", ")}"}
  end

  defp validate_profile(map, path) do
    role = Map.get(map, "role", "worker")
    effort = map["reasoning_effort"]
    instructions = map["instructions"]

    cond do
      role not in @roles ->
        {:error, "bad_persona", "#{path} has an invalid role"}

      not is_nil(effort) and effort not in @efforts ->
        {:error, "bad_persona", "#{path} has an invalid reasoning_effort"}

      not optional_string?(map["provider"]) or not optional_string?(map["model"]) ->
        {:error, "bad_persona", "#{path} provider/model must be non-empty texts"}

      not is_binary(instructions) or String.trim(instructions) == "" ->
        {:error, "bad_persona", "#{path} instructions must not be empty"}

      byte_size(instructions) > 4_000 ->
        {:error, "bad_persona", "#{path} instructions exceed 4000 bytes"}

      true ->
        :ok
    end
  end

  defp optional_string?(nil), do: true
  defp optional_string?(value), do: is_binary(value) and String.trim(value) != ""

  defp persona_dir do
    System.get_env("NEWBEE_PERSONA_DIR") || Path.join(System.user_home!(), ".newbee/personas")
  end
end
