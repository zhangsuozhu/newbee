defmodule Newbee.Colony.TeamTest do
  use ExUnit.Case, async: false
  alias Newbee.Colony.{Store, Engine, Work, Team, TeamTemplate}

  setup do
    Store.clear_all()
    {:ok, colony} = Engine.create_colony(%{"name" => "主蜂群"})
    %{cid: colony["id"], actor: colony["queen_bee_id"]}
  end

  defp draft_json(overrides \\ %{}) do
    TeamTemplate.product_team() |> Map.merge(overrides) |> Jason.encode!()
  end

  defp propose_and_plan(ctx, goal \\ "做一个记账小程序") do
    {:ok, proposal} = Team.start_proposal(%{"goal" => goal, "colony_id" => ctx.cid}, ctx.actor)
    {:ok, task} = Store.get_task(proposal["task_id"])
    {:ok, proposal} = Team.plan_complete(task, draft_json())
    {proposal, task}
  end

  defp approve(ctx, proposal) do
    {:ok, %{"template" => template}} = Team.decide_proposal(proposal["id"], "approve", ctx.actor)
    template
  end

  defp start_run(ctx, template, goal \\ "记账小程序：记录收支并出月报") do
    {:ok, run} = Team.start_run(%{"template_id" => template["id"], "goal" => goal, "name" => "记账项目"}, ctx.actor)
    run
  end

  defp current_task(run) do
    {:ok, run} = Team.get_run(run["id"])
    {:ok, task} = Store.get_task(run["current_task_id"])
    task
  end

  defp submit(task, content) do
    {:ok, task} = Store.get_task(task["id"])

    {:ok, honey} =
      Work.submit(
        task["colony_id"],
        task["id"],
        %{"content" => content, "work_revision" => task["context_revision"]},
        task["assigned_bee_id"]
      )

    honey
  end

  defp accept_stage(run, content) do
    task = current_task(run)
    honey = submit(task, content)
    {:ok, run} = Team.review_stage(run["id"], honey["id"], "accept", run["created_by"], "通过")
    {run, honey}
  end

  # ── 模板模式 ──

  test "内置产研模板可规范化：5角色5阶段，测试打回研发" do
    {:ok, t} = TeamTemplate.normalize(TeamTemplate.product_team())
    assert length(t["roles"]) == 5
    assert length(t["stages"]) == 5
    assert TeamTemplate.lead_key(t) == "pm"
    test_stage = Enum.find(t["stages"], &(&1["key"] == "test"))
    assert test_stage["rework_to"] == "develop"
    assert Enum.find(t["stages"], &(&1["key"] == "develop"))["gate"] == "auto"
  end

  test "非法模板被拒绝：未知角色、未知回退目标、重复key、轮次越界" do
    base = TeamTemplate.product_team()
    assert {:error, "bad_request", _} = TeamTemplate.normalize(%{base | "roles" => []})
    bad_stage = put_in(base, ["stages", Access.at(0), "role"], "nobody")
    assert {:error, "bad_request", _} = TeamTemplate.normalize(bad_stage)
    bad_rework = put_in(base, ["stages", Access.at(4), "rework_to"], "nowhere")
    assert {:error, "bad_request", _} = TeamTemplate.normalize(bad_rework)
    dup = update_in(base, ["roles"], fn [r | rest] -> [r, r | rest] end)
    assert {:error, "bad_request", _} = TeamTemplate.normalize(dup)
    assert {:error, "bad_request", _} = TeamTemplate.normalize(%{base | "max_rounds" => 99})
  end

  # ── main 提案 → 审批 ──

  test "提案创建 main 角色与规划任务，上下文带输出契约", ctx do
    {:ok, proposal} = Team.start_proposal(%{"goal" => "做一个记账小程序", "colony_id" => ctx.cid}, ctx.actor)
    assert proposal["status"] == "planning"
    {:ok, main} = Store.get_bee(proposal["main_bee_id"])
    assert main["display"] == "团队主理人"
    assert main["role"] == "main"
    {:ok, task} = Store.get_task(proposal["task_id"])
    assert task["mode"] == "team_plan"
    context = Work.context(task)
    assert context =~ "团队主理人"
    assert context =~ "输出契约"
    assert context =~ "做一个记账小程序"
    # 规划任务有投递，等执行器派发
    assert Enum.any?(Store.all("deliveries"), &(&1["task_id"] == task["id"]))
  end

  test "main 草案就绪后等待审批；批准入库模板并收尾任务", ctx do
    {proposal, task} = propose_and_plan(ctx)
    assert proposal["status"] == "draft_ready"
    assert proposal["draft"]["name"] == "产研团队"
    {:ok, planned} = Store.get_task(task["id"])
    assert planned["status"] == "blocked"
    assert planned["waiting_for"] == "user"

    template = approve(ctx, proposal)
    assert template["source"] == "proposal"
    assert {:ok, ^template} = Team.get_template(template["id"])
    {:ok, approved} = Team.get_proposal(proposal["id"])
    assert approved["status"] == "approved"
    assert approved["template_id"] == template["id"]
    {:ok, closed} = Store.get_task(task["id"])
    assert closed["status"] == "done"
    # 幂等：重复批准返回同一模板
    assert {:ok, ^template} = Team.decide_proposal(proposal["id"], "approve", ctx.actor)
  end

  test "无效草案不入库，可带意见重新规划且有预算上限", ctx do
    {:ok, proposal} = Team.start_proposal(%{"goal" => "目标", "colony_id" => ctx.cid}, ctx.actor)
    {:ok, task} = Store.get_task(proposal["task_id"])
    {:ok, proposal} = Team.plan_complete(task, "我觉得这个团队不错")
    assert proposal["status"] == "draft_invalid"
    assert Team.list_templates() == []

    {:ok, retried} = Team.retry_proposal(proposal["id"], ctx.actor, "角色要含测试")
    assert retried["status"] == "planning"
    {:ok, task2} = Store.get_task(proposal["task_id"])
    assert task2["context_revision"] > task["context_revision"]
    {:ok, proposal2} = Team.plan_complete(task2, "```json\n" <> draft_json() <> "\n```")
    assert proposal2["status"] == "draft_ready"
  end

  test "驳回提案不产生模板", ctx do
    {proposal, _task} = propose_and_plan(ctx)
    {:ok, %{"proposal" => rejected}} = Team.decide_proposal(proposal["id"], "reject", ctx.actor, "不需要")
    assert rejected["status"] == "rejected"
    assert Team.list_templates() == []
    assert {:error, "terminal", _} = Team.retry_proposal(proposal["id"], ctx.actor)
  end

  test "无 colony 的提案进入临时组建群，批准后保留记录可追溯", ctx do
    {:ok, proposal} = Team.start_proposal(%{"goal" => "独立组建"}, ctx.actor)
    refute proposal["colony_id"] == ctx.cid
    {:ok, task} = Store.get_task(proposal["task_id"])
    {:ok, proposal} = Team.plan_complete(task, draft_json())
    _ = approve(ctx, proposal)
    assert {:ok, %{"status" => "approved"}} = Team.get_proposal(proposal["id"])
  end

  # ── 引用模板开项目 ──

  test "启动项目：按模板建角色蜂群并派发第一阶段", ctx do
    {proposal, _} = propose_and_plan(ctx)
    template = approve(ctx, proposal)
    run = start_run(ctx, template)

    {:ok, colony} = Store.get_colony(run["colony_id"])
    assert colony["name"] == "记账项目"
    members = Store.bees_for_colony(run["colony_id"])
    displays = Enum.map(members, & &1["display"])
    for name <- ["产品经理", "UI交互设计师", "架构师", "研发工程师", "测试工程师"], do: assert(name in displays)
    # 没有多余的默认研发助手
    refute "研发助手" in displays

    task = current_task(run)
    assert task["team_stage"] == "research"
    assert task["assigned_bee_id"] == run["role_bees"]["pm"]
    assert task["title"] =~ "第1轮 · 产品调研设计"
    context = Work.context(task)
    assert context =~ "团队运营上下文"
    assert context =~ "产品经理"
    assert context =~ "记账小程序"
  end

  test "全流程闭环：调研→设计→架构→研发(auto)→测试→完成", ctx do
    {proposal, _} = propose_and_plan(ctx)
    template = approve(ctx, proposal)
    run = start_run(ctx, template)

    {run, prd} = accept_stage(run, "PRD v1：目标用户与验收标准")
    assert current_task(run)["team_stage"] == "design"
    # 下游上下文携带上游已验收成果（沟通机制）
    assert Work.context(current_task(run)) =~ "PRD v1"

    {run, _} = accept_stage(run, "交互说明 v1")
    assert current_task(run)["team_stage"] == "arch"
    {run, _} = accept_stage(run, "技术方案 v1")
    assert current_task(run)["team_stage"] == "develop"

    # develop 是 auto 闸门：提交成果后 stage_complete 自动验收并推进
    dev_task = current_task(run)
    _honey = submit(dev_task, "实现完成，测试通过")
    {:ok, :ignored} = Team.stage_complete(dev_task)
    {:ok, run} = Team.get_run(run["id"])
    # stage_complete 用旧 task 快照会 ignored；用最新快照驱动（与 Runtime 相同路径）
    {:ok, fresh} = Store.get_task(dev_task["id"])
    {:ok, _} = Team.stage_complete(fresh)
    {:ok, run} = Team.get_run(run["id"])
    assert run["stage_index"] == 4
    assert current_task(run)["team_stage"] == "test"
    dev_history = Enum.find(run["history"], &(&1["stage"] == "develop"))
    assert dev_history["verdict"] == "accept"

    {run, _} = accept_stage(run, "测试报告：全部通过")
    assert run["status"] == "completed"
    assert length(run["history"]) == 5
    assert is_binary(run["final_honey_id"])
    assert prd["id"] in Enum.map(run["history"], & &1["honey_id"])

    # 完成后确认结束
    {:ok, closed} = Team.finish(run["id"], "complete", ctx.actor)
    assert closed["status"] == "closed"
  end

  test "测试打回回到研发重做，反馈进入下一轮上下文", ctx do
    {proposal, _} = propose_and_plan(ctx)
    template = approve(ctx, proposal)
    run = start_run(ctx, template)
    {run, _} = accept_stage(run, "PRD")
    {run, _} = accept_stage(run, "交互")
    {run, _} = accept_stage(run, "架构")
    dev_task = current_task(run)
    submit(dev_task, "实现 v1")
    {:ok, fresh} = Store.get_task(dev_task["id"])
    {:ok, _} = Team.stage_complete(fresh)
    {:ok, run} = Team.get_run(run["id"])

    test_task = current_task(run)
    honey = submit(test_task, "发现阻断缺陷：月报金额错误")
    {:ok, run} = Team.review_stage(run["id"], honey["id"], "reject", ctx.actor, "月报金额计算错误，必须修复")

    assert run["status"] == "active"
    assert run["round"] == 2
    assert run["reworks"] == 1
    redo = current_task(run)
    assert redo["team_stage"] == "develop"
    assert redo["team_round"] == 2
    assert redo["assigned_bee_id"] == run["role_bees"]["dev"]
    context = Work.context(redo)
    assert context =~ "月报金额计算错误"
    assert context =~ "第 2 轮"
    # 旧任务已终态，不会被重复派发
    {:ok, old} = Store.get_task(test_task["id"])
    assert old["status"] == "blocked"
  end

  test "轮次预算用尽后停下等人，提高预算可继续", ctx do
    {proposal, _} = propose_and_plan(ctx)
    _template = approve(ctx, proposal)
    # 用单阶段模板快速触发预算：max_rounds=1
    single = %{
      "name" => "单阶段",
      "roles" => [%{"key" => "dev", "name" => "研发", "duty" => "实现"}],
      "stages" => [
        %{"key" => "build", "name" => "实现", "role" => "dev", "goal" => "交付", "gate" => "review", "rework_to" => "build"}
      ],
      "max_rounds" => 1
    }

    {:ok, small} = Team.save_template(single, ctx.actor)
    run = start_run(ctx, small, "小项目")

    task = current_task(run)
    honey = submit(task, "v1")
    {:ok, run} = Team.review_stage(run["id"], honey["id"], "reject", ctx.actor, "不行")
    assert run["round"] == 2

    task2 = current_task(run)
    honey2 = submit(task2, "v2")
    {:ok, run} = Team.review_stage(run["id"], honey2["id"], "reject", ctx.actor, "还是不行")
    assert run["status"] == "halted"
    assert run["halt_reason"] == "round_budget"
    assert {:error, "invalid_phase", _} = Team.review_stage(run["id"], honey2["id"], "accept", ctx.actor)

    {:ok, run} = Team.extend(run["id"], 2, ctx.actor)
    assert run["status"] == "active"
    assert run["template"]["max_rounds"] == 3
    assert current_task(run)["team_round"] == 2
  end

  test "完成后继续迭代：回到第一阶段并带上反馈", ctx do
    {proposal, _} = propose_and_plan(ctx)
    template = approve(ctx, proposal)
    run = start_run(ctx, template)
    {run, _} = accept_stage(run, "PRD")
    {run, _} = accept_stage(run, "交互")
    {run, _} = accept_stage(run, "架构")
    dev_task = current_task(run)
    submit(dev_task, "实现")
    {:ok, fresh} = Store.get_task(dev_task["id"])
    {:ok, _} = Team.stage_complete(fresh)
    {:ok, run} = Team.get_run(run["id"])
    {run, _} = accept_stage(run, "测试通过")
    assert run["status"] == "completed"

    {:ok, run} = Team.finish(run["id"], "iterate", ctx.actor, "增加导出功能")
    assert run["status"] == "active"
    assert run["round"] == 2
    task = current_task(run)
    assert task["team_stage"] == "research"
    assert Work.context(task) =~ "增加导出功能"
  end

  test "阶段回调与验收幂等：重复提交/重复验收不重复推进", ctx do
    {proposal, _} = propose_and_plan(ctx)
    template = approve(ctx, proposal)
    run = start_run(ctx, template)
    task = current_task(run)
    honey = submit(task, "PRD")

    {:ok, run1} = Team.review_stage(run["id"], honey["id"], "accept", ctx.actor)
    assert run1["stage_index"] == 1
    # 同一成果再次验收：任务已不是当前阶段 → 明确报错而不是重复推进
    assert {:error, "invalid_phase", _} = Team.review_stage(run["id"], honey["id"], "accept", ctx.actor)
    {:ok, run2} = Team.get_run(run["id"])
    assert run2["stage_index"] == 1
    assert length(run2["history"]) == 1
    # stage_complete 对已推进的旧任务忽略
    assert {:ok, :ignored} = Team.stage_complete(task)
  end

  test "内置模板种子幂等，运行视图给出阶段状态", ctx do
    {:ok, t1} = Team.seed_builtin(ctx.actor)
    {:ok, t2} = Team.seed_builtin(ctx.actor)
    assert t1["id"] == t2["id"]
    assert t1["source"] == "builtin"

    run = start_run(ctx, t1)
    {:ok, view} = Team.run_view(run["id"])
    assert Enum.at(view["stages"], 0)["state"] == "current"
    assert Enum.at(view["stages"], 1)["state"] == "pending"
    assert view["current_task"]["id"] == run["current_task_id"]
    assert length(view["members"]) == 6
  end
end
