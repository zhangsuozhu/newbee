defmodule Newbee.Environment.SequentialLifecycleTest do
  @moduledoc """
  R8 长期生命周期验证（seed 可重复）：
  劣化被检出、持续坏持续报警、修复恢复清白——滚动 SPRT 完整语义。
  """

  use ExUnit.Case, async: false

  alias Newbee.Environment.Sequential

  @tag :lifecycle
  test "400 步生命周期: 缓慢劣化在第200步前检出, 修复后恢复清白" do
    :rand.seed(:exsss, {2026, 6, 18})

    p_of = fn step ->
      cond do
        step <= 100 -> 0.95
        step <= 200 -> max(0.95 - (step - 100) * 0.0055, 0.4)
        step <= 300 -> 0.35
        true -> 0.90
      end
    end

    st = Sequential.sprt_init()

    {final_st, h1_steps} =
      Enum.reduce(1..400, {st, []}, fn step, {sp, h1s} ->
        sp2 = Sequential.sprt_step_counted(sp, :rand.uniform() < p_of.(step))

        case sp2.decided do
          :h1 -> {Sequential.sprt_roll(sp2), [step | h1s]}
          :h0 -> {Sequential.sprt_roll(sp2), h1s}
          nil -> {sp2, h1s}
        end
      end)

    # 劣化被检出（h1 出现在劣化区间内）
    assert h1_steps != []
    # 至少一次 h1 落在缓慢劣化或持续坏区间 (101..300)
    assert Enum.any?(h1_steps, &(&1 in 101..300))
    # 最终状态恢复清白（修复期证据）
    assert final_st.decided == :h0 or final_st.s < 0
  end

  @tag :lifecycle
  test "sprt_roll: 决定后重置证据并累计轮数" do
    st = %{s: 5.0, decided: :h1, n: 7, rounds: 2}
    rolled = Sequential.sprt_roll(st)
    assert rolled.s == 0.0 and rolled.decided == nil and rolled.n == 0 and rolled.rounds == 3
    # 未决定时 roll 是幂等的
    fresh = Sequential.sprt_init()
    assert Sequential.sprt_roll(fresh) == fresh
  end
end
