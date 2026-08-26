defmodule Newbee.Environment.ContextQuality.Collector do
  @moduledoc """
  ContextQuality Collector：事件流 → ContextQuality ledger 的桥梁。

  订阅 `Newbee.Bus`（{:newbee_event, topic, event}），按 **单活跃 turn 模型**
  归集事件：harness 顺序执行，同一时刻只有一个活跃 turn；事件按时间顺序归属
  当前 turn，turn 在 `turn_end`/`goal_done` 处关闭并记账。

  ## 真实事件载荷（.newbee/events.jsonl 实证）

  - `prompt_injection`：payload[1] 是 map，规则 id 在 `rules[].id`（source 恒为
    "sleeping_rule"），session_id 在 map 顶层。
  - `turn_end`：payload = ["turn_end", outcome_type, ms]，outcome_type ∈
    "done"/"error"/"interrupted"/"text"/"ask"。**不带 session_id**。
  - `tool_error`：payload = ["tool_error", msg]。不带 session_id。
  - `usage`：payload = ["usage", %{total_tokens, model, ...}]。不带 session_id。
  - `goal_done`：payload 是 %{session_id}。

  ## outcome 判定（确定性，非 LLM judge —— Blind Curator 防线）

  turn success 当且仅当 `turn_end` outcome_type == "done" 或收到 goal_done，
  **且**该 turn 无 tool_error；"error"/"interrupted" 或有 tool_error → failure。

  ## 注入归因（差分）

  turn 内注入的 release 记 with_ctx，未注入的活跃 release 记 without_ctx。
  """

  use GenServer
  require Logger

  alias Newbee.Environment.{ContextQuality, Store}

  @stats_path "context_quality.jsonl"
  @max_ledgers 500

  # current_turn: nil | %{injected: MapSet.t(), errors: non_neg_integer(),
  #                       tokens: non_neg_integer(), goal_done: boolean()}
  defstruct ledgers: %{}, current_turn: nil, active: MapSet.new()

  # ═══════════ 公共 API ═══════════

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  def ledger(release_id, server \\ __MODULE__), do: GenServer.call(server, {:ledger, release_id})
  def price_tags(server \\ __MODULE__), do: GenServer.call(server, :price_tags)
  def retire_candidates(server \\ __MODULE__), do: GenServer.call(server, :retire_candidates)

  def register_release(release_id, server \\ __MODULE__) do
    GenServer.cast(server, {:register, release_id})
  end

  # ═══════════ GenServer ═══════════

  @impl true
  def init(opts) do
    if Keyword.get(opts, :subscribe, true) and Process.whereis(Newbee.Bus) do
      Newbee.Bus.subscribe()
    end

    {:ok, %{__struct__() | ledgers: restore()}}
  end

  @impl true
  def handle_call({:ledger, rid}, _from, s),
    do: {:reply, Map.get(s.ledgers, rid, ContextQuality.new_ledger()), s}

  def handle_call(:price_tags, _from, s),
    do: {:reply, Map.new(s.ledgers, fn {rid, l} -> {rid, ContextQuality.summary(l)} end), s}

  def handle_call(:retire_candidates, _from, s) do
    cands =
      s.ledgers
      |> Enum.filter(fn {_rid, l} ->
        ContextQuality.verdict(l) == :harmful or ContextQuality.bloat_regression?(l)
      end)
      |> Enum.map(fn {rid, l} -> {rid, ContextQuality.summary(l)} end)

    {:reply, cands, s}
  end

  @impl true
  def handle_cast({:register, rid}, s), do: {:noreply, %{s | active: MapSet.put(s.active, to_string(rid))}}

  @impl true
  def handle_info({:newbee_event, topic, event}, s), do: {:noreply, handle_event(topic, event, s)}
  def handle_info(_, s), do: {:noreply, s}

  # ═══════════ 事件处理（纯函数，可测） ═══════════

  @doc false
  def handle_event(:prompt_injection, event, s) do
    # 规则 id 从 rules[].id 提取（真实载荷：source 恒为 "sleeping_rule"）
    rids = rule_ids_of(event)

    if rids == [] do
      s
    else
      s = ensure_turn(s)

      s =
        update_current(s, fn t ->
          %{t | injected: Enum.reduce(rids, t.injected, &MapSet.put(&2, &1))}
        end)

      %{s | active: Enum.reduce(rids, s.active, &MapSet.put(&2, &1))}
    end
  end

  def handle_event(:rule_hit, event, s) do
    # rule_hit 也是注入信号（规则命中即注入上下文）
    handle_event(:prompt_injection, event, s)
  end

  def handle_event(:tool_error, _event, s) do
    s |> ensure_turn() |> update_current(fn t -> %{t | errors: t.errors + 1} end)
  end

  def handle_event(:final_check_low, _event, s) do
    s |> ensure_turn() |> update_current(fn t -> %{t | errors: t.errors + 1} end)
  end

  def handle_event(:usage, event, s) do
    tokens = safe_int(usage_tokens(event))

    if tokens > 0 do
      s |> ensure_turn() |> update_current(fn t -> %{t | tokens: t.tokens + tokens} end)
    else
      s
    end
  end

  def handle_event(:goal_done, _event, s) do
    s |> ensure_turn() |> update_current(fn t -> %{t | goal_done: true} end) |> close_turn(:done)
  end

  def handle_event(:turn_end, event, s) do
    outcome = turn_end_outcome(event)
    close_turn(s, outcome)
  end

  def handle_event(_, _, s), do: s

  # ═══════════ turn 生命周期（单活跃 turn） ═══════════

  defp ensure_turn(%{current_turn: nil} = s), do: %{s | current_turn: fresh_turn()}
  defp ensure_turn(s), do: s

  # 调用方都先经 ensure_turn，current_turn 必非 nil
  defp update_current(%{current_turn: t} = s, fun) when not is_nil(t),
    do: %{s | current_turn: fun.(t)}

  defp fresh_turn, do: %{injected: MapSet.new(), errors: 0, tokens: 0, goal_done: false}

  # outcome: :done | :error | :interrupted | :text | :ask | nil
  defp close_turn(%{current_turn: nil} = s, _outcome), do: s

  defp close_turn(s, outcome) do
    t = s.current_turn
    s = %{s | current_turn: nil}

    success =
      cond do
        # goal_done 显式声明 + 无错误
        t.goal_done and t.errors == 0 -> true
        t.goal_done and t.errors > 0 -> false
        # turn_end outcome_type
        outcome == :done and t.errors == 0 -> true
        outcome == :done and t.errors > 0 -> false
        outcome in [:error, :interrupted] -> false
        t.errors > 0 -> false
        # text/ask/nil：成败未定，诚实缺测不记账
        true -> :skip
      end

    if success == :skip or MapSet.size(t.injected) == 0 do
      s
    else
      record_turn(s, t, success)
    end
  end

  defp record_turn(s, t, success) do
    tokens = if t.tokens > 0, do: t.tokens, else: nil

    ledgers =
      s.active
      |> Enum.reduce(s.ledgers, fn rid, acc ->
        injected? = MapSet.member?(t.injected, rid)
        l = Map.get(acc, rid, ContextQuality.new_ledger())
        Map.put(acc, rid, ContextQuality.record(l, injected?, success, tokens))
      end)
      |> gc_ledgers()

    persist(ledgers)
    %{s | ledgers: ledgers}
  end

  defp gc_ledgers(ledgers) when map_size(ledgers) <= @max_ledgers, do: ledgers

  defp gc_ledgers(ledgers) do
    ledgers
    |> Enum.sort_by(fn {_r, l} -> l.n_with + l.n_without end)
    |> Enum.take(@max_ledgers)
    |> Map.new()
  end

  # ═══════════ 载荷解析（兼容真实事件流形状） ═══════════

  # 规则 id：真实载荷 rules[].id；兼容 source 直接是规则 id 的情况
  # 系统注入的 source（非可退休经验，不进入质量度量）——实证自真实事件流
  @system_sources ["sleeping_rule", "history_recall", "goal_continue", "goal_start",
                   "goal_idle", "final_verifier", "jspace_recovery"]

  defp rule_ids_of(event) when is_map(event) do
    rules = event[:rules] || event["rules"]

    cond do
      # 权威来源：rules[].id（沉睡规则命中的真实载荷）
      is_list(rules) and rules != [] ->
        rules
        |> Enum.map(fn r -> if is_map(r), do: r[:id] || r["id"], else: nil end)
        |> Enum.filter(&is_binary/1)

      # fallback：仅当 source 是明确的自定义规则（非系统注入）才收录
      true ->
        case event[:source] || event["source"] do
          src when is_binary(src) ->
            if src in @system_sources, do: [], else: [src]

          _ ->
            []
        end
    end
  end

  defp rule_ids_of(_), do: []

  # turn_end outcome：payload = ["turn_end", type, ms]（真实流），或 map
  defp turn_end_outcome(event) when is_map(event) do
    case event[:payload] || event["payload"] do
      ["turn_end", type | _] when is_binary(type) -> String.to_atom(type)
      [_, type | _] when is_binary(type) -> String.to_atom(type)
      _ -> nil
    end
  end

  defp turn_end_outcome(_), do: nil

  # usage tokens：payload = ["usage", %{total_tokens}]，或 %{tokens}
  defp usage_tokens(event) when is_map(event) do
    case event[:payload] || event["payload"] do
      ["usage", usage] when is_map(usage) ->
        usage[:total_tokens] || usage["total_tokens"] ||
          (safe_int(usage[:prompt_tokens] || usage["prompt_tokens"]) +
             safe_int(usage[:completion_tokens] || usage["completion_tokens"]))

      usage when is_map(usage) ->
        usage[:total_tokens] || usage["total_tokens"] || usage[:tokens] || usage["tokens"]

      _ ->
        # 真实流形状：usage map 顶层直接带 total_tokens / prompt+completion
        event[:total_tokens] || event["total_tokens"] || event[:tokens] || event["tokens"] ||
          safe_int(event[:prompt_tokens] || event["prompt_tokens"]) +
            safe_int(event[:completion_tokens] || event["completion_tokens"])
    end
  end

  defp usage_tokens(_), do: 0

  # 健壮性（隔离性原则）：事件字段任意形态，非数字降级 0，绝不让畸形事件杀死 Collector
  defp safe_int(v) when is_integer(v), do: v
  defp safe_int(v) when is_float(v), do: trunc(v)

  defp safe_int(v) when is_binary(v) do
    case Integer.parse(v) do
      {n, _} -> n
      _ -> 0
    end
  end

  defp safe_int(_), do: 0

  # ═══════════ 持久化（Project Store evaluations/） ═══════════

  defp persist(ledgers) do
    dir = Path.join(Store.dir(:evaluations), "context_quality")
    File.mkdir_p!(dir)
    path = Path.join(dir, @stats_path)

    content =
      ledgers
      |> Enum.map(fn {rid, l} -> Jason.encode!(%{release_id: rid, ledger: ser(l)}) end)
      |> Enum.join("\n")

    Store.write_atomic!(path, content <> "\n")
  rescue
    e -> Logger.debug("context_quality persist failed: #{Exception.message(e)}")
  end

  defp restore do
    path = Path.join([Store.dir(:evaluations), "context_quality", @stats_path])

    with {:ok, content} <- File.read(path),
         lines <- String.split(content, "\n", trim: true) do
      lines
      |> Enum.reduce(%{}, fn line, acc ->
        case Jason.decode(line) do
          {:ok, %{"release_id" => rid, "ledger" => l}} -> Map.put(acc, rid, deser(l))
          _ -> acc
        end
      end)
    else
      _ -> %{}
    end
  rescue
    _ -> %{}
  end

  defp ser(l) do
    %{
      with_ctx: Tuple.to_list(l.with_ctx),
      without_ctx: Tuple.to_list(l.without_ctx),
      with_tokens: l.with_tokens,
      without_tokens: l.without_tokens,
      n_with: l.n_with,
      n_without: l.n_without
    }
  end

  defp deser(m) do
    %{
      with_ctx: List.to_tuple(m["with_ctx"]),
      without_ctx: List.to_tuple(m["without_ctx"]),
      with_tokens: m["with_tokens"] || 0.0,
      without_tokens: m["without_tokens"] || 0.0,
      n_with: m["n_with"] || 0,
      n_without: m["n_without"] || 0
    }
  end
end
