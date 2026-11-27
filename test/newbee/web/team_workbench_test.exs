defmodule Newbee.Web.TeamWorkbenchTest do
  use ExUnit.Case, async: true
  alias Newbee.Web.TeamWorkbench

  defp row(id, extra), do: Map.merge(%{"id" => id, "created_at" => 1, "title" => id}, extra)

  test "the queue folds children and stage execution into the owning record" do
    data = %{
      "tasks" => %{
        "work" => row("work", %{"conversation" => true, "origin_session_id" => "s", "status" => "pending_review"}),
        "child" => row("child", %{"conversation" => true, "conversation_child" => true, "status" => "pending_review"}),
        "hidden" => row("hidden", %{"conversation" => true, "conversation_hidden" => true, "status" => "done"}),
        "stage" => row("stage", %{"team_run_id" => "team", "status" => "done", "colony_id" => "c"}),
        "planner" => row("planner", %{"status" => "done"}),
        "old" => row("old", %{"status" => "cancelled", "colony_id" => "manual"})
      },
      "colonies" => %{"c" => row("c", %{})},
      "team_runs" => %{
        "team" => row("team", %{"status" => "completed", "current_task_id" => "stage", "colony_id" => "c"})
      },
      "team_proposals" => %{"p" => row("p", %{"status" => "draft_invalid", "task_id" => "planner"})}
    }

    assert %{queues: queues, counts: %{"attention" => 3, "history" => 1}, colonies: []} =
             TeamWorkbench.project(data, [], [])

    assert Map.new(queues["attention"], &{&1.id, &1.state}) == %{
             "work" => "review",
             "team" => "confirm",
             "p" => "blocked"
           }

    assert [%{id: "old", state: "stopped"}] = queues["history"]
  end

  test "Hive submitted and verified states stay distinct and navigation retains source identifiers" do
    empty = Map.new(~w(tasks colonies team_runs team_proposals), &{&1, %{}})
    base = %{"group_id" => "g", "session_id" => "s", "updated_at" => "2026-01-01T00:00:00Z"}

    hive = [
      Map.merge(base, %{"task_id" => "t", "status" => "submitted"}),
      Map.merge(base, %{"task_id" => "u", "status" => "succeeded"})
    ]

    groups = [%{"group_id" => "g", "title" => "项目", "members" => ["private"]}]

    out = TeamWorkbench.project(empty, groups, [], hive)

    assert [%{kind: "hive", id: "t", state: "review", target: %{session_id: "s", group_id: "g"}}] =
             out.queues["attention"]

    assert [%{id: "u", state: "delivered", updated_at: 1_767_225_600_000}] = out.queues["history"]
    assert out.groups == [%{"group_id" => "g", "title" => "项目"}]
  end

  test "cross-device tickets retain the group and task IDs and do not imply file delivery" do
    empty = Map.new(~w(tasks colonies team_runs team_proposals), &{&1, %{}})
    waiting = row("waiting", %{"status" => "waiting_input", "group_id" => "cross", "description" => "private"})
    finished = row("finished", %{"status" => "done", "group_id" => "cross"})

    out = TeamWorkbench.project(empty, [], [], [], [waiting, finished])

    assert [%{id: "waiting", kind: "remote_task", state: "answer", target: %{group_id: "cross", task_id: "waiting"}}] =
             out.queues["attention"]

    assert [%{state: "finished"}] = out.queues["history"]
    refute inspect(out) =~ "private"
  end
end
