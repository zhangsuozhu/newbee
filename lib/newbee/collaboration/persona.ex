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
      "instructions" => "负责一个边界明确的子任务；先读取任务契约和依赖，过程报告事实，完成后提交可复核证据。"
    },
    "tester" => %{
      "role" => "tester",
      "reasoning_effort" => "medium",
      "instructions" => "以独立验证者视角工作；优先复现、边界条件和回归测试，不把实现者的自述当作证据。"
    },
    "reviewer" => %{
      "role" => "reviewer",
      "reasoning_effort" => "high",
      "instructions" => "审查行为回归、安全风险和缺失测试；结论必须引用文件、命令输出或可复现步骤。"
    },
    "observer" => %{
      "role" => "observer",
      "instructions" => "只做调查和报告，不修改工作区。"
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
        true -> {:error, "unknown_persona", "未知 persona #{inspect(name)}；可用：#{Enum.join(list(), ", ")}"}
      end
    else
      {:error, "bad_persona", "persona 名只支持小写字母、数字、下划线和连字符（最多 64 字符）"}
    end
  end

  def resolve(_), do: {:error, "bad_persona", "persona 名必须是字符串"}

  @doc "把已解析 persona 转为可持久化的会话配置。"
  def session_profile(persona) when is_map(persona) do
    Map.take(persona, ["name", "role", "provider", "model", "reasoning_effort", "instructions"])
  end

  defp load_user(path, name) do
    with {:ok, body} <- File.read(path),
         {:ok, map} <- Jason.decode(body),
         true <- is_map(map) or {:error, "bad_persona", "#{path} 须是 JSON object"},
         :ok <- validate_keys(map, path),
         :ok <- validate_profile(map, path) do
      {:ok, map |> Map.put_new("role", "worker") |> Map.put("name", name)}
    else
      {:error, %Jason.DecodeError{} = error} ->
        {:error, "bad_persona", "#{path} JSON 无效：#{Exception.message(error)}"}

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
      else: {:error, "bad_persona", "#{path} 含未知字段：#{Enum.join(Enum.sort(unknown), ", ")}"}
  end

  defp validate_profile(map, path) do
    role = Map.get(map, "role", "worker")
    effort = map["reasoning_effort"]
    instructions = map["instructions"]

    cond do
      role not in @roles ->
        {:error, "bad_persona", "#{path} role 无效"}

      not is_nil(effort) and effort not in @efforts ->
        {:error, "bad_persona", "#{path} reasoning_effort 无效"}

      not optional_string?(map["provider"]) or not optional_string?(map["model"]) ->
        {:error, "bad_persona", "#{path} provider/model 必须是非空字符串"}

      not is_binary(instructions) or String.trim(instructions) == "" ->
        {:error, "bad_persona", "#{path} instructions 不能为空"}

      byte_size(instructions) > 4_000 ->
        {:error, "bad_persona", "#{path} instructions 超过 4000 字节"}

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
