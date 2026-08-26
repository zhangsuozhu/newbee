defmodule Newbee.Environment.PatternStore do
  @moduledoc """
  PatternStore（TCE 总纲 A/F 节）：pattern → PatternStats 投影的持有与持久化。

  - 数据源是既有事件流（tool_start / tool_error / release_observation），
    零新增观测通道 [D9]；
  - 持久化到 Project Store `evaluations/pattern_stats.jsonl`（原子写），
    重启可恢复；
  - 分桶粒度 pattern × task_type [D16]；
  - 时间衰减 [D6]：每 @decay_interval 次观察整体乘 @decay_factor。

  语义约定（诚实计量）：
  - tool_start.tokens = 该 pattern 本次消耗的推理 token —— 即"如果已编译本可节省的量"，
    作为 saved_tokens 观测；这是编译收益的上界（编译后仍有调用成本~0，故上界≈真值）。
  - tool_error → success=false 计入 succ 后验（供 deopt 判据）。
  """

  alias Newbee.Environment.{PatternStats, Store}
  alias Newbee.Environment.Jit, as: JitStrategy

  @stats_file "pattern_stats.jsonl"
  @decay_every_n 500
  @decay_factor 0.98

  # ── 键 ──
  @doc "pattern × task_type 复合键 [D16]。"
  def key_of(%{"topic" => topic, "payload" => [_, name | _]} = ev)
      when is_binary(name) and topic in ["tool_start", "tool_error", "tool_result"] do
    # 真实事件流形状（Events.append_durable 落盘）:
    #   {:tool_start, name, title, code} -> payload=[topic,name,title,code]
    {{:tool_use, name}, task_type_of(ev)}
  end

  def key_of(%{"topic" => topic, "data" => %{"name" => name}} = ev)
      when topic in ["tool_start", "tool_error"] do
    {{:tool_use, name}, task_type_of(ev)}
  end

  def key_of(%{topic: t, data: %{name: name}} = ev) when t in [:tool_start, :tool_error] do
    {{:tool_use, name}, task_type_of(ev)}
  end

  def key_of(%{topic: t, payload: [_t2, name | _]} = ev)
      when t in [:tool_start, :tool_result] and is_binary(name) do
    {{:tool_use, name}, task_type_of(ev)}
  end

  # 真实事件流 JSON 反序列化后 topic 是字符串、map key 是 atom（消费端归一化裂缝）
  def key_of(%{topic: t, payload: [_t2, name | _]} = ev)
      when t in ["tool_start", "tool_result"] and is_binary(name) do
    {{:tool_use, name}, task_type_of(ev)}
  end

  # tool_error 的 payload 第二元素是错误消息文本而非工具名——
  # 不提取为 tool_use 模式（避免把错误堆栈当成工具产生假模式）。
  # 错误归因由 success_of 通道处理（tool_error → success=false 计入配对工具）。
  def key_of(%{topic: t, payload: [_, msg | _]})
      when t in [:tool_error, "tool_error"] and is_binary(msg) do
    nil
  end
  def key_of(ev) when is_map(ev) do
    case JitStrategy.pattern_key(ev) do
      nil -> nil
      key -> {key, task_type_of(ev)}
    end
  end

  def key_of(_), do: nil

  defp task_type_of(%{"data" => %{"task_type" => t}}) when is_binary(t), do: t
  defp task_type_of(%{data: %{task_type: t}}) when is_binary(t), do: t
  defp task_type_of(_), do: "general"


  # ── 投影：事件流 → stats ──

  @doc "从事件流重建全部 PatternStats（幂等投影）。"
  def project(events) when is_list(events) do
    Enum.reduce(events, %{}, fn ev, acc ->
      case key_of(ev) do
        nil -> acc
        key ->
          existing = Map.get(acc, key)
          base = if is_struct(existing, PatternStats), do: existing, else: PatternStats.new()
          Map.put(acc, key, apply_event(base, ev))
      end
    end)
  end

  defp apply_event(%PatternStats{} = s, ev) do
    # token 归因优先级: 显式字段 > Collector 归因(usage) > 无(不估计,宁缺毋滥 R6)
    tokens =
      ev[:tokens] || ev["tokens"] ||
        case ev do
          %{data: %{tokens: t}} when is_number(t) -> t
          %{"data" => %{"tokens" => t}} when is_number(t) -> t
          %{payload: [_t, _n, _x, tk]} when is_number(tk) -> tk
          _ -> estimate_tokens()
        end

    obs =
      if is_number(tokens) do
        %{success: success_of(ev), saved_tokens: tokens * 1.0, count: count_of(ev)}
      else
        %{success: success_of(ev), count: count_of(ev)}
      end

    PatternStats.observe(s, obs)
    |> maybe_decay()
  end

  defp success_of(%{topic: :tool_error}), do: false
  defp success_of(%{"topic" => "tool_error"}), do: false
  # tool_start 只记频率不判成败；tool_result(完成)才是成功信号
  defp success_of(%{topic: :tool_result}), do: true
  defp success_of(%{"topic" => "tool_result"}), do: true
  defp success_of(_), do: nil

  defp count_of(%{count: c}) when is_number(c), do: c
  defp count_of(%{"count" => c}) when is_number(c), do: c
  defp count_of(_), do: 1

  defp maybe_decay(%PatternStats{n: n} = s) when rem(n, @decay_every_n) == 0 and n > 0 do
    PatternStats.decay(s, @decay_factor)
  end

  defp maybe_decay(s), do: s

  # 无真实 token 观测时不做默认估计——宁缺毋滥（R6 反思）
  defp estimate_tokens, do: nil

  # ── 持久化 ──

  @doc "stats map 序列化为 JSONL 行列表。key 编码为 inspect 字符串（稳定、可读）。"
  def serialize(stats) when is_map(stats) do
    Enum.map(stats, fn {key, %PatternStats{} = s} ->
      %{
        "key" => inspect(key),
        "freq" => tuple_to_list(s.freq),
        "succ" => tuple_to_list(s.succ),
        "save" => tuple_to_list(s.save),
        "n" => s.n,
        "snapshot" => stringify_map(s.snapshot)
      }
    end)
  end

  @doc "写入 Project Store（原子写）。返回 :ok | {:error, reason}。"
  def persist(stats) when is_map(stats) do
    dir = Path.join(Store.dir(:evaluations), "pattern_stats")
    File.mkdir_p!(dir)
    path = Path.join(dir, @stats_file)

    content =
      stats
      |> serialize()
      |> Enum.map(&Jason.encode!/1)
      |> Enum.join("\n")

    Store.write_atomic!(path, content <> "\n")
  rescue
    e -> {:error, Exception.message(e)}
  end

  @doc "从 Project Store 恢复。无文件时返回空 map。"
  def restore do
    path = Path.join([Store.dir(:evaluations), "pattern_stats", @stats_file])

    with {:ok, content} <- File.read(path),
         lines <- content |> String.split("\n", trim: true) do
      lines
      |> Enum.reduce(%{}, fn line, acc ->
        case Jason.decode(line) do
          {:ok, m} ->
            key = decode_key(m["key"])
            Map.put(acc, key, from_row(m))

          _ ->
            acc
        end
      end)
    else
      _ -> %{}
    end
  rescue
    _ -> %{}
  end

  @doc "单行 map → PatternStats。"
  def from_row(m) do
    %PatternStats{
      freq: list_to_pair(m["freq"]),
      succ: list_to_pair(m["succ"]),
      save: list_to_triple(m["save"]),
      n: m["n"] || 0,
      snapshot:
        (m["snapshot"] || %{})
        |> Enum.map(fn {k, v} -> {String.to_atom(k), v} end)
        |> Map.new()
    }
  end

  defp decode_key(str) when is_binary(str) do
    case Code.string_to_quoted(str) do
      {:ok, ast} ->
        try do
          {tuple, _} = Code.eval_quoted(ast)
          tuple
        rescue
          _ -> str
        end

      _ ->
        str
    end
  end

  defp decode_key(other), do: other

  defp tuple_to_list(t) when is_tuple(t), do: Tuple.to_list(t) |> Enum.map(&to_float/1)

  defp to_float(v) when is_integer(v), do: v * 1.0
  defp to_float(v) when is_float(v), do: v
  defp to_float(v), do: v

  defp list_to_pair([a, b]), do: {a * 1.0, b * 1.0}
  defp list_to_pair(_), do: {1.0, 1.0}

  defp list_to_triple([a, b, c]), do: {a * 1.0, b * 1.0, c * 1.0}
  defp list_to_triple(_), do: {0.0, 0.0, 1.0}

  defp stringify_map(m) when is_map(m) do
    m
    |> Enum.map(fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), v}
      kv -> kv
    end)
    |> Map.new()
  end
end
