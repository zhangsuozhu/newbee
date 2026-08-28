defmodule Newbee.Collaboration.DispatchStub do
  use GenServer

  def start_link(sid, tester) do
    GenServer.start_link(__MODULE__, {sid, tester}, name: {:via, Registry, {Newbee.Web.SessionRegistry, sid}})
  end

  @impl true
  def init({sid, tester}), do: {:ok, %{sid: sid, tester: tester}}

  @impl true
  def handle_cast(msg, st) do
    send(st.tester, {:stub_got, st.sid, msg})
    {:noreply, st}
  end
end

defmodule Newbee.Collaboration.DispatchTest do
  use ExUnit.Case, async: false

  alias Newbee.Collaboration.{Coordinator, DispatchStub}

  setup do
    case Process.whereis(Coordinator) do
      nil -> :ok
      pid -> GenServer.stop(pid)
    end

    root = Path.join(System.tmp_dir!(), "newbee-collab-dispatch-#{System.unique_integer([:positive])}")
    {:ok, coord} = Coordinator.start_link(path: Path.join(root, "events.jsonl"), durability: :event)
    {:ok, stub} = DispatchStub.start_link("stub-worker", self())

    on_exit(fn ->
      if Process.alive?(coord), do: GenServer.stop(coord)
      if Process.alive?(stub), do: Process.exit(stub, :kill)
      File.rm_rf!(root)
    end)

    %{}
  end

  test "创建并分派任务时，目标会话收到 collaboration_task 投递" do
    assert {:ok, group} = Coordinator.create_group(%{"session_id" => "parent", "title" => "分派群"})
    assert {:ok, _} = Coordinator.add_member(group["group_id"], %{"session_id" => "stub-worker"})

    assert {:ok, task} =
             Coordinator.create_task(group["group_id"], %{
               "created_by_session_id" => "parent",
               "assigned_session_id" => "stub-worker",
               "title" => "跑回归",
               "description" => "执行 mix test",
               "command_id" => "d1"
             })

    task_id = task["task_id"]
    assert_receive {:stub_got, "stub-worker", {:collaboration_task, delivered}}, 1_000
    assert %{"task_id" => ^task_id, "assigned_session_id" => "stub-worker"} = delivered

    # 分派只发生一次：更新状态不再重复投递
    assert {:ok, _} =
             Coordinator.update_task(group["group_id"], task_id, %{
               "session_id" => "parent",
               "status" => "cancelled",
               "command_id" => "d2"
             })

    refute_receive {:stub_got, _, {:collaboration_task, _}}, 200
  end

  test "Tools.Collaboration.report 更新任务并校验状态" do
    assert {:ok, group} = Coordinator.create_group(%{"session_id" => "p", "title" => "工具群"})
    gid = group["group_id"]
    assert {:ok, _} = Coordinator.add_member(gid, %{"session_id" => "w"})

    assert {:ok, task} =
             Coordinator.create_task(gid, %{
               "created_by_session_id" => "p",
               "assigned_session_id" => "w",
               "title" => "T"
             })

    tid = task["task_id"]

    assert {:error, "bad_request", _} =
             Newbee.Tools.Collaboration.report(gid, tid, "w", :nonsense)

    assert {:ok, updated} =
             Newbee.Tools.Collaboration.report(gid, tid, "w", :running, progress: "30%")

    assert updated["status"] == "running"
    assert updated["progress"] == "30%"

    assert {:ok, [%{"status" => "running"}]} = Newbee.Tools.Collaboration.tasks(gid)

    msg_opts = [to: "p", kind: :question, message_id: "msg-tool-fixed"]

    assert {:ok, _} = Newbee.Tools.Collaboration.send_message(gid, "w", "我开始了", msg_opts)

    assert {:error, "duplicate_message", _} =
             Newbee.Tools.Collaboration.send_message(gid, "w", "重试同一条", msg_opts)
  end

  test "任务进入终态时创建者会话收到一次结构化结果通知" do
    {:ok, parent_stub} = DispatchStub.start_link("parent", self())

    assert {:ok, group} = Coordinator.create_group(%{"session_id" => "parent", "title" => "结果群"})
    gid = group["group_id"]
    assert {:ok, _} = Coordinator.add_member(gid, %{"session_id" => "worker2"})

    assert {:ok, task} =
             Coordinator.create_task(gid, %{
               "created_by_session_id" => "parent",
               "assigned_session_id" => "worker2",
               "title" => "T",
               "command_id" => "r1"
             })

    tid = task["task_id"]

    # assigned worker2 无进程：分派静默跳过；父桩收到的是 parent 自己的被分派任务
    assert {:ok, running} =
             Coordinator.update_task(gid, tid, %{
               "session_id" => "worker2",
               "status" => "running",
               "command_id" => "r2"
             })

    assert running["status"] == "running"
    refute_receive {:stub_got, _, {:collaboration_result, _}}, 200

    assert {:ok, done} =
             Coordinator.update_task(gid, tid, %{
               "session_id" => "worker2",
               "status" => "succeeded",
               "result" => "OK",
               "command_id" => "r3"
             })

    assert done["status"] == "succeeded"
    assert_receive {:stub_got, "parent", {:collaboration_result, notified}}, 1_000
    assert notified["task_id"] == tid
    assert notified["status"] == "succeeded"
    Process.exit(parent_stub, :kill)
  end
end
