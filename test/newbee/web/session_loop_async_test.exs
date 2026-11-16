defmodule Newbee.Web.SessionLoopAsyncTest do
  use ExUnit.Case, async: false

  # 回归：/loop 必须离开会话进程。
  #
  # 判据设计：假 kernel 是一个**永不回复 GenServer.call 的普通进程**。如果 /loop 仍在
  # 会话进程里同步执行 Loop.loop/3（内部是 GenServer.call(..., :infinity)），
  # handle_cast 就会一直挂住 —— 下面的 500ms 断言必然失败。所以这条测试真正区分
  # 「同步」与「异步」，不是只测一个数字。

  alias Newbee.Web.Session

  # 不响应任何 call 的假 kernel：模拟「正卡在一轮模型调用里」。
  defp blocking_kernel do
    spawn(fn -> Process.sleep(:infinity) end)
  end

  defp state_with_kernel(sid, kernel) do
    %Session{
      sid: sid,
      kernel: kernel,
      client: nil,
      busy: false,
      booting: false,
      queue: :queue.new(),
      queue_seq: 0,
      queue_events: [],
      current: nil
    }
  end

  defp timed(fun) do
    t0 = System.monotonic_time(:millisecond)
    result = fun.()
    {result, System.monotonic_time(:millisecond) - t0}
  end

  # 首次调用会触发模块/代码路径的惰性加载（实测可达 1s+），那是冷启动成本，
  # 与被 /loop 阻塞无关。断言前先用一次性 dummy 会话把路径预热，
  # 这样测到的是「是否存在阻塞」，而不是「代码是否已加载」。
  defp warm_up do
    kernel = blocking_kernel()

    for {text, qid} <- [{"/loop 预热", "warm-loop"}, {"预热", "warm-plain"}] do
      st = %Session{
        sid: "test_warm_2708",
        kernel: kernel,
        client: nil,
        busy: false,
        booting: false,
        queue: :queue.new(),
        queue_seq: 0,
        queue_events: [],
        current: nil
      }

      {:noreply, next} = Session.handle_cast({:prompt, text, qid}, st)

      if is_pid(next.turn_task) and Process.alive?(next.turn_task),
        do: Process.exit(next.turn_task, :kill)

      Session.handle_call(:state, {self(), make_ref()}, next)
    end

    if Process.alive?(kernel), do: Process.exit(kernel, :kill)
    :ok
  end

  test "handle_cast({:prompt, \"/loop ...\"}) 立即返回，工作交给独立 turn task" do
    warm_up()
    sid = "test_loop_async_#{System.unique_integer([:positive])}"
    kernel = blocking_kernel()
    on_exit(fn -> if Process.alive?(kernel), do: Process.exit(kernel, :kill) end)

    st = state_with_kernel(sid, kernel)

    {{:noreply, next}, took} =
      timed(fn -> Session.handle_cast({:prompt, "/loop 做完这个任务", "qid-1"}, st) end)

    assert took < 500, "/loop 不该在会话进程里同步执行，实测 #{took}ms"

    # 关键：工作被移交给独立进程，会话本身只持有一个 turn_task 句柄。
    assert is_pid(next.turn_task), "turn_task 应为独立进程，实际 #{inspect(next.turn_task)}"
    assert next.turn_task != self()
    assert is_reference(next.turn_ref)
    assert next.busy == true
    assert next.turn_id != nil

    if Process.alive?(next.turn_task), do: Process.exit(next.turn_task, :kill)
    ref = Process.monitor(next.turn_task)
    assert_receive {:DOWN, ^ref, :process, _pid, _}, 2_000
  end

  test "/loop 执行期间 session.state 仍在毫秒级返回" do
    warm_up()
    sid = "test_loop_state_#{System.unique_integer([:positive])}"
    kernel = blocking_kernel()
    on_exit(fn -> if Process.alive?(kernel), do: Process.exit(kernel, :kill) end)

    st = state_with_kernel(sid, kernel)
    goal = %{text: "目标", status: :active, rounds: 2, max_rounds: 10, tokens_used: 10, token_budget: 100}
    st = %{st | goal_snap: goal}

    {:noreply, st2} = Session.handle_cast({:prompt, "/loop 长任务", "qid-2"}, st)

    {{:reply, state, _}, took} =
      timed(fn -> Session.handle_call(:state, {self(), make_ref()}, st2) end)

    assert took < 1_000, "session.state 不该被 /loop 阻塞，实测 #{took}ms"
    # 快照仍可读，且不依赖 kernel（kernel 此刻完全无响应）
    assert state.goal.text == "目标"
    assert state.goal.rounds == 2
    assert state.busy == true

    if Process.alive?(st2.turn_task), do: Process.exit(st2.turn_task, :kill)
  end

  test "对比基线：假 kernel 完全不响应，但 /loop 路径不受其影响" do
    # 这条给出上两条的反证：同一假 kernel 若被同步 call，就会卡住。
    # 直接 call 它会超时/退出 —— 说明 /loop 必须绕开它才能在上面的 500ms 内返回。
    kernel = blocking_kernel()
    on_exit(fn -> if Process.alive?(kernel), do: Process.exit(kernel, :kill) end)

    assert catch_exit(GenServer.call(kernel, :anything, 100)) != nil
  end
end
