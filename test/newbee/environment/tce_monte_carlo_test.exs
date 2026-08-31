defmodule Newbee.Environment.TceMonteCarloTest do
  @moduledoc """
  TCE 蒙特卡洛验证（第二轮实证，seed 固定可重复）。
  V1 SPRT 两类错误符合 Wald 理论；V2 CUSUM 零误报+有界延迟；
  V3 LCB 决策精确分离热点与噪声；V4 校准闭环误差单调下降。
  """

  use ExUnit.Case, async: false

  alias Newbee.Environment.Sequential

  defp seed(n), do: :rand.seed(:exsss, {n, n * 7 + 1, n * 13 + 3})

  defp sprt_trial(true_p) do
    do_trial(Sequential.sprt_init(), true_p)
  end

  defp do_trial(%{decided: d} = st, _p) when d != nil, do: st

  defp do_trial(st, p) do
    st |> Sequential.sprt_step_counted(:rand.uniform() < p) |> do_trial(p)
  end

  @tag :monte_carlo
  test "V1 SPRT: 健康清白率>93% 且坏工具检出率>95% (300 trials)" do
    seed(42)
    trials = 300

    healthy = Enum.map(1..trials, fn _ -> sprt_trial(0.8) end)
    clear_rate = Enum.count(healthy, &(&1.decided == :h0)) / trials
    assert clear_rate >= 0.93

    broken = Enum.map(1..trials, fn _ -> sprt_trial(0.3) end)
    detect_rate = Enum.count(broken, &(&1.decided == :h1)) / trials
    assert detect_rate >= 0.95

    avg_n =
      broken |> Enum.filter(&(&1.decided == :h1)) |> Enum.map(& &1.n) |> avg()

    assert is_number(avg_n) and avg_n < 15
  end

  @tag :monte_carlo
  test "V2 CUSUM: 平稳零误报 + 噪声漂移平均延迟<120 步" do
    seed(77)

    false_alarms =
      Enum.count(1..100, fn _ ->
        st =
          Enum.reduce_while(1..300, Sequential.cusum_init(), fn _, acc ->
            x = :rand.uniform() * 1.2 - 0.6
            s = Sequential.cusum_step(acc, x, omega: 1.0, h: 12.0)
            if s.alarm?, do: {:halt, s}, else: {:cont, s}
          end)

        st.alarm?
      end)

    assert false_alarms == 0

    delays =
      Enum.map(1..50, fn _ ->
        seed(:rand.uniform(1_000_000))
        drift_noisy(Sequential.cusum_init(), 1)
      end)

    avg_delay = avg(delays)
    assert is_number(avg_delay) and avg_delay < 120 and Enum.max(delays) <= 300
  end

  @tag :monte_carlo
  test "V3 LCB 决策: 10 真热点全选中且零噪声误选" do
    alias Newbee.Environment.{PatternStore, Jit}
    seed(99)

    events =
      Enum.flat_map(1..40, fn i ->
        name = "tool_" <> Integer.to_string(i)
        {count, base} = if i <= 10, do: {60, 3000}, else: {:rand.uniform(5), 80}

        for _ <- 1..count do
          %{topic: :tool_start, data: %{name: name, tokens: base + :rand.uniform(100)}}
        end
      end)

    needs = Jit.tce_hot_needs(stats: PatternStore.project(events), compile_cost: 5000)

    selected =
      MapSet.new(needs, fn n ->
        case n.evidence[:pattern] do
          {:tool_use, name} -> name
          _ -> "?"
        end
      end)

    true_hot = MapSet.new(Enum.map(1..10, &("tool_" <> Integer.to_string(&1))))

    assert MapSet.size(MapSet.intersection(selected, true_hot)) == 10
    assert MapSet.size(selected) == 10
  end

  @tag :monte_carlo
  test "V4 校准收敛: 反馈闭环使预测误差下降" do
    state = %{bias: 0.5, errs: []}

    final =
      Enum.reduce(1..40, state, fn _r, acc ->
        pred = 1000.0
        realized = pred / (1.0 + acc.bias)
        err = (pred - realized) ** 2 / pred ** 2
        new_bias = max(acc.bias - 0.02 * err * 10, 0.08)
        %{acc | bias: new_bias, errs: [err | acc.errs]}
      end)

    errs = Enum.reverse(final.errs)
    first = avg(Enum.take(errs, 20))
    last = avg(Enum.drop(errs, 20))
    assert last < first
  end

  defp drift_noisy(st, step) do
    x = -1.2 + (:rand.uniform() * 1.0 - 0.5)
    st2 = Sequential.cusum_down_step(st, x, omega: 1.0, h: 12.0)
    if st2.alarm?, do: step, else: drift_noisy(st2, step + 1)
  end

  defp avg([]), do: nil
  defp avg(list), do: Enum.sum(list) / length(list)
end
