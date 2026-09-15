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

  # 暂停 + 有待决方案时，群聊里的普通消息以前会返回 workflow_decision_required（消息其实
  # 已经记进群聊），前端弹红 toast、用户以为没发出去。
  test "暂停且工作处于方案阶段时，消息仍算发送成功并被记录", ctx do
    {:ok, task} =
      Newbee.Colony.Work.create(ctx.cid, %{
        "title" => "TRIAGE 任务",
        "description" => "处于方案阶段的工作",
        "workflow" => true,
        "assigned_bee_id" => ctx.a["id"],
        "actor_bee_id" => ctx.actor
      })

    assert task["workflow"]["phase"] == "triage"
    {:ok, _} = Newbee.Colony.Control.set(ctx.cid, "work", task["id"], "pause", actor_bee_id: ctx.actor)

    assert {:ok, res} = Interaction.say(ctx.cid, "大家好", actor_bee_id: ctx.actor, context: %{"taskId" => task["id"]})
    assert is_binary(res["reply"])
    assert res["reply"] =~ "消息已记录在群聊"

    # 关键：消息本身必须落到群聊轨迹里（前端据此显示）
    texts = Store.trace_for_colony(ctx.cid, channel: "colony") |> Enum.map(& &1["text"])
    assert "大家好" in texts
    # 「继续」这类指令不该被当成新约束塞进 task.constraints（会被当要求喂给执行器）。
    assert {:ok, cont} =
             Interaction.say(ctx.cid, "继续", actor_bee_id: ctx.actor, context: %{"taskId" => task["id"]})

    assert cont["reply"] =~ "工作已暂停"
    assert elem(Newbee.Colony.Store.get_task(task["id"]), 1)["constraints"] in [nil, []]
  end

  # 「继续」在方案阶段会被 Work.continue 拒绝；以前这个错误直接冒到 API，
  # 前端弹红 toast——但消息其实已经记进群聊了（R117 的同类问题，另一条分支）。
  test "方案阶段说「继续」不再是发送失败，而是给出可走的下一步", ctx do
    {:ok, task} =
      Newbee.Colony.Work.create(ctx.cid, %{
        "title" => "方案阶段的工作",
        "description" => "尚未进入实施",
        "workflow" => true,
        "assigned_bee_id" => ctx.a["id"],
        "actor_bee_id" => ctx.actor
      })

    # 造一个「受阻、等决策」的任务，让它落进 continue_latest 的候选。
    :ok = Newbee.Colony.Store.put_task(Map.put(task, "status", "blocked"))

    assert {:ok, res} = Interaction.say(ctx.cid, "继续", actor_bee_id: ctx.actor)
    assert is_binary(res["reply"])
    assert res["reply"] =~ "消息已记录在群聊"
  end
end
