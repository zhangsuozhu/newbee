defmodule Newbee.Colony.DrillHoneyTest do
  use ExUnit.Case, async: false

  alias Newbee.Colony.{Engine, Store, Work}

  setup do
    Store.clear_all()
    {:ok, colony} = Engine.create_colony(%{"name" => "深钻成果"})
    %{cid: colony["id"], actor: colony["queen_bee_id"]}
  end

  # 人的提交（colony.work.submit）以前不写任务级 Trace，drill 只给 trace 时
  # 「已提交、待验收」的任务在详情里会显示「还没有工作记录」，也验收不了。
  test "任务深钻带上该子树的成果，且人提交/验收会留痕", %{cid: cid, actor: actor} do
    {:ok, task} = Work.create(cid, %{"title" => "写文档", "assigned_bee_id" => actor})
    {:ok, honey} = Work.submit(cid, task["id"], %{"content" => "成果正文", "limitations" => []}, actor)

    assert {:ok, drill} = Engine.drill(cid, task["id"])
    assert [listed] = drill["honey"]
    assert listed["task_id"] == task["id"]
    assert listed["review_state"] == "pending_review"
    assert listed["content"] =~ "成果正文"

    # 提交留痕：任务轨迹里能看到这次提交（以前是空的）
    assert [submit_entry] = drill["trace"]
    assert submit_entry["type"] == "honey"
    assert submit_entry["task_id"] == task["id"]
    assert submit_entry["data"]["honey_id"] == honey["id"]
    assert submit_entry["text"] =~ "产出成果"

    # 验收也留痕
    assert {:ok, _} = Work.review(cid, honey["id"], "accept", actor, "")
    assert {:ok, drill2} = Engine.drill(cid, task["id"])
    assert Enum.any?(drill2["trace"], &(&1["text"] =~ "已验收通过"))
  end
end
