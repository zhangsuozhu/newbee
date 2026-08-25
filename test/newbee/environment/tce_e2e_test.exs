defmodule Newbee.Environment.TceEndToEndTest do
  @moduledoc """
  R5 端到端：Bus → Collector → PatternStore → Jit.tce_hot_needs 全链路。
  用真实 Bus 进程（非 mock），事件形状与 loop.ex emit 完全一致。
  """

  use Newbee.EnvironmentCase, async: false

  alias Newbee.Environment.{PatternStore, Jit}

  setup do
    # 确保 Bus 与 Collector 都活着（Collector 订阅 Bus）
    if Process.whereis(Newbee.Bus), do: :ok, else: start_supervised!(Newbee.Bus)

    if Process.whereis(Newbee.Environment.PatternStore.Collector) do
      :ok
    else
      start_supervised!(Newbee.Environment.PatternStore.Collector)
    end
    :ok
  end

  @tag :e2e
  test "E2E: tool_start+usage 事件经 Bus 流入 Collector，flush 后 tce 可见" do
    # 模拟 loop.ex: 30 次工具调用，每次 LLM 消耗 900 tokens
    for _ <- 1..30 do
      Newbee.Bus.emit(:tool_start, {:tool_start, "run_elixir", "demo title", "1+1"})
      Newbee.Bus.emit_sync(:usage, {:usage, %{"prompt_tokens" => 800, "completion_tokens" => 100}})
    end

    # 强制 flush: 等 batch(25) 触发或定时器；直接发 flush 消息最稳
    send(Process.whereis(Newbee.Environment.PatternStore.Collector), :flush)
    Process.sleep(50)

    needs = Jit.tce_hot_needs()
    assert length(needs) >= 1

    top = hd(needs)
    assert top.evidence[:count] >= 25
  end
end
