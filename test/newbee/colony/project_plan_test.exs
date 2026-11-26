defmodule Newbee.Colony.ProjectPlanTest do
  use ExUnit.Case, async: false
  alias Newbee.Colony.{ConversationWork, ProjectReview, Store, Work, Workflow, Workspace, WorkspaceReview}
  @moduletag :tmp_dir

  setup %{tmp_dir: source} do
    :ok = Store.clear_all()
    File.write!(Path.join(source, "README"), "project baseline")
    sid = "project-#{System.unique_integer([:positive])}"
    {:ok, %{"work" => work}} = ConversationWork.start(sid, source, "迁移仓库模块", "start", project: true)
    root = task(work["id"])
    {:ok, staged} = Workspace.ensure(root, source)
    [delivery] = deliveries(root)
    {:ok, _} = Store.update("deliveries", delivery["id"], nil, &{:ok, Map.put(&1, "status", "accepted")})
    :ok = ConversationWork.consumed(delivery["id"])
    %{sid: sid, source: source, staged: staged, root_id: root["id"]}
  end

  @tag timeout: 180_000
  test "30 tasks roll through six slots, baseline includes only staged work, and integration is delivered once", ctx do
    items =
      for n <- 1..30 do
        dependencies = if n <= 10, do: [], else: ["p#{n - 10}"]
        item("p#{n}", dependencies)
      end

    root = plan(ctx, items)
    assert root["workflow"]["strategy"] == "project"
    assert length(children(root)) == 30
    assert Enum.count(children(root), &is_binary(&1["assigned_bee_id"])) == 6
    assert Enum.count(children(root), &(&1["status"] == "claimed")) == 6

    finish_batches(ctx, 0)
    root = task(ctx.root_id)
    assert root["workflow"]["phase"] == "integrating"
    assert Enum.all?(children(root), &(&1["status"] == "done"))
    assert [%{"instruction" => instruction}] = Enum.filter(deliveries(root), &(&1["status"] == "pending"))
    assert instruction =~ "已经应用"
    assert :idle = ProjectReview.run_once()
    :ok = Store.restore()
    :ok = Workflow.advance()
    assert length(deliveries(root)) == 2

    for n <- 1..30 do
      assert File.read!(Path.join(ctx.staged, "p#{n}.txt")) == "p#{n}"
      refute File.exists?(Path.join(ctx.source, "p#{n}.txt"))
    end

    {:ok, _honey} = submit(task(ctx.root_id))
    {:ok, review} = WorkspaceReview.review(task(ctx.root_id))
    assert review["file_count"] == 30
    refute File.exists?(Path.join(ctx.source, "p1.txt"))

    {:ok, _receipt} = WorkspaceReview.apply(task(ctx.root_id), review["patch_sha256"], "human-adopts")
    root = task(ctx.root_id)
    assert {:ok, _reviewed} = Work.review(root["colony_id"], root["result"], "accept", root["created_by"])
    assert task(ctx.root_id)["status"] == "done"
    assert File.read!(Path.join(ctx.source, "p30.txt")) == "p30"
  end

  test "no downstream delivery on bare submission or bad file scope; retry is fenced and requeued", ctx do
    root = plan(ctx, [item("up"), item("down", ["up"])])
    [up, down] = children(root)
    {:ok, path} = Workspace.ensure(up, ctx.staged)
    File.write!(Path.join(path, "unrelated.txt"), "not in scope")
    {:ok, honey} = submit(up)
    :ok = Workflow.advance()
    assert deliveries(down) == []

    assert {:error, "project_check_required", _} =
             Work.review(root["colony_id"], honey["id"], "accept", root["created_by"])

    assert {:error, "project_file_contract", _} = ProjectReview.run_once()
    assert task(up["id"])["status"] == "blocked"
    assert deliveries(down) == []
    refute File.exists?(Path.join(ctx.staged, "unrelated.txt"))

    assert {:ok, _} = ConversationWork.control(ctx.sid, ctx.root_id, "retry")
    requeued = task(up["id"])
    assert requeued["waiting_for"] == "capacity"
    assert requeued["execution_generation"] > up["execution_generation"]
    :ok = Workflow.advance()
    up = task(up["id"])

    assert {:error, "stale_result", _} =
             Work.submit(
               up["colony_id"],
               up["id"],
               %{"content" => "late", "work_revision" => up["context_revision"] - 1},
               up["assigned_bee_id"]
             )

    File.rm!(Path.join(path, "unrelated.txt"))
    File.write!(Path.join(path, "up.txt"), "accepted upstream")
    {:ok, _honey} = submit(up)
    assert {:ok, _receipt} = ProjectReview.run_once()
    :ok = Workflow.advance()
    assert [%{"instruction" => instruction}] = deliveries(down)
    assert instruction =~ "patch_sha256"
    {:ok, downstream} = Workspace.ensure(task(down["id"]), ctx.staged)
    assert File.read!(Path.join(downstream, "up.txt")) == "accepted upstream"
    refute File.exists?(Path.join(ctx.source, "up.txt"))
  end

  test "pause holds adoption and a saved application receipt recovers without replaying the worker", ctx do
    root = plan(ctx, [item("up"), item("down", ["up"])])
    [up, down] = children(root)
    {:ok, path} = Workspace.ensure(up, ctx.staged)
    File.write!(Path.join(path, "up.txt"), "staged")
    {:ok, result} = submit(up)
    {:ok, _} = ConversationWork.control(ctx.sid, ctx.root_id, "pause")
    assert :idle = ProjectReview.run_once()
    refute File.exists?(Path.join(ctx.staged, "up.txt"))
    assert deliveries(down) == []
    {:ok, _} = ConversationWork.control(ctx.sid, ctx.root_id, "resume")
    up = task(up["id"])
    {:ok, review} = WorkspaceReview.review(up)
    {:ok, receipt} = WorkspaceReview.apply(up, review["patch_sha256"], "project:" <> result["id"])
    assert receipt["idempotent"] == false
    :ok = Store.restore()
    assert {:ok, %{"idempotent" => true}} = ProjectReview.run_once()
    :ok = Workflow.advance()
    assert task(up["id"])["status"] == "done"
    assert length(deliveries(up)) == 1
    assert length(deliveries(down)) == 1
  end

  test "partial application blocks staging until the same receipt is reconciled", ctx do
    up = Map.put(item("up"), "writes", ["up.txt", "extra.txt"])
    root = plan(ctx, [up, item("parallel"), item("down", ["up"])])
    [up, parallel, down] = children(root)
    {:ok, path} = Workspace.ensure(up, ctx.staged)
    File.write!(Path.join(path, "up.txt"), "first")
    File.write!(Path.join(path, "extra.txt"), "second")
    {:ok, result} = submit(up)
    {:ok, check} = WorkspaceReview.review(task(up["id"]))
    {:ok, _} = WorkspaceReview.apply(task(up["id"]), check["patch_sha256"], "project:" <> result["id"])

    # Model a crash between file writes and the final application receipt.
    File.rm!(Path.join(ctx.staged, "extra.txt"))

    {:ok, _} =
      Store.update("tasks", up["id"], nil, fn task ->
        {:ok, put_in(task, ["application", "state"], "applying")}
      end)

    assert {:error, "project_staging_unavailable", _} = Workspace.ensure(parallel, ctx.staged)
    assert {:error, "apply_unknown", _} = ProjectReview.run_once()
    :ok = Workflow.advance()
    assert deliveries(down) == []
    refute File.exists?(Path.join(ctx.source, "up.txt"))

    # A human reconciles the isolated staging tree, then retries the same application.
    File.write!(Path.join(ctx.staged, "extra.txt"), "second")
    {:ok, _} = ConversationWork.control(ctx.sid, ctx.root_id, "retry")
    assert {:ok, %{"idempotent" => true}} = ProjectReview.run_once()
    :ok = Workflow.advance()
    assert length(deliveries(down)) == 1
    assert length(deliveries(up)) == 1
  end

  test "overlapping declared paths block a plan before any worker starts", ctx do
    items = [item("up"), Map.put(item("down"), "writes", ["up.txt/nested"])]
    root = plan(ctx, items)
    assert root["status"] == "blocked"
    assert root["waiting_for"] == "plan"
    assert children(root) == []
    assert length(Store.list_tasks()) == 1
  end

  defp finish_batches(ctx, completed) when completed < 30 do
    current = children(task(ctx.root_id))
    running = Enum.filter(current, &(&1["status"] == "claimed"))
    assert length(running) in 1..6

    for child <- running do
      {:ok, path} = Workspace.ensure(child, ctx.staged)

      for dep <- child["depends_on"] do
        id = task(dep)["plan_id"]
        assert File.read!(Path.join(path, id <> ".txt")) == id
      end

      File.write!(Path.join(path, hd(child["project_writes"])), child["plan_id"])
      assert {:ok, _} = submit(child)
    end

    for _ <- running, do: assert({:ok, _} = ProjectReview.run_once())
    assert :idle = ProjectReview.run_once()
    :ok = Workflow.advance()
    finish_batches(ctx, completed + length(running))
  end

  defp finish_batches(_ctx, 30), do: :ok

  @tag timeout: 60_000
  test "pinned HTTPS: only the current device can read and deliver, expired work is reassigned, and downstream receives accepted files",
       ctx do
    alias Newbee.Colony.{Membership, ProjectRemote}
    alias Newbee.Collaboration.CrossHost.Transport
    alias Newbee.Collaboration.Workspace, as: Snapshots
    alias Newbee.Web.{Cert, Router}

    root = task(ctx.root_id)
    cid = root["colony_id"]
    {:ok, _} = Store.update("tasks", root["id"], nil, &{:ok, put_in(&1, ["workflow", "project_pool"], "remote")})
    File.write!(Path.join(ctx.staged, "large.txt"), String.duplicate("x", 525_000))
    File.write!(Path.join(ctx.staged, ".env"), "not_for_remote")

    {:ok, %{cert: cert}} = Cert.ensure()
    {:ok, fingerprint} = Cert.fingerprint()

    server =
      start_supervised!(
        {Bandit, plug: Router, scheme: :https, port: 0, ip: {127, 0, 0, 1}, certfile: cert, keyfile: Cert.key_path()}
      )

    {:ok, {_, port}} = ThousandIsland.listener_info(server)
    url = "https://127.0.0.1:#{port}"

    call = fn method, token, payload ->
      Transport.rpc(url, method, payload, fingerprint: fingerprint, device_token: token)
    end

    enroll = fn name, enabled ->
      {:ok, %{"code" => code}} = Membership.invite(cid, root["created_by"], %{"kind" => "ai"}, project_runner: enabled)

      {:ok, %{"token" => token, "bee" => %{"id" => id}}} =
        call.("colony.invite.redeem", nil, %{"code" => code, "display" => name})

      assert {:error, "invalid_invite", _} = call.("colony.invite.redeem", nil, %{"code" => code, "display" => name})
      {id, token}
    end

    {other_id, other_token} = enroll.("普通成员", false)
    {first_id, first_token} = enroll.("执行端一", true)
    assert {:error, "forbidden", _} = Membership.authorize_rpc("colony.view", %{"__token__" => first_token})
    assert {:error, "forbidden", _} = Membership.session_access(first_token, ctx.sid, :read)

    {second_id, second_token} = enroll.("执行端二", true)
    poll = fn token -> call.("colony.remote.poll", token, %{"projectRunner" => 1}) end
    request = fn token, args -> call.("colony.remote.attachment", token, args) end

    assert {:ok, %{"projects" => []}} = poll.(other_token)
    assert {:ok, %{"projects" => []}} = poll.(first_token)
    root = plan(ctx, [item("up"), item("down", ["up"])])
    [up, down] = children(root)
    assert up["assigned_bee_id"] == first_id
    refute up["assigned_bee_id"] == other_id
    assert down["waiting_for"] == "dependencies"
    assert {:ok, %{"projects" => [%{"task" => offered}], "tasks" => []}} = poll.(first_token)
    refute Map.has_key?(offered, "workspace_source")
    assert {:error, "lease_lost", _} = request.(other_token, Map.put(ProjectRemote.args(up, "baseline"), "offset", 0))
    assert {:ok, snapshot} = ProjectRemote.fetch_baseline(&request.(first_token, &1), offered)
    assert snapshot["large.txt"]["bytes"] == 525_000
    refute Map.has_key?(snapshot, ".env")
    assert {:error, "lease_lost", _} = Work.submit(cid, up["id"], %{"content" => "bypass"}, first_id)

    # Move the host clock relative to the stored lease without an actual 90s wait.
    {:ok, _} = Store.update("tasks", up["id"], nil, &{:ok, put_in(&1, ["project_lease", "expires_at"], 0)})
    {:ok, _} = Store.update("bees", first_id, nil, &{:ok, Map.put(&1, "last_seen_at", 0)})
    assert {:ok, %{"projects" => []}} = poll.(second_token)
    assert :ok = Workflow.advance()
    current = task(up["id"])
    assert current["assigned_bee_id"] == second_id
    assert current["execution_generation"] > up["execution_generation"]
    assert current["project_lease"]["id"] != up["project_lease"]["id"]
    assert {:error, "lease_lost", _} = request.(first_token, ProjectRemote.args(up, "finish"))

    assert {:ok, %{"projects" => [%{"task" => offered}]}} = poll.(second_token)
    worker = Path.join(ctx.source, ".newbee/test-remote")
    assert {:ok, snapshot} = ProjectRemote.fetch_baseline(&request.(second_token, &1), offered)
    assert :ok = Snapshots.materialize_snapshot(snapshot, worker)
    baseline = worker <> ".json"
    File.write!(baseline, Jason.encode!(snapshot))
    File.write!(Path.join(worker, "up.txt"), "created on device two")
    payload = ProjectRemote.result(offered, worker, baseline, "done")
    assert {:error, "project_candidate", _} = request.(second_token, put_in(payload, ["entries", "../../escape"], nil))
    assert {:ok, %{"accepted" => true}} = request.(second_token, payload)
    assert {:ok, %{"accepted" => true}} = request.(second_token, payload)
    assert task(down["id"])["waiting_for"] == "dependencies"
    refute File.exists?(Path.join(ctx.source, "up.txt"))
    assert {:ok, _} = ProjectReview.run_once()
    assert :ok = Workflow.advance()
    [_, down] = children(root)
    assert is_binary(down["assigned_bee_id"])
    token = if down["assigned_bee_id"] == second_id, do: second_token, else: first_token
    assert {:ok, next} = ProjectRemote.fetch_baseline(&request.(token, &1), down)
    assert next["up.txt"]["content"] == "created on device two"
  end

  test "execution node isolates a lease and keeps its artifact until the host ACKs it", ctx do
    alias Newbee.Colony.{Id, ProjectRunner, Runtime}
    alias Newbee.Collaboration.Workspace, as: Snapshots
    root = task(ctx.root_id)
    {:ok, snapshot} = Snapshots.snapshot(ctx.staged)
    binary = Jason.encode!(snapshot)
    tid = Id.new(:task)
    lease = Id.new(:delivery, :xhost)
    delivery_id = Id.new(:delivery)

    offered = %{
      "task" => %{
        "id" => tid,
        "colony_id" => root["colony_id"],
        "assigned_bee_id" => root["assigned_bee_id"],
        "title" => "worker fixture",
        "project_writes" => ["worker.txt"],
        "project_lease" => %{"id" => lease},
        "context_revision" => 3,
        "execution_generation" => 2
      },
      "delivery" => %{
        "id" => delivery_id,
        "instruction" => "test model",
        "context_revision" => 3,
        "execution_generation" => 2
      }
    }

    connection = %{"cwd" => ctx.source, "colony_id" => root["colony_id"]}

    fetch = fn %{"op" => "baseline", "offset" => 0} ->
      {:ok, %{"data" => Base.encode64(binary), "total" => byte_size(binary)}}
    end

    assert :ok = ProjectRunner.reconcile(connection, [offered], fetch)
    mirror = task(tid)
    path = mirror["workspace"]["path"]
    assert path != ctx.source
    assert File.read!(Path.join(path, "README")) == "project baseline"
    assert ProjectRunner.heartbeat(connection)["projectLease"] == lease
    assert :ok = ProjectRunner.reconcile(connection, [offered], fn _ -> flunk("same lease was fetched twice") end)
    assert [_] = deliveries(mirror)
    File.write!(Path.join(path, "worker.txt"), "from isolated execution")
    {:ok, _} = Store.update("deliveries", delivery_id, nil, &{:ok, Map.put(&1, "status", "accepted")})
    assert is_nil(Runtime.project(mirror["session_id"], :done, %{delivery_id: delivery_id, execution_generation: 1}))
    assert :ok = Runtime.project(mirror["session_id"], :done, %{delivery_id: delivery_id, execution_generation: 2})
    assert [%{"payload" => payload}] = Store.all("remote_reports")
    assert payload["entries"]["worker.txt"]["content"] == "from isolated execution"
    refute File.exists?(Path.join(ctx.source, "worker.txt"))
    assert :ok = ProjectRunner.flush(connection, fn ^payload -> {:error, "network", "test disconnect"} end)
    assert [_] = Store.all("remote_reports")
    assert :ok = ProjectRunner.flush(connection, fn ^payload -> {:ok, %{"accepted" => true}} end)
    assert Store.all("remote_reports") == []
    assert :ok = ProjectRunner.reconcile(connection, [], fetch)
    assert task(tid)["status"] == "cancelled"
  end

  test "the host-wide project quota applies before creating another local or remote worker" do
    alias Newbee.Colony.ProjectLease
    active = Map.new(1..24, fn n -> {"sub-#{n}", %{"status" => "running", "project_writes" => ["out.txt"]}} end)
    local = %{"workflow" => %{"project_pool" => "local"}}
    remote = %{"workflow" => %{"project_pool" => "remote"}}
    child = %{"project_writes" => ["next.txt"]}
    assert :wait = ProjectLease.allocate(%{"tasks" => active}, local, child, 0)
    assert :wait = ProjectLease.allocate(%{"tasks" => active}, remote, child, 0)
    assert {:ok, ^child} = ProjectLease.allocate(%{"tasks" => Map.delete(active, "sub-1")}, local, child, 0)
    assert {:ok, %{}} = ProjectLease.allocate(%{"tasks" => active}, local, %{}, 0)
  end

  defp plan(ctx, items) do
    root = task(ctx.root_id)
    payload = Jason.encode!(%{"summary" => "迁移模块并核对", "tasks" => items})
    assert {:ok, _} = Workflow.complete(root, payload, root["context_revision"])
    task(ctx.root_id)
  end

  defp item(id, deps \\ []) do
    %{
      "id" => id,
      "title" => id,
      "scope" => "产出 #{id}",
      "writes" => [id <> ".txt"],
      "acceptance" => ["核对文件"],
      "depends_on" => deps
    }
  end

  defp children(root), do: Enum.map(root["workflow"]["children"], &task/1)
  defp deliveries(task), do: Enum.filter(Store.all("deliveries"), &(&1["task_id"] == task["id"]))

  defp task(id) do
    {:ok, task} = Store.get_task(id)
    task
  end

  defp submit(task) do
    Work.submit(
      task["colony_id"],
      task["id"],
      %{"content" => "执行已结束", "work_revision" => task["context_revision"]},
      task["assigned_bee_id"]
    )
  end
end
