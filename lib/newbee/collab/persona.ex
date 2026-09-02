defmodule Newbee.Collab.Persona do
  @moduledoc """
  角色实体化（A4）：role 不只是标签，而是编译进子代理的真实配置差异。

  内置角色 worker/tester/reviewer/lead，可通过 TOML 在
  `~/.newbee/personas/*.toml` 覆写。delegate 时 resolve/1 把 persona
  折成 {model 覆写, system 提示补丁, 工具白名单, token 预算}。
  """

  @builtin %{
    "lead" => %{
      "role" => "lead",
      "system_patch" => "你是协作组的 Lead。先拆解任务、写板、分配，再 wait 聚合，最后验收。",
      "tool_allow" => nil,
      "model" => nil,
      "reasoning_effort" => nil,
      "token_budget" => nil
    },
    "worker" => %{
      "role" => "worker",
      "system_patch" => "你是 worker。认领任务后专注执行，完成前 report 事实结果。",
      "tool_allow" => nil,
      "model" => nil,
      "reasoning_effort" => nil,
      "token_budget" => nil
    },
    "tester" => %{
      "role" => "tester",
      "system_patch" => "你是 tester。以破坏性思维验证他人产出，跑测试、找边界、写回归。",
      "tool_allow" => ["Run", "Fs", "Edit", "Search", "Git"],
      "model" => nil,
      "reasoning_effort" => nil,
      "token_budget" => nil
    },
    "reviewer" => %{
      "role" => "reviewer",
      "system_patch" => "你是 reviewer。只读不改，review diff 并给出接受/拒绝 + 理由。",
      "tool_allow" => ["Fs", "Search", "Git", "RepoMap"],
      "model" => nil,
      "reasoning_effort" => "high",
      "token_budget" => nil
    }
  }

  @doc "列出全部可用 persona 名（内置 + 用户 TOML）。"
  def list do
    user = user_personas()
    Map.merge(@builtin, user) |> Map.keys() |> Enum.sort()
  end

  @doc "解析 persona：用户 TOML 覆写优先于内置。返回 {:ok, map} | {:error, code, msg}。"
  def resolve(name) when is_binary(name) do
    user = user_personas()

    cond do
      Map.has_key?(user, name) -> {:ok, Map.merge(@builtin["worker"], user[name])}
      Map.has_key?(@builtin, name) -> {:ok, @builtin[name]}
      true -> {:error, "unknown_persona", "未知角色 #{name}，可用: #{Enum.join(list(), ", ")}"}
    end
  end

  def resolve(_), do: {:ok, @builtin["worker"]}

  @doc "把 persona 编译成子代理 config 覆写（delegate 时并入）。"
  def compile(persona) when is_map(persona) do
    %{
      "system_patch" => persona["system_patch"],
      "model" => persona["model"],
      "reasoning_effort" => persona["reasoning_effort"],
      "tool_allow" => persona["tool_allow"],
      "token_budget" => persona["token_budget"]
    }
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end

  defp user_personas do
    dir = Path.join(System.user_home!(), ".newbee/personas")

    if File.dir?(dir) do
      dir
      |> File.ls!()
      |> Enum.filter(&String.ends_with?(&1, ".toml"))
      |> Enum.flat_map(fn file ->
        path = Path.join(dir, file)
        name = Path.rootname(file)

        case File.read(path) do
          {:ok, body} ->
            {:ok, map} = parse_toml(body)
            [{name, map}]

          _ ->
            []
        end
      end)
      |> Map.new()
    else
      %{}
    end
  end

  # 极简 TOML 解析（只取顶层 string/list，避免引依赖）
  defp parse_toml(body) do
    body
    |> String.split("\n")
    |> Enum.reduce(%{}, fn line, acc ->
      line = String.trim(line)

      cond do
        line == "" or String.starts_with?(line, "#") ->
          acc

        String.contains?(line, "=") ->
          [k, v] = String.split(line, "=", parts: 2)
          k = String.trim(k)
          v = v |> String.trim() |> String.trim("\"")

          parsed =
            if String.starts_with?(v, "[") do
              v
              |> String.trim_leading("[")
              |> String.trim_trailing("]")
              |> String.split(",")
              |> Enum.map(&( &1 |> String.trim() |> String.trim("\"") ))
              |> Enum.reject(&(&1 == ""))
            else
              v
            end

          Map.put(acc, k, parsed)

        true ->
          acc
      end
    end)
    |> then(&{:ok, &1})
  end
end
