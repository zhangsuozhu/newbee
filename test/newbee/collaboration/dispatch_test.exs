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
  alias Newbee.Tools.Hive

  setup do
    case Process.whereis(Coordinator) do
      nil -> :ok
      pid -> GenServer.stop(pid)
    end

    root =
      Path.join(System.tmp_dir!(), "newbee-collab-dispatch-" <> Integer.to_string(System.unique_integer([:positive])))

    {:ok, coord} = Coordinator.start_link(path: Path.join(root, "events.jsonl"), durability: :event)
    {:ok, stub} = DispatchStub.start_link("stub-worker", self())

    on_exit(fn ->
      if Process.alive?(coord), do: GenServer.stop(coord)
      if Process.alive?(stub), do: Process.exit(stub, :kill)
      File.rm_rf!(root)
    end)

    %{}
  end

  test "创建并分派 Hive 任务时，目标会话收到一次 task 投递" do
    assert {:ok, group} =
             Coordinator.create_group(%{
               "session_id" => "parent",
               "title" => "分派群",
               "project_root" => File.cwd!(),
               "command_id" => "dispatch-open"
             })

    gid = group["group_id"]
    assert {:ok, _} = Coordinator.add_member(gid, %{"session_id" => "stub-worker"})
    assert {:ok, board} = Coordinator.board(gid, "parent")

    acceptance = [%{"kind" => "file_exists", "path" => "mix.exs"}]

    assert {:ok, %{"task" => task, "revision" => revision}} =
             Coordinator.board_create_task(
               gid,
               %{
                 "session_id" => "parent",
                 "assigned_session_id" => "stub-worker",
                 "title" => "跑回归",
                 "description" => "执行 mix test",
                 "acceptance" => acceptance,
                 "expected_revision" => board["revision"],
                 "command_id" => "dispatch-task"
               }
             )

    task_id = task["task_id"]
    assert_receive {:stub_got, "stub-worker", {:collaboration_task, delivered}}, 1_000
    assert %{"task_id" => ^task_id, "assigned_session_id" => "stub-worker", "protocol_version" => 2} = delivered
    assert delivered["acceptance"] == [%{"id" => 1, "kind" => "file_exists", "path" => "mix.exs"}]

    assert {:error, "revision_conflict", _} =
             Coordinator.board_update_task(gid, task_id, %{
               "session_id" => "parent",
               "status" => "cancelled",
               "expected_revision" => board["revision"],
               "command_id" => "dispatch-stale"
             })

    assert {:ok, %{"task" => cancelled}} =
             Coordinator.board_update_task(gid, task_id, %{
               "session_id" => "parent",
               "status" => "cancelled",
               "expected_revision" => revision,
               "command_id" => "dispatch-cancel"
             })

    assert cancelled["status"] == "cancelled"
    refute_receive {:stub_got, _, {:collaboration_task, _}}, 200
  end

  test "无 token 时 Hive delegate 拒绝派生子代理" do
    assert {:error, "no_execution_context", _} =
             Hive.delegate("missing-group", "无上下文任务", acceptance: [%{"kind" => "file_exists", "path" => "mix.exs"}])
  end

  test "Hive delegate 使用调用方身份、结构化验收和 protocol v2" do
    assert {:ok, result} =
             with_identity("model-parent", File.cwd!(), fn ->
               {:ok, group} = Hive.open("delegate group", max_depth: 1, max_total: 3)

               Hive.delegate(group["group_id"], "分析认证失败路径",
                 name: "认证分析子代理",
                 description: "找出失败路径并给出测试建议",
                 persona: "reviewer",
                 acceptance: [%{"kind" => "file_exists", "path" => "mix.exs"}],
                 isolate: false
               )
             end)

    assert is_binary(result.session_id)
    assert result.member["parent_session_id"] == "model-parent"
    assert result.member["role"] == "reviewer"
    assert result.task["assigned_session_id"] == result.session_id
    assert result.task["protocol_version"] == 2
    assert is_binary(result.task["acceptance_sha256"])

    on_exit(fn -> Newbee.Web.Session.destroy(result.session_id) end)
  end

  test "Hive report 使用 revision CAS 并通过 Hive send/inbox 传递消息" do
    assert {:ok, group} =
             Coordinator.create_group(%{
               "session_id" => "p",
               "title" => "工具群",
               "project_root" => File.cwd!(),
               "command_id" => "report-open"
             })

    gid = group["group_id"]
    assert {:ok, _} = Coordinator.add_member(gid, %{"session_id" => "w"})
    assert {:ok, board} = Coordinator.board(gid, "p")

    assert {:ok, %{"task" => task, "revision" => revision}} =
             Coordinator.board_create_task(
               gid,
               %{
                 "session_id" => "p",
                 "assigned_session_id" => "w",
                 "title" => "T",
                 "acceptance" => [%{"kind" => "file_exists", "path" => "mix.exs"}],
                 "expected_revision" => board["revision"],
                 "command_id" => "report-task"
               }
             )

    tid = task["task_id"]

    with_identity("w", File.cwd!(), fn ->
      assert {:error, "bad_request", _} = Hive.report(gid, tid, "nonsense", expected_revision: revision)

      assert {:ok, %{"task" => updated, "revision" => running_revision}} =
               Hive.report(gid, tid, "running",
                 expected_revision: revision,
                 progress: "30%",
                 command_id: "report-running"
               )

      assert updated["status"] == "running"
      assert updated["progress"] == "30%"

      assert {:ok, _} =
               Hive.send(gid, "p", "我开始了",
                 kind: :question,
                 message_id: "msg-tool-fixed",
                 command_id: "message-tool-fixed"
               )

      assert {:error, "duplicate_message", _} =
               Hive.send(gid, "p", "重试同一条",
                 kind: :question,
                 message_id: "msg-tool-fixed",
                 command_id: "message-tool-duplicate"
               )

      assert running_revision > revision
    end)

    with_identity("p", File.cwd!(), fn ->
      assert {:ok,
              %{
                "messages" => [%{"sender_session_id" => "w", "to_session_id" => "p", "body" => "我开始了"}],
                "last_seq" => _
              }} =
               Hive.inbox(gid)
    end)
  end

  test "worker 只能 submitted，Lead verify 后才能 succeeded" do
    assert {:ok, group} =
             Coordinator.create_group(%{
               "session_id" => "lead",
               "title" => "结果群",
               "project_root" => File.cwd!(),
               "command_id" => "verify-open"
             })

    gid = group["group_id"]
    assert {:ok, _} = Coordinator.add_member(gid, %{"session_id" => "worker2"})
    assert {:ok, board} = Coordinator.board(gid, "lead")

    assert {:ok, %{"task" => task, "revision" => revision}} =
             Coordinator.board_create_task(
               gid,
               %{
                 "session_id" => "lead",
                 "assigned_session_id" => "worker2",
                 "title" => "T",
                 "acceptance" => [%{"kind" => "file_exists", "path" => "mix.exs"}],
                 "expected_revision" => board["revision"],
                 "command_id" => "verify-task"
               }
             )

    tid = task["task_id"]

    with_identity("worker2", File.cwd!(), fn ->
      assert {:ok, %{"task" => submitted, "revision" => submitted_revision}} =
               Hive.report(gid, tid, "submitted",
                 expected_revision: revision,
                 result: "mix.exs exists",
                 command_id: "verify-submit"
               )

      assert submitted["status"] == "submitted"

      assert {:error, "bad_request", _} =
               Hive.report(gid, tid, "succeeded",
                 expected_revision: submitted_revision,
                 command_id: "verify-self-certify"
               )
    end)

    with_identity("lead", File.cwd!(), fn ->
      assert {:ok, %{"task" => verified}} = Hive.verify(gid, tid)
      assert verified["status"] == "succeeded"
    end)
  end

  defp with_identity(session_id, root, fun) do
    :ok = Newbee.Collaboration.Capability.register(self(), session_id, root)
    {:ok, token} = Newbee.Collaboration.Capability.issue(self())
    Process.put({Newbee.Tools.Hive, :context}, %{capability: token})

    try do
      fun.()
    after
      Process.delete({Newbee.Tools.Hive, :context})
      Newbee.Collaboration.Capability.revoke(token)
    end
  end
end
