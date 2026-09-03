defmodule Newbee.Environment.HumanBrief do
  @moduledoc """
  进化批准的讲人话卡（opt_a：提案时生成、随 Change 快照审计）。

  第性原理：批准是个委托决策，人只需要五问——发现了什么、要变成什么样、
  为啥有效、风险反悔、要我干啥。答不上这五问的信息全是噪音。

  - `template_brief/1` 是纯函数兜底：只用给定材料造句，绝不复读原始ID。
  - `generate/2` 试图用 LLM（adapter 角色）写得更准，任何失败回退模板。
  - 永不抛异常：提案链路不能因为写说明而断。
  """

  require Logger

  @sections ~w(title found change_to why risk_undo ask)

  @doc """
  纯模板兜底。attrs 可含（atom 或 string key）：reason, evidence,
  plugin_id, kind, usage, note, ring, eval_summary, change_id。
  返回 string-key map，含 meta（fallback: true, model: "template"）。
  """
  def template_brief(attrs) when is_map(attrs) do
    kind = gv(attrs, "kind")
    usage = gv(attrs, "usage") || gv(attrs, "note")
    evidence = gv(attrs, "evidence") || []
    ring = gv(attrs, "ring")
    eval_summary = gv(attrs, "eval_summary")
    kind_cn = kind_cn(kind)
    purpose = short_purpose(usage)
    %{
      "title" => "让环境记住" <> kind_cn <> purpose_suffix(purpose),
      "found" => found_sentence(evidence),
      "change_to" => change_sentence(kind_cn, usage),
      "why" => why_sentence(eval_summary),
      "risk_undo" => risk_sentence(ring),
      "ask" => "如果你认可这个改进，点击批准；拿不准就先放着，环境维持现状。",
      "fallback" => true,
      "model" => "template",
      "generated_at" => DateTime.utc_now() |> DateTime.to_iso8601()
    }
  end

  @doc """
  LLM 生成讲人话卡。opts：
  - client_fun: (messages -> {:ok, text} | {:error, reason})，默认 adapter 角色客户端。
  - model: 记录用模型名（仅写入 meta）。
  任何失败回退 `template_brief/1`（fallback: true），永不 raise。
  """
  def generate(attrs, opts \\ []) when is_map(attrs) do
    timeout = Keyword.get(opts, :timeout, 30_000)
    task = Task.async(fn -> run_client(attrs, opts) end)

    case Task.yield(task, timeout) || Task.shutdown(task) do
      {:ok, brief} -> brief
      nil -> template_brief(attrs)
    end
  end

  defp run_client(attrs, opts) do
    client_fun = Keyword.get(opts, :client_fun, &default_client_fun/1)
    model = Keyword.get(opts, :model, "adapter")
    try do
      case client_fun.(prompt_for(attrs)) do
        {:ok, text} when is_binary(text) ->
          case parse_response(text) do
            {:ok, brief} ->
              brief
              |> Map.put("fallback", false)
              |> Map.put("model", model)
              |> Map.put("generated_at", DateTime.utc_now() |> DateTime.to_iso8601())
            :error -> template_brief(attrs)
          end
        _ -> template_brief(attrs)
      end
    rescue
      e ->
        Logger.warning("human_brief generate failed, fallback: " <> inspect(e))
        template_brief(attrs)
    catch
      _, _ -> template_brief(attrs)
    end
  end

  @doc false
  def parse_response(text) when is_binary(text) do
    text
    |> String.split(~r/```[a-z]*/, trim: true)
    |> Enum.find_value(fn chunk ->
      case Jason.decode(String.trim(chunk)) do
        {:ok, m} when is_map(m) -> validate(m)
        _ -> nil
      end
    end)
    |> case do
      nil -> :error
      brief -> {:ok, brief}
    end
  end

  defp validate(m) do
    vals = Map.new(@sections, fn k -> {k, m[k] || m[String.to_atom(k)]} end)
    ok? =
      Enum.all?(vals, fn {_k, v} ->
        is_binary(v) and String.length(String.trim(v)) >= 2 and String.length(v) <= 800 and
          not String.contains?(v, "chg_") and Regex.match?(~r/\p{Han}/u, v)
      end)
    if ok?, do: Map.new(vals), else: nil
  end

  defp default_client_fun(messages) do
    client = Newbee.LLM.Config.client_for("adapter")
    case Newbee.LLM.Client.stream_chat(client, messages, fn _ -> :ok end) do
      {:ok, msg, _usage} -> {:ok, msg["content"] || ""}
      {:error, e} -> {:error, e}
    end
  rescue
    e -> {:error, e}
  end

  defp prompt_for(attrs) do
    material = %{
      "type" => to_string(gv(attrs, "proposal_type") || gv(attrs, "kind") || ""),
      "kind_cn" => kind_cn(gv(attrs, "kind")),
      "usage" => cut(gv(attrs, "usage") || gv(attrs, "note") || "", 800),
      "evidence" => cut(inspect(gv(attrs, "evidence") || [], limit: 6, printable_limit: 800), 800),
      "ring" => to_string(gv(attrs, "ring") || "")
    }
    content = "你是 newbee 的进化说明员。把下面的环境改进提案翻译成普通用户能看懂的批准说明，只输出 JSON 对象（无围栏外文字），键为 title/found/change_to/why/risk_undo/ask，每值 1-3 句中文。" <>
      "title 要求 10 字内一句话且必须含中文，不许出现英文ID或哈希；found 写怎么发现的；change_to 写要变成什么样；why 写为什么有效；risk_undo 写风险与能否反悔；ask 写要用户做什么。" <>
      "纪律：只用给定材料，没有的数据不要编具体数字，不许输出 change_id 或 plugin_id，只讲人话。材料：" <> Jason.encode!(material)
    [%{"role" => "user", "content" => content}]
  end

  defp kind_cn(:rule), do: "一条新提醒"
  defp kind_cn(:tool), do: "一个新工具"
  defp kind_cn(:prompt), do: "一条经验"
  defp kind_cn("rule"), do: "一条新提醒"
  defp kind_cn("tool"), do: "一个新工具"
  defp kind_cn("prompt"), do: "一条经验"
  defp kind_cn(_), do: "一个改进"

  defp short_purpose(nil), do: nil
  defp short_purpose(""), do: nil
  defp short_purpose(s) when is_binary(s) do
    t = String.trim(s)
    if Regex.match?(~r/\p{Han}/u, t), do: String.slice(t, 0, 24), else: nil
  end
  defp short_purpose(_), do: nil

  defp purpose_suffix(nil), do: ""
  defp purpose_suffix(p), do: "：" <> p

  defp found_sentence(evidence) when is_list(evidence) and length(evidence) > 0 do
    first = List.first(evidence)
    cap = (is_map(first) && (Map.get(first, :capability) || Map.get(first, "capability"))) || nil
    n = length(evidence)
    if is_binary(cap) and cap != "" and not raw_id?(cap) do
      "AI 在【" <> cap <> "】上多次遇到问题（目前收集到 " <> to_string(n) <> " 条相关信息），总结出这个改进。"
    else
      "AI 在日常任务中注意到一个反复出现的模式（收集到 " <> to_string(n) <> " 条证据），总结出这个改进。"
    end
  end
  defp found_sentence(_), do: "AI 在日常任务中注意到一个可以固化的做法。"

  defp change_sentence(kind_cn, usage) when is_binary(usage) and usage != "" do
    t = String.trim(usage)
    if Regex.match?(~r/\p{Han}/u, t) do
      String.slice(t, 0, 120)
    else
      "把这次的做法固化成" <> kind_cn <> "，下次同类任务自动用上。"
    end
  end
  defp change_sentence(kind_cn, _), do: "把这次的做法固化成" <> kind_cn <> "，下次同类任务自动用上。"

  defp why_sentence(nil), do: "先经过 5 道验证（格式/复测/回放/试用/长期），通过了才需要你批准。"
  defp why_sentence(""), do: "先经过 5 道验证（格式/复测/回放/试用/长期），通过了才需要你批准。"
  defp why_sentence(s) when is_binary(s), do: s <> "。通过验证后才需要你批准。"
  defp why_sentence(_), do: "先经过 5 道验证（格式/复测/回放/试用/长期），通过了才需要你批准。"

  defp risk_sentence(ring) when ring in [3, "3"], do: "影响小（单个工具或提醒）。批准后生成新版本，旧版本保留，可一键回退。"
  defp risk_sentence(ring) when ring in [2, "2"], do: "影响中等（规则或提示词）。批准后生成新版本，旧版本保留，可一键回退。"
  defp risk_sentence(ring) when ring in [1, "1", 0, "0"], do: "影响较大（底层能力变更），请仔细看发现和改法。批准后旧版本保留，可一键回退。"
  defp risk_sentence(_), do: "批准后生成新版本，旧版本保留，可一键回退；不批准则维持现状。"

  defp raw_id?(s) when is_binary(s) do
    not Regex.match?(~r/\p{Han}|\s/u, s) and Regex.match?(~r/[_\-]/, s)
  end

  defp cut(s, n) when is_binary(s), do: String.slice(s, 0, n)
  defp cut(_, _), do: ""

  defp gv(m, k) when is_map(m) and is_binary(k) do
    Map.get(m, k) || get_atom(m, k)
  end

  defp gv(_, _), do: nil

  defp get_atom(m, k) do
    Map.get(m, String.to_existing_atom(k))
  rescue
    _ -> nil
  end
end
