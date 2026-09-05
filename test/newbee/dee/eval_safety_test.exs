defmodule Newbee.DEE.EvalSafetyTest do
  use ExUnit.Case, async: false
  alias Newbee.DEE.{EvalJob, EvalWorker, BoundedIO}

  setup do
    worker = start_supervised!(EvalWorker)
    %{worker: worker}
  end

  test "normal result returns and failed cell preserves bindings", %{worker: worker} do
    assert %{value: "42"} = GenServer.call(worker, {:eval, "x = 42", [timeout: 1000]}, 3000)
    assert %{error: error} = GenServer.call(worker, {:eval, "Process.sleep(:infinity)", [timeout: 30]}, 3000)
    assert error =~ "timeout"
    assert %{value: "84"} = GenServer.call(worker, {:eval, "x * 2", [timeout: 1000]}, 3000)
  end

  test "CPU runaway is bounded", %{worker: worker} do
    code = "f = fn f -> f.(f) end; f.(f)"
    result = GenServer.call(worker, {:eval, code, [timeout: 2000, reductions_limit: 10000]}, 3000)
    assert result.error =~ "reductions"
    assert %{value: "2"} = GenServer.call(worker, {:eval, "1 + 1", [timeout: 1000]}, 3000)
  end

  test "worker stays responsive and stale cancellation is ignored", %{worker: worker} do
    id = make_ref()
    key = make_ref()

    caller =
      Task.async(fn ->
        GenServer.call(
          worker,
          {:eval, "Process.sleep(:infinity)", [job_id: id, interrupt_key: key, timeout: 2000]},
          4000
        )
      end)

    on_exit(fn -> if Process.alive?(caller.pid), do: Process.exit(caller.pid, :kill) end)
    wait_active(key, 100)
    assert [] = GenServer.call(worker, :bindings_summary, 200)
    assert {:error, :not_active} = GenServer.call(worker, {:cancel, make_ref()}, 200)
    assert :ok = GenServer.call(worker, {:cancel, id}, 200)
    assert %{error: "interrupted"} = Task.await(caller, 1000)
  end

  test "finite configuration and terminal state cannot be reopened" do
    job = EvalJob.new(timeout: :infinity)
    assert is_integer(job.timeout) and job.timeout > 0
    assert EvalJob.normalize_timeout(999_999_999) <= 1_800_000
    {finished, :accepted} = EvalJob.finish(job, :timed_out, :deadline)
    assert {:error, :already_terminal} = EvalJob.finish(finished, :succeeded, nil)
  end

  test "output truncation preserves UTF-8" do
    {:ok, io} = BoundedIO.start_link(2)
    assert :ok = IO.write(io, <<228, 184, 173>>)
    result = BoundedIO.contents(io)
    assert String.valid?(result)
    assert result =~ "dropped 3 bytes"
    BoundedIO.stop(io)
  end

  defp wait_active(_key, 0), do: flunk("cell did not register")

  defp wait_active(key, n) do
    if EvalWorker.active_pid(key) == nil do
      Process.sleep(5)
      wait_active(key, n - 1)
    end
  end

  test "guardian terminates an unresponsive evaluator without its mailbox" do
    evaluator = spawn(fn -> Process.sleep(:infinity) end)
    worker = spawn(fn -> Process.sleep(:infinity) end)
    monitor = Process.monitor(evaluator)

    on_exit(fn ->
      Process.exit(evaluator, :kill)
      Process.exit(worker, :kill)
    end)

    {guardian, _} =
      Newbee.DEE.EvalGuardian.start(evaluator, self(), %{mode: :local, worker: worker}, nil, make_ref(), 10)

    on_exit(fn -> Process.exit(guardian, :kill) end)
    assert_receive {:DOWN, ^monitor, :process, ^evaluator, :killed}, 6000
  end

  @tag :node
  test "accepted code is not replayed after the remote node dies" do
    alias Newbee.DEE.Evaluator
    marker = Path.join(System.tmp_dir!(), "eval-once-" <> Integer.to_string(System.unique_integer([:positive])))
    {:ok, evaluator} = Evaluator.start(mode: :node)

    on_exit(fn ->
      if Process.alive?(evaluator), do: GenServer.stop(evaluator)
      File.rm(marker)
    end)

    code = "File.write!(" <> inspect(marker) <> ", \"x\", [:append]); System.halt(0)"
    result = Evaluator.eval(evaluator, code, timeout: 5000)
    assert result.outcome_unknown
    assert File.read!(marker) == "x"
    assert %{status: :ok, value: "2"} = Evaluator.eval(evaluator, "1 + 1")
    assert File.read!(marker) == "x"
  end

  test "seal_pending_tools appends one unknown result per dangling call" do
    session = Newbee.Session.open("eval-seal-" <> Integer.to_string(System.unique_integer([:positive])))

    Newbee.Session.append(session, %{
      "role" => "assistant",
      "content" => "working",
      "tool_calls" => [
        %{"id" => "dangling", "type" => "function", "function" => %{"name" => "run_elixir", "arguments" => "{}"}}
      ]
    })

    assert 1 = Newbee.Session.seal_pending_tools(session)
    assert 0 = Newbee.Session.seal_pending_tools(session)

    tools =
      Newbee.Session.messages(session)
      |> Enum.filter(fn message -> message["role"] == "tool" and message["tool_call_id"] == "dangling" end)

    assert [%{"content" => content, "recovery" => true}] = tools
    assert content =~ "outcome_unknown"
    assert content =~ "not replayed"
  end

  test "stale active registration is cleaned" do
    key = make_ref()
    dead = spawn(fn -> :ok end)
    ref = Process.monitor(dead)
    assert_receive {:DOWN, ^ref, :process, ^dead, _}, 1000
    :ok = Newbee.DEE.EvalWorker.register_active(key, make_ref(), dead)
    assert nil == Newbee.DEE.EvalWorker.active_pid(key)
  end

  test "node budget admits local and rejects dead node" do
    assert :ok = Newbee.DEE.Evaluator.check_node_budget(%{mode: :local, worker: self()})

    assert {:error, :node_dead} =
             Newbee.DEE.Evaluator.check_node_budget(%{node: :nonexistent_eval_node@nohost, worker: self()})
  end

  test "orphan reconciliation keeps live origin" do
    assert {:ok, _} = Newbee.DEE.Evaluator.reconcile_orphans()
  end
end
