defmodule Newbee.Collaboration.HiveV2CoordinatorTest do
  use ExUnit.Case, async: false

  alias Newbee.Collaboration.Coordinator

  setup do
    root = Path.join(System.tmp_dir!(), "hive-v2-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    File.write!(Path.join(root, "proof.txt"), "verified")
    path = Path.join(root, "events.jsonl")
    name = String.to_atom("hive_v2_#{System.unique_integer([:positive])}")
    {:ok, pid} = Coordinator.start_link(name: name, path: path, durability: :event)

    {:ok, group} =
      Coordinator.create_group(
        %{
          "session_id" => "lead",
          "title" => "evidence",
          "project_root" => root,
          "max_depth" => 1,
          "max_total" => 4,
          "command_id" => "open"
        },
        name
      )

    {:ok, _} = Coordinator.add_member(group["group_id"], %{"session_id" => "worker"}, name)

    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid)
      File.rm_rf!(root)
    end)

    %{server: name, pid: pid, root: root, path: path, gid: group["group_id"]}
  end

  test "Board mutation requires exact revision and competing writers cannot both commit", ctx do
    {:ok, board} = Coordinator.board(ctx.gid, "lead", ctx.server)
    revision = board["revision"]
    acceptance = [%{"kind" => "file_exists", "path" => "proof.txt"}]

    calls =
      for n <- 1..2 do
        Task.async(fn ->
          Coordinator.board_create_task(
            ctx.gid,
            %{
              "session_id" => "lead",
              "title" => "task-#{n}",
              "acceptance" => acceptance,
              "expected_revision" => revision,
              "command_id" => "race-#{n}"
            },
            ctx.server
          )
        end)
      end

    results = Enum.map(calls, &Task.await(&1, 5_000))
    assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    assert Enum.count(results, &match?({:error, "revision_conflict", _}, &1)) == 1
  end

  test "DAG dependency blocks claim until predecessor is submitted and verified", ctx do
    {:ok, b0} = Coordinator.board(ctx.gid, "lead", ctx.server)

    {:ok, %{"task" => first, "revision" => r1}} =
      create_task(ctx, b0["revision"], "first", [], "worker", ["lib/a"])

    {:ok, %{"task" => second, "revision" => r2}} =
      create_task(ctx, r1, "second", [first["task_id"]], "worker", ["lib/a/file.ex"])

    assert {:error, "dependency_blocked", _} =
             Coordinator.board_claim(
               ctx.gid,
               second["task_id"],
               %{"session_id" => "worker", "expected_revision" => r2, "command_id" => "claim-blocked"},
               ctx.server
             )

    assert {:ok, %{"task" => submitted, "revision" => r3}} =
             Coordinator.board_update_task(
               ctx.gid,
               first["task_id"],
               %{
                 "session_id" => "worker",
                 "expected_revision" => r2,
                 "status" => "submitted",
                 "result" => "proof.txt exists",
                 "command_id" => "submit-first"
               },
               ctx.server
             )

    assert submitted["status"] == "submitted"
    Newbee.Bus.subscribe()

    assert {:ok, %{"task" => verified, "revision" => r4}} =
             Coordinator.board_verify(
               ctx.gid,
               first["task_id"],
               %{
                 "session_id" => "lead",
                 "expected_revision" => r3,
                 "command_id" => "verify-first"
               },
               ctx.server
             )

    assert verified["status"] == "succeeded"

    assert_receive {:newbee_event, :collab_event, %{"payload" => %{"task" => %{"task_id" => first_id}}}},
                   1_000

    assert_receive {:newbee_event, :collab_event, %{"payload" => %{"task" => %{"task_id" => second_id}}}},
                   1_000

    assert first_id == first["task_id"]
    assert second_id == second["task_id"]

    assert {:ok, %{"task" => claimed}} =
             Coordinator.board_claim(
               ctx.gid,
               second["task_id"],
               %{"session_id" => "worker", "expected_revision" => r4, "command_id" => "claim-second"},
               ctx.server
             )

    assert claimed["status"] == "running"
  end

  test "worker cannot self-certify succeeded and stale attestation cannot commit", ctx do
    {:ok, b0} = Coordinator.board(ctx.gid, "lead", ctx.server)
    {:ok, %{"task" => task, "revision" => r1}} = create_task(ctx, b0["revision"], "guard", [], "worker", [])

    assert {:error, "verification_required", _} =
             Coordinator.board_update_task(
               ctx.gid,
               task["task_id"],
               %{
                 "session_id" => "worker",
                 "expected_revision" => r1,
                 "status" => "succeeded",
                 "command_id" => "self-certify"
               },
               ctx.server
             )

    for {name, arities} <- [
          {:create_task, [2, 3]},
          {:update_task, [3, 4]},
          {:claim_task, [3, 4]},
          {:renew_task, [4, 5]}
        ] do
      for arity <- arities do
        refute function_exported?(Coordinator, name, arity)
      end
    end

    assert {:error, "invalid_state", _} =
             Coordinator.board_verify(
               ctx.gid,
               task["task_id"],
               %{
                 "session_id" => "lead",
                 "expected_revision" => r1,
                 "command_id" => "verify-before-submit"
               },
               ctx.server
             )
  end

  test "assigned worker cannot rewrite acceptance, dependencies, or write scope", ctx do
    {:ok, board} = Coordinator.board(ctx.gid, "lead", ctx.server)

    {:ok, %{"task" => task, "revision" => revision}} =
      create_task(ctx, board["revision"], "immutable-contract", [], "worker", ["lib/original"])

    for mutation <- [
          %{"acceptance" => [%{"kind" => "file_exists", "path" => "forged.txt"}]},
          %{"depends_on" => []},
          %{"write_scope" => ["lib/forged"]},
          %{"title" => "rewritten"}
        ] do
      attrs =
        mutation
        |> Map.merge(%{
          "session_id" => "worker",
          "expected_revision" => revision,
          "command_id" => "worker-contract-36162"
        })

      assert {:error, "contract_forbidden", _} =
               Coordinator.board_update_task(ctx.gid, task["task_id"], attrs, ctx.server)
    end

    assert {:ok, %{"revision" => ^revision, "tasks" => [unchanged]}} =
             Coordinator.board(ctx.gid, "lead", ctx.server)

    assert unchanged["title"] == "immutable-contract"
    assert unchanged["write_scope"] == ["lib/original"]
  end

  test "verification refuses to commit when Board changes while checks run", ctx do
    {:ok, board} = Coordinator.board(ctx.gid, "lead", ctx.server)

    {:ok, %{"task" => task, "revision" => r1}} =
      Coordinator.board_create_task(
        ctx.gid,
        %{
          "session_id" => "lead",
          "title" => "slow-check",
          "assigned_session_id" => "worker",
          "acceptance" => [
            %{
              "kind" => "command",
              "program" => "python3",
              "args" => ["-c", "import time; time.sleep(0.3)"],
              "timeout_ms" => 5_000
            }
          ],
          "expected_revision" => board["revision"],
          "command_id" => "slow-create"
        },
        ctx.server
      )

    {:ok, %{"revision" => r2}} =
      Coordinator.board_update_task(
        ctx.gid,
        task["task_id"],
        %{
          "session_id" => "worker",
          "expected_revision" => r1,
          "status" => "submitted",
          "result" => "ready",
          "command_id" => "slow-submit"
        },
        ctx.server
      )

    verification =
      Task.async(fn ->
        Coordinator.board_verify(
          ctx.gid,
          task["task_id"],
          %{"session_id" => "lead", "expected_revision" => r2, "command_id" => "slow-verify"},
          ctx.server
        )
      end)

    Process.sleep(75)
    assert {:ok, _} = create_task(ctx, r2, "concurrent-change", [], nil, [])
    assert {:error, "revision_conflict", _} = Task.await(verification, 6_000)

    {:ok, latest} = Coordinator.board(ctx.gid, "lead", ctx.server)
    unchanged = Enum.find(latest["tasks"], &(&1["task_id"] == task["task_id"]))
    assert unchanged["status"] == "submitted"
  end

  test "caller-supplied attestation cannot forge a passing verification", ctx do
    {:ok, board} = Coordinator.board(ctx.gid, "lead", ctx.server)

    {:ok, %{"task" => task, "revision" => r1}} =
      Coordinator.board_create_task(
        ctx.gid,
        %{
          "session_id" => "lead",
          "title" => "must-not-exist",
          "assigned_session_id" => "worker",
          "acceptance" => [%{"kind" => "file_exists", "path" => "missing-proof.txt"}],
          "expected_revision" => board["revision"],
          "command_id" => "forge-create"
        },
        ctx.server
      )

    {:ok, %{"revision" => r2}} =
      Coordinator.board_update_task(
        ctx.gid,
        task["task_id"],
        %{
          "session_id" => "worker",
          "expected_revision" => r1,
          "status" => "submitted",
          "result" => "claimed pass",
          "command_id" => "forge-submit"
        },
        ctx.server
      )

    forged = %{
      "contract_sha256" => task["acceptance_sha256"],
      "all_passed" => true,
      "results" => [%{"id" => 1, "kind" => "file_exists", "path" => "missing-proof.txt", "passed" => true}]
    }

    assert {:ok, %{"task" => checked}} =
             Coordinator.board_verify(
               ctx.gid,
               task["task_id"],
               %{
                 "session_id" => "lead",
                 "expected_revision" => r2,
                 "attestation" => forged,
                 "command_id" => "forge-verify"
               },
               ctx.server
             )

    assert checked["status"] == "blocked"
    assert checked["verification"]["status"] == "failed"
    refute checked["verification"]["all_passed"]
  end

  test "Board write payloads require idempotency keys and reject unbounded or non-JSON data", ctx do
    {:ok, board} = Coordinator.board(ctx.gid, "lead", ctx.server)

    assert {:error, "command_id_required", _} =
             Coordinator.board_create_task(
               ctx.gid,
               %{
                 "session_id" => "lead",
                 "title" => "missing command",
                 "acceptance" => [%{"kind" => "file_exists", "path" => "proof.txt"}],
                 "expected_revision" => board["revision"]
               },
               ctx.server
             )

    assert {:error, "command_acceptance_forbidden", _} =
             Coordinator.board_create_task(
               ctx.gid,
               %{
                 "session_id" => "worker",
                 "title" => "untrusted command",
                 "acceptance" => [
                   %{"kind" => "command", "program" => "python3", "args" => ["-c", "print('x')"]}
                 ],
                 "expected_revision" => board["revision"],
                 "command_id" => "worker-command-acceptance"
               },
               ctx.server
             )

    assert {:error, "payload_too_large", _} =
             Coordinator.board_create_task(
               ctx.gid,
               %{
                 "session_id" => "lead",
                 "title" => String.duplicate("x", 513),
                 "acceptance" => [%{"kind" => "file_exists", "path" => "proof.txt"}],
                 "expected_revision" => board["revision"],
                 "command_id" => "oversized-title"
               },
               ctx.server
             )

    {:ok, %{"task" => task, "revision" => revision}} =
      create_task(ctx, board["revision"], "bounded", [], "worker", [])

    assert {:error, "bad_request", _} =
             Coordinator.board_update_task(
               ctx.gid,
               task["task_id"],
               %{
                 "session_id" => "worker",
                 "expected_revision" => revision,
                 "result" => self(),
                 "command_id" => "non-json-result"
               },
               ctx.server
             )

    assert {:ok, %{"revision" => ^revision}} = Coordinator.board(ctx.gid, "lead", ctx.server)
  end

  test "write_scope overlap is diagnostic rather than a lock", ctx do
    {:ok, b0} = Coordinator.board(ctx.gid, "lead", ctx.server)
    {:ok, %{"revision" => r1}} = create_task(ctx, b0["revision"], "a", [], nil, ["lib/auth"])
    {:ok, %{"warnings" => warnings}} = create_task(ctx, r1, "b", [], nil, ["lib/auth/token.ex"])
    assert [%{"task_id" => _}] = warnings
  end

  test "wait is edge-triggered without polling and times out explicitly", ctx do
    {:ok, board} = Coordinator.board(ctx.gid, "lead", ctx.server)

    waiter =
      Task.async(fn ->
        Coordinator.wait(ctx.gid, "lead", board["revision"], 5_000, ctx.server)
      end)

    Process.sleep(30)
    {:ok, _} = create_task(ctx, board["revision"], "wake", [], nil, [])
    assert {:ok, %{"kind" => "edge", "revision" => revision}} = Task.await(waiter, 6_000)
    assert revision > board["revision"]

    assert {:ok, %{"kind" => "timeout"}} =
             Coordinator.wait(ctx.gid, "lead", revision, 1_000, ctx.server)
  end

  test "event replay restores revision and command idempotency", ctx do
    {:ok, board} = Coordinator.board(ctx.gid, "lead", ctx.server)
    {:ok, %{"revision" => revision}} = create_task(ctx, board["revision"], "persist", [], nil, [])
    GenServer.stop(ctx.pid)

    restored_name = String.to_atom("hive_restore_#{System.unique_integer([:positive])}")
    {:ok, restored} = Coordinator.start_link(name: restored_name, path: ctx.path, durability: :event)
    on_exit(fn -> if Process.alive?(restored), do: GenServer.stop(restored) end)

    assert {:ok, %{"revision" => ^revision}} = Coordinator.board(ctx.gid, "lead", restored_name)

    assert {:error, "duplicate_command", _} =
             Coordinator.board_create_task(
               ctx.gid,
               %{
                 "session_id" => "lead",
                 "title" => "duplicate",
                 "acceptance" => [%{"kind" => "file_exists", "path" => "proof.txt"}],
                 "expected_revision" => revision,
                 "command_id" => "task-persist"
               },
               restored_name
             )
  end

  test "spawn depth and cumulative total are hard limits", ctx do
    workspace = %{"kind" => "shared", "path" => ctx.root}
    acceptance = [%{"kind" => "file_exists", "path" => "proof.txt"}]
    {:ok, before_child} = Coordinator.board(ctx.gid, "lead", ctx.server)

    assert {:ok, %{member: child}} =
             Coordinator.delegate(
               ctx.gid,
               %{
                 "session_id" => "child",
                 "parent_session_id" => "lead",
                 "title" => "child",
                 "role" => "worker",
                 "protocol_version" => 2,
                 "acceptance" => acceptance,
                 "depends_on" => [],
                 "write_scope" => [],
                 "expected_revision" => before_child["revision"],
                 "workspace" => workspace,
                 "command_id" => "spawn-child"
               },
               ctx.server
             )

    assert child["depth"] == 1
    {:ok, before_grandchild} = Coordinator.board(ctx.gid, "lead", ctx.server)

    assert {:error, "depth_limit", _} =
             Coordinator.delegate(
               ctx.gid,
               %{
                 "session_id" => "grandchild",
                 "parent_session_id" => "child",
                 "title" => "grandchild",
                 "role" => "worker",
                 "protocol_version" => 2,
                 "acceptance" => acceptance,
                 "depends_on" => [],
                 "write_scope" => [],
                 "expected_revision" => before_grandchild["revision"],
                 "workspace" => workspace,
                 "command_id" => "spawn-grandchild"
               },
               ctx.server
             )
  end

  test "delegated task waits for unfinished dependencies", ctx do
    {:ok, board} = Coordinator.board(ctx.gid, "lead", ctx.server)

    {:ok, %{"task" => predecessor, "revision" => revision}} =
      Coordinator.board_create_task(
        ctx.gid,
        %{
          "session_id" => "lead",
          "title" => "predecessor",
          "assigned_session_id" => "worker",
          "acceptance" => [%{"kind" => "file_exists", "path" => "proof.txt"}],
          "expected_revision" => board["revision"],
          "command_id" => "delegate-dependency-predecessor"
        },
        ctx.server
      )

    assert {:ok, %{task: delegated}} =
             Coordinator.delegate(
               ctx.gid,
               %{
                 "session_id" => "dependent-child",
                 "parent_session_id" => "lead",
                 "title" => "dependent",
                 "role" => "worker",
                 "protocol_version" => 2,
                 "acceptance" => [%{"kind" => "file_exists", "path" => "proof.txt"}],
                 "depends_on" => [predecessor["task_id"]],
                 "write_scope" => [],
                 "expected_revision" => revision,
                 "workspace" => %{"kind" => "shared", "path" => ctx.root},
                 "command_id" => "delegate-dependency-child"
               },
               ctx.server
             )

    assert delegated["status"] == "pending"
    assert delegated["depends_on"] == [predecessor["task_id"]]
  end

  test "wake restores a persisted session runtime before delivery", ctx do
    sid = "wake-recover-" <> Integer.to_string(System.unique_integer([:positive]))
    :ok = Newbee.Session.mark_created(sid)
    :ok = Newbee.Session.set_cwd(sid, ctx.root)
    on_exit(fn -> Newbee.Web.Session.destroy(sid) end)

    assert {:ok, _member} =
             Coordinator.add_member(
               ctx.gid,
               %{"session_id" => sid, "parent_session_id" => "lead", "command_id" => "wake-member-" <> sid},
               ctx.server
             )

    assert {:ok, _message} =
             Coordinator.send_message(
               ctx.gid,
               %{
                 "sender_session_id" => "lead",
                 "to_session_id" => sid,
                 "body" => "wake persisted session",
                 "delivery" => "wake",
                 "command_id" => "wake-message-" <> sid
               },
               ctx.server
             )

    assert {:ok, _pid} = await_session_runtime(sid, 100)
    assert Newbee.Session.cwd(sid) == Path.expand(ctx.root)
  end

  test "terminal Hive tasks make waiting workspaces reviewable", ctx do
    child_session_id = "review-success-" <> Integer.to_string(System.unique_integer([:positive]))
    {:ok, workspace} = Newbee.Collaboration.Workspace.prepare(ctx.root, child_session_id, true)
    File.write!(Path.join(workspace["path"], "proof.txt"), "changed")

    {:ok, board} = Coordinator.board(ctx.gid, "lead", ctx.server)

    assert {:ok, %{task: task}} =
             Coordinator.delegate(
               ctx.gid,
               %{
                 "session_id" => child_session_id,
                 "parent_session_id" => "lead",
                 "title" => "review success",
                 "role" => "worker",
                 "protocol_version" => 2,
                 "acceptance" => [%{"kind" => "file_exists", "path" => "proof.txt"}],
                 "depends_on" => [],
                 "write_scope" => [],
                 "expected_revision" => board["revision"],
                 "workspace" => workspace,
                 "command_id" => "review-success-delegate"
               },
               ctx.server
             )

    assert task["workspace"]["review_status"] == "waiting"

    assert {:ok, %{"revision" => submitted_revision}} =
             Coordinator.board_update_task(
               ctx.gid,
               task["task_id"],
               %{
                 "session_id" => child_session_id,
                 "expected_revision" => task["board_revision"],
                 "status" => "submitted",
                 "result" => "ready",
                 "command_id" => "review-success-submit"
               },
               ctx.server
             )

    assert {:ok, %{"task" => verified}} =
             Coordinator.board_verify(
               ctx.gid,
               task["task_id"],
               %{
                 "session_id" => "lead",
                 "expected_revision" => submitted_revision,
                 "command_id" => "review-success-verify"
               },
               ctx.server
             )

    assert verified["status"] == "succeeded"
    assert verified["workspace"]["review_status"] == "pending"
    assert {:ok, review} = Newbee.Collaboration.Workspace.review(verified)
    assert review.review_status == "pending"

    assert {:error, "stale_review", _} =
             Newbee.Collaboration.Workspace.apply(verified, String.duplicate("0", 64))

    {:ok, terminal_group} =
      Coordinator.create_group(
        %{
          "session_id" => "terminal-lead",
          "title" => "terminal review states",
          "project_root" => ctx.root,
          "max_total" => 4,
          "command_id" => "terminal-review-group"
        },
        ctx.server
      )

    {:ok, terminal_board} = Coordinator.board(terminal_group["group_id"], "terminal-lead", ctx.server)

    assert {:ok, %{task: failed_task}} =
             Coordinator.delegate(
               terminal_group["group_id"],
               %{
                 "session_id" => "failed-child",
                 "parent_session_id" => "terminal-lead",
                 "title" => "failed review",
                 "protocol_version" => 2,
                 "acceptance" => [%{"kind" => "file_exists", "path" => "proof.txt"}],
                 "depends_on" => [],
                 "write_scope" => [],
                 "expected_revision" => terminal_board["revision"],
                 "workspace" => %{"kind" => "shared", "path" => ctx.root, "review_status" => "waiting"},
                 "command_id" => "failed-review-delegate"
               },
               ctx.server
             )

    assert {:ok, %{"task" => failed}} =
             Coordinator.board_update_task(
               terminal_group["group_id"],
               failed_task["task_id"],
               %{
                 "session_id" => "failed-child",
                 "expected_revision" => failed_task["board_revision"],
                 "status" => "failed",
                 "result" => "failed",
                 "command_id" => "failed-review-update"
               },
               ctx.server
             )

    assert failed["workspace"]["review_status"] == "pending"

    {:ok, cancelled_board} = Coordinator.board(terminal_group["group_id"], "terminal-lead", ctx.server)

    assert {:ok, %{task: cancelled_task}} =
             Coordinator.delegate(
               terminal_group["group_id"],
               %{
                 "session_id" => "cancelled-child",
                 "parent_session_id" => "terminal-lead",
                 "title" => "cancelled review",
                 "protocol_version" => 2,
                 "acceptance" => [%{"kind" => "file_exists", "path" => "proof.txt"}],
                 "depends_on" => [],
                 "write_scope" => [],
                 "expected_revision" => cancelled_board["revision"],
                 "workspace" => %{"kind" => "shared", "path" => ctx.root, "review_status" => "waiting"},
                 "command_id" => "cancelled-review-delegate"
               },
               ctx.server
             )

    assert {:ok, %{"task" => cancelled}} =
             Coordinator.board_update_task(
               terminal_group["group_id"],
               cancelled_task["task_id"],
               %{
                 "session_id" => "cancelled-child",
                 "expected_revision" => cancelled_task["board_revision"],
                 "status" => "cancelled",
                 "command_id" => "cancelled-review-update"
               },
               ctx.server
             )

    assert cancelled["workspace"]["review_status"] == "pending"
  end

  test "Hive running task survives restart without a live runtime or lease", ctx do
    {:ok, board} = Coordinator.board(ctx.gid, "lead", ctx.server)

    {:ok, %{"task" => task, "revision" => r1}} =
      Coordinator.board_create_task(
        ctx.gid,
        %{
          "session_id" => "lead",
          "title" => "recoverable-running",
          "assigned_session_id" => "worker",
          "acceptance" => [%{"kind" => "file_exists", "path" => "proof.txt"}],
          "expected_revision" => board["revision"],
          "command_id" => "recoverable-create"
        },
        ctx.server
      )

    assert {:ok, %{"revision" => _running_revision}} =
             Coordinator.board_update_task(
               ctx.gid,
               task["task_id"],
               %{
                 "session_id" => "worker",
                 "expected_revision" => r1,
                 "status" => "running",
                 "command_id" => "recoverable-running"
               },
               ctx.server
             )

    GenServer.stop(ctx.pid)
    restored_name = String.to_atom("hive_restore_#{System.unique_integer([:positive])}")
    {:ok, restored} = Coordinator.start_link(name: restored_name, path: ctx.path, durability: :event)
    on_exit(fn -> if Process.alive?(restored), do: GenServer.stop(restored) end)

    assert {:error, "busy", _} = Coordinator.delete_group(ctx.gid, "lead", restored_name)
    assert {:ok, board_after_restart} = Coordinator.board(ctx.gid, "lead", restored_name)
    [recovered] = Enum.filter(board_after_restart["tasks"], &(&1["task_id"] == task["task_id"]))
    assert recovered["protocol_version"] == 2
    assert recovered["status"] == "running"
    assert recovered["lease_until"] in [nil, ""]
  end

  test "deleting a group wakes registered waiters", ctx do
    {:ok, group} =
      Coordinator.create_group(
        %{"session_id" => "solo", "title" => "delete", "command_id" => "delete-group-open"},
        ctx.server
      )

    waiter =
      Task.async(fn ->
        Coordinator.wait(group["group_id"], "solo", group["revision"], 5_000, ctx.server)
      end)

    Process.sleep(30)
    assert {:ok, _} = Coordinator.delete_group(group["group_id"], "solo", ctx.server)
    assert {:error, "group_deleted", _} = Task.await(waiter, 6_000)
  end

  test "delivery claim and ack are durable and idempotent", ctx do
    {:ok, board} = Coordinator.board(ctx.gid, "lead", ctx.server)

    {:ok, %{"task" => task, "revision" => _revision}} =
      Coordinator.board_create_task(
        ctx.gid,
        %{
          "session_id" => "lead",
          "title" => "durable delivery",
          "assigned_session_id" => "worker",
          "acceptance" => [%{"kind" => "file_exists", "path" => "proof.txt"}],
          "expected_revision" => board["revision"],
          "command_id" => "delivery-create"
        },
        ctx.server
      )

    {:ok, group} = Coordinator.get(ctx.gid, ctx.server)
    delivery = Enum.find(group["deliveries"], &(&1["task_id"] == task["task_id"]))
    assert is_binary(delivery["delivery_id"])

    attrs = %{
      "delivery_id" => delivery["delivery_id"],
      "runtime_id" => "runtime-one",
      "kind" => "task",
      "task_id" => task["task_id"],
      "attempt" => 0
    }

    assert {:ok, %{"decision" => "deliver"}} =
             Coordinator.delivery_claim(ctx.gid, "worker", attrs, ctx.server)

    assert {:ok, %{"decision" => "duplicate"}} =
             Coordinator.delivery_claim(ctx.gid, "worker", attrs, ctx.server)

    assert {:error, "delivery_owner", _} =
             Coordinator.delivery_ack(ctx.gid, "worker", %{attrs | "runtime_id" => "runtime-two"}, ctx.server)

    assert {:ok, %{"decision" => "consumed"}} =
             Coordinator.delivery_ack(ctx.gid, "worker", attrs, ctx.server)

    assert {:ok, %{"decision" => "duplicate"}} =
             Coordinator.delivery_ack(ctx.gid, "worker", attrs, ctx.server)

    assert {:ok, []} = Coordinator.pending_deliveries("worker", ctx.server)
  end

  test "submitted task captures a frozen source and running result does not submit", ctx do
    {:ok, board} = Coordinator.board(ctx.gid, "lead", ctx.server)

    {:ok, %{"task" => task, "revision" => r1}} =
      Coordinator.board_create_task(
        ctx.gid,
        %{
          "session_id" => "lead",
          "title" => "frozen submission",
          "assigned_session_id" => "worker",
          "acceptance" => [%{"kind" => "file_exists", "path" => "proof.txt"}],
          "expected_revision" => board["revision"],
          "command_id" => "submission-create"
        },
        ctx.server
      )

    {:ok, %{"task" => running, "revision" => r2}} =
      Coordinator.board_update_task(
        ctx.gid,
        task["task_id"],
        %{
          "session_id" => "worker",
          "expected_revision" => r1,
          "status" => "running",
          "result" => "progress only",
          "command_id" => "submission-running"
        },
        ctx.server
      )

    refute Map.has_key?(running, "submission")

    assert {:ok, %{"task" => submitted, "revision" => _r3}} =
             Coordinator.board_update_task(
               ctx.gid,
               task["task_id"],
               %{
                 "session_id" => "worker",
                 "expected_revision" => r2,
                 "expected_attempt" => 0,
                 "status" => "submitted",
                 "result" => "proof captured",
                 "command_id" => "submission-submit"
               },
               ctx.server
             )

    assert %{"id" => submission_id, "root" => root, "tree_sha256" => tree} = submitted["submission"]
    assert is_binary(submission_id)
    assert File.dir?(root)
    assert is_binary(tree)

    {:ok, group_after_submit} = Coordinator.get(ctx.gid, ctx.server)
    result_delivery = Enum.find(group_after_submit["deliveries"], &(&1["purpose"] == "result"))
    assert result_delivery["session_id"] == "lead"
    assert result_delivery["task_id"] == task["task_id"]

    assert {:ok, [%{"delivery_id" => result_delivery_id, "kind" => "task"}]} =
             Coordinator.pending_deliveries("lead", ctx.server)

    assert result_delivery_id == result_delivery["delivery_id"]

    result_attrs = %{
      "delivery_id" => result_delivery_id,
      "runtime_id" => "lead-runtime",
      "kind" => "task",
      "task_id" => task["task_id"],
      "attempt" => 0
    }

    assert {:ok, %{"decision" => "deliver"}} =
             Coordinator.delivery_claim(ctx.gid, "lead", result_attrs, ctx.server)

    assert {:ok, %{"decision" => "consumed"}} =
             Coordinator.delivery_ack(ctx.gid, "lead", result_attrs, ctx.server)

    {:ok, board_after_delivery} = Coordinator.board(ctx.gid, "lead", ctx.server)

    assert {:ok, %{"task" => verified}} =
             Coordinator.board_verify(
               ctx.gid,
               task["task_id"],
               %{
                 "session_id" => "lead",
                 "expected_revision" => board_after_delivery["revision"],
                 "command_id" => "submission-verify"
               },
               ctx.server
             )

    assert verified["status"] == "succeeded"
    assert verified["verification"]["submission_id"] == submission_id
    assert verified["verification"]["tree_sha256"] == tree
  end

  defp await_session_runtime(sid, attempts) when attempts > 0 do
    case Newbee.Web.Session.lookup(sid) do
      {:ok, pid} ->
        {:ok, pid}

      _ ->
        Process.sleep(50)
        await_session_runtime(sid, attempts - 1)
    end
  end

  defp await_session_runtime(_sid, 0), do: {:error, :not_found}

  defp create_task(ctx, revision, title, deps, assigned, scopes) do
    Coordinator.board_create_task(
      ctx.gid,
      %{
        "session_id" => "lead",
        "title" => title,
        "acceptance" => [%{"kind" => "file_exists", "path" => "proof.txt"}],
        "depends_on" => deps,
        "write_scope" => scopes,
        "assigned_session_id" => assigned,
        "expected_revision" => revision,
        "command_id" => "task-#{title}"
      },
      ctx.server
    )
  end
end
