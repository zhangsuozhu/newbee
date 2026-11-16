defmodule Newbee.Web.SessionGoalStateTest do
  use ExUnit.Case, async: false

  # WebUI 目标状态（/goal）回归：
  #   1. 六个 goal 事件都要有结构化编码，不能再落到兜底的 %{raw: inspect(...)}
  #   2. session.state 只读会话内存快照，绝不为拿目标状态去 call 忙碌 kernel
  #   3. /loop 在 Web 上不再占用会话进程（返回 {:loop, ...} 由独立 turn task 执行）
  #
  # 目标事件的编码/归约都在 Web.Session 内部，测试走公开的 render_event/2 + Bus 订阅，
  # 因此这些用例同时也是「事件确实下发给浏览器」的回归。

  alias Newbee.Web.Session

  setup do
    sid = "test_goal_#{System.unique_integer([:positive])}"
    :ok = Newbee.Bus.subscribe()
    on_exit(fn -> Newbee.Bus.unsubscribe() end)
    {:ok, sid: sid}
  end

  # 目标事件由会话进程归约并广播：这里直接驱动它的 cast handler
  # （等价于 kernel 事件线程投递过来的那条消息），检查下行给浏览器的 payload。
  defp render_and_collect(sid, event) do
    st = %Session{sid: sid, kernel: nil, client: nil, busy: false, booting: false, queue: :queue.new()}
    {:noreply, _st} = Session.handle_cast({:goal_event, elem(event, 0), event}, st)
    collect_kind(elem(event, 0))
  end

  defp collect_kind(kind, acc \\ []) do
    receive do
      {:newbee_event, :web_event, {:web_event, _sid, ^kind, payload}} ->
        if Map.has_key?(payload, :created_at) and not Map.has_key?(payload, :raw),
          do: payload,
          else: collect_kind(kind, [payload | acc])
    after
      1_000 -> flunk("没有收到 #{kind} 事件")
    end
  end

  describe "goal 事件结构化编码" do
    test "六个补编码的事件都有结构化字段、且都不落到 raw 兜底", %{sid: sid} do
      cases = [
        {{:goal_budget_limited, 1234}, %{tokens_used: 1234}},
        {{:goal_blocked, "blocked on tool"}, %{reason: "blocked on tool"}},
        {{:goal_verification_block, "ledger gap"}, %{summary: "ledger gap"}},
        {{:goal_status, :paused}, %{status: "paused"}},
        {{:goal_updated, "新目标"}, %{text: "新目标"}},
        {{:goal_budget, 50_000}, %{token_budget: 50_000}}
      ]

      for {event, expected} <- cases do
        payload = render_and_collect(sid, event)
        refute Map.has_key?(payload, :raw), "#{inspect(event)} 落到了 raw 兜底: #{inspect(payload)}"

        for {k, v} <- expected do
          assert Map.get(payload, k) == v, "期望 #{inspect(event)}.#{k} == #{inspect(v)}，实际 #{inspect(payload)}"
        end
      end
    end

    test "既有 goal 事件编码保持不变", %{sid: sid} do
      assert %{round: 3} = render_and_collect(sid, {:goal_round, 3})
      assert %{retry: 2} = render_and_collect(sid, {:goal_retry, 2})
      assert %{max: 20} = render_and_collect(sid, {:goal_limit, 20})
      assert %{text: "目标"} = render_and_collect(sid, {:goal_start, "目标"})
      assert %{summary: "done"} = render_and_collect(sid, {:goal_done, "done"})
      assert %{reason: "user"} = render_and_collect(sid, {:goal_cancelled, :user})
    end
  end

  describe "session.state 读快照而不是 call kernel" do
    test "带 goal_snap 的会话只读内存字段并原样返回 st" do
      sid = "test_goal_state_#{System.unique_integer([:positive])}"

      snap = %{
        id: "g1",
        text: "把 WebUI 目标状态做出来",
        status: :active,
        tokens_used: 42,
        token_budget: 1000,
        rounds: 3,
        max_rounds: 20,
        idle: 0,
        blocked_streak: 0
      }

      st = %Session{
        sid: sid,
        kernel: nil,
        client: nil,
        busy: false,
        booting: false,
        queue: :queue.new(),
        goal_snap: snap
      }

      t0 = System.monotonic_time(:millisecond)
      assert {:reply, state, ^st} = Session.handle_call(:state, {self(), make_ref()}, st)
      took = System.monotonic_time(:millisecond) - t0

      assert took < 1000, "session.state 不该被目标状态拖慢，实测 #{took}ms"
      assert state.goal.text == "把 WebUI 目标状态做出来"
      assert state.goal.status == "active"
      assert state.goal.rounds == 3
      assert state.goal.tokens_used == 42
      assert state.goal.token_budget == 1000
      assert state.goal.max_rounds == 20
    end

    test "无目标时会话快照为 nil（前端据此隐藏状态条）" do
      sid = "test_goal_nil_#{System.unique_integer([:positive])}"

      st = %Session{sid: sid, kernel: nil, client: nil, busy: false, booting: false, queue: :queue.new()}
      assert {:reply, state, ^st} = Session.handle_call(:state, {self(), make_ref()}, st)
      assert state.goal == nil
    end

    test "非 active 状态原样透出，便于前端区分暂停/受阻/预算触顶" do
      for status <- [:paused, :blocked, :budget_limited, :complete] do
        st = %Session{
          sid: "s_#{status}",
          kernel: nil,
          client: nil,
          busy: false,
          booting: false,
          queue: :queue.new(),
          goal_snap: %{text: "t", status: status}
        }

        assert {:reply, state, ^st} = Session.handle_call(:state, {self(), make_ref()}, st)
        assert state.goal.status == Atom.to_string(status)
      end
    end
  end

  describe "/loop 在 Web 上不占用会话进程" do
    test "async_loop 上下文返回 {:loop, task, opts} 而不是同步执行" do
      ctx = %{kernel: self(), say: fn _ -> :ok end, async_loop: true}

      assert {:loop, "做完这个任务", opts} =
               Newbee.Commands.handle("/loop 做完这个任务 --iterations 3", ctx)

      assert opts[:iterations] == 3
    end

    test "async_loop 也能解析 --budget" do
      ctx = %{kernel: self(), say: fn _ -> :ok end, async_loop: true}

      assert {:loop, "任务", opts} = Newbee.Commands.handle("/loop 任务 --budget 5000", ctx)
      assert opts[:token_budget] == 5_000
    end

    test "没有 kernel 时仍是 :handled（不返回 {:loop, ...}）" do
      ctx = %{kernel: nil, say: fn _ -> :ok end, async_loop: true}
      assert Newbee.Commands.handle("/loop x", ctx) == :handled
    end

    test "CLI/TUI 不带 async_loop，保持同步路径（这里用假 kernel 验证走的是同步分支）" do
      ctx = %{kernel: self(), say: fn _ -> :ok end}

      # 同步分支会对 self() 做 GenServer.call，必然失败/退出；关键是**不能**是 {:loop, ...}
      result =
        try do
          Newbee.Commands.handle("/loop x --iterations 1", ctx)
        catch
          :exit, _ -> :sync_path
        end

      refute match?({:loop, _, _}, result)
    end
  end

  describe "目标事件补充执行上下文" do
    test "goal_start 之后的事件带上轮次与预算上限（前端状态条需要）", %{sid: sid} do
      # 起一个带预算的目标，然后推进轮次：goal_round 的 payload 自身只有 round，
      # 其余进度信息由快照补齐。
      render_and_collect(sid, {:goal_start, "把目标状态做出来"})

      st = %Session{
        sid: sid,
        kernel: nil,
        client: nil,
        busy: false,
        booting: false,
        queue: :queue.new(),
        goal_snap: %{
          text: "把目标状态做出来",
          status: :active,
          rounds: 2,
          max_rounds: 20,
          tokens_used: 500,
          token_budget: 10_000,
          idle: 0,
          blocked_streak: 0
        }
      }

      {:noreply, st2} = Session.handle_cast({:goal_event, :goal_round, {:goal_round, 3}}, st)
      payload = collect_kind(:goal_round)

      assert payload.round == 3
      assert payload.rounds == 3
      assert payload.max_rounds == 20
      assert payload.token_budget == 10_000
      assert st2.goal_snap.rounds == 3
    end

    test "goal_status 的 status 不被快照覆盖", %{sid: sid} do
      st = %Session{
        sid: sid,
        kernel: nil,
        client: nil,
        busy: false,
        booting: false,
        queue: :queue.new(),
        goal_snap: %{text: "t", status: :active, rounds: 1, max_rounds: 5}
      }

      {:noreply, st2} = Session.handle_cast({:goal_event, :goal_status, {:goal_status, :paused}}, st)
      payload = collect_kind(:goal_status)

      assert payload.status == "paused"
      assert st2.goal_snap.status == :paused
    end

    test "goal_done 之后快照清空，session.state 回到 nil" do
      sid = "test_goal_done_#{System.unique_integer([:positive])}"

      st = %Session{
        sid: sid,
        kernel: nil,
        client: nil,
        busy: false,
        booting: false,
        queue: :queue.new(),
        goal_snap: %{text: "t", status: :active, rounds: 4, max_rounds: 5}
      }

      {:noreply, st2} = Session.handle_cast({:goal_event, :goal_done, {:goal_done, "搞定"}}, st)
      assert st2.goal_snap == nil
      assert {:reply, state, ^st2} = Session.handle_call(:state, {self(), make_ref()}, st2)
      assert state.goal == nil
    end
  end
end
