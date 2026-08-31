defmodule Newbee.EventStoreTest do
  use ExUnit.Case, async: true

  alias Newbee.EventStore

  setup do
    path =
      Path.join(
        System.tmp_dir!(),
        "evs_#{System.system_time(:native)}_#{System.system_time(:native)}_#{System.unique_integer([:positive])}.jsonl"
      )

    on_exit(fn -> File.rm(path) end)
    {:ok, path: path}
  end

  test "追加 + 单调 event_id + 重放", %{path: path} do
    {:ok, store} = EventStore.start_link(path: path, durability: :event)

    {:ok, e1} = EventStore.append(store, :"turn/start", %{"x" => 1})
    {:ok, e2} = EventStore.append(store, :"tool/result", %{"y" => 2})

    assert e1.id == 1
    assert e2.id == 2
    assert EventStore.watermark(store) == 2

    events = EventStore.replay(path)
    assert [%{id: 1, topic: :"turn/start"}, %{id: 2, topic: :"tool/result"}] = events

    # 从水位重放
    assert [%{id: 2}] = EventStore.replay(path, 1)

    GenServer.stop(store)
  end

  test "崩溃半帧被识别并截断", %{path: path} do
    {:ok, store} = EventStore.start_link(path: path, durability: :event)
    {:ok, _} = EventStore.append(store, :a, %{"ok" => true})
    GenServer.stop(store)

    # 模拟崩溃写了一半的尾行
    File.write!(path, "{\"id\": 99, \"topic\": \"b\", \"data\"", [:append])

    # 重启：截断坏帧，id 不回退
    {:ok, store2} = EventStore.start_link(path: path, durability: :event)
    assert EventStore.watermark(store2) == 1
    {:ok, e} = EventStore.append(store2, :b, %{"after" => "crash"})
    assert e.id == 2

    events = EventStore.replay(path)
    assert length(events) == 2
    GenServer.stop(store2)
  end

  test "crc 篡改的帧被丢弃", %{path: path} do
    {:ok, store} = EventStore.start_link(path: path, durability: :event)
    {:ok, _} = EventStore.append(store, :a, %{"v" => 1})
    {:ok, _} = EventStore.append(store, :b, %{"v" => 2})
    GenServer.stop(store)

    # 篡改第一行内容（crc 不再匹配）
    [l1, l2] = File.read!(path) |> String.split("\n", trim: true)
    tampered = String.replace(l1, "\"v\":1", "\"v\":999")
    File.write!(path, tampered <> "\n" <> l2 <> "\n")

    # 首个坏帧之后全部丢弃
    assert EventStore.replay(path) == []
  end

  test "batch 档位：周期性 fsync", %{path: path} do
    {:ok, store} = EventStore.start_link(path: path, durability: :batch, batch_size: 3)

    for i <- 1..3, do: EventStore.append(store, :t, %{"i" => i})
    assert EventStore.watermark(store) == 3

    GenServer.stop(store, :normal, 5_000)
    assert length(EventStore.replay(path)) == 3
  end
end
