defmodule Newbee.Learning.Evaluation do
  @moduledoc """
  Frozen evaluation protocol and report generation for the BRS/DRS v2
  background-learning experiment (docs/brs-drs-design.md §8).

  `lock/1` freezes a comparison *before* any outcome is observed: source,
  dependency and release snapshots, model/provider/judge configuration, the
  separated development/held-out fixture cohorts, trial count, per-task
  budget, and the two memory arms (baseline M0 vs candidate Mn). The locked
  protocol enumerates every planned arm run with an interleaved order so the
  cohort cannot be re-scoped after results are seen.

  `summarize/2` folds recorded outcomes into an auditable report. Semantic
  failures (`"fail"`) are kept strictly distinct from missing, cancelled,
  unknown and infrastructure-error outcomes; no best-of retries, historical
  imputation or post-hoc trimming is performed. Small samples are reported
  descriptively only and never promote automatically.

  All data is JSON-safe with string keys. Hashing is canonical (sorted-key
  JSON, SHA-256 hex) and self-contained in this module until
  `Newbee.Learning.Store.hash/1` lands, at which point the stores may share
  an implementation without changing produced hashes.

  This module is pure: no GenServer, no IO, no sandboxing. Actual sandboxed
  execution and the learning pipeline are owned by other components.
  """

  alias Newbee.Learning.Fixtures

  @schema_version 1
  @min_full_pairs 30
  @arms ["baseline", "candidate"]
  @statuses ["pass", "fail", "unknown", "infra_error", "cancelled", "missing"]
  @unresolved ["missing", "cancelled", "unknown", "infra_error"]
  @conclusions ["improved", "regressed", "no_clear_gain", "invalid"]

  # ---------------------------------------------------------------- lock/1

  @doc """
  Freeze an evaluation protocol from a JSON-safe spec map.

  Returns `{:ok, protocol}` where the protocol contains the normalized spec,
  the fully enumerated interleaved plan, and a canonical `protocol_hash`;
  or `{:error, reason}` describing the first validation failure.
  """
  @spec lock(map()) :: {:ok, map()} | {:error, term()}
  def lock(spec) when is_map(spec) do
    with :ok <- json_safe(spec),
         {:ok, normalized} <- normalize_spec(spec),
         {:ok, plan} <- build_plan(normalized) do
      protocol = %{
        "schema_version" => @schema_version,
        "name" => normalized["name"],
        "spec" => Map.delete(normalized, "name"),
        "plan" => plan
      }

      {:ok, Map.put(protocol, "protocol_hash", hash(protocol))}
    end
  end

  def lock(_other), do: {:error, :invalid_spec}

  defp normalize_spec(spec) do
    with {:ok, source} <- fetch_map(spec, "source"),
         {:ok, tree_hash} <- fetch_nonempty_string(source, "tree_hash"),
         {:ok, dependencies_hash} <- fetch_nonempty_string(source, "dependencies_hash"),
         {:ok, release_map} <- fetch_map(spec, "release_map"),
         {:ok, model} <- fetch_map(spec, "model"),
         {:ok, provider} <- fetch_nonempty_string(model, "provider"),
         {:ok, model_name} <- fetch_nonempty_string(model, "name"),
         {:ok, judge} <- fetch_map(spec, "judge"),
         {:ok, judge_id} <- fetch_nonempty_string(judge, "id"),
         {:ok, judge_version} <- fetch_nonempty_string(judge, "version"),
         {:ok, fixtures} <- fetch_map(spec, "fixtures"),
         {:ok, development} <- fetch_id_list(fixtures, "development"),
         {:ok, heldout} <- fetch_id_list(fixtures, "heldout"),
         :ok <- check_disjoint(development, heldout),
         :ok <- check_heldout(heldout),
         {:ok, trials} <- fetch_trials(spec),
         {:ok, budget} <- fetch_budget(spec),
         {:ok, arms} <- fetch_arms(spec),
         {:ok, learning_cost} <- fetch_cost(spec, "learning_cost"),
         {:ok, seed} <- fetch_seed(spec),
         {:ok, name} <- fetch_name(spec) do
      {:ok,
       %{
         "name" => name,
         "source" => %{"tree_hash" => tree_hash, "dependencies_hash" => dependencies_hash},
         "release_map" => stringify_keys(release_map),
         "model" =>
           %{"provider" => provider, "name" => model_name}
           |> put_optional(model, "config_hash"),
         "judge" =>
           %{"id" => judge_id, "version" => judge_version}
           |> put_optional(judge, "config_hash"),
         "fixtures" => %{"development" => development, "heldout" => heldout},
         "trials" => trials,
         "budget" => %{"per_task" => budget},
         "arms" => arms,
         "learning_cost" => learning_cost,
         "seed" => seed
       }}
    end
  end

  defp fetch_map(spec, key) do
    case Map.get(spec, key) do
      m when is_map(m) -> {:ok, m}
      nil -> {:error, {:missing_field, key}}
      _ -> {:error, {:invalid_field, key}}
    end
  end

  defp fetch_nonempty_string(map, key) do
    case Map.get(map, key) do
      s when is_binary(s) and s != "" -> {:ok, s}
      nil -> {:error, {:missing_field, key}}
      _ -> {:error, {:invalid_field, key}}
    end
  end

  defp fetch_id_list(fixtures, key) do
    case Map.get(fixtures, key) do
      ids when is_list(ids) ->
        if Enum.all?(ids, &(is_binary(&1) and &1 != "")),
          do: {:ok, ids},
          else: {:error, {:invalid_field, "fixtures." <> key}}

      nil ->
        {:error, {:missing_field, "fixtures." <> key}}

      _ ->
        {:error, {:invalid_field, "fixtures." <> key}}
    end
  end

  defp check_disjoint(development, heldout) do
    case MapSet.intersection(MapSet.new(development), MapSet.new(heldout)) |> MapSet.to_list() do
      [] -> :ok
      overlap -> {:error, {:overlapping_cohorts, overlap}}
    end
  end

  defp check_heldout([]), do: {:error, :empty_heldout}
  defp check_heldout(_), do: :ok

  defp fetch_trials(spec) do
    case Map.get(spec, "trials") do
      t when is_integer(t) and t >= 1 -> {:ok, t}
      nil -> {:error, {:missing_field, "trials"}}
      _ -> {:error, :invalid_trials}
    end
  end

  defp fetch_budget(spec) do
    with {:ok, budget} <- fetch_map(spec, "budget") do
      case Map.get(budget, "per_task") do
        n when is_number(n) and n > 0 -> {:ok, n}
        nil -> {:error, {:missing_field, "budget.per_task"}}
        _ -> {:error, {:invalid_field, "budget.per_task"}}
      end
    end
  end

  defp fetch_arms(spec) do
    with {:ok, arms} <- fetch_map(spec, "arms") do
      with {:ok, baseline} <- fetch_map(arms, "baseline"),
           {:ok, candidate} <- fetch_map(arms, "candidate"),
           {:ok, baseline_memory} <- fetch_nonempty_string(baseline, "memory_id"),
           {:ok, candidate_memory} <- fetch_nonempty_string(candidate, "memory_id") do
        if baseline_memory == candidate_memory do
          {:error, :identical_arms}
        else
          {:ok,
           %{
             "baseline" => %{"memory_id" => baseline_memory},
             "candidate" => %{"memory_id" => candidate_memory}
           }}
        end
      end
    end
  end

  defp fetch_cost(spec, key) do
    case Map.get(spec, key) do
      nil ->
        {:ok, %{}}

      m when is_map(m) ->
        if Enum.all?(m, fn {k, v} -> is_binary(k) and is_number(v) and v >= 0 end),
          do: {:ok, m},
          else: {:error, {:invalid_field, key}}

      _ ->
        {:error, {:invalid_field, key}}
    end
  end

  defp fetch_seed(spec) do
    case Map.get(spec, "seed") do
      nil -> {:ok, 0}
      s when is_integer(s) and s >= 0 -> {:ok, s}
      _ -> {:error, {:invalid_field, "seed"}}
    end
  end

  defp fetch_name(spec) do
    case Map.get(spec, "name") do
      nil -> {:ok, "evaluation"}
      s when is_binary(s) and s != "" -> {:ok, s}
      _ -> {:error, {:invalid_field, "name"}}
    end
  end

  defp put_optional(target, source, key) do
    case Map.get(source, key) do
      s when is_binary(s) and s != "" -> Map.put(target, key, s)
      _ -> target
    end
  end

  defp stringify_keys(map) do
    Map.new(map, fn
      {k, v} when is_binary(k) -> {k, v}
      {k, v} -> {to_string(k), v}
    end)
  end

  # Enumerate every planned pair: held-out fixture x trial x both arms,
  # interleaving arm order deterministically per (fixture, trial, seed) so
  # neither arm systematically runs first.
  defp build_plan(spec) do
    seed = spec["seed"]
    trials = spec["trials"]

    cells =
      spec["fixtures"]["heldout"]
      |> Enum.with_index()
      |> Enum.flat_map(fn {fixture_id, fixture_index} ->
        Enum.flat_map(0..(trials - 1), fn trial ->
          pair_index = fixture_index * trials + trial

          arms =
            if rem(fixture_index + trial + seed, 2) == 0,
              do: ["baseline", "candidate"],
              else: ["candidate", "baseline"]

          Enum.map(arms, fn arm ->
            %{
              "fixture_id" => fixture_id,
              "trial" => trial,
              "pair_index" => pair_index,
              "arm" => arm,
              "status" => "planned"
            }
          end)
        end)
      end)

    {:ok, Enum.map(Enum.with_index(cells), fn {cell, seq} -> Map.put(cell, "sequence", seq) end)}
  end

  # ------------------------------------------------------------ summarize/2

  @doc """
  Fold recorded outcomes into a frozen evaluation report.

  `outcomes` is a list of JSON-safe maps with `"fixture_id"`, `"trial"`,
  `"arm"` and `"status"` (one of `pass`, `fail`, `unknown`, `infra_error`,
  `cancelled`, `missing`), optional `"cost"` (map of numbers), optional
  `"attempt_id"` and optional `"protocol_hash"` (checked against the locked
  protocol when present to forbid mismatched snapshots/judges).

  Planned cells without any recorded outcome count as `"missing"`, kept
  distinct from semantic `"fail"`. Duplicate attempts for the same cell are
  rejected (`{:duplicate_attempt, key}`): no best-of retries.
  """
  @spec summarize(map(), [map()]) :: {:ok, map()} | {:error, term()}
  def summarize(%{"spec" => spec, "plan" => plan, "protocol_hash" => protocol_hash} = protocol, outcomes)
      when is_map(spec) and is_list(plan) and is_binary(protocol_hash) and is_list(outcomes) do
    if Map.get(protocol, "schema_version") == @schema_version do
      with {:ok, normalized} <- normalize_outcomes(outcomes, protocol_hash, plan),
           :ok <- check_duplicates(normalized),
           {:ok, cells} <- merge(plan, normalized) do
        {:ok, build_report(protocol, cells)}
      end
    else
      {:error, :invalid_protocol}
    end
  end

  def summarize(_protocol, _outcomes), do: {:error, :invalid_protocol}

  defp normalize_outcomes(outcomes, protocol_hash, plan) do
    Enum.reduce_while(outcomes, {:ok, []}, fn outcome, {:ok, acc} ->
      case normalize_outcome(outcome, protocol_hash, plan) do
        {:ok, entry} -> {:cont, {:ok, [entry | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp normalize_outcome(outcome, protocol_hash, plan) when is_map(outcome) do
    with :ok <- check_protocol_hash(outcome, protocol_hash),
         {:ok, fixture_id} <- fetch_nonempty_string(outcome, "fixture_id"),
         {:ok, trial} <- fetch_trial(outcome),
         {:ok, arm} <- fetch_arm(outcome),
         {:ok, status} <- fetch_status(outcome),
         :ok <- check_known_cell(plan, fixture_id, trial, arm),
         {:ok, cost} <- fetch_cost(outcome, "cost") do
      {:ok,
       %{
         "fixture_id" => fixture_id,
         "trial" => trial,
         "arm" => arm,
         "status" => status,
         "cost" => cost,
         "attempt_id" => optional_string(outcome, "attempt_id")
       }}
    end
  end

  defp normalize_outcome(_other, _hash, _plan), do: {:error, :invalid_outcome}

  # Forbid mismatched snapshots/judges: an outcome pinned to a different
  # protocol hash can never be folded into this report.
  defp check_protocol_hash(outcome, protocol_hash) do
    case Map.get(outcome, "protocol_hash") do
      nil -> :ok
      ^protocol_hash -> :ok
      _other -> {:error, :protocol_hash_mismatch}
    end
  end

  defp fetch_trial(outcome) do
    case Map.get(outcome, "trial") do
      t when is_integer(t) and t >= 0 -> {:ok, t}
      _ -> {:error, {:invalid_field, "trial"}}
    end
  end

  defp fetch_arm(outcome) do
    case Map.get(outcome, "arm") do
      arm when arm in @arms -> {:ok, arm}
      _ -> {:error, {:invalid_field, "arm"}}
    end
  end

  defp fetch_status(outcome) do
    case Map.get(outcome, "status") do
      s when s in @statuses -> {:ok, s}
      _ -> {:error, {:invalid_status, Map.get(outcome, "status")}}
    end
  end

  defp check_known_cell(plan, fixture_id, trial, arm) do
    known? =
      Enum.any?(plan, fn cell ->
        cell["fixture_id"] == fixture_id and cell["trial"] == trial and cell["arm"] == arm
      end)

    if known?, do: :ok, else: {:error, {:unknown_cell, fixture_id, trial, arm}}
  end

  defp optional_string(map, key) do
    case Map.get(map, key) do
      s when is_binary(s) -> s
      _ -> nil
    end
  end

  defp check_duplicates(normalized) do
    keys =
      Enum.map(normalized, fn o ->
        {o["fixture_id"], o["trial"], o["arm"], o["attempt_id"]}
      end)

    dup = keys |> Enum.frequencies() |> Enum.find(fn {_k, n} -> n > 1 end)

    case dup do
      nil -> :ok
      {key, _n} -> {:error, {:duplicate_attempt, Tuple.to_list(key)}}
    end
  end

  defp merge(plan, normalized) do
    by_cell = Map.new(normalized, fn o -> {{o["fixture_id"], o["trial"], o["arm"]}, o} end)

    cells =
      Enum.map(plan, fn cell ->
        key = {cell["fixture_id"], cell["trial"], cell["arm"]}

        case Map.fetch(by_cell, key) do
          {:ok, outcome} ->
            cell
            |> Map.put("status", outcome["status"])
            |> Map.put("cost", outcome["cost"])
            |> Map.put("attempt_id", outcome["attempt_id"])

          :error ->
            cell
            |> Map.put("status", "missing")
            |> Map.put("cost", %{})
            |> Map.put("attempt_id", nil)
        end
      end)

    {:ok, cells}
  end

  defp build_report(protocol, cells) do
    spec = protocol["spec"]
    pairs = Enum.group_by(cells, & &1["pair_index"])

    per_pair = Enum.map(Enum.sort(Map.keys(pairs)), &analyze_pair(&1, Map.fetch!(pairs, &1)))
    resolved = Enum.filter(per_pair, & &1["resolved"])

    diffs = Enum.map(resolved, & &1["difference"])
    n = length(diffs)
    mean_diff = if n > 0, do: Enum.sum(diffs) / n, else: 0.0

    unresolved? = Enum.any?(cells, &(&1["status"] in @unresolved))
    budget_check = budget_check(cells, spec["budget"]["per_task"])

    conclusion = conclude(unresolved?, n, mean_diff, budget_check["exceeded_count"])
    costs = cost_totals(spec["learning_cost"], cells)

    %{
      "schema_version" => @schema_version,
      "name" => protocol["name"],
      "protocol_hash" => protocol["protocol_hash"],
      "conclusion" => conclusion,
      "promotion" => "manual_review_required",
      "snapshot" => %{
        "source" => spec["source"],
        "release_map" => spec["release_map"],
        "model" => spec["model"],
        "judge" => spec["judge"],
        "arms" => spec["arms"]
      },
      "coverage" => coverage(cells, per_pair),
      "status_counts" => status_counts(cells),
      "paired_differences" => paired_differences(per_pair),
      "regressions" => regression_list(resolved, "regression"),
      "improvements" => regression_list(resolved, "improvement"),
      "difference_stats" => difference_stats(diffs, mean_diff, n),
      "budget" => budget_check,
      "cost" => costs,
      "all_outcomes" => Enum.sort_by(cells, & &1["sequence"]),
      "notes" => notes(n, unresolved?, budget_check["exceeded_count"])
    }
  end

  defp analyze_pair(pair_index, cells) do
    baseline = Enum.find(cells, &(&1["arm"] == "baseline"))
    candidate = Enum.find(cells, &(&1["arm"] == "candidate"))
    resolved? = baseline["status"] in ["pass", "fail"] and candidate["status"] in ["pass", "fail"]

    base = %{
      "pair_index" => pair_index,
      "fixture_id" => baseline["fixture_id"],
      "trial" => baseline["trial"],
      "baseline_status" => baseline["status"],
      "candidate_status" => candidate["status"],
      "resolved" => resolved?
    }

    if resolved? do
      diff = score(candidate["status"]) - score(baseline["status"])

      base
      |> Map.put("difference", diff)
      |> Map.put("classification", classify(diff))
    else
      base
    end
  end

  defp score("pass"), do: 1

  defp classify(diff) when diff > 0, do: "improvement"
  defp classify(diff) when diff < 0, do: "regression"
  defp classify(_), do: "unchanged"

  defp coverage(cells, per_pair) do
    planned = length(cells)
    semantic = Enum.count(cells, &(&1["status"] in ["pass", "fail"]))

    by_arm =
      Map.new(@arms, fn arm ->
        arm_cells = Enum.filter(cells, &(&1["arm"] == arm))
        {arm, %{
           "planned" => length(arm_cells),
           "semantic" => Enum.count(arm_cells, &(&1["status"] in ["pass", "fail"])),
           "unresolved" => Enum.count(arm_cells, &(&1["status"] in @unresolved))
         }}
      end)

    %{
      "planned_cells" => planned,
      "semantic_cells" => semantic,
      "unresolved_cells" => planned - semantic,
      "coverage_ratio" => ratio(semantic, planned),
      "per_arm" => by_arm,
      "planned_pairs" => length(per_pair),
      "resolved_pairs" => Enum.count(per_pair, & &1["resolved"])
    }
  end

  defp ratio(_num, 0), do: 0.0
  defp ratio(num, den), do: num / den

  defp status_counts(cells) do
    counts = Map.new(@statuses, &{&1, 0})
    Enum.reduce(cells, counts, fn cell, acc -> Map.update!(acc, cell["status"], &(&1 + 1)) end)
  end

  defp paired_differences(per_pair) do
    Enum.map(per_pair, fn pair ->
      base = %{
        "pair_index" => pair["pair_index"],
        "fixture_id" => pair["fixture_id"],
        "trial" => pair["trial"],
        "baseline_status" => pair["baseline_status"],
        "candidate_status" => pair["candidate_status"],
        "resolved" => pair["resolved"]
      }

      if pair["resolved"] do
        base
        |> Map.put("difference", pair["difference"])
        |> Map.put("classification", pair["classification"])
      else
        base
      end
    end)
  end

  defp regression_list(resolved, kind) do
    resolved
    |> Enum.filter(&(&1["classification"] == kind))
    |> Enum.map(&%{"pair_index" => &1["pair_index"], "fixture_id" => &1["fixture_id"], "trial" => &1["trial"]})
  end

  # Descriptive statistics only: with tiny samples the interval is reported
  # for transparency but never authorizes automatic promotion.
  defp difference_stats(diffs, mean_diff, n) do
    variance =
      if n > 1 do
        Enum.reduce(diffs, 0.0, fn d, acc -> acc + (d - mean_diff) * (d - mean_diff) end) / (n - 1)
      else
        0.0
      end

    half_width = if n > 1, do: 1.96 * :math.sqrt(variance / n), else: 0.0

    %{
      "resolved_pairs" => n,
      "mean_difference" => mean_diff,
      "interval_95_descriptive" => %{"low" => mean_diff - half_width, "high" => mean_diff + half_width},
      "min_pairs_for_full_power" => @min_full_pairs,
      "small_sample" => n < @min_full_pairs,
      "sample_limit" =>
        if(n < @min_full_pairs,
          do: "small_sample_descriptive_only",
          else: "sufficient_pairs_descriptive"
        )
    }
  end

  defp budget_check(cells, per_task) do
    per_task_cells =
      cells
      |> Enum.group_by(&{&1["fixture_id"], &1["trial"], &1["arm"]})
      |> Enum.map(fn {{fixture_id, trial, arm}, group} ->
        %{
          "fixture_id" => fixture_id,
          "trial" => trial,
          "arm" => arm,
          "cost_total" => sum_cost(Enum.map(group, & &1["cost"]))
        }
      end)

    exceeded = Enum.filter(per_task_cells, &(&1["cost_total"] > per_task))

    %{
      "per_task" => per_task,
      "per_task_cells" => per_task_cells,
      "exceeded" => exceeded,
      "exceeded_count" => length(exceeded)
    }
  end

  defp cost_totals(learning_cost, cells) do
    evaluation = merge_costs(Enum.map(cells, & &1["cost"]))

    %{
      "learning" => learning_cost,
      "evaluation" => evaluation,
      "learning_total" => sum_cost([learning_cost]),
      "evaluation_total" => sum_cost([evaluation]),
      "total" => sum_cost([learning_cost, evaluation])
    }
  end

  defp conclude(unresolved?, n, mean, exceeded_count)

  defp conclude(true, _n, _mean, _exceeded), do: "invalid"
  defp conclude(false, 0, _mean, _exceeded), do: "invalid"
  defp conclude(false, _n, _mean, exceeded) when exceeded > 0, do: "invalid"
  defp conclude(false, _n, mean, _exceeded) when mean > 0.0, do: "improved"
  defp conclude(false, _n, mean, _exceeded) when mean < 0.0, do: "regressed"
  defp conclude(false, _n, _mean, _exceeded), do: "no_clear_gain"

  defp notes(n, unresolved?, exceeded_count) do
    []
    |> maybe_note(n < @min_full_pairs, "tiny_sample_no_automatic_promotion")
    |> maybe_note(unresolved?, "unresolved_outcomes_block_conclusion")
    |> maybe_note(exceeded_count > 0, "per_task_budget_exceeded")
  end

  defp maybe_note(notes, true, note), do: [note | notes]
  defp maybe_note(notes, false, _note), do: notes

  defp merge_costs(costs) do
    Enum.reduce(costs, %{}, fn cost, acc ->
      Map.merge(acc, cost, fn _k, a, b -> a + b end)
    end)
  end

  defp sum_cost(costs) do
    costs |> merge_costs() |> Map.values() |> Enum.sum()
  end

  # --------------------------------------------------------- canonical JSON

  @doc """
  Canonical JSON encoding: object keys sorted lexicographically, no
  whitespace, UTF-8. Raises on values that are not JSON-safe.
  """
  @spec canonical_json(term()) :: binary()
  def canonical_json(value) do
    value
    |> canonicalize!()
    |> Jason.encode!(maps: :strict)
  end

  @doc """
  Canonical SHA-256 hex hash of a JSON-safe value. Self-contained
  implementation; intended to converge with `Newbee.Learning.Store.hash/1`
  when the durable store lands.
  """
  @spec hash(term()) :: binary()
  def hash(value) do
    :sha256 |> :crypto.hash(canonical_json(value)) |> Base.encode16(case: :lower)
  end

  defp canonicalize!(value) when is_map(value) do
    value
    |> Enum.map(fn {k, v} -> {canonical_key!(k), canonicalize!(v)} end)
    |> Enum.sort_by(&elem(&1, 0))
    |> Jason.OrderedObject.new()
  end

  defp canonicalize!(value) when is_list(value), do: Enum.map(value, &canonicalize!/1)

  defp canonicalize!(value)
       when is_binary(value) or is_integer(value) or is_float(value) or is_boolean(value) or
              is_nil(value),
       do: value

  defp canonicalize!(other),
    do: raise(ArgumentError, "not a JSON-safe value: #{inspect(other)}")

  defp canonical_key!(key) when is_binary(key), do: key
  defp canonical_key!(key) when is_atom(key), do: Atom.to_string(key)

  defp canonical_key!(other),
    do: raise(ArgumentError, "not a JSON-safe key: #{inspect(other)}")

  defp json_safe(term), do: if(json_safe?(term), do: :ok, else: {:error, :not_json_safe})

  defp json_safe?(term) when is_map(term),
    do: Enum.all?(term, fn {k, v} -> is_binary(k) and json_safe?(v) end)

  defp json_safe?(term) when is_list(term), do: Enum.all?(term, &json_safe?/1)

  defp json_safe?(term),
    do: is_binary(term) or is_integer(term) or is_float(term) or is_boolean(term) or is_nil(term)

  # Introspection helpers for other learning components.

  @doc "Arm identifiers in canonical order."
  def arms, do: @arms

  @doc "All valid outcome statuses."
  def statuses, do: @statuses

  @doc "Non-semantic statuses: recorded but never counted as learning evidence."
  def unresolved_statuses, do: @unresolved

  @doc "Valid evaluation conclusions."
  def conclusions, do: @conclusions

  @doc "Fixture suite version used to pin the cohort (see Fixtures.version/0)."
  def fixture_version, do: Fixtures.version()
end