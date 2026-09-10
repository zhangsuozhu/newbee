defmodule Newbee.EventStoreRotationTest do
  use ExUnit.Case, async: false

  alias Newbee.EventStore

  setup do
    dir = Path.join(System.tmp_dir!(), "evs-rotate-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    path = Path.join(dir, "events.jsonl")
    on_exit(fn -> File.rm_rf(dir) end)
    {:ok, dir: dir, path: path}
  end

  defp append_many(store, count, pad \\ 20) do
    for i <- 1..count do
      {:ok, _} = EventStore.append(store, :rotation_probe, %{"i" => i, "pad" => String.duplicate("x", pad)})
    end

    :ok
  end

  defp segments(dir), do: dir |> Path.join("events") |> Path.join("seg-*.jsonl*") |> Path.wildcard()

  test "超过阈值即封段，全量重放跨段且 id 连续", %{dir: dir, path: path} do
    {:ok, store} = EventStore.start_link(path: path, durability: :os, max_active_bytes: 4096)
    append_many(store, 200)

    assert EventStore.watermark(store) == 200

    segs = segments(dir)
    assert segs != [], "应至少封出一个段"
    assert Enum.any?(segs, &String.ends_with?(&1, ".gz")), "段应被 gzip"
    assert File.stat!(path).size < 4096 + 512, "活动文件应保持在小尺寸"

    events = EventStore.replay(path)
    assert Enum.map(events, & &1.id) == Enum.to_list(1..200)
    assert Enum.all?(events, &(&1.topic == :rotation_probe))

    GenServer.stop(store)
  end

  test "重启后从最新存档段续 id，不回退", %{path: path} do
    {:ok, store} = EventStore.start_link(path: path, durability: :os, max_active_bytes: 2048)
    append_many(store, 120)
    GenServer.stop(store)

    {:ok, store2} = EventStore.start_link(path: path, durability: :os, max_active_bytes: 2048)
    assert EventStore.watermark(store2) == 120
    {:ok, e} = EventStore.append(store2, :rotation_probe, %{"i" => 121})
    assert e.id == 121
    assert Enum.map(EventStore.replay(path), & &1.id) == Enum.to_list(1..121)
    GenServer.stop(store2)
  end

  test "replay_tail 跨段与全量等值", %{path: path} do
    {:ok, store} = EventStore.start_link(path: path, durability: :os, max_active_bytes: 2048)
    append_many(store, 150)
    GenServer.stop(store)

    for k <- [1, 5, 50, 149, 150, 200] do
      assert EventStore.replay_tail(path, k) |> Enum.map(& &1.id) ==
               EventStore.replay(path) |> Enum.take(-k) |> Enum.map(& &1.id),
             "k=#{k} 跨段尾读与全量不一致"
    end
  end

  test "checkpoint（from_id）跨段重放：跳过整段也不丢事件", %{path: path} do
    {:ok, store} = EventStore.start_link(path: path, durability: :os, max_active_bytes: 2048)
    append_many(store, 120)
    GenServer.stop(store)

    for from <- [0, 1, 40, 119] do
      ids = EventStore.replay(path, from) |> Enum.map(& &1.id)
      assert ids == Enum.to_list((from + 1)..120)
    end
  end

  test "保留策略：只留最新的 max_segments 个段", %{dir: dir, path: path} do
    {:ok, store} =
      EventStore.start_link(path: path, durability: :os, max_active_bytes: 1024, max_segments: 2)

    append_many(store, 200)
    GenServer.stop(store)

    assert length(segments(dir)) == 2
    # 被裁掉的是最旧的段，最近的事件仍在流里
    ids = EventStore.replay(path) |> Enum.map(& &1.id)
    assert List.last(ids) == 200
    assert length(ids) < 200
  end

  test "max_active_bytes: 0 关闭轮转", %{dir: dir, path: path} do
    {:ok, store} = EventStore.start_link(path: path, durability: :os, max_active_bytes: 0)
    append_many(store, 60, 200)
    GenServer.stop(store)

    assert segments(dir) == []
    assert length(EventStore.replay(path)) == 60
  end

  test "未压缩段（崩溃窗口）也能读：.jsonl 与 .gz 混存", %{dir: dir, path: path} do
    {:ok, store} = EventStore.start_link(path: path, durability: :os, max_active_bytes: 1024)
    append_many(store, 80)
    GenServer.stop(store)
    # 模拟「rename 完成但 gzip 还没做」的崩溃残留：同一段同时留 .gz 与 .jsonl
    gz = dir |> segments() |> List.last()
    plain = Path.rootname(gz)
    assert String.ends_with?(plain, ".jsonl")
    File.write!(plain, :zlib.gunzip(File.read!(gz)))

    ids = EventStore.replay(path) |> Enum.map(& &1.id)
    # 同一段同时存在 .gz 与 .jsonl 时只取 .gz，不重复计数
    assert ids == Enum.uniq(ids)
    assert ids == Enum.to_list(1..80)
    assert EventStore.replay_tail(path, 3) |> Enum.map(& &1.id) == [78, 79, 80]
  end

  test "gzip 在途的 .tmp.* 文件不参与读取（崩溃残渣）", %{dir: dir, path: path} do
    {:ok, store} = EventStore.start_link(path: path, durability: :os, max_active_bytes: 1024)
    append_many(store, 40)
    GenServer.stop(store)

    # 造一个半截 gzip 残渣（真实环境里进程死在中途会留下它）
    junk = Path.join([dir, "events", "seg-999999-999.jsonl.tmp.gz"])
    File.write!(junk, <<31, 139, 8, 0, 1, 2, 3>>)

    refute junk in EventStore.segments(path)
    assert EventStore.replay(path) |> Enum.map(& &1.id) == Enum.to_list(1..40)
    assert EventStore.replay_tail(path, 3) |> Enum.map(& &1.id) == [38, 39, 40]
  end

  test "resync/1 在人工重编号之后把水位对齐到磁盘", %{path: path} do
    {:ok, store} = EventStore.start_link(path: path, durability: :os, max_active_bytes: 0)
    append_many(store, 3)

    # 模拟人工修复：把活动文件里的 id 改成从 150840 起（保持 data/at，重算 crc）
    lines = File.read!(path) |> String.split("\n", trim: true)

    renumbered =
      lines
      |> Enum.with_index(150_840)
      |> Enum.map(fn {line, id} ->
        f = Jason.decode!(line)
        payload = %{"id" => id, "topic" => f["topic"], "data" => f["data"], "at" => f["at"]}
        crc = :erlang.crc32(Jason.encode_to_iodata!(payload))
        Jason.encode!(Map.put(payload, "crc", crc))
      end)

    File.write!(path, Enum.map(renumbered, &(&1 <> "\n")))

    assert {:ok, 150_842} = EventStore.resync(store)
    assert EventStore.watermark(store) == 150_842

    {:ok, e} = EventStore.append(store, :rotation_probe, %{"after" => "resync"})
    assert e.id == 150_843
    assert EventStore.replay(path) |> List.last() |> Map.get(:id) == 150_843
    GenServer.stop(store)
  end
end
