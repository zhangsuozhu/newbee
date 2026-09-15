defmodule Newbee.Colony.StoreTest do
  use ExUnit.Case, async: false

  alias Newbee.Colony.Store

  setup do
    Store.clear_all()
    :ok
  end

  test "colony 基本读写" do
    :ok = Store.put_colony(%{"id" => "col_l_a", "name" => "A", "created_at" => 1})
    assert {:ok, %{"name" => "A"}} = Store.get_colony("col_l_a")
    assert Enum.any?(Store.list_colonies(), &(&1["id"] == "col_l_a"))
  end

  test "trace 追加按群隔离并有序" do
    :ok = Store.put_colony(%{"id" => "col_l_a", "name" => "A", "created_at" => 1})
    :ok = Store.put_colony(%{"id" => "col_l_b", "name" => "B", "created_at" => 2})

    {:ok, e1} =
      Store.append_trace(%{"colony_id" => "col_l_a", "text" => "一", "type" => "message"})

    {:ok, e2} =
      Store.append_trace(%{"colony_id" => "col_l_a", "text" => "二", "type" => "message"})

    {:ok, _} =
      Store.append_trace(%{"colony_id" => "col_l_b", "text" => "别的群", "type" => "message"})

    assert e2["seq"] > e1["seq"]

    trace = Store.trace_for_colony("col_l_a")
    assert length(trace) == 2
    assert Enum.map(trace, & &1["text"]) == ["一", "二"]

    assert [%{"text" => "二"}] = Store.trace_for_colony("col_l_a", limit: 1)
  end

  test "trace 支持 task_id / bee_id / channel 过滤" do
    :ok = Store.put_colony(%{"id" => "col_l_a", "name" => "A", "created_at" => 1})

    {:ok, _} =
      Store.append_trace(%{
        "colony_id" => "col_l_a",
        "type" => "task",
        "task_id" => "task_l_1",
        "text" => "任务1"
      })

    {:ok, _} =
      Store.append_trace(%{
        "colony_id" => "col_l_a",
        "type" => "task",
        "task_id" => "task_l_2",
        "text" => "任务2"
      })

    {:ok, _} =
      Store.append_trace(%{
        "colony_id" => "col_l_a",
        "type" => "message",
        "bee_id" => "bee_l_a",
        "channel" => "dm",
        "text" => "私聊"
      })

    assert [%{"text" => "任务1"}] = Store.trace_for_colony("col_l_a", task_id: "task_l_1")
    assert [%{"text" => "私聊"}] = Store.trace_for_colony("col_l_a", bee_id: "bee_l_a")
    assert [%{"text" => "私聊"}] = Store.trace_for_colony("col_l_a", channel: "dm")
  end

  test "signal 存取与 seq 单调" do
    :ok = Store.put_colony(%{"id" => "col_l_a", "name" => "A", "created_at" => 1})
    {:ok, s1} = Store.put_signal(%{"colony_id" => "col_l_a", "kind" => "notify"})
    {:ok, s2} = Store.put_signal(%{"colony_id" => "col_l_a", "kind" => "report"})
    assert s2["seq"] > s1["seq"]
    assert [_, _] = Store.signals_for_colony("col_l_a")
  end

  test "解散保留证据与成员历史" do
    :ok = Store.put_colony(%{"id" => "col_l_a", "name" => "A", "created_at" => 1})
    :ok = Store.put_bee(%{"id" => "bee_l_a", "colony_id" => "col_l_a", "display" => "b"})
    :ok = Store.put_task(%{"id" => "task_l_a", "colony_id" => "col_l_a", "title" => "t"})
    :ok = Store.put_honey(%{"id" => "hon_l_a", "colony_id" => "col_l_a", "title" => "h"})
    {:ok, _} = Store.append_trace(%{"colony_id" => "col_l_a", "text" => "x"})
    {:ok, _} = Store.put_signal(%{"colony_id" => "col_l_a", "kind" => "notify"})

    :ok = Store.delete_colony("col_l_a")

    assert {:ok, %{"status" => "dissolved"}} = Store.get_colony("col_l_a")
    refute Enum.any?(Store.list_colonies(), &(&1["id"] == "col_l_a"))

    for records <- [
          Store.bees_for_colony("col_l_a"),
          Store.tasks_for_colony("col_l_a"),
          Store.honey_for_colony("col_l_a"),
          Store.trace_for_colony("col_l_a"),
          Store.signals_for_colony("col_l_a")
        ] do
      assert length(records) == 1
    end
  end

  test "dump/restore 往返（持久化契约）" do
    :ok = Store.put_colony(%{"id" => "col_l_rt", "name" => "往返", "created_at" => 1})
    :ok = Store.put_bee(%{"id" => "bee_l_rt", "colony_id" => "col_l_rt", "display" => "b"})

    {:ok, _} =
      Store.append_trace(%{"colony_id" => "col_l_rt", "text" => "记录", "type" => "message"})

    dump = Store.dump()
    assert Enum.any?(dump["colonies"], &(&1["id"] == "col_l_rt"))
    refute dump["trace"] == []

    # Simulate volatile-state loss without writing a destructive clear to disk.
    :sys.replace_state(Store, fn state ->
      %{state | data: Map.new(state.data, fn {k, v} -> {k, if(is_map(v), do: %{}, else: v)} end)}
    end)

    assert Store.trace_for_colony("col_l_rt") == []

    :ok = Store.restore()
    assert {:ok, %{"name" => "往返"}} = Store.get_colony("col_l_rt")
    assert [%{"text" => "记录"}] = Store.trace_for_colony("col_l_rt")
  end
end
