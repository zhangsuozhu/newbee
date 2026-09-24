defmodule Newbee.Evals.CompactionRecall do
  @moduledoc "离线压缩召回评测。不访问网络，不调用模型。Jev 分数来自 cassette，对照臂走真实的 Policy 与 Projection。阈值写死，合成夹具不能得到 keep。"

  alias Newbee.Compaction.{Config, Policy, Projection}

  @min_answerable 60
  @recall_slack_points 3
  @ceiling_percent 90
  @min_net_wins 8

  def min_answerable, do: @min_answerable

  def jev_config do
    {:ok, config} = Config.resolve(%{"mode" => "jev"})
    config
  end

  @doc "用 cassette 分数投影一份转录。缺分数或截断不划算时保持原文。"
  def project(messages, scores, config \\ nil) when is_list(messages) and is_map(scores) do
    config = config || jev_config()

    with {:ok, calls} <- Policy.collect_calls(messages, config, nil, nil) do
      {records, recoveries} = records_for(calls, scores, config)

      case Projection.apply(messages, records) do
        {:ok, projected, stats} ->
          {:ok,
           %{
             messages: projected,
             records: records,
             recoveries: recoveries,
             stats: stats,
             validation: Projection.validate(messages, projected, records)
           }}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc "构造对照臂。jev_read 与 wording 不另造转录。"
  def arms(session) when is_map(session) do
    session = ensure_session(session)
    config = jev_config()

    with {:ok, projected} <- project(session.messages, session.scores, config) do
      jev_messages = projected.messages
      recent = config.preserve_recent_messages

      contexts = %{
        full: session.messages,
        legacy: legacy_messages(session.messages, session.legacy_summary, recent),
        recency: recency_messages(session.messages, tokens(jev_messages), recent),
        jev: jev_messages
      }

      {:ok,
       %{
         contexts: contexts,
         recoveries: projected.recoveries,
         validation: projected.validation,
         stats: projected.stats,
         tokens: Map.new(contexts, fn {arm, msgs} -> {arm, tokens(msgs)} end)
       }}
    end
  end

  @doc "跑一份会话。报告里只有计数，没有转录、答案或标准答案。"
  def run(session) when is_map(session) do
    session = ensure_session(session)

    case arms(session) do
      {:ok, built} ->
        per_question = score_questions(session, built)
        stats = aggregates(session, built, per_question)
        finish(stats)

      {:error, reason} ->
        stats = blank_stats(session, 1)
        finish(Map.put(stats, :error, reason))
    end
  end

  def run_file!(path) when is_binary(path) do
    path |> File.read!() |> Jason.decode!() |> run()
  end

  @doc "事前登记的判决。keep 需要全部门槛同时成立。invalid 表示评测本身坏了，不要据此调阈值。"
  def judge(stats) when is_map(stats) do
    n = stats.answerable
    wording_swing = Map.get(stats, :wording_swing)
    net = stats.paired_jev_recency.won - stats.paired_jev_recency.lost
    within_slack? = n > 0 and within_slack?(stats.jev_correct, stats.legacy_correct, n)
    read_recovers? = n > 0 and stats.jev_read_correct * 100 >= stats.legacy_correct * 100
    address_used? = stats.tool_jev_read_correct > stats.tool_jev_correct

    reasons =
      []
      |> reason(Map.get(stats, :synthetic, false), :synthetic_fixture)
      |> reason(n < @min_answerable, :corpus_too_small)
      |> reason(stats.validation_failures != 0, :validation_failed)
      |> reason(n == 0 or not ceiling?(stats.full_correct, n), :exam_not_ceiling)
      |> reason(is_nil(wording_swing), :no_wording_control)
      |> reason(stats.jev_tokens > stats.legacy_tokens, :tokens_not_lower)
      |> reason(not (within_slack? or read_recovers?), :recall_not_better)
      |> reason(not address_used?, :address_not_used)
      |> reason(net < @min_net_wins, :recency_margin)
      |> reason(is_integer(wording_swing) and net <= wording_swing, :inside_noise)
      |> Enum.sort()

    invalid? = Enum.any?(reasons, &(&1 in [:validation_failed, :exam_not_ceiling]))

    status =
      cond do
        invalid? -> :invalid
        reasons != [] -> :insufficient
        true -> :keep
      end

    %{status: status, reasons: reasons}
  end

  def render(report) when is_map(report) do
    tokens = Map.get(report, :tokens, %{})
    presence = Map.get(report, :presence, %{})

    line = fn arm, correct_key ->
      row = Map.get(presence, arm, %{closed: 0, one_read: 0})
      "| #{arm} | #{Map.get(report, correct_key, 0)} | #{row.closed} / #{row.one_read} | #{Map.get(tokens, arm, "")} |"
    end

    Enum.join(
      [
        "# 压缩召回评分卡",
        "",
        "会话: #{report.session_id}",
        "合成夹具: #{report.synthetic}",
        "可答题: #{report.answerable}",
        "验收失败: #{report.validation_failures}",
        "",
        "合成夹具或可答题少于 #{@min_answerable} 时，判决不能是 keep。本卡不含转录和答案。",
        "",
        "| 臂 | 脚本答对 | 闭卷仍在 / 一次读回可达 | tokens |",
        "|---|---:|---:|---:|",
        line.(:full, :full_correct),
        line.(:legacy, :legacy_correct),
        line.(:recency, :recency_correct),
        line.(:jev, :jev_correct),
        "| jev_read | #{report.jev_read_correct} | 与 jev 同一上下文 | #{report.jev_tokens} |",
        "| wording | #{report.wording_correct} | 与 legacy 同一上下文 | #{report.legacy_tokens} |",
        "",
        "配对 jev 对 recency: 赢 #{report.paired_jev_recency.won} 负 #{report.paired_jev_recency.lost} 平 #{report.paired_jev_recency.tied}",
        "措辞摆动: #{report.wording_swing}",
        "工具事实脚本答对: jev #{report.tool_jev_correct} / jev_read #{report.tool_jev_read_correct}",
        "",
        "判决: #{report.verdict.status}",
        "原因: #{Enum.join(report.verdict.reasons, ", ")}",
        ""
      ],
      "\n"
    )
  end

  def contains?(haystack, needle) when is_binary(haystack) and is_binary(needle) and needle != "" do
    String.contains?(squash(haystack), squash(needle))
  end

  def contains?(_, _), do: false

  def synthetic_session do
    middle = String.duplicate("H", 500) <> "FACT-MIDDLE-UNIQUE" <> String.duplicate("T", 500)
    dropped = "FACT-DROPPED-CALL " <> String.duplicate("P", 400)
    filler = for n <- 1..8, do: %{"role" => "user", "content" => "continue #{n}"}

    %{
      "id" => "synthetic-001",
      "synthetic" => true,
      "note" => "Harness check only. Not a measured result.",
      "legacy_summary" => "用户要修 lib/foo.ex 的超时。ALPHA-USER 被提到。工具输出未保留。",
      "messages" =>
        [
          %{"role" => "system", "content" => "base"},
          %{"role" => "user", "content" => "请修 lib/foo.ex 里的超时。目标符号 ALPHA-USER。"},
          tool_pair("c1", middle),
          tool_pair("c2", dropped)
        ]
        |> List.flatten()
        |> Kernel.++(filler),
      "scores" => %{
        "c1" => %{"keep_call" => 0.9, "keep_result" => 0.1},
        "c2" => %{"keep_call" => 0.1, "keep_result" => 0.1}
      },
      "questions" => [
        %{"id" => "q-user", "gold" => "ALPHA-USER", "locus" => "user"},
        %{"id" => "q-middle", "gold" => "FACT-MIDDLE-UNIQUE", "locus" => "tool_result"},
        %{"id" => "q-drop", "gold" => "FACT-DROPPED-CALL", "locus" => "tool_result"}
      ],
      "answers" => %{
        "full" => %{
          "q-user" => "ALPHA-USER",
          "q-middle" => "FACT-MIDDLE-UNIQUE",
          "q-drop" => "FACT-DROPPED-CALL"
        },
        "legacy" => %{"q-user" => "ALPHA-USER", "q-middle" => "unknown", "q-drop" => "unknown"},
        "recency" => %{"q-user" => "ALPHA-USER", "q-middle" => "unknown", "q-drop" => "unknown"},
        "jev" => %{"q-user" => "ALPHA-USER", "q-middle" => "unknown", "q-drop" => "unknown"},
        "jev_read" => %{
          "q-user" => "ALPHA-USER",
          "q-middle" => "FACT-MIDDLE-UNIQUE",
          "q-drop" => "FACT-DROPPED-CALL"
        },
        "wording" => %{"q-user" => "只记得超时", "q-middle" => "unknown", "q-drop" => "unknown"}
      }
    }
  end

  defp finish(stats) do
    verdict = judge(Map.delete(stats, :error))
    report = Map.put(stats, :verdict, verdict)
    Map.put(report, :scorecard, render(report))
  end

  defp ensure_session(session), do: normalize(session)

  defp blank_stats(session, failures) do
    %{
      session_id: session.id,
      synthetic: session.synthetic,
      answerable: length(session.questions),
      validation_failures: failures,
      full_correct: 0,
      legacy_correct: 0,
      recency_correct: 0,
      jev_correct: 0,
      jev_read_correct: 0,
      wording_correct: 0,
      legacy_tokens: 0,
      jev_tokens: 0,
      tokens: %{},
      paired_jev_recency: %{won: 0, lost: 0, tied: 0},
      tool_jev_correct: 0,
      tool_jev_read_correct: 0,
      wording_swing: nil,
      presence: %{}
    }
  end

  defp tool_pair(id, result) do
    [
      %{
        "role" => "assistant",
        "content" => "noted " <> id,
        "tool_calls" => [
          %{
            "id" => id,
            "type" => "function",
            "function" => %{
              "name" => "run_elixir",
              "arguments" => Jason.encode!(%{"code" => "1", "title" => "t"})
            }
          }
        ]
      },
      %{"role" => "tool", "tool_call_id" => id, "content" => result}
    ]
  end

  defp records_for(calls, scores, config) do
    {records, recoveries} =
      Enum.reduce(calls, {[], %{}}, fn call, {records, recoveries} ->
        answer = score_for(scores, call.tool_call_id)
        decision = Policy.decide(call, answer, config)
        text = call.result["content"]
        recovery_id = "eval-" <> call.tool_call_id

        case decision.action do
          :drop_result when is_binary(text) ->
            case Projection.replacement(text, recovery_id, config) do
              :keep ->
                {records, recoveries}

              body ->
                record = %{
                  tool_call_id: call.tool_call_id,
                  action: "drop_result",
                  replacement: body,
                  recovery_id: recovery_id,
                  source_sha: call.source_sha
                }

                {[record | records], Map.put(recoveries, recovery_id, text)}
            end

          :drop_call when is_binary(text) ->
            record = %{
              tool_call_id: call.tool_call_id,
              action: "drop_call",
              recovery_id: recovery_id,
              source_sha: call.source_sha
            }

            {[record | records], Map.put(recoveries, recovery_id, text)}

          _ ->
            {records, recoveries}
        end
      end)

    {Enum.reverse(records), recoveries}
  end

  defp score_for(scores, id) do
    raw = Map.get(scores, id) || Map.get(scores, to_string(id)) || %{}

    %{
      keep_call: number(raw[:keep_call] || raw["keep_call"]),
      keep_result: number(raw[:keep_result] || raw["keep_result"])
    }
  end

  defp number(n) when is_integer(n), do: n / 1
  defp number(n) when is_float(n), do: n
  defp number(_), do: nil

  defp legacy_messages(messages, summary, recent) do
    tail = Enum.take(messages, -min(recent, length(messages)))
    [%{"role" => "system", "content" => summary} | tail]
  end

  defp recency_messages(messages, budget, recent) do
    cutoff = max(length(messages) - recent, 0)

    old_tool_indexes =
      messages
      |> Enum.with_index()
      |> Enum.flat_map(fn
        {%{"role" => "tool"}, idx} when idx < cutoff -> [idx]
        _ -> []
      end)

    Enum.reduce(old_tool_indexes, messages, fn idx, acc ->
      if tokens(acc) <= budget do
        acc
      else
        List.update_at(acc, idx, &Map.put(&1, "content", "[recency-dropped]"))
      end
    end)
  end

  defp tokens(messages) do
    case Policy.estimate_tokens(messages) do
      n when is_integer(n) -> n
      _ -> 0
    end
  end

  defp score_questions(session, built) do
    texts = Map.new(built.contexts, fn {arm, msgs} -> {arm, render_messages(msgs)} end)

    Enum.map(session.questions, fn question ->
      %{
        id: question.id,
        locus: question.locus,
        scripted:
          Map.new([:full, :legacy, :recency, :jev, :jev_read, :wording], fn arm ->
            {arm, contains?(answer_of(session, arm, question.id), question.gold)}
          end),
        presence:
          Map.new(texts, fn {arm, text} ->
            closed = contains?(text, question.gold)

            {arm, %{closed: closed, one_read: closed or one_read?(text, built.recoveries, question.gold)}}
          end),
        jev_one_read: one_read?(texts.jev, built.recoveries, question.gold)
      }
    end)
  end

  defp one_read?(text, recoveries, gold) do
    Enum.any?(recoveries, fn {id, body} ->
      String.contains?(text, "spill://" <> id) and contains?(body, gold)
    end)
  end

  defp aggregates(session, built, per_question) do
    count = fn arm -> Enum.count(per_question, fn question -> question.scripted[arm] end) end
    tool_questions = Enum.filter(per_question, fn question -> question.locus == :tool_result end)

    presence =
      Map.new([:full, :legacy, :recency, :jev], fn arm ->
        rows = Enum.map(per_question, fn question -> question.presence[arm] end)

        {arm,
         %{
           closed: Enum.count(rows, & &1.closed),
           one_read: Enum.count(rows, & &1.one_read)
         }}
      end)

    jev_presence = %{
      closed: presence.jev.closed,
      one_read:
        Enum.count(per_question, fn question ->
          question.jev_one_read or question.presence.jev.closed
        end)
    }

    %{
      session_id: session.id,
      synthetic: session.synthetic,
      answerable: length(per_question),
      validation_failures: if(built.validation == :ok, do: 0, else: 1),
      full_correct: count.(:full),
      legacy_correct: count.(:legacy),
      recency_correct: count.(:recency),
      jev_correct: count.(:jev),
      jev_read_correct: count.(:jev_read),
      wording_correct: count.(:wording),
      legacy_tokens: built.tokens.legacy,
      jev_tokens: built.tokens.jev,
      tokens: built.tokens,
      paired_jev_recency: paired(per_question, :jev, :recency),
      tool_jev_correct: Enum.count(tool_questions, fn question -> question.scripted.jev end),
      tool_jev_read_correct: Enum.count(tool_questions, fn question -> question.scripted.jev_read end),
      wording_swing: swing(per_question),
      presence: Map.put(presence, :jev, jev_presence)
    }
  end

  defp paired(per_question, left, right) do
    Enum.reduce(per_question, %{won: 0, lost: 0, tied: 0}, fn question, acc ->
      cond do
        question.scripted[left] and not question.scripted[right] -> %{acc | won: acc.won + 1}
        question.scripted[right] and not question.scripted[left] -> %{acc | lost: acc.lost + 1}
        true -> %{acc | tied: acc.tied + 1}
      end
    end)
  end

  defp swing(per_question) do
    legacy = Enum.count(per_question, fn question -> question.scripted.legacy end)
    wording = Enum.count(per_question, fn question -> question.scripted.wording end)
    abs(legacy - wording)
  end

  defp answer_of(session, arm, id) do
    session.answers |> Map.get(arm, %{}) |> Map.get(id, "")
  end

  defp within_slack?(correct, baseline, n) do
    correct * 100 >= baseline * 100 - @recall_slack_points * n
  end

  defp ceiling?(correct, n) when n > 0, do: correct * 100 >= @ceiling_percent * n
  defp ceiling?(_, _), do: false

  defp reason(reasons, true, name), do: [name | reasons]
  defp reason(reasons, false, _name), do: reasons

  defp render_messages(messages) do
    Enum.map_join(messages, "\n", fn msg ->
      content = if is_binary(msg["content"]), do: msg["content"], else: ""
      calls = if is_list(msg["tool_calls"]), do: inspect(msg["tool_calls"]), else: ""
      content <> "\n" <> calls
    end)
  end

  defp squash(text), do: text |> String.trim() |> String.replace(~r/\s+/u, " ")

  defp normalize(session) do
    session = stringify_keys(session)

    %{
      id: session["id"] || "unknown",
      synthetic: session["synthetic"] == true,
      legacy_summary: session["legacy_summary"] || "",
      messages: session["messages"] || [],
      scores: session["scores"] || %{},
      questions: Enum.map(session["questions"] || [], &normalize_question/1),
      answers: normalize_answers(session["answers"] || %{})
    }
  end

  defp normalize_question(question) do
    question = stringify_keys(question)
    %{id: question["id"], gold: question["gold"], locus: locus(question["locus"])}
  end

  defp normalize_answers(answers) do
    answers
    |> stringify_keys()
    |> Enum.flat_map(fn {arm, rows} ->
      case arm_name(arm) do
        nil ->
          []

        name ->
          rows =
            rows
            |> stringify_keys()
            |> Map.new(fn {qid, text} -> {qid, to_string(text)} end)

          [{name, rows}]
      end
    end)
    |> Map.new()
  end

  defp arm_name("full"), do: :full
  defp arm_name("legacy"), do: :legacy
  defp arm_name("recency"), do: :recency
  defp arm_name("jev"), do: :jev
  defp arm_name("jev_read"), do: :jev_read
  defp arm_name("wording"), do: :wording
  defp arm_name(_), do: nil

  defp locus("user"), do: :user
  defp locus("assistant"), do: :assistant
  defp locus("tool_result"), do: :tool_result
  defp locus(_), do: :unknown

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), value}
      {key, value} -> {key, value}
    end)
  end
end
