defmodule Newbee.EventStoreTailTest do
  use ExUnit.Case, async: true

  alias Newbee.EventStore

  defp tmp_path(tag) do
    path = Path.join(System.tmp_dir!(), "evstore-#{tag}-#{System.unique_integer([:positive])}.jsonl")
    on_exit(fn -> File.rm(path) end)
    path
  end

  # 用真实 store 追加事件，保证帧格式/crc 与生产一致。
  defp store_with(path, count, payload_bytes) do
    {:ok, pid} = EventStore.start_link(path: path, durability: :event)
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

    for i <- 1..count do
      payload = %{"i" => i, "body" => String.duplicate("x", payload_bytes)}
      {:ok, _} = EventStore.append(pid, :tool_result, payload)
    end

    :ok
  end

  test "replay_tail 与 replay |> take(-n) 等值（小文件，全窗口）" do
    path = tmp_path("small")
    store_with(path, 12, 20)

    for n <- [1, 3, 11, 12] do
      assert EventStore.replay_tail(path, n) == EventStore.replay(path) |> Enum.take(-n)
    end
  end

  test "replay_tail 与全量等值（大文件，只读尾部窗口）" do
    path = tmp_path("large")
    # 400 * ~700B ≈ 280 KB > 尾窗初值，强制走 :partial 路径
    store_with(path, 400, 700)

    assert File.stat!(path).size > 131_072

    for n <- [1, 5, 50, 400] do
      got = EventStore.replay_tail(path, n)
      assert got == EventStore.replay(path) |> Enum.take(-n), "n=#{n} 不一致"
      assert length(got) == min(n, 400)
    end
  end

  test "崩溃半帧（末尾无换行的坏行）按截断处理，与全量一致" do
    path = tmp_path("crash")
    store_with(path, 8, 10)
    File.write!(path, ~s|{"id":999,"topic":"tool_start","data":{"payload":["to|, [:append])

    for n <- [1, 3, 8] do
      assert EventStore.replay_tail(path, n) == EventStore.replay(path) |> Enum.take(-n)
    end
  end

  test "缺失文件返回空（与 replay/2 一致）" do
    path = Path.join(System.tmp_dir!(), "evstore-missing-#{System.unique_integer([:positive])}.jsonl")
    assert EventStore.replay_tail(path, 5) == []
    assert EventStore.replay(path) == []
  end

  test "非法 n 直接被守卫拒绝" do
    path = tmp_path("guard")
    store_with(path, 2, 10)
    assert_raise FunctionClauseError, fn -> EventStore.replay_tail(path, 0) end
  end
end
