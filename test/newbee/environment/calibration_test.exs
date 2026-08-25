defmodule Newbee.Environment.CalibrationTest do
  use Newbee.EnvironmentCase, async: false

  alias Newbee.Environment.Calibration

  @tag :calibration
  test "record + settle + score：预测准则误差低" do
    Calibration.record("c1", 1000.0)
    Calibration.settle("c1", 1050.0)
    # rel_err = (50/1000)² = 0.0025
    assert_in_delta Calibration.score(), 0.0025, 1.0e-6
  end

  @tag :calibration
  test "系统性高报被 proper scoring rule 惩罚 [R9]" do
    Calibration.record("h1", 5000.0)
    Calibration.record("h2", 5000.0)
    Calibration.settle("h1", 1000.0)
    Calibration.settle("h2", 1200.0)
    score = Calibration.score()
    assert score > 0.5
  end

  @tag :calibration
  test "converging?：误差下降趋势为真，发散为假 [D18]" do
    # 无样本 → false
    refute Calibration.converging?(window: 4)

    # 改善序列
    Enum.with_index([2.0, 1.5, 1.0, 0.7], fn e, i ->
      id = "conv-#{i}"
      Calibration.record(id, 1000.0)
      Calibration.settle(id, 1000.0 - trunc(1000 * :math.sqrt(e)))
    end)

    assert Calibration.converging?(threshold: 10.0)
  end

  @tag :calibration
  test "adjust_compile_cost：偏差大时成本上调且封顶 ×3 [D18]" do
    assert Calibration.adjust_compile_cost(5000) == 5000
    Calibration.record("adj1", 3000.0)
    Calibration.settle("adj1", 100.0)
    adjusted = Calibration.adjust_compile_cost(5000)
    assert adjusted > 5000
    assert adjusted <= 15_000
  end
end
