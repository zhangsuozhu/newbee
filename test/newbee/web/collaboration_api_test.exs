defmodule Newbee.Web.CollaborationApiTest do
  use ExUnit.Case, async: false

  @opts Newbee.Web.Router.init([])

  setup do
    case Process.whereis(Newbee.Collaboration.Coordinator) do
      nil -> :ok
      pid -> GenServer.stop(pid)
    end

    root = Path.join(System.tmp_dir!(), "newbee-collab-api-#{System.unique_integer([:positive])}")
    path = Path.join(root, "events.jsonl")
    {:ok, pid} = Newbee.Collaboration.Coordinator.start_link(path: path, durability: :event)

    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid)
      File.rm_rf!(root)
    end)

    :ok
  end

  test "创建群、添加现有会话并双向发消息" do
    group =
      post_rpc("group.create", %{
        "sessionId" => "session-a",
        "title" => "API 群组",
        "goal" => "验证会话互发消息",
        "commandId" => "api-create-1"
      })
      |> ok!()

    group_id = group["group_id"]

    assert {:ok, _} =
             Newbee.Collaboration.Coordinator.add_member(group_id, %{
               "session_id" => "session-b",
               "parent_session_id" => "session-a"
             })

    first =
      post_rpc("collab.message.send", %{
        "groupId" => group_id,
        "senderSessionId" => "session-a",
        "toSessionId" => "session-b",
        "body" => "开始检查",
        "commandId" => "api-message-1"
      })
      |> ok!()

    assert first["seq"] == 1

    second =
      post_rpc("collab.message.send", %{
        "groupId" => group_id,
        "senderSessionId" => "session-b",
        "toSessionId" => "session-a",
        "body" => "检查完成",
        "kind" => "task_result"
      })
      |> ok!()

    assert second["seq"] == 2

    messages =
      post_rpc("collab.message.list", %{
        "groupId" => group_id,
        "sessionId" => "session-a"
      })
      |> ok!()

    assert Enum.map(messages["messages"], & &1["body"]) == ["开始检查", "检查完成"]

    groups = post_rpc("group.list", %{"sessionId" => "session-b"}) |> ok!()
    assert [%{"group_id" => ^group_id, "member_count" => 2, "current_session_member" => true}] = groups["groups"]
  end

  test "成员可读取工作组持久活动时间线，非成员被拒绝" do
    group = post_rpc("group.create", %{"sessionId" => "activity-parent", "title" => "活动群"}) |> ok!()

    post_rpc("collab.message.send", %{
      "groupId" => group["group_id"],
      "senderSessionId" => "activity-parent",
      "body" => "一条消息",
      "commandId" => "activity-message"
    })
    |> ok!()

    post_rpc("group.task.create", %{
      "groupId" => group["group_id"],
      "sessionId" => "activity-parent",
      "title" => "一项任务",
      "commandId" => "activity-task"
    })
    |> ok!()

    result =
      post_rpc("group.activity.list", %{
        "groupId" => group["group_id"],
        "sessionId" => "activity-parent",
        "limit" => 20
      })
      |> ok!()

    topics = Enum.map(result["activity"], & &1["topic"])
    assert "collab_group_created" in topics
    assert "collab_message_created" in topics
    assert "collab_task_created" in topics
    message_event = Enum.find(result["activity"], &(&1["topic"] == "collab_message_created"))
    refute Map.has_key?(message_event["payload"]["message"], "body")
    ids = Enum.map(result["activity"], & &1["event_id"])
    assert ids == Enum.sort(ids)

    denied =
      post_rpc("group.activity.list", %{
        "groupId" => group["group_id"],
        "sessionId" => "outsider"
      })

    assert %{"error" => %{"code" => "not_member"}} = denied["result"]
  end

  test "父会话可启动群内子会话" do
    group =
      post_rpc("group.create", %{"sessionId" => "spawn-parent", "title" => "派生群"})
      |> ok!()

    spawned =
      post_rpc("group.member.spawn", %{
        "groupId" => group["group_id"],
        "parentSessionId" => "spawn-parent",
        "sessionId" => "spawn-child",
        "commandId" => "spawn-command-1"
      })
      |> ok!()

    assert spawned["sessionId"] == "spawn-child"

    detail =
      post_rpc("group.get", %{
        "groupId" => group["group_id"],
        "sessionId" => "spawn-child"
      })
      |> ok!()

    assert Enum.any?(detail["members"], &(&1["session_id"] == "spawn-child" and &1["role"] == "worker"))

    on_exit(fn -> Newbee.Web.Session.destroy("spawn-child") end)
  end

  test "非成员不能读取消息" do
    group =
      post_rpc("group.create", %{"sessionId" => "session-a", "title" => "私有群"})
      |> ok!()

    response =
      post_rpc("collab.message.list", %{
        "groupId" => group["group_id"],
        "sessionId" => "outsider"
      })

    assert %{"error" => %{"code" => "not_member"}} = response["result"]
  end

  test "组内会话删除时自动移出工作组，协调者删除时自动解散工作组" do
    suffix = System.unique_integer([:positive])
    parent_sid = "member-parent-#{suffix}"
    member_sid = "existing-member-#{suffix}"
    child_sid = "child-member-#{suffix}"

    {:ok, _pid, ^member_sid} = Newbee.Web.Session.ensure(member_sid, File.cwd!())
    :ok = Newbee.Session.mark_created(member_sid)

    {:ok, _pid, ^child_sid} = Newbee.Web.Session.ensure(child_sid, File.cwd!())
    :ok = Newbee.Session.mark_created(child_sid)

    on_exit(fn ->
      Newbee.Web.Session.destroy(member_sid)
      Newbee.Web.Session.destroy(child_sid)
    end)

    group =
      post_rpc("group.create", %{"sessionId" => parent_sid, "title" => "已有会话分组"})
      |> ok!()

    # 普通成员 + 其子协作成员（parent_session_id=member_sid）
    member =
      post_rpc("group.member.add", %{
        "groupId" => group["group_id"],
        "actorSessionId" => parent_sid,
        "sessionId" => member_sid,
        "commandId" => "add-existing-#{suffix}"
      })
      |> ok!()

    assert member["session_id"] == member_sid

    child =
      post_rpc("group.member.add", %{
        "groupId" => group["group_id"],
        "actorSessionId" => parent_sid,
        "sessionId" => child_sid,
        "parentSessionId" => member_sid,
        "commandId" => "add-child-#{suffix}"
      })
      |> ok!()

    assert child["session_id"] == child_sid

    # 删除普通成员：自动级联移出其子成员，然后删除成功（带 notices）
    deleted = post_rpc("session.delete", %{"sessionId" => member_sid}) |> ok!()
    assert deleted["deleted"] == member_sid
    assert [note | _] = deleted["notices"]
    assert is_binary(note)
    refute Newbee.Collaboration.Coordinator.member?(group["group_id"], member_sid)
    refute Newbee.Collaboration.Coordinator.member?(group["group_id"], child_sid)

    # 删除协调者：自动解散工作组（取消 + 移出全部成员），然后删除成功
    deleted_parent = post_rpc("session.delete", %{"sessionId" => parent_sid}) |> ok!()
    assert deleted_parent["deleted"] == parent_sid
    assert [note2 | _] = deleted_parent["notices"]
    assert is_binary(note2)

    # 组内已无成员（协调者已移出，工作组被取消）
    group_after = Newbee.Collaboration.Coordinator.get(group["group_id"])
    assert {:ok, g} = group_after
    assert g["status"] == "cancelled"
    assert g["members"] == []
  end


  test "让另一个 AI 帮忙会创建会话、成员和已分派任务" do
    suffix = System.unique_integer([:positive])
    parent_sid = "delegate-parent-#{suffix}"
    child_sid = "delegate-child-#{suffix}"

    group =
      post_rpc("group.create", %{"sessionId" => parent_sid, "title" => "原子分工"})
      |> ok!()

    delegated =
      post_rpc("group.member.delegate", %{
        "groupId" => group["group_id"],
        "parentSessionId" => parent_sid,
        "sessionId" => child_sid,
        "name" => "认证测试",
        "title" => "补充认证回归测试",
        "description" => "覆盖过期凭证",
        "commandId" => "delegate-#{suffix}"
      })
      |> ok!()

    assert delegated["sessionId"] == child_sid
    assert delegated["member"]["parent_session_id"] == parent_sid
    assert delegated["task"]["assigned_session_id"] == child_sid
    assert delegated["task"]["status"] == "assigned"
    refute Map.has_key?(delegated["task"]["workspace"], "path")
    refute Map.has_key?(delegated["task"]["workspace"], "root")

    detail =
      post_rpc("group.get", %{"groupId" => group["group_id"], "sessionId" => parent_sid})
      |> ok!()

    assert Enum.any?(detail["members"], &(&1["session_id"] == child_sid))
    assert Enum.any?(detail["tasks"], &(&1["assigned_session_id"] == child_sid))

    on_exit(fn -> Newbee.Web.Session.destroy(child_sid) end)
  end

  test "消息投递方式：notify 只入时间线，queue 唤醒目标会话且忙时安全排队" do
    suffix = System.unique_integer([:positive])
    parent_sid = "delivery-parent-#{suffix}"
    worker_sid = "delivery-worker-#{suffix}"

    assert {:ok, _worker} = Newbee.Web.Session.start_link(worker_sid)

    group =
      post_rpc("group.create", %{"sessionId" => parent_sid, "title" => "投递群"})
      |> ok!()

    assert {:ok, _} =
             Newbee.Collaboration.Coordinator.add_member(group["group_id"], %{
               "session_id" => worker_sid
             })

    # 订阅 Bus：会话下行事件（notice/error/queued）经 web_event topic 广播
    Newbee.Bus.subscribe()
    on_exit(fn -> Newbee.Bus.unsubscribe() end)

    # 无 kernel 的会话：busy=false，queue 消息经 dispatch_input 处理，不产生 turn
    # 但必产生可见证据：collab_message_queued 或空内核提示事件
    assert {:ok, _} =
             Newbee.Collaboration.Coordinator.send_message(group["group_id"], %{
               "sender_session_id" => parent_sid,
               "to_session_id" => worker_sid,
               "kind" => "question",
               "delivery" => "wake",
               "body" => "请确认接口边界",
               "command_id" => "wake-#{suffix}"
             })

    assert_receive {:newbee_event, :web_event, {:web_event, ^worker_sid, kind, _payload}}, 2_000
    assert kind in [:collab_message_queued, :queue_updated, :error, :notice]
    # 新行为一次入队发两帧（queue_updated + 兼容老事件），排空残留再测 notify，否则残留会误判。
    receive do
      {:newbee_event, :web_event, {:web_event, ^worker_sid, _, _}} -> :ok
    after
      200 -> :ok
    end
    receive do
      {:newbee_event, :web_event, {:web_event, ^worker_sid, _, _}} -> :ok
    after
      0 -> :ok
    end
    before = :counters

    assert {:ok, _} =
             Newbee.Collaboration.Coordinator.send_message(group["group_id"], %{
               "sender_session_id" => parent_sid,
               "to_session_id" => worker_sid,
               "delivery" => "notify",
               "body" => "纯时间线记录",
               "command_id" => "notify-#{suffix}"
             })

    refute_receive {:newbee_event, :web_event, {:web_event, ^worker_sid, _, _}}, 300
    _ = before

    # 无效投递方式被拒绝
    assert {:error, "bad_request", _} =
             Newbee.Collaboration.Coordinator.send_message(group["group_id"], %{
               "sender_session_id" => parent_sid,
               "to_session_id" => worker_sid,
               "delivery" => "bullhorn",
               "body" => "x",
               "command_id" => "bad-#{suffix}"
             })

    # 时间线上能看到 delivery 标记
    assert {:ok, listed} =
             Newbee.Collaboration.Coordinator.messages(group["group_id"], limit: 50)

    deliveries = Enum.map(listed, & &1["delivery"])
    assert deliveries -- ["wake", "notify"] == []

    on_exit(fn -> Newbee.Web.Session.destroy(worker_sid) end)
  end

  test "queue 消息在忙时会话上排队且去重，空闲后由队列驱动处理" do
    suffix = System.unique_integer([:positive])
    sid = "queue-dedup-#{suffix}"

    assert {:ok, session} = Newbee.Web.Session.start_link(sid)
    on_exit(fn -> Newbee.Web.Session.destroy(sid) end)

    # 模拟内核忙：置 booting，投两条同 ID 消息，断言只排一条
    :sys.replace_state(session, fn st -> %{st | booting: true} end)

    msg = %{
      "message_id" => "m-fixed-#{suffix}",
      "group_id" => "g",
      "sender_session_id" => "peer",
      "to_session_id" => sid,
      "kind" => "chat",
      "delivery" => "queue",
      "body" => "排队处理我"
    }

    Newbee.Web.Session.collaboration_message(session, msg)
    Newbee.Web.Session.collaboration_message(session, msg)

    st = :sys.get_state(session)
    q = st.queue |> :queue.to_list()

    assert Enum.count(q) == 1
    assert :queue.len(st.queue) == 1
    [only] = q
    mid = case only do
      %{kind: "collab_message", message_id: m} -> m
      %{message_id: m} -> m
      {:collab_message, %{"message_id" => m}} -> m
      _ -> nil
    end
    assert mid == "m-fixed-#{suffix}"
  end

  test "总控可审查、应用并清理子代理变更，成员只能查看" do
    suffix = System.unique_integer([:positive])
    parent_sid = "review-parent-#{suffix}"
    child_sid = "review-child-#{suffix}"
    repo = Path.join(System.tmp_dir!(), "newbee-review-api-#{suffix}")
    File.mkdir_p!(repo)
    git!(repo, ["init", "-q"])
    git!(repo, ["config", "user.email", "review@test.local"])
    git!(repo, ["config", "user.name", "Review Test"])
    File.write!(Path.join(repo, "feature.txt"), "base\n")
    git!(repo, ["add", "feature.txt"])
    git!(repo, ["commit", "-q", "-m", "base"])

    assert {:ok, group} =
             Newbee.Collaboration.Coordinator.create_group(%{
               "session_id" => parent_sid,
               "title" => "审查群",
               "project_root" => repo
             })

    assert {:ok, workspace} = Newbee.Collaboration.Workspace.prepare(repo, child_sid, true)

    assert {:ok, %{task: task}} =
             Newbee.Collaboration.Coordinator.delegate(group["group_id"], %{
               "session_id" => child_sid,
               "parent_session_id" => parent_sid,
               "role" => "worker",
               "title" => "修改功能",
               "workspace" => workspace,
               "command_id" => "review-delegate-#{suffix}"
             })

    :ok = Newbee.Session.mark_created(child_sid)
    :ok = Newbee.Session.set_cwd(child_sid, workspace["path"])
    File.write!(Path.join(workspace["path"], "feature.txt"), "base\nchild\n")

    assert {:ok, _} =
             Newbee.Collaboration.Coordinator.update_task(group["group_id"], task["task_id"], %{
               "session_id" => child_sid,
               "status" => "running"
             })

    assert {:ok, _} =
             Newbee.Collaboration.Coordinator.update_task(group["group_id"], task["task_id"], %{
               "session_id" => child_sid,
               "status" => "succeeded",
               "result" => "done"
             })

    review =
      post_rpc("group.workspace.review", %{
        "groupId" => group["group_id"],
        "taskId" => task["task_id"],
        "sessionId" => child_sid
      })
      |> ok!()

    assert review["dirty"]
    assert [%{"path" => "feature.txt"}] = review["files"]
    refute Map.has_key?(review, "workspace_path")
    refute Map.has_key?(review, "base_ref")

    forbidden =
      post_rpc("group.workspace.apply", %{
        "groupId" => group["group_id"],
        "taskId" => task["task_id"],
        "sessionId" => child_sid,
        "patchSha256" => review["patch_sha256"]
      })

    assert %{"error" => %{"code" => "forbidden_role"}} = forbidden["result"]

    stale =
      post_rpc("group.workspace.apply", %{
        "groupId" => group["group_id"],
        "taskId" => task["task_id"],
        "sessionId" => parent_sid,
        "patchSha256" => String.duplicate("0", 64)
      })

    assert %{"error" => %{"code" => "stale_review"}} = stale["result"]

    applied =
      post_rpc("group.workspace.apply", %{
        "groupId" => group["group_id"],
        "taskId" => task["task_id"],
        "sessionId" => parent_sid,
        "patchSha256" => review["patch_sha256"],
        "commandId" => "apply-#{suffix}"
      })
      |> ok!()

    assert applied["task"]["workspace"]["review_status"] == "applied"
    assert File.read!(Path.join(repo, "feature.txt")) == "base\nchild\n"

    cleaned =
      post_rpc("group.workspace.cleanup", %{
        "groupId" => group["group_id"],
        "taskId" => task["task_id"],
        "sessionId" => parent_sid,
        "commandId" => "cleanup-#{suffix}"
      })
      |> ok!()

    assert cleaned["task"]["workspace"]["review_status"] == "cleaned"
    refute File.exists?(workspace["path"])
    assert Newbee.Session.cwd(child_sid) == repo

    on_exit(fn ->
      Newbee.Web.Session.destroy(child_sid)
      File.rm_rf!(repo)
    end)
  end

  defp git!(dir, args) do
    case System.cmd("git", ["-C", dir | args], stderr_to_stdout: true) do
      {output, 0} -> output
      {output, code} -> flunk("git #{Enum.join(args, " ")} failed (#{code}): #{output}")
    end
  end

  defp post_rpc(method, payload) do
    body = Jason.encode!(%{"rpcId" => "test", "method" => method, "payload" => payload})

    Plug.Test.conn(:post, "/api/" <> method, body)
    |> Plug.Conn.put_req_header("content-type", "application/json")
    |> Newbee.Web.Router.call(@opts)
    |> then(fn conn -> Jason.decode!(conn.resp_body) end)
  end

  defp ok!(%{"result" => %{"ok" => value}}), do: value
end
