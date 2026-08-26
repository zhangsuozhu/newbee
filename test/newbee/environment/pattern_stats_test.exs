defmodule Newbee.Environment.PatternStatsTest do
  use ExUnit.Case, async: true

  alias Newbee.Environment.PatternStats, as: PS

  @tag :pattern_stats
  test "log_gamma 对照已知值" do
    assert_in_delta PS.log_gamma(1.0), 0.0, 1.0e-9
    assert_in_delta PS.log_gamma(5.0), :math.log(24), 1.0e-9
    assert_in_delta PS.log_gamma(0.5), 0.5 * :math.log(:math.pi()), 1.0e-9
  end

  @tag :pattern_stats
  test "digamma/trigamma 对照已知值" do
    assert_in_delta PS.digamma(1.0), -0.577_215_6649, 1.0e-8
    assert_in_delta PS.trigamma(1.0), :math.pi() * :math.pi() / 6.0, 1.0e-8
    # 递推性 ψ(x+1) = ψ(x) + 1/x
    steps = [4.3, 5.3, 6.3, 7.3, 8.3, 9.3]
    assert_in_delta PS.digamma(10.3), PS.digamma(4.3) + Enum.sum(Enum.map(steps, fn x -> 1 / x end)), 1.0e-6
  end

  @tag :pattern_stats
  test "betai 基本性质：均匀分布、对称、单调" do
    assert_in_delta PS.betai(0.3, 1.0, 1.0), 0.3, 1.0e-9
    assert_in_delta PS.betai(0.5, 2.0, 2.0), 0.5, 1.0e-9
    assert PS.betai(0.2, 2.0, 5.0) < PS.betai(0.4, 2.0, 5.0)
    assert_in_delta PS.betai(0.7, 3.0, 4.0) + PS.betai(0.3, 4.0, 3.0), 1.0, 1.0e-6
  end

  @tag :pattern_stats
  test "gammainc_p 对照解析值 P(a,x)" do
    assert_in_delta PS.gammainc_p(1.0, 1.0), 1 - :math.exp(-1), 1.0e-9
    assert_in_delta PS.gammainc_p(2.0, 2.0), 1 - 3 * :math.exp(-2), 1.0e-9
    assert_in_delta PS.gammainc_p(0.5, 5.0), :math.erf(:math.sqrt(5)), 1.0e-6
    assert_in_delta PS.gammainc_p(1.0, 0.01), 0.00995, 1.0e-4
  end

  @tag :pattern_stats
  test "observe 更新三组后验" do
    s =
      PS.new()
      |> PS.observe(%{success: true, saved_tokens: 100.0})
      |> PS.observe(%{success: false, saved_tokens: 200.0})

    assert s.n == 2
    assert_in_delta PS.freq_mean(s), 3.0, 1.0e-9
    assert_in_delta PS.succ_mean(s), 2.0 / 4.0, 1.0e-9
    assert_in_delta PS.save_mean(s), 150.0, 1.0e-9
  end

  @tag :pattern_stats
  test "decay 保均值、增方差（有效样本量衰减）[D6]" do
    s = PS.new() |> PS.observe(%{count: 100})
    d = PS.decay(s, 0.5)
    assert_in_delta PS.freq_mean(d), PS.freq_mean(s), PS.freq_mean(s) * 1.0e-9
    assert PS.gamma_var(d.freq) > PS.gamma_var(s.freq)
    assert d.n == 50
  end

  @tag :pattern_stats
  test "net_lcb 与 compile_worthy? 判据方向正确 [D14]" do
    hot = PS.new() |> PS.observe(%{count: 30, saved_tokens: 2000.0})
    cold = PS.new()
    assert PS.net_lcb(hot, 5000.0) > 0
    refute PS.compile_worthy?(cold, 5000.0)
    # κ 越大 LCB 越低（风险厌恶惩罚）
    assert PS.net_lcb(hot, 5000.0, kappa: 5.0) < PS.net_lcb(hot, 5000.0, kappa: 0.1)
  end

  @tag :pattern_stats
  test "deopt 双通道分离工具坏与漂移 [D17]" do
    broken =
      1..20
      |> Enum.reduce(PS.new(freq: {10.0, 1.0}), fn i, acc ->
        PS.observe(acc, %{success: rem(i, 10) == 0})
      end)

    assert {:tool_broken, _} = PS.deopt_decision(broken)

    drift =
      PS.new()
      |> Map.put(:snapshot, %{a: 50.0, b: 1.0})
      |> PS.observe(%{count: 1})

    assert {:drifted, _} = PS.deopt_decision(drift)

    healthy = PS.new() |> PS.observe(%{success: true}) |> PS.observe(%{success: true})
    assert PS.deopt_decision(healthy) == :keep
  end

  @tag :pattern_stats
  test "take_snapshot 记录预测供校准 [D8][D11]" do
    s = PS.new() |> PS.observe(%{count: 5, saved_tokens: 300.0}) |> PS.take_snapshot()
    assert s.snapshot.predicted_save_mean == 300.0
    assert s.snapshot.a == elem(s.freq, 0)
  end

  @tag :pattern_stats
  test "eb_shrink 小样本向群体收缩，群体小时不动 [D12]" do
    group = for _ <- 1..10, do: PS.new(freq: {50.0, 1.0}) |> PS.observe(%{count: 0})
    individual = PS.new(freq: {2.0, 1.0})
    shrunk = PS.eb_shrink(group, individual, 0.5)
    assert PS.freq_mean(shrunk) > PS.freq_mean(individual)
    assert PS.eb_shrink(Enum.take(group, 3), individual, 0.5) == individual
  end
end
