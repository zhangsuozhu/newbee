defmodule Newbee.Environment.PatternStatsVarianceTest do
  @moduledoc """
  R7 否定之否定第二次否定的回归防线：
  同均值不同方差的两个模式，实证方差(Welford)必须让稳定模式 LCB 显著更高。
  """

  use ExUnit.Case, async: true

  alias Newbee.Environment.PatternStats, as: PS

  @tag :variance_discrimination
  test "同均值异方差: 稳定模式 LCB 高于波动模式" do
    s1 = Enum.reduce(1..50, PS.new(), fn _, a -> PS.observe(a, %{saved_tokens: 3000.0}) end)

    s2 =
      Enum.reduce(1..25, PS.new(), fn _, a ->
        a |> PS.observe(%{saved_tokens: 5900.0}) |> PS.observe(%{saved_tokens: 100.0})
      end)

    assert elem(s2.save, 2) > 1_000_000, "波动模式实证方差应很大"
    lcb_stable = PS.net_lcb(s1, 100_000)
    lcb_volatile = PS.net_lcb(s2, 100_000)

    # 均值相同(153k)但方差惩罚使波动模式 LCB 大幅更低甚至为负
    assert lcb_stable > lcb_volatile + 50_000
    assert lcb_stable > 0
  end

  @tag :variance_discrimination
  test "恒定观测的方差为 0（不引入虚假不确定性）" do
    s = Enum.reduce(1..30, PS.new(), fn _, a -> PS.observe(a, %{saved_tokens: 2000.0}) end)
    assert elem(s.save, 2) == 0.0
  end
end
