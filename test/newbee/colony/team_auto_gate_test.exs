defmodule Newbee.Colony.TeamAutoGateTest do
  # R2P-01 回归：team_run 的 auto 闸门必须真的推进 stage_index。
  # 这里刻意走真实调用点 Runtime.project_remote/3（runtime.ex 的 done 分支），
  # 而不是直接调 Team.stage_complete/1 —— 缺陷正是"调用点传了旧快照"。
  use ExUnit.Case, async: false

  alias Newbee.Colony.{Store, Engine, Work, Team, TeamTemplate, Runtime}

  setup do
    Store.clear_all()
    {:ok, colony} = Engine.create_colony(%{"name" => "主蜂群"})
    %{cid: colony["id"], actor: colony["queen_bee_id"]}
  end

  defp start_run_at_auto_stage(ctx) do
    {:ok, proposal} = Team.start_proposal(%{"goal" => "记账小程序", "colony_id" => ctx.cid}, ctx.actor)
    {:ok, ptask} = Store.get_task(proposal["task_id"])
    {:ok, proposal} = Team.plan_complete(ptask, TeamTemplate.product_team() |> Jason.encode!())
    {:ok, %{"template" => template}} = Team.decide_proposal(proposal["id"], "approve", ctx.actor)

    {:ok, run} =
      Team.start_run(
        %{"template_id" => template["id"], "goal" => "记账", "name" => "自动闸门项目"},
        ctx.actor
      )

    run =
      Enum.reduce(1..3, run, fn _, run ->
        {:ok, run} = Team.get_run(run["id"])
        {:ok, task} = Store.get_task(run["current_task_id"])

        {:ok, honey} =
          Work.submit(
            task["colony_id"],
            task["id"],
            %{"content" => "阶段成果", "work_revision" => task["context_revision"]},
            task["assigned_bee_id"]
          )

        {:ok, run} = Team.review_stage(run["id"], honey["id"], "accept", run["created_by"], "通过")
        run
      end)

    {:ok, run} = Team.get_run(run["id"])
    %{run: run, template: template}
  end

  test "auto 闸门阶段完成即推进：走 Runtime 的真实提交路径 stage_index 3 → 4", ctx do
    %{run: run, template: template} = start_run_at_auto_stage(ctx)
    stage = Enum.at(template["stages"], run["stage_index"])
    assert stage["key"] == "develop"
    assert stage["gate"] == "auto"

    {:ok, dev_task} = Store.get_task(run["current_task_id"])
    assert dev_task["source"] == "team_run"
    assert dev_task["status"] == "claimed"

    # ★ 真实生产路径：Runtime 收到 done 事件 → Work.submit → Team.stage_complete
    Runtime.project_remote(dev_task, :done, %{summary: "实现完成，测试通过"})

    {:ok, after_run} = Team.get_run(run["id"])

    assert after_run["stage_index"] == 4,
           "auto 闸门必须推进；改前这里恒为 3（提交前的旧快照判定 → :ignored）"

    assert Enum.at(template["stages"], after_run["stage_index"])["key"] == "test"

    dev_history = Enum.find(after_run["history"], &(&1["stage"] == "develop"))
    assert dev_history["verdict"] == "accept"
    assert dev_history["note"] == "auto 闸门：完成即推进"
  end

  test "重复的 done 事件不会重复推进（幂等）", ctx do
    %{run: run} = start_run_at_auto_stage(ctx)
    {:ok, dev_task} = Store.get_task(run["current_task_id"])

    Runtime.project_remote(dev_task, :done, %{summary: "实现完成"})
    Runtime.project_remote(dev_task, :done, %{summary: "实现完成"})
    Runtime.project_remote(dev_task, :done, %{summary: "实现完成"})

    {:ok, after_run} = Team.get_run(run["id"])
    assert after_run["stage_index"] == 4, "同一份成果重复上报只能推进一次"
    assert Enum.count(after_run["history"], &(&1["stage"] == "develop")) == 1
  end

  test "review 闸门不受影响：成果停在待验收，等人决定（防过度推进）", ctx do
    %{run: run, template: template} = start_run_at_auto_stage(ctx)
    {:ok, dev_task} = Store.get_task(run["current_task_id"])
    Runtime.project_remote(dev_task, :done, %{summary: "实现完成"})
    {:ok, run} = Team.get_run(run["id"])
    assert Enum.at(template["stages"], run["stage_index"])["gate"] == "review"

    {:ok, test_task} = Store.get_task(run["current_task_id"])
    Runtime.project_remote(test_task, :done, %{summary: "测试报告：全部通过"})

    {:ok, after_run} = Team.get_run(run["id"])
    assert after_run["stage_index"] == 4, "review 闸门必须原地等人验收，不能自动推进"
    {:ok, after_task} = Store.get_task(test_task["id"])
    assert after_task["status"] == "pending_review"
  end

  test "stage_complete/1 对旧快照仍幂等 :ignored（判定语义不许改）", ctx do
    %{run: run} = start_run_at_auto_stage(ctx)
    {:ok, stale_task} = Store.get_task(run["current_task_id"])

    {:ok, _honey} =
      Work.submit(
        stale_task["colony_id"],
        stale_task["id"],
        %{"content" => "实现完成", "work_revision" => stale_task["context_revision"]},
        stale_task["assigned_bee_id"]
      )

    # 旧快照（status=claimed / result=nil）必须仍然 ignored：契约不变，
    # 修的是调用点（Runtime），不是判定。
    assert {:ok, :ignored} = Team.stage_complete(stale_task)

    {:ok, fresh} = Store.get_task(stale_task["id"])
    assert {:ok, _} = Team.stage_complete(fresh)
    {:ok, after_run} = Team.get_run(run["id"])
    assert after_run["stage_index"] == 4
  end
end
