defmodule Newbee.Environment.ContextQuality.E2ETest do
  @moduledoc """
  端到端验收：真实 Bus + Events.emit 事件流 → Collector 差分归因 → 退休候选。
  模拟 harness 真实运行：规则注入 → 任务成败 → 质量判定。
  """
  use ExUnit.Case, async: false

  alias Newbee.Environment.ContextQuality.Collector

  setup do
    # 确保 Bus 在跑（test 环境 Application 已起 Bus）
    unless Process.whereis(Newbee.Bus) do
      {:ok, _} = Newbee.Bus.start_link([])
    end

    {:ok, pid} = Collector.start_link(subscribe: true, name: nil)
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
    %{collector: pid}
  end

  test "真实事件流：有害规则被识别为退休候选，有益/中性不误杀", %{collector: pid} do
    GenServer.cast(pid, {:register, "helpful_rule"})
    GenServer.cast(pid, {:register, "harmful_rule"})

    :rand.seed(:exsss, {7, 8, 9})

    # 40 个真实事件 turn
    Enum.each(1..40, fn i ->
      sid = "e2e_#{i}"

      if rem(i, 2) == 0 do
        # helpful_rule：注入后 85% 成功
        Newbee.Events.emit(:prompt_injection, %{session_id: sid, source: "helpful_rule"})

        if :rand.uniform() < 0.85 do
          Newbee.Events.emit(:goal_done, %{session_id: sid})
        else
          Newbee.Events.emit(:tool_error, %{session_id: sid})
          Newbee.Events.emit(:turn_end, %{session_id: sid})
        end
      else
        # harmful_rule：注入后 30% 成功
        Newbee.Events.emit(:prompt_injection, %{session_id: sid, source: "harmful_rule"})

        if :rand.uniform() < 0.30 do
          Newbee.Events.emit(:goal_done, %{session_id: sid})
        else
          Newbee.Events.emit(:tool_error, %{session_id: sid})
          Newbee.Events.emit(:turn_end, %{session_id: sid})
        end
      end
    end)

    # 等 Bus 异步投递 + Collector 处理完
    Process.sleep(300)

    tags = Collector.price_tags(pid)
    assert Map.has_key?(tags, "helpful_rule")
    assert Map.has_key?(tags, "harmful_rule")

    helpful = tags["helpful_rule"]
    harmful = tags["harmful_rule"]

    # 有害规则：注入成功率显著低于基线，判定 harmful 或至少方向正确
    assert harmful.success_with < harmful.success_without
    assert harmful.verdict in [:harmful, :insufficient]

    # 有益规则：绝不被误判 harmful
    refute helpful.verdict == :harmful
    assert helpful.success_with > harmful.success_with

    # 退休候选应只含有害规则（当样本足够判定）
    cands = Collector.retire_candidates(pid) |> Enum.map(fn {rid, _} -> rid end)
    if harmful.verdict == :harmful do
      assert "harmful_rule" in cands
      refute "helpful_rule" in cands
    end
  end

  test "Collector 崩溃不影响 Loop（隔离性）", %{collector: pid} do
    # 发一个畸形事件，Collector 不应崩（事件处理健壮性）
    Newbee.Events.emit(:prompt_injection, %{})
    Newbee.Events.emit(:tool_error, nil)
    Newbee.Events.emit(:usage, %{tokens: "not_a_number"})
    Process.sleep(100)
    assert Process.alive?(pid)
  end
end
