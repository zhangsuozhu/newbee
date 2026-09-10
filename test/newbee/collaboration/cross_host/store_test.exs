defmodule Newbee.Collaboration.CrossHost.StoreTest do
  use ExUnit.Case, async: false
  alias Newbee.Collaboration.CrossHost.Store

  test "device status covers paused online offline with actionable hints" do
    Store.clear()
    now = 1_700_000_000_000

    assert %{"state" => "paused", "hint" => hint} =
             Store.device_status(%{"paused" => true, "last_seen" => now}, [%{"status" => "running"}], 0, now)

    assert hint =~ "恢复"

    assert %{"state" => "online", "remote" => true, "hint" => hint2} =
             Store.device_status(%{"paused" => false, "last_seen" => now - 1_000, "remote" => true}, [], 2, now)

    assert hint2 =~ "远端 Worker 连接正常"
    assert hint2 =~ "2 个任务待投递"

    assert %{"state" => "online", "hint" => hint3} =
             Store.device_status(%{"paused" => false, "remote" => true}, [], 1, now)

    assert hint3 =~ "等待首次心跳"

    assert %{"state" => "offline", "age_text" => age, "hint" => hint4} =
             Store.device_status(%{"paused" => false, "last_seen" => now - 300_000}, [], 0, now)

    assert age =~ "分钟前活跃"
    assert hint4 =~ "心跳超时"
  end

  test "group device statuses count assigned tasks and pending outbox" do
    Store.clear()

    Store.put_group(%{
      "id" => "g-status",
      "devices" => %{
        "d1" => %{"display" => "w1", "paused" => false, "last_seen" => 1_700_000_000_000, "remote" => true}
      }
    })

    Store.put_task(%{"id" => "t1", "group_id" => "g-status", "status" => "running", "assigned_device_id" => "d1"})
    assert {:ok, _} = Store.enqueue_delivery("g-status", "d1", %{"id" => "t1", "task_id" => "t1", "status" => "queued"})
    [st] = Store.group_device_statuses("g-status", 1_700_000_001_000)

    assert st["state"] == "online"
    assert st["active_tasks"] == 1
    assert st["pending"] == 1
  end

  test "restart restores groups tasks and pending outbox without plaintext tokens" do
    Store.clear()
    path = Store.persist_path()
    File.rm(path)

    on_exit(fn -> File.rm(path) end)

    Store.put_group(%{
      "id" => "g-persist",
      "name" => "重启恢复",
      "password" => %{"hash" => "hash-abc"},
      "devices" => %{"d1" => %{"display" => "w1", "plain" => "ONE-TIME-SECRET", "token_hash" => "th-1"}}
    })

    Store.put_task(%{"id" => "t1", "group_id" => "g-persist", "status" => "queued"})
    :ok = Store.bind_session(%{"session_id" => "s1", "group_id" => "g-persist", "device_id" => "d1"})
    assert {:ok, _} = Store.enqueue_delivery("g-persist", "d1", %{"id" => "t1", "task_id" => "t1"})

    :ok = File.mkdir_p(Path.dirname(path))
    :ok = File.write!(path, Jason.encode!(Store.dump()))
    raw = File.read!(path)
    refute raw =~ "ONE-TIME-SECRET"
    assert raw =~ "hash-abc"
    assert raw =~ "th-1"

    # 模拟重启：内存全清后从磁盘恢复
    Store.clear()
    assert {:error, "not_found", _} = Store.get_group("g-persist")
    :ok = Store.restore()

    assert {:ok, group} = Store.get_group("g-persist")
    assert get_in(group, ["devices", "d1", "token_hash"]) == "th-1"
    assert get_in(group, ["devices", "d1", "plain"]) == nil
    assert [%{"id" => "t1"}] = Store.list_tasks("g-persist")
    assert [%{"session_id" => "s1"}] = Store.sessions_for_group("g-persist")
    assert [%{"task_id" => "t1"}] = Store.pending_deliveries("d1")
  end

  test "cancel drops only pending deliveries for the task" do
    Store.clear()

    Store.put_group(%{
      "id" => "g-cancel",
      "devices" => %{"d1" => %{"display" => "w1", "paused" => false}}
    })

    assert {:ok, _} = Store.enqueue_delivery("g-cancel", "d1", %{"id" => "t1", "task_id" => "t1"})
    assert {:ok, _} = Store.enqueue_delivery("g-cancel", "d1", %{"id" => "t2", "task_id" => "t2"})
    assert length(Store.pending_deliveries("d1")) == 2

    assert {:ok, 1} = Store.drop_deliveries_for_task("t1")
    assert [%{"task_id" => "t2"}] = Store.pending_deliveries("d1")
    assert {:ok, 0} = Store.drop_deliveries_for_task("t1")
    assert {:ok, 0} = Store.drop_deliveries_for_task("")
  end

  test "tables survive short-lived owner process" do
    Store.clear()
    parent = self()

    spawn(fn ->
      Store.put_group(%{"id" => "g-heir", "name" => "heir"})
      send(parent, :stored)
    end)

    assert_receive :stored, 2000
    :timer.sleep(100)
    assert {:ok, %{"id" => "g-heir"}} = Store.get_group("g-heir")
  end

  test "replayed activity snapshots are idempotent and never re-emit" do
    Store.clear()
    gid = "g-activity-dedup"
    Store.put_group(%{"id" => gid, "devices" => %{}})
    :ok = Store.bind_session(%{"session_id" => "s-activity-dedup", "group_id" => gid, "device_id" => "d1"})
    :ok = Newbee.Bus.subscribe()
    on_exit(fn -> Newbee.Bus.unsubscribe() end)

    aid = "a-replay-1"
    event = %{"id" => aid, "event" => "task_created", "created_at" => 1_700_000_000_000}
    assert {:ok, %{"id" => "a-replay-1"}} = Store.add_activity(gid, event)
    assert_receive {:newbee_event, :collab_event, %{"payload" => %{"id" => ^aid}}}, 1_000

    # 轮询快照反复重放同一事件：不再广播，也不覆盖已有记录
    assert {:ok, %{"event" => "task_created"}} = Store.add_activity(gid, event)
    refute_receive {:newbee_event, :collab_event, %{"payload" => %{"id" => ^aid}}}, 300
    assert [%{"id" => "a-replay-1"}] = Store.list_activity(gid)

    # 全新事件（调用方未给 id）照常广播
    fresh = %{"event" => "task_status_changed"}
    assert {:ok, %{"id" => fresh_id}} = Store.add_activity(gid, fresh)
    assert_receive {:newbee_event, :collab_event, %{"payload" => %{"id" => ^fresh_id}}}, 1_000
    assert fresh_id != aid
  end

  test "replayed messages are deduplicated by id and never re-emit" do
    Store.clear()
    gid = "g-message-dedup"
    Store.put_group(%{"id" => gid, "devices" => %{}})
    :ok = Store.bind_session(%{"session_id" => "s-message-dedup", "group_id" => gid, "device_id" => "d1"})
    :ok = Newbee.Bus.subscribe()
    on_exit(fn -> Newbee.Bus.unsubscribe() end)

    mid = "m-replay-1"

    message = %{
      "id" => mid,
      "role" => "system",
      "kind" => "notice",
      "body" => "hello",
      "created_at" => 1_700_000_000_000
    }

    assert {:ok, %{"id" => "m-replay-1"}} = Store.add_message(gid, message)
    assert_receive {:newbee_event, :collab_event, %{"payload" => %{"id" => ^mid}}}, 1_000

    assert {:ok, %{"id" => "m-replay-1"}} = Store.add_message(gid, message)
    refute_receive {:newbee_event, :collab_event, %{"payload" => %{"id" => ^mid}}}, 300
    assert length(Store.list_messages(gid)) == 1
  end
end
