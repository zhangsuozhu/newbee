defmodule Newbee.Environment.TceIntegrationTest do
  @moduledoc """
  真实调用链集成测试（修复"改进未被调用"问题后的回归防线）：
  C1 真实事件流形状（Events 落盘格式）能被 PatternStore.project 消费
  C2 adapter.collect_signals 默认走 tce_hot_needs
  C3 Fitness.observe 双投影到 PatternStats
  """

  use Newbee.EnvironmentCase, async: false

  alias Newbee.Environment.{PatternStore, PatternStats, Jit}
  alias Newbee.Agent.Adapter

  @tag :tce_wiring
  test "C1 真实事件形状: payload list 格式可被 project 消费" do
    # loop.ex emit 的 {:tool_start, name, title, code} 经 json_safe 落盘后的形状:
    events = [
      %{"topic" => "tool_start", "payload" => ["tool_start", "run_elixir", "demo", "1+1"]},
      %{"topic" => "tool_result", "payload" => ["tool_result", "run_elixir", "ok", 42]},
      %{"topic" => "tool_error", "payload" => ["tool_error", "run_elixir", "boom"]}
    ]

    stats = PatternStore.project(events)
    key = {{:tool_use, "run_elixir"}, "general"}
    assert Map.has_key?(stats, key)
    assert stats[key].n == 3
  end

  @tag :tce_wiring
  test "C2 adapter.collect_signals 无事件参数时走 tce_hot_needs" do
    # 构造一个明确的热点并持久化
    # Collector 归因后的形状: tokens 已知; 120x2500=300k > 100k [R6]
    events =
      for _ <- 1..120 do
        %{"topic" => "tool_start", "payload" => ["tool_start", "HotTool", "", "x"], "tokens" => 2500}
      end

    stats = PatternStore.project(events)
    assert is_atom(PatternStore.persist(stats))

    signals = Adapter.collect_signals(hints: [])
    hot = Enum.filter(signals, &(&1.type == :jit_hot))
    assert length(hot) >= 1
    assert Enum.any?(hot, &String.contains?(to_string(&1.capability), "tool_use"))
  end

  @tag :tce_wiring
  test "C3 Fitness.observe 双投影写入 PatternStats" do
    alias Newbee.Environment.Fitness

    Fitness.observe("rel-test-1", %{success: true, tokens: 800, task_type: "refactor"})
    restored = PatternStore.restore()
    key = {{:tool_use, "refactor"}, "refactor"}
    assert Map.has_key?(restored, key)
    s = restored[key]
    assert s.n == 1
    assert PatternStats.save_mean(s) == 800.0
  end
end
