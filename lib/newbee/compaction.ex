defmodule Newbee.Compaction do
  @moduledoc """
  Jev 可回退压缩编排：评分、投影、预算验收与恢复。失败时调用方走原 Archive 路径。
  """

  alias Newbee.Agent.ContextBudget
  alias Newbee.Compaction.{Config, Policy, Projection, Store, JevClient}

  def restore(_session, base_messages, %{mode: :legacy}) when is_list(base_messages) do
    {base_messages, nil, %{outcome: :skipped, reason: :legacy}}
  end

  def restore(nil, base_messages, _config) when is_list(base_messages) do
    {base_messages, nil, %{outcome: :skipped, reason: :no_session}}
  end

  def restore(session, base_messages, _config) when is_list(base_messages) do
    with {:ok, source} <- Store.source_index(session),
         {:ok, manifest} <- load_ok(Store.load(session, source)),
         {:ok, projected, _stats} <- Projection.apply(base_messages, manifest.records, source: source),
         :ok <- Projection.validate(source.view || base_messages, projected, manifest.records) do
      {projected, manifest, %{outcome: :accepted, reason: :restored, records: length(manifest.records)}}
    else
      :none -> {base_messages, nil, %{outcome: :skipped, reason: :no_projection}}
      {:error, reason} -> {base_messages, nil, %{outcome: :restore_ignored, reason: reason}}
      _ -> {base_messages, nil, %{outcome: :restore_ignored, reason: :restore_failed}}
    end
  rescue
    _ -> {base_messages, nil, %{outcome: :restore_ignored, reason: :restore_failed}}
  end

  def try_prune(messages, context, config, deps \\ %{}) when is_list(messages) and is_map(config) do
    stats0 = base_stats()
    interrupt? = Map.get(context, :interrupt?) || fn -> false end

    cond do
      config.mode != :jev ->
        {:skip, :legacy, Map.put(stats0, :reason, :legacy)}

      is_nil(Map.get(context, :session)) ->
        {:skip, :no_session, Map.put(stats0, :reason, :no_session)}

      interrupt?.() ->
        {:interrupted, Map.put(stats0, :reason, :interrupted)}

      true ->
        do_prune(messages, context, config, deps, stats0, interrupt?)
    end
  rescue
    _ -> {:error, :internal_error, base_stats() |> Map.put(:reason, :internal_error)}
  catch
    _, _ -> {:error, :internal_error, base_stats() |> Map.put(:reason, :internal_error)}
  end

  def invalidate(nil), do: :ok
  def invalidate(session), do: Store.clear(session)

  def legacy_reason({:ok, %{stats: %{reason: reason}}}), do: reason
  def legacy_reason({:skip, reason, _}), do: reason
  def legacy_reason({:error, reason, _}), do: reason
  def legacy_reason({:interrupted, _}), do: :interrupted
  def legacy_reason(_), do: :unknown

  # ── prune pipeline ──

  defp do_prune(messages, context, config, deps, stats0, interrupt?) do
    session = context.session
    projection = Map.get(context, :projection)
    budget_opts = Map.get(context, :budget_opts) || []
    scorer = Map.get(deps, :scorer) || (&JevClient.score/4)

    with :ok <- not_interrupted(interrupt?),
         {:ok, source} <- Store.source_index(session),
         {:ok, stripped} <- Projection.strip_catalog(messages, projection),
         {:ok, calls} <- Policy.collect_calls(stripped, config, source, projection),
         {open, pinned} <- split_candidates(calls),
         {:ok, open} <- enough_candidates(open),
         {:ok, recoveries, scored} <- precheck_recoveries(open),
         {:ok, state, fit} <- Policy.build_state(stripped, scored, config: config, goal: Map.get(context, :goal)),
         {:ok, batches} <- Policy.batch_calls(state, Enum.reject(scored, & &1.pinned), config),
         :ok <- not_interrupted(interrupt?),
         {:ok, answers, score_stats} <- scorer.(state, batches, config, interrupt?: interrupt?),
         decisions <- Enum.map(calls, fn call -> Policy.decide(call, answers_for(call, answers), config) end),
         new_records <- build_records(decisions, scored, recoveries, config),
         {:ok, trial, _proj_stats} <- Projection.apply(stripped, new_records, source: source, skip_catalog: true),
         {:ok, trial} <- attach_catalog(trial, merge_records(projection, new_records)),
         :ok <- Projection.validate(stripped, trial, new_records),
         :ok <- pairing_unrepaired(trial),
         {:ok, budget_before, budget_after} <- accept_budget(messages, trial, budget_opts, config),
         :ok <- not_interrupted(interrupt?),
         persist_set <- persist_set(new_records, recoveries),
         :ok <- Store.persist_recoveries(persist_set),
         {:ok, manifest} <- Store.commit(session, source, new_records) do
      stats =
        stats0
        |> Map.merge(%{
          strategy: :jev,
          outcome: :accepted,
          reason: :accepted,
          candidates: length(open),
          pinned: length(pinned),
          kept: count_action(decisions, :keep),
          results_dropped: count_action(decisions, :drop_result),
          calls_dropped: count_action(decisions, :drop_call),
          request_count: Map.get(score_stats, :requests, length(batches)),
          estimated_scoring_tokens: fit.tokens,
          elapsed_ms: Map.get(score_stats, :elapsed_ms, 0),
          budget_before: budget_before.request_tokens,
          budget_after: budget_after.request_tokens,
          saved_tokens_est: budget_before.request_tokens - budget_after.request_tokens,
          reduction_ratio: reduction_ratio(budget_before, budget_after),
          state_fit_stage: fit.stage
        })

      {:ok, %{messages: trial, projection: manifest, stats: stats}}
    else
      {:interrupted, _} ->
        {:interrupted, Map.put(stats0, :reason, :interrupted)}

      :interrupted ->
        {:interrupted, Map.put(stats0, :reason, :interrupted)}

      {:skip, reason} ->
        {:skip, reason, Map.put(stats0, :reason, reason)}

      {:error, reason, score_stats} when is_map(score_stats) ->
        {:error, reason, Map.merge(stats0, %{reason: reason, request_count: Map.get(score_stats, :requests, 0)})}

      {:error, reason} ->
        {:error, reason, Map.put(stats0, :reason, reason)}

      other ->
        {:error, normalize_reason(other), Map.put(stats0, :reason, normalize_reason(other))}
    end
  end

  defp load_ok(:none), do: :none
  defp load_ok({:ok, manifest}), do: {:ok, manifest}
  defp load_ok({:error, reason}), do: {:error, reason}

  defp not_interrupted(interrupt?) do
    if interrupt?.(), do: :interrupted, else: :ok
  end

  defp split_candidates(calls) do
    Enum.split_with(calls, &(not &1.pinned))
  end

  defp enough_candidates([]), do: {:skip, :no_candidates}
  defp enough_candidates(candidates), do: {:ok, candidates}

  defp precheck_recoveries(candidates) do
    {ok, oversized} =
      Enum.split_with(candidates, fn call ->
        case Store.recovery_payload(call) do
          {:ok, _payload, _id, bytes} -> bytes <= Config.max_recovery_bytes()
          _ -> false
        end
      end)

    if ok == [] and oversized != [] do
      {:skip, :recovery_too_large}
    else
      recoveries =
        Enum.map(ok, fn call ->
          {:ok, payload, id, bytes} = Store.recovery_payload(call)
          %{call: call, payload: payload, id: id, bytes: bytes}
        end)

      pinned_over = Enum.map(oversized, &%{&1 | pinned: true, pin_reason: :recovery_too_large})
      {:ok, recoveries, ok ++ pinned_over}
    end
  end

  defp answers_for(call, answers) do
    %{
      keep_call: Map.get(answers, "call_#{call.id}"),
      keep_result: Map.get(answers, "result_#{call.id}")
    }
  end

  defp build_records(decisions, candidates, recoveries, config) do
    by_id = Map.new(candidates, &{&1.id, &1})
    recovery_by_call = Map.new(recoveries, &{&1.call.id, &1})

    decisions
    |> Enum.filter(&(&1.action in [:drop_call, :drop_result]))
    |> Enum.flat_map(fn decision ->
      call = by_id[decision.id]
      recovery = recovery_by_call[decision.id]

      cond do
        is_nil(call) or call.pinned or is_nil(recovery) ->
          []

        decision.action == :drop_result ->
          case Projection.replacement(call.result["content"], recovery.id, config) do
            :keep ->
              []

            text ->
              [
                %{
                  tool_call_id: call.tool_call_id,
                  source_sha: call.source_sha,
                  action: :drop_result,
                  recovery_id: recovery.id,
                  head_chars: config.truncate_head_chars,
                  tail_chars: config.truncate_tail_chars,
                  replacement: text
                }
              ]
          end

        true ->
          [
            %{
              tool_call_id: call.tool_call_id,
              source_sha: call.source_sha,
              action: :drop_call,
              recovery_id: recovery.id
            }
          ]
      end
    end)
  end

  defp merge_records(nil, new_records), do: new_records
  defp merge_records(%{records: existing}, new_records), do: existing ++ new_records
  defp merge_records(_, new_records), do: new_records

  defp attach_catalog(messages, records) do
    case Projection.catalog(records) do
      nil -> {:ok, messages}
      cat -> {:ok, Projection.insert_catalog(messages, cat)}
    end
  end

  defp pairing_unrepaired(messages) do
    if Projection.validate(messages, messages, []) == :ok do
      :ok
    else
      {:error, :pairing_broken}
    end
  end

  defp accept_budget(before_msgs, after_msgs, budget_opts, config) do
    before = ContextBudget.assess(before_msgs, budget_opts)
    afterb = ContextBudget.assess(after_msgs, budget_opts)
    ratio = reduction_ratio(before, afterb)

    if afterb.status == :ok and ratio >= config.min_reduction_ratio do
      {:ok, before, afterb}
    else
      {:skip, :insufficient_reduction}
    end
  end

  defp persist_set(records, recoveries) do
    needed = MapSet.new(records, & &1.recovery_id)
    Enum.filter(recoveries, &MapSet.member?(needed, &1.id))
  end

  defp reduction_ratio(before, afterb) do
    if before.request_tokens <= 0 do
      0.0
    else
      (before.request_tokens - afterb.request_tokens) / before.request_tokens
    end
  end

  defp count_action(decisions, action), do: Enum.count(decisions, &(&1.action == action))

  defp base_stats do
    %{
      strategy: :jev,
      outcome: :skipped,
      reason: nil,
      candidates: 0,
      pinned: 0,
      kept: 0,
      results_dropped: 0,
      calls_dropped: 0,
      request_count: 0,
      estimated_scoring_tokens: 0,
      elapsed_ms: 0,
      budget_before: 0,
      budget_after: 0,
      saved_tokens_est: 0,
      reduction_ratio: 0.0,
      state_fit_stage: 0
    }
  end

  defp normalize_reason(reason) when is_atom(reason), do: reason
  defp normalize_reason({reason, _}) when is_atom(reason), do: reason
  defp normalize_reason(_), do: :internal_error
end
