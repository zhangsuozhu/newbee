defmodule Newbee.Learning.StateStoreTest do
  use ExUnit.Case, async: true

  alias Newbee.Learning.{State, Store}

  @moduletag :learning

  defp tmp_root(test_name) do
    root = Path.join(System.tmp_dir!(), "newbee-learning-store-#{test_name}-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(root) end)
    root
  end

  defp sha256_of(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

  # ── Store ──

  describe "Store content addressing" do
    test "hash is canonical: key order and nesting do not change the address" do
      a = %{"b" => 1, "a" => %{"y" => [1, 2], "x" => "text"}}
      b = %{"a" => %{"x" => "text", "y" => [1, 2]}, "b" => 1}

      assert Store.hash(a) == Store.hash(b)
      assert Store.hash(a) =~ ~r/\A[0-9a-f]{64}\z/
      assert Store.canonical(a) == Store.canonical(b)
    end

    test "hash normalizes text to NFC" do
      nfc = %{"k" => "\u00e9"}
      nfd = %{"k" => "\u0065\u0301"}

      assert nfc["k"] != nfd["k"]
      assert Store.hash(nfc) == Store.hash(nfd)
    end

    test "hash matches the raw sha256 of the canonical encoding" do
      value = %{"a" => [1, "two", 3.5], "b" => %{"c" => nil}}
      assert Store.hash(value) == sha256_of(Store.canonical(value))
    end

    test "non-JSON-safe values cannot be hashed" do
      assert_raise ArgumentError, fn -> Store.hash(%{"a" => {:tuple, 1}}) end
      assert_raise ArgumentError, fn -> Store.hash(%{a: 1}) end
    end
  end

  describe "Store put/get" do
    test "put then get round-trips the value" do
      root = tmp_root("roundtrip")
      value = %{"lesson" => "retry with smaller scope", "n" => 3, "tags" => ["a", "b"]}

      assert {:ok, sha} = Store.put(root, value)
      assert {:ok, ^value} = Store.get(root, sha)
    end

    test "put is idempotent and content is immutable" do
      root = tmp_root("immutable")
      value = %{"v" => 1}

      assert {:ok, sha} = Store.put(root, value)
      assert {:ok, ^sha} = Store.put(root, value)
      assert {:ok, ^sha} = Store.put(root, %{"v" => 1})

      object = Path.join([root, "objects", String.slice(sha, 0, 2), String.slice(sha, 2, 62)])
      assert File.read!(object) == Store.canonical(value)

      # direct overwrite on disk simulates tampering, not Store API
      File.write!(object, "tampered")
      assert {:error, {:corrupt, ^sha}} = Store.get(root, sha)
    end

    test "corrupted bytes fail instead of returning data" do
      root = tmp_root("corrupt")
      assert {:ok, sha} = Store.put(root, %{"data" => "important"})

      object = Path.join([root, "objects", String.slice(sha, 0, 2), String.slice(sha, 2, 62)])
      File.write!(object, "garbage-bytes")

      assert {:error, {:corrupt, ^sha}} = Store.get(root, sha)
      assert {:error, {:corrupt, ^sha}} = Store.verify(root, sha)
    end

    test "get of a missing object reports not_found" do
      root = tmp_root("missing")
      sha = String.duplicate("a", 64)
      assert {:error, :not_found} = Store.get(root, sha)
      refute Store.exists?(root, sha)
    end

    test "invalid sha is rejected before touching the filesystem" do
      root = tmp_root("invalidsha")
      assert {:error, {:invalid_sha, _}} = Store.get(root, "../../etc/passwd")
      assert {:error, {:invalid_sha, _}} = Store.get(root, "ZZZZ")
      refute Store.exists?(root, "not-a-sha")
    end

    test "root is scoped: objects never land outside the root" do
      parent = tmp_root("scoped")
      root = Path.join(parent, "store")

      assert {:ok, sha} = Store.put(root, %{"x" => 1})
      assert Store.exists?(root, sha)

      # nothing outside the store root
      assert File.ls!(parent) == ["store"]
    end

    test "orphan tmp files are cleaned on the next put" do
      root = tmp_root("orphan")
      tmp_dir = Path.join(root, "tmp")

      assert {:ok, _sha} = Store.put(root, %{"first" => true})
      File.write!(Path.join(tmp_dir, "put-crashed"), "partial")
      assert File.ls!(tmp_dir) == ["put-crashed"]

      assert {:ok, _sha} = Store.put(root, %{"second" => true})
      assert File.ls!(tmp_dir) == []
    end

    test "put rejects non-JSON-safe values without creating objects" do
      root = tmp_root("reject")
      assert {:error, {:invalid_value, _}} = Store.put(root, %{"pid" => self()})
      refute File.exists?(Path.join(root, "objects"))
    end
  end

  # ── State construction ──

  defp baseline do
    %{
      "id" => "base-1",
      "project_id" => "proj-1",
      "source_tree_hash" => String.duplicate("1", 64),
      "dependencies_hash" => String.duplicate("2", 64),
      "release_map" => %{"tool.demo" => "rel-1"},
      "memory_m0" => "mem-m0",
      "model_config_hash" => String.duplicate("3", 64),
      "policy_hash" => String.duplicate("4", 64),
      "fixture_version" => "fx-1"
    }
  end

  defp new_state(extra \\ %{}) do
    spec = Map.merge(%{"baseline" => baseline()}, extra)
    {:ok, state} = State.new(spec)
    state
  end

  defp budgeted_state do
    new_state(%{"budget" => %{"total" => %{"calls" => 4, "tokens" => 10_000, "eval_reserve" => 2}}})
  end

  defp cmd(state, id, type, payload) do
    %{"id" => id, "type" => type, "expected_revision" => state["revision"], "payload" => payload}
  end

  defp apply!(state, id, type, payload) do
    assert {:ok, next, receipt} = State.apply(state, cmd(state, id, type, payload))
    assert receipt["command_id"] == id
    assert receipt["command_type"] == type
    assert receipt["revision"] == next["revision"]
    {next, receipt}
  end

  defp start_attempt!(state, id, attempt_id, extra \\ %{}) do
    payload =
      Map.merge(
        %{
          "attempt_id" => attempt_id,
          "input_memory_id" => state["learning_head"],
          "contract_hash" => "contract-v1"
        },
        extra
      )

    {next, receipt} = apply!(state, id, "start_attempt", payload)
    {next, receipt, next["attempts"][attempt_id]}
  end

  defp finish_pass!(state, id, attempt_id) do
    {state, _} = apply!(state, id <> ":run", "record_execution", %{"attempt_id" => attempt_id, "execution_status" => "running"})
    {state, _} = apply!(state, id <> ":sub", "record_execution", %{"attempt_id" => attempt_id, "execution_status" => "submitted"})

    {state, _} =
      apply!(state, id <> ":term", "record_execution", %{
        "attempt_id" => attempt_id,
        "execution_status" => "terminal",
        "execution_reason" => "completed"
      })

    apply!(state, id <> ":fin", "finish_attempt", %{"attempt_id" => attempt_id, "verdict" => "pass"})
  end

  defp lesson(overrides \\ %{}) do
    Map.merge(
      %{
        "claim" => "smaller scopes reduce tool errors",
        "scope" => "elixir-fixtures",
        "preconditions" => ["fixture uses mix test"],
        "counterexample" => "does not apply to multi-app umbrellas",
        "uncertainties" => ["single fixture family"],
        "evidence_hashes" => [String.duplicate("5", 64)]
      },
      overrides
    )
  end

  describe "State.new/1" do
    test "builds revision-0 state with learning_head at M0" do
      state = new_state()

      assert state["revision"] == 0
      assert state["schema_version"] == 1
      assert state["status"] == "active"
      assert state["learning_head"] == "mem-m0"
      assert state["memories"]["mem-m0"]["parent_id"] == nil
      assert state["attempts"] == %{}
    end

    test "rejects invalid baseline specs" do
      assert {:error, {:missing_field, "id"}} = State.new(%{"baseline" => Map.delete(baseline(), "id")})
      assert {:error, {:invalid_spec, _}} = State.new("nope")

      assert {:error, {:invalid_field, "baseline.memory_m0", _}} =
               State.new(%{"baseline" => %{baseline() | "memory_m0" => "bad id!"}})
    end

    test "rejects invalid budget totals" do
      spec = %{"baseline" => baseline(), "budget" => %{"total" => %{"calls" => -1}}}
      assert {:error, {:invalid_field, "budget.total.calls", _}} = State.new(spec)
    end
  end

  describe "command envelope and CAS" do
    test "expected_revision mismatch is a revision conflict" do
      state = new_state()
      command = %{"id" => "c1", "type" => "stop_learning", "expected_revision" => 5, "payload" => %{"reason" => "stalled"}}
      assert {:error, :revision_conflict} = State.apply(state, command)
    end

    test "unknown command types and malformed envelopes are rejected" do
      state = new_state()

      assert {:error, {:invalid_field, "command.type", _}} =
               State.apply(state, %{"id" => "c1", "type" => "forge_admission", "expected_revision" => 0, "payload" => %{}})

      assert {:error, {:missing_field, "payload"}} =
               State.apply(state, %{"id" => "c1", "type" => "stop_learning", "expected_revision" => 0})
    end

    test "same command id + same payload replays the original receipt without re-applying" do
      state = new_state()
      {next, receipt} = apply!(state, "c1", "stop_learning", %{"reason" => "saturated"})

      assert {:ok, replayed_state, replayed} = State.apply(next, cmd(next, "c1", "stop_learning", %{"reason" => "saturated"}))
      assert replayed == receipt
      assert replayed_state == next
      assert replayed_state["revision"] == 1
    end

    test "same command id + different payload is rejected" do
      state = new_state()
      {next, _} = apply!(state, "c1", "stop_learning", %{"reason" => "saturated"})

      assert {:error, :command_payload_mismatch} =
               State.apply(next, cmd(next, "c1", "stop_learning", %{"reason" => "stalled"}))
    end

    test "wire duality: decimal text expected_revision is normalized to a number" do
      state = new_state()
      command = %{"id" => "c1", "type" => "stop_learning", "expected_revision" => "0", "payload" => %{"reason" => "stalled"}}
      assert {:ok, next, _} = State.apply(state, command)
      assert next["revision"] == 1
    end
  end
  # ── attempt lifecycle: execution, verdict, admission are separate ──

  describe "attempt lifecycle" do
    test "start_attempt queues with separate pending fields" do
      state = new_state()
      {state, _receipt, attempt} = start_attempt!(state, "s1", "att-1")

      assert attempt["execution_status"] == "queued"
      assert attempt["verdict"] == "pending"
      assert attempt["admission"] == "not_proposed"
      assert attempt["input_memory_id"] == "mem-m0"
      assert state["revision"] == 1
    end

    test "duplicate attempt ids are rejected" do
      state = new_state()
      {state, _, _} = start_attempt!(state, "s1", "att-1")

      assert {:error, :attempt_exists} =
               State.apply(state, cmd(state, "s2", "start_attempt", %{
                 "attempt_id" => "att-1",
                 "input_memory_id" => "mem-m0",
                 "contract_hash" => "c"
               }))
    end

    test "attempts can only start from a known admitted memory" do
      state = new_state()

      assert {:error, {:unknown_memory, "mem-nope"}} =
               State.apply(state, cmd(state, "s1", "start_attempt", %{
                 "attempt_id" => "att-1",
                 "input_memory_id" => "mem-nope",
                 "contract_hash" => "c"
               }))
    end

    test "execution transitions are monotone; terminal requires a reason" do
      state = new_state()
      {state, _, _} = start_attempt!(state, "s1", "att-1")

      assert {:error, {:invalid_field, "payload.execution_reason", _}} =
               State.apply(state, cmd(state, "e1", "record_execution", %{"attempt_id" => att_id = "att-1", "execution_status" => "terminal"}))

      assert {:error, {:invalid_execution_transition, "queued", "queued"}} =
               State.apply(state, cmd(state, "e2", "record_execution", %{"attempt_id" => att_id, "execution_status" => "queued"}))

      {state, _} = apply!(state, "e3", "record_execution", %{"attempt_id" => att_id, "execution_status" => "running"})

      assert {:error, {:invalid_execution_transition, "running", "queued"}} =
               State.apply(state, cmd(state, "e4", "record_execution", %{"attempt_id" => att_id, "execution_status" => "queued"}))
    end

    test "verdict requires terminal+completed and is recorded once" do
      state = new_state()
      {state, _, _} = start_attempt!(state, "s1", "att-1")

      assert {:error, {:not_terminal, "att-1"}} =
               State.apply(state, cmd(state, "f0", "finish_attempt", %{"attempt_id" => "att-1", "verdict" => "pass"}))

      {state, _} = finish_pass!(state, "f", "att-1")
      assert state["attempts"]["att-1"]["verdict"] == "pass"

      assert {:error, {:verdict_locked, _}} =
               State.apply(state, cmd(state, "f9", "finish_attempt", %{"attempt_id" => "att-1", "verdict" => "fail"}))
    end

    test "infra_error terminal keeps verdict unknown and can never admit" do
      state = new_state()
      {state, _, _} = start_attempt!(state, "s1", "att-1")

      {state, _} =
        apply!(state, "e1", "record_execution", %{
          "attempt_id" => "att-1",
          "execution_status" => "terminal",
          "execution_reason" => "infra_error"
        })

      attempt = state["attempts"]["att-1"]
      assert attempt["verdict"] == "unknown"

      assert {:error, {:verdict_locked, _}} =
               State.apply(state, cmd(state, "f1", "finish_attempt", %{"attempt_id" => "att-1", "verdict" => "pass"}))

      assert {:error, {:not_proposable, _}} =
               State.apply(state, cmd(state, "p1", "propose_lesson", %{"attempt_id" => "att-1", "lesson" => lesson()}))
    end

    test "budget_exhausted never upgrades unknown to pass" do
      state = new_state()
      {state, _, _} = start_attempt!(state, "s1", "att-1")

      {state, _} =
        apply!(state, "e1", "record_execution", %{
          "attempt_id" => "att-1",
          "execution_status" => "terminal",
          "execution_reason" => "budget_exhausted"
        })

      assert state["attempts"]["att-1"]["verdict"] == "unknown"

      assert {:error, {:verdict_locked, _}} =
               State.apply(state, cmd(state, "f1", "finish_attempt", %{"attempt_id" => "att-1", "verdict" => "pass"}))
    end
  end

  describe "admission" do
    test "pass attempt admits a positive lesson and advances learning_head" do
      state = new_state()
      {state, _, _} = start_attempt!(state, "s1", "att-1")
      {state, _} = finish_pass!(state, "f", "att-1")

      lesson = lesson()
      {state, _} = apply!(state, "p1", "propose_lesson", %{"attempt_id" => "att-1", "lesson" => lesson})
      assert state["attempts"]["att-1"]["admission"] == "candidate"

      {state, receipt} = apply!(state, "a1", "admit", %{"attempt_id" => "att-1", "lesson" => lesson})

      new_head = state["learning_head"]
      assert new_head != "mem-m0"
      assert state["memories"][new_head]["parent_id"] == "mem-m0"
      assert state["memories"][new_head]["ordered_experience_ids"] == ["xp-att-1"]
      assert state["memories"][new_head]["manifest_hash"] =~ ~r/\A[0-9a-f]{64}\z/
      assert state["attempts"]["att-1"]["admission"] == "admitted"

      effect = Enum.find(receipt["effects"], &(&1["kind"] == "head_advanced"))
      assert effect["from"] == "mem-m0"
      assert effect["to"] == new_head

    end

    test "admit requires the exact proposed lesson (no forged swap)" do
      state = new_state()
      {state, _, _} = start_attempt!(state, "s1", "att-1")
      {state, _} = finish_pass!(state, "f", "att-1")
      {state, _} = apply!(state, "p1", "propose_lesson", %{"attempt_id" => "att-1", "lesson" => lesson()})

      forged = lesson(%{"claim" => "unverified universal rule"})

      assert {:error, {:lesson_mismatch, _}} =
               State.apply(state, cmd(state, "a1", "admit", %{"attempt_id" => "att-1", "lesson" => forged}))
    end

    test "verified fail can admit a negative lesson without becoming a pass" do
      state = new_state()
      {state, _, _} = start_attempt!(state, "s1", "att-1")
      {state, _} = apply!(state, "e1", "record_execution", %{"attempt_id" => "att-1", "execution_status" => "running"})

      {state, _} =
        apply!(state, "e2", "record_execution", %{
          "attempt_id" => "att-1",
          "execution_status" => "terminal",
          "execution_reason" => "completed"
        })

      {state, _} = apply!(state, "f1", "finish_attempt", %{"attempt_id" => "att-1", "verdict" => "fail"})

      negative = lesson(%{"claim" => "broad sed edits break fixtures"})

      {state, _} = apply!(state, "p1", "propose_lesson", %{"attempt_id" => "att-1", "lesson" => negative})
      {state, _} = apply!(state, "a1", "admit", %{"attempt_id" => "att-1", "lesson" => negative})

      attempt = state["attempts"]["att-1"]
      # design §13.2: terminal + completed + fail + admitted = negative lesson
      assert attempt["execution_status"] == "terminal"
      assert attempt["verdict"] == "fail"
      assert attempt["admission"] == "admitted"
      assert state["learning_head"] != "mem-m0"
    end

    test "lesson without scope/preconditions/counterexample cannot be admitted" do
      state = new_state()
      {state, _, _} = start_attempt!(state, "s1", "att-1")
      {state, _} = finish_pass!(state, "f", "att-1")

      thin = Map.delete(lesson(), "counterexample")

      assert {:error, {:missing_field, "counterexample"}} =
               State.apply(state, cmd(state, "p1", "propose_lesson", %{"attempt_id" => "att-1", "lesson" => thin}))

      assert state["attempts"]["att-1"]["admission"] == "not_proposed"
      assert state["learning_head"] == "mem-m0"
    end

    test "stale attempt cannot admit after the head advanced" do
      state = new_state()
      {state, _, _} = start_attempt!(state, "s1", "att-1")
      {state, _, _} = start_attempt!(state, "s2", "att-2")
      {state, _} = finish_pass!(state, "f1", "att-1")
      {state, _} = apply!(state, "p1", "propose_lesson", %{"attempt_id" => "att-1", "lesson" => lesson()})
      {state, _} = apply!(state, "a1", "admit", %{"attempt_id" => "att-1", "lesson" => lesson()})

      # att-2 was dispatched with M0 but the head is now Mn+1.
      {state, _} = finish_pass!(state, "f2", "att-2")
      {state, _} = apply!(state, "p2", "propose_lesson", %{"attempt_id" => "att-2", "lesson" => lesson(%{"claim" => "second lesson"})})

      assert {:error, :stale_attempt} =
               State.apply(state, cmd(state, "a2", "admit", %{"attempt_id" => "att-2", "lesson" => lesson(%{"claim" => "second lesson"})}))

      assert state["attempts"]["att-2"]["admission"] == "candidate"
    end

    test "quarantined attempts cannot advance memory" do
      state = new_state()
      {state, _, _} = start_attempt!(state, "s1", "att-1")
      {state, _} = finish_pass!(state, "f", "att-1")
      {state, _} = apply!(state, "p1", "propose_lesson", %{"attempt_id" => "att-1", "lesson" => lesson()})
      {state, _} = apply!(state, "q1", "quarantine_attempt", %{"attempt_id" => "att-1", "reason" => "hash mismatch"})

      assert state["attempts"]["att-1"]["admission"] == "quarantined"

      assert {:error, {:invalid_admission_state, "quarantined"}} =
               State.apply(state, cmd(state, "a1", "admit", %{"attempt_id" => "att-1", "lesson" => lesson()}))

      assert state["learning_head"] == "mem-m0"
    end

    test "reject_lesson keeps the head; re-proposal is allowed" do
      state = new_state()
      {state, _, _} = start_attempt!(state, "s1", "att-1")
      {state, _} = finish_pass!(state, "f", "att-1")
      {state, _} = apply!(state, "p1", "propose_lesson", %{"attempt_id" => "att-1", "lesson" => lesson()})
      {state, _} = apply!(state, "r1", "reject_lesson", %{"attempt_id" => "att-1", "reason" => "insufficient evidence"})

      assert state["attempts"]["att-1"]["admission"] == "rejected"
      assert state["learning_head"] == "mem-m0"

      {state, _} = apply!(state, "p2", "propose_lesson", %{"attempt_id" => "att-1", "lesson" => lesson()})
      assert state["attempts"]["att-1"]["admission"] == "candidate"
    end
  end

  describe "budgets" do
    test "reserve is capped by total minus reserved" do
      state = budgeted_state()
      {state, receipt, _} = start_attempt!(state, "s1", "att-1", %{"reserve" => %{"calls" => 3}})
      assert Enum.any?(receipt["effects"], &(&1["kind"] == "budget_reserved" and &1["attempt_id"] == "att-1"))
      assert state["budget"]["reserved"]["calls"] == 3

      assert {:error, {:budget_exhausted, "calls"}} =
               State.apply(state, cmd(state, "s2", "start_attempt", %{
                 "attempt_id" => "att-2",
                 "input_memory_id" => "mem-m0",
                 "contract_hash" => "c",
                 "reserve" => %{"calls" => 2}
               }))
    end

    test "practice may not consume the evaluation reserve" do
      state = budgeted_state()

      assert {:error, {:budget_exhausted, "eval_reserve"}} =
               State.apply(state, cmd(state, "s1", "start_attempt", %{
                 "attempt_id" => "att-1",
                 "input_memory_id" => "mem-m0",
                 "contract_hash" => "c",
                 "reserve" => %{"eval_reserve" => 1}
               }))
    end

    test "reconcile releases the reservation and settles actual cost" do
      state = budgeted_state()
      {state, _, _} = start_attempt!(state, "s1", "att-1", %{"reserve" => %{"calls" => 2, "tokens" => 500}})
      {state, _, attempt} = finish_pass_with_state(state, "f", "att-1")
      assert attempt["reserved"]["calls"] == 2

      {state, receipt} = apply!(state, "rec1", "reconcile_budget", %{"attempt_id" => "att-1", "cost" => %{"calls" => 1, "tokens" => 480}})

      assert state["budget"]["reserved"]["calls"] == 0
      assert state["budget"]["spent"]["calls"] == 1
      assert state["budget"]["spent"]["tokens"] == 480
      assert state["attempts"]["att-1"]["reserved"]["calls"] == 0
      assert Enum.any?(receipt["effects"], &(&1["kind"] == "budget_reconciled" and &1["attempt_id"] == "att-1"))
    end

    test "ambiguous calls retain the reservation until explicit release" do
      state = budgeted_state()
      {state, _, _} = start_attempt!(state, "s1", "att-1", %{"reserve" => %{"calls" => 2}})

      {state, receipt} =
        apply!(state, "amb1", "record_ambiguous_call", %{"attempt_id" => "att-1", "kind" => "host_crash_after_model_call"})

      assert Enum.any?(receipt["effects"], &(&1["kind"] == "ambiguous_call_recorded" and &1["reservation"] == "retained"))

      {state, _, _} = finish_pass_with_state(state, "f", "att-1")

      # reconcile without release is refused while ambiguity is pending
      assert {:error, {:ambiguous_calls_pending, _}} =
               State.apply(state, cmd(state, "rec1", "reconcile_budget", %{"attempt_id" => "att-1", "cost" => %{"calls" => 1}}))

      {state, _} =
        apply!(state, "rec2", "reconcile_budget", %{
          "attempt_id" => "att-1",
          "cost" => %{"calls" => 1},
          "release_ambiguous" => true
        })

      assert state["budget"]["reserved"]["calls"] == 0
      assert state["attempts"]["att-1"]["ambiguous_calls"] == []
    end

    test "record_cost counts every role and retry cost, marked estimated honestly" do
      state = budgeted_state()
      {state, _, _} = start_attempt!(state, "s1", "att-1", %{"reserve" => %{"calls" => 2}})
      {state, _, _} = finish_pass_with_state(state, "f", "att-1")

      {state, _} = apply!(state, "c1", "record_cost", %{"attempt_id" => "att-1", "cost" => %{"calls" => 1, "tokens" => 200}})
      {state, _} = apply!(state, "c2", "record_cost", %{"attempt_id" => "att-1", "cost" => %{"tokens" => 50}, "estimated" => true})

      attempt = state["attempts"]["att-1"]
      assert attempt["cost"]["calls"] == 1
      assert attempt["cost"]["tokens"] == 250
      assert attempt["cost_estimated"] == true
      assert state["budget"]["spent"]["tokens"] == 250
    end

    test "costs are only recorded for terminal attempts" do
      state = budgeted_state()
      {state, _, _} = start_attempt!(state, "s1", "att-1", %{"reserve" => %{"calls" => 1}})

      assert {:error, {:not_terminal, "att-1"}} =
               State.apply(state, cmd(state, "c1", "record_cost", %{"attempt_id" => "att-1", "cost" => %{"calls" => 1}}))
    end

    test "cancel releases the reservation and locks verdict to unknown" do
      state = budgeted_state()
      {state, _, _} = start_attempt!(state, "s1", "att-1", %{"reserve" => %{"calls" => 2}})
      assert state["budget"]["reserved"]["calls"] == 2

      {state, receipt} = apply!(state, "x1", "cancel", %{"attempt_id" => "att-1", "reason" => "host hard limit"})

      attempt = state["attempts"]["att-1"]
      assert attempt["execution_status"] == "terminal"
      assert attempt["execution_reason"] == "cancelled"
      assert attempt["verdict"] == "unknown"
      assert state["budget"]["reserved"]["calls"] == 0
      assert Enum.any?(receipt["effects"], &(&1["kind"] == "attempt_cancelled" and &1["reservation_released"] == %{"calls" => 2}))

      assert {:error, {:already_terminal, "att-1"}} =
               State.apply(state, cmd(state, "x2", "cancel", %{"attempt_id" => "att-1"}))
    end
  end

  # finish_pass! plus returning the attempt
  defp finish_pass_with_state(state, id, attempt_id) do
    {state, receipt} = finish_pass!(state, id, attempt_id)
    {state, receipt, state["attempts"][attempt_id]}
  end
end