defmodule Newbee.Learning.Contracts do
  @moduledoc """
  BRS/DRS v2 contracts (docs/brs-drs-design.md §5/§8/§10/§12).

  Shared constants, wire normalization, and validators for the pure
  learning-state reducer (`Newbee.Learning.State`) and the durable artifact
  store (`Newbee.Learning.Store`). All data here is string-keyed and
  JSON-safe; this module starts no process and holds no state.

  Event authority remains with `Newbee.Environment.Coordinator` (owned by
  the Lead): the reducer only validates commands and computes transitions;
  `memory_committed` appended by the Coordinator is the sole durable commit
  point. Same `command_id` + same payload replays the original receipt;
  same id with a different payload is rejected.

  Numeric fields that may arrive on the wire either as JSON numbers or as
  decimal text (`expected_revision`, budget amounts) are accepted as a union
  at this boundary and unified to canonical numbers by
  `normalize_command/1` before validation.
  """

  @schema_version 1

  @command_types ~w(
    start_attempt record_execution finish_attempt propose_lesson admit
    reject_lesson quarantine_attempt record_cost reconcile_budget
    record_ambiguous_call record_evaluation brs_wave_open brs_wave_close
    cancel stop_learning
  )

  @execution_statuses ~w(queued running submitted terminal)
  @execution_reasons ~w(completed infra_error cancelled budget_exhausted)
  @verdicts ~w(pending pass fail unknown)
  @terminal_verdicts ~w(pass fail unknown)
  @admissions ~w(not_proposed candidate admitted rejected quarantined)

  # queued -> running -> submitted -> terminal (monotone, no skipping back)
  @execution_order %{"queued" => 0, "running" => 1, "submitted" => 2, "terminal" => 3}

  @stop_reasons ~w(target_pass saturated budget_exhausted stalled infra_error)
  @eval_conclusions ~w(improved regressed no_clear_gain invalid)
  @eval_outcomes ~w(pass fail unknown infra_error cancelled missing)

  # Design §12: every role/retry cost counts; unknown billing is not free.
  @budget_dimensions ~w(calls tokens wall_ms disk_bytes eval_reserve)

  @sha256_re ~r/\A[0-9a-f]{64}\z/
  @id_re ~r/\A[A-Za-z0-9][A-Za-z0-9._:-]{0,127}\z/

  @baseline_required ~w(
    id project_id source_tree_hash dependencies_hash release_map
    memory_m0 model_config_hash policy_hash fixture_version
  )

  # ── constants ──

  def schema_version, do: @schema_version
  def command_types, do: @command_types
  def execution_statuses, do: @execution_statuses
  def execution_reasons, do: @execution_reasons
  def verdicts, do: @verdicts
  def terminal_verdicts, do: @terminal_verdicts
  def admissions, do: @admissions
  def stop_reasons, do: @stop_reasons
  def eval_conclusions, do: @eval_conclusions
  def eval_outcomes, do: @eval_outcomes
  def budget_dimensions, do: @budget_dimensions
  def baseline_required_fields, do: @baseline_required

  def sha256_hex?(v), do: is_binary(v) and Regex.match?(@sha256_re, v)
  def id?(v), do: is_binary(v) and Regex.match?(@id_re, v)

  # ── boundary normalization (dual wire forms -> canonical numbers) ──

  @doc """
  Normalize a command map at the API boundary.

  `expected_revision` may arrive as an integer or as decimal text; it is
  unified to a number here so the reducer sees exactly one canonical type.
  Budget maps inside `payload` (`reserve` / `cost` / `total`) get the same
  treatment. Unknown fields and values pass through untouched; validation
  reports them afterwards.
  """
  def normalize_command(command) when is_map(command) do
    command
    |> normalize_field("expected_revision", &normalize_number/1)
    |> normalize_payload_budgets()
  end

  def normalize_command(other), do: other

  @doc "Decimal text is unified to a number; other values pass through."
  def normalize_number(v) when is_binary(v) do
    case Integer.parse(v) do
      {int, ""} ->
        int

      _ ->
        case Float.parse(v) do
          {float, ""} -> float
          _ -> v
        end
    end
  end

  def normalize_number(v), do: v

  @doc "Normalize every value of a budget/cost map."
  def normalize_budget_map(budget) when is_map(budget) do
    Map.new(budget, fn {k, v} -> {k, normalize_number(v)} end)
  end

  def normalize_budget_map(other), do: other

  defp normalize_payload_budgets(%{"payload" => payload} = command) when is_map(payload) do
    payload =
      payload
      |> normalize_field("reserve", &normalize_budget_map/1)
      |> normalize_field("cost", &normalize_budget_map/1)
      |> normalize_field("total", &normalize_budget_map/1)

    %{command | "payload" => payload}
  end

  defp normalize_payload_budgets(command), do: command

  defp normalize_field(map, field, fun) when is_map(map) do
    case Map.fetch(map, field) do
      {:ok, value} -> %{map | field => fun.(value)}
      :error -> map
    end
  end

  # ── generic validators (return :ok | {:error, reason}) ──

  def validate_id(value, field \\ "id") do
    if id?(value), do: :ok, else: {:error, {:invalid_field, field, "expected #{inspect(@id_re)}"}}
  end

  def validate_enum(value, allowed, field) do
    if is_binary(value) and value in allowed do
      :ok
    else
      {:error, {:invalid_field, field, "expected one of #{Enum.join(allowed, "/")}"}}
    end
  end

  def validate_non_neg_number(value, field) do
    if (is_integer(value) or is_float(value)) and value >= 0 do
      :ok
    else
      {:error, {:invalid_field, field, "expected non-negative number"}}
    end
  end

  @doc "Execution status transitions are monotone: queued<running<submitted<terminal."
  def execution_transition_ok?(from, to) do
    with true <- is_binary(from) and is_binary(to),
         %{^from => a} <- @execution_order,
         %{^to => b} <- @execution_order do
      b > a
    else
      _ -> false
    end
  end

  # ── JSON-safety ──

  @doc """
  True when `value` round-trips through Jason: maps keyed by text, lists,
  text values, numbers, booleans, nil. Used by the reducer and the store to
  guarantee every persisted artifact is canonical-encodable.
  """
  def json_safe?(value) when is_map(value) do
    Enum.all?(value, fn {k, v} -> is_binary(k) and json_safe?(v) end)
  end

  def json_safe?(value) when is_list(value), do: Enum.all?(value, &json_safe?/1)
  def json_safe?(value) when is_binary(value), do: String.valid?(value)
  def json_safe?(value) when is_number(value) or is_boolean(value) or is_nil(value), do: true
  def json_safe?(_), do: false

  # ── composite validators ──

  @doc """
  Validate a command envelope: `%{"id","type","expected_revision","payload"}`.
  Unknown command types are rejected (design §8: validate writes and reads;
  model proposals cannot forge admission or verifier results). Call
  `normalize_command/1` first when the command came off the wire.
  """
  def validate_command(command) when is_map(command) do
    with :ok <- require_fields(command, ["id", "type", "expected_revision", "payload"]),
         :ok <- validate_id(command["id"], "command.id"),
         :ok <- validate_enum(command["type"], @command_types, "command.type"),
         :ok <- validate_expected_revision(command["expected_revision"]),
         :ok <- require_map(command["payload"], "command.payload") do
      :ok
    end
  end

  def validate_command(_), do: {:error, {:invalid_command, "expected a map"}}

  defp validate_expected_revision(v) when is_integer(v) and v >= 0, do: :ok

  defp validate_expected_revision(_),
    do: {:error, {:invalid_field, "command.expected_revision", "expected non-negative integer"}}

  @doc """
  Validate an immutable baseline spec (design §5/§8). The baseline pins
  source, dependencies, tools, model and policy configuration and the
  starting memory M0; any change starts a new lineage.
  """
  def validate_baseline(baseline) when is_map(baseline) do
    with :ok <- require_fields(baseline, @baseline_required),
         :ok <- validate_id(baseline["id"], "baseline.id"),
         :ok <- validate_id(baseline["memory_m0"], "baseline.memory_m0"),
         :ok <- require_map(baseline["release_map"], "baseline.release_map"),
         :ok <- require_json_safe(baseline, "baseline") do
      :ok
    end
  end

  def validate_baseline(_), do: {:error, {:invalid_field, "baseline", "expected a map"}}

  @doc """
  Validate a lesson payload (design §6 step 7): admission requires scope,
  preconditions, evidence, and a contrast/boundary example. A positive
  lesson must carry all of them; a negative (verified-fail) lesson must at
  least pin scope, preconditions, and a counterexample.
  """
  def validate_lesson(lesson, kind) when is_map(lesson) and kind in [:positive, :negative] do
    base = ["claim", "scope", "preconditions", "counterexample", "evidence_hashes"]

    with :ok <- require_fields(lesson, base),
         :ok <- require_nonempty_string(lesson["claim"], "lesson.claim"),
         :ok <- require_nonempty_string(lesson["scope"], "lesson.scope"),
         :ok <- require_list(lesson["preconditions"], "lesson.preconditions"),
         :ok <- require_nonempty_string(lesson["counterexample"], "lesson.counterexample"),
         :ok <- require_list(lesson["evidence_hashes"], "lesson.evidence_hashes"),
         :ok <- require_hash_list(lesson["evidence_hashes"], "lesson.evidence_hashes"),
         :ok <- require_json_safe(lesson, "lesson") do
      :ok
    end
  end

  def validate_lesson(_, _), do: {:error, {:invalid_field, "lesson", "expected a map"}}

  @doc """
  Validate a reserve/cost/reconcile budget map: only known dimensions,
  non-negative numbers. `eval_reserve` protects the pre-committed frozen
  comparison budget (§11/§12): practice may not consume it.
  """
  def validate_budget_map(budget, field \\ "budget") do
    with :ok <- require_map(budget, field),
         :ok <-
           Enum.reduce_while(budget, :ok, fn {k, v}, :ok ->
             cond do
               k not in @budget_dimensions ->
                 {:halt, {:error, {:invalid_field, "#{field}.#{k}", "unknown budget dimension"}}}

               not ((is_integer(v) or is_float(v)) and v >= 0) ->
                 {:halt, {:error, {:invalid_field, "#{field}.#{k}", "expected non-negative number"}}}

               true ->
                 {:cont, :ok}
             end
           end) do
      :ok
    end
  end

  # ── helpers ──

  def require_fields(map, fields) do
    case Enum.find(fields, fn f -> not Map.has_key?(map, f) end) do
      nil -> :ok
      missing -> {:error, {:missing_field, missing}}
    end
  end

  def require_map(value, field) do
    if is_map(value), do: :ok, else: {:error, {:invalid_field, field, "expected a map"}}
  end

  def require_list(value, field) do
    if is_list(value), do: :ok, else: {:error, {:invalid_field, field, "expected a list"}}
  end

  def require_nonempty_string(value, field) do
    if is_binary(value) and String.trim(value) != "" do
      :ok
    else
      {:error, {:invalid_field, field, "expected non-empty text"}}
    end
  end

  def require_hash_list(values, field) do
    if Enum.all?(values, &sha256_hex?/1) do
      :ok
    else
      {:error, {:invalid_field, field, "expected a list of lowercase sha256 hex hashes"}}
    end
  end

  def require_json_safe(value, field) do
    if json_safe?(value), do: :ok, else: {:error, {:invalid_field, field, "value is not JSON-safe"}}
  end
end