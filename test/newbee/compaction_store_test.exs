defmodule Newbee.Compaction.StoreTest do
  use ExUnit.Case, async: false
  alias Newbee.Compaction.{Config, Projection, Store}
  alias Newbee.Session

  setup do
    id = "jevstore_" <> Integer.to_string(:erlang.unique_integer([:positive]))
    session = Session.open(id)
    on_exit(fn -> Session.delete(id) end)
    {:ok, config} = Config.resolve(%{"mode" => "jev"})
    %{session: session, config: config, id: id}
  end

  defp append_turn(session, n) do
    code = "IO.puts(" <> Integer.to_string(n) <> ")"
    result = String.duplicate("RESULT" <> Integer.to_string(n) <> "-", 80)

    call = %{
      "role" => "assistant",
      "content" => "",
      "tool_calls" => [
        %{
          "id" => "c" <> Integer.to_string(n),
          "type" => "function",
          "function" => %{"name" => "run_elixir", "arguments" => Jason.encode!(%{code: code})}
        }
      ]
    }

    Session.append(session, %{"role" => "user", "content" => "turn " <> Integer.to_string(n)})
    Session.append(session, call)
    Session.append(session, %{"role" => "tool", "tool_call_id" => "c" <> Integer.to_string(n), "content" => result})
    session
  end

  test "transcript bytes do not change when persisting recoveries", %{session: session, config: config} do
    session = append_turn(session, 1)
    before = File.read!(session.transcript)
    {:ok, source} = Store.source_index(session)
    call = source.calls["c1"] |> Map.put(:id, "t0") |> Map.put(:name, "run_elixir")
    {:ok, [recovery]} = Store.prepare_recovery([call])
    assert :ok = Store.persist_recoveries([recovery])
    replacement = Projection.replacement(call.result["content"], recovery.id, config)

    record = %{
      tool_call_id: "c1",
      source_sha: call.source_sha,
      action: :drop_result,
      recovery_id: recovery.id,
      head_chars: config.truncate_head_chars,
      tail_chars: config.truncate_tail_chars,
      replacement: replacement
    }

    assert {:ok, manifest} = Store.commit(session, source, [record])
    assert File.read!(session.transcript) == before
    {:ok, loaded} = Store.load(session, source)
    assert length(loaded.records) == 1
    {:ok, payload} = Store.read_recovery(recovery.id)
    assert payload["tool_call"]["id"] == "c1"
    assert payload["tool_result"]["content"] == call.result["content"]
    assert manifest.records == loaded.records
  end

  test "corrupt projection is ignored as a whole", %{session: session} do
    session = append_turn(session, 1)
    {:ok, source} = Store.source_index(session)
    File.write!(Store.path(session), "{not json")
    assert {:error, _} = Store.load(session, source)
  end

  test "cut mismatch ignores projection", %{session: session, config: config} do
    session = append_turn(session, 1)
    {:ok, source} = Store.source_index(session)
    call = source.calls["c1"] |> Map.put(:id, "t0") |> Map.put(:name, "run_elixir")
    {:ok, [recovery]} = Store.prepare_recovery([call])
    :ok = Store.persist_recoveries([recovery])
    replacement = Projection.replacement(call.result["content"], recovery.id, config)

    record = %{
      tool_call_id: "c1",
      source_sha: call.source_sha,
      action: :drop_result,
      recovery_id: recovery.id,
      head_chars: 200,
      tail_chars: 200,
      replacement: replacement
    }

    assert {:ok, _} = Store.commit(session, source, [record])
    assert {:error, :projection_mismatch} = Store.load(session, %{source | cut: 99})
  end
end
