defmodule Newbee.Collaboration.HiveSessionStub do
  use GenServer

  def start_link(session_id, owner) do
    GenServer.start_link(__MODULE__, owner, name: {:via, Registry, {Newbee.Web.SessionRegistry, session_id}})
  end

  @impl true
  def init(owner), do: {:ok, owner}

  @impl true
  def handle_cast(message, owner) do
    send(owner, {:hive_stub, message})
    {:noreply, owner}
  end
end

defmodule Newbee.Tools.HiveIntegrationTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog

  alias Newbee.Collaboration.{Capability, Coordinator, HiveSessionStub}
  alias Newbee.Tools.Hive
  alias Newbee.Agent.Loop
  alias Newbee.DEE.Evaluator

  setup do
    if pid = Process.whereis(Coordinator), do: GenServer.stop(pid)

    root = Path.join(System.tmp_dir!(), "hive-tool-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    {:ok, coordinator} = Coordinator.start_link(path: Path.join(root, "events.jsonl"), durability: :event)

    on_exit(fn ->
      if Process.alive?(coordinator), do: GenServer.stop(coordinator)
      File.rm_rf!(root)
    end)

    %{root: root, project_root: File.cwd!()}
  end

  test "all Hive entrypoints return recoverable errors for malformed top-level types" do
    calls = [
      {:open, [:bad]},
      {:delegate, [nil, nil]},
      {:board, [nil]},
      {:board_put, ["group", []]},
      {:board_claim, ["group", nil, "revision"]},
      {:report, ["group", "task", :submitted, %{}]},
      {:retry, [nil, nil, []]},
      {:verify, [nil, nil]},
      {:wait, ["group", %{}]},
      {:send, ["group", "target", :bad, []]},
      {:inbox, [nil, []]},
      {:roster, [nil]},
      {:interrupt, [nil, nil]},
      {:close, [nil, nil]}
    ]

    for {function, args} <- calls do
      assert {:error, "bad_request", message} = apply(Hive, function, args)
      assert is_binary(message)
    end
  end

  test "report accepts documented atom and string statuses with revision CAS", ctx do
    with_identity("lead", ctx.project_root, fn ->
      {:ok, group} = Hive.open("report contract")
      gid = group["group_id"]

      assert {:ok, created} =
               Hive.board_put(gid, %{
                 "title" => "check project",
                 "assigned_session_id" => "lead",
                 "acceptance" => [%{"kind" => "file_exists", "path" => "mix.exs"}],
                 "expected_revision" => group["revision"]
               })

      tid = created["task"]["task_id"]
      assert {:error, "bad_request", _} = Hive.report(gid, tid, :running)
      assert {:ok, running} = Hive.report(gid, tid, :running, expected_revision: created["revision"])
      assert running["task"]["status"] == "running"
      assert {:ok, running} = Hive.report(gid, tid, :running, expected_revision: running["revision"], progress: "50%")
      assert running["task"]["progress"] == "50%"

      assert {:ok, submitted} =
               Hive.report(gid, tid, "submitted", expected_revision: running["revision"], result: "checked")

      assert submitted["task"]["status"] == "submitted"

      for status <- [:succeeded, "succeeded", :unknown, %{}, 42] do
        assert {:error, "bad_request", _} = Hive.report(gid, tid, status, expected_revision: submitted["revision"])
      end
    end)
  end

  test "Hive declares the filesystem and shell effects used by delegation and verification" do
    builtin = Newbee.Plugins.builtin("tool.hive")
    assert Enum.sort(builtin.capabilities) == [:fs, :shell]
  end

  test "Hive is the only registered collaboration tool and prompt contract" do
    assert is_nil(Newbee.Plugins.builtin("tool.collaboration"))
    assert Newbee.Plugins.builtin("tool.hive")

    prompt = Newbee.Environment.Projection.collaboration_prompt()
    assert prompt =~ "Newbee.Tools.Hive"
    assert prompt =~ "source of truth"
    assert prompt =~ "untrusted data"
    assert prompt =~ "expected_attempt"
    assert prompt =~ "write_scope"
    assert prompt =~ "queue"
    refute prompt =~ "Newbee.Tools.Collaboration"
    refute File.exists?(Path.join(File.cwd!(), "lib/newbee/tools/collaboration.ex"))
    refute File.exists?(Path.join(File.cwd!(), "lib/newbee/tools/collaboration_host_identity.ex"))
  end

  test "normal Agent.Loop capability shape opens one real Coordinator group", ctx do
    assert {:error, "no_execution_context", _} = Hive.open("no token")

    with_identity("lead", ctx.project_root, fn ->
      assert {:ok, group} = Hive.open("real group", max_depth: 1, max_total: 3)
      assert group["coordinator_session_id"] == "lead"
      assert group["revision"] > 0
      assert [same] = Coordinator.groups_for_session("lead")
      assert same["group_id"] == group["group_id"]
      assert {:error, "bad_request", _} = Hive.wait(group["group_id"])
      assert {:error, "bad_request", _} = Hive.wait(group["group_id"], since_revision: "stale")
    end)
  end

  test "Agent.Loop passes collaboration capability into the current evaluator cell", ctx do
    {:ok, evaluator} = Evaluator.start(mode: :local)
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    tool =
      loop_tool_msg("Newbee.Tools.Hive.open(\"loop capability group\", max_depth: 1, max_total: 3)", "call_loop_hive")

    done = loop_done_msg("loop delegation works")

    client_fun = fn _messages, _on_text ->
      Agent.get_and_update(counter, fn
        0 -> {{:ok, tool, %{}}, 1}
        _ -> {{:ok, done, %{}}, 2}
      end)
    end

    {:ok, kernel} =
      Loop.start_link(
        client: %{},
        evaluator: evaluator,
        root: ctx.project_root,
        client_fun: client_fun
      )

    session_id = :sys.get_state(kernel).session.id

    on_exit(fn ->
      if Process.alive?(kernel), do: GenServer.stop(kernel)
      if Process.alive?(evaluator), do: GenServer.stop(evaluator)
      Newbee.Session.delete(session_id)
    end)

    assert {:done, "loop delegation works"} = Loop.submit(kernel, "delegate")
    final_state = :sys.get_state(kernel)

    result =
      Enum.find(final_state.messages, &(&1["role"] == "tool" and &1["tool_call_id"] == "call_loop_hive"))

    assert is_map(result)
    refute result["content"] =~ "no_execution_context"
    assert result["content"] =~ "revision"
    assert [group] = Coordinator.groups_for_session(session_id)
    assert group["coordinator_session_id"] == session_id
  end

  test "delegate uses the same group and persists persona plus filtered fork", ctx do
    parent_id = "hive-parent-#{System.unique_integer([:positive])}"
    :ok = Newbee.Session.mark_created(parent_id)
    parent = Newbee.Session.open(parent_id)
    Newbee.Session.append(parent, %{"role" => "user", "content" => "stable context"})
    Newbee.Session.append(parent, %{"role" => "assistant", "content" => "known conclusion"})

    result =
      with_identity(parent_id, ctx.project_root, fn ->
        {:ok, group} = Hive.open("delegate group", max_depth: 1, max_total: 3)

        assert {:ok, delegated} =
                 Hive.delegate(group["group_id"], "inspect proof",
                   persona: "reviewer",
                   acceptance: [%{"kind" => "file_exists", "path" => "mix.exs"}],
                   fork_turns: 1,
                   isolate: false
                 )

        {group, delegated}
      end)

    {group, delegated} = result
    child_id = delegated.session_id
    assert delegated.member["parent_session_id"] == parent_id
    assert delegated.member["depth"] == 1
    assert delegated.task["protocol_version"] == 2
    assert is_binary(delegated.task["acceptance_sha256"])
    assert delegated.fork == %{turns: 1, messages: 2}

    assert {:ok, same_group} = Coordinator.get(group["group_id"])
    assert Enum.any?(same_group["members"], &(&1["session_id"] == child_id))
    refute Enum.any?(Coordinator.list(), &(&1["title"] == "hive-shadow"))

    profile = Newbee.Session.collaboration_profile(child_id)
    assert profile["name"] == "reviewer"
    assert profile["reasoning_effort"] == "high"
    assert profile["group_id"] == group["group_id"]

    forked = Newbee.Session.messages(Newbee.Session.open(child_id))
    assert Enum.any?(forked, &(&1["content"] == "stable context"))
    assert Enum.any?(forked, &(&1["content"] == "known conclusion"))

    :ok = Newbee.Web.Session.destroy(child_id)
    assert wait_session_down(child_id, 50)
  end

  test "non-Lead command acceptance is rejected before a child session is created", ctx do
    group =
      with_identity("lead", ctx.project_root, fn ->
        {:ok, group} = Hive.open("command ownership")
        {:ok, _member} = Coordinator.add_member(group["group_id"], %{"session_id" => "worker"})
        group
      end)

    before_sessions = MapSet.new(Newbee.Session.list())

    with_identity("worker", ctx.project_root, fn ->
      assert {:error, "command_acceptance_forbidden", _} =
               Hive.delegate(group["group_id"], "must not spawn",
                 acceptance: [
                   %{"kind" => "command", "program" => "python3", "args" => ["-c", "print('x')"]}
                 ],
                 isolate: false
               )
    end)

    assert MapSet.new(Newbee.Session.list()) == before_sessions
    {:ok, unchanged} = Coordinator.get(group["group_id"])
    assert length(unchanged["members"]) == 2
    assert unchanged["tasks"] == []
  end

  test "malformed v2 acceptance is rejected before workspace or session side effects", ctx do
    group =
      with_identity("lead", ctx.project_root, fn ->
        {:ok, group} = Hive.open("acceptance preflight")
        group
      end)

    child_id = "bad-acceptance-child-6726"
    before_sessions = MapSet.new(Newbee.Session.list())

    with_identity("lead", ctx.project_root, fn ->
      assert {:error, "bad_acceptance", _} =
               Newbee.Collaboration.Delegator.delegate(
                 group["group_id"],
                 "lead",
                 "must not materialize",
                 session_id: child_id,
                 protocol_version: 2,
                 expected_revision: group["revision"],
                 acceptance: [%{"kind" => "shell", "cmd" => "rm -rf /"}],
                 isolate: false
               )
    end)

    assert MapSet.new(Newbee.Session.list()) == before_sessions
    assert {:error, :not_found} = Newbee.Web.Session.lookup(child_id)
    {:ok, unchanged} = Coordinator.get(group["group_id"])
    assert unchanged["members"] |> Enum.map(& &1["session_id"]) == ["lead"]
    assert unchanged["tasks"] == []
  end

  test "destroy cancels an in-flight kernel boot before its workspace disappears", ctx do
    sid = "boot-cancel-#{System.unique_integer([:positive])}"
    workspace = Path.join(ctx.root, "boot-workspace")
    File.mkdir_p!(workspace)

    log =
      capture_log(fn ->
        {:ok, session, ^sid} = Newbee.Web.Session.ensure(sid, workspace)
        worker = wait_boot_worker(session, 100)
        monitor = Process.monitor(worker)

        assert :ok = Newbee.Web.Session.destroy(sid)
        assert_receive {:DOWN, ^monitor, :process, ^worker, _reason}, 20_000
        File.rm_rf!(workspace)
        Process.sleep(100)
      end)

    refute log =~ "invalid_cwd"
    refute log =~ "evaluator node 初始启动失败"
    assert {:error, :not_found} = Newbee.Web.Session.lookup(sid)
  end

  test "invalid persona model is rejected before member publication and is compensated", ctx do
    child_id = "invalid-model-child-#{System.unique_integer([:positive])}"

    with_identity("lead", ctx.project_root, fn ->
      {:ok, group} = Hive.open("invalid model transaction")

      assert {:error, "session_error", _} =
               Newbee.Collaboration.Delegator.delegate(
                 group["group_id"],
                 "lead",
                 "must rollback",
                 session_id: child_id,
                 protocol_version: 2,
                 expected_revision: group["revision"],
                 persona_profile: %{
                   "name" => "invalid-provider",
                   "role" => "worker",
                   "provider" => "provider-that-does-not-exist",
                   "model" => "missing/model",
                   "instructions" => "work"
                 },
                 acceptance: [%{"kind" => "file_exists", "path" => "mix.exs"}],
                 isolate: false
               )

      {:ok, current} = Coordinator.get(group["group_id"])
      refute Enum.any?(current["members"], &(&1["session_id"] == child_id))
      refute child_id in Newbee.Session.list()
      assert {:error, :not_found} = Newbee.Web.Session.lookup(child_id)
    end)
  end

  test "interrupt resolves pid and enforces lead-or-parent authority", ctx do
    {:ok, stub} = HiveSessionStub.start_link("target", self())

    group =
      with_identity("lead", ctx.project_root, fn ->
        {:ok, group} = Hive.open("lifecycle")
        {:ok, _} = Coordinator.add_member(group["group_id"], %{"session_id" => "target", "parent_session_id" => "lead"})
        assert {:ok, %{"interrupted" => "target"}} = Hive.interrupt(group["group_id"], "target")
        group
      end)

    assert_receive {:hive_stub, :interrupt}, 1_000

    with_identity("outsider", ctx.project_root, fn ->
      assert {:error, "forbidden_role", _} = Hive.interrupt(group["group_id"], "target")
    end)

    Process.exit(stub, :kill)
  end

  defp wait_session_down(_session_id, 0), do: false

  defp wait_session_down(session_id, attempts) do
    case Newbee.Web.Session.lookup(session_id) do
      {:error, :not_found} ->
        true

      _ ->
        Process.sleep(50)
        wait_session_down(session_id, attempts - 1)
    end
  end

  defp wait_boot_worker(_session, 0), do: flunk("kernel boot worker did not start")

  defp wait_boot_worker(session, attempts) do
    case :sys.get_state(session).boot_worker do
      worker when is_pid(worker) ->
        worker

      _ ->
        Process.sleep(10)
        wait_boot_worker(session, attempts - 1)
    end
  end

  defp with_identity(session_id, root, fun) do
    :ok = Capability.register(self(), session_id, root)
    {:ok, token} = Capability.issue(self())
    Process.put({Newbee.Tools.Hive, :context}, %{capability: token})

    try do
      fun.()
    after
      Process.delete({Newbee.Tools.Hive, :context})
      Capability.revoke(token)
    end
  end

  defp loop_tool_msg(code, id) do
    %{
      "role" => "assistant",
      "content" => "",
      "tool_calls" => [
        %{
          "id" => id,
          "type" => "function",
          "function" => %{"name" => "run_elixir", "arguments" => Jason.encode!(%{code: code})}
        }
      ]
    }
  end

  defp loop_done_msg(summary) do
    %{
      "role" => "assistant",
      "content" => "final text",
      "tool_calls" => [
        %{
          "id" => "call_done",
          "type" => "function",
          "function" => %{"name" => "done", "arguments" => Jason.encode!(%{summary: summary})}
        }
      ]
    }
  end
end
