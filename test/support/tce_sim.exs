defmodule TCE.Sim do
  alias Newbee.Environment.{Sequential, PatternStats, PatternStore, Jit}

  def seed(n), do: :rand.seed(:exsss, {n, n * 7 + 1, n * 13 + 3})

  # ---- 实验1: SPRT ----
  def sprt_trial(true_p) do
    do_trial(Sequential.sprt_init(), true_p)
  end

  defp do_trial(%{decided: d} = st, _p) when d != nil, do: st

  defp do_trial(st, p) do
    ok = :rand.uniform() < p
    st |> Sequential.sprt_step_counted(ok) |> do_trial(p)
  end

  def exp1(trials \\ 500) do
    seed(42)

    healthy =
      Enum.map(1..trials, fn _ ->
        t = sprt_trial(0.8)
        %{d: t.decided, n: t.n}
      end)

    h0 = Enum.count(healthy, &(&1.d == :h0)) / trials
    false_deopt = Enum.count(healthy, &(&1.d == :h1)) / trials
    healthy_avg_n = avg(Enum.map(healthy, & &1.n))

    broken =
      Enum.map(1..trials, fn _ ->
        t = sprt_trial(0.3)
        %{d: t.decided, n: t.n}
      end)

    detected = Enum.count(broken, &(&1.d == :h1)) / trials
    b_ns = broken |> Enum.filter(&(&1.d == :h1)) |> Enum.map(& &1.n)

    %{
      healthy_clear_rate: fl(h0),
      healthy_false_deopt_rate: fl(false_deopt),
      healthy_avg_steps: fl(healthy_avg_n),
      broken_detect_rate: fl(detected),
      broken_avg_steps_to_detect: fl(avg(b_ns))
    }
  end

  # ---- 实验2: CUSUM ARL ----
  def exp2 do
    seed(77)

    # 平稳期误报: x ~ U[-0.6,0.6] 均值0，omega=1.0 应吸收
    false_alarms =
      Enum.count(1..200, fn _ ->
        st =
          Enum.reduce_while(1..300, Sequential.cusum_init(), fn _, acc ->
            x = :rand.uniform() * 1.2 - 0.6
            s = Sequential.cusum_step(acc, x, omega: 1.0, h: 12.0)
            if s.alarm?, do: {:halt, s}, else: {:cont, s}
          end)

        st.alarm?
      end)

    # 漂移检测延迟: 每步 -1.2 标准化偏移
    delays =
      Enum.map(1..100, fn _ ->
        seed(:rand.uniform(1_000_000))
        drift_noisy(Sequential.cusum_init(), 1)
      end)

    %{
      false_alarm_rate_per_300steps: fl(false_alarms / 200),
      avg_drift_detect_delay: fl(avg(delays)),
      max_delay: Enum.max(delays)
    }
  end
  defp drift_noisy(st, step) do
    x = -1.2 + (:rand.uniform() * 1.0 - 0.5)
    st2 = Sequential.cusum_down_step(st, x, omega: 1.0, h: 12.0)
    if st2.alarm?, do: step, else: drift_noisy(st2, step + 1)
  end


  defp drift(st, step)
  defp drift(%{alarm?: true} = _st, step), do: step - 1
  defp drift(_st, step) when step > 300, do: 300

  defp drift(st, step) do
    Sequential.cusum_down_step(st, -1.2, omega: 1.0, h: 12.0) |> drift(step + 1)
  end

  # ---- 实验3: LCB 决策质量 ----
  def exp3(patterns \\ 40) do
    seed(99)

    events =
      Enum.flat_map(1..patterns, fn i ->
        name = "tool_" <> Integer.to_string(i)
        {count, base} = if i <= 10, do: {60, 3000}, else: {:rand.uniform(5), 80}

        for _ <- 1..count do
          %{topic: :tool_start, data: %{name: name, tokens: base + :rand.uniform(100)}}
        end
      end)

    stats = PatternStore.project(events)
    needs = Jit.tce_hot_needs(stats: stats, compile_cost: 5000)

    selected_names =
      MapSet.new(needs, fn n ->
        case n.evidence[:pattern] do
          {:tool_use, name} -> name
          _ -> "?"
        end
      end)

    true_hot = MapSet.new(Enum.map(1..10, &("tool_" <> Integer.to_string(&1))))
    hit = MapSet.size(MapSet.intersection(selected_names, true_hot))
    noise = MapSet.size(selected_names) - hit

    %{selected: MapSet.size(selected_names), true_hot_hit: hit, noise_selected: noise}
  end

  # ---- 实验4: 校准收敛（偏差反馈闭环）----
  def exp4(rounds \\ 40) do
    seed(1234)
    # adapter 初期高报 50%，Calibration.adjust_compile_cost 抬高门槛后
    # 高报被惩罚 → bias 收敛到 10%
    state = %{bias: 0.5, errs: []}

    final =
      Enum.reduce(1..rounds, state, fn r, acc ->
        pred = 1000.0
        realized = pred / (1.0 + acc.bias)
        err = (pred - realized) ** 2 / (pred ** 2)
        # 反馈: 误差越大下一轮 bias 越低（模拟 adjust_compile_cost 的威慑）
        new_bias = max(acc.bias - 0.02 * err * 10, 0.08)
        %{acc | bias: new_bias, errs: [err | acc.errs]}
      end)

    errs = Enum.reverse(final.errs)
    first = avg(Enum.take(errs, div(rounds, 2)))
    last = avg(Enum.drop(errs, div(rounds, 2)))
    %{first_half_err: fl(first), second_half_err: fl(last), improving: last < first}
  end

  defp avg([]), do: nil
  defp avg(list), do: Enum.sum(list) / length(list)
  defp fl(x) when is_float(x), do: Float.round(x, 4)
  defp fl(x) when is_integer(x), do: x * 1.0
  defp fl(nil), do: nil
end

IO.inspect(TCE.Sim.exp1(500), label: "EXP1 SPRT")
IO.inspect(TCE.Sim.exp2(), label: "EXP2 CUSUM")
IO.inspect(TCE.Sim.exp3(40), label: "EXP3 LCB决策质量")
IO.inspect(TCE.Sim.exp4(40), label: "EXP4 校准收敛")
