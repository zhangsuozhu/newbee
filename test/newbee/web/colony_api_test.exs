defmodule Newbee.Web.ColonyApiTest do
  use ExUnit.Case, async: false
  alias Newbee.Colony.{Store, Engine, Work}
  @opts Newbee.Web.Router.init([])
  setup do
    Store.clear_all()
    {:ok, colony} = Engine.create_colony(%{"name" => "RPC 蜂群"})
    %{cid: colony["id"], actor: colony["queen_bee_id"]}
  end

  defp rpc(method, payload, token \\ nil) do
    conn =
      Plug.Test.conn(:post, "/api/" <> method, Jason.encode!(%{rpcId: "t-1", payload: payload}))
      |> Plug.Conn.put_req_header("content-type", "application/json")

    conn =
      if token,
        do: Plug.Conn.put_req_header(conn, "authorization", "Bearer " <> token),
        else: conn

    conn = Newbee.Web.Router.call(conn, @opts)
    assert conn.status == 200
    Jason.decode!(conn.resp_body)["result"]
  end

  test "view exposes actual actor and durable control state", %{cid: cid, actor: actor} do
    assert %{"ok" => view} = rpc("colony.view", %{"colonyId" => cid})
    assert view["actor_bee_id"] == actor
    assert view["control_state"] == "running"
    assert view["can_manage"]
    assert %{"ok" => %{"colonies" => [_]}} = rpc("colony.list", %{})
  end

  test "natural request assigns one owner and does not start a model in the HTTP request", %{
    cid: cid
  } do
    {:ok, bee} = Engine.add_bee(cid, %{"display" => "auth-bot", "kind" => "ai"})

    assert %{"ok" => result} =
             rpc("colony.say", %{
               "colonyId" => cid,
               "text" => "让 auth-bot 写测试",
               "requestId" => "stable"
             })

    assert [task] = result["tasks"]
    assert task["assigned_bee_id"] == bee["id"]
    assert task["session_id"] == nil
    assert length(Store.all("deliveries")) == 1

    assert %{"ok" => again} =
             rpc("colony.say", %{
               "colonyId" => cid,
               "text" => "让 auth-bot 写测试",
               "requestId" => "stable"
             })

    assert hd(again["tasks"])["id"] == task["id"]
    assert length(Store.all("deliveries")) == 1
    assert %{"ok" => progress} = rpc("colony.say", %{"colonyId" => cid, "text" => "进展如何"})
    assert progress["reply"] =~ "进度"
  end

  test "AI state cannot be manually completed and old dispatch methods are closed", %{cid: cid} do
    {:ok, task} = Work.create(cid, %{"title" => "改代码"})

    assert %{"error" => %{"code" => "forbidden"}} =
             rpc("colony.task.transition", %{
               "colonyId" => cid,
               "taskId" => task["id"],
               "event" => "complete"
             })

    assert %{"error" => %{"code" => "replaced"}} =
             rpc("colony.task.claim", %{
               "colonyId" => cid,
               "taskId" => task["id"],
               "beeId" => task["assigned_bee_id"]
             })
  end

  test "human owner can submit evidence and administrator can accept", %{cid: cid, actor: actor} do
    {:ok, task} = Work.create(cid, %{"title" => "验证方案", "assigned_bee_id" => actor})

    assert %{"ok" => %{"task" => %{"status" => "running"}}} =
             rpc("colony.task.transition", %{
               "colonyId" => cid,
               "taskId" => task["id"],
               "event" => "start"
             })

    assert Store.all("deliveries") == []

    assert %{"ok" => %{"honey" => honey}} =
             rpc("colony.work.submit", %{
               "colonyId" => cid,
               "taskId" => task["id"],
               "result" => %{
                 "content" => "完成文档复核；尚未做负载测试",
                 "content_ref" => "docs/spec.md",
                 "limitations" => ["未做负载测试"]
               }
             })

    assert honey["review_state"] == "pending_review"

    assert %{"ok" => %{"honey" => accepted}} =
             rpc("colony.honey.review", %{
               "colonyId" => cid,
               "honeyId" => honey["id"],
               "verdict" => "accept"
             })

    assert accepted["review_state"] == "accepted"
    assert {:ok, %{"status" => "done"}} = Store.get_task(task["id"])
  end

  test "member identity cannot be forged and is isolated to its colony", %{cid: cid, actor: actor} do
    {:ok, invite} = Newbee.Colony.Membership.invite(cid, actor, %{})
    {:ok, enrollment} = Newbee.Colony.Membership.redeem(invite["code"], "同事")
    token = enrollment["token"]

    assert %{"error" => %{"code" => "forbidden"}} =
             rpc(
               "colony.control",
               %{
                 "colonyId" => cid,
                 "actorBeeId" => actor,
                 "scope" => "colony",
                 "action" => "pause"
               },
               token
             )

    {:ok, other} = Engine.create_colony(%{"name" => "另一蜂群"})

    assert %{"error" => %{"code" => "forbidden"}} =
             rpc("colony.view", %{"colonyId" => other["id"]}, token)

    assert %{"ok" => %{"colonies" => colonies}} = rpc("colony.list", %{}, token)
    assert Enum.map(colonies, & &1["colony"]["id"]) == [cid]

    assert %{"error" => %{"code" => "unauthorized"}} =
             rpc("colony.view", %{"colonyId" => cid}, "invalid-token-with-long-enough-length")
  end

  test "attachments retain metadata without exposing host paths", %{cid: cid} do
    sid = "upload-colony-api"
    {:ok, uploaded} = Newbee.Upload.store(sid, "diagnosis.txt", "text/plain", "diagnosis")

    assert %{"ok" => _} =
             rpc("colony.say", %{
               "colonyId" => cid,
               "text" => "检查附件",
               "uploadSid" => sid,
               "uploadIds" => [uploaded.id]
             })

    message = Store.trace_for_colony(cid) |> Enum.find(&(&1["type"] == "message"))
    assert [attachment] = message["data"]["attachments"]
    assert attachment["name"] == "diagnosis.txt"
    refute Map.has_key?(attachment, "path")
    assert [delivery] = Store.all("deliveries")
    assert delivery["upload_sid"] == sid
  end

  test "missing arguments and removed demo are explicit", %{cid: cid} do
    assert %{"error" => %{"code" => "bad_request"}} = rpc("colony.view", %{})
    assert %{"error" => %{"code" => "bad_request"}} = rpc("colony.say", %{"colonyId" => cid})
    assert %{"error" => %{"code" => "unknown_method"}} = rpc("colony.unknown.method", %{})
    assert %{"error" => %{"code" => "removed"}} = rpc("colony.seed_demo", %{})
  end

  test "Queen can rename a colony through RPC", %{cid: cid} do
    assert %{"ok" => %{"colony" => %{"name" => "RPC 改名蜂群"}}} =
             rpc("colony.rename", %{"colonyId" => cid, "name" => "RPC 改名蜂群"})

    assert %{"ok" => %{"colony" => %{"name" => "RPC 改名蜂群"}}} =
             rpc("colony.view", %{"colonyId" => cid})

    assert %{"error" => %{"code" => "bad_request"}} =
             rpc("colony.rename", %{"colonyId" => cid, "name" => "   "})
  end

  test "workflow decisions use the authenticated actor and reject stale revisions", %{cid: cid} do
    assert %{"ok" => result} =
             rpc("colony.say", %{"colonyId" => cid, "text" => "讨论方案：改进接口兼容性", "requestId" => "workflow-api"})

    [root] = result["tasks"]
    assert root["workflow"]["phase"] == "triage"

    assert %{"ok" => %{"task" => commented}} =
             rpc("colony.work.flow", %{
               "colonyId" => cid,
               "taskId" => root["id"],
               "action" => "comment",
               "revision" => root["revision"],
               "text" => "保留旧接口"
             })

    assert length(commented["workflow"]["comments"]) == 1

    assert %{"error" => %{"code" => "conflict"}} =
             rpc("colony.work.flow", %{
               "colonyId" => cid,
               "taskId" => root["id"],
               "action" => "comment",
               "revision" => root["revision"],
               "text" => "过期请求"
             })
  end
end
