defmodule Newbee.Colony.DecompositionTest do
  use ExUnit.Case, async: false
  alias Newbee.Colony.{ConversationWork, Store, Workflow, Workspace, Work, Control, Decomposition}
  @moduletag :tmp_dir
  setup %{tmp_dir: root} do
    File.mkdir_p!(root)
    :ok = Store.clear_all()
    sid = "dag-#{System.unique_integer([:positive])}"
    {:ok, result} = ConversationWork.start(sid, root, "实现功能并验证交付", "start")
    {:ok, task} = Store.get_task(result["work"]["id"])
    {:ok, _} = Workspace.ensure(task, root)
    {:ok, task} = Store.get_task(task["id"])
    delivery = Enum.find(Store.all("deliveries"), &(&1["task_id"] == task["id"]))
    {:ok, _} = Store.update("deliveries", delivery["id"], nil, &{:ok, Map.put(&1, "status", "accepted")})
    :ok = ConversationWork.consumed(delivery["id"])
    %{root: root, sid: sid, task: task}
  end

  defp item(id, deps \\ []),
    do: %{
      "id" => id,
      "title" => "任务 #{id}",
      "scope" => "只修改#{id}模块，运行对应测试并报告结果",
      "acceptance" => ["指定测试通过"],
      "depends_on" => deps
    }

  defp plan(ctx, tasks) do
    assert {:ok, _} =
             Workflow.complete(
               ctx.task,
               Jason.encode!(%{"summary" => "分工并集成", "tasks" => tasks}),
               ctx.task["context_revision"]
             )

    {:ok, task} = Store.get_task(ctx.task["id"])
    task
  end

  defp children(task),
    do:
      Enum.map(task["workflow"]["children"], fn id ->
        {:ok, child} = Store.get_task(id)
        child
      end)

  defp finish(child, content \\ "分工已验证") do
    {:ok, _} =
      Work.submit(
        child["colony_id"],
        child["id"],
        %{"content" => content, "evidence" => ["module test passed"], "work_revision" => child["context_revision"]},
        child["assigned_bee_id"]
      )
  end

  test "four independent assignments start only three and recover a single free slot", ctx do
    task = plan(ctx, Enum.map(1..4, &item("task#{&1}")))
    [first, _, _, last] = children(task)
    assert Enum.count(children(task), &(&1["status"] == "claimed")) == 3
    assert last["waiting_for"] == "capacity"
    assert length(Store.all("deliveries")) == 4
    finish(first)
    :ok = Workflow.advance()
    {:ok, last} = Store.get_task(last["id"])
    assert last["status"] == "claimed"
    count = length(Store.all("deliveries"))
    :ok = Workflow.advance()
    assert length(Store.all("deliveries")) == count
  end

  test "dependency waits for current result and receives its real content and evidence", ctx do
    task = plan(ctx, [item("api"), item("tests", ["api"])])
    [first, second] = children(task)
    assert second["status"] == "blocked"
    assert second["depends_on"] == [first["id"]]
    finish(first, "API已实现，新增export_csv/2")
    :ok = Workflow.advance()
    {:ok, second} = Store.get_task(second["id"])
    delivery = Enum.find(Store.all("deliveries"), &(&1["task_id"] == second["id"]))
    assert second["status"] == "claimed"
    assert delivery["instruction"] =~ "API已实现"
    assert delivery["instruction"] =~ "module test passed"
  end

  test "illegal plans never allocate workers or deliveries", ctx do
    invalids = [
      nil,
      %{},
      [item("a"), item("a")],
      [item("a", ["missing"])],
      [item("a", ["a"])],
      [item("a", ["b"]), item("b", ["a"])],
      [42],
      [Map.put(item("a"), "id", %{})],
      [Map.put(item("a"), "acceptance", [])],
      Enum.map(1..5, &item("t#{&1}"))
    ]

    for tasks <- invalids do
      assert {:ok, _} =
               Workflow.complete(
                 ctx.task,
                 Jason.encode!(%{"summary" => "错误计划", "tasks" => tasks}),
                 ctx.task["context_revision"]
               )

      assert length(Store.list_tasks()) == 1
      assert length(Store.list_bees()) == 2
      assert length(Store.all("deliveries")) == 1
      {:ok, current} = Store.get_task(ctx.task["id"])
      assert current["status"] == "blocked"
      {:ok, _} = Store.update("tasks", current["id"], nil, fn _ -> {:ok, ctx.task} end)
    end
  end

  test "fenced JSON is accepted but malformed bracket order safely blocks", ctx do
    text = "说明\n```json\n" <> Jason.encode!(%{"summary" => "有界计划", "tasks" => [item("a")]}) <> "\n```"
    assert {:ok, _} = Workflow.complete(ctx.task, text, ctx.task["context_revision"])
    assert length(Store.list_tasks()) == 2

    data = %{
      "tasks" => %{ctx.task["id"] => ctx.task},
      "bees" => %{},
      "deliveries" => %{},
      "honey" => %{},
      "controls" => %{}
    }

    assert {:ok, {:ok, blocked}, _} = Decomposition.complete(data, ctx.task, "} garbage {")
    assert blocked["status"] == "blocked"
  end

  test "model configuration and execution isolation are inherited for every child", ctx do
    {:ok, root} =
      Store.update(
        "tasks",
        ctx.task["id"],
        nil,
        &{:ok, Map.put(&1, "execution_config", %{"provider" => "fixture", "model" => "model-a", "effort" => "high"})}
      )

    task = plan(%{ctx | task: root}, [item("a"), item("b")])

    for child <- children(task) do
      assert child["execution_config"] == root["execution_config"]
      assert child["workspace_source"] == root["workspace"]["path"]
      assert child["conversation_child"]
      assert child["created_by"] == root["created_by"]
      assert child["owner_kind"] == "ai"
      assert child["execution_generation"] == 1
    end

    assert length(Enum.uniq(Enum.map(children(task), & &1["assigned_bee_id"]))) == 2
  end

  test "all current children yield one integration delivery, even after restore", ctx do
    task = plan(ctx, [item("a"), item("b")])
    Enum.each(children(task), &finish/1)
    :ok = Workflow.advance()
    :ok = Store.restore()
    :ok = Workflow.advance()
    {:ok, task} = Store.get_task(task["id"])
    assert task["workflow"]["phase"] == "integrating"
    assert Enum.count(Store.all("deliveries"), &(&1["task_id"] == task["id"] and &1["status"] == "pending")) == 1
    assert Decomposition.view(task)["completed"] == 2
  end

  test "pause of this root holds ready work while unrelated pause does not", ctx do
    task = plan(ctx, [item("a"), item("b", ["a"])])
    [first, second] = children(task)
    finish(first)
    {:ok, _} = Control.set(task["colony_id"], "work", task["id"], "pause", actor_bee_id: task["created_by"])
    :ok = Workflow.advance()
    {:ok, held} = Store.get_task(second["id"])
    assert held["waiting_for"] == "dependencies"
    {:ok, _} = Control.set(task["colony_id"], "work", task["id"], "resume", actor_bee_id: task["created_by"])

    :ok =
      Store.put("controls", %{
        "id" => "unrelated:gate",
        "scope" => "colony",
        "target_id" => "unrelated",
        "colony_id" => "unrelated",
        "paused" => true
      })

    :ok = Workflow.advance()
    {:ok, ready} = Store.get_task(second["id"])
    assert ready["status"] == "claimed"
  end

  test "failed and stale child results never release dependencies or integration", ctx do
    task = plan(ctx, [item("a"), item("b", ["a"])])
    [first, second] = children(task)
    finish(first)
    {:ok, _} = Store.update("tasks", first["id"], nil, &{:ok, Map.update!(&1, "context_revision", fn v -> v + 1 end)})
    :ok = Workflow.advance()
    {:ok, second} = Store.get_task(second["id"])
    assert second["waiting_for"] == "dependencies"
    {:ok, _} = Store.update("tasks", first["id"], nil, &{:ok, Map.put(&1, "status", "failed")})
    :ok = Workflow.advance()
    {:ok, root} = Store.get_task(task["id"])
    assert root["workflow"]["phase"] == "executing"
  end
end
