defmodule Newbee.Collaboration.SharedContextTest do
  use ExUnit.Case, async: false

  alias Newbee.Collaboration.{Coordinator, SharedContext}
  alias Newbee.Collaboration.CrossHost.{Bridge, Group, Store}

  setup do
    Store.clear()
    :ok
  end

  test "cross-host group shares board, knowledge, and capabilities without secrets" do
    {:ok, group, _password} = Group.create("跨主机", "orders", password: "shared-pass-9")
    group = Map.merge(group, %{"server_fp" => "sha256:test", "devices" => %{}})
    :ok = Store.put_group(group)
    :ok = Store.bind_session(%{"session_id" => "x-lead", "group_id" => group["id"], "device_id" => nil})
    :ok = Store.put_task(%{"id" => "task-1", "group_id" => group["id"], "title" => "编译", "status" => "queued"})

    assert {:ok, board} = SharedContext.fetch("x-lead", group["id"] <> "/board")
    assert board["tasks"] == [%{"group_id" => group["id"], "id" => "task-1", "status" => "queued", "title" => "编译"}]
    refute inspect(board) =~ "shared-pass-9"

    assert {:ok, first} =
             SharedContext.publish("x-lead", group["id"], "构建约定", "OPENAI_API_KEY=should-not-leak",
               command_id: "knowledge-1"
             )

    assert {:ok, ^first} = SharedContext.publish("x-lead", group["id"], "被重放", "ignored", command_id: "knowledge-1")
    assert {:ok, knowledge} = SharedContext.fetch("x-lead", group["id"] <> "/knowledge")
    assert [%{"body" => body, "title" => "构建约定"}] = knowledge["entries"]
    assert body == "[REDACTED]"
    assert knowledge["entries"] |> inspect() |> then(&(!String.contains?(&1, "should-not-leak")))

    assert {:ok, task} =
             SharedContext.dispatch_task("x-lead", group["id"], "自动派发", "在目标机器运行测试", idempotency_key: "dispatch-1")

    assert task["status"] == "queued"
    assert task["assigned_session_id"] == nil

    assert {:ok, messages} = SharedContext.fetch("x-lead", group["id"] <> "/messages")
    assert Enum.any?(messages["messages"], &(&1["kind"] == "task"))
    assert {:ok, activity} = SharedContext.fetch("x-lead", group["id"] <> "/activity")
    assert Enum.any?(activity["activity"], &(&1["event"] == "task_created"))
    assert SharedContext.system_prompt("x-lead") =~ "Hive.dispatch/3"

    assert {:error, "not_member", _} = SharedContext.fetch("outsider", group["id"] <> "/board")
    assert {:ok, index} = SharedContext.fetch("x-lead", "")
    assert [%{"id" => id, "kind" => "cross_host"}] = index["groups"]
    assert id == group["id"]
  end

  test "automatic dispatch assigns a live non-creator session" do
    lead = "dispatch-lead-#{System.unique_integer([:positive])}"
    worker = "dispatch-worker-#{System.unique_integer([:positive])}"
    {:ok, _lead_pid, _} = Newbee.Web.Session.ensure(lead)
    {:ok, worker_pid, _} = Newbee.Web.Session.ensure(worker)
    :ok = Newbee.Bus.subscribe()

    on_exit(fn ->
      Newbee.Bus.unsubscribe()
      Newbee.Web.Session.destroy(lead)
      Newbee.Web.Session.destroy(worker)
    end)

    {:ok, group, _password} = Group.create("自动派发", "orders", password: "dispatch-pass-9")
    group = Map.merge(group, %{"server_fp" => "sha256:test", "devices" => %{}})
    :ok = Store.put_group(group)
    :ok = Store.bind_session(%{"session_id" => lead, "group_id" => group["id"], "device_id" => nil})
    :ok = Store.bind_session(%{"session_id" => worker, "group_id" => group["id"], "device_id" => nil})

    assert {:ok, task} =
             SharedContext.dispatch_task(lead, group["id"], "远端测试", "运行项目测试", idempotency_key: "dispatch-live-1")

    assert task["status"] == "running"
    assert task["assigned_session_id"] == worker
    assert_receive {:newbee_event, :web_event, {:web_event, ^worker, :collab_task_queued, _}}, 1_000
    assert is_map(Newbee.Web.Session.state(worker_pid))
  end

  test "remote bridge enrolls, polls, and idempotently acknowledges a task" do
    fingerprint = "sha256:" <> String.duplicate("a", 64)
    {:ok, group, password} = Group.create("远端桥接", "orders", password: "bridge-pass-9")
    group = Map.merge(group, %{"server_fp" => fingerprint, "devices" => %{}, "members" => %{}})
    :ok = Store.put_group(group)

    assert {:error, "fake_server", _} =
             Bridge.join(%{
               "group_id" => group["id"],
               "password" => password,
               "fingerprint" => "sha256:" <> String.duplicate("b", 64)
             })

    assert {:ok, enrolled} =
             Bridge.join(%{
               "group_id" => group["id"],
               "password" => password,
               "fingerprint" => fingerprint,
               "display" => "build-worker"
             })

    device = enrolled["device"]
    assert is_binary(device["plain"])
    refute Map.has_key?(device, "token_hash")

    task = %{
      "id" => "remote-task-1",
      "task_id" => "remote-task-1",
      "group_id" => group["id"],
      "title" => "远端编译",
      "description" => "mix test",
      "status" => "accepted"
    }

    :ok = Store.put_task(task)
    assert :ok = Bridge.enqueue(group["id"], device["id"], task)

    auth = %{"device_id" => device["id"], "token" => device["plain"]}
    assert {:error, "unauthorized", _} = Bridge.poll(%{auth | "token" => "wrong-token"})
    assert {:ok, polled} = Bridge.poll(auth)
    assert [%{"delivery_id" => delivery_id, "task" => %{"status" => "queued"}}] = polled["deliveries"]
    assert polled["snapshot"]["kind"] == "shared_snapshot"

    assert {:ok, %{"acknowledged" => true, "status" => "done"}} =
             Bridge.ack(
               Map.merge(auth, %{"delivery_id" => delivery_id, "status" => "done", "result" => "OPENAI_API_KEY=hidden"})
             )

    assert {:ok, stored} = Store.get_group(group["id"])
    assert get_in(stored, ["devices", device["id"], "last_seen"]) != nil
    # Plain device token must never land in Hub storage.
    refute Map.has_key?(get_in(stored, ["devices", device["id"]]) || %{}, "plain")
    assert is_binary(get_in(stored, ["devices", device["id"], "token_hash"]))
    [updated] = Store.list_tasks(group["id"])
    assert updated["status"] == "done"
    assert updated["result"] == "[REDACTED]"
  end

  test "joining an unknown group tells whether the code belongs to another hub" do
    {:ok, local_fp} = Newbee.Web.Cert.fingerprint()

    foreign_fp =
      if String.starts_with?(local_fp, "sha256:f"),
        do: "sha256:" <> String.duplicate("e", 64),
        else: "sha256:" <> String.duplicate("f", 64)

    assert {:error, "wrong_hub", _} =
             Bridge.join(%{
               "group_id" => "no-such-group",
               "password" => "whatever-123",
               "fingerprint" => foreign_fp
             })

    assert {:error, "not_found", _} =
             Bridge.join(%{
               "group_id" => "no-such-group",
               "password" => "whatever-123",
               "fingerprint" => ""
             })
  end

  test "poll reclaims tasks deferred while the worker was unreachable" do
    fingerprint = "sha256:" <> String.duplicate("e", 64)
    {:ok, group, password} = Group.create("断线认领", "orders", password: "reclaim-pass-9")
    group = Map.merge(group, %{"server_fp" => fingerprint, "devices" => %{}, "members" => %{}})
    :ok = Store.put_group(group)

    assert {:ok, enrolled} =
             Bridge.join(%{
               "group_id" => group["id"],
               "password" => password,
               "fingerprint" => fingerprint,
               "display" => "reclaim-worker"
             })

    device = enrolled["device"]
    auth = %{"device_id" => device["id"], "token" => device["plain"]}

    # 模拟断线期间派发失败：任务滞留 Hub 且状态为 queued，已指派到该设备。
    deferred = %{
      "id" => "reclaim-task-1",
      "task_id" => "reclaim-task-1",
      "group_id" => group["id"],
      "title" => "断线演练",
      "description" => "重连后应投递",
      "status" => "queued",
      "assigned_device_id" => device["id"]
    }

    :ok = Store.put_task(deferred)
    assert Store.pending_deliveries(device["id"]) == []

    assert {:ok, polled} = Bridge.poll(auth)
    assert [%{"task" => %{"id" => "reclaim-task-1", "status" => "queued"}}] = polled["deliveries"]

    # 重复轮询不产生重复投递。
    assert {:ok, polled_again} = Bridge.poll(auth)
    assert [%{"task" => %{"id" => "reclaim-task-1"}}] = polled_again["deliveries"]

    # 未指派到该设备的 queued 任务不被认领。
    :ok =
      Store.put_task(%{
        "id" => "reclaim-task-other",
        "task_id" => "reclaim-task-other",
        "group_id" => group["id"],
        "title" => "他人任务",
        "description" => "不应投递",
        "status" => "queued",
        "assigned_device_id" => "d_someone_else"
      })

    assert {:ok, polled_third} = Bridge.poll(auth)
    assert [%{"task" => %{"id" => "reclaim-task-1"}}] = polled_third["deliveries"]
  end

  test "transport refuses cleartext and unpinned https without sending secrets" do
    alias Newbee.Collaboration.CrossHost.Transport

    assert {:error, "bad_server_identity", _} =
             Transport.rpc("http://127.0.0.1:9", "xgroup.bridge.poll", %{}, [])

    assert {:error, "bad_server_identity", _} =
             Transport.rpc("https://127.0.0.1:9", "xgroup.bridge.poll", %{}, [])

    assert {:error, "forbidden", _} =
             Transport.rpc("https://127.0.0.1:9", "xgroup.task.list", %{},
               fingerprint: "sha256:" <> String.duplicate("c", 64)
             )
  end

  test "worker snapshot merge preserves hub passwords and device hashes" do
    fingerprint = "sha256:" <> String.duplicate("d", 64)
    {:ok, group, password} = Group.create("同机保护", "orders", password: "coprotect-9")
    group = Map.merge(group, %{"server_fp" => fingerprint, "devices" => %{}, "members" => %{}})
    :ok = Store.put_group(group)
    {:ok, enrolled} = Bridge.join(%{"group_id" => group["id"], "password" => password, "fingerprint" => fingerprint})
    device = enrolled["device"]
    {:ok, before} = Store.get_group(group["id"])
    {:ok, snapshot} = SharedContext.remote_snapshot(group["id"])
    :ok = Store.put_remote_snapshot(group["id"], snapshot)
    # Remote cache must hold redacted copies, while Hub storage keeps hashes.
    assert {:ok, %{"kind" => "shared_snapshot"}} = {:ok, snapshot}
    {:ok, after_merge} = Store.get_group(group["id"])
    assert get_in(after_merge, ["password", "hash"]) == get_in(before, ["password", "hash"])
    assert is_binary(get_in(after_merge, ["devices", device["id"], "token_hash"]))
  end

  test "worker reads hub knowledge and history from snapshot cache" do
    lead = "w-hub-lead-#{System.unique_integer([:positive])}"
    worker = "w-side-#{System.unique_integer([:positive])}"
    lead_session = Newbee.Session.open(lead)

    :ok =
      Newbee.Session.append(lead_session, %{"role" => "user", "content" => "部署流程使用蓝色策略，密钥 OPENAI_API_KEY=hub-secret-1"})

    on_exit(fn ->
      Newbee.Session.delete(lead)
      Newbee.Session.delete(worker)
    end)

    {:ok, group, _password} = Group.create("共享走查", "orders", password: "readwalk-9")
    group = Map.merge(group, %{"server_fp" => "sha256:test", "devices" => %{}, "members" => %{}})
    :ok = Store.put_group(group)
    :ok = Store.bind_session(%{"session_id" => lead, "group_id" => group["id"], "device_id" => nil})

    assert {:ok, _} =
             SharedContext.publish(lead, group["id"], "发布约定", "上线前执行蓝色策略演练", command_id: "readwalk-knowledge-1")

    :ok = Store.put_task(%{"id" => "readwalk-task-1", "group_id" => group["id"], "title" => "演练", "status" => "queued"})
    assert {:ok, snapshot} = SharedContext.remote_snapshot(group["id"])
    refute inspect(snapshot) =~ "hub-secret-1"

    # 模拟分机：Worker 侧只有公开群信息 + 快照缓存，没有 Hub 实时表。
    Store.clear()
    :ok = Store.put_group(Map.put(snapshot["group"], "id", group["id"]))
    :ok = Store.bind_session(%{"session_id" => worker, "group_id" => group["id"], "device_id" => nil})
    :ok = Store.put_remote_snapshot(group["id"], snapshot)

    assert {:ok, knowledge} = SharedContext.fetch(worker, group["id"] <> "/knowledge")
    assert [%{"title" => "发布约定"}] = knowledge["entries"]
    refute inspect(knowledge) =~ "hub-secret-1"

    assert {:ok, history} = SharedContext.fetch(worker, group["id"] <> "/history")
    assert Enum.any?(history["group"]["sessions"], &(&1["session_id"] == lead))

    assert {:ok, detail} = SharedContext.fetch(worker, group["id"] <> "/history/" <> lead)
    encoded = Jason.encode!(detail)
    assert encoded =~ "蓝色策略"
    refute encoded =~ "hub-secret-1"

    assert {:ok, searched} = SharedContext.fetch(worker, group["id"] <> "/history/q/蓝色")
    assert Enum.any?(searched["group"]["matches"], &(&1["session_id"] == lead))
    refute inspect(searched) =~ "hub-secret-1"

    assert {:ok, board} = SharedContext.fetch(worker, group["id"] <> "/board")
    assert Enum.any?(board["tasks"], &(&1["id"] == "readwalk-task-1"))

    assert {:error, "not_member", _} = SharedContext.fetch(worker, group["id"] <> "/history/no-such-session")
    assert {:error, "not_member", _} = SharedContext.fetch("outsider", group["id"] <> "/knowledge")
  end

  test "Hive history and messages are shared only to members and are redacted" do
    root = Path.join(System.tmp_dir!(), "shared-context-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    {:ok, coordinator} = Coordinator.start_link(path: Path.join(root, "events.jsonl"), durability: :event)
    lead = "shared-lead-#{System.unique_integer([:positive])}"
    worker = "shared-worker-#{System.unique_integer([:positive])}"
    lead_session = Newbee.Session.open(lead)
    :ok = Newbee.Session.append(lead_session, %{"role" => "user", "content" => "采用 API_KEY=secret-value 的方案"})

    on_exit(fn ->
      if Process.alive?(coordinator), do: GenServer.stop(coordinator)
      Newbee.Session.delete(lead)
      Newbee.Session.delete(worker)
      File.rm_rf!(root)
    end)

    {:ok, group} =
      Coordinator.create_group(%{"session_id" => lead, "title" => "共享写作", "project_root" => File.cwd!()}, coordinator)

    {:ok, _member} =
      Coordinator.add_member(group["group_id"], %{"session_id" => worker, "role" => "worker"}, coordinator)

    assert {:ok, _message} =
             SharedContext.publish(lead, group["group_id"], "决策", "先读共享历史再修改",
               coordinator: coordinator,
               command_id: "hive-knowledge-1"
             )

    assert {:ok, knowledge} = SharedContext.fetch(lead, group["group_id"] <> "/knowledge", coordinator: coordinator)
    assert [%{"content" => "# 决策\n\n先读共享历史再修改"}] = knowledge["entries"]

    assert {:ok, history} = SharedContext.fetch(worker, group["group_id"] <> "/history", coordinator: coordinator)
    assert Enum.any?(history["group"]["sessions"], &(&1["session_id"] == lead))

    assert {:ok, detail} =
             SharedContext.fetch(worker, group["group_id"] <> "/history/" <> lead, coordinator: coordinator)

    encoded = Jason.encode!(detail)
    assert encoded =~ "采用 [REDACTED] 的方案"
    refute encoded =~ "secret-value"

    assert {:error, "not_member", _} =
             SharedContext.fetch(worker, group["group_id"] <> "/history/not-a-member", coordinator: coordinator)

    assert {:error, "not_member", _} =
             SharedContext.fetch("outsider", group["group_id"] <> "/knowledge", coordinator: coordinator)
  end
end
