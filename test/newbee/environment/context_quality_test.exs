defmodule Newbee.Environment.ContextQualityTest do
  use ExUnit.Case, async: true
  alias Newbee.Environment.ContextQuality, as: CQ

  describe "prob_less/2 统计正确性" do
    test "相同分布 P(X<Y) ≈ 0.5" do
      assert_in_delta CQ.prob_less({5.0, 5.0}, {5.0, 5.0}), 0.5, 0.02
    end

    test "明显更差 P(X<Y) 接近 1" do
      assert CQ.prob_less({2.0, 8.0}, {8.0, 2.0}) > 0.95
    end

    test "明显更好 P(X<Y) 接近 0" do
      assert CQ.prob_less({8.0, 2.0}, {2.0, 8.0}) < 0.05
    end

    test "对称性 P(X<Y)+P(Y<X) ≈ 1" do
      p1 = CQ.prob_less({3.0, 7.0}, {6.0, 4.0})
      p2 = CQ.prob_less({6.0, 4.0}, {3.0, 7.0})
      assert_in_delta p1 + p2, 1.0, 0.02
    end
  end

  describe "beta_quantile/3 分位数" do
    test "Beta(2,2) 中位数 ≈ 0.5" do
      assert_in_delta CQ.beta_quantile(2.0, 2.0, 0.5), 0.5, 0.01
    end

    test "Beta(8,2) 偏向 1，2.5% 分位数 > 0.5" do
      assert CQ.beta_quantile(8.0, 2.0, 0.025) > 0.5
    end

    test "单调性：分位数随 p 递增" do
      assert CQ.beta_quantile(5.0, 5.0, 0.9) > CQ.beta_quantile(5.0, 5.0, 0.1)
    end
  end

  describe "record/3 账本" do
    test "注入成功计 with α" do
      l = CQ.new_ledger() |> CQ.record(true, true)
      assert l.with_ctx == {2.0, 1.0} and l.n_with == 1
    end

    test "token 滑动平均" do
      l = CQ.new_ledger() |> CQ.record(true, true, 100) |> CQ.record(true, true, 200)
      assert_in_delta l.with_tokens, 150.0, 0.01
    end
  end

  describe "verdict/2 CI 不重叠判据" do
    test "样本不足 → insufficient" do
      l = CQ.new_ledger() |> CQ.record(true, false) |> CQ.record(false, true)
      assert CQ.verdict(l) == :insufficient
    end

    test "明确有害 → harmful" do
      l = CQ.new_ledger()
      l = Enum.reduce(1..18, l, fn _, a -> CQ.record(a, false, true) end)
      l = Enum.reduce(1..2, l, fn _, a -> CQ.record(a, false, false) end)
      l = Enum.reduce(1..4, l, fn _, a -> CQ.record(a, true, true) end)
      l = Enum.reduce(1..16, l, fn _, a -> CQ.record(a, true, false) end)
      assert CQ.verdict(l) == :harmful
    end

    test "明确有益 → ok" do
      l = CQ.new_ledger()
      l = Enum.reduce(1..4, l, fn _, a -> CQ.record(a, false, true) end)
      l = Enum.reduce(1..16, l, fn _, a -> CQ.record(a, false, false) end)
      l = Enum.reduce(1..18, l, fn _, a -> CQ.record(a, true, true) end)
      l = Enum.reduce(1..2, l, fn _, a -> CQ.record(a, true, false) end)
      assert CQ.verdict(l) == :ok
    end

    test "效果相当 → 不退休" do
      l = CQ.new_ledger()
      l = Enum.reduce(1..15, l, fn _, a -> CQ.record(a, false, true) end)
      l = Enum.reduce(1..5, l, fn _, a -> CQ.record(a, false, false) end)
      l = Enum.reduce(1..15, l, fn _, a -> CQ.record(a, true, true) end)
      l = Enum.reduce(1..5, l, fn _, a -> CQ.record(a, true, false) end)
      refute CQ.verdict(l) == :harmful
    end
  end

  describe "bloat_regression?/2" do
    test "token 涨成功率不升 → true" do
      l = CQ.new_ledger()
      l = Enum.reduce(1..8, l, fn _, a -> CQ.record(a, false, true, 100) end)
      l = Enum.reduce(1..2, l, fn _, a -> CQ.record(a, false, false, 100) end)
      l = Enum.reduce(1..8, l, fn _, a -> CQ.record(a, true, true, 250) end)
      l = Enum.reduce(1..2, l, fn _, a -> CQ.record(a, true, false, 250) end)
      assert CQ.bloat_regression?(l)
    end
  end

  describe "统计性质回归（Blind Curator 防线，蒙特卡洛锁定）" do
    test "中性经验假阳性率 < 5%" do
      :rand.seed(:exsss, {11, 22, 33})

      harmful =
        Enum.count(1..200, fn _ ->
          l =
            CQ.new_ledger()
            |> then(fn l -> Enum.reduce(1..20, l, fn _, a -> CQ.record(a, false, :rand.uniform() < 0.7) end) end)
            |> then(fn l -> Enum.reduce(1..20, l, fn _, a -> CQ.record(a, true, :rand.uniform() < 0.7) end) end)

          CQ.verdict(l) == :harmful
        end)

      assert harmful / 200 < 0.05
    end

    test "明显有害检出率 > 30%（功效下界）" do
      :rand.seed(:exsss, {44, 55, 66})

      detected =
        Enum.count(1..200, fn _ ->
          l =
            CQ.new_ledger()
            |> then(fn l -> Enum.reduce(1..40, l, fn _, a -> CQ.record(a, false, :rand.uniform() < 0.8) end) end)
            |> then(fn l -> Enum.reduce(1..40, l, fn _, a -> CQ.record(a, true, :rand.uniform() < 0.5) end) end)

          CQ.verdict(l) == :harmful
        end)

      assert detected / 200 > 0.30
    end

    test "有益经验零误杀" do
      :rand.seed(:exsss, {77, 88, 99})

      misjudged =
        Enum.count(1..200, fn _ ->
          l =
            CQ.new_ledger()
            |> then(fn l -> Enum.reduce(1..20, l, fn _, a -> CQ.record(a, false, :rand.uniform() < 0.5) end) end)
            |> then(fn l -> Enum.reduce(1..20, l, fn _, a -> CQ.record(a, true, :rand.uniform() < 0.85) end) end)

          CQ.verdict(l) == :harmful
        end)

      assert misjudged == 0
    end
  end
end
