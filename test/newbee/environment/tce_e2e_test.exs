defmodule Newbee.Environment.TceEndToEndTest do
  @moduledoc """
  R5 端到端：Bus → Collector → PatternStore → Jit.tce_hot_needs 全链路。
  用真实 Bus 进程（非 mock），事件形状与 loop.ex emit 完全一致。
  """

  use Newbee.EnvironmentCase, async: false

  alias Newbee.Environment.Jit

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
    # 模拟 loop.ex: 200 次工具调用，每次 LLM 消耗 900 tokens
    # 200 次 x 900 = 180k > 校准后的默认 compile_cost 100k [R6]
    for _ <- 1..200 do
      Newbee.Bus.emit(:tool_start, {:tool_start, "run_elixir", "demo title", "1+1"})
      Newbee.Bus.emit_sync(:usage, {:usage, %{"prompt_tokens" => 800, "completion_tokens" => 100}})
    end

    # Bus 与 Collector 是不同发送者；固定 sleep 不能保证 flush 排在所有事件之后。
    # 轮询持久化投影，既验证最终一致性，也给慢机器明确的超时边界。
    send(Process.whereis(Newbee.Environment.PatternStore.Collector), :flush)
    assert eventually(fn -> Jit.tce_hot_needs() != [] end)

    [top | _] = Jit.tce_hot_needs()
    assert top.evidence[:count] >= 25
  end

  defp eventually(fun), do: eventually(fun, 100)
  defp eventually(_fun, 0), do: false

  defp eventually(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(20)
      eventually(fun, attempts - 1)
    end
  end
end
