defmodule Newbee.SessionIndexPerfTest do
  use ExUnit.Case, async: false

  alias Newbee.Session

  test "hot list does not reread transcripts after append" do
    id = unique("hot")
    on_exit(fn -> Session.delete(id) end)

    assert :ok = Session.mark_created(id)
    session = Session.open(id)
    scans = Session.transcript_scan_count()

    Session.append(session, %{"role" => "user", "content" => "hello world from cache"})
    Session.append(session, %{"role" => "assistant", "content" => String.duplicate("x", 80_000)})
    Session.append(session, %{"role" => "user", "content" => "hi"})

    {entries, _} = Session.list_page(30, 0)
    entry = Enum.find(entries, &(&1.id == id))
    assert entry.messages == 3
    assert entry.title == "hello world from cache"
    assert Session.transcript_scan_count() == scans

    {micros, _} =
      :timer.tc(fn ->
        for _ <- 1..20, do: Session.list_page(30, 0)
      end)

    assert Session.transcript_scan_count() == scans
    assert micros < 500_000
  end

  test "short first user text keeps tracking the latest user text" do
    id = unique("title")
    on_exit(fn -> Session.delete(id) end)
    assert :ok = Session.mark_created(id)
    session = Session.open(id)

    Session.append(session, %{"role" => "user", "content" => "hi"})
    Session.append(session, %{"role" => "assistant", "content" => "ack"})
    Session.append(session, %{"role" => "user", "content" => "the real question is longer"})

    {entries, _} = Session.list_page(30, 0)
    entry = Enum.find(entries, &(&1.id == id))
    assert entry.title == "the real question is longer"
    assert entry.messages == 3
  end

  test "cold transcript scan counts lines without decoding every object" do
    id = unique("cold")
    on_exit(fn -> Session.delete(id) end)
    path = Path.join([Newbee.GlobalStore.root(), "sessions", id <> ".jsonl"])
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

    scans = Session.transcript_scan_count()
    {list_us, {entries, _}} = :timer.tc(fn -> Session.list_page(50, 0) end)
    entry = Enum.find(entries, &(&1.id == id))
    assert entry.messages == 1502
    assert entry.title == "cold scan title value"
    assert Session.transcript_scan_count() == scans + 1

    {decode_us, decoded} =
      :timer.tc(fn ->
        payload
        |> String.split("\n", trim: true)
        |> Enum.map(&Jason.decode!/1)
        |> length()
      end)

    assert decoded == 1502
    assert list_us < decode_us
  end

  defp unique(prefix), do: prefix <> "_" <> Integer.to_string(System.unique_integer([:positive]))
end
