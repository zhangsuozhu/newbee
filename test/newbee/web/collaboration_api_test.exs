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
    assert [%{"group_id" => ^group_id, "member_count" => 2}] = groups["groups"]
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

  test "已有会话可加入和移出工作组，组内会话不能直接删除" do
    suffix = System.unique_integer([:positive])
    parent_sid = "member-parent-#{suffix}"
    member_sid = "existing-member-#{suffix}"

    {:ok, _pid, ^member_sid} = Newbee.Web.Session.ensure(member_sid, File.cwd!())
    :ok = Newbee.Session.mark_created(member_sid)
    on_exit(fn -> Newbee.Web.Session.destroy(member_sid) end)

    group =
      post_rpc("group.create", %{"sessionId" => parent_sid, "title" => "已有会话分组"})
      |> ok!()

    member =
      post_rpc("group.member.add", %{
        "groupId" => group["group_id"],
        "actorSessionId" => parent_sid,
        "sessionId" => member_sid,
        "commandId" => "add-existing-#{suffix}"
      })
      |> ok!()

    assert member["session_id"] == member_sid

    blocked = post_rpc("session.delete", %{"sessionId" => member_sid})
    assert %{"error" => %{"code" => "session_in_group"}} = blocked["result"]

    removed =
      post_rpc("group.member.remove", %{
        "groupId" => group["group_id"],
        "actorSessionId" => parent_sid,
        "sessionId" => member_sid,
        "commandId" => "remove-existing-#{suffix}"
      })
      |> ok!()

    assert removed["sessionId"] == member_sid
    assert %{"deleted" => ^member_sid} = post_rpc("session.delete", %{"sessionId" => member_sid}) |> ok!()
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

    detail =
      post_rpc("group.get", %{"groupId" => group["group_id"], "sessionId" => parent_sid})
      |> ok!()

    assert Enum.any?(detail["members"], &(&1["session_id"] == child_sid))
    assert Enum.any?(detail["tasks"], &(&1["assigned_session_id"] == child_sid))

    on_exit(fn -> Newbee.Web.Session.destroy(child_sid) end)
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
