defmodule Newbee.EventStoreTopicSafetyTest do
  use ExUnit.Case, async: false

  test "replay maps unknown topics to a fixed atom without atom growth" do
    path =
      Path.join(
        System.tmp_dir!(),
        "newbee-event-topic-" <> Integer.to_string(System.unique_integer([:positive])) <> ".jsonl"
      )

    on_exit(fn -> File.rm(path) end)
    unknown = "audit_unknown_" <> Integer.to_string(System.unique_integer([:positive]))
    payload = %{"id" => 1, "topic" => unknown, "data" => %{"ok" => true}, "at" => "now"}
    payload = Map.put(payload, "crc", :erlang.crc32(Jason.encode_to_iodata!(payload)))
    File.write!(path, Jason.encode!(payload) <> "\n")

    before = :erlang.system_info(:atom_count)
    assert [%{topic: :unknown_event_topic}] = Newbee.EventStore.replay(path)
    assert :erlang.system_info(:atom_count) == before
  end
end
