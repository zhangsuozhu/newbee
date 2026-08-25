defmodule Newbee.Environment.SequentialTest do
  use ExUnit.Case, async: true

  alias Newbee.Environment.{Sequential, PatternStats, PatternStore}

  @tag :sequential
  test "SPRT: 持续失败序列在 O(log) 样本内判 H1（工具坏）" do
    st =
      Enum.reduce(1..30, Sequential.sprt_init(), fn _, acc ->
        Sequential.sprt_step_counted(acc, false)
      end)

    assert st.decided == :h1
    # Wald 最优性: alpha=beta=0.05 时约 10-15 个样本应决定
    assert st.n < 20
  end

  @tag :sequential
  test "SPRT: 健康工具(80%成功)最终判 H0 清白" do
    # 确定性伪随机: 80% 成功模式
    outcomes = Stream.cycle([true, true, true, true, false])
    st =
      outcomes
      |> Enum.take(40)
      |> Enum.reduce(Sequential.sprt_init(), fn ok, acc ->
        case acc.decided do
          nil -> Sequential.sprt_step_counted(acc, ok)
          _ -> acc
        end
      end)

    assert st.decided == :h0
  end

  @tag :sequential
  test "SPRT: decided 后冻结不再变化" do
    st = Enum.reduce(1..30, Sequential.sprt_init(), fn _, a -> Sequential.sprt_step(a, false) end)
    frozen = Sequential.sprt_step(st, true)
    assert frozen.s == st.s and frozen.decided == st.decided
  end

  @tag :sequential
  test "CUSUM: 缓慢下漂被检测，平稳序列不误报" do
    # 平稳: x 在 0 附近抖动，omega=0.5 吸收
    steady = Enum.reduce(1..200, Sequential.cusum_init(), fn i, acc ->
      x = if rem(i, 2) == 0, do: 0.4, else: -0.4
      Sequential.cusum_step(acc, x, omega: 0.5, h: 4.0)
    end)
    refute steady.alarm?

    # 缓慢漂移: 每 step -0.3 偏移
    drift = Enum.reduce(1..60, Sequential.cusum_init(), fn _, acc ->
      Sequential.cusum_down_step(acc, -0.8, omega: 0.5, h: 4.0)
    end)
    assert drift.alarm?
    # 首次报警应在 ~14 步内 (S 累积 0.3/步 越过 h=4)
  end

  @tag :sequential
  test "standardized_offset: 观测等于期望时偏移为负小值（先验主导）" do
    off = Sequential.standardized_offset({50.0, 1.0}, 48)
    assert off < 0.5 and off > -2.0
  end

  @tag :tce_v2
  @tag :tce_v2
  test "net_asym: 非对称区间更保守，成本端 UCB 随样本收缩 [U3]" do
    s = PatternStats.new() |> PatternStats.observe(%{count: 20, saved_tokens: 1500.0})
    assert PatternStats.net_asym(s, 5000) <= PatternStats.net_lcb(s, 5000)

    # 成本端: n=400 时 c_ucb 仅放大 4.1%；n=4 时放大 41%
    big = PatternStats.new() |> PatternStats.observe(%{count: 400, saved_tokens: 1500.0})
    tiny = PatternStats.new() |> PatternStats.observe(%{count: 4, saved_tokens: 1500.0})

    gap_big = PatternStats.net_lcb(big, 5000) - PatternStats.net_asym(big, 5000, z: 1.0)
    gap_tiny = PatternStats.net_lcb(tiny, 5000) - PatternStats.net_asym(tiny, 5000)

    # 大样本时两式差异主要来自成本端（125 = 5000*0.5*1.645/20 的量级）
    # 大样本时 b 端对称、差异主要来自成本端 UCB
    assert_in_delta gap_big, 5000 * (1.645 * 0.5 / :math.sqrt(400)), 500.0
    # 小样本差异更大
    assert gap_tiny > gap_big
  end

  @tag :tce_v2
  test "beta_quantile bisection: 中位数与均值关系、单调性 [U-数值]" do
    q50 = PatternStats.beta_quantile(0.5, {3.0, 5.0})
    # 右偏分布中位数 < 均值 3/8=0.375
    assert q50 < 0.375
    q25 = PatternStats.beta_quantile(0.25, {3.0, 5.0})
    q75 = PatternStats.beta_quantile(0.75, {3.0, 5.0})
    assert q25 < q50 and q50 < q75
    # 自洽性: betai(q50) 约 0.5
    assert_in_delta PatternStats.betai(q50, 3.0, 5.0), 0.5, 1.0e-6
  end

  @tag :tce_v2
  test "集成: SPRT 判定接入 deopt 流程语义（与旧判据一致性方向）" do
    # 90% 失败的工具：SPRT 应快速判坏
    outcomes = for i <- 1..40, do: rem(i, 10) == 0
    final =
      Enum.reduce(outcomes, Sequential.sprt_init(), fn ok, acc ->
        case acc.decided do
          nil -> Sequential.sprt_step_counted(acc, ok)
          _ -> acc
        end
      end)

    assert final.decided == :h1
    # 对比: PatternStats.tool_broken? 也判坏（方向一致）
    s =
      outcomes
      |> Enum.reduce(PatternStore.project([]) |> Map.get(:x, PatternStats.new()), fn ok, acc ->
        PatternStats.observe(acc, %{success: ok})
      end)

    assert PatternStats.tool_broken?(s, 0.5, 0.95)
  end
end
