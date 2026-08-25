defmodule Newbee.Archive do
  @moduledoc """
  会话档案库（DESIGN §4.6 "压缩改视图不动日志" 的运行时落位）⭐。

  把 compaction 从"销毁式压扁"重建为**分层、可寻址、无损**的记忆层级：

  ```text
  transcript（append-only，永不覆写）
     │ compact: 归档区间 → seg-000N.jsonl（内容寻址 sha256，原子写）
     ▼
  ledger compactions.jsonl（append-only；tail_sha 锚自校验；尾行损坏整体忽略）
     │ 每段一次 LLM 蒸馏（全保真抽取物 → digest 事件，可补写不改历史）
     ▼
  视图 = [system 基底] ++ [汇总消息（确定性装配，零 LLM）] ++ [近期消息原文]
  ```

  四条设计纪律：

  - **一次蒸馏，永不重蒸**：每段 digest 只从原始消息计算一次；视图装配是纯确定性
    滑窗（新段全量、旧段首行+指针）——消灭"摘要的摘要"电话游戏；
  - **确定性优先**（§6.2）：压缩先用解析提取类型化事实（用户意图逐字、文件路径、
    ✗→✓ 错误对、✓ 验证结果），LLM 只补叙事；LLM 失败时账本仍然完整；
  - **pull over push**：模型经 `Newbee.read("history://…")` 随时拉回任何被压缩的
    原文（索引 / 段 digest / 段原文 / 全文检索 / 文件清单）——不加工具，光头原则不破；
  - **崩溃安全**：段文件 tmp+rename；账本逐行自包含，尾行损坏视同未压缩；
    `tail_sha` 不对齐（日志漂移）优雅降级为原始视图。

  所有函数接收 `Newbee.Session` 结构；无服务进程，纯文件操作（与 Session 同风格）。
  """

  alias Newbee.Session

  @ledger_name "compactions.jsonl"
  @seg_dir "archive"
  @seg_prefix "seg-"
  @intent_max 12
  @intent_slice 160
  @digest_max_chars 700
  @extract_budget 9_000
  @summary_budget_tokens 1_400
  @backfill_segments 2
  @search_hits 60
  @raw_msg_slice 1_600
  @raw_total_bytes 512 * 1024
  # 尾部压缩指令：放最后一条 user 消息（deepseek-harness 2026-07-21 note）——
  # 摘要请求 = 暖前缀回放 + 尾部指令，provider 前缀缓存可命中；
  # 指令放头部（独立 system/首条消息）会让首 token 就偏离缓存前缀。
  @compaction_instruction """
  你现在扮演压缩引擎。上面的对话是编程 agent 会话的一段（含 system 基底与原始消息）。\
  用 ≤300 字中文写要点摘要：任务目标、关键决策、改动、踩过的坑与解法、未完成事项。\
  规则：不要提及本压缩请求本身；不要调用工具；只输出摘要正文。
  """

  # ── 对外 API ──

  @doc """
  压缩：把 transcript 的 `[prev_cut, new_cut)` 区间归档为不可变段，追加账本事件，
  返回 `{:ok, %{view: messages, archived: n, segment: id, cut: new_cut}}`。
  无可归档消息时返回 `:noop`。

  - `:retain` — 保留策略：整数 ≤64 按消息条数、更大按 token 预算（沿用 Loop 旧语义）；
  - `:client` — LLM client（可选）；提供则对新段做一次 digest，并补写历史缺失 digest；
  - `:trigger` — "auto" | "manual"（进账本，供审计）。

  次序即崩溃语义：先原子落段文件，再追加账本；账本落盘成功压缩才"发生"。
  崩在两步之间只留下无主段文件（无账本引用，视图不受影响，下次压缩原位覆写）。
  """
  def compact(%Session{} = session, opts \\ []) do
    retain = Keyword.get(opts, :retain, 8)
    raw = Session.messages(session)
    prev_cut = cut_of(session, raw)

    {new_cut, seg} = plan_cut(raw, prev_cut, retain)

    if new_cut <= prev_cut or seg == [] do
      :noop
    else
      seg_id = next_segment_id(session)
      seg_bin = Enum.map_join(seg, "\n", &Jason.encode_to_iodata!/1)

      event = %{
        "id" => next_event_id(session),
        "topic" => "compacted",
        "at" => iso_now(),
        "data" => %{
          "segment" => seg_id,
          "from" => prev_cut,
          "upto" => new_cut,
          "messages" => length(seg),
          "seg_sha" => sha256(seg_bin),
          "seg_bytes" => byte_size(seg_bin),
          "tokens_est" => div(byte_size(seg_bin) + 2, 3),
          "tail_sha" => sha256(Jason.encode_to_iodata!(List.last(seg))),
          "trigger" => to_string(Keyword.get(opts, :trigger, "manual")),
          "facts" => extract_facts(seg)
        }
      }

      write_segment(session, seg_id, seg_bin)
      append_ledger(session, event)

      # :envelope = 上次路由请求快照（Loop 记录，Archive 只消费不猜测）。
      # 命中资格 + 请求形状见 digest_segment/4。
      if client = Keyword.get(opts, :client) do
        digest_segment(session, seg_id, client, envelope: Keyword.get(opts, :envelope))
        backfill_digests(session, client)
      end

      {:ok, %{view: view(session), archived: length(seg), segment: seg_id, cut: new_cut}}
    end
  end

  @doc """
  当前视图（物化视图的构建器）：`[汇总消息] ++ [切点之后的消息原文]`。
  system 基底不进 transcript（由 Loop 持有），故视图不含基底——Loop 在头部自行
  前置。无账本 / 账本失校验时 = 原始消息（逐字节兼容旧行为）。零 LLM 调用。
  """
  def view(%Session{} = session) do
    raw = Session.messages(session)

    case validated_cut(session, raw) do
      nil ->
        raw

      cut ->
        [%{"role" => "system", "content" => summary_text(session)} | Enum.drop(raw, cut)]
    end
  end

  @doc "档案是否存在（有段被归档过）。"
  def archived?(%Session{} = session), do: segments(session) != []

  @doc """
  当前压缩切点与段清单（UI/诊断用）：`%{cut: n, segments: [...]}`；无有效档案返回 nil。
  """
  def current_cut(%Session{} = session) do
    raw = Session.messages(session)

    case validated_cut(session, raw) do
      nil -> nil
      cut -> %{cut: cut, segments: segments(session)}
    end
  end

  @doc "段清单（账本 compacted 事件 → 段元数据，按归档序）。"
  def segments(%Session{} = session) do
    session
    |> ledger()
    |> Enum.filter(&(&1["topic"] == "compacted"))
    |> Enum.map(fn ev ->
      d = ev["data"]

      %{
        id: d["segment"],
        upto: d["upto"],
        messages: d["messages"],
        tokens_est: d["tokens_est"],
        first_intent: d["facts"] |> user_intent_list() |> List.first()
      }
    end)
  end

  @doc "digest 表：segment → digest 文本（同段多条 digest 事件取最后一条）。"
  def digests(%Session{} = session) do
    session
    |> ledger()
    |> Enum.filter(&(&1["topic"] == "digest"))
    |> Enum.reduce(%{}, fn ev, acc -> Map.put(acc, ev["data"]["segment"], ev["data"]["text"]) end)
  end

  @doc """
  为一段生成 digest（LLM 一次）。成功追加 `digest` 事件；失败不写事件。

  `envelope`（可选）= 上次路由请求快照（Newbee.RequestEnvelope）。命中条件：
  快照存在且 route（base_url + model）与当前 client 一致——此时摘要请求 =
  快照 messages 逐字回放 ++ 尾部压缩指令，成为上次请求的严格前缀，provider
  前缀缓存命中。无快照 / route 失配 / client 为注入函数 → 走有界抽取路径
  （build_extract），不伪装命中。
  """
  def digest_segment(session, seg_id, client, opts \\ [])

  def digest_segment(%Session{} = session, seg_id, client, opts) when is_list(opts) do
    case Keyword.get(opts, :envelope) do
      env when is_map(env) ->
        if Newbee.RequestEnvelope.hit_eligible?(env, client) do
          with {:ok, text} <- llm_digest_replay(client, env, seg_id) do
            record_digest(session, seg_id, text)
          end
        else
          extract_digest(session, seg_id, client)
        end

      _ ->
        extract_digest(session, seg_id, client)
    end
  end

  defp extract_digest(%Session{} = session, seg_id, client) do
    with {:ok, msgs} <- segment_messages(session, seg_id),
         extract = build_extract(msgs),
         {:ok, text} <- llm_digest(client, extract, seg_id) do
      record_digest(session, seg_id, text)
    end
  end

  defp record_digest(%Session{} = session, seg_id, text) do
    append_ledger(session, %{
      "id" => next_event_id(session),
      "topic" => "digest",
      "at" => iso_now(),
      "data" => %{"segment" => seg_id, "text" => text, "tokens" => div(byte_size(text) + 2, 3)}
    })

    :ok
  end

  @doc "读段原始消息（sha 校验失败 → {:error, :checksum_mismatch}；无此段 → {:error, :segment_not_found}）。"
  def segment_messages(%Session{} = session, seg_id) do
    case ledger_find(session, seg_id) do
      nil ->
        {:error, :segment_not_found}

      ev ->
        case File.read(segment_path(session, seg_id)) do
          {:ok, bin} ->
            if sha256(bin) == ev["data"]["seg_sha"] do
              {:ok,
               bin
               |> String.split("\n", trim: true)
               |> Enum.flat_map(fn line ->
                 case Jason.decode(line) do
                   {:ok, m} when is_map(m) -> [m]
                   _ -> []
                 end
               end)}
            else
              {:error, :checksum_mismatch}
            end

          {:error, _} ->
            {:error, :segment_file_missing}
        end
    end
  end

  # ── history:// 读取（Newbee.read 路由；经 Host.call 在主节点执行，peer 节点同样可用）──

  @doc """
  `history://` 内部 scheme 的读取端（当前活动会话）。query:

  - ``（空）→ 档案索引：段清单 + 消息数/token/意图首行 + 用法提示
  - `s/<id>` → 段 digest + 确定性事实账本
  - `s/<id>/raw` → 段原始消息（压缩渲染，封顶 512KB）
  - `q/<term>` → 跨段全文检索（不区分大小写，命中带段 id 与行上下文）
  - `files` → 本会话归档区间碰过的文件清单
  """
  def read_history(query) do
    case Newbee.Host.call(Newbee.Session, :current_id, []) do
      nil -> {:ok, "（当前无活动会话，无 history:// 档案）"}
      id -> read_history(Session.open(id), query)
    end
  end

  def read_history(%Session{} = session, query) do
    cond do
      query in [nil, ""] -> {:ok, index_text(session)}
      query == "files" -> {:ok, files_text(session)}
      String.starts_with?(query, "q/") -> {:ok, search_text(session, String.trim_leading(query, "q/"))}
      true -> read_segment(session, query)
    end
  end

  defp read_segment(%Session{} = session, query) do
    case Regex.run(~r{^s/([\w-]+)(/raw)?$}, query) do
      [_, seg_id, _raw] -> {:ok, raw_text(session, seg_id)}
      [_, seg_id] -> {:ok, segment_text(session, seg_id)}
      _ -> {:error, :history_path_not_found}
    end
  end

  defp index_text(%Session{} = session) do
    segs = segments(session)

    if segs == [] do
      "（会话 #{session.id} 尚无归档段——历史还未被压缩，近期原文都在上下文里）"
    else
      lines =
        segs
        |> Enum.reverse()
        |> Enum.map_join("\n", fn s ->
          intent = s.first_intent || "（无用户消息）"
          "  [#{s.id}] #{s.messages} 条消息 · ~#{s.tokens_est} tokens · 始于：#{intent}"
        end)

      "会话 #{session.id} 档案（#{length(segs)} 段，最新在上）：\n" <>
        lines <>
        "\n\n用法：Newbee.read(\"history://s/段id\") 段摘要与事实；\"history://s/段id/raw\" 原文；" <>
        "\"history://q/关键词\" 全文检索；\"history://files\" 文件清单。"
    end
  end

  defp segment_text(%Session{} = session, seg_id) do
    case ledger_find(session, seg_id) do
      nil ->
        "（段 #{seg_id} 不存在；用 Newbee.read(\"history://\") 看索引）"

      ev ->
        d = ev["data"]
        facts = d["facts"]

        digest = digests(session)[seg_id] || "（digest 尚未生成——确定性账本如下）"
        intents = facts |> user_intent_list() |> Enum.map_join("\n", &"  - #{&1}")

        "段 #{seg_id}（消息 #{d["from"] + 1}..#{d["upto"]}，#{d["messages"]} 条，~#{d["tokens_est"]} tokens）\n" <>
          "## 摘要\n" <>
          digest <>
          "\n\n## 用户意图（逐字）\n" <>
          if(intents == "", do: "  （无）", else: intents) <>
          "\n\n## 文件\n" <>
          fact_lines(facts["files"], "  - ") <>
          "\n## 错误与解决\n" <>
          fact_lines(facts["errors"], "  ✗ ") <>
          "\n## 已验证结果\n" <>
          fact_lines(facts["results"], "  ✓ ") <>
          "\n\n原文：Newbee.read(\"history://s/#{seg_id}/raw\")"
    end
  end

  defp raw_text(%Session{} = session, seg_id) do
    case segment_messages(session, seg_id) do
      {:ok, msgs} ->
        body =
          msgs
          |> Enum.map_join("\n", &render_raw_msg/1)
          |> maybe_truncate(@raw_total_bytes)

        "段 #{seg_id} 原始消息（#{length(msgs)} 条）：\n" <> body

      {:error, reason} ->
        "（读取失败：#{inspect(reason)}）"
    end
  end

  defp render_raw_msg(m) do
    role = m["role"] || "?"

    body =
      case m do
        %{"tool_calls" => calls} when is_list(calls) ->
          Enum.map_join(calls, "\n", fn c ->
            args = get_in(c, ["function", "arguments"]) || ""
            "  ⏺ #{get_in(c, ["function", "name"]) || "?"}: " <> String.slice(args, 0, 240)
          end)

        _ ->
          content = m["content"]
          text = if is_binary(content), do: content, else: inspect(content, limit: 20)
          String.slice(text, 0, @raw_msg_slice)
      end

    "[#{role}] " <> body
  end

  defp search_text(%Session{} = session, term) do
    if String.trim(term) == "" do
      "（空检索词）"
    else
      hits =
        session
        |> segments()
        |> Enum.flat_map(fn s ->
          case segment_messages(session, s.id) do
            {:ok, msgs} -> scan_segment(s.id, msgs, term)
            _ -> []
          end
        end)
        |> Enum.take(@search_hits)

      case hits do
        [] ->
          "（档案中未命中 #{inspect(term)}；注意：近期未压缩消息就在上下文里，无需检索）"

        _ ->
          Enum.join(hits, "\n") <>
            "\n（#{length(hits)} 处命中；完整上下文 Newbee.read(\"history://s/<段id>/raw\")）"
      end
    end
  end

  defp scan_segment(seg_id, msgs, term) do
    needle = String.downcase(term)

    msgs
    |> Enum.with_index(1)
    |> Enum.flat_map(fn {m, i} ->
      text = msg_search_text(m)

      if String.contains?(String.downcase(text), needle) do
        line = text |> String.replace("\n", " ⏎ ") |> String.slice(0, 220)
        ["[#{seg_id}##{i}] #{line}"]
      else
        []
      end
    end)
  end

  defp msg_search_text(%{"role" => r, "content" => c}) when is_binary(c), do: "#{r}: #{c}"

  defp msg_search_text(%{"role" => r, "tool_calls" => calls}) when is_list(calls),
    do: "#{r}: #{inspect(calls, limit: 5)}"

  defp msg_search_text(m), do: inspect(m, limit: 10)

  # ── 档案召回（查询感知 rehydration）：零检索基础设施的 mini-RAG ──

  @recall_min_terms 2
  @recall_term_cap 24
  @latin_stopwords ~w(the and for with that this from have will into your our their what when then than just also been was are was were you can use using make made like need want get got set let)

  @doc """
  档案召回：用户输入 → 词元（latin/digit ≥3 字符 + CJK 二元组）→ 跨段打分
  （命中的 distinct 词元数 ≥ #{@recall_min_terms}）→ top 命中行。

  与 `history://q/` 的分工：q/ 是模型主动 pull；recall 是宿主在用户输入命中
  旧档案时**推送指针**（只推 pull 通道的一行摘要，不推载荷）——光头原则不破。
  纯确定性（无嵌入、无外部服务），失败/无档案静默返回 []。
  """
  def recall(%Session{} = session, text, opts \\ []) when is_binary(text) do
    limit = Keyword.get(opts, :limit, 5)
    terms = query_terms(text)

    if terms == [] or length(terms) < @recall_min_terms do
      []
    else
      session
      |> segments()
      |> Enum.flat_map(fn s ->
        case segment_messages(session, s.id) do
          {:ok, msgs} ->
            msgs
            |> Enum.with_index(1)
            |> Enum.map(fn {m, i} -> {s.id, i, msg_search_text(m)} end)

          _ ->
            []
        end
      end)
      |> Enum.reduce([], fn {seg, i, text}, acc ->
        down = String.downcase(text)
        score = Enum.count(terms, &String.contains?(down, &1))

        if score >= @recall_min_terms do
          line = text |> String.replace("\n", " ⏎ ") |> String.slice(0, 200)
          [{score, "[#{seg}##{i}] " <> line} | acc]
        else
          acc
        end
      end)
      |> Enum.sort_by(fn {score, _} -> -score end)
      |> Enum.take(limit)
      |> Enum.map(&elem(&1, 1))
    end
  rescue
    _ -> []
  end

  # 词元提取：latin/digit ≥3（去停用词）+ CJK 连续段做二元组；封顶 @recall_term_cap
  defp query_terms(text) do
    latin =
      ~r/[A-Za-z0-9_]{3,}/
      |> Regex.scan(text)
      |> Enum.map(&(&1 |> hd() |> String.downcase()))
      |> Enum.reject(&(&1 in @latin_stopwords))

    cjk_bigrams =
      text
      |> String.split(~r/[^\p{Han}]+/u, trim: true)
      |> Enum.flat_map(fn run ->
        gs = String.graphemes(run)
        Enum.zip(gs, tl(gs)) |> Enum.map(fn {a, b} -> a <> b end)
      end)

    (latin ++ cjk_bigrams)
    |> Enum.uniq()
    |> Enum.take(@recall_term_cap)
  end

  defp files_text(%Session{} = session) do
    files =
      session
      |> all_facts()
      |> Enum.flat_map(&(&1["files"] || []))
      |> Enum.uniq()
      |> Enum.sort()

    if files == [], do: "（归档区间内未发现文件操作）", else: Enum.map_join(files, "\n", &"  - #{&1}")
  end

  defp all_facts(%Session{} = session) do
    session
    |> ledger()
    |> Enum.filter(&(&1["topic"] == "compacted"))
    |> Enum.map(& &1["data"]["facts"])
  end

  # ── 视图装配（零 LLM）──

  # 汇总消息：头部 + 意图脊柱（全部段用户消息逐字，有界）+ 段 digest 滑窗（新→旧，
  # 新段全量、超预算段折叠为首行+指针）+ 检索提示。
  defp summary_text(%Session{} = session) do
    compacted =
      session
      |> ledger()
      |> Enum.filter(&(&1["topic"] == "compacted"))
      |> Enum.sort_by(& &1["data"]["upto"])

    digested = digests(session)

    intents =
      compacted
      |> Enum.flat_map(&user_intent_list(&1["data"]["facts"]))
      |> Enum.uniq()
      |> Enum.take(@intent_max)

    header = "（以下为已压缩的早期对话；完整原文可随时拉取：Newbee.read(\"history://\")，共 #{length(compacted)} 段）\n"

    spine =
      if intents == [],
        do: "",
        else: "## 用户意图（逐字保留）\n" <> Enum.map_join(intents, "\n", &"  - #{&1}") <> "\n\n"

    body = assemble_segments(Enum.reverse(compacted), digested, @summary_budget_tokens, [])

    tail =
      if length(compacted) > 1,
        do: "\n\n更早细节：Newbee.read(\"history://q/关键词\") 全文检索；Newbee.read(\"history://s/段id/raw\") 段原文。",
        else: ""

    header <> spine <> body <> tail
  end

  defp assemble_segments([], _digests, _budget, acc),
    do: acc |> Enum.reverse() |> Enum.join("\n")

  defp assemble_segments([ev | rest], digests, budget, acc) do
    d = ev["data"]
    seg_id = d["segment"]

    text = digests[seg_id] || fallback_line(d)

    {line, used} =
      case div(byte_size(text) + 2, 3) <= budget do
        true ->
          {"[#{seg_id}] " <> String.trim_trailing(text), div(byte_size(text) + 2, 3)}

        false ->
          first = first_line(text)
          {"[#{seg_id}] " <> first <> " …（更多 Newbee.read(\"history://s/#{seg_id}\")）", div(byte_size(first) + 2, 3)}
      end

    if used >= budget do
      # 预算耗尽：本段保留（可能已折叠），更早段整体折叠为一行指针
      folded = if rest == [], do: [], else: ["（更早 #{length(rest)} 段已折叠：Newbee.read(\"history://\")）"]
      assemble_segments([], digests, 0, folded ++ [line | acc])
    else
      assemble_segments(rest, digests, budget - used, [line | acc])
    end
  end

  defp fallback_line(d) do
    facts = d["facts"]
    intent = facts |> user_intent_list() |> List.first() || "（无用户消息）"

    "（#{d["messages"]} 条消息 · 文件 #{length(facts["files"] || [])} · 错误 #{length(facts["errors"] || [])} · " <>
      "始于：#{intent}）"
  end

  defp first_line(text), do: text |> String.split("\n", trim: true) |> List.first() |> Kernel.||("")

  # ── 确定性事实提取（§6.2：解析优先，零 token）──

  @doc """
  从消息列表提取类型化事实：user_intents（逐字）/ files / errors / results。
  纯函数：压缩时落账本，测试直接断言。
  """
  def extract_facts(messages) do
    %{
      "user_intents" => user_intents(messages),
      "files" => files_touched(messages),
      "errors" => error_facts(messages),
      "results" => result_facts(messages)
    }
  end

  # 用户消息逐字（≤160 字）；剔除系统注入的方括号提醒（[进度监控] 等）与自主模式报头
  defp user_intents(messages) do
    messages
    |> Enum.filter(fn
      %{"role" => "user", "content" => c} when is_binary(c) ->
        t = String.trim(c)
        t != "" and not String.starts_with?(t, "[") and not String.starts_with?(t, "（自主")

      _ ->
        false
    end)
    |> Enum.map(&String.slice(String.trim(&1["content"]), 0, @intent_slice))
    |> Enum.take(@intent_max)
  end

  # 工具调用代码里解析文件路径：字符串字面量中含路径且代码涉及文件工具
  @path_re ~r'"((?:~/)?[\w\-./]+\.[A-Za-z0-9]{1,8})"'
  @file_tools ~w(Fs Edit File Path)

  defp files_touched(messages) do
    messages
    |> Enum.flat_map(fn
      %{"tool_calls" => calls} when is_list(calls) ->
        Enum.flat_map(calls, fn c ->
          code = decode_tool_code(c)

          if code != "" and Enum.any?(@file_tools, &String.contains?(code, &1)) do
            @path_re |> Regex.scan(code) |> Enum.map(&Enum.at(&1, 1))
          else
            []
          end
        end)

      _ ->
        []
    end)
    |> Enum.reject(&String.starts_with?(&1, "http"))
    |> Enum.uniq()
    |> Enum.take(40)
  end

  defp decode_tool_code(%{"function" => %{"arguments" => args}}) when is_binary(args) do
    case Jason.decode(args) do
      {:ok, %{"code" => code}} when is_binary(code) -> code
      _ -> ""
    end
  end

  defp decode_tool_code(_), do: ""

  # ✗ error 首行签名（去 ANSI）；"已解决"判定走**路径关联**：失败调用代码里出现过的
  # 文件路径，若在此后某个 ✓ 成功调用的代码里再次出现 → 该错误已解决（对话级失败
  # 抗体：踩过的坑 + 怎么爬出来的）。无路径可关联的错误保持未解决（保守，不误报）。
  defp error_facts(messages) do
    code_of = calls_code_index(messages)

    results =
      messages
      |> Enum.flat_map(fn
        %{"role" => "tool", "tool_call_id" => id, "content" => "✗ error\n" <> rest} ->
          [{id, :error, first_nonempty(rest) |> String.slice(0, 140)}]

        %{"role" => "tool", "tool_call_id" => id, "content" => "✓ ok\n" <> rest} ->
          [{id, :ok, first_nonempty(rest) |> String.slice(0, 120)}]

        _ ->
          []
      end)

    errors =
      results
      |> Enum.filter(fn {_id, kind, sig} -> kind == :error and sig != "" end)
      |> Enum.map(&elem(&1, 2))
      |> Enum.uniq()
      |> Enum.take(20)

    ok_paths =
      results
      |> Enum.filter(fn {_id, kind, _} -> kind == :ok end)
      |> Enum.flat_map(fn {id, _, _} -> code_of[id] |> paths_in_code() end)
      |> MapSet.new()

    errors
    |> Enum.map(fn sig ->
      error_paths = error_call_paths(results, code_of, sig)

      if error_paths != [] and Enum.any?(error_paths, &MapSet.member?(ok_paths, &1)) do
        sig <> " → 已解决"
      else
        sig
      end
    end)
  end

  # 错误签名 → 失败调用的代码 → 其中的文件路径（同签名多处取并集）
  defp error_call_paths(results, code_of, sig) do
    results
    |> Enum.filter(fn {_id, kind, s} -> kind == :error and s == sig end)
    |> Enum.flat_map(fn {id, _, _} -> code_of[id] |> paths_in_code() end)
    |> Enum.uniq()
  end

  defp calls_code_index(messages) do
    messages
    |> Enum.flat_map(fn
      %{"tool_calls" => calls} when is_list(calls) -> calls
      _ -> []
    end)
    |> Map.new(fn c -> {c["id"] || "", decode_tool_code(c)} end)
  end

  defp paths_in_code(code) when is_binary(code) do
    if Enum.any?(@file_tools, &String.contains?(code, &1)) do
      @path_re |> Regex.scan(code) |> Enum.map(&Enum.at(&1, 1))
    else
      []
    end
  end

  defp paths_in_code(_), do: []

  defp first_nonempty(text) do
    text |> strip_ansi() |> String.split("\n") |> Enum.find(&(&1 != "")) |> Kernel.||("")
  end

  defp result_facts(messages) do
    messages
    |> Enum.flat_map(fn
      %{"role" => "tool", "content" => "✓ ok\n" <> rest} ->
        [rest |> strip_ansi() |> String.split("\n") |> Enum.find(&(&1 != "")) |> Kernel.||("") |> String.slice(0, 120)]

      _ ->
        []
    end)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
    |> Enum.take(15)
  end

  defp strip_ansi(s), do: String.replace(s, ~r/\e\[[0-9;]*[A-Za-z~]/, "")

  defp user_intent_list(nil), do: []
  defp user_intent_list(facts) when is_map(facts), do: facts["user_intents"] || []

  defp fact_lines(nil, _prefix), do: "  （无）"
  defp fact_lines([], _prefix), do: "  （无）"
  defp fact_lines(list, prefix) when is_list(list), do: list |> Enum.map_join("\n", &"#{prefix}#{&1}")

  # ── LLM 蒸馏（每段一次，从全保真抽取物——不是 240 字截断）──

  defp build_extract(msgs) do
    facts = extract_facts(msgs)

    intents = facts["user_intents"] |> Enum.map_join("\n", &"用户: #{&1}")

    code_lines =
      msgs
      |> Enum.flat_map(fn
        %{"tool_calls" => calls} when is_list(calls) -> Enum.map(calls, &decode_tool_code/1)
        _ -> []
      end)
      |> Enum.reject(&(&1 == ""))
      |> Enum.map(&("工具: " <> (String.split(&1, "\n") |> Enum.take(3) |> Enum.join(" ⏎ ") |> String.slice(0, 220))))
      |> Enum.take(40)

    out_lines = Enum.map(facts["results"], &"✓ #{&1}") ++ Enum.map(facts["errors"], &"✗ #{&1}")

    assistant_lines =
      msgs
      |> Enum.filter(&(&1["role"] == "assistant"))
      |> Enum.map_join("\n", fn m ->
        c = m["content"] || ""
        if String.trim(c) == "", do: "", else: "助手: " <> String.slice(c, 0, 180)
      end)

    [intents, assistant_lines, Enum.join(code_lines, "\n"), Enum.join(out_lines, "\n")]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n\n")
    |> String.slice(0, @extract_budget)
  end

  # digest 生成器二态：函数（注入用，测试/离线）直接调；LLM client 走 complete/3。
  defp llm_digest(digest, extract, seg_id) when is_function(digest, 2),
    do: digest.(extract, seg_id)

  defp llm_digest(client, extract, seg_id) do
    prompt =
      "以下是一个编程 agent 会话片段（段 #{seg_id}）的结构化抽取。" <>
        "用 ≤300 字中文写要点摘要：任务目标、关键决策、改动、踩过的坑与解法、未完成事项。只输出摘要正文。\n\n" <> extract

    case Newbee.LLM.Client.complete(client, [%{"role" => "user", "content" => prompt}], extra: %{max_tokens: 500}) do
      {:ok, content, _} ->
        text = content |> String.trim() |> String.slice(0, @digest_max_chars)
        if text == "", do: {:error, :empty_digest}, else: {:ok, text}

      other ->
        {:error, {:digest_failed, other}}
    end
  rescue
    e -> {:error, {:digest_raised, e}}
  end

  # ── 前缀缓存友好摘要路径（deepseek-harness 2026-07-21 note 同构）──
  # warm_prefix 是压缩前 view(session)；消息对象完全原样，不截断、不降维。
  # ── 前缀回放摘要（envelope 命中路径）──
  # 回放上次路由请求快照的消息 + tools，尾部追加压缩指令。
  # 消息与 tools 与快照逐字节一致（不截断/不降维），是严格前缀。
  defp llm_digest_replay(client, env, seg_id) do
    prefix = env["messages"] || []
    # tools 固定用当前 Codec（与路由请求 stream_chat 同源），保证请求体与路由一致；
    # env["tools"] 仅用于 hit_eligible? 一致性校验（A3），不用作请求体来源。
    tools = Newbee.Codec.tools()

    request =
      prefix ++
        [%{"role" => "user", "content" => @compaction_instruction}]

    Newbee.DebugLog.log(
      :compact,
      "digest seg=" <>
        seg_id <>
        " hit-path messages=" <> Integer.to_string(length(request)) <> " tools=" <> Integer.to_string(length(tools))
    )

    case Newbee.LLM.Client.complete(client, request, tools: tools, temperature: nil, extra: %{max_tokens: 500}) do
      {:ok, content, _} ->
        text = content |> String.trim() |> String.slice(0, @digest_max_chars)
        if text == "", do: {:error, :empty_digest}, else: {:ok, text}

      other ->
        {:error, {:digest_failed, other}}
    end
  rescue
    e -> {:error, {:digest_raised, e}}
  end

  # 历史补写没有与其对应的暖 routed request；走抽取路径保证正确性，不伪装命中。
  defp backfill_digests(%Session{} = session, client) do
    have = digests(session)

    session
    |> segments()
    |> Enum.reject(&Map.has_key?(have, &1.id))
    |> Enum.take(@backfill_segments)
    |> Enum.each(&digest_segment(session, &1.id, client))
  end

  # ── 账本与段文件（EventStore 同款纪律：追加写 + 坏尾截断）──

  # 逐行 JSON；首个坏行（崩溃写一半）之后的全部丢弃——半条账本 = 没发生过。
  defp ledger(%Session{} = session) do
    case File.read(ledger_path(session)) do
      {:ok, body} ->
        body
        |> String.split("\n", trim: true)
        |> Enum.reduce_while([], fn line, acc ->
          case Jason.decode(line) do
            {:ok, %{"id" => id, "topic" => topic} = ev} when is_integer(id) and is_binary(topic) ->
              {:cont, [ev | acc]}

            _ ->
              {:halt, acc}
          end
        end)
        |> Enum.reverse()

      _ ->
        []
    end
  end

  defp append_ledger(%Session{} = session, event) do
    path = ledger_path(session)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, [Jason.encode_to_iodata!(event), "\n"], [:append])
    Session.mark_created(session.id)
    event
  end

  defp ledger_path(%Session{dir: dir}), do: Path.join(dir, @ledger_name)
  defp segment_path(%Session{dir: dir}, seg_id), do: Path.join([dir, @seg_dir, seg_id <> ".jsonl"])

  defp write_segment(%Session{} = session, seg_id, bin) do
    path = segment_path(session, seg_id)
    File.mkdir_p!(Path.dirname(path))
    tmp = path <> ".tmp"
    File.write!(tmp, bin)
    File.rename!(tmp, path)
  end

  defp ledger_find(%Session{} = session, seg_id) do
    session
    |> ledger()
    |> Enum.find(&(&1["topic"] == "compacted" and &1["data"]["segment"] == seg_id))
  end

  defp next_event_id(%Session{} = session) do
    case ledger(session) |> List.last() do
      %{"id" => id} when is_integer(id) -> id + 1
      _ -> 1
    end
  end

  defp next_segment_id(%Session{} = session) do
    n = length(Enum.filter(ledger(session), &(&1["topic"] == "compacted"))) + 1
    @seg_prefix <> String.pad_leading(Integer.to_string(n), 4, "0")
  end

  # ── 切点计算与校验 ──

  # 当前生效切点：tail_sha 与 transcript 对齐的最后一条 compacted 事件的 upto；
  # 越界 / sha 不对齐（日志漂移，如旧版本覆写过）→ 返回 nil（视图退回原始消息）。
  defp validated_cut(%Session{} = session, raw) do
    session
    |> ledger()
    |> Enum.filter(&(&1["topic"] == "compacted"))
    |> Enum.sort_by(& &1["data"]["upto"])
    |> Enum.reverse()
    |> Enum.find(fn ev ->
      upto = ev["data"]["upto"]

      is_integer(upto) and upto >= 1 and upto < length(raw) and
        sha256(Jason.encode_to_iodata!(Enum.at(raw, upto - 1))) == ev["data"]["tail_sha"]
    end)
    |> case do
      nil -> nil
      ev -> ev["data"]["upto"]
    end
  end

  # 基于 prev_cut 计算新切点与归档区间（保留语义沿用旧 split_for_retention：
  # 条数模式保留最近 retain 条；token 模式从尾部按预算保留，至少保最新 1 条。
  # 预算内放得下 → {prev_cut, []} → noop；transcript 不含 system 基底，从 0 起切）
  defp plan_cut(raw, prev_cut, retain) when retain <= 64 do
    new_cut = (length(raw) - retain) |> max(prev_cut) |> min(max(length(raw) - 1, 0))

    if new_cut <= prev_cut or raw == [] do
      {prev_cut, []}
    else
      {new_cut, Enum.slice(raw, prev_cut, new_cut - prev_cut)}
    end
  end

  defp plan_cut(raw, prev_cut, retain) do
    tail = Enum.drop(raw, prev_cut)
    keep = retention_keep(tail, retain)

    if length(keep) >= length(tail) do
      {prev_cut, []}
    else
      new_cut = (length(raw) - length(keep)) |> max(prev_cut + 1) |> min(length(raw))
      {new_cut, Enum.slice(raw, prev_cut, new_cut - prev_cut)}
    end
  end

  # 从尾部按 token 预算保留（与旧 split_for_retention 同语义：至少保最新 1 条）
  defp retention_keep(messages, budget) do
    messages
    |> Enum.reverse()
    |> Enum.reduce_while({[], 0}, fn m, {keep, tokens} ->
      cost = estimate_tokens(m)

      if keep == [] or tokens + cost <= budget do
        {:cont, {[m | keep], tokens + cost}}
      else
        {:halt, {keep, tokens}}
      end
    end)
    |> elem(0)
  end

  defp cut_of(%Session{} = session, raw) do
    case validated_cut(session, raw) do
      nil -> 0
      upto -> upto
    end
  end

  @doc "token 估算（与 Loop 口径一致：bytes/3 + 常数）"
  def estimate_tokens(m) do
    div(byte_size(Jason.encode!(m)) + 2, 3) + 8
  rescue
    _ -> div(byte_size(inspect(m)) + 2, 3) + 8
  end

  # ── 杂项 ──

  defp sha256(bin), do: :crypto.hash(:sha256, bin) |> Base.encode16(case: :lower)
  defp iso_now, do: DateTime.utc_now() |> DateTime.to_iso8601()

  defp maybe_truncate(bin, cap) when byte_size(bin) <= cap, do: bin

  defp maybe_truncate(bin, cap),
    do: binary_part(bin, 0, cap) <> "\n… [截断：#{byte_size(bin)} bytes > #{cap}] …"
end
