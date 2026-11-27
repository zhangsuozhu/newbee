defmodule Newbee.Colony.ConversationWorkDeleteTest do
  use ExUnit.Case, async: false
  alias Newbee.Colony.{ConversationWork, Store}
  @moduletag :tmp_dir

  setup %{tmp_dir: root} do
    Store.clear_all()
    sid = "delete-origin-" <> Integer.to_string(System.unique_integer([:positive]))

    on_exit(fn ->
      Store.clear_all()
    end)

    %{root: root, sid: sid}
  end

  test "terminal work can be hidden and restored without deleting history", %{root: root, sid: sid} do
    {:ok, result} = ConversationWork.start(sid, root, "完成导出", "delete-start")
    id = result["work"]["id"]
    {:ok, _} = Store.update("tasks", id, nil, &{:ok, Map.put(&1, "status", "done")})
    assert [work] = ConversationWork.list(sid)
    assert work["id"] == id

    assert {:ok, %{"deleted" => true}} = ConversationWork.delete(sid, id)
    assert ConversationWork.list(sid) == []
    assert ConversationWork.hidden?(sid)
    assert {:ok, %{"status" => "done"}} = Store.get_task(id)

    assert :ok = Store.restore()
    assert ConversationWork.list(sid) == []
    assert :ok = ConversationWork.restore(sid)
    assert [%{"id" => ^id}] = ConversationWork.list(sid)
    assert [%{"id" => ^id}] = ConversationWork.list(sid)
  end

  test "active work and another conversation's work cannot be deleted", %{root: root, sid: sid} do
    {:ok, result} = ConversationWork.start(sid, root, "仍在推进", "delete-active")
    id = result["work"]["id"]
    assert {:error, "busy", _} = ConversationWork.delete(sid, id)
    assert [%{"id" => ^id}] = ConversationWork.list(sid)
    assert {:error, "not_found", _} = ConversationWork.delete("other-session", id)
  end
end
