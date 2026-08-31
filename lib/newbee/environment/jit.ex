defmodule Newbee.Environment.Jit do
  @moduledoc """
  认知 JIT（DESIGN §8.5）：环境是 JIT 编译器——持续把"需要模型推理的智能"
  编译成"不需要推理的确定性产物"。

  ```text
  L1 教训       kind: prompt release（读到要花 token 推理）
  L2 沉睡规则   kind: rule release（平时零成本，触发才注入）
  L3 蒸馏工具   kind: tool release（纯函数+测试，调用零 token）
  ```

  三个机制的运行时落位：

  - **热度剖析**：事件流统计 模式频率 × 单次 token 成本 = **编译收益**；
    越过阈值（收益 > 编译成本）才作为高优 need 进 adapter 队列——
    不热的模式永不编译，避免过度工程。价签数据让阈值计算越用越准。
  - **编译（compile）**：adapter 执行晋升——同 plugin release 演进或派生新
    plugin，走标准 Change 生命周期（小补丁纪律，§3.4）。
  - **去优化（deopt）**：L3 工具判退化时降级回上级形态 release 而非删除——
    知识不丢，条件合适重新编译。

  本模块是纯策略：识别热点、判定晋升/降级路径；执行走 Coordinator。
  """

  # 默认阈值：编译收益（token）> 编译成本（token）才晋升（§16 校准项）
  @default_compile_cost 100_000
  # deopt：L3 工具成功率跌破阈值且样本足够 → 降级
  @deopt_success_rate 0.5
  @deopt_min_samples 5

  defstruct patterns: %{}

  @doc "pattern 键：从事件提取可归因的重复模式标识（工具调用名 / 错误类别 / 任务类型）。"
  def pattern_key(%{topic: :tool_start, data: %{name: name}}), do: {:tool_use, to_string(name)}
  def pattern_key(%{"topic" => "tool_start", "data" => %{"name" => name}}), do: {:tool_use, to_string(name)}
  def pattern_key(%{topic: :tool_error, data: %{error_class: cls}}), do: {:error, to_string(cls)}
  def pattern_key(%{"topic" => "tool_error", "data" => %{"error_class" => cls}}), do: {:error, to_string(cls)}
  def pattern_key(%{topic: :prompt_injection, data: data}), do: prompt_injection_key(data)
  def pattern_key(%{"topic" => "prompt_injection", "data" => data}), do: prompt_injection_key(data)
  def pattern_key(_), do: nil

  @doc """
  热度剖析：从事件流统计每个模式的 频率 × 单次 token 成本 = 编译收益。
  events 为事件流（map 列表，含 topic/data/tokens）。
  返回 [%{pattern, count, token_cost, compile_benefit, hot?}]，按收益降序。
  """
  def profile(events, opts \\ []) do
    base_cost = Keyword.get(opts, :compile_cost, @default_compile_cost)
    # 偏差驱动成本上调 [D18]：校准差 → 更保守的编译门槛
    compile_cost =
      case Keyword.fetch(opts, :stats) do
        {:ok, _} -> base_cost
        :error -> Newbee.Environment.Calibration.adjust_compile_cost(base_cost)
      end

    events
    |> Enum.reduce(%{}, fn ev, acc ->
      case pattern_key(ev) do
        nil ->
          acc

        key ->
          tokens = ev[:tokens] || ev["tokens"] || estimate_tokens(ev)
          Map.update(acc, key, {1, tokens}, fn {n, t} -> {n + 1, t + tokens} end)
      end
    end)
    |> Enum.map(fn {pattern, {count, tokens}} ->
      benefit = count * max(div(tokens, max(count, 1)), 1)

      %{
        pattern: pattern,
        count: count,
        token_cost: tokens,
        compile_benefit: benefit,
        hot?: benefit > compile_cost
      }
    end)
    |> Enum.sort_by(&(-&1.compile_benefit))
  end

  @doc """
  热度阈值判定：越过阈值的模式作为高优 need 进 adapter 队列（§8.5）。
  返回 [%{capability, evidence, urgency: :high}]（need 消息载荷雏形）。
  """
  def hot_needs(events, opts \\ []) do
    events
    |> profile(opts)
    |> Enum.filter(& &1.hot?)
    |> Enum.map(fn p ->
      %{
        capability: capability_for(p.pattern),
        evidence: %{pattern: p.pattern, count: p.count, compile_benefit: p.compile_benefit},
        urgency: :high
      }
    end)
  end

  defp prompt_injection_key(data) do
    details =
      case data do
        %{"payload" => ["prompt_injection", details]} when is_map(details) -> details
        %{payload: [:prompt_injection, details]} when is_map(details) -> details
        details when is_map(details) -> details
        _ -> %{}
      end

    rule_ids =
      (details["rules"] || details[:rules] || [])
      |> Enum.map(&(&1["id"] || &1[:id]))
      |> Enum.reject(&is_nil/1)
      |> Enum.sort()

    key =
      case rule_ids do
        [] -> details["source"] || details[:source] || "unknown"
        ids -> Enum.join(ids, ",")
      end

    {:prompt_injection, key}
  end

  defp capability_for({:prompt_injection, key}), do: "optimize prompt injection #{key}"
  defp capability_for(pattern), do: "distill #{inspect(pattern)}"

  # ── 晋升/降级路径 ──

  @doc "L1 → L2：教训（prompt release）固化为沉睡规则（rule release）。"
  def promote_l1_to_l2(lesson, pattern, injection, opts \\ []) do
    %{
      plugin_id: Keyword.get(opts, :plugin_id, "rule." <> slug(lesson)),
      kind: :rule,
      derived_from: :l1_prompt,
      spec: %{pattern: pattern, injection: injection, scope: Keyword.get(opts, :scope, :all)},
      reason: "JIT L1→L2: #{lesson}"
    }
  end

  @doc "L2 → L3：沉睡规则/playbook 蒸馏为纯函数工具（带测试）。"
  def promote_l2_to_l3(name, source, test_source, opts \\ []) do
    %{
      plugin_id: Keyword.get(opts, :plugin_id, "tool." <> slug(name)),
      kind: :tool,
      derived_from: :l2_rule,
      source_files: %{"#{slug(name)}.ex" => source, "#{slug(name)}_test.exs" => test_source},
      reason: "JIT L2→L3: #{name}"
    }
  end

  @doc """
  deopt 判定：L3 工具判退化 → 降级回上级形态（L2 rule / L1 prompt）release。
  返回 {:deopt, target_form, reason} | :keep。
  """
  def deopt_decision(release_id, _opts \\ []) do
    f = Newbee.Environment.Fitness.overall(release_id)

    if f.samples >= @deopt_min_samples and (f.success_rate || 1.0) < @deopt_success_rate do
      {:deopt, :l2_rule,
       "success_rate #{Float.round((f.success_rate || 0.0) * 100, 1)}% < #{@deopt_success_rate * 100}% (n=#{f.samples})"}
    else
      :keep
    end
  end

  @doc "deopt 阈值（配置项暴露，§16 校准）。"
  def deopt_thresholds, do: %{success_rate: @deopt_success_rate, min_samples: @deopt_min_samples}

  # ── helpers ──

  defp estimate_tokens(ev) do
    # 无显式 token 记账时按输出大小粗估（价签数据让估计越用越准）
    bytes = ev[:output_bytes] || ev["output_bytes"] || 0
    max(div(bytes, 4), 100)
  end

  defp slug(name) do
    name
    |> to_string()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "_")
    |> String.trim("_")
    |> String.slice(0, 40)
  end

  # ═══════════ TCE 分级编译经济学（总纲 B/C 节）═══════════

  alias Newbee.Environment.PatternStats

  @doc """
  TCE 热点：从 PatternStore 后验出发，按净收益 LCB 排序的编译候选（[D10][D14]）。

  返回与 hot_needs/2 兼容的形状（capability/evidence/urgency），另带
  lcb / stats 字段供 adapter 与校准投影使用。compile_cost 为该 pattern
  的编译成本估计（token），默认常量。
  """
  def tce_hot_needs(opts \\ []) do
    store = Keyword.get_lazy(opts, :stats, fn -> Newbee.Environment.PatternStore.restore() end)
    base_cost = Keyword.get(opts, :compile_cost, @default_compile_cost)
    # 偏差驱动成本上调 [D18]：校准差 → 更保守的编译门槛
    compile_cost =
      case Keyword.fetch(opts, :stats) do
        {:ok, _} -> base_cost
        :error -> Newbee.Environment.Calibration.adjust_compile_cost(base_cost)
      end

    kappa = Keyword.get(opts, :kappa, 1.0)
    min_samples = Keyword.get(opts, :min_samples, 3)

    store
    |> Enum.map(fn {key, %PatternStats{} = s} ->
      lcb = PatternStats.net_lcb(s, compile_cost, kappa: kappa)

      %{
        key: key,
        stats: s,
        lcb: lcb,
        pattern: elem(key, 0),
        task_type: elem(key, 1),
        compile_benefit: trunc(PatternStats.freq_mean(s) * max(PatternStats.save_mean(s), 0.0)),
        count: s.n,
        token_cost: trunc(PatternStats.save_mean(s))
      }
    end)
    |> Enum.filter(&(&1.count >= min_samples and &1.lcb > 0.0))
    |> Enum.sort_by(&(-&1.lcb))
    |> Enum.map(fn c ->
      %{
        capability: capability_for(c.pattern),
        evidence: %{
          pattern: c.pattern,
          task_type: c.task_type,
          count: c.count,
          compile_benefit: c.compile_benefit,
          lcb: Float.round(c.lcb, 2),
          freq_mean: Float.round(PatternStats.freq_mean(c.stats), 4),
          succ_mean: Float.round(PatternStats.succ_mean(c.stats), 4)
        },
        urgency: :high,
        lcb: c.lcb,
        stats: c.stats
      }
    end)
  end

  @doc "TCE deopt：对给定 release/pattern 的 stats 做双通道判定 [D17]。"
  def tce_deopt_decision(stats_or_key, opts \\ [])

  def tce_deopt_decision(%PatternStats{} = s, opts) do
    PatternStats.deopt_decision(s, opts)
  end

  def tce_deopt_decision(key, opts) when is_tuple(key) do
    store = Keyword.get_lazy(opts, :stats, fn -> Newbee.Environment.PatternStore.restore() end)

    case Map.get(store, key) do
      nil -> :keep
      s -> PatternStats.deopt_decision(s, opts)
    end
  end

  @doc "TCE deopt v2 [U1]：后验判据 + SPRT 序贯证据合流。"
  def tce_deopt_decision_v2(%PatternStats{} = s, opts \\ []) do
    case PatternStats.deopt_decision(s, opts) do
      :keep ->
        # 后验不够强时用 SPRT 的序贯证据补充判定：
        # 用 succ 后验均值作为当前成功率的点估计，模拟一次 SPRT 快照判定
        {al, be} = s.succ
        mean_p = al / (al + be)
        p_ok = Keyword.get(opts, :p_ok, 0.8)
        p_bad = Keyword.get(opts, :p_bad, 0.3)

        cond do
          al + be >= 8 and mean_p < p_bad ->
            {:tool_broken, "posterior mean below p_bad with sufficient evidence"}

          al + be >= 8 and betai_ge?(mean_p, p_ok) ->
            :keep

          true ->
            :keep
        end

      other ->
        other
    end
  end

  defp betai_ge?(p, q), do: p >= q
end
