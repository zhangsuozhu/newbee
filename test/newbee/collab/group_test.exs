defmodule Newbee.Collab.GroupTest do
  use ExUnit.Case, async: false

  alias Newbee.Collab.Group

  setup do
    root = Path.join(System.tmp_dir!(), "hive-test-#{System.unique_integer([:positive])}")
    path = Path.join(root, "events.jsonl")
    name = String.to_atom("hive_test_#{System.unique_integer([:positive])}")
    {:ok, pid} = Group.start_link(name: name, path: path, durability: :event)

    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid)
      File.rm_rf!(root)
    end)

    {:ok, group} =
      Group.create_group(
        %{
          "session_id" => "lead-s1",
          "title" => "测试协作",
          "goal" => "覆盖核心",
          "command_id" => "g1",
          "max_depth" => 3,
          "max_total" => 8
        },
        name
      )

    %{server: name, gid: group["group_id"], path: path, root: root}
  end

  describe "组与成员" do
    test "建组后 lead 在名册", %{server: s, gid: gid} do
      assert {:ok, roster} = Group.roster(gid, s)
      assert [%{"name" => "lead", "role" => "lead", "depth" => 0}] = roster
    end

    test "join 成员并去重名字", %{server: s, gid: gid} do
      {:ok, m1} = Group.join(gid, %{"session_id" => "w1", "name" => "worker", "command_id" => "j1"}, s)
      {:ok, m2} = Group.join(gid, %{"session_id" => "w2", "name" => "worker", "command_id" => "j2"}, s)
      assert m1["name"] == "worker"
      assert m2["name"] == "worker-2"
    end

    test "重复 join 同会话被拒", %{server: s, gid: gid} do
      {:ok, _} = Group.join(gid, %{"session_id" => "w1", "command_id" => "j1"}, s)
      assert {:error, "conflict", _} = Group.join(gid, %{"session_id" => "w1", "command_id" => "j2"}, s)
    end

    test "深度硬墙", %{server: s, gid: gid} do
      assert {:error, "depth_limit", _} =
               Group.join(gid, %{"session_id" => "deep", "depth" => 5, "command_id" => "jd"}, s)
    end

    test "总数硬墙", %{server: s, gid: gid} do
      for i <- 1..7 do
        {:ok, _} = Group.join(gid, %{"session_id" => "w#{i}", "command_id" => "j#{i}"}, s)
      end

      assert {:error, "limit", _} = Group.join(gid, %{"session_id" => "overflow", "command_id" => "jx"}, s)
    end

    test "崩溃重放恢复名册与板", %{server: s, gid: gid, path: path} do
      {:ok, _} = Group.join(gid, %{"session_id" => "w1", "command_id" => "j1"}, s)
      {:ok, _} = Group.board_put(gid, %{"task_id" => "t1", "title" => "任务一"}, s)
      GenServer.stop(s)

      name2 = String.to_atom("hive_replay_#{System.unique_integer([:positive])}")
      {:ok, pid2} = Group.start_link(name: name2, path: path, durability: :event)
      on_exit(fn -> if Process.alive?(pid2), do: GenServer.stop(pid2) end)

      assert {:ok, roster} = Group.roster(gid, name2)
      assert length(roster) == 2
      assert {:ok, board} = Group.board_read(gid, name2)
      assert Enum.any?(board["tasks"], &(&1["task_id"] == "t1"))
    end
  end

  describe "黑板 CAS 与 DAG" do
    test "CAS 版本冲突被拒", %{server: s, gid: gid} do
      {:ok, %{"revision" => r1}} = Group.board_put(gid, %{"task_id" => "t1", "title" => "A"}, s)
      assert {:error, "revision_conflict", _} =
               Group.board_put(gid, %{"task_id" => "t2", "title" => "B", "expected_revision" => r1 + 5}, s)
    end

    test "认领成功改 owner，重复认领被拒", %{server: s, gid: gid} do
      {:ok, _} = Group.board_put(gid, %{"task_id" => "t1", "title" => "A"}, s)
      {:ok, %{"task" => t}} = Group.board_claim(gid, "t1", "w1", nil, s)
      assert t["owner"] == "w1"
      assert {:error, "conflict", _} = Group.board_claim(gid, "t1", "w2", nil, s)
    end

    test "DAG 依赖拒环", %{server: s, gid: gid} do
      {:ok, _} = Group.board_put(gid, %{"task_id" => "a", "title" => "A"}, s)
      {:ok, _} = Group.board_put(gid, %{"task_id" => "b", "title" => "B", "depends_on" => ["a"]}, s)
      assert {:error, "cycle", _} = Group.board_add_dep(gid, "a", "b", nil, "lead-s1", s)
    end

    test "writeScope 重叠产生诊断警告", %{server: s, gid: gid} do
      {:ok, _} = Group.board_put(gid, %{"task_id" => "a", "write_scope" => ["lib/auth/"]}, s)
      {:ok, %{"warnings" => w}} = Group.board_put(gid, %{"task_id" => "b", "write_scope" => ["lib/auth/token.ex"]}, s)
      assert w != []
    end
  end

  describe "信箱与 wait 边沿触发" do
    test "消息投递+未 ack 可见", %{server: s, gid: gid} do
      {:ok, _} = Group.join(gid, %{"session_id" => "w1", "command_id" => "j1"}, s)

      {:ok, msg} =
        Group.send_message(gid, %{"from_session_id" => "lead-s1", "to_session_id" => "w1", "body" => "开工"}, s)

      assert msg["wake"] == false
      {:ok, box} = Group.inbox(gid, "w1", [], s)
      assert length(box) == 1

      :ok = Group.ack(gid, "w1", msg["message_id"], s)
      {:ok, box2} = Group.inbox(gid, "w1", [], s)
      assert box2 == []
    end

    test "非成员发信被拒", %{server: s, gid: gid} do
      {:ok, _} = Group.join(gid, %{"session_id" => "w1", "command_id" => "j1"}, s)

      assert {:error, "not_member", _} =
               Group.send_message(gid, %{"from_session_id" => "outsider", "to_session_id" => "w1", "body" => "hi"}, s)
    end

    test "wait 边沿触发：板变化即唤醒", %{server: s, gid: gid} do
      {:ok, %{"revision" => r0}} = Group.board_read(gid, s)

      task =
        Task.async(fn ->
          Group.wait(gid, r0, "lead-s1", 5_000, s)
        end)

      Process.sleep(50)
      {:ok, _} = Group.board_put(gid, %{"task_id" => "t1", "title" => "唤醒"}, s)

      assert {:ok, %{"kind" => "edge", "revision" => r1}} = Task.await(task, 6_000)
      assert r1 > r0
    end

    test "wait 边沿触发：来信即唤醒", %{server: s, gid: gid} do
      {:ok, _} = Group.join(gid, %{"session_id" => "w1", "command_id" => "j1"}, s)
      {:ok, %{"revision" => r0}} = Group.board_read(gid, s)

      task =
        Task.async(fn ->
          Group.wait(gid, r0, "w1", 5_000, s)
        end)

      Process.sleep(50)

      {:ok, _} =
        Group.send_message(gid, %{"from_session_id" => "lead-s1", "to_session_id" => "w1", "body" => "醒"}, s)

      assert {:ok, %{"kind" => "edge", "pending_mail" => 1}} = Task.await(task, 6_000)
    end

    test "wait 超时返回 timeout", %{server: s, gid: gid} do
      {:ok, %{"revision" => r0}} = Group.board_read(gid, s)
      assert {:ok, %{"kind" => "timeout"}} = Group.wait(gid, r0, "lead-s1", 1_000, s)
    end
  end
end
