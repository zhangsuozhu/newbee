defmodule Newbee.Colony.ConversationLifecycleTest do
  use ExUnit.Case, async: false

  alias Newbee.Colony.{Conversation, Engine, Store}

  setup do
    Store.clear_all()
    {:ok, colony} = Engine.create_colony(%{"name" => "对话生命周期"})
    {:ok, bee} = Engine.add_bee(colony["id"], %{"display" => "auth-bot", "kind" => "ai"})
    %{cid: colony["id"], bee: bee, actor: colony["queen_bee_id"]}
  end

  test "不能和自己对话", %{cid: cid, actor: actor} do
    assert {:error, "self_conversation", _} = Conversation.create(cid, actor, actor)
  end

  test "对话列表包含处理中工作会话", %{cid: cid, bee: bee, actor: actor} do
    {:ok, %{"sessionId" => sid}} = Conversation.create(cid, bee["id"], actor)

    Store.put("conversations", %{
      "id" => "work-session",
      "colony_id" => cid,
      "bee_id" => bee["id"],
      "task_id" => "task-x",
      "participants" => [actor, bee["id"]],
      "visibility" => "work"
    })

    {:ok, trail} = Conversation.trail(cid, bee["id"], actor)
    ids = Enum.map(trail["conversations"], & &1["id"])

    assert sid in ids
    assert "work-session" in ids
  end

  test "改名写会话标题；删除后会话与登记一起消失", %{cid: cid, bee: bee, actor: actor} do
    {:ok, %{"sessionId" => sid}} = Conversation.create(cid, bee["id"], actor)

    assert {:ok, %{"title" => "登录重构"}} =
             Engine.rename_conversation(cid, bee["id"], sid, "登录重构")

    {:ok, trail} = Conversation.trail(cid, bee["id"], actor)
    assert Enum.any?(trail["conversations"], &(&1["id"] == sid and &1["title"] == "登录重构"))

    assert {:ok, %{"sessionId" => ^sid}} = Engine.delete_conversation(cid, bee["id"], sid)
    assert {:ok, after_trail} = Conversation.trail(cid, bee["id"], actor)
    refute Enum.any?(after_trail["conversations"], &(&1["id"] == sid))
    assert {:error, :not_found} = Store.get("conversations", sid)
  end

  test "不属于该 Bee 的对话不能改名或删除", %{cid: cid, bee: bee, actor: actor} do
    assert {:error, "not_found", _} =
             Engine.delete_conversation(cid, bee["id"], "no-such-session")

    assert {:error, "not_found", _} =
             Engine.rename_conversation(cid, bee["id"], "no-such-session", "随便")
  end

  test "改名不能留空", %{cid: cid, bee: bee, actor: actor} do
    {:ok, %{"sessionId" => sid}} = Conversation.create(cid, bee["id"], actor)
    assert {:error, "bad_request", _} = Engine.rename_conversation(cid, bee["id"], sid, "   ")
  end

  test "真人对话没有会话，不能按会话删除", %{cid: cid, actor: actor} do
    {:ok, colleague} = Engine.add_bee(cid, %{"display" => "同事", "kind" => "human"})
    {:ok, %{"conversation" => human}} = Conversation.create(cid, colleague["id"], actor)

    assert {:error, "bad_request", _} =
             Engine.delete_conversation(cid, colleague["id"], human["id"])
  end
end
