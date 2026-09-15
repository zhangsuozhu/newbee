defmodule Newbee.Colony.DrillHoneyTest do
  use ExUnit.Case, async: false

  alias Newbee.Colony.{Engine, Store, Work}

  setup do
    Store.clear_all()
    {:ok, colony} = Engine.create_colony(%{"name" => "深钻成果"})
    %{cid: colony["id"], actor: colony["queen_bee_id"]}
  end

  # 人的提交（colony.work.submit）不写任务级 Trace；如果 drill 只给 trace，
  # 「已提交、待验收」的任务在详情里就会显示「还没有工作记录」，也验收不了。
  test "任务深钻带上该子树的成果", %{cid: cid, actor: actor} do
    {:ok, task} = Work.create(cid, %{"title" => "写文档", "assigned_bee_id" => actor})
    {:ok, _honey} = Work.submit(cid, task["id"], %{"content" => "成果正文", "limitations" => []}, actor)

    assert {:ok, drill} = Engine.drill(cid, task["id"])
    assert [honey] = drill["honey"]
    assert honey["task_id"] == task["id"]
    assert honey["review_state"] == "pending_review"
    assert honey["content"] =~ "成果正文"
    assert drill["trace"] == []
  end
end
