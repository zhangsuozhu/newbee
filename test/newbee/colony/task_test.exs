defmodule Newbee.Colony.TaskTest do
  use ExUnit.Case, async: true

  alias Newbee.Colony.{Bee, Task}

  defp bee(attrs \\ %{}) do
    Bee.new(Map.merge(%{"colony_id" => "col_l_x", "kind" => "ai", "display" => "bot"}, attrs))
  end

  defp task(attrs \\ %{}) do
    Task.new(Map.merge(%{"colony_id" => "col_l_x", "title" => "做点事"}, attrs))
  end

  test "stimulus 随等待增长且封顶 1.0" do
    t = task(%{"priority" => 0.2, "created_at" => 0})
    s0 = Task.stimulate(t, 0)
    s1 = Task.stimulate(t, 60_000)
    s2 = Task.stimulate(t, 3_600_000)
    assert s1 > s0
    assert s2 <= 1.0
  end

  test "能力不匹配为硬门槛（score=:infinity，不会抢到干不了的活）" do
    b = bee(%{"capabilities" => ["edit"]})
    t = task(%{"requires" => ["shell"]})
    assert Task.score(b, t) == :infinity
    assert Task.claim(t, b) == {:error, :incapable}
  end

  test "claim 用 CAS：同一时刻只有一个 Bee 能领到" do
    b1 = bee(%{"capabilities" => ["edit"]})
    b2 = bee(%{"capabilities" => ["edit"], "display" => "bot2"})
    t = task(%{"requires" => ["edit"]})

    assert {:ok, claimed} = Task.claim(t, b1)
    assert claimed["status"] == "claimed"
    assert claimed["revision"] == t["revision"] + 1
    assert claimed["assigned_bee_id"] == b1["id"]

    assert Task.claim(claimed, b2) == {:error, :conflict}
  end

  test "失联不允许抢占结果未知的工作" do
    b1 = bee(%{"capabilities" => ["edit"]})
    b2 = bee(%{"capabilities" => ["edit"], "display" => "bot2"})
    now = 10_000_000
    {:ok, claimed} = Task.claim(task(%{"requires" => ["edit"]}), b1, now)

    assert Task.claim(claimed, b2, now + 60_000) == {:error, :conflict}
    assert {:error, :conflict} = Task.claim(claimed, b2, now + 20 * 60 * 1000)
    assert claimed["assigned_bee_id"] == b1["id"]
  end

  test "状态迁移合法路径与非法路径" do
    b = bee(%{"capabilities" => ["edit"]})
    {:ok, t} = Task.claim(task(%{"requires" => ["edit"]}), b)

    assert {:ok, running} = Task.transition(t, "start")
    assert running["status"] == "running"

    assert {:ok, blocked} = Task.transition(running, "block")
    assert {:ok, run2} = Task.transition(blocked, "unblock")

    assert {:ok, done} = Task.transition(run2, "complete", result: %{"ok" => true})
    assert done["status"] == "done"
    assert done["completed_at"]

    assert {:error, :invalid_transition} = Task.transition(done, "start")
  end

  test "release 让任务回流（执行者离开时）" do
    b = bee(%{"capabilities" => ["edit"]})
    {:ok, t} = Task.claim(task(%{"requires" => ["edit"]}), b)
    {:ok, released} = Task.transition(t, "release")
    assert released["status"] == "pending"
    assert released["assigned_bee_id"] == nil
    assert released["revision"] == t["revision"] + 1
  end

  test "decompose 受并行与深度预算约束，并记录父子关系" do
    b = bee(%{"capabilities" => ["edit"]})
    parent = task(%{"requires" => ["edit"], "budget" => %{"max_children" => 2, "max_depth" => 2}})
    {:ok, parent} = Task.claim(parent, b)
    all = [parent]

    {:ok, children} = Task.decompose(parent, [%{"title" => "a"}, %{"title" => "b"}], all)
    assert length(children) == 2
    assert Enum.all?(children, &(&1["parent_task_id"] == parent["id"]))
    assert Enum.all?(children, &(&1["coordinator_bee_id"] == b["id"]))

    assert {:error, :budget_exceeded} =
             Task.decompose(parent, [%{"title" => "c"}], all ++ children)

    assert {:error, :budget_exceeded} =
             Task.decompose(parent, [%{"title" => "c"}, %{"title" => "d"}], all ++ children)

    # 深度：parent(1) -> child(2) 后不能再拆（max_depth 2）
    [c1 | _] = children
    assert {:error, :depth_exceeded} = Task.decompose(c1, [%{"title" => "深"}], all ++ children)
  end

  test "tree 组装嵌套任务树" do
    parent = task(%{"id" => "task_l_p"})
    child = task(%{"id" => "task_l_c", "parent_task_id" => "task_l_p"})
    grand = task(%{"id" => "task_l_g", "parent_task_id" => "task_l_c"})

    [root] = Task.tree([parent, child, grand])
    assert root["id"] == "task_l_p"
    assert [c] = root["children"]
    assert [g] = c["children"]
    assert g["id"] == "task_l_g"
  end

  test "public 附带 stimulus 与终态标记" do
    t = task(%{"status" => "done"})
    pub = Task.public(t)
    assert is_float(pub["stimulus"])
    assert pub["is_terminal"] == true
  end
end
