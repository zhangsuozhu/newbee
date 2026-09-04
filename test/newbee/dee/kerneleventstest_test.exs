defmodule Newbee.Agent.LoopEventsTest do
  use ExUnit.Case, async: false
  import Newbee.TestScripted
  alias Newbee.Agent.Loop
  alias Newbee.DEE.Evaluator

  test "turn_end / usage / tool_error 事件流经总线" do
    Newbee.Bus.subscribe()

    {:ok, ev} = Evaluator.start(mode: :local)

    {:ok, kernel} =
      Loop.start_link(
        client: %{},
        evaluator: ev,
        session: false,
        client_fun:
          scripted([
            fn _m, _o -> {:ok, tool_msg("raise \"boom\""), %{"prompt_tokens" => 3}} end,
            fn _m, _o -> {:ok, done_msg("done"), %{}} end
          ])
      )

    assert {:done, "done"} = Loop.submit(kernel, "go")
    # Loop 不再广播 :done——由 session 层 broadcast_turn_end 统一发送（去重）
    refute_received {:newbee_event, :done, {:done, "done"}}
    assert_received {:newbee_event, :usage, {:usage, %{"prompt_tokens" => 3}}}
    assert_received {:newbee_event, :tool_error, {:tool_error, rendered}}
    assert rendered =~ "boom"
    assert_received {:newbee_event, :turn_end, {:turn_end, :done, ms}}
    assert is_integer(ms)

    GenServer.stop(kernel)
    GenServer.stop(ev)
  end

  test "危险代码放行但审计（宽松沙箱）" do
    Newbee.Bus.subscribe()

    {:ok, ev} = Evaluator.start(mode: :local)

    {:ok, kernel} =
      Loop.start_link(
        client: %{},
        evaluator: ev,
        session: false,
        client_fun:
          scripted([
            fn _m, _o -> {:ok, tool_msg("x = String.length(\"System.halt is mentioned\")"), %{}} end,
            fn _m, _o -> {:ok, done_msg("d"), %{}} end
          ])
      )

    assert {:done, "d"} = Loop.submit(kernel, "go")
    assert_received {:newbee_event, :audit, {:audit, :dangerous_code, hits, _reversibility}}
    assert "System.halt" in hits

    GenServer.stop(kernel)
    GenServer.stop(ev)
  end

  test "沉睡规则命中时公开实际 prompt 注入详情" do
    Newbee.Bus.subscribe()
    Newbee.DEE.Rules.add("test-prompt-audit", "AUDIT_TRIGGER", "请改写输出", scope: :content)
    on_exit(fn -> Newbee.DEE.Rules.remove("test-prompt-audit") end)

    {:ok, ev} = Evaluator.start(mode: :local)

    {:ok, kernel} =
      Loop.start_link(
        client: %{},
        evaluator: ev,
        session: false,
        client_fun:
          scripted([
            fn _m, _o ->
              {:ok, %{"role" => "assistant", "content" => "结果 AUDIT_TRIGGER", "tool_calls" => []}, %{}}
            end,
            fn _m, _o ->
              {:ok, %{"role" => "assistant", "content" => "已按提醒修正", "tool_calls" => []}, %{}}
            end
          ])
      )

    assert {:text, "已按提醒修正"} = Loop.submit(kernel, "go")
    assert_received {:newbee_event, :rule_hit, {:rule_hit, [%{id: "test-prompt-audit"}]}}

    assert_received {:newbee_event, :prompt_injection, {:prompt_injection, details}}
    assert details.source == "sleeping_rule"
    assert details.role == "system"
    assert details.timing == "current_turn_retry"
    assert details.trigger == "结果 AUDIT_TRIGGER"
    assert details.content =~ "[Sleeping-rule hit]"
    assert details.content =~ "请改写输出"
    assert [%{id: "test-prompt-audit", pattern: "AUDIT_TRIGGER"}] = details.rules

    GenServer.stop(kernel)
    GenServer.stop(ev)
  end
end

:ok
