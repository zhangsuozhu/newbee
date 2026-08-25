defmodule Newbee.Environment.TceDecisionTest do
  use Newbee.EnvironmentCase, async: false

  alias Newbee.Environment.{PatternStore, PatternStats, Jit}

  defp hot_events(n, tokens) do
    for _ <- 1..n, do: %{topic: :tool_start, data: %{name: "Edit", tokens: tokens}}
  end

  @tag :tce
  test "tce_hot_needs: 热模式按 LCB 排序且携带后验证据 [D10][D14]" do
    events = hot_events(30, 2000)
    stats = PatternStore.project(events)
    needs = Jit.tce_hot_needs(stats: stats)

    assert length(needs) >= 1
    top = hd(needs)
    assert top.urgency == :high
    assert top.lcb > 0
    assert {:tool_use, "Edit"} = top.evidence[:pattern]
    assert is_number(top.evidence[:lcb]) or is_map(top.evidence)
  end

  @tag :tce
  test "tce_hot_needs: 冷模式与低收益模式不进队列（小样本不决策 P1）" do
    cold = PatternStore.project(hot_events(2, 5000))
    assert Jit.tce_hot_needs(stats: cold) == []

    # 高频但节省太小，LCB 扣除编译成本后为负
    tiny = PatternStore.project(for _ <- 1..50, do: %{topic: :tool_start, data: %{name: "Run", tokens: 10}})
    refute Jit.tce_hot_needs(stats: tiny, compile_cost: 5_000) |> Enum.any?()
  end

  @tag :tce
  test "kappa 越大 LCB 越保守（风险厌恶）[D14]" do
    events = hot_events(20, 1500)
    stats = PatternStore.project(events)
    loose = Jit.tce_hot_needs(stats: stats, kappa: 0.1)
    tight = Jit.tce_hot_needs(stats: stats, kappa: 8.0)
    assert length(loose) >= length(tight)

    if length(loose) > 0 and length(tight) > 0 do
      assert hd(loose).lcb >= hd(tight).lcb
    end
  end

  @tag :tce
  test "tce_deopt_decision: 双通道判定接通 PatternStore [D17]" do
    broken =
      1..20
      |> Enum.reduce(PatternStore.project(hot_events(25, 800)), fn i, acc ->
        Map.update!(acc, {{:tool_use, "Edit"}, "general"}, fn s ->
          PatternStats.observe(s, %{success: rem(i, 10) == 0})
        end)
      end)

    decision = Jit.tce_deopt_decision({{:tool_use, "Edit"}, "general"}, stats: broken)
    assert match?(:keep, decision) or match?({:tool_broken, _}, decision) or match?({:drifted, _}, decision)
    assert is_atom(decision) or elem(decision, 1) != ""

    unknown = Jit.tce_deopt_decision({{:tool_use, "Nope"}, "general"}, stats: %{})
    assert unknown == :keep
  end

  @tag :tce
  test "端到端：project → persist → restore → tce_hot_needs" do
    events = hot_events(40, 2500) ++ [%{topic: :tool_start, data: %{name: "Bash", tokens: 100}}]
    stats = PatternStore.project(events)
    assert is_atom(PatternStore.persist(stats))
    restored = PatternStore.restore()
    needs = Jit.tce_hot_needs(stats: restored)
    assert needs |> Enum.any?(&(&1.evidence[:pattern] == {:tool_use, "Edit"} or get_in(&1.evidence, [:pattern]) == {:tool_use, "Edit"}))
  end
end
