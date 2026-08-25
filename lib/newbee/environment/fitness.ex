defmodule Newbee.Environment.Fitness do
  @moduledoc """
  价签系统（DESIGN §3.3）：ReleaseObservation 事件流 + fitness 投影。

  - 每次使用带 `release_id` 归因记账：observe 产生 observation 事件
    （token 成本、成功率、延迟、输出大小，按 **模型 × 任务类型 × 时间窗口**
    分桶）——事件进 Event Store，持久可归因；
  - `fitness` 是评价层对 observation 的持续聚合投影，可随证据变化，
    **绝不写回 Release 本体**（Release 严格不可变）；
  - Projection 向模型暴露聚合价签——模型按"够用且最便宜"显式选路；
  - **样本不足的桶不展示**（min_samples，默认 3）；
  - 价签与实测偏差在滑动窗口内收敛（窗口/偏差阈值为配置参数，§15.16）。
  """

  alias Newbee.Environment.Store

  @min_samples 3
  @window_days 7
  # 滑动窗口内预测与实测的允许偏差（§15.16 配置参数）
  @deviation_threshold 0.5

  # ── 记账 ──

  @doc """
  使用归因记账。obs = %{success, latency_ms, tokens, output_bytes, model, task_type}。
  写入项目 evaluations/observations/<release_id>.jsonl（Event Store 的
  release_observation 事件的物化投影，event 本体由 Coordinator/Events 落盘）。
  """
  def observe(release_id, obs) when is_map(obs) do
    entry = %{
      "release_id" => release_id,
      "success" => truthy(obs[:success] || obs["success"]),
      "latency_ms" => obs[:latency_ms] || obs["latency_ms"] || 0,
      "tokens" => obs[:tokens] || obs["tokens"] || 0,
      "output_bytes" => obs[:output_bytes] || obs["output_bytes"] || 0,
      "model" => obs[:model] || obs["model"] || "unknown",
      "task_type" => obs[:task_type] || obs["task_type"] || "general",
      "at" => now_iso()
    }

    dir = Path.join(Store.dir(:evaluations), "observations")
    File.mkdir_p!(dir)
    Store.append_jsonl!(Path.join(dir, "#{safe(release_id)}.jsonl"), entry)

    Newbee.Bus.emit(:release_observation, entry)

    # TCE [F2]: 同一事件双投影（总纲 F 节）
    try do
      stats_map = Newbee.Environment.PatternStore.restore()
      key = {{:tool_use, entry["task_type"]}, entry["task_type"]}
      cur = Map.get(stats_map, key, Newbee.Environment.PatternStats.new())

      updated =
        Newbee.Environment.PatternStats.observe(cur, %{
          success: entry["success"],
          saved_tokens: (entry["tokens"] || 0) * 1.0,
          count: 1
        })

      Newbee.Environment.PatternStore.persist(Map.put(stats_map, key, updated))
    rescue
      e -> Newbee.DebugLog.log(:event, "pattern projection failed: " <> Exception.message(e))
    end

    :ok
  end

  @doc "读取某 release 的全部 observation。"
  def observations(release_id) do
    Store.read_jsonl(Path.join(Store.dir(:evaluations), "observations/#{safe(release_id)}.jsonl"))
  end

  # ── fitness 投影 ──

  @doc """
  聚合 fitness：按 模型 × 任务类型 × 时间窗口 分桶。
  返回 %{bucket_key => %{samples, success_rate, avg_latency_ms, avg_tokens, avg_output_bytes}}。
  bucket_key = {model, task_type, window_start_date}。
  """
  def fitness(release_id, opts \\ []) do
    window_days = Keyword.get(opts, :window_days, @window_days)

    release_id
    |> observations()
    |> Enum.group_by(fn obs ->
      {obs["model"], obs["task_type"], window_of(obs["at"], window_days)}
    end)
    |> Map.new(fn {key, group} ->
      n = length(group)

      {key,
       %{
         samples: n,
         success_rate: Enum.count(group, & &1["success"]) / max(n, 1),
         avg_latency_ms: avg(group, "latency_ms"),
         avg_tokens: avg(group, "tokens"),
         avg_output_bytes: avg(group, "output_bytes")
       }}
    end)
  end

  @doc "release 的总体 fitness（跨桶汇总）。"
  def overall(release_id) do
    obs = observations(release_id)
    n = length(obs)

    %{
      release_id: release_id,
      samples: n,
      success_rate: if(n > 0, do: Enum.count(obs, & &1["success"]) / n, else: nil),
      avg_latency_ms: avg(obs, "latency_ms"),
      avg_tokens: avg(obs, "tokens"),
      avg_output_bytes: avg(obs, "output_bytes")
    }
  end

  @doc """
  给投影的价签文本（一行）。样本不足的桶不展示（§3.3）。
  返回 nil（样本不足）或 "✓92% ·180ms ~340tok (n=12)"。
  """
  def price_tag(release_id, opts \\ []) do
    min = Keyword.get(opts, :min_samples, @min_samples)
    o = overall(release_id)

    if o.samples >= min do
      rate = round(o.success_rate * 100)
      "✓#{rate}% ·#{round(o.avg_latency_ms)}ms ~#{round(o.avg_tokens)}tok (n=#{o.samples})"
    end
  end

  @doc "全部有观测的 release 的价签表（投影工具清单用）。"
  def price_tags(opts \\ []) do
    Store.dir(:evaluations)
    |> Path.join("observations/*.jsonl")
    |> Path.wildcard()
    |> Enum.map(&Path.basename(&1, ".jsonl"))
    |> Enum.flat_map(fn release_id ->
      case price_tag(release_id, opts) do
        nil -> []
        tag -> [{release_id, tag}]
      end
    end)
    |> Map.new()
  end

  @doc """
  价签收敛检查（§15.16）：滑动窗口内 预测均值 vs 最近实测均值 的偏差。
  返回 %{converged?, deviation, window_samples}。
  """
  def convergence(release_id, opts \\ []) do
    window_days = Keyword.get(opts, :window_days, @window_days)
    threshold = Keyword.get(opts, :deviation_threshold, @deviation_threshold)

    obs =
      release_id
      |> observations()
      |> Enum.filter(fn o -> within_days?(o["at"], window_days) end)

    n = length(obs)

    if n < @min_samples do
      %{converged?: false, deviation: nil, window_samples: n}
    else
      half = div(n, 2)
      older = Enum.take(obs, half)
      recent = Enum.take(obs, -(n - half))

      older_rate = Enum.count(older, & &1["success"]) / max(length(older), 1)
      recent_rate = Enum.count(recent, & &1["success"]) / max(length(recent), 1)
      deviation = abs(recent_rate - older_rate)

      %{converged?: deviation <= threshold, deviation: deviation, window_samples: n}
    end
  end

  # ── helpers ──

  defp window_of(iso, window_days) do
    case DateTime.from_iso8601(iso || "") do
      {:ok, dt, _} ->
        days = div(DateTime.to_unix(dt), 86_400)
        window_start = div(days, window_days) * window_days
        DateTime.from_unix!(window_start * 86_400) |> DateTime.to_date() |> Date.to_iso8601()

      _ ->
        "unknown"
    end
  end

  defp within_days?(iso, days) do
    case DateTime.from_iso8601(iso || "") do
      {:ok, dt, _} -> System.system_time(:second) - DateTime.to_unix(dt) <= days * 86_400
      _ -> false
    end
  end

  defp avg([], _field), do: 0.0

  defp avg(group, field) do
    Enum.reduce(group, 0, fn o, acc -> acc + (o[field] || 0) end) / length(group)
  end

  defp truthy(v), do: v in [true, "true", 1]

  defp safe(id), do: id |> to_string() |> String.replace(~r/[^\w\.\-\@]/, "_")

  defp now_iso, do: DateTime.utc_now() |> DateTime.to_iso8601()

  def min_samples, do: @min_samples
end
