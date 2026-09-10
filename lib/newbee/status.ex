defmodule Newbee.Status do
  @moduledoc ~S"环境健康与进化证据面板 (DESIGN §6 落地证据)"
  @spec render() :: String.t()
  def render, do: render(nil)

  @doc "采集可核验运行数据并交给模型整理；模型不可用时本地降级。"
  @spec render(map() | nil, function()) :: String.t()
  def render(client, complete_fn \\ &Newbee.LLM.Client.complete/3) do
    source = evidence_text()
    fallback = source

    if client do
      prompt = [
        %{
          "role" => "system",
          "content" =>
            "你只负责压缩运行数据，不要宣传产品，不要解释设计，不要写优点。" <>
              "每行必须严格使用：功能：功能名 数据：可核验数字或状态。" <>
              "只保留有数据的功能，最多 12 行。禁止 Markdown、标题、表格、项目符号、反引号、星号和泛泛而谈。"
        },
        %{"role" => "user", "content" => source}
      ]

      case safe_complete(complete_fn, client, prompt) do
        {:ok, text} when text != "" -> text
        _ -> fallback
      end
    else
      fallback
    end
  end

  defp evidence_text do
    info = safe(fn -> Newbee.DEE.Evaluator.info() end, nil)
    plugins = safe(fn -> Newbee.Plugins.list() end, [])
    env = safe(fn -> Newbee.Environment.Coordinator.current() end, nil)
    bindings = safe(fn -> Newbee.DEE.Evaluator.bindings_summary() end, [])
    rules = safe(fn -> Newbee.DEE.Rules.list() end, [])
    tags = safe(fn -> Newbee.Environment.Fitness.price_tags() end, %{})
    usage = safe(fn -> Newbee.Agent.Loop.usage(Process.whereis(Newbee.Agent.Loop)) end, %{})
    antibodies = safe(fn -> Newbee.Environment.Antibodies.all() end, [])
    verified = Enum.count(antibodies, &(&1["state"] == "verified_regression_test"))
    sessions = safe(fn -> Newbee.Session.count() end, 0)
    # 只数行不解析 JSON：读 100k 条事件（几十 MB）会拖慢每次 status。
    event_count = safe(fn -> Newbee.EventLog.count() end, 0)
    event_bytes = safe(fn -> Newbee.EventLog.size() end, 0)

    env_line =
      if env do
        "功能：Environment 数据：revision=#{env.revision} active插件=#{map_size(env.active)} autonomy=#{env.autonomy}"
      else
        "功能：Environment 数据：未启动"
      end

    [
      "功能：Evaluator 隔离求值 数据：模式=#{if(info, do: info.mode, else: "不可用")} 节点=#{if(info, do: inspect(info.node), else: "不可用")} 重启=#{if(info, do: info.restarts, else: "不可用")}次",
      env_line,
      "功能：内置插件 数据：#{length(plugins)}个",
      "功能：持久绑定 数据：#{length(bindings)}个",
      "功能：沉睡规则 数据：#{length(rules)}条",
      "功能：价签（fitness 投影） 数据：#{map_size(tags)}个",
      "功能：Token 统计 数据：#{inspect(usage)}",
      "功能：失败抗体 数据：#{length(antibodies)}条（已验证 #{verified}）",
      "功能：事件溯源 数据：#{event_count}条 #{human_bytes(event_bytes)}",
      "功能：会话记录 数据：至少#{sessions}条"
    ]
    |> Enum.join("\n")
  end

  defp safe_complete(fun, client, messages) do
    case fun.(client, messages, temperature: 0.2) do
      {:ok, text, _usage} when is_binary(text) ->
        text = text |> String.trim() |> strip_decoration()
        if evidence_lines?(text), do: {:ok, text}, else: :error

      _ ->
        :error
    end
  rescue
    _ -> :error
  catch
    :exit, _ -> :error
  end

  defp evidence_lines?(text) do
    text != "" and Enum.all?(String.split(text, "\n"), &(String.contains?(&1, "功能：") and String.contains?(&1, "数据：")))
  end

  defp strip_decoration(text) do
    text
    |> String.replace(~r/```[^\n]*\n?/, "")
    |> String.replace(~r/[#>*`]/, "")
    |> String.replace(~r/^\s*[-|]+\s*/m, "")
    |> String.trim()
  end

  defp human_bytes(n) when n >= 1_000_000, do: :io_lib.format("~.1fMB", [n / 1_000_000]) |> IO.iodata_to_binary()
  defp human_bytes(n) when n >= 1_000, do: :io_lib.format("~.1fKB", [n / 1_000]) |> IO.iodata_to_binary()
  defp human_bytes(n), do: "#{n}B"

  defp safe(fun, default) do
    try do
      fun.()
    rescue
      _ -> default
    catch
      :exit, _ -> default
    end
  end
end
