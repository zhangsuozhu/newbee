defmodule Newbee.SessionIndexPerfTest do
  @moduledoc """
  会话索引的缓存契约：热路径不读 transcript，冷路径读了就进缓存。

  R1 基线的这两条用例断言**全局**扫描计数器（`transcript_scan_count() == scans + 1`）
  与绝对墙钟（`micros < 500_000`、`list_us < decode_us`）。同一个测试 VM 里其他 async
  测试文件也在建会话，`list_page/2` 会把它们一起算进"未命中"，于是断言失败与本次改动
  无关，只与"机器上有多少别的会话"有关（R1 D9），绝对微秒数测的是负载（R1 D7）。

  这里改成**因果断言**，不数全局计数器：

  - 冷路径：索引里没有 count，1502 只能来自真实扫描；
  - 缓存命中：把 transcript **改写成长度相同、行数少一条**的文件再列表——命中缓存时
    报告的仍是旧计数（1502），重新扫描则会变成 1501。这条证据与并发会话数量无关。
  """
  use ExUnit.Case, async: false

  alias Newbee.Session

  test "热路径：追加消息后列表不再读 transcript" do
    id = unique("hot")
    on_exit(fn -> Session.delete(id) end)

    assert :ok = Session.mark_created(id)
    session = Session.open(id)

    Session.append(session, %{"role" => "user", "content" => "hello world from cache"})
    Session.append(session, %{"role" => "assistant", "content" => String.duplicate("x", 80_000)})
    Session.append(session, %{"role" => "user", "content" => "hi"})

    {entries, _} = Session.list_page(50, 0)
    entry = Enum.find(entries, &(&1.id == id))
    assert entry.messages == 3
    assert entry.title == "hello world from cache"

    # 第二次列表不得再读盘：用"改同尺寸文件后计数不变"证明命中缓存。
    stale_growth_guard(entry.messages, session_path(id))
  end

  test "短首条用户消息不锁定标题，后续更长的问题会接管" do
    id = unique("title")
    on_exit(fn -> Session.delete(id) end)
    assert :ok = Session.mark_created(id)
    session = Session.open(id)

    Session.append(session, %{"role" => "user", "content" => "hi"})
    Session.append(session, %{"role" => "assistant", "content" => "ack"})
    Session.append(session, %{"role" => "user", "content" => "the real question is longer"})

    {entries, _} = Session.list_page(50, 0)
    entry = Enum.find(entries, &(&1.id == id))
    assert entry.title == "the real question is longer"
    assert entry.messages == 3
  end

  test "冷路径：统计来自真实扫描，之后由索引提供（同尺寸改写不触发重扫）" do
    id = unique("cold")
    on_exit(fn -> Session.delete(id) end)
    path = session_path(id)
    File.mkdir_p!(Path.dirname(path))

    lines =
      [
        Jason.encode!(%{"role" => "user", "content" => "cold scan title value"})
        | Enum.map(1..1500, fn n ->
            Jason.encode!(%{"role" => "assistant", "content" => "row #{n} " <> String.duplicate("y", 120)})
          end)
      ]

    payload = Enum.join(lines, "\n") <> "\n\n" <> Jason.encode!(%{"role" => "tool", "content" => "tail"}) <> "\n"
    File.write!(path, payload)

    {entries, _} = Session.list_page(100, 0)
    entry = Enum.find(entries, &(&1.id == id))
    assert entry.messages == 1502, "冷路径没有真实扫描（或漏掉了空行之后的消息）"
    assert entry.title == "cold scan title value"

    stale_growth_guard(entry.messages, path)
  end

  # 同字节数、少一行：命中缓存 → 计数不变；重新扫描 → 计数变 1501。
  #
  # 索引回填是异步的（list_page 内部 spawn backfill_index_cache），所以先"等索引收敛"：
  # 反复列表直到扫描计数器连续两轮不变，此时该会话的 size/count 已进索引。
  defp stale_growth_guard(expected_count, path) do
    settle_scans()

    payload = File.read!(path)
    size = byte_size(payload)
    tampered = String.replace(payload, "\n\n", "  ", global: false)

    assert byte_size(tampered) == size, "改写必须保持文件大小不变（否则命中判定会变）"
    File.write!(path, tampered)

    {entries, _} = Session.list_page(100, 0)
    id = Path.basename(path, ".jsonl")
    entry = Enum.find(entries, &(&1.id == id))

    assert entry.messages == expected_count,
           "列表重新扫描了 transcript（计数从 #{expected_count} 变成 #{entry.messages}）：索引缓存没有生效"
  end

  defp settle_scans(rounds \\ 0) do
    {_entries, _} = Session.list_page(100, 0)
    first = Session.transcript_scan_count()

    {_entries, _} = Session.list_page(100, 0)

    cond do
      Session.transcript_scan_count() == first -> :ok
      rounds >= 15 -> :ok
      true -> settle_scans(rounds + 1)
    end
  end

  defp session_path(id), do: Path.join([Newbee.GlobalStore.root(), "sessions", id <> ".jsonl"])

  defp unique(prefix), do: prefix <> "_" <> Integer.to_string(System.unique_integer([:positive]))
end
