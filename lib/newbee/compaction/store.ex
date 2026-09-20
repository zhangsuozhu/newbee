defmodule Newbee.Compaction.Store do
  @moduledoc """
  原文恢复包与决策投影的原子持久化。投影是可丢弃缓存，transcript 才是事实来源。
  """

  alias Newbee.Compaction.{Config, Policy, Projection}
  alias Newbee.Spill

  @filename "jev-projection.json"
  @version 1

  def source_index(nil), do: {:error, :no_session}

  def source_index(session) do
    view = Newbee.Archive.view(session)
    cut = archive_cut(session)
    calls = Policy.index_calls(view)

    if duplicate_ids?(view) do
      {:error, :ambiguous_ids}
    else
      {:ok, %{cut: cut, calls: calls, view: view}}
    end
  rescue
    _ -> {:error, :source_index_failed}
  end

  def prepare_recovery(calls) when is_list(calls) do
    Enum.reduce_while(calls, {:ok, []}, fn call, {:ok, acc} ->
      case recovery_payload(call) do
        {:ok, payload, id, bytes} ->
          if bytes <= Config.max_recovery_bytes() do
            {:cont, {:ok, acc ++ [%{call: call, payload: payload, id: id, bytes: bytes}]}}
          else
            {:halt, {:error, {:recovery_too_large, call.tool_call_id}}}
          end

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  def persist_recoveries(recoveries) when is_list(recoveries) do
    Enum.reduce_while(recoveries, :ok, fn rec, :ok ->
      case Spill.store(rec.payload) do
        {:ok, %{id: id, partial: false}} when id == rec.id ->
          if verify_spill(id, rec.payload) == :ok do
            {:cont, :ok}
          else
            {:halt, {:error, :spill_verify_failed}}
          end

        {:ok, %{partial: true}} ->
          {:halt, {:error, :spill_partial}}

        {:ok, %{id: other}} ->
          {:halt, {:error, {:spill_id_mismatch, other}}}

        {:error, reason} ->
          {:halt, {:error, {:spill_store_failed, normalize_reason(reason)}}}
      end
    end)
  end

  def load(nil, _source), do: :none

  def load(session, source) do
    path = path(session)

    cond do
      not File.regular?(path) ->
        :none

      File.stat!(path).size > Config.max_projection_bytes() ->
        {:error, :projection_too_large}

      true ->
        decode_manifest(File.read!(path), session, source)
    end
  rescue
    _ -> {:error, :projection_unreadable}
  end

  def commit(session, source, records) when is_list(records) do
    with {:ok, existing} <- existing_records(session, source),
         merged <- merge_records(existing, records),
         :ok <- validate_against_source(merged, source),
         {:ok, manifest} <- encode_manifest(session, source, merged),
         :ok <- atomic_write(path(session), Jason.encode!(manifest)) do
      {:ok, atomize_manifest(manifest)}
    end
  end

  def clear(nil), do: :ok

  def clear(session) do
    source =
      case source_index(session) do
        {:ok, src} -> src
        _ -> %{cut: 0, calls: %{}}
      end

    with {:ok, manifest} <- encode_manifest(session, source, []),
         :ok <- atomic_write(path(session), Jason.encode!(manifest)) do
      :ok
    end
  end

  def path(%{dir: dir}) when is_binary(dir), do: Path.join(dir, @filename)

  def recovery_payload(call) do
    payload =
      Jason.encode!(%{
        "tool_call" => call.call,
        "tool_result" => call.result
      })

    {:ok, payload, Spill.id_for(payload), byte_size(payload)}
  rescue
    _ -> {:error, :recovery_encode_failed}
  end

  def read_recovery(id) when is_binary(id) do
    with {:ok, text} <- read_all_spill(id),
         {:ok, map} <- Jason.decode(text) do
      {:ok, map}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :recovery_unreadable}
    end
  end

  def verify_spill(id, expected) when is_binary(id) and is_binary(expected) do
    path = Spill.object_path(id)

    with true <- Spill.valid_id?(id),
         true <- is_binary(path),
         :ok <- Spill.verify_object(path, id),
         {:ok, text} <- read_all_spill(id),
         true <- text == expected do
      :ok
    else
      _ -> {:error, :spill_verify_failed}
    end
  end

  def encode_manifest(session, source, records) do
    payload = %{
      "version" => @version,
      "session_id" => session.id,
      "archive_cut" => source[:cut] || source["cut"] || 0,
      "records" => Enum.map(records, &stringify_record/1)
    }

    sha = payload_sha(payload)
    {:ok, Map.put(payload, "payload_sha", sha)}
  end

  def payload_sha(payload) do
    canonical = Map.take(payload, ["version", "session_id", "archive_cut", "records"])

    :crypto.hash(:sha256, Jason.encode!(canonical))
    |> Base.encode16(case: :lower)
  end

  # ── internals ──

  defp archive_cut(session) do
    case Newbee.Archive.current_cut(session) do
      %{cut: cut} when is_integer(cut) -> cut
      _ -> 0
    end
  end

  defp duplicate_ids?(messages) do
    ids =
      Enum.flat_map(messages, fn
        %{"role" => "assistant", "tool_calls" => calls} when is_list(calls) ->
          Enum.flat_map(calls, fn c -> if is_binary(c["id"]), do: [c["id"]], else: [] end)

        _ ->
          []
      end)

    length(ids) != length(Enum.uniq(ids))
  end

  defp existing_records(session, source) do
    case load(session, source) do
      {:ok, manifest} -> {:ok, manifest.records}
      :none -> {:ok, []}
      {:error, reason} -> {:error, reason}
    end
  end

  defp merge_records(existing, incoming) do
    by_id = Map.new(existing, fn rec -> {rec.tool_call_id, rec} end)

    Enum.reduce(incoming, existing, fn rec, acc ->
      id = rec[:tool_call_id] || rec["tool_call_id"]

      if Map.has_key?(by_id, id) do
        acc
      else
        acc ++ [normalize_record(rec)]
      end
    end)
  end

  defp validate_against_source(records, source) do
    if length(records) > Config.max_records() do
      {:error, :record_limit}
    else
      calls = source[:calls] || %{}

      Enum.reduce_while(records, :ok, fn rec, :ok ->
        id = rec.tool_call_id
        sha = rec.source_sha

        case Map.get(calls, id) do
          %{source_sha: ^sha} -> {:cont, :ok}
          _ -> {:halt, {:error, :fingerprint_mismatch}}
        end
      end)
    end
  end

  defp decode_manifest(bin, session, source) do
    with {:ok, map} <- Jason.decode(bin),
         :ok <- schema_ok?(map),
         true <- map["session_id"] == session.id,
         true <- map["archive_cut"] == (source[:cut] || 0),
         true <- map["payload_sha"] == payload_sha(map),
         records <- Enum.map(map["records"] || [], &normalize_record/1),
         :ok <- validate_records(records, source) do
      {:ok, %{version: @version, session_id: session.id, archive_cut: map["archive_cut"], records: records}}
    else
      false -> {:error, :projection_mismatch}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :projection_invalid}
    end
  end

  defp schema_ok?(%{
         "version" => 1,
         "session_id" => sid,
         "archive_cut" => cut,
         "records" => records,
         "payload_sha" => sha
       })
       when is_binary(sid) and is_integer(cut) and is_list(records) and is_binary(sha) and
              length(records) <= 128 do
    :ok
  end

  defp schema_ok?(_), do: {:error, :projection_schema}

  defp validate_records(records, source) do
    ids = Enum.map(records, & &1.tool_call_id)

    cond do
      length(ids) != length(Enum.uniq(ids)) ->
        {:error, :duplicate_record}

      true ->
        Enum.reduce_while(records, :ok, fn rec, :ok ->
          with :ok <- action_ok?(rec.action),
               :ok <- recovery_ok?(rec),
               :ok <- fingerprint_ok?(rec, source) do
            {:cont, :ok}
          else
            {:error, reason} -> {:halt, {:error, reason}}
          end
        end)
    end
  end

  defp action_ok?(:drop_call), do: :ok
  defp action_ok?(:drop_result), do: :ok
  defp action_ok?(_), do: {:error, :invalid_action}

  defp recovery_ok?(%{recovery_id: id, action: :drop_call}) when is_binary(id), do: spill_present(id)

  defp recovery_ok?(%{recovery_id: id, action: :drop_result, replacement: text} = rec)
       when is_binary(id) and is_binary(text) do
    with :ok <- spill_present(id),
         {:ok, payload} <- read_recovery(id),
         result when is_binary(result) <- get_in(payload, ["tool_result", "content"]),
         expected <-
           Projection.replacement_body(
             result,
             id,
             rec.head_chars || Config.legacy().truncate_head_chars,
             rec.tail_chars || Config.legacy().truncate_tail_chars
           ),
         true <- expected == text do
      :ok
    else
      false -> {:error, :replacement_mismatch}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :recovery_invalid}
    end
  end

  defp recovery_ok?(_), do: {:error, :recovery_invalid}

  defp fingerprint_ok?(rec, source) do
    case Map.get(source[:calls] || %{}, rec.tool_call_id) do
      %{source_sha: sha} ->
        if sha == rec.source_sha, do: :ok, else: {:error, :fingerprint_mismatch}

      _ ->
        {:error, :fingerprint_mismatch}
    end
  end

  defp spill_present(id) do
    case Spill.stat(id) do
      {:ok, _} ->
        path = Spill.object_path(id)
        if is_binary(path) and Spill.verify_object(path, id) == :ok, do: :ok, else: {:error, :spill_integrity}

      _ ->
        {:error, :spill_missing}
    end
  end

  defp stringify_record(rec) do
    rec = normalize_record(rec)

    base = %{
      "tool_call_id" => rec.tool_call_id,
      "source_sha" => rec.source_sha,
      "action" => Atom.to_string(rec.action),
      "recovery_id" => rec.recovery_id
    }

    if rec.action == :drop_result do
      base
      |> Map.put("head_chars", rec.head_chars)
      |> Map.put("tail_chars", rec.tail_chars)
      |> Map.put("replacement", rec.replacement)
    else
      base
    end
  end

  defp normalize_record(rec) when is_map(rec) do
    action = rec[:action] || rec["action"]
    action = if is_atom(action), do: action, else: known_action(action)

    %{
      tool_call_id: rec[:tool_call_id] || rec["tool_call_id"],
      source_sha: rec[:source_sha] || rec["source_sha"],
      action: action,
      recovery_id: rec[:recovery_id] || rec["recovery_id"],
      head_chars: rec[:head_chars] || rec["head_chars"],
      tail_chars: rec[:tail_chars] || rec["tail_chars"],
      replacement: rec[:replacement] || rec["replacement"]
    }
  end

  defp known_action("drop_call"), do: :drop_call
  defp known_action("drop_result"), do: :drop_result
  defp known_action(_), do: :invalid

  defp atomize_manifest(map) do
    %{
      version: map["version"],
      session_id: map["session_id"],
      archive_cut: map["archive_cut"],
      records: Enum.map(map["records"], &normalize_record/1)
    }
  end

  defp atomic_write(path, bin) do
    dir = Path.dirname(path)
    File.mkdir_p!(dir)
    tmp = path <> ".tmp-" <> Integer.to_string(System.unique_integer([:positive]))

    try do
      File.write!(tmp, bin)
      :ok = sync_file(tmp)
      File.rename!(tmp, path)
      :ok
    rescue
      e ->
        _ = File.rm(tmp)
        {:error, {:projection_write_failed, Exception.message(e)}}
    end
  end

  defp sync_file(path) do
    case :file.open(String.to_charlist(path), [:read, :raw]) do
      {:ok, fd} ->
        try do
          :file.sync(fd)
        after
          :file.close(fd)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp read_all_spill(id) do
    read_all_spill(id, 0, "")
  end

  defp read_all_spill(id, offset, acc) do
    case Spill.read(id, offset: offset, max_bytes: 64 * 1024, max_lines: 100_000) do
      {:ok, %{text: text, eof: true}} -> {:ok, acc <> text}
      {:ok, %{text: text, next_offset: next, eof: false}} -> read_all_spill(id, next, acc <> text)
      {:error, reason} -> {:error, reason}
    end
  end

  defp normalize_reason(reason) when is_atom(reason), do: reason
  defp normalize_reason({reason, _}) when is_atom(reason), do: reason
  defp normalize_reason(_), do: :unknown
end
