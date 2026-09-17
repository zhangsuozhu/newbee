defmodule Newbee.Agent.LoopRetryNoticeTest do
  use ExUnit.Case, async: false

  alias Newbee.Agent.Loop
  alias Newbee.DEE.Evaluator

  # 上游流中断自动重试的链路：LLM 层调用 on_retry → Loop 发 :llm_retry 事件 → 观察者渲染。
  # 这里用 4 元 client_fun 模拟 LLM 层的重试回调，验证事件确实到达渲染出口。
  test "upstream retry notifies observers with a :llm_retry event" do
    test_pid = self()
    {:ok, ev} = Evaluator.start(mode: :local)

    client_fun = fn _messages, _on_text, _on_reasoning, on_retry ->
      on_retry.(:stream_read_error)
      {:ok, %{"role" => "assistant", "content" => "ok", "tool_calls" => []}, %{}}
    end

    {:ok, kernel} =
      Loop.start_link(
        client: %{},
        evaluator: ev,
        session: false,
        client_fun: client_fun,
        render: fn event -> send(test_pid, {:rendered, event}) end
      )

    assert {:text, "ok"} = Loop.submit(kernel, "go")
    assert_received {:rendered, {:llm_retry, :stream_read_error}}

    GenServer.stop(kernel)
    GenServer.stop(ev)
  end
end
