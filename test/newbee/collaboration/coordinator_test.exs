defmodule Newbee.Collaboration.SilentStub do
  @moduledoc false
  use GenServer

  def start_link(name) do
    GenServer.start_link(__MODULE__, :ok, name: name)
  end

  @impl true
  def init(:ok), do: {:ok, :ok}

  @impl true
  def handle_cast(_msg, state), do: {:noreply, state}

  @impl true
  def handle_info(_msg, state), do: {:noreply, state}
end

defmodule Newbee.Collaboration.CoordinatorTest do
  use ExUnit.Case, async: false

  alias Newbee.Collaboration.Coordinator

  setup do
    root = Path.join(System.tmp_dir!(), "newbee-collab-#{System.unique_integer([:positive])}")
    path = Path.join(root, "events.jsonl")
    name = String.to_atom("collab_test_#{System.unique_integer([:positive])}")
    {:ok, pid} = Coordinator.start_link(name: name, path: path, durability: :event)

    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid)
      File.rm_rf!(root)
    end)

    %{server: name, pid: pid, path: path}
  end

  test "创建群、添加成员并双向发送可靠消息", %{server: server} do
    assert {:ok, group} =
             Coordinator.create_group(
               %{
                 "session_id" => "session-a",
                 "title" => "认证重构",
                 "goal" => "完成认证重构",
                 "command_id" => "create-1"
               },
               server
             )

    group_id = group["group_id"]
    assert group["coordinator_session_id"] == "session-a"
    assert Coordinator.member?(group_id, "session-a", server)

    assert {:ok, member} =
             Coordinator.add_member(
               group_id,
               %{
                 "session_id" => "session-b",
                 "role" => "worker",
                 "parent_session_id" => "session-a",
                 "command_id" => "member-1"
               },
               server
             )

    assert member["session_id"] == "session-b"

    assert {:ok, first} =
             Coordinator.send_message(
               group_id,
               %{
                 "sender_session_id" => "session-a",
                 "to_session_id" => "session-b",
                 "body" => "请检查认证测试",
                 "command_id" => "message-1"
               },
               server
             )

    assert first["seq"] == 1

    assert {:ok, second} =
             Coordinator.send_message(
               group_id,
               %{
                 "sender_session_id" => "session-b",
                 "to_session_id" => "session-a",
                 "body" => "测试已通过",
                 "kind" => "task_result",
                 "command_id" => "message-2"
               },
               server
             )

    assert second["seq"] == 2
    assert {:ok, [^first, ^second]} = Coordinator.messages(group_id, [], server)
  end

  test "命令幂等且非成员不能发消息", %{server: server} do
    attrs = %{
      "session_id" => "session-a",
      "title" => "群组",
      "command_id" => "create-once"
    }

    assert {:ok, group} = Coordinator.create_group(attrs, server)
    assert {:error, "duplicate_command", _} = Coordinator.create_group(attrs, server)

    assert {:error, "not_member", _} =
             Coordinator.send_message(
               group["group_id"],
               %{"sender_session_id" => "outsider", "body" => "越权消息"},
               server
             )
  end

  test "重启后从 EventStore 恢复群组、成员和消息", %{server: server, pid: pid, path: path} do
    assert {:ok, group} =
             Coordinator.create_group(
               %{"session_id" => "session-a", "goal" => "恢复测试"},
               server
             )

    group_id = group["group_id"]
    assert {:ok, _} = Coordinator.add_member(group_id, %{"session_id" => "session-b"}, server)

    assert {:ok, _} =
             Coordinator.send_message(group_id, %{"sender_session_id" => "session-a", "body" => "持久消息"}, server)

    GenServer.stop(pid)
    {:ok, restored} = Coordinator.start_link(name: server, path: path, durability: :event)

    assert {:ok, recovered} = Coordinator.get(group_id, server)
    assert length(recovered["members"]) == 2
    assert {:ok, [%{"body" => "持久消息", "seq" => 1}]} = Coordinator.messages(group_id, [], server)

    GenServer.stop(restored)
  end

  test "重放旧版 delegated 事件时补齐累计派生字段", %{
    server: server,
    pid: pid,
    path: path
  } do
    GenServer.stop(pid)
    now = DateTime.utc_now() |> DateTime.to_iso8601()
    group_id = "legacy-replay-group"

    old_group = %{
      "group_id" => group_id,
      "title" => "legacy",
      "goal" => "legacy",
      "status" => "running",
      "coordinator_session_id" => "parent",
      "project_root" => File.cwd!(),
      "members" => [
        %{
          "session_id" => "parent",
          "role" => "coordinator",
          "parent_session_id" => nil,
          "joined_at" => now
        }
      ],
      "messages" => [],
      "tasks" => [],
      "next_seq" => 0,
      "created_at" => now,
      "updated_at" => now
    }

    member = %{
      "session_id" => "legacy-child",
      "role" => "worker",
      "parent_session_id" => "parent",
      "joined_at" => now
    }

    task = %{
      "task_id" => "legacy-task",
      "group_id" => group_id,
      "title" => "old delegated task",
      "description" => "old delegated task",
      "acceptance" => [],
      "created_by_session_id" => "parent",
      "assigned_session_id" => "legacy-child",
      "status" => "assigned",
      "created_at" => now,
      "updated_at" => now
    }

    {:ok, store} = Newbee.EventStore.start_link(path: path, durability: :event)

    {:ok, _} =
      Newbee.EventStore.append(store, :collab_group_created, %{
        "command_id" => nil,
        "payload" => %{"group" => old_group}
      })

    {:ok, _} =
      Newbee.EventStore.append(store, :collab_delegated, %{
        "group_id" => group_id,
        "command_id" => "legacy-delegate",
        "payload" => %{"member" => member, "task" => task}
      })

    GenServer.stop(store)
    {:ok, restored} = Coordinator.start_link(name: server, path: path, durability: :event)
    assert {:ok, recovered} = Coordinator.get(group_id, server)
    assert recovered["total_spawned"] == 2
    assert recovered["revision"] == 2
    assert Enum.any?(recovered["members"], &(&1["session_id"] == "legacy-child"))
    GenServer.stop(restored)
  end

  test "移出成员保护 Hive 任务和父子关系，并在重启后保持结果", %{
    server: server,
    pid: pid,
    path: path
  } do
    assert {:ok, group} =
             Coordinator.create_group(%{"session_id" => "parent", "title" => "成员生命周期"}, server)

    group_id = group["group_id"]

    {:ok, _} = Newbee.Collaboration.SilentStub.start_link({:via, Registry, {Newbee.Web.SessionRegistry, "worker"}})
    {:ok, _} = Newbee.Collaboration.SilentStub.start_link({:via, Registry, {Newbee.Web.SessionRegistry, "reviewer"}})

    assert {:ok, _} =
             Coordinator.add_member(
               group_id,
               %{
                 "session_id" => "worker",
                 "parent_session_id" => "parent"
               },
               server
             )

    assert {:ok, _} =
             Coordinator.add_member(
               group_id,
               %{
                 "session_id" => "reviewer",
                 "parent_session_id" => "worker"
               },
               server
             )

    assert {:error, "forbidden_role", _} =
             Coordinator.remove_member(
               group_id,
               %{"session_id" => "reviewer", "actor_session_id" => "worker"},
               server
             )

    assert {:error, "member_has_children", _} =
             Coordinator.remove_member(
               group_id,
               %{"session_id" => "parent", "actor_session_id" => "parent"},
               server
             )

    assert {:error, "member_has_children", _} =
             Coordinator.remove_member(
               group_id,
               %{"session_id" => "worker", "actor_session_id" => "parent"},
               server
             )

    assert {:ok, _} =
             Coordinator.remove_member(
               group_id,
               %{"session_id" => "reviewer", "actor_session_id" => "parent"},
               server
             )

    assert {:ok, task} =
             board_create_task(server, group_id, %{
               "created_by_session_id" => "parent",
               "assigned_session_id" => "worker",
               "title" => "进行中的 Hive 工作"
             })

    assert {:error, "member_has_active_tasks", _} =
             Coordinator.remove_member(
               group_id,
               %{"session_id" => "worker", "actor_session_id" => "parent"},
               server
             )

    assert {:ok, cancelled} =
             board_update_task(server, group_id, task["task_id"], %{
               "session_id" => "parent",
               "status" => "cancelled"
             })

    assert cancelled["status"] == "cancelled"

    assert {:ok, removed} =
             Coordinator.remove_member(
               group_id,
               %{
                 "session_id" => "worker",
                 "actor_session_id" => "parent",
                 "command_id" => "remove-worker"
               },
               server
             )

    assert removed["session_id"] == "worker"
    refute Coordinator.member?(group_id, "worker", server)

    GenServer.stop(pid)
    {:ok, restored} = Coordinator.start_link(name: server, path: path, durability: :event)
    refute Coordinator.member?(group_id, "worker", server)
    GenServer.stop(restored)
  end

  test "权限请求只广播给直接父会话和总控", %{server: server} do
    assert {:ok, group} = Coordinator.create_group(%{"session_id" => "parent", "title" => "审批群"}, server)
    group_id = group["group_id"]

    assert {:ok, _} =
             Coordinator.add_member(group_id, %{"session_id" => "manager", "parent_session_id" => "parent"}, server)

    assert {:ok, _} =
             Coordinator.add_member(group_id, %{"session_id" => "child", "parent_session_id" => "manager"}, server)

    assert {:ok, _} =
             Coordinator.add_member(group_id, %{"session_id" => "sibling", "parent_session_id" => "parent"}, server)

    Newbee.Bus.subscribe()
    assert :ok = Coordinator.permission_request("child", "执行写文件", server)

    assert_receive {:newbee_event, :collab_event, event}, 1_000
    assert event["topic"] == "collab_permission_ask"
    assert event["payload"]["request_session_id"] == "child"
    assert Enum.sort(event["session_ids"]) == ["manager", "parent"]
    assert Enum.sort(event["payload"]["approver_session_ids"]) == ["manager", "parent"]
    refute "sibling" in event["session_ids"]

    assert {:error, "not_member", _} = Coordinator.permission_request("outsider", "x", server)
    Newbee.Bus.unsubscribe()
  end

  test "原子 Hive 委派事件同时持久化成员、任务和工作区，重放不产生半状态", %{
    server: server,
    path: path
  } do
    assert {:ok, group} =
             Coordinator.create_group(
               %{"session_id" => "parent", "title" => "原子派生"},
               server
             )

    workspace = %{
      "kind" => "git_worktree",
      "root" => File.cwd!(),
      "path" => File.cwd!(),
      "base_ref" => String.duplicate("a", 40),
      "review_status" => "pending",
      "reviewed_at" => nil,
      "reviewed_by_session_id" => nil
    }

    attrs = %{
      "session_id" => "child",
      "parent_session_id" => "parent",
      "role" => "worker",
      "protocol_version" => 2,
      "title" => "实现功能",
      "acceptance" => [%{"kind" => "file_exists", "path" => "mix.exs"}],
      "depends_on" => [],
      "write_scope" => [],
      "expected_revision" => group["revision"],
      "workspace" => workspace,
      "command_id" => "delegate-atomic"
    }

    assert {:ok, %{member: member, task: task}} = Coordinator.delegate(group["group_id"], attrs, server)
    assert member["workspace"] == workspace
    assert task["workspace"] == workspace
    assert task["protocol_version"] == 2

    {:ok, after_delegate} = Coordinator.board(group["group_id"], "parent", server)

    assert {:error, "duplicate_command", _} =
             Coordinator.delegate(
               group["group_id"],
               %{attrs | "session_id" => "other", "expected_revision" => after_delegate["revision"]},
               server
             )

    assert {:ok, %{"task" => running, "revision" => running_revision}} =
             Coordinator.board_update_task(
               group["group_id"],
               task["task_id"],
               %{
                 "session_id" => "child",
                 "expected_revision" => task["board_revision"],
                 "status" => "running",
                 "command_id" => "run-atomic"
               },
               server
             )

    assert running["status"] == "running"

    assert {:ok, %{"task" => submitted, "revision" => _submitted_revision}} =
             Coordinator.board_update_task(
               group["group_id"],
               task["task_id"],
               %{
                 "session_id" => "child",
                 "expected_revision" => running_revision,
                 "status" => "submitted",
                 "result" => "ready",
                 "command_id" => "submit-atomic"
               },
               server
             )

    assert submitted["status"] == "submitted"
    assert submitted["workspace"]["review_status"] == "pending"

    assert {:error, "forbidden_role", _} =
             Coordinator.update_workspace(
               group["group_id"],
               task["task_id"],
               %{
                 "actor_session_id" => "child",
                 "action" => "rejected"
               },
               server
             )

    assert {:ok, reviewed} =
             Coordinator.update_workspace(
               group["group_id"],
               task["task_id"],
               %{
                 "actor_session_id" => "parent",
                 "action" => "rejected",
                 "patch_sha256" => String.duplicate("b", 64)
               },
               server
             )

    assert reviewed["workspace"]["review_status"] == "rejected"
    assert reviewed["workspace"]["patch_sha256"] == String.duplicate("b", 64)

    GenServer.stop(Process.whereis(server))
    {:ok, restored} = Coordinator.start_link(name: server, path: path, durability: :event)
    assert {:ok, detail} = Coordinator.get(group["group_id"], server)
    assert Enum.any?(detail["members"], &(&1["session_id"] == "child"))
    assert [%{"workspace" => restored_workspace}] = detail["tasks"]
    assert restored_workspace["review_status"] == "rejected"
    GenServer.stop(restored)
  end

  test "delete_group 保留 Hive 孤儿任务直到显式取消", %{server: server} do
    assert {:ok, group} =
             Coordinator.create_group(%{"session_id" => "parent", "title" => "孤儿删组"}, server)

    group_id = group["group_id"]

    assert {:ok, _} =
             Coordinator.add_member(
               group_id,
               %{"session_id" => "ghost-worker", "parent_session_id" => "parent"},
               server
             )

    assert {:ok, task} =
             board_create_task(server, group_id, %{
               "created_by_session_id" => "parent",
               "assigned_session_id" => "ghost-worker",
               "title" => "可恢复的 Hive 任务"
             })

    assert task["status"] == "assigned"
    assert {:error, "busy", _} = Coordinator.delete_group(group_id, "parent", server)

    assert {:ok, cancelled} =
             board_update_task(server, group_id, task["task_id"], %{
               "session_id" => "parent",
               "status" => "cancelled"
             })

    assert cancelled["status"] == "cancelled"
    assert {:ok, %{"group_id" => ^group_id}} = Coordinator.delete_group(group_id, "parent", server)
    assert {:error, "not_found", _} = Coordinator.get(group_id, server)
  end

  test "活跃会话的 Hive 任务仍阻止删除", %{server: server} do
    assert {:ok, group} =
             Coordinator.create_group(%{"session_id" => "parent", "title" => "活任务保护"}, server)

    group_id = group["group_id"]

    assert {:ok, _} =
             Coordinator.add_member(
               group_id,
               %{"session_id" => "stub-alive", "parent_session_id" => "parent"},
               server
             )

    {:ok, stub} =
      Newbee.Collaboration.SilentStub.start_link({:via, Registry, {Newbee.Web.SessionRegistry, "stub-alive"}})

    assert {:ok, task} =
             board_create_task(server, group_id, %{
               "created_by_session_id" => "parent",
               "assigned_session_id" => "stub-alive",
               "title" => "真活任务"
             })

    assert task["status"] == "assigned"
    assert {:error, "busy", _} = Coordinator.delete_group(group_id, "parent", server)

    GenServer.stop(stub)
  end

  test "remove_member 保留 Hive 孤儿任务直到显式取消", %{server: server} do
    assert {:ok, group} =
             Coordinator.create_group(%{"session_id" => "parent", "title" => "孤儿移除"}, server)

    group_id = group["group_id"]

    assert {:ok, _} =
             Coordinator.add_member(
               group_id,
               %{"session_id" => "ghost-2", "parent_session_id" => "parent"},
               server
             )

    assert {:ok, task} =
             board_create_task(server, group_id, %{
               "created_by_session_id" => "parent",
               "assigned_session_id" => "ghost-2",
               "title" => "可恢复的 Hive 任务二"
             })

    assert {:error, "member_has_active_tasks", _} =
             Coordinator.remove_member(
               group_id,
               %{"session_id" => "ghost-2", "actor_session_id" => "parent"},
               server
             )

    assert {:ok, _cancelled} =
             board_update_task(server, group_id, task["task_id"], %{
               "session_id" => "parent",
               "status" => "cancelled"
             })

    assert {:ok, _removed} =
             Coordinator.remove_member(
               group_id,
               %{"session_id" => "ghost-2", "actor_session_id" => "parent"},
               server
             )

    refute Coordinator.member?(group_id, "ghost-2", server)
  end

  test "Board claim 后由 worker submitted，Lead verify 才能完成", %{server: server} do
    assert {:ok, group} =
             Coordinator.create_group(
               %{
                 "session_id" => "parent",
                 "title" => "Hive lease 测试",
                 "project_root" => File.cwd!()
               },
               server
             )

    group_id = group["group_id"]
    assert {:ok, _} = Coordinator.add_member(group_id, %{"session_id" => "child"}, server)

    assert {:ok, task} =
             board_create_task(server, group_id, %{
               "created_by_session_id" => "parent",
               "assigned_session_id" => "child",
               "title" => "短任务"
             })

    assert {:ok, claimed} = board_claim_task(server, group_id, task["task_id"], "child")
    assert claimed["lease_owner"] == "child"

    assert {:ok, submitted} =
             board_update_task(server, group_id, task["task_id"], %{
               "session_id" => "child",
               "status" => "submitted",
               "result" => "done"
             })

    assert submitted["status"] == "submitted"

    {:ok, submitted_board} = Coordinator.board(group_id, "parent", server)

    assert {:ok, verified} =
             Coordinator.board_verify(
               group_id,
               task["task_id"],
               %{
                 "session_id" => "parent",
                 "expected_revision" => submitted_board["revision"],
                 "command_id" => "verify-short"
               },
               server
             )

    assert verified["task"]["status"] == "succeeded"

    assert {:ok, accepted_task} =
             board_create_task(server, group_id, %{
               "created_by_session_id" => "parent",
               "assigned_session_id" => "child",
               "title" => "直接完成"
             })

    assert {:ok, accepted} =
             board_update_task(server, group_id, accepted_task["task_id"], %{
               "session_id" => "child",
               "status" => "accepted"
             })

    assert accepted["status"] == "accepted"

    assert {:ok, accepted_submitted} =
             board_update_task(server, group_id, accepted_task["task_id"], %{
               "session_id" => "child",
               "status" => "submitted",
               "result" => "accepted done"
             })

    assert accepted_submitted["status"] == "submitted"
    {:ok, accepted_board} = Coordinator.board(group_id, "parent", server)

    assert {:ok, accepted_verified} =
             Coordinator.board_verify(
               group_id,
               accepted_task["task_id"],
               %{
                 "session_id" => "parent",
                 "expected_revision" => accepted_board["revision"],
                 "command_id" => "verify-accepted"
               },
               server
             )

    assert accepted_verified["task"]["status"] == "succeeded"
  end

  defp board_create_task(server, group_id, attrs) do
    actor = attrs["created_by_session_id"] || attrs["session_id"] || "parent"
    {:ok, board} = Coordinator.board(group_id, actor, server)

    defaults = %{
      "session_id" => actor,
      "title" => "Hive task",
      "acceptance" => [%{"kind" => "file_exists", "path" => "mix.exs"}],
      "depends_on" => [],
      "write_scope" => [],
      "expected_revision" => board["revision"],
      "command_id" => command_id("board-create")
    }

    attrs = Map.drop(attrs, ["created_by_session_id"])

    case Coordinator.board_create_task(group_id, Map.merge(defaults, attrs), server) do
      {:ok, %{"task" => task}} -> {:ok, task}
      other -> other
    end
  end

  defp board_update_task(server, group_id, task_id, attrs) do
    actor = attrs["session_id"] || "parent"
    {:ok, board} = Coordinator.board(group_id, actor, server)

    defaults = %{
      "session_id" => actor,
      "expected_revision" => board["revision"],
      "command_id" => command_id("board-update")
    }

    case Coordinator.board_update_task(group_id, task_id, Map.merge(defaults, attrs), server) do
      {:ok, %{"task" => task}} -> {:ok, task}
      other -> other
    end
  end

  defp board_claim_task(server, group_id, task_id, session_id) do
    {:ok, board} = Coordinator.board(group_id, session_id, server)

    case Coordinator.board_claim(
           group_id,
           task_id,
           %{
             "session_id" => session_id,
             "expected_revision" => board["revision"],
             "command_id" => command_id("board-claim")
           },
           server
         ) do
      {:ok, %{"task" => task}} -> {:ok, task}
      other -> other
    end
  end

  defp command_id(prefix), do: prefix <> "-" <> Integer.to_string(System.unique_integer([:positive]))
end
