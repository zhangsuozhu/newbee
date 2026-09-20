defmodule Newbee.Learning.State do
  @moduledoc """
  Pure learning-state reducer for BRS/DRS v2 (docs/brs-drs-design.md).

  Owns the v2 contracts: immutable baseline, advancing `learning_head`,
  three separate attempt fields (execution / verdict / admission), CAS via
  `command_id` + `expected_revision`, budget reserve/reconcile (including
  ambiguous calls), and the BRS whole-wave barrier.

  This module is pure: `new/1` and `apply/2` only transform string-keyed,
  JSON-safe maps. No process, no clock, no I/O — timestamps must arrive in
  payloads. `Newbee.Environment.Coordinator` (owned by the Lead) stays the
  event authority: it sequences artifact seals in `Newbee.Learning.Store`,
  calls this reducer, and appends the durable `memory_committed` event as
  the sole commit point. Crash before the event leaves unreferenced
  artifacts and an unchanged head; crash after replays the same commit —
  a repeated `command_id` with the same payload returns the original
  receipt without re-applying, and with a different payload it is rejected.
  """

  alias Newbee.Learning.{Contracts, Store}

  @zero_budget %{
    "calls" => 0,
    "tokens" => 0,
    "wall_ms" => 0,
    "disk_bytes" => 0,
    "eval_reserve" => 0
  }

  # ── construction ──

  @doc """
  Build the initial state at `revision` 0 from a spec map:

      %{
        "baseline" => %{...},           # Contracts.validate_baseline/1
        "budget" => %{"total" => %{...}} # optional; defaults to zero totals
      }
  """
  def new(spec) when is_map(spec) do
    baseline = Map.get(spec, "baseline", %{})

    with :ok <- Contracts.validate_baseline(baseline),
         {:ok, budget} <- build_budget(Map.get(spec, "budget", %{})) do
      m0 = baseline["memory_m0"]

      state = %{
        "id" => Map.get(spec, "id", baseline["id"]),
        "schema_version" => Contracts.schema_version(),
        "revision" => 0,
        "status" => "active",
        "stop_reason" => nil,
        "baseline" => baseline,
        "learning_head" => m0,
        "memories" => %{
          m0 => %{
            "id" => m0,
            "parent_id" => nil,
            "ordered_experience_ids" => [],
            "entry_hashes" => [],
            "manifest_hash" => nil,
            "schema_version" => Contracts.schema_version()
          }
        },
        "attempts" => %{},
        "budget" => budget,
        "evaluations" => %{},
        "brs_waves" => %{},
        "processed_commands" => %{}
      }

      {:ok, state}
    end
  end

  def new(_), do: {:error, {:invalid_spec, "expected a map"}}

  defp build_budget(spec) do
    total = Map.get(spec, "total", @zero_budget)

    with :ok <- Contracts.validate_budget_map(total, "budget.total") do
      {:ok,
       %{
         "total" => Map.merge(@zero_budget, total),
         "reserved" => Map.new(@zero_budget, fn {k, _} -> {k, 0} end),
         "spent" => Map.new(@zero_budget, fn {k, _} -> {k, 0} end)
       }}
    end
  end

  # ── command application ──

  @doc """
  Apply a command map `%{"id","type","expected_revision","payload"}`.

  Returns `{:ok, next_state, receipt}` or `{:error, reason}`. Wire duality
  (decimal text instead of numbers) is normalized at this boundary via
  `Contracts.normalize_command/1`.

  Rejections: `{:error, :revision_conflict}` when `expected_revision` does
  not match, `{:error, :command_payload_mismatch}` when a known
  `command_id` arrives with a different payload, plus validation errors.
  A repeated `command_id` with the identical payload replays the original
  receipt and leaves the state untouched.
  """
  def apply(state, command) when is_map(state) and is_map(command) do
    command = Contracts.normalize_command(command)

    with :ok <- Contracts.validate_command(command),
         :ok <- check_revision(state, command) do
      id = command["id"]

      case Map.fetch(state["processed_commands"], id) do
        {:ok, %{"payload_hash" => seen_hash, "receipt" => receipt}} ->
          if seen_hash == Store.hash(command["payload"]) do
            # Idempotent replay: same commit, no second application.
            {:ok, state, receipt}
          else
            {:error, :command_payload_mismatch}
          end

        :error ->
          dispatch(state, command)
      end
    end
  end

  def apply(_, _), do: {:error, {:invalid_command, "expected state and command maps"}}

  defp check_revision(state, command) do
    if command["expected_revision"] == state["revision"] do
      :ok
    else
      {:error, :revision_conflict}
    end
  end

  defp dispatch(state, %{"type" => type, "payload" => payload} = command) do
    case do_apply(type, state, payload) do
      {:ok, next, effects} ->
        receipt = build_receipt(command, next, effects)
        {:ok, record_command(next, command, receipt), receipt}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp do_apply("start_attempt", state, p), do: start_attempt(state, p)
  defp do_apply("record_execution", state, p), do: record_execution(state, p)
  defp do_apply("finish_attempt", state, p), do: finish_attempt(state, p)
  defp do_apply("propose_lesson", state, p), do: propose_lesson(state, p)
  defp do_apply("admit", state, p), do: admit(state, p)
  defp do_apply("reject_lesson", state, p), do: reject_lesson(state, p)
  defp do_apply("quarantine_attempt", state, p), do: quarantine_attempt(state, p)
  defp do_apply("record_cost", state, p), do: record_cost(state, p)
  defp do_apply("reconcile_budget", state, p), do: reconcile_budget(state, p)
  defp do_apply("record_ambiguous_call", state, p), do: record_ambiguous_call(state, p)
  defp do_apply("record_evaluation", state, p), do: record_evaluation(state, p)
  defp do_apply("brs_wave_open", state, p), do: brs_wave_open(state, p)
  defp do_apply("brs_wave_close", state, p), do: brs_wave_close(state, p)
  defp do_apply("cancel", state, p), do: cancel(state, p)
  defp do_apply("stop_learning", state, p), do: stop_learning(state, p)

  # ── receipts ──

  defp build_receipt(command, next_state, effects) do
    %{
      "command_id" => command["id"],
      "command_type" => command["type"],
      "revision" => next_state["revision"],
      "state_hash" => Store.hash(receipt_projection(next_state)),
      "effects" => effects,
      "replayed" => false
    }
  end

  # Deterministic projection of the state for receipt hashing; excludes the
  # processed-command journal so replays cannot change earlier state hashes.
  defp receipt_projection(state) do
    Map.drop(state, ["processed_commands"])
  end

  defp record_command(state, command, receipt) do
    entry = %{"payload_hash" => Store.hash(command["payload"]), "receipt" => receipt}
    put_in(state, ["processed_commands", command["id"]], entry)
  end

  defp bump(state), do: %{state | "revision" => state["revision"] + 1}

  defp active?(state), do: state["status"] == "active"

  defp ensure_active(state) do
    if active?(state), do: :ok, else: {:error, {:learning_stopped, state["stop_reason"]}}
  end

  # ── attempt lifecycle ──

  defp start_attempt(state, p) do
    with :ok <- ensure_active(state),
         :ok <- Contracts.require_fields(p, ["attempt_id", "input_memory_id", "contract_hash"]),
         :ok <- Contracts.validate_id(p["attempt_id"], "payload.attempt_id"),
         :ok <- require_known_memory(state, p["input_memory_id"]),
         :ok <- Contracts.require_json_safe(p["contract_hash"], "payload.contract_hash"),
         :ok <- ensure_absent(state["attempts"], p["attempt_id"], :attempt_exists),
         {:ok, reserve} <- optional_budget(p, "reserve"),
         :ok <- check_budget_headroom(state, reserve),
         {:ok, wave_check} <- check_wave_membership(state, p) do
      attempt = %{
        "id" => p["attempt_id"],
        "wave_id" => Map.get(p, "wave_id"),
        "parent_attempt_id" => Map.get(p, "parent_attempt_id"),
        "hive_task_id" => Map.get(p, "hive_task_id"),
        "hive_attempt" => Map.get(p, "hive_attempt"),
        "dispatch_id" => Map.get(p, "dispatch_id"),
        "input_memory_id" => p["input_memory_id"],
        "contract_hash" => p["contract_hash"],
        "submission_id" => nil,
        "submission_hash" => nil,
        "execution_status" => "queued",
        "execution_reason" => nil,
        "verdict" => "pending",
        "admission" => "not_proposed",
        "status_reason" => nil,
        "lesson" => nil,
        "reserved" => reserve,
        "cost" => Map.new(@zero_budget, fn {k, _} -> {k, 0} end),
        "cost_estimated" => false,
        "ambiguous_calls" => [],
        "evidence_hashes" => Map.get(p, "evidence_hashes", [])
      }

      next =
        state
        |> put_in(["attempts", p["attempt_id"]], attempt)
        |> update_in(["budget", "reserved"], &add_budget(&1, reserve))
        |> register_wave_attempt(wave_check, p["attempt_id"])
        |> bump()

      effects = [%{"kind" => "attempt_started", "attempt_id" => p["attempt_id"]}]

      effects =
        if map_size(reserve) > 0,
          do: effects ++ [%{"kind" => "budget_reserved", "attempt_id" => p["attempt_id"], "reserve" => reserve}],
          else: effects

      {:ok, next, effects}
    end
  end

  defp require_known_memory(state, memory_id) do
    if is_binary(memory_id) and Map.has_key?(state["memories"], memory_id) do
      :ok
    else
      {:error, {:unknown_memory, memory_id}}
    end
  end

  defp ensure_absent(map, key, error) do
    if Map.has_key?(map, key), do: {:error, error}, else: :ok
  end

  defp check_wave_membership(state, p) do
    case Map.get(p, "wave_id") do
      nil ->
        {:ok, nil}

      wave_id ->
        case Map.fetch(state["brs_waves"], wave_id) do
          {:ok, %{"status" => "open"}} -> {:ok, wave_id}
          {:ok, _} -> {:error, {:wave_not_open, wave_id}}
          :error -> {:error, {:unknown_wave, wave_id}}
        end
    end
  end

  defp register_wave_attempt(state, nil, _attempt_id), do: state

  defp register_wave_attempt(state, wave_id, attempt_id) do
    update_in(state, ["brs_waves", wave_id, "attempt_ids"], &(&1 ++ [attempt_id]))
  end

  # ── execution / verdict (separate fields, design §8) ──

  defp record_execution(state, p) do
    with :ok <- Contracts.require_fields(p, ["attempt_id", "execution_status"]),
         {:ok, attempt} <- fetch_attempt(state, p["attempt_id"]),
         :ok <-
           Contracts.validate_enum(p["execution_status"], Contracts.execution_statuses(), "payload.execution_status"),
         :ok <- validate_execution_transition(attempt, p),
         {:ok, attempt} <- apply_execution_transition(attempt, p) do
      next = state |> put_in(["attempts", attempt["id"]], attempt) |> bump()

      {:ok, next,
       [%{"kind" => "execution_recorded", "attempt_id" => attempt["id"], "status" => attempt["execution_status"]}]}
    end
  end

  defp validate_execution_transition(attempt, p) do
    to = p["execution_status"]

    cond do
      not Contracts.execution_transition_ok?(attempt["execution_status"], to) ->
        {:error, {:invalid_execution_transition, attempt["execution_status"], to}}

      to == "terminal" and p["execution_reason"] not in Contracts.execution_reasons() ->
        {:error,
         {:invalid_field, "payload.execution_reason",
          "terminal requires completed/infra_error/cancelled/budget_exhausted"}}

      to != "terminal" and Map.has_key?(p, "execution_reason") ->
        {:error, {:invalid_field, "payload.execution_reason", "only a terminal transition carries a reason"}}

      true ->
        :ok
    end
  end

  defp apply_execution_transition(attempt, p) do
    attempt = %{attempt | "execution_status" => p["execution_status"]}

    if p["execution_status"] == "terminal" do
      reason = p["execution_reason"]

      attempt =
        attempt
        |> Map.put("execution_reason", reason)
        |> Map.put("status_reason", Map.get(p, "status_reason"))

      # Only a completed run may ever receive a verdict. infra_error,
      # cancelled, and budget_exhausted settle the verdict as unknown now
      # and finish_attempt will refuse to change it afterwards (design
      # §8: infra_error stays unknown; §13.3 unknown is never upgraded).
      if reason == "completed" do
        {:ok, attempt}
      else
        {:ok, %{attempt | "verdict" => "unknown"}}
      end
    else
      {:ok, attempt}
    end
  end

  defp finish_attempt(state, p) do
    with :ok <- Contracts.require_fields(p, ["attempt_id", "verdict"]),
         {:ok, attempt} <- fetch_attempt(state, p["attempt_id"]),
         :ok <- Contracts.validate_enum(p["verdict"], Contracts.terminal_verdicts(), "payload.verdict"),
         :ok <- ensure_finished(attempt),
         {:ok, evidence} <- optional_hash_list(p, "evidence_hashes"),
         :ok <- optional_submission(p) do
      attempt =
        attempt
        |> Map.put("verdict", p["verdict"])
        |> Map.put("evidence_hashes", attempt["evidence_hashes"] ++ evidence)
        |> maybe_put("submission_id", Map.get(p, "submission_id"))
        |> maybe_put("submission_hash", Map.get(p, "submission_hash"))
        |> maybe_put("checker_version", Map.get(p, "checker_version"))

      next = state |> put_in(["attempts", attempt["id"]], attempt) |> bump()

      {:ok, next, [%{"kind" => "verdict_recorded", "attempt_id" => attempt["id"], "verdict" => p["verdict"]}]}
    end
  end

  # Only a terminal+completed attempt may receive or change a verdict, and
  # only exactly once while it is still pending. Unknown is sticky: neither
  # budget exhaustion nor a later retry of the same attempt upgrades it
  # (design §13.3); a retry is a new attempt with a new id.
  defp ensure_finished(attempt) do
    cond do
      attempt["execution_status"] != "terminal" ->
        {:error, {:not_terminal, attempt["id"]}}

      attempt["execution_reason"] != "completed" ->
        {:error, {:verdict_locked, "non-completed terminal attempts keep verdict=unknown"}}

      attempt["verdict"] != "pending" ->
        {:error, {:verdict_locked, "verdict already recorded as #{attempt["verdict"]}"}}

      true ->
        :ok
    end
  end

  defp optional_submission(p) do
    case {Map.get(p, "submission_id"), Map.get(p, "submission_hash")} do
      {nil, nil} ->
        :ok

      {id, hash} when is_binary(id) and is_binary(hash) ->
        :ok

      _ ->
        {:error, {:invalid_field, "payload.submission", "submission_id and submission_hash must be provided together"}}
    end
  end

  # ── lesson proposal and admission ──

  defp propose_lesson(state, p) do
    with :ok <- ensure_active(state),
         :ok <- Contracts.require_fields(p, ["attempt_id", "lesson"]),
         {:ok, attempt} <- fetch_attempt(state, p["attempt_id"]),
         :ok <- ensure_finished_for_lesson(attempt),
         :ok <- ensure_admission(attempt, ["not_proposed", "rejected"]),
         :ok <- validate_lesson_for(attempt, p["lesson"]) do
      attempt = %{attempt | "admission" => "candidate", "lesson" => p["lesson"]}
      next = state |> put_in(["attempts", attempt["id"]], attempt) |> bump()
      {:ok, next, [%{"kind" => "lesson_proposed", "attempt_id" => attempt["id"]}]}
    end
  end

  defp ensure_finished_for_lesson(attempt) do
    if attempt["execution_status"] == "terminal" and attempt["execution_reason"] == "completed" and
         attempt["verdict"] in ["pass", "fail"] do
      :ok
    else
      {:error, {:not_proposable, "lessons require a completed attempt with a pass/fail verdict"}}
    end
  end

  defp ensure_admission(attempt, allowed) do
    if attempt["admission"] in allowed do
      :ok
    else
      {:error, {:invalid_admission_state, attempt["admission"]}}
    end
  end

  # Positive lessons come from pass verdicts; negative lessons from verified
  # fails. Both need scope/preconditions/counterexample/evidence (§6 step 7).
  defp validate_lesson_for(attempt, lesson) do
    kind = if attempt["verdict"] == "pass", do: :positive, else: :negative
    Contracts.validate_lesson(lesson, kind)
  end

  defp admit(state, p) do
    with :ok <- ensure_active(state),
         :ok <- Contracts.require_fields(p, ["attempt_id", "lesson"]),
         {:ok, attempt} <- fetch_attempt(state, p["attempt_id"]),
         :ok <- ensure_admission(attempt, ["candidate"]),
         :ok <- ensure_lesson_matches(attempt, p["lesson"]),
         :ok <- ensure_admissible_verdict(attempt),
         :ok <- ensure_head_cas(state, attempt),
         {:ok, manifest} <- build_manifest(state, attempt, p["lesson"]) do
      manifest = Map.put(manifest, "manifest_hash", Store.hash(manifest))

      attempt = %{attempt | "admission" => "admitted"}

      next =
        state
        |> put_in(["attempts", attempt["id"]], attempt)
        |> put_in(["memories", manifest["id"]], manifest)
        |> Map.put("learning_head", manifest["id"])
        |> bump()

      {:ok, next,
       [
         %{"kind" => "lesson_admitted", "attempt_id" => attempt["id"]},
         %{
           "kind" => "head_advanced",
           "from" => manifest["parent_id"],
           "to" => manifest["id"],
           "manifest_hash" => manifest["manifest_hash"]
         }
       ]}
    end
  end

  defp ensure_lesson_matches(attempt, lesson) do
    if attempt["lesson"] == lesson do
      :ok
    else
      {:error, {:lesson_mismatch, "admit lesson must equal the proposed candidate lesson"}}
    end
  end

  # Design §13.1/§13.2: pass admits a positive lesson; a verified fail can
  # admit a negative lesson without turning the task into a pass. Unknown
  # and infra_error attempts can never admit (§8, §13.3).
  defp ensure_admissible_verdict(attempt) do
    case attempt["verdict"] do
      v when v in ["pass", "fail"] -> :ok
      other -> {:error, {:not_admissible, "verdict=#{other} cannot admit"}}
    end
  end

  # CAS on the memory head (design §10 step 2): an attempt may only extend
  # the memory it was dispatched with. A stale attempt is rejected so
  # duplicate delivery or a late retry cannot double-admit (§13.7/§13.8).
  defp ensure_head_cas(state, attempt) do
    if state["learning_head"] == attempt["input_memory_id"] do
      :ok
    else
      {:error, :stale_attempt}
    end
  end

  defp build_manifest(state, attempt, lesson) do
    parent_id = state["learning_head"]
    parent = Map.fetch!(state["memories"], parent_id)
    experience_id = "xp-" <> attempt["id"]
    entry = %{"experience_id" => experience_id, "attempt_id" => attempt["id"], "lesson" => lesson}
    entry_hash = Store.hash(entry)

    {:ok,
     %{
       "id" => "mem-" <> entry_hash,
       "parent_id" => parent_id,
       "ordered_experience_ids" => parent["ordered_experience_ids"] ++ [experience_id],
       "entry_hashes" => parent["entry_hashes"] ++ [entry_hash],
       "manifest_hash" => nil,
       "schema_version" => Contracts.schema_version()
     }}
  end

  defp reject_lesson(state, p) do
    with :ok <- Contracts.require_fields(p, ["attempt_id"]),
         {:ok, attempt} <- fetch_attempt(state, p["attempt_id"]),
         :ok <- ensure_admission(attempt, ["candidate", "not_proposed"]) do
      attempt = %{attempt | "admission" => "rejected", "status_reason" => Map.get(p, "reason")}
      next = state |> put_in(["attempts", attempt["id"]], attempt) |> bump()
      {:ok, next, [%{"kind" => "lesson_rejected", "attempt_id" => attempt["id"]}]}
    end
  end

  # Missing artifacts, hash mismatches, or checker mismatch quarantine the
  # work (design §10). Quarantined attempts can never advance memory.
  defp quarantine_attempt(state, p) do
    with :ok <- Contracts.require_fields(p, ["attempt_id"]),
         {:ok, attempt} <- fetch_attempt(state, p["attempt_id"]),
         :ok <- ensure_admission(attempt, ["candidate", "not_proposed", "rejected"]) do
      attempt = %{attempt | "admission" => "quarantined", "status_reason" => Map.get(p, "reason")}
      next = state |> put_in(["attempts", attempt["id"]], attempt) |> bump()
      {:ok, next, [%{"kind" => "attempt_quarantined", "attempt_id" => attempt["id"]}]}
    end
  end

  # ── budgets (design §12: reserve before dispatch, reconcile after) ──

  defp record_cost(state, p) do
    with :ok <- Contracts.require_fields(p, ["attempt_id", "cost"]),
         {:ok, attempt} <- fetch_attempt(state, p["attempt_id"]),
         :ok <- Contracts.validate_budget_map(p["cost"], "payload.cost"),
         :ok <- ensure_terminal(attempt) do
      cost = p["cost"]
      estimated = Map.get(p, "estimated", false)

      attempt =
        attempt
        |> Map.put("cost", add_budget(attempt["cost"], cost))
        |> Map.put("cost_estimated", attempt["cost_estimated"] or estimated)

      next =
        state
        |> put_in(["attempts", attempt["id"]], attempt)
        |> update_in(["budget", "spent"], &add_budget(&1, cost))
        |> bump()

      {:ok, next,
       [%{"kind" => "cost_recorded", "attempt_id" => attempt["id"], "cost" => cost, "estimated" => estimated}]}
    end
  end

  # Reconcile after a terminal attempt (§10/§12): release the reservation
  # and settle actual cost. Ambiguous calls are conservative: if an attempt
  # still carries un-reconciled ambiguous calls, the reservation is kept
  # unless explicitly released by cancel.
  defp reconcile_budget(state, p) do
    with :ok <- Contracts.require_fields(p, ["attempt_id", "cost"]),
         {:ok, attempt} <- fetch_attempt(state, p["attempt_id"]),
         :ok <- Contracts.validate_budget_map(p["cost"], "payload.cost"),
         :ok <- ensure_terminal(attempt),
         :ok <- ensure_no_pending_ambiguity(attempt, p) do
      cost = p["cost"]
      reserved = attempt["reserved"]

      attempt =
        attempt
        |> Map.put("cost", add_budget(attempt["cost"], cost))
        |> Map.put("reserved", Map.new(@zero_budget, fn {k, _} -> {k, 0} end))
        |> Map.put("ambiguous_calls", [])

      next =
        state
        |> put_in(["attempts", attempt["id"]], attempt)
        |> update_in(["budget", "reserved"], &subtract_budget(&1, reserved))
        |> update_in(["budget", "spent"], &add_budget(&1, cost))
        |> bump()

      {:ok, next,
       [
         %{
           "kind" => "budget_reconciled",
           "attempt_id" => attempt["id"],
           "released" => reserved,
           "cost" => cost
         }
       ]}
    end
  end

  defp ensure_no_pending_ambiguity(attempt, p) do
    if attempt["ambiguous_calls"] == [] or Map.get(p, "release_ambiguous", false) do
      :ok
    else
      {:error,
       {:ambiguous_calls_pending, "reconcile requires release_ambiguous=true while ambiguous calls are unreconciled"}}
    end
  end

  # A Host crash after a model call can leave unknown billing/outcome
  # (design §10). Record the ambiguous call and conservatively RETAIN the
  # budget reservation until reconcile; unknown usage is never free (§12).
  defp record_ambiguous_call(state, p) do
    with :ok <- Contracts.require_fields(p, ["attempt_id", "kind"]),
         {:ok, attempt} <- fetch_attempt(state, p["attempt_id"]),
         :ok <- Contracts.require_nonempty_string(p["kind"], "payload.kind"),
         :ok <- ensure_not_terminal_admission(attempt) do
      entry = %{"kind" => p["kind"], "at" => Map.get(p, "at"), "reconciled" => false}
      attempt = %{attempt | "ambiguous_calls" => attempt["ambiguous_calls"] ++ [entry]}
      next = state |> put_in(["attempts", attempt["id"]], attempt) |> bump()

      {:ok, next,
       [
         %{
           "kind" => "ambiguous_call_recorded",
           "attempt_id" => attempt["id"],
           "reservation" => "retained"
         }
       ]}
    end
  end

  defp ensure_not_terminal_admission(attempt) do
    if attempt["admission"] in ["admitted", "quarantined"] do
      {:error, {:invalid_admission_state, attempt["admission"]}}
    else
      :ok
    end
  end

  defp check_budget_headroom(state, reserve) do
    if Map.get(reserve, "eval_reserve", 0) > 0 do
      {:error, {:budget_exhausted, "eval_reserve"}}
    else
      budget = state["budget"]

      lacking =
        Enum.find(reserve, fn {dim, amount} ->
          total = budget["total"][dim] || 0
          available = total - (budget["reserved"][dim] || 0)
          amount > available
        end)

      case lacking do
        nil -> :ok
        {dim, _} -> {:error, {:budget_exhausted, dim}}
      end
    end
  end

  defp ensure_terminal(attempt) do
    if attempt["execution_status"] == "terminal" do
      :ok
    else
      {:error, {:not_terminal, attempt["id"]}}
    end
  end

  defp optional_budget(p, field) do
    case Map.get(p, field) do
      nil ->
        {:ok, %{}}

      budget ->
        case Contracts.validate_budget_map(budget, "payload.#{field}") do
          :ok -> {:ok, budget}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp add_budget(a, b) when is_map(a) and is_map(b) do
    Map.merge(a, b, fn _k, x, y -> x + y end)
  end

  defp subtract_budget(a, b) when is_map(a) and is_map(b) do
    Map.new(a, fn {k, v} -> {k, v - Map.get(b, k, 0)} end)
  end

  # ── evaluation (frozen comparison, design §11) ──

  defp record_evaluation(state, p) do
    with :ok <-
           Contracts.require_fields(p, [
             "evaluation_id",
             "baseline_snapshot_id",
             "candidate_snapshot_id",
             "locked_cohort_hash",
             "outcomes",
             "conclusion"
           ]),
         :ok <- Contracts.validate_id(p["evaluation_id"], "payload.evaluation_id"),
         :ok <- ensure_absent(state["evaluations"], p["evaluation_id"], :evaluation_exists),
         :ok <- validate_outcomes(p["outcomes"]),
         :ok <- Contracts.validate_enum(p["conclusion"], Contracts.eval_conclusions(), "payload.conclusion"),
         {:ok, cost} <- optional_budget(p, "cost"),
         :ok <- Contracts.require_json_safe(p, "payload") do
      evaluation = %{
        "id" => p["evaluation_id"],
        "baseline_snapshot_id" => p["baseline_snapshot_id"],
        "candidate_snapshot_id" => p["candidate_snapshot_id"],
        "locked_cohort_hash" => p["locked_cohort_hash"],
        "judge_version" => Map.get(p, "judge_version"),
        "model_provider_config" => Map.get(p, "model_provider_config"),
        # Every planned outcome is retained verbatim: pass/fail/unknown/
        # infra_error/cancelled/missing are never silently dropped or turned
        # into automatic task zeros (§11).
        "outcomes" => p["outcomes"],
        "cost" => cost,
        "conclusion" => p["conclusion"]
      }

      next =
        state
        |> put_in(["evaluations", evaluation["id"]], evaluation)
        |> update_in(["budget", "spent"], &add_budget(&1, cost))
        |> bump()

      {:ok, next,
       [%{"kind" => "evaluation_recorded", "evaluation_id" => evaluation["id"], "conclusion" => p["conclusion"]}]}
    end
  end

  defp validate_outcomes(outcomes) when is_list(outcomes) do
    Enum.reduce_while(outcomes, :ok, fn outcome, :ok ->
      case outcome do
        %{"task_id" => task_id, "arm" => arm, "result" => result}
        when is_binary(task_id) and arm in ["baseline", "candidate"] ->
          if result in Contracts.eval_outcomes() do
            {:cont, :ok}
          else
            {:halt, {:error, {:invalid_field, "payload.outcomes", "unknown result #{inspect(result)}"}}}
          end

        _ ->
          {:halt, {:error, {:invalid_field, "payload.outcomes", "each outcome needs task_id, arm, result"}}}
      end
    end)
  end

  defp validate_outcomes(_), do: {:error, {:invalid_field, "payload.outcomes", "expected a list"}}

  # ── BRS whole-wave barrier (design §7) ──

  defp brs_wave_open(state, p) do
    with :ok <- ensure_active(state),
         :ok <- Contracts.require_fields(p, ["wave_id"]),
         :ok <- Contracts.validate_id(p["wave_id"], "payload.wave_id"),
         :ok <- ensure_absent(state["brs_waves"], p["wave_id"], :wave_exists),
         {:ok, branch_order} <- validate_branch_order(Map.get(p, "branch_order", [])) do
      wave = %{
        "id" => p["wave_id"],
        "status" => "open",
        # Authored order is frozen before branch scores are observed (§7).
        "branch_order" => branch_order,
        "attempt_ids" => [],
        "blocked_reason" => nil
      }

      next = state |> put_in(["brs_waves", wave["id"]], wave) |> bump()
      {:ok, next, [%{"kind" => "wave_opened", "wave_id" => wave["id"]}]}
    end
  end

  defp validate_branch_order(order) when is_list(order) do
    if Enum.all?(order, &Contracts.id?/1) do
      {:ok, order}
    else
      {:error, {:invalid_field, "payload.branch_order", "expected a list of attempt ids"}}
    end
  end

  defp validate_branch_order(_), do: {:error, {:invalid_field, "payload.branch_order", "expected a list"}}

  # Whole-wave barrier: publication happens only at the complete-wave
  # barrier and only when every wave attempt is terminal with a trusted
  # verdict (pass or fail). Unknown / infra_error / missing evidence blocks
  # publication; an unresolved wave is aborted, never partially published
  # (§7, §13.9). Conflicting lessons stay unresolved and are excluded from
  # the consolidated memory — majority vote is not a truth oracle.
  defp brs_wave_close(state, p) do
    with :ok <- ensure_active(state),
         :ok <- Contracts.require_fields(p, ["wave_id"]),
         {:ok, wave} <- fetch_wave(state, p["wave_id"]),
         :ok <- ensure_wave_open(wave),
         {:ok, attempts} <- wave_attempts(state, wave) do
      if Map.get(p, "abort", false) do
        abort_wave(state, wave, Map.get(p, "reason"))
      else
        case wave_blocker(wave, attempts) do
          nil -> publish_wave(state, wave, attempts)
          blocker -> block_wave(state, wave, blocker)
        end
      end
    end
  end

  defp fetch_wave(state, wave_id) do
    case Map.fetch(state["brs_waves"], wave_id) do
      {:ok, wave} -> {:ok, wave}
      :error -> {:error, {:unknown_wave, wave_id}}
    end
  end

  defp ensure_wave_open(%{"status" => "open"}), do: :ok
  defp ensure_wave_open(%{"status" => status}), do: {:error, {:wave_not_open, status}}

  defp wave_attempts(state, wave) do
    attempts = Enum.map(wave["attempt_ids"], &Map.fetch!(state["attempts"], &1))
    {:ok, attempts}
  end

  defp wave_blocker(_wave, attempts) do
    cond do
      attempts == [] ->
        "wave has no attempts"

      blocker = Enum.find(attempts, &(&1["execution_status"] != "terminal")) ->
        "attempt #{blocker["id"]} not terminal"

      blocker = Enum.find(attempts, &(&1["verdict"] not in ["pass", "fail"])) ->
        "attempt #{blocker["id"]} verdict=#{blocker["verdict"]} (unknown/infra_error/missing blocks publication)"

      true ->
        nil
    end
  end

  defp block_wave(state, wave, reason) do
    wave = %{wave | "status" => "blocked", "blocked_reason" => reason}
    next = state |> put_in(["brs_waves", wave["id"]], wave) |> bump()
    {:ok, next, [%{"kind" => "wave_blocked", "wave_id" => wave["id"], "reason" => reason}]}
  end

  defp abort_wave(state, wave, reason) do
    # An aborted wave retains all evidence and publishes no subset (§7).
    wave = %{wave | "status" => "aborted", "blocked_reason" => reason}
    next = state |> put_in(["brs_waves", wave["id"]], wave) |> bump()
    {:ok, next, [%{"kind" => "wave_aborted", "wave_id" => wave["id"], "reason" => reason}]}
  end

  defp publish_wave(state, wave, attempts) do
    admissible =
      attempts
      |> Enum.filter(&(&1["admission"] == "candidate"))
      |> Enum.sort_by(fn a ->
        Enum.find_index(wave["branch_order"], &(&1 == a["id"])) || length(wave["branch_order"])
      end)

    {accepted, conflicts} = split_conflicts(admissible)

    if accepted == [] do
      # Nothing admissible: record no_change instead of publishing (§7).
      wave = %{wave | "status" => "closed"}
      next = state |> put_in(["brs_waves", wave["id"]], wave) |> bump()

      {:ok, next,
       [
         %{"kind" => "wave_closed", "wave_id" => wave["id"], "result" => "no_change"},
         conflict_effect(conflicts)
       ]}
    else
      {next, manifest} = consolidate_wave(state, wave, accepted)
      wave = %{wave | "status" => "closed"}
      next = next |> put_in(["brs_waves", wave["id"]], wave) |> bump()

      {:ok, next,
       [
         %{"kind" => "wave_closed", "wave_id" => wave["id"], "result" => "published"},
         %{
           "kind" => "head_advanced",
           "from" => manifest["parent_id"],
           "to" => manifest["id"],
           "manifest_hash" => manifest["manifest_hash"]
         },
         conflict_effect(conflicts)
       ]}
    end
  end

  # Lessons whose claims conflict (same claim text with differing scope, or
  # vice versa) remain unresolved: both are excluded from actionable
  # guidance, never majority-voted (§7).
  defp split_conflicts(admissible) do
    groups = Enum.group_by(admissible, fn a -> a["lesson"]["claim"] end)

    Enum.reduce(groups, {[], []}, fn
      {_claim, [single]}, {acc, conflicts} ->
        # Same claim must also agree on scope to be unambiguous.
        case Enum.split_with(admissible, fn a ->
               a["lesson"]["scope"] == single["lesson"]["scope"] and a["lesson"]["claim"] == single["lesson"]["claim"]
             end) do
          {same, _other} when length(same) > 1 -> {acc ++ same, conflicts}
          _ -> {acc ++ [single], conflicts}
        end

      {_claim, several}, {acc, conflicts} ->
        scopes = several |> Enum.map(& &1["lesson"]["scope"]) |> Enum.uniq()

        if length(scopes) == 1 do
          {acc ++ several, conflicts}
        else
          {acc, conflicts ++ Enum.map(several, & &1["id"])}
        end
    end)
    |> then(fn {acc, conflicts} -> {Enum.uniq_by(acc, & &1["id"]), Enum.uniq(conflicts)} end)
  end

  defp conflict_effect([]), do: %{"kind" => "conflicts_excluded", "attempt_ids" => []}
  defp conflict_effect(ids), do: %{"kind" => "conflicts_excluded", "attempt_ids" => ids}

  defp consolidate_wave(state, wave, accepted) do
    parent_id = state["learning_head"]
    parent = Map.fetch!(state["memories"], parent_id)

    entries =
      Enum.map(accepted, fn a ->
        %{
          "experience_id" => "xp-" <> a["id"],
          "attempt_id" => a["id"],
          "lesson" => a["lesson"],
          "wave_id" => wave["id"]
        }
      end)

    entry_hashes = Enum.map(entries, &Store.hash/1)
    seed = Store.hash(%{"parent" => parent_id, "wave" => wave["id"], "entries" => entry_hashes})

    manifest = %{
      "id" => "mem-" <> seed,
      "parent_id" => parent_id,
      "ordered_experience_ids" => parent["ordered_experience_ids"] ++ Enum.map(entries, & &1["experience_id"]),
      "entry_hashes" => parent["entry_hashes"] ++ entry_hashes,
      "manifest_hash" => nil,
      "schema_version" => Contracts.schema_version()
    }

    manifest = Map.put(manifest, "manifest_hash", Store.hash(manifest))

    admitted_ids = Enum.map(accepted, & &1["id"])

    attempts =
      Enum.reduce(admitted_ids, state["attempts"], fn id, acc ->
        put_in(acc, [id, "admission"], "admitted")
      end)

    next =
      state
      |> Map.put("attempts", attempts)
      |> put_in(["memories", manifest["id"]], manifest)
      |> Map.put("learning_head", manifest["id"])

    {next, manifest}
  end

  # ── cancellation and stopping ──

  # Cancellation is explicit (§8): a non-terminal attempt becomes
  # terminal+cancelled, its verdict is locked to unknown, and its budget
  # reservation (including any retained ambiguous-call reservation) is
  # released. Already-terminal attempts are left untouched.
  defp cancel(state, p) do
    with :ok <- Contracts.require_fields(p, ["attempt_id"]),
         {:ok, attempt} <- fetch_attempt(state, p["attempt_id"]) do
      if attempt["execution_status"] == "terminal" do
        {:error, {:already_terminal, attempt["id"]}}
      else
        released = attempt["reserved"]

        attempt =
          attempt
          |> Map.put("execution_status", "terminal")
          |> Map.put("execution_reason", "cancelled")
          |> Map.put("verdict", "unknown")
          |> Map.put("status_reason", Map.get(p, "reason"))
          |> Map.put("reserved", Map.new(@zero_budget, fn {k, _} -> {k, 0} end))
          |> Map.put("ambiguous_calls", [])

        next =
          state
          |> put_in(["attempts", attempt["id"]], attempt)
          |> update_in(["budget", "reserved"], &subtract_budget(&1, released))
          |> bump()

        {:ok, next,
         [%{"kind" => "attempt_cancelled", "attempt_id" => attempt["id"], "reservation_released" => released}]}
      end
    end
  end

  # Stop learning and freeze Mn for the precommitted held-out comparison
  # (§6 step 9). Frozen state refuses further starts and admissions; costs,
  # reconciliation, and evaluation recording remain possible.
  defp stop_learning(state, p) do
    with :ok <- ensure_active(state),
         :ok <- Contracts.require_fields(p, ["reason"]),
         :ok <- Contracts.validate_enum(p["reason"], Contracts.stop_reasons(), "payload.reason") do
      next =
        state
        |> Map.put("status", "stopped")
        |> Map.put("stop_reason", p["reason"])
        |> bump()

      {:ok, next,
       [
         %{"kind" => "learning_stopped", "reason" => p["reason"]},
         %{"kind" => "head_frozen", "memory_id" => next["learning_head"]}
       ]}
    end
  end

  # ── shared helpers ──

  defp fetch_attempt(state, attempt_id) do
    case Map.fetch(state["attempts"], attempt_id || "") do
      {:ok, attempt} -> {:ok, attempt}
      :error -> {:error, {:unknown_attempt, attempt_id}}
    end
  end

  defp optional_hash_list(p, field) do
    case Map.get(p, field) do
      nil ->
        {:ok, []}

      values when is_list(values) ->
        case Contracts.require_hash_list(values, "payload.#{field}") do
          :ok -> {:ok, values}
          {:error, reason} -> {:error, reason}
        end

      _ ->
        {:error, {:invalid_field, "payload.#{field}", "expected a list of hashes"}}
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
