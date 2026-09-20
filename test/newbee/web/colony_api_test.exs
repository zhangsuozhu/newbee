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

  test "trace pagination is bounded, exclusive and scoped", %{cid: cid} do
    {:ok, task} = Work.create(cid, %{"title" => "history fixture"})

    for n <- 1..7 do
      Store.append_trace(%{
        "colony_id" => cid,
        "task_id" => task["id"],
        "channel" => "colony",
        "type" => "message",
        "text" => "page #{n}"
      })
    end

    payload = %{"colonyId" => cid, "taskId" => task["id"], "limit" => 3}
    assert %{"ok" => first} = rpc("colony.trace.list", payload)
    assert length(first["trace"]) == 3
    assert first["trace_page"]["has_more"] == true
    cursor = first["trace_page"]["before_seq"]
    snapshot = first["trace_page"]["snapshot_seq"]
    Store.append_trace(%{"colony_id" => cid, "task_id" => task["id"], "channel" => "colony", "text" => "new arrival"})

    assert %{"ok" => second} =
             rpc("colony.trace.list", Map.merge(payload, %{"beforeSeq" => cursor, "snapshotSeq" => snapshot}))

    assert length(second["trace"]) == 3
    assert Enum.all?(second["trace"], &(&1["seq"] < cursor))
    assert second["trace_page"]["snapshot_seq"] == snapshot

    assert %{"ok" => tail} =
             rpc(
               "colony.trace.list",
               Map.merge(payload, %{
                 "beforeSeq" => second["trace_page"]["before_seq"],
                 "snapshotSeq" => snapshot,
                 "limit" => 100
               })
             )

    assert tail["trace_page"]["has_more"] == false
    records = tail["trace"] ++ second["trace"] ++ first["trace"]
    assert records == Enum.sort_by(records, & &1["seq"])
    assert length(records) == length(Enum.uniq_by(records, & &1["seq"]))
    assert Enum.count(records, &String.starts_with?(&1["text"] || "", "page ")) == 7
    refute Enum.any?(records, &(&1["text"] == "new arrival"))
    assert %{"error" => %{"code" => "bad_request"}} = rpc("colony.trace.list", Map.put(payload, "beforeSeq", -1))
    assert %{"ok" => empty} = rpc("colony.trace.list", Map.put(payload, "beforeSeq", 1))
    assert empty["trace"] == []
    refute empty["trace_page"]["has_more"]
  end

  test "view exposes actual actor and durable control state", %{cid: cid, actor: actor} do
    assert %{"ok" => view} = rpc("colony.view", %{"colonyId" => cid})
    assert view["actor_bee_id"] == actor
    assert view["control_state"] == "running"
    assert view["can_manage"]
    assert %{"ok" => %{"colonies" => [_]}} = rpc("colony.list", %{})
  end

  test "目录选择会持久化为蜂群默认 cwd，并固定新任务目录", %{cid: cid} do
    assert %{"ok" => %{"colony" => %{"cwd" => "/"}}} =
             rpc("colony.cwd", %{"colonyId" => cid, "cwd" => "/"})

    assert %{"ok" => view} = rpc("colony.view", %{"colonyId" => cid})
    assert view["colony"]["cwd"] == "/"

    {:ok, bee} = Engine.add_bee(cid, %{"display" => "cwd-bee", "kind" => "ai"})

    assert %{"ok" => result} =
             rpc("colony.say", %{"colonyId" => cid, "text" => "让 cwd-bee 做 cwd 测试", "cwd" => "/"})

    assert [task] = result["tasks"]
    assert task["cwd"] == "/"
    assert task["assigned_bee_id"] == bee["id"]
  end

  test "任务详情可在启动前单独切换 cwd，不改变蜂群默认目录", %{cid: cid} do
    {:ok, before} = Engine.view(cid)
    default_cwd = before["colony"]["cwd"]
    {:ok, task} = Work.create(cid, %{"title" => "待切换目录的工作"})

    assert %{"ok" => %{"task" => updated}} =
             rpc("colony.work.cwd", %{"colonyId" => cid, "taskId" => task["id"], "cwd" => "/"})

    assert updated["cwd"] == "/"

    [delivery] = Enum.filter(Store.all("deliveries"), &(&1["task_id"] == task["id"]))
    assert delivery["status"] == "pending"
    assert delivery["context_revision"] == updated["context_revision"]

    assert {:ok, stored} = Store.get_task(task["id"])
    assert stored["cwd"] == "/"
    assert %{"colony" => %{"cwd" => ^default_cwd}} = Engine.view(cid) |> elem(1)
  end

  test "incremental view detects rename below another record revision and control changes", %{cid: cid} do
    {:ok, bee} = Engine.add_bee(cid, %{"display" => "revision fixture", "kind" => "ai"})
    :ok = Store.put_bee(Map.put(bee, "revision", 999))
    assert %{"ok" => initial} = rpc("colony.view", %{"colonyId" => cid})

    assert %{"ok" => %{"changed" => false}} =
             rpc("colony.view", %{"colonyId" => cid, "sinceRevision" => initial["view_revision"]})

    assert %{"ok" => _} = rpc("colony.rename", %{"colonyId" => cid, "name" => "renamed"})
    assert %{"ok" => renamed} = rpc("colony.view", %{"colonyId" => cid, "sinceRevision" => initial["view_revision"]})
    assert renamed["changed"]
    assert renamed["colony"]["name"] == "renamed"

    assert %{"ok" => _} = rpc("colony.control", %{"colonyId" => cid, "scope" => "colony", "action" => "pause"})
    assert %{"ok" => paused} = rpc("colony.view", %{"colonyId" => cid, "sinceRevision" => renamed["view_revision"]})
    assert paused["changed"]
    refute paused["control_state"] == renamed["control_state"]
  end

  test "incremental view stays stable as task stimulus decays over time", %{cid: cid} do
    {:ok, bee} = Engine.add_bee(cid, %{"display" => "stimulus-bee", "kind" => "ai"})
    {:ok, _task} = Engine.create_task(cid, %{"title" => "decaying task", "assigned_bee_id" => bee["id"]})

    assert %{"ok" => first} = rpc("colony.view", %{"colonyId" => cid})
    assert first["tasks"] != []

    # stimulus 每轮都在涨；指纹若把派生值算进去，这里会一直报 changed=true，
    # 前端就会每 3 秒全量重传、白白丢掉增量轮询。
    Process.sleep(3_200)

    assert %{"ok" => %{"changed" => false}} =
             rpc("colony.view", %{"colonyId" => cid, "sinceRevision" => first["view_revision"]})
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

    assert result["receipt"] == %{
             "status" => "accepted",
             "message" => result["reply"],
             "task_ids" => [task["id"]]
           }

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
    assert progress["receipt"]["status"] == "accepted"
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
    trace_count = length(Store.trace_for_colony(cid))

    assert %{"ok" => %{"honey" => ^accepted}} =
             rpc("colony.honey.review", %{"colonyId" => cid, "honeyId" => honey["id"], "verdict" => "accept"})

    assert length(Store.trace_for_colony(cid)) == trace_count
  end

  test "Queen can explicitly clean an ended task workspace", %{cid: cid, actor: actor} do
    root = Path.join(System.tmp_dir!(), "colony-cleanup-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)

    ai = Store.bees_for_colony(cid) |> Enum.find(&(&1["kind"] == "ai"))

    {:ok, task} =
      Work.create(cid, %{
        "title" => "可清理任务",
        "workflow" => true,
        "assigned_bee_id" => ai["id"],
        "actor_bee_id" => actor,
        "workspace_source" => root
      })

    assert {:ok, workspace_path} = Newbee.Colony.Workspace.ensure(task, root)
    {:ok, stored} = Store.get_task(task["id"])
    :ok = Store.update("tasks", task["id"], nil, &{:ok, Map.put(&1, "status", "done")}) |> elem(0)
    assert File.dir?(workspace_path)

    assert %{"ok" => %{"task" => cleaned}} =
             rpc("colony.workspace.cleanup", %{"colonyId" => cid, "taskId" => task["id"]})

    assert cleaned["workspace"]["review_status"] == "cleaned"
    refute File.exists?(workspace_path)
    refute File.exists?(workspace_path <> ".base_snapshot.term")
    assert {:ok, after_cleanup} = Store.get_task(task["id"])
    assert after_cleanup["workspace"]["review_status"] == "cleaned"
    assert stored["workspace"]["kind"] == "filesystem_copy"
    trace_count = length(Store.trace_for_colony(cid))

    assert %{"ok" => %{"task" => cleaned_again}} =
             rpc("colony.workspace.cleanup", %{"colonyId" => cid, "taskId" => task["id"]})

    assert cleaned_again["task"]["revision"] == cleaned["task"]["revision"]
    assert length(Store.trace_for_colony(cid)) == trace_count
  end

  test "workspace cleanup rejects active tasks and non-Queen members", %{cid: cid, actor: actor} do
    root = Path.join(System.tmp_dir!(), "colony-cleanup-boundary-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)

    ai = Store.bees_for_colony(cid) |> Enum.find(&(&1["kind"] == "ai"))

    {:ok, task} =
      Work.create(cid, %{
        "title" => "不可提前清理",
        "workflow" => true,
        "assigned_bee_id" => ai["id"],
        "actor_bee_id" => actor,
        "workspace_source" => root
      })

    assert {:ok, workspace_path} = Newbee.Colony.Workspace.ensure(task, root)

    assert %{"error" => %{"code" => "task_not_terminal"}} =
             rpc("colony.workspace.cleanup", %{"colonyId" => cid, "taskId" => task["id"]})

    assert File.dir?(workspace_path)
    {:ok, invite} = Newbee.Colony.Membership.invite(cid, actor, %{})
    {:ok, enrollment} = Newbee.Colony.Membership.redeem(invite["code"], "清理成员")

    assert %{"error" => %{"code" => "forbidden"}} =
             rpc(
               "colony.workspace.cleanup",
               %{"colonyId" => cid, "taskId" => task["id"]},
               enrollment["token"]
             )

    assert File.dir?(workspace_path)
    assert {:ok, unchanged} = Store.get_task(task["id"])
    assert unchanged["workspace"]["review_status"] == "waiting"
  end

  test "parent workspace waits for nested children and releases after them", %{cid: cid, actor: actor} do
    source = Path.join(System.tmp_dir!(), "colony-parent-workspace-#{System.unique_integer([:positive])}")
    File.mkdir_p!(source)
    on_exit(fn -> File.rm_rf!(source) end)
    ai = Store.bees_for_colony(cid) |> Enum.find(&(&1["kind"] == "ai"))

    {:ok, parent} =
      Work.create(cid, %{
        "title" => "父工作",
        "workflow" => true,
        "assigned_bee_id" => ai["id"],
        "actor_bee_id" => actor,
        "workspace_source" => source
      })

    assert {:ok, parent_path} = Newbee.Colony.Workspace.ensure(parent, source)
    {:ok, parent_stored} = Store.get_task(parent["id"])

    {:ok, child} =
      Work.create(cid, %{
        "title" => "子工作",
        "workflow" => true,
        "assigned_bee_id" => ai["id"],
        "actor_bee_id" => actor,
        "workspace_source" => parent_path
      })

    assert {:ok, child_path} = Newbee.Colony.Workspace.ensure(child, parent_path)
    assert {:ok, _} = Store.update("tasks", parent["id"], nil, &{:ok, Map.put(&1, "status", "done")})
    assert {:ok, _} = Store.update("tasks", child["id"], nil, &{:ok, Map.put(&1, "status", "done")})

    assert %{"error" => %{"code" => "workspace_in_use"}} =
             rpc("colony.workspace.cleanup", %{"colonyId" => cid, "taskId" => parent["id"]})

    assert File.dir?(parent_path)
    assert File.dir?(child_path)
    assert %{"ok" => _} = rpc("colony.workspace.cleanup", %{"colonyId" => cid, "taskId" => child["id"]})
    refute File.exists?(child_path)
    assert File.dir?(parent_path)

    assert %{"ok" => _} = rpc("colony.workspace.cleanup", %{"colonyId" => cid, "taskId" => parent["id"]})
    refute File.exists?(parent_path)
    assert parent_stored["workspace"]["kind"] == "filesystem_copy"
  end

  test "cleanup marks terminal tasks that share one workspace path", %{cid: cid, actor: actor} do
    source = Path.join(System.tmp_dir!(), "colony-shared-workspace-#{System.unique_integer([:positive])}")
    File.mkdir_p!(source)
    on_exit(fn -> File.rm_rf!(source) end)
    ai = Store.bees_for_colony(cid) |> Enum.find(&(&1["kind"] == "ai"))

    {:ok, first} =
      Work.create(cid, %{
        "title" => "共享工作一",
        "workflow" => true,
        "assigned_bee_id" => ai["id"],
        "actor_bee_id" => actor,
        "workspace_source" => source
      })

    assert {:ok, path} = Newbee.Colony.Workspace.ensure(first, source)
    {:ok, first_stored} = Store.get_task(first["id"])

    {:ok, second} =
      Work.create(cid, %{
        "title" => "共享工作二",
        "workflow" => true,
        "assigned_bee_id" => ai["id"],
        "actor_bee_id" => actor
      })

    assert {:ok, _} =
             Store.update("tasks", second["id"], nil, &{:ok, Map.put(&1, "workspace", first_stored["workspace"])})

    assert {:ok, _} = Store.update("tasks", first["id"], nil, &{:ok, Map.put(&1, "status", "done")})
    assert {:ok, _} = Store.update("tasks", second["id"], nil, &{:ok, Map.put(&1, "status", "done")})

    assert %{"ok" => _} = rpc("colony.workspace.cleanup", %{"colonyId" => cid, "taskId" => first["id"]})
    refute File.exists?(path)
    assert {:ok, second_cleaned} = Store.get_task(second["id"])
    assert second_cleaned["workspace"]["review_status"] == "cleaned"
    assert %{"ok" => _} = rpc("colony.workspace.cleanup", %{"colonyId" => cid, "taskId" => second["id"]})
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

  test "待办可以先忽略：只有本查看者看不到，工作有实质变化后自动回来", %{cid: cid, actor: actor} do
    {:ok, task} = Work.create(cid, %{"title" => "需要你答复的旧工作"})
    {:ok, _blocked} = Engine.transition_task(cid, task["id"], "block", bee_id: actor)

    assert %{"ok" => before} = rpc("colony.view", %{"colonyId" => cid})
    refute task["id"] in before["dismissed_task_ids"]

    assert %{"ok" => %{"task" => _}} =
             rpc("colony.work.dismiss", %{"colonyId" => cid, "taskId" => task["id"]})

    assert %{"ok" => after_dismiss} = rpc("colony.view", %{"colonyId" => cid})
    assert task["id"] in after_dismiss["dismissed_task_ids"]

    # 忽略要能被增量轮询看见：否则工作台拿到 sinceRevision 相同的旧视图，点了没反应。
    assert %{"ok" => %{"changed" => true}} =
             rpc("colony.view", %{"colonyId" => cid, "sinceRevision" => before["view_revision"]})

    # 负责人推进工作 → 快照失配，忽略自动失效（工作重新进入待办）
    {:ok, _running} = Engine.transition_task(cid, task["id"], "unblock", bee_id: actor)
    assert %{"ok" => after_progress} = rpc("colony.view", %{"colonyId" => cid})
    refute task["id"] in after_progress["dismissed_task_ids"]

    # 手动恢复提醒
    assert %{"ok" => %{"task" => _}} =
             rpc("colony.work.dismiss", %{"colonyId" => cid, "taskId" => task["id"]})

    assert %{"ok" => %{"task" => _}} =
             rpc("colony.work.restore", %{"colonyId" => cid, "taskId" => task["id"]})

    assert %{"ok" => after_restore} = rpc("colony.view", %{"colonyId" => cid})
    refute task["id"] in after_restore["dismissed_task_ids"]
  end

  test "执行器已经不在的工作可以由人结束（终态，不再有待办）", %{cid: cid, actor: actor} do
    {:ok, task} = Work.create(cid, %{"title" => "心跳超时的工作"})
    {:ok, _blocked} = Engine.transition_task(cid, task["id"], "block", bee_id: actor)

    assert %{"ok" => %{"task" => cancelled}} =
             rpc("colony.work.abandon", %{
               "colonyId" => cid,
               "taskId" => task["id"],
               "note" => "执行器已经不在"
             })

    assert cancelled["status"] == "cancelled"
    assert is_nil(cancelled["waiting_for"])
    refute cancelled["resume_needed"]
    assert cancelled["completed_at"] != nil

    assert %{"error" => %{"code" => "terminal"}} =
             rpc("colony.work.abandon", %{"colonyId" => cid, "taskId" => task["id"]})

    # 终态任务的忽略没有意义，直接拒绝（避免把它再塞回待办）
    assert %{"error" => %{"code" => "terminal"}} =
             rpc("colony.work.dismiss", %{"colonyId" => cid, "taskId" => task["id"]})
  end
end
