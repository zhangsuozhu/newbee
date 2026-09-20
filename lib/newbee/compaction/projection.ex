defmodule Newbee.Compaction.Projection do
  @moduledoc """
  工具事务裁剪、恢复目录与结构验收。纯函数，不访问磁盘。
  """

  @catalog_prefix "（Jev 压缩恢复目录"

  def catalog_prefix, do: @catalog_prefix

  @doc "将 records 应用到 messages。先校验 fingerprint，再生成新列表。"
  def apply(messages, records, opts \\ []) when is_list(messages) and is_list(records) do
    source = Keyword.get(opts, :source)
    skip_catalog? = Keyword.get(opts, :skip_catalog, false)

    with :ok <- unique_ids(records),
         :ok <- fingerprints_match(messages, records, source) do
      dropped_calls = Enum.filter(records, &action?(&1, "drop_call"))
      dropped_results = Enum.filter(records, &action?(&1, "drop_result"))
      call_ids = MapSet.new(dropped_calls, &record_id/1)
      result_map = Map.new(dropped_results, &{record_id(&1), &1})

      projected =
        messages
        |> Enum.map(&rewrite_message(&1, call_ids, result_map))
        |> Enum.reject(&is_nil/1)

      projected =
        if skip_catalog? do
          projected
        else
          case catalog(records) do
            nil -> projected
            cat -> insert_catalog(projected, cat)
          end
        end

      stats = %{
        calls_dropped: length(dropped_calls),
        results_dropped: length(dropped_results),
        messages_before: length(messages),
        messages_after: length(projected)
      }

      {:ok, projected, stats}
    end
  end

  @doc "drop_result 的本地替代文本。过短时返回 :keep。"
  def replacement(result_text, recovery_id, config)
      when is_binary(result_text) and is_binary(recovery_id) and is_map(config) do
    head_n = config.truncate_head_chars
    tail_n = config.truncate_tail_chars
    body = replacement_body(result_text, recovery_id, head_n, tail_n)

    if String.length(body) >= String.length(result_text) do
      :keep
    else
      body
    end
  end

  def replacement_body(result_text, recovery_id, head_n, tail_n)
      when is_binary(result_text) and is_binary(recovery_id) do
    head = String.slice(result_text, 0, head_n)
    tail = tail_slice(result_text, tail_n)
    omitted = max(String.length(result_text) - String.length(head) - String.length(tail), 0)

    head <>
      "\n[jev-compaction truncated #{omitted} chars of this tool result]\n" <>
      tail <>
      "\nOriginal call and result: Newbee.read(\"spill://#{recovery_id}\"). Read the original; do not re-run the tool to recover history."
  end

  @doc "drop_call 的精简恢复目录。无 drop_call 时返回 nil。"
  def catalog(records) when is_list(records) do
    dropped =
      records
      |> Enum.filter(&action?(&1, "drop_call"))
      |> Enum.sort_by(&record_id/1)

    if dropped == [] do
      nil
    else
      lines =
        Enum.map_join(dropped, "\n", fn rec ->
          id = record_id(rec)
          recovery = rec[:recovery_id] || rec["recovery_id"]
          "  - #{id}: Newbee.read(\"spill://#{recovery}\")"
        end)

      digest = catalog_digest(dropped)

      %{
        "role" => "system",
        "content" =>
          @catalog_prefix <>
            " #{digest}）被移出当前上下文的工具调用原文可按地址找回；先读取，不要为恢复历史而重新执行。\n" <>
            lines
      }
    end
  end

  def catalog(_), do: nil

  @doc "只移除由旧 manifest 确定性生成、完全相等且唯一的一条目录消息。"
  def strip_catalog(messages, nil) when is_list(messages), do: {:ok, messages}

  def strip_catalog(messages, projection) when is_list(messages) do
    expected = catalog(records_of(projection))

    if is_nil(expected) do
      {:ok, messages}
    else
      matches = Enum.with_index(messages) |> Enum.filter(fn {msg, _} -> msg == expected end)

      case matches do
        [] -> {:ok, messages}
        [{_msg, index}] -> {:ok, List.delete_at(messages, index)}
        _ -> {:error, :ambiguous_catalog}
      end
    end
  end

  @doc "结构验收：文本不变、相对顺序、配对完整、只有声明内容变化。"
  def validate(before, after_msgs, changed_records)
      when is_list(before) and is_list(after_msgs) and is_list(changed_records) do
    changed_ids = MapSet.new(changed_records, &record_id/1)
    drop_call_ids = MapSet.new(Enum.filter(changed_records, &action?(&1, "drop_call")), &record_id/1)
    drop_result_ids = MapSet.new(Enum.filter(changed_records, &action?(&1, "drop_result")), &record_id/1)

    with :ok <- texts_preserved(before, after_msgs, drop_call_ids),
         :ok <- pairing_intact(after_msgs),
         :ok <- only_declared_changes(before, after_msgs, changed_ids, drop_call_ids, drop_result_ids) do
      :ok
    end
  end

  def insert_catalog(messages, catalog) when is_list(messages) and is_map(catalog) do
    {leading, rest} = Enum.split_while(messages, &(&1["role"] == "system"))
    leading ++ [catalog | rest]
  end

  # ── rewrite ──

  defp rewrite_message(%{"role" => "assistant", "tool_calls" => calls} = msg, call_ids, _result_map)
       when is_list(calls) and calls != [] do
    kept = Enum.reject(calls, fn call -> MapSet.member?(call_ids, call["id"]) end)

    cond do
      kept == [] and empty_assistant?(msg) ->
        nil

      kept == [] ->
        msg |> Map.delete("tool_calls") |> maybe_empty_assistant()

      true ->
        Map.put(msg, "tool_calls", kept)
    end
    |> case do
      nil -> nil
      rewritten -> rewritten
    end
  end

  defp rewrite_message(%{"role" => "tool", "tool_call_id" => id} = msg, call_ids, result_map) do
    cond do
      MapSet.member?(call_ids, id) ->
        nil

      Map.has_key?(result_map, id) ->
        rec = result_map[id]
        Map.put(msg, "content", rec[:replacement] || rec["replacement"])

      true ->
        msg
    end
  end

  defp rewrite_message(msg, _call_ids, _result_map), do: msg

  defp empty_assistant?(msg) do
    content_empty?(msg["content"]) and not has_extra_semantics?(msg)
  end

  defp maybe_empty_assistant(msg) do
    if empty_assistant?(msg), do: nil, else: msg
  end

  defp content_empty?(nil), do: true
  defp content_empty?(""), do: true
  defp content_empty?(content) when is_binary(content), do: String.trim(content) == ""
  defp content_empty?(_), do: false

  defp has_extra_semantics?(msg) do
    keys = Map.keys(msg) -- ["role", "content", "tool_calls", "created_at"]
    Enum.any?(keys, fn key -> msg[key] not in [nil, "", [], %{}] end)
  end

  # ── validation helpers ──

  defp unique_ids(records) do
    ids = Enum.map(records, &record_id/1)

    if length(ids) == length(Enum.uniq(ids)) do
      :ok
    else
      {:error, :duplicate_record}
    end
  end

  defp fingerprints_match(_messages, records, source) do
    calls = source_calls(source)

    Enum.reduce_while(records, :ok, fn rec, :ok ->
      id = record_id(rec)
      sha = rec[:source_sha] || rec["source_sha"]

      case calls && Map.get(calls, id) do
        %{source_sha: ^sha} when is_binary(sha) -> {:cont, :ok}
        %{"source_sha" => ^sha} when is_binary(sha) -> {:cont, :ok}
        nil when is_nil(calls) -> {:cont, :ok}
        _ -> {:halt, {:error, :fingerprint_mismatch}}
      end
    end)
  end

  defp source_calls(nil), do: nil
  defp source_calls(%{calls: calls}) when is_map(calls), do: calls
  defp source_calls(%{"calls" => calls}), do: calls
  defp source_calls(_), do: nil

  defp texts_preserved(before, after_msgs, drop_call_ids) do
    before_texts = text_spine(before, drop_call_ids)
    after_texts = text_spine(after_msgs, MapSet.new())

    if before_texts == after_texts do
      :ok
    else
      {:error, :text_mutated}
    end
  end

  defp text_spine(messages, drop_call_ids) do
    Enum.flat_map(messages, fn msg ->
      cond do
        catalog_message?(msg) ->
          []

        msg["role"] == "tool" and MapSet.member?(drop_call_ids, msg["tool_call_id"]) ->
          []

        msg["role"] in ["system", "user", "assistant"] ->
          content = msg["content"]

          if is_binary(content) do
            [{msg["role"], content}]
          else
            [{msg["role"], :non_binary}]
          end

        true ->
          []
      end
    end)
  end

  defp pairing_intact(messages) do
    {calls, results} =
      Enum.reduce(messages, {[], []}, fn msg, {calls, results} ->
        calls =
          if msg["role"] == "assistant" and is_list(msg["tool_calls"]) do
            calls ++ Enum.flat_map(msg["tool_calls"], fn c -> if is_binary(c["id"]), do: [c["id"]], else: [] end)
          else
            calls
          end

        results =
          if msg["role"] == "tool" and is_binary(msg["tool_call_id"]) do
            results ++ [msg["tool_call_id"]]
          else
            results
          end

        {calls, results}
      end)

    if Enum.sort(calls) == Enum.sort(results) and length(calls) == length(Enum.uniq(calls)) and
         length(results) == length(Enum.uniq(results)) do
      :ok
    else
      {:error, :pairing_broken}
    end
  end

  defp only_declared_changes(before, after_msgs, _changed_ids, drop_call_ids, drop_result_ids) do
    before_ids = tool_ids(before)
    after_ids = tool_ids(after_msgs)
    removed = MapSet.difference(before_ids, after_ids)
    added = MapSet.difference(after_ids, before_ids)

    cond do
      not MapSet.subset?(removed, drop_call_ids) ->
        {:error, :undeclared_removal}

      not MapSet.subset?(added, MapSet.new()) ->
        {:error, :undeclared_addition}

      true ->
        before_results = result_contents(before)
        after_results = result_contents(after_msgs)

        Enum.reduce_while(Map.keys(before_results), :ok, fn id, :ok ->
          cond do
            MapSet.member?(drop_call_ids, id) ->
              {:cont, :ok}

            MapSet.member?(drop_result_ids, id) ->
              if Map.has_key?(after_results, id), do: {:cont, :ok}, else: {:halt, {:error, :missing_replacement}}

            before_results[id] == after_results[id] ->
              {:cont, :ok}

            true ->
              {:halt, {:error, :undeclared_result_change}}
          end
        end)
    end
  end

  defp tool_ids(messages) do
    messages
    |> Enum.flat_map(fn
      %{"role" => "assistant", "tool_calls" => calls} when is_list(calls) ->
        Enum.flat_map(calls, fn c -> if is_binary(c["id"]), do: [c["id"]], else: [] end)

      _ ->
        []
    end)
    |> MapSet.new()
  end

  defp result_contents(messages) do
    messages
    |> Enum.filter(&(&1["role"] == "tool"))
    |> Map.new(fn msg -> {msg["tool_call_id"], msg["content"]} end)
  end

  defp catalog_message?(%{"role" => "system", "content" => content}) when is_binary(content) do
    String.starts_with?(content, @catalog_prefix)
  end

  defp catalog_message?(_), do: false

  defp records_of(%{records: records}) when is_list(records), do: records
  defp records_of(%{"records" => records}) when is_list(records), do: records
  defp records_of(records) when is_list(records), do: records
  defp records_of(_), do: []

  defp action?(rec, name) do
    rec[:action] == String.to_atom(name) or rec[:action] == name or rec["action"] == name
  end

  defp record_id(rec), do: rec[:tool_call_id] || rec["tool_call_id"]

  defp catalog_digest(records) do
    payload =
      Enum.map(records, fn rec ->
        {record_id(rec), rec[:recovery_id] || rec["recovery_id"]}
      end)

    :crypto.hash(:sha256, :erlang.term_to_binary(payload, [:deterministic]))
    |> Base.encode16(case: :lower)
    |> String.slice(0, 12)
  end

  defp tail_slice(_text, n) when n <= 0, do: ""

  defp tail_slice(text, n) do
    len = String.length(text)
    if len <= n, do: text, else: String.slice(text, len - n, n)
  end
end
