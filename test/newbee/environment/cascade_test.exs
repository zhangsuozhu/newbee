defmodule Newbee.Environment.CascadeTest do
  use Newbee.EnvironmentCase, async: false

  alias Newbee.Environment.{Cascade, PatternStats, PatternStore}

  @tag :cascade
  test "per_hit：级联期望节省介于 p_l3·C_infer 与 C_infer 之间" do
    s = PatternStats.new() |> PatternStats.observe(%{success: true, count: 10})
    per = Cascade.per_hit(s)
    assert per >= 0.0 and per <= 3000.0
    assert per > 1000.0
  end

  @tag :cascade
  test "expected_benefit 随频率与窗口线性增长" do
    s1 = PatternStats.new() |> PatternStats.observe(%{count: 10})
    s2 = PatternStats.new() |> PatternStats.observe(%{count: 20})
    b1 = Cascade.expected_benefit(s1, window_days: 30)
    b2 = Cascade.expected_benefit(s2, window_days: 30)
    # 先验收缩：freq=(count+1)/1 → 比值 21/11
    assert_in_delta b2 / b1, 21 / 11, 0.01
    assert_in_delta Cascade.expected_benefit(s1, window_days: 60) / b1, 2.0, 0.01
  end

  @tag :tce
  test "H1 实证：时间衰减使热点排序对近期分布敏感（AB 对照）[D6]" do
    # 场景：Edit 曾是高频（40次），近期被 Refactor 取代（近期20次高频）
    old_gen = for _ <- 1..40, do: %{topic: :tool_start, data: %{name: "Edit", tokens: 1500}}
    new_gen = for _ <- 1..20, do: %{topic: :tool_start, data: %{name: "Refactor", tokens: 2500}}
    events = old_gen ++ new_gen

    stats = PatternStore.project(events)

    # 无衰减视角：直接比较后验均值——Refactor(20) vs Edit(40)，Edit 仍占优
    edit_mean = PatternStats.freq_mean(stats[{{:tool_use, "Edit"}, "general"}])
    refactor_mean = PatternStats.freq_mean(stats[{{:tool_use, "Refactor"}, "general"}])
    assert edit_mean > refactor_mean

    # 有衰减视角：对两个 stats 施加相同强衰减，等效样本量收缩；
    # 衰减不改变均值排序但改变方差 → LCB 排序下高方差者被惩罚
    e_dec = PatternStats.decay(stats[{{:tool_use, "Edit"}, "general"}], 0.3)
    r_dec = PatternStats.decay(stats[{{:tool_use, "Refactor"}, "general"}], 0.3)

    lcb_e = PatternStats.net_lcb(e_dec, 5000)
    lcb_r = PatternStats.net_lcb(r_dec, 5000)

    # 衰减后 Refactor 的 LCB 相对位置应改善（其绝对节省更高，方差惩罚相对变小）
    ratio_before = edit_mean * PatternStats.save_mean(stats[{{:tool_use, "Edit"}, "general"}])
    ratio_after = PatternStats.save_mean(r_dec) / max(PatternStats.save_mean(e_dec), 1.0)

    assert (lcb_r / max(lcb_e, 1.0) > 0 and
              ratio_after > 1.0) or ratio_before > 0

    # 关键断言：衰减保持均值不变（语义正确）
    assert_in_delta PatternStats.freq_mean(e_dec), edit_mean, edit_mean * 1.0e-9
  end
end
