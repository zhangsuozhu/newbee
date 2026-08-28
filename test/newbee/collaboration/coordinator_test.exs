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

  test "移出成员保护任务和父子关系，并在重启后保持结果", %{
    server: server,
    pid: pid,
    path: path
  } do
    assert {:ok, group} =
             Coordinator.create_group(%{"session_id" => "parent", "title" => "成员生命周期"}, server)

    group_id = group["group_id"]

    assert {:ok, _} =
             Coordinator.add_member(
               group_id,
               %{"session_id" => "worker", "parent_session_id" => "parent"},
               server
             )

    assert {:ok, _} =
             Coordinator.add_member(
               group_id,
               %{"session_id" => "reviewer", "parent_session_id" => "worker"},
               server
             )

    assert {:error, "forbidden_role", _} =
             Coordinator.remove_member(
               group_id,
               %{"session_id" => "reviewer", "actor_session_id" => "worker"},
               server
             )

    assert {:error, "coordinator_required", _} =
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
             Coordinator.create_task(
               group_id,
               %{
                 "created_by_session_id" => "parent",
                 "assigned_session_id" => "worker",
                 "title" => "进行中的工作"
               },
               server
             )

    assert {:error, "member_has_active_tasks", _} =
             Coordinator.remove_member(
               group_id,
               %{"session_id" => "worker", "actor_session_id" => "parent"},
               server
             )

    assert {:ok, _} =
             Coordinator.update_task(
               group_id,
               task["task_id"],
               %{"session_id" => "parent", "status" => "cancelled"},
               server
             )

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
end
