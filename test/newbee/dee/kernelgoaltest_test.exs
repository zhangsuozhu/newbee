defmodule Newbee.Agent.LoopGoalTest do
  use ExUnit.Case, async: false
  import Newbee.TestScripted
  alias Newbee.Agent.Loop
  alias Newbee.DEE.Evaluator

  defp text_msg(content) do
    %{"role" => "assistant", "content" => content, "tool_calls" => []}
  end

  defp ask_msg(question) do
    %{
      "role" => "assistant",
      "content" => "",
      "tool_calls" => [
        %{
          "id" => "c_ask",
          "type" => "function",
          "function" => %{"name" => "ask", "arguments" => Jason.encode!(%{question: question})}
        }
      ]
    }
  end

  test "自主循环：文本回合自动续轮，直到 done 才停止并清除目标" do
    Newbee.Bus.subscribe()

    {:ok, ev} = Evaluator.start(mode: :local)

    {:ok, kernel} =
      Loop.start_link(
        client: %{},
        evaluator: ev,
        session: false,
        client_fun:
          scripted([
            fn _m, _o -> {:ok, text_msg("第一步：检查现状"), %{}} end,
            fn messages, _o ->
              # 第 2 轮能看到第 1 轮后的自动继续消息
              assert Enum.any?(messages, fn m ->
                       m["role"] == "system" and m["content"] =~ "自主模式第 1 轮"
                     end)

              {:ok, text_msg("第二步：改代码"), %{}}
            end,
            fn _m, _o -> {:ok, done_msg("达成"), %{}} end
          ])
      )

    assert :ok = Loop.set_goal(kernel, "修复所有失败测试")
    assert_receive {:newbee_event, :goal_start, {:goal_start, "修复所有失败测试"}}
    assert_receive {:newbee_event, :goal_round, {:goal_round, 1}}
    assert_receive {:newbee_event, :goal_round, {:goal_round, 2}}
    assert_receive {:newbee_event, :goal_done, {:goal_done, "达成"}}

    assert Loop.goal(kernel) == nil

    msgs = :sys.get_state(kernel).messages
    assert Enum.any?(msgs, fn m -> m["role"] == "system" and m["content"] =~ "[自主目标模式]" end)
    assert Enum.any?(msgs, fn m -> m["role"] == "user" and m["content"] =~ "自主目标模式启动" end)

    GenServer.stop(kernel)
    GenServer.stop(ev)
  end

  test "轮数上限：达到 max_rounds 自动停止并清目标" do
    Newbee.Bus.subscribe()

    {:ok, ev} = Evaluator.start(mode: :local)

    {:ok, kernel} =
      Loop.start_link(
        client: %{},
        evaluator: ev,
        session: false,
        client_fun:
          scripted([
            fn _m, _o -> {:ok, text_msg("r1"), %{}} end,
            fn _m, _o -> {:ok, text_msg("r2"), %{}} end
          ])
      )

    assert :ok = Loop.set_goal(kernel, "目标", max_rounds: 2)
    assert_receive {:newbee_event, :goal_start, {:goal_start, "目标"}}
    assert_receive {:newbee_event, :goal_round, {:goal_round, 1}}
    assert_receive {:newbee_event, :goal_limit, {:goal_limit, 2}}

    assert Loop.goal(kernel) == nil
    refute_received {:newbee_event, :goal_round, {:goal_round, 3}}

    GenServer.stop(kernel)
    GenServer.stop(ev)
  end

  test "ask 保留目标：用户回答后自动续跑直到 done" do
    Newbee.Bus.subscribe()

    {:ok, ev} = Evaluator.start(mode: :local)

    {:ok, kernel} =
      Loop.start_link(
        client: %{},
        evaluator: ev,
        session: false,
        client_fun:
          scripted([
            fn _m, _o -> {:ok, ask_msg("要重构吗？"), %{}} end,
            fn _m, _o -> {:ok, text_msg("继续干活"), %{}} end,
            fn _m, _o -> {:ok, done_msg("完"), %{}} end
          ])
      )

    assert :ok = Loop.set_goal(kernel, "目标")
    assert_receive {:newbee_event, :goal_ask, {:goal_ask, "要重构吗？"}}

    # ask 后目标保留（rounds 未推进）
    g = Loop.goal(kernel)
    assert g != nil and g.text == "目标" and g.rounds == 0

    # 用户回答：单轮 submit 结束后自动续跑（脚本 3 的 done 由 goal_next 驱动）
    assert {:text, "继续干活"} = Loop.submit(kernel, "可以")
    assert_receive {:newbee_event, :goal_done, {:goal_done, "完"}}
    assert Loop.goal(kernel) == nil

    GenServer.stop(kernel)
    GenServer.stop(ev)
  end

  test "clear_goal 取消自主循环" do
    Newbee.Bus.subscribe()

    {:ok, ev} = Evaluator.start(mode: :local)

    {:ok, kernel} =
      Loop.start_link(
        client: %{},
        evaluator: ev,
        session: false,
        client_fun:
          scripted([
            fn _m, _o -> {:ok, text_msg("r1"), %{}} end,
            fn _m, _o -> {:ok, text_msg("r2"), %{}} end
          ])
      )

    assert :ok = Loop.set_goal(kernel, "目标")
    assert_receive {:newbee_event, :goal_round, {:goal_round, 1}}

    assert :ok = Loop.clear_goal(kernel)
    assert_receive {:newbee_event, :goal_cancelled, {:goal_cancelled, :user}}
    assert Loop.goal(kernel) == nil

    # 残留的 goal_next 不再触发回合
    refute_received {:newbee_event, :goal_round, {:goal_round, 3}}

    GenServer.stop(kernel)
    GenServer.stop(ev)
  end

  test "Esc 中断清除目标" do
    Newbee.Bus.subscribe()

    {:ok, ev} = Evaluator.start(mode: :local)

    {:ok, kernel} =
      Loop.start_link(
        client: %{},
        evaluator: ev,
        session: false,
        client_fun:
          scripted([
            fn _m, _o -> {:ok, text_msg("r1"), %{}} end,
            fn _m, on_text ->
              on_text.("部分")
              {:interrupted, "部分"}
            end
          ])
      )

    assert :ok = Loop.set_goal(kernel, "目标")
    assert_receive {:newbee_event, :goal_cancelled, {:goal_cancelled, :interrupted}}
    assert Loop.goal(kernel) == nil

    GenServer.stop(kernel)
    GenServer.stop(ev)
  end

  test "连续多轮无工具调用：注入停滞提醒" do
    Newbee.Bus.subscribe()

    {:ok, ev} = Evaluator.start(mode: :local)

    {:ok, kernel} =
      Loop.start_link(
        client: %{},
        evaluator: ev,
        session: false,
        client_fun:
          scripted([
            fn _m, _o -> {:ok, text_msg("r1"), %{}} end,
            fn _m, _o -> {:ok, text_msg("r2"), %{}} end,
            fn _m, _o -> {:ok, text_msg("r3"), %{}} end,
            fn _m, _o -> {:ok, done_msg("完"), %{}} end
          ])
      )

    assert :ok = Loop.set_goal(kernel, "目标", max_rounds: 10)
    assert_receive {:newbee_event, :goal_done, {:goal_done, "完"}}

    msgs = :sys.get_state(kernel).messages
    assert Enum.any?(msgs, fn m -> m["role"] == "system" and m["content"] =~ "连续多轮没有调用工具" end)

    GenServer.stop(kernel)
    GenServer.stop(ev)
  end

  test "瞬态上游错误：重试后继续并完成目标" do
    Newbee.Bus.subscribe()
    {:ok, ev} = Evaluator.start(mode: :local)

    {:ok, kernel} =
      Loop.start_link(
        client: %{},
        evaluator: ev,
        session: false,
        client_fun:
          scripted([
            fn _m, _o -> {:error, {:stream_error, :timeout, "partial"}} end,
            fn _m, _o -> {:ok, done_msg("重试后完成"), %{}} end
          ])
      )

    assert :ok = Loop.set_goal(kernel, "目标", retry_delay: 0)
    assert_receive {:newbee_event, :goal_retry, {:goal_retry, 1}}
    assert_receive {:newbee_event, :goal_done, {:goal_done, "重试后完成"}}
    assert Loop.goal(kernel) == nil

    GenServer.stop(kernel)
    GenServer.stop(ev)
  end

  test "瞬态上游错误耗尽重试后取消目标" do
    Newbee.Bus.subscribe()
    {:ok, ev} = Evaluator.start(mode: :local)

    {:ok, kernel} =
      Loop.start_link(
        client: %{},
        evaluator: ev,
        session: false,
        client_fun:
          scripted([
            fn _m, _o -> {:error, {:upstream_error, :overloaded}} end,
            fn _m, _o -> {:error, {:upstream_error, :overloaded}} end,
            fn _m, _o -> {:error, {:upstream_error, :overloaded}} end
          ])
      )

    assert :ok = Loop.set_goal(kernel, "目标", max_error_retries: 2, retry_delay: 0)
    assert_receive {:newbee_event, :goal_retry, {:goal_retry, 1}}
    assert_receive {:newbee_event, :goal_retry, {:goal_retry, 2}}
    assert_receive {:newbee_event, :goal_cancelled, {:goal_cancelled, :error}}
    assert Loop.goal(kernel) == nil

    GenServer.stop(kernel)
    GenServer.stop(ev)
  end
end
