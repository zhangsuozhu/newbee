defmodule Newbee.Colony.WorkflowTest do
  use ExUnit.Case, async: false
  alias Newbee.Colony.{Store, Engine, Work, Workflow, Control, Workspace}

  setup do
    Store.clear_all()
    {:ok, colony} = Engine.create_colony(%{"name" => "协作流程"})
    {:ok, a} = Engine.add_bee(colony["id"], %{"display" => "方案甲", "kind" => "ai"})
    {:ok, b} = Engine.add_bee(colony["id"], %{"display" => "方案乙", "kind" => "ai"})
    %{cid: colony["id"], actor: colony["queen_bee_id"], bees: [a["id"], b["id"]]}
  end

  defp create(ctx, extra \\ %{}) do
    {:ok, task} =
      Work.create(
        ctx.cid,
        Map.merge(
          %{
            "title" => "修改接口",
            "description" => "验证兼容性并修改接口",
            "workflow" => true,
            "assigned_bee_id" => hd(ctx.bees),
            "actor_bee_id" => ctx.actor
          },
          extra
        )
      )

    task
  end

  defp get(id), do: elem(Store.get_task(id), 1)
  defp complete(task, text), do: Workflow.complete(task, text, task["context_revision"])

  defp choose(ctx) do
    root = create(ctx)
    {:ok, root} = complete(root, Jason.encode!(%{route: "discuss", reason: "需比较兼容路径", participants: ctx.bees}))
    for p <- root["workflow"]["proposals"], do: complete(get(p["task_id"]), "依据接口代码提出修改与测试方案")
    for p <- root["workflow"]["proposals"], do: complete(get(p["task_id"]), "互评：按接口边界分工，补充兼容测试")
    get(root["id"])
  end

  defp act(ctx, root, action, attrs \\ %{}),
    do: Workflow.act(ctx.cid, root["id"], action, Map.put(attrs, "revision", root["revision"]), ctx.actor)

  test "simple work analyzes first and creates exactly one execution delivery", ctx do
    root = create(ctx)
    assert root["mode"] == "triage"
    assert {:error, "planning_only", _} = Work.submit(ctx.cid, root["id"], %{"content" => "只有方案"}, hd(ctx.bees))
    assert {:ok, executing} = complete(root, ~s({"route":"self","reason":"局部明确修改","participants":[]}))
    assert executing["workflow"]["phase"] == "executing"
    assert executing["mode"] == "execution"
    count = length(Store.all("deliveries"))
    assert :ignored = complete(root, ~s({"route":"self","reason":"重复回调"}))
    assert length(Store.all("deliveries")) == count
  end

  test "invalid analysis is blocked and bounded retries never silently execute", ctx do
    root = create(ctx)
    {:ok, root} = complete(root, "我直接完成了")
    assert root["status"] == "blocked"

    for _ <- 1..2 do
      {:ok, retried} = act(ctx, get(root["id"]), "retry")
      complete(retried, "仍不是路由JSON")
    end

    assert {:error, "budget_exhausted", _} = act(ctx, get(root["id"]), "retry")
    assert Store.all("honey") == []
  end

  test "proposal collection automatically performs one round and waits for a human", ctx do
    root = choose(ctx)
    assert root["workflow"]["phase"] == "choosing"
    assert root["workflow"]["round"] == 1
    assert root["workflow"]["calls"] == 5
    assert length(root["workflow"]["proposals"]) == 2
    assert Enum.all?(root["workflow"]["proposals"], &(length(&1["reviews"]) == 1))
    assert Store.all("honey") == []
    assert {:error, "workflow_decision_required", _} = Work.continue(ctx.cid, root["id"], "直接开工", ctx.actor)
  end

  test "comments are shared context but only managers decide; stale concurrent selection loses", ctx do
    root = choose(ctx)
    {:ok, member} = Engine.add_bee(ctx.cid, %{"display" => "同事", "kind" => "human"})

    assert {:ok, commented} =
             Workflow.act(
               ctx.cid,
               root["id"],
               "comment",
               %{"revision" => root["revision"], "text" => "保留旧接口"},
               member["id"]
             )

    assert {:error, "conflict", _} = act(ctx, root, "execute", %{"assignments" => [%{"bee_id" => hd(ctx.bees)}]})

    assert {:error, _, _} =
             Workflow.act(
               ctx.cid,
               root["id"],
               "execute",
               %{"revision" => commented["revision"], "assignments" => [%{"bee_id" => hd(ctx.bees)}]},
               member["id"]
             )

    results =
      1..4
      |> Elixir.Task.async_stream(fn _ ->
        act(ctx, commented, "execute", %{"assignments" => [%{"bee_id" => hd(ctx.bees)}]})
      end)
      |> Enum.map(&elem(&1, 1))

    assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    assert Enum.count(results, &match?({:error, "conflict", _}, &1)) == 3
    assert get(root["id"])["workflow"]["phase"] == "executing"
  end

  test "discussion rounds stop at two and pause prevents a decision", ctx do
    root = choose(ctx)
    {:ok, _} = Control.set(ctx.cid, "work", root["id"], "pause", actor_bee_id: ctx.actor)
    assert {:error, "paused", _} = act(ctx, root, "discuss")
    {:ok, _} = Control.set(ctx.cid, "work", root["id"], "resume", actor_bee_id: ctx.actor)
    {:ok, root} = act(ctx, get(root["id"]), "discuss")
    for p <- root["workflow"]["proposals"], do: complete(get(p["task_id"]), "没有新分歧，建议执行")
    assert {:error, "budget_exhausted", _} = act(ctx, get(root["id"]), "discuss")
  end

  test "invalid split is atomic, valid split integrates once and is accepted together", ctx do
    root = choose(ctx)
    before = length(Store.all("tasks"))
    assert {:error, _, _} = act(ctx, root, "execute", %{"assignments" => Enum.map(ctx.bees, &%{"bee_id" => &1})})
    assert length(Store.all("tasks")) == before

    assignments =
      Enum.with_index(ctx.bees)
      |> Enum.map(fn {bee, i} -> %{"bee_id" => bee, "title" => "分工#{i}", "scope" => "仅修改模块#{i}，验证接口兼容"} end)

    {:ok, root} = act(ctx, root, "execute", %{"assignments" => assignments})
    assert root["waiting_for"] == "children"

    assert {:error, "planning_only", _} =
             Work.submit(ctx.cid, root["id"], %{"content" => "尚未集成"}, root["assigned_bee_id"])

    [one, two] = root["workflow"]["children"] |> Enum.map(&get/1)
    {:ok, _} = Work.submit(ctx.cid, one["id"], %{"content" => "模块一及验证结果"}, one["assigned_bee_id"])
    Workflow.advance()
    assert get(root["id"])["waiting_for"] == "children"
    {:ok, _} = Work.submit(ctx.cid, two["id"], %{"content" => "模块二及验证结果"}, two["assigned_bee_id"])
    Workflow.advance()
    integrated = get(root["id"])
    assert integrated["workflow"]["phase"] == "integrating"
    count = length(Store.all("deliveries"))
    Workflow.advance()
    assert length(Store.all("deliveries")) == count
    {:ok, honey} = Work.submit(ctx.cid, root["id"], %{"content" => "已集成两个模块并运行组合验证"}, integrated["assigned_bee_id"])
    assert {:ok, _} = Work.review(ctx.cid, honey["id"], "accept", ctx.actor)
    assert Enum.all?([root["id"], one["id"], two["id"]], &(get(&1)["status"] == "done"))
  end

  test "plain-directory workspaces preserve dirty input and isolate each worker", ctx do
    source = Path.join(System.tmp_dir!(), "colony-workspace-#{System.unique_integer([:positive])}")
    File.mkdir_p!(source)
    on_exit(fn -> File.rm_rf(source) end)
    File.write!(Path.join(source, "input.txt"), "uncommitted input")
    root = create(ctx)
    assert {:ok, path} = Workspace.ensure(root, source)
    assert path != source
    assert File.read!(Path.join(path, "input.txt")) == "uncommitted input"
    File.write!(Path.join(path, "input.txt"), "worker change")
    assert File.read!(Path.join(source, "input.txt")) == "uncommitted input"
    assert {:ok, ^path} = Workspace.ensure(get(root["id"]), source)
  end

  test "Git worktrees include tracked dirt and untracked source without changing HEAD", ctx do
    source = Path.join(System.tmp_dir!(), "colony-git-#{System.unique_integer([:positive])}")
    File.mkdir_p!(source)
    on_exit(fn -> File.rm_rf(source) end)

    git = fn args ->
      {out, status} = System.cmd("git", args, cd: source, stderr_to_stdout: true)
      assert status == 0, out
      String.trim(out)
    end

    git.(["init", "-q"])
    File.write!(Path.join(source, "tracked.txt"), "base")
    git.(["add", "tracked.txt"])
    git.(["-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "-qm", "fixture"])
    head = git.(["rev-parse", "HEAD"])
    File.write!(Path.join(source, "tracked.txt"), "dirty")
    File.write!(Path.join(source, "new.txt"), "new source")
    root = create(ctx)
    assert {:ok, path} = Workspace.ensure(root, source)
    assert get(root["id"])["workspace"]["kind"] == "git_worktree"
    assert File.regular?(Path.join(path, ".git"))
    assert File.read!(Path.join(path, "tracked.txt")) == "dirty"
    assert File.read!(Path.join(path, "new.txt")) == "new source"
    {status, 0} = System.cmd("git", ["status", "--porcelain"], cd: path)
    assert status =~ " M tracked.txt"
    assert status =~ "?? new.txt"
    assert git.(["rev-parse", "HEAD"]) == head
    File.write!(Path.join(path, "tracked.txt"), "isolated execution")
    assert File.read!(Path.join(source, "tracked.txt")) == "dirty"
  end

  test "empty proposal can retry its own stage and survives Store restore", ctx do
    root = create(ctx)
    {:ok, root} = complete(root, Jason.encode!(%{route: "discuss", reason: "比较两份方案", participants: ctx.bees}))
    proposal = root["workflow"]["proposals"] |> hd() |> Map.fetch!("task_id") |> get()
    assert {:ok, blocked} = complete(proposal, "  ")
    assert blocked["status"] == "blocked"
    assert get(root["id"])["workflow"]["phase"] == "proposing"

    {:ok, root} =
      act(ctx, get(root["id"]), "retry_member", %{"memberTaskId" => proposal["id"], "text" => "请给出修改文件与验证方法"})

    retry = get(proposal["id"])
    assert retry["mode"] == "proposal"
    assert retry["context_revision"] > proposal["context_revision"]
    assert :ignored = complete(proposal, "过期结果")
    Store.persist_now()
    Store.restore()
    assert get(root["id"])["workflow"] == root["workflow"]
    assert {:ok, _} = complete(get(proposal["id"]), "有效方案及代码依据")
  end

  test "unexpected interruption blocks an AI task without replay until continue", ctx do
    task = create(ctx, %{"workflow" => false, "mode" => "execution"})
    [delivery] = Store.all("deliveries")
    assert {:ok, _} = Store.update("deliveries", delivery["id"], nil, &{:ok, Map.put(&1, "status", "accepted")})

    Newbee.Colony.Runtime.project_remote(task, :interrupted, %{})
    blocked = get(task["id"])
    assert blocked["status"] == "blocked"
    assert blocked["waiting_for"] == "user"
    assert blocked["resume_needed"] == false
    assert blocked["next_step"] =~ "执行会话意外中断"
    assert Enum.all?(Store.all("deliveries"), &(&1["status"] == "paused"))

    before = length(Store.all("deliveries"))
    Newbee.Colony.Runtime.sweep()
    Newbee.Colony.Runtime.sweep()
    assert length(Store.all("deliveries")) == before
    assert get(task["id"])["session_id"] == nil

    assert {:ok, continued} = Work.continue(ctx.cid, task["id"], "核对后继续", hd(ctx.bees))
    assert continued["status"] == "claimed"
    assert length(Store.all("deliveries")) == before + 1
    [new_delivery] = Store.all("deliveries") |> Enum.filter(&(&1["status"] == "pending"))
    assert new_delivery["task_id"] == task["id"]
  end
end
