defmodule Newbee.Colony.ConversationDecompositionTest do
  use ExUnit.Case, async: false
  alias Newbee.Colony.{ConversationWork, Store, Workflow, Workspace, Work, Control}
  @moduletag :tmp_dir

  setup %{tmp_dir: root} do
    File.mkdir_p!(root)
    File.write!(Path.join(root, "source.txt"), "original\n")
    :ok = Store.clear_all()
    sid = "coord-origin-#{System.unique_integer([:positive])}"
    :ok = Newbee.Session.set_cwd(sid, root)
    :ok = Newbee.Session.mark_created(sid)
    %{root: root, sid: sid}
  end

  defp planned(%{root: root, sid: sid}) do
    {:ok, result} = ConversationWork.start(sid, root, "完善导出模块：实现并独立验证", "start")
    id = result["work"]["id"]
    {:ok, task} = Store.get_task(id)
    {:ok, _} = Workspace.ensure(task, root)
    {:ok, task} = Store.get_task(id)
    delivery = Enum.find(Store.all("deliveries"), &(&1["task_id"] == id))
    {:ok, _} = Store.update("deliveries", delivery["id"], nil, &{:ok, Map.put(&1, "status", "accepted")})
    :ok = ConversationWork.consumed(delivery["id"])

    plan = %{
      "summary" => "两项独立分工后汇总验证",
      "tasks" => [
        %{
          "id" => "implementation",
          "title" => "实现导出逻辑",
          "scope" => "仅实现导出模块；运行模块用例；不修改其他目录",
          "depends_on" => [],
          "acceptance" => ["模块用例通过"]
        },
        %{
          "id" => "review",
          "title" => "独立核对兼容性",
          "scope" => "只读核对接口边界并提交验证依据",
          "depends_on" => [],
          "acceptance" => ["给出兼容性报告"]
        }
      ]
    }

    assert {:ok, _} = Workflow.complete(task, Jason.encode!(plan), task["context_revision"])
    {:ok, task} = Store.get_task(id)

    children =
      task["workflow"]["children"]
      |> Enum.map(fn child ->
        {:ok, item} = Store.get_task(child)
        item
      end)

    {task, children}
  end

  test "direct task entry creates a decomposition root without source configuration", ctx do
    {:ok, result} = ConversationWork.start(ctx.sid, ctx.root, "做一个导出功能并测试", "direct")
    task = result["work"]
    assert task["coordination"]["phase"] == "planning"
    assert task["coordination"]["total"] == 0
    assert Store.all("source_instances") == []
    assert length(Store.list_bees()) == 2
  end

  test "only the root appears in conversation lists, history and public mutations", ctx do
    {root, [child | _]} = planned(ctx)
    assert [view] = ConversationWork.list(ctx.sid)
    assert view["id"] == root["id"]
    assert view["coordination"]["total"] == 2
    assert view["stage"] == "working"
    assert {:error, "not_found", _} = ConversationWork.fetch(ctx.sid, child["id"])
    assert {:error, "not_found", _} = ConversationWork.input(ctx.sid, child["id"], "不能直接修改子项", "direct-child")
    {:ok, _} = Store.update("tasks", child["id"], nil, &{:ok, Map.put(&1, "session_id", "hidden-child-session")})

    entries =
      ConversationWork.project_index([
        %{"id" => ctx.sid, "mtime" => 0},
        %{"id" => "hidden-child-session", "mtime" => 0}
      ])

    assert [%{"id" => sid, "background_count" => 1}] = entries
    assert sid == ctx.sid
    assert [%{"role" => "user"}] = ConversationWork.merge_messages(ctx.sid, [])
  end

  test "child questions are answered from the root once, with real consumption receipts", ctx do
    {root, [child | _]} = planned(ctx)

    q =
      ConversationWork.question(child, %{
        question: "空日期如何表示？",
        kind: "single",
        options: [%{label: "空字符串", value: "empty"}]
      })

    {:ok, _} =
      Store.update(
        "tasks",
        child["id"],
        nil,
        &{:ok, Map.merge(&1, %{"status" => "blocked", "waiting_for" => "user", "question" => q})}
      )

    {:ok, current} = Store.get_task(root["id"])
    assert ConversationWork.view(current)["question"]["task_title"] == child["title"]
    assert {:ok, answer} = ConversationWork.answer(ctx.sid, root["id"], q["id"], "空字符串", "answer-child")
    assert answer["work"]["question"] == nil
    assert {:ok, retry} = ConversationWork.answer(ctx.sid, root["id"], q["id"], "空字符串", "answer-child")
    assert retry["input_id"] == answer["input_id"]
    assert {:error, "stale_question", _} = ConversationWork.answer(ctx.sid, root["id"], q["id"], "改答案", "stale")
    {:ok, after_answer} = Store.get_task(child["id"])
    assert after_answer["last_answer"]["answer"] == "空字符串"
    input = List.last(after_answer["inputs"])
    :ok = ConversationWork.consumed(input["delivery_id"])
    {:ok, root} = Store.get_task(root["id"])
    assert List.last(root["inputs"])["consumed_at"] > 0
    assert List.last(root["inputs"])["delegated_work_id"] == child["id"]
  end

  test "follow-up fans out idempotently without starting a parallel coordinator writer", ctx do
    {root, children} = planned(ctx)
    assert {:ok, reply} = ConversationWork.input(ctx.sid, root["id"], "保留现有日期格式", "followup")
    assert {:ok, _} = ConversationWork.input(ctx.sid, root["id"], "保留现有日期格式", "followup")
    input = List.last(reply["work"]["inputs"])
    {:ok, held} = Store.get("deliveries", input["delivery_id"])
    assert held["status"] == "held"
    assert reply["work"]["stage"] == "working"

    for child <- children do
      {:ok, current} = Store.get_task(child["id"])
      assert length(current["inputs"]) == 1
      assert List.last(current["inputs"])["text"] =~ "保留现有日期格式"
    end

    assert length(Store.all("command_receipts")) == 2
  end

  test "pause covers every child, resume fences each writer, and stop cancels queued children", ctx do
    {root, children} = planned(ctx)
    assert {:ok, paused} = ConversationWork.control(ctx.sid, root["id"], "pause")
    assert paused["work"]["stage"] == "paused"
    assert Enum.all?(children, &Control.blocked?(&1["colony_id"], &1["assigned_bee_id"], &1["id"]))
    assert {:ok, resumed} = ConversationWork.control(ctx.sid, root["id"], "resume")
    assert resumed["work"]["stage"] == "working"
    assert resumed["work"]["execution_generation"] == 2

    for child <- children do
      {:ok, current} = Store.get_task(child["id"])
      assert current["execution_generation"] == 2
      assert Enum.count(Store.all("deliveries"), &(&1["task_id"] == child["id"] and &1["status"] == "pending")) == 1
    end

    assert {:ok, _} = ConversationWork.control(ctx.sid, root["id"], "stop")
    assert Enum.all?(Store.list_tasks(), &(&1["status"] == "cancelled"))
    assert Enum.all?(Store.all("deliveries"), &(&1["status"] not in ["pending", "dispatching", "accepted"]))
    assert File.read!(Path.join(ctx.root, "source.txt")) == "original\n"
  end

  test "a failed isolated child can be retried without restarting its siblings", ctx do
    {root, [failed, other]} = planned(ctx)

    {:ok, _} =
      Store.update(
        "tasks",
        failed["id"],
        nil,
        &{:ok, Map.merge(&1, %{"status" => "blocked", "waiting_for" => nil, "next_step" => "模型暂时不可用"})}
      )

    assert {:ok, retried} = ConversationWork.control(ctx.sid, root["id"], "retry")
    assert retried["work"]["stage"] == "working"
    {:ok, next_failed} = Store.get_task(failed["id"])
    {:ok, same_other} = Store.get_task(other["id"])
    assert next_failed["execution_generation"] == 2
    assert same_other["execution_generation"] == other["execution_generation"]
    assert same_other["revision"] == other["revision"]
  end

  test "supplementing uncertain execution holds new delivery until explicit recovery", ctx do
    {root, [child | _]} = planned(ctx)

    {:ok, _} =
      Store.update(
        "tasks",
        child["id"],
        nil,
        &{:ok, Map.merge(&1, %{"status" => "blocked", "waiting_for" => nil, "next_step" => "执行回执丢失，无法确认外部操作是否完成"})}
      )

    assert {:ok, _} = ConversationWork.input(ctx.sid, root["id"], "保留已有格式", "uncertain-extra")
    {:ok, current} = Store.get_task(child["id"])
    assert current["status"] == "blocked"
    assert current["next_step"] =~ "回执丢失"
    pending_input = List.last(current["inputs"])
    {:ok, delivery} = Store.get("deliveries", pending_input["delivery_id"])
    assert delivery["status"] == "held"
  end

  test "late child completion after stop cannot create results or integrate", ctx do
    {root, [child | _]} = planned(ctx)
    {:ok, _} = ConversationWork.control(ctx.sid, root["id"], "stop")

    assert {:error, _, _} =
             Work.submit(
               child["colony_id"],
               child["id"],
               %{"content" => "迟到结果", "work_revision" => child["context_revision"]},
               child["assigned_bee_id"]
             )

    :ok = Workflow.advance()
    {:ok, stopped} = Store.get_task(root["id"])
    assert stopped["status"] == "cancelled"
    assert Store.all("honey") == []
  end
end
