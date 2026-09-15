defmodule Newbee.Colony.InteractionTargetTest do
  use ExUnit.Case, async: false

  alias Newbee.Colony.{Conversation, Engine, Interaction, Store}

  # 「这句话发给谁」的语义约束（前端据此把成员视图的输入转进对话）：
  # - 成员层级（一对一）里 colony.say 带 context.beeId 会走 Conversation.message；
  # - 而 AI 的 1:1 只能在内嵌对话里进行，服务端固定返回 conversation_required——
  #   所以蜂群页成员视图里给 AI 打字必须转进它的对话，不能直接 colony.say。
  # - 群聊里 @点名只投给被点名的人（仿微信群）。
  setup do
    Store.clear_all()
    {:ok, colony} = Engine.create_colony(%{"name" => "点名投递"})
    {:ok, a} = Engine.add_bee(colony["id"], %{"display" => "方案甲", "kind" => "ai"})
    {:ok, b} = Engine.add_bee(colony["id"], %{"display" => "方案乙", "kind" => "ai"})
    %{cid: colony["id"], actor: colony["queen_bee_id"], a: a, b: b}
  end

  test "给 AI 成员的 1:1 消息走 Conversation.message，且必须先打开它的对话", ctx do
    assert {:error, "conversation_required", msg} =
             Conversation.message(ctx.cid, ctx.b["id"], ctx.actor, "建个任务：写接口文档")

    assert msg =~ "对话"
  end

  test "给真人成员的 1:1 消息可以直接投递并落进 dm 轨迹", ctx do
    {:ok, human} = Engine.add_bee(ctx.cid, %{"display" => "同事", "kind" => "human"})
    assert {:ok, _} = Conversation.message(ctx.cid, human["id"], ctx.actor, "帮我看下这个")
    dm = Store.trace_for_colony(ctx.cid) |> Enum.filter(&(&1["channel"] == "dm"))
    assert Enum.any?(dm, &(&1["text"] == "帮我看下这个"))
  end

  test "群聊 @点名只投给被点名的人", ctx do
    {:ok, res} =
      Interaction.say(ctx.cid, "@方案甲 建个任务：改一处文案", actor_bee_id: ctx.actor)

    assert [task] = res["tasks"]
    assert task["assigned_bee_id"] == ctx.a["id"]
  end

  test "@不存在的名字时不乱派，提示从 @ 列表选", ctx do
    {:ok, res} =
      Interaction.say(ctx.cid, "@查无此人 建个任务：改一处文案", actor_bee_id: ctx.actor)

    assert res["tasks"] == []
    assert res["reply"] =~ "@ 列表"
  end
end
