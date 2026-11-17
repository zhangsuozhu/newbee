defmodule Newbee.Agent.GoalAccountingTest do
  # NEWBEE_GOALS_DIR / NEWBEE_JSPACE_DIR 是进程级环境变量，串行运行避免相互干扰。
  use ExUnit.Case, async: false
  import Newbee.TestScripted
  alias Newbee.Agent.Loop
  alias Newbee.DEE.Evaluator
  alias Newbee.Tools.JSpace

  setup do
    goals = Path.join(System.tmp_dir!(), "newbee-goals-agent-#{System.unique_integer([:positive])}")
    jspace = Path.join(System.tmp_dir!(), "newbee-jspace-agent-#{System.unique_integer([:positive])}")
    File.mkdir_p!(goals)
    File.mkdir_p!(jspace)

    prev_goals = System.get_env("NEWBEE_GOALS_DIR")
    prev_jspace = System.get_env("NEWBEE_JSPACE_DIR")
    System.put_env("NEWBEE_GOALS_DIR", goals)
    System.put_env("NEWBEE_JSPACE_DIR", jspace)

    on_exit(fn ->
      restore("NEWBEE_GOALS_DIR", prev_goals)
      restore("NEWBEE_JSPACE_DIR", prev_jspace)
      File.rm_rf(goals)
      File.rm_rf(jspace)
    end)

    {:ok, ev} = Evaluator.start(mode: :local)
    {:ok, goals_dir: goals, evaluator: ev}
  end

  defp restore(name, nil), do: System.delete_env(name)
  defp restore(name, value), do: System.put_env(name, value)

  defp text_msg(content) do
    %{"role" => "assistant", "content" => content, "tool_calls" => []}
  end

  defp start_kernel(ev, client_fun) do
    {:ok, kernel} = Loop.start_link(client: %{}, evaluator: ev, session: true, client_fun: client_fun)
    kernel
  end

  defp session_id(kernel), do: :sys.get_state(kernel).session.id

  test "一轮 usage total_tokens=N 时 goal.tokens_used 增量恰为 N（不按字节估算、不按轮均摊）", %{
    evaluator: ev
  } do
    Newbee.Bus.subscribe()
    # 第一轮 700、第二轮 534：只有“本轮真实 usage 增量”口径才会得到 1234；
    # 若按字节/4 估算，或把累计 total_tokens 按轮均摊，结果不会是这两个真值之和。
    fun =
      scripted([
        fn _m, _o ->
          {:ok, text_msg("第一轮：只做了检查"), %{"total_tokens" => 700, "prompt_tokens" => 500, "completion_tokens" => 200}}
        end,
        fn _m, _o -> {:ok, done_msg("完成"), %{"total_tokens" => 534}} end
      ])

    kernel = start_kernel(ev, fun)

    assert :ok = Loop.set_goal(kernel, "真实 usage 记账")

    # 第一轮结束后（下一次模型调用前）内存里的增量必须恰好是这一轮的 700。
    assert_receive {:newbee_event, :goal_round, {:goal_round, 1}}, 30_000
    assert Loop.goal(kernel).tokens_used == 700

    assert_receive {:newbee_event, :goal_done, {:goal_done, "完成"}}, 30_000

    result = Loop.last_goal_result(kernel)
    assert result["tokens_used"] == 700 + 534
    assert result["status"] == "complete"

    GenServer.stop(kernel)
  end

  test "done 出口：落盘终态与内存最终值一致，随后目标文件被清理", %{evaluator: ev, goals_dir: goals} do
    Newbee.Bus.subscribe()

    fun =
      scripted([
        fn _m, _o -> {:ok, text_msg("r1"), %{"total_tokens" => 111}} end,
        fn _m, _o -> {:ok, text_msg("r2"), %{"total_tokens" => 222}} end,
        fn _m, _o -> {:ok, done_msg("完成"), %{"total_tokens" => 333}} end
      ])

    kernel = start_kernel(ev, fun)
    assert :ok = Loop.set_goal(kernel, "落盘一致性")

    assert_receive {:newbee_event, :goal_done, {:goal_done, "完成"}}, 30_000
    sid = session_id(kernel)

    result = Loop.last_goal_result(kernel)
    assert result["tokens_used"] == 666
    assert result["status"] == "complete"
    assert result["text"] == "落盘一致性"
    refute File.regular?(Path.join(goals, "#{sid}.json"))

    GenServer.stop(kernel)
  end

  test "否定句（not blocked / 没有 blocked / 未阻塞）连续 3 轮不置 blocked", %{evaluator: ev} do
    Newbee.Bus.subscribe()

    fun =
      scripted([
        fn _m, _o -> {:ok, text_msg("not blocked: 继续跑测试"), %{}} end,
        fn _m, _o -> {:ok, text_msg("没有 blocked，正在推进"), %{}} end,
        fn _m, _o -> {:ok, text_msg("未阻塞，下一步补验证"), %{}} end,
        fn _m, _o -> {:ok, done_msg("完成"), %{}} end
      ])

    kernel = start_kernel(ev, fun)
    assert :ok = Loop.set_goal(kernel, "否定句不误判")

    assert_receive {:newbee_event, :goal_round, {:goal_round, 1}}, 30_000
    assert_receive {:newbee_event, :goal_round, {:goal_round, 2}}, 30_000
    assert_receive {:newbee_event, :goal_round, {:goal_round, 3}}, 30_000
    assert_receive {:newbee_event, :goal_done, {:goal_done, "完成"}}, 30_000
    refute_received {:newbee_event, :goal_blocked, _}

    GenServer.stop(kernel)
  end

  test "连续 3 轮明确阻塞才置 :blocked 并停轮", %{evaluator: ev} do
    Newbee.Bus.subscribe()

    fun =
      scripted([
        fn _m, _o -> {:ok, text_msg("blocked: 等待用户提供凭证"), %{}} end,
        fn _m, _o -> {:ok, text_msg("仍然 blocked，无法继续"), %{}} end,
        fn _m, _o -> {:ok, text_msg("blocked，需要用户确认"), %{}} end,
        fn _m, _o -> {:ok, done_msg("不该被调用"), %{}} end
      ])

    kernel = start_kernel(ev, fun)
    assert :ok = Loop.set_goal(kernel, "真阻塞")

    assert_receive {:newbee_event, :goal_blocked, _}, 30_000
    g = Loop.goal(kernel)
    assert g.status == :blocked
    assert g.blocked_streak == 3
    refute_received {:newbee_event, :goal_done, _}

    GenServer.stop(kernel)
  end

  test "JSpace 门：空账本（Verified/Open 均 none）不拦 done", %{evaluator: ev} do
    Newbee.Bus.subscribe()
    fun = scripted([fn _m, _o -> {:ok, done_msg("完成"), %{}} end])
    kernel = start_kernel(ev, fun)
    JSpace.note([goal: "g", next: "n"], session_id(kernel))

    assert :ok = Loop.set_goal(kernel, "空账本")
    assert_receive {:newbee_event, :goal_done, {:goal_done, "完成"}}, 30_000
    refute_received {:newbee_event, :goal_verification_block, _}

    GenServer.stop(kernel)
  end

  test "JSpace 门：有 `? ` 且无 ✓ 时拦 done；补上 ✓ 后放行", %{evaluator: ev} do
    Newbee.Bus.subscribe()
    {:ok, sid_agent} = Agent.start_link(fn -> nil end)
    test_pid = self()

    fun =
      scripted([
        fn _m, _o -> {:ok, done_msg("提前完成"), %{}} end,
        fn _m, _o ->
          JSpace.note([verified: "定向测试全绿"], Agent.get(sid_agent, & &1))
          send(test_pid, :recorded_verified)
          {:ok, done_msg("完成"), %{}}
        end
      ])

    kernel = start_kernel(ev, fun)
    Agent.update(sid_agent, fn _ -> session_id(kernel) end)
    JSpace.note([open: "并发语义待确认"], session_id(kernel))

    assert :ok = Loop.set_goal(kernel, "验证门")
    assert_receive {:newbee_event, :goal_verification_block, _}, 30_000
    assert_receive :recorded_verified, 30_000
    assert_receive {:newbee_event, :goal_done, {:goal_done, "完成"}}, 30_000
    assert Loop.goal(kernel) == nil

    GenServer.stop(kernel)
  end

  test "JSpace 门：有 ✓ 时不拦 done", %{evaluator: ev} do
    Newbee.Bus.subscribe()
    fun = scripted([fn _m, _o -> {:ok, done_msg("完成"), %{}} end])
    kernel = start_kernel(ev, fun)
    sid = session_id(kernel)
    JSpace.note([open: "边缘场景待定"], sid)
    JSpace.note([verified: "主路径已验"], sid)

    assert :ok = Loop.set_goal(kernel, "已验")
    assert_receive {:newbee_event, :goal_done, {:goal_done, "完成"}}, 30_000
    refute_received {:newbee_event, :goal_verification_block, _}

    GenServer.stop(kernel)
  end
end
