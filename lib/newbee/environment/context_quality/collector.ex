defmodule Newbee.Environment.ContextQuality.Collector do
  @moduledoc """
  ContextQuality Collector：事件流 → ContextQuality ledger 的桥梁。

  订阅 `Newbee.Bus`（{:newbee_event, topic, event}），按 session 维护"当前 turn
  注入了哪些 release（沉睡规则/记忆）"的滑动窗口，在 turn 结束时把
  （注入集合 × outcome）记入 ContextQuality 账本并持久化。

  ## outcome 判定（确定性，非 LLM judge —— Blind Curator 防线）

  turn outcome = success 当且仅当：
    - 收到 `{:goal_done, _}`（模型自评完成）且该 turn **无 tool_error**；或
    - verifier `final_score` ≥ 阈值（若有）
  任一 `tool_error` 或 `final_check_low` → 该 turn 记 failure。

  ## 注入归因

  `{:prompt_injection, %{source: rule_id}}` → 该 rule 在本 turn 处于上下文。
  turn 内注入过的 release 记 `injected?=true`，**未注入的活跃 release 记
  `injected?=false`**（基线侧）——这是差分归因的关键：同一 release 既积累
  with_ctx 也积累 without_ctx 样本（取自它没参与的那些 turn）。

  幂等：turn 以 turn_end/goal_done 为界；无 turn 边界的孤立注入不产生样本。
  """

  use GenServer
  require Logger

  alias Newbee.Environment.{ContextQuality, Store}

  @stats_path "context_quality.jsonl"
  # 活跃 release 登记上限（防内存膨胀，§9.1 GC 纪律）
  @max_ledgers 500

  # ── 状态 ──
  # %{
  #   ledgers: %{release_id => ContextQuality.ledger()},
  #   turns: %{session_id => %{injected: MapSet.t(), errors: non_neg_integer(),
  #                           tokens: non_neg_integer(), done: boolean()}},
  #   active: MapSet.t()  # 已知活跃 release（用于基线归因）
  # }
  defstruct ledgers: %{}, turns: %{}, active: MapSet.new()

  # ═══════════ 公共 API ═══════════

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "取某 release 的质量账本。"
  def ledger(release_id, server \\ __MODULE__) do
    GenServer.call(server, {:ledger, release_id})
  end

  @doc "全部 release 的质量价签（Projection/TUI 展示）。"
  def price_tags(server \\ __MODULE__) do
    GenServer.call(server, :price_tags)
  end

  @doc "需退休的 release 清单（verdict == :harmful 或 bloat 回归）。"
  def retire_candidates(server \\ __MODULE__) do
    GenServer.call(server, :retire_candidates)
  end

  @doc "登记一个活跃 release（激活时调用，使其参与基线归因）。"
  def register_release(release_id, server \\ __MODULE__) do
    GenServer.cast(server, {:register, release_id})
  end

  # ═══════════ GenServer ═══════════

  @impl true
  def init(opts) do
    if Keyword.get(opts, :subscribe, true) and Process.whereis(Newbee.Bus) do
      Newbee.Bus.subscribe()
    end

    {:ok, %{__struct__() | ledgers: restore(), active: restore_active()}}
  end

  @impl true
  def handle_call({:ledger, rid}, _from, s) do
    {:reply, Map.get(s.ledgers, rid, ContextQuality.new_ledger()), s}
  end

  def handle_call(:price_tags, _from, s) do
    tags =
      Map.new(s.ledgers, fn {rid, l} -> {rid, ContextQuality.summary(l)} end)

    {:reply, tags, s}
  end

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
  def handle_cast({:register, rid}, s) do
    {:noreply, %{s | active: MapSet.put(s.active, to_string(rid))}}
  end

  @impl true
  def handle_info({:newbee_event, topic, event}, s) do
    {:noreply, handle_event(topic, event, s)}
  end

  def handle_info(_, s), do: {:noreply, s}

  # ═══════════ 事件处理（纯函数，可测） ═══════════

  @doc false
  def handle_event(:prompt_injection, event, s) do
    {sid, rid} = {session_of(event), source_of(event)}

    if sid && rid do
      update_turn(s, sid, fn t -> %{t | injected: MapSet.put(t.injected, rid)} end)
      |> register_active(rid)
    else
      s
    end
  end

  def handle_event(:tool_error, event, s) do
    case session_of(event) do
      nil -> s
      sid -> update_turn(s, sid, fn t -> %{t | errors: t.errors + 1} end)
    end
  end

  def handle_event(:usage, event, s) do
    tokens = (event[:tokens] || event["tokens"] || total_tokens(event)) |> trunc()

    case session_of(event) do
      nil -> s
      sid -> update_turn(s, sid, fn t -> %{t | tokens: t.tokens + tokens} end)
    end
  end

  def handle_event(:final_check_low, event, s) do
    case session_of(event) do
      nil -> s
      sid -> update_turn(s, sid, fn t -> %{t | errors: t.errors + 1} end)
    end
  end

  def handle_event(:goal_done, event, s) do
    case session_of(event) do
      nil -> s
      sid -> close_turn(s, sid, true)
    end
  end

  def handle_event(:turn_end, event, s) do
    case session_of(event) do
      nil -> s
      # turn_end 无 goal_done 时按成败未定处理——只在有明确信号时记账
      sid -> close_turn(s, sid, nil)
    end
  end

  def handle_event(_, _, s), do: s

  # ── turn 生命周期 ──

  defp update_turn(s, sid, fun) do
    t = Map.get(s.turns, sid, fresh_turn())
    %{s | turns: Map.put(s.turns, sid, fun.(t))}
  end

  defp register_active(s, rid), do: %{s | active: MapSet.put(s.active, rid)}

  defp fresh_turn, do: %{injected: MapSet.new(), errors: 0, tokens: 0}

  # turn 关闭：有明确成败信号才记账
  defp close_turn(s, sid, done_override) do
    case Map.pop(s.turns, sid) do
      {nil, _} ->
        s

      {t, turns} ->
        s = %{s | turns: turns}

        success =
          cond do
            done_override == true and t.errors == 0 -> true
            done_override == true and t.errors > 0 -> false
            done_override == false -> false
            # turn_end 无 goal 信号且出错 → failure；干净退出 → 不计（成败未定）
            done_override == nil and t.errors > 0 -> false
            done_override == nil and t.injected == MapSet.new() -> :skip
            true -> :skip
          end

        if success == :skip do
          s
        else
          record_turn(s, t, success)
        end
    end
  end

  # 差分归因落账：注入的记 with_ctx，未注入的活跃 release 记 without_ctx
  defp record_turn(s, t, success) do
    tokens = if t.tokens > 0, do: t.tokens, else: nil

    ledgers =
      s.active
      |> Enum.reduce(s.ledgers, fn rid, acc ->
        injected? = MapSet.member?(t.injected, rid)
        l = Map.get(acc, rid, ContextQuality.new_ledger())
        Map.put(acc, rid, ContextQuality.record(l, injected?, success, tokens))
      end)
      # GC：超上限时淘汰样本最少的账本（§9.1）
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

  # ── 事件字段提取（兼容 atom/string key） ──

  defp session_of(event) when is_map(event) do
    event[:session_id] || event["session_id"] || event[:session] || event["session"]
  end

  defp session_of(_), do: nil

  defp source_of(event) when is_map(event) do
    src = event[:source] || event["source"]
    if is_binary(src), do: src, else: nil
  end

  defp source_of(_), do: nil

  defp total_tokens(event) do
    (event[:total_tokens] || event["total_tokens"] || 0) +
      (event[:input_tokens] || event["input_tokens"] || 0) +
      (event[:output_tokens] || event["output_tokens"] || 0)
  end

  # ── 持久化（Project Store evaluations/） ──

  defp persist(ledgers) do
    if Process.whereis(Newbee.Bus) && store_ready?() do
      dir = Path.join(Store.dir(:evaluations), "context_quality")
      File.mkdir_p!(dir)
      path = Path.join(dir, @stats_path)

      content =
        ledgers
        |> Enum.map(fn {rid, l} -> Jason.encode!(%{release_id: rid, ledger: ser(l)}) end)
        |> Enum.join("\n")

      Store.write_atomic!(path, content <> "\n")
    end
  rescue
    e -> Logger.debug("context_quality persist failed: #{Exception.message(e)}")
  end

  defp restore do
    if store_ready?() do
      path = Path.join([Store.dir(:evaluations), "context_quality", @stats_path])

      with {:ok, content} <- File.read(path),
           lines <- String.split(content, "\n", trim: true) do
        Map.new(lines, fn line ->
          case Jason.decode(line) do
            {:ok, %{"release_id" => rid, "ledger" => l}} -> {rid, deser(l)}
            _ -> {nil, nil}
          end
        end)
        |> Map.delete(nil)
      else
        _ -> %{}
      end
    else
      %{}
    end
  rescue
    _ -> %{}
  end

  defp restore_active, do: MapSet.new()

  defp store_ready?, do: function_exported?(Store, :dir, 1)

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
