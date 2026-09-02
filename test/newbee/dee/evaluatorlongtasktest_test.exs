defmodule Newbee.DEE.EvaluatorLongTaskTest do
  use ExUnit.Case, async: false
  alias Newbee.DEE.Evaluator

  # 回归：cell 的 60s 硬截止和 RPC 的 300s 硬截止都可能在正确任务仍运行时
  # 返回错误。任务现在由自身 deadline 决定；默认无限等待但始终可中断。

  @tag :node
  @tag timeout: 100_000
  test "shell 任务超过 60 秒仍正常返回" do
    {:ok, ev} = Evaluator.start(mode: :node)
    on_exit(fn -> if Process.alive?(ev), do: GenServer.stop(ev) end)

    command_module = "Newbee.Tools." <> "Run"
    code = command_module <> ~S|.sh_long("sleep 61; printf long-ok")|
    t0 = System.monotonic_time(:millisecond)
    result = Evaluator.eval(ev, code)
    elapsed = System.monotonic_time(:millisecond) - t0

    assert result.status == :ok
    assert result.value =~ "exit: 0"
    assert result.value =~ "long-ok"
    assert elapsed >= 60_000, "应等待任务完成而不是在 60 秒返回错误"
  end

  @tag :node
  test "长任务副作用只执行一次（不重复）" do
    {:ok, ev} = Evaluator.start(mode: :node)
    Process.sleep(2_000)

    marker =
      Path.join(
        System.tmp_dir!(),
        "eval_long_marker_" <>
          Integer.to_string(System.system_time(:native)) <> "_" <> Integer.to_string(System.unique_integer([:positive]))
      )

    code = "File.write!(\"" <> marker <> "\", \"x\")\n:timer.sleep(12_000)\n\"done\""
    r = Evaluator.eval(ev, code, [])
    assert r.status == :ok
    assert File.read!(marker) == "x"
    File.rm(marker)

    GenServer.stop(ev)
  end

  @tag :node
  @tag timeout: 30_000
  test "跨节点 interrupt 会清理 shell 和子进程" do
    marker = marker_path("interrupt")
    {:ok, ev} = Evaluator.start(mode: :node)

    on_exit(fn ->
      if Process.alive?(ev), do: GenServer.stop(ev)
      cleanup_marker(marker)
    end)

    command_module = "Newbee.Tools." <> "Run"
    command = shell_tree_command(marker)
    code = command_module <> ".sh_long(" <> inspect(command) <> ")"
    task = Task.async(fn -> Evaluator.eval(ev, code) end)

    assert wait_until(fn -> length(read_pids(marker)) == 2 end, 10_000)
    pids = read_pids(marker)

    assert :ok = Evaluator.interrupt(ev)
    assert %{status: :error, error: "interrupted"} = Task.await(task, 10_000)
    assert wait_until(fn -> Enum.all?(pids, &(not process_running?(&1))) end, 5_000)
    assert %{status: :ok, value: "2"} = Evaluator.eval(ev, "1 + 1")
  end

  @tag :node
  @tag timeout: 30_000
  test "跨节点调用者死亡会清理 shell 和子进程" do
    marker = marker_path("owner-down")
    {:ok, ev} = Evaluator.start(mode: :node)

    on_exit(fn ->
      if Process.alive?(ev), do: GenServer.stop(ev)
      cleanup_marker(marker)
    end)

    command_module = "Newbee.Tools." <> "Run"
    command = shell_tree_command(marker)
    code = command_module <> ".sh_long(" <> inspect(command) <> ")"
    caller = spawn(fn -> Evaluator.eval(ev, code) end)

    assert wait_until(fn -> length(read_pids(marker)) == 2 end, 10_000)
    pids = read_pids(marker)
    Process.exit(caller, :kill)

    assert wait_until(fn -> Enum.all?(pids, &(not process_running?(&1))) end, 5_000)
    assert %{status: :ok, value: "2"} = Evaluator.eval(ev, "1 + 1")
  end

  @tag :node
  @tag timeout: 30_000
  test "Ring0 shell 始终恢复 evaluator 的 worktree cwd" do
    cwd =
      Path.join(
        System.tmp_dir!(),
        "newbee-worktree-cwd-#{System.unique_integer([:positive, :monotonic])}"
      )

    other = cwd <> "-other"
    File.mkdir_p!(cwd)
    File.mkdir_p!(other)
    {:ok, ev} = Evaluator.start(mode: :node, cwd: cwd)

    on_exit(fn ->
      if Process.alive?(ev), do: GenServer.stop(ev)
      File.rm_rf(cwd)
      File.rm_rf(other)
    end)

    command_module = "Newbee.Tools." <> "Run"
    initial = Evaluator.eval(ev, command_module <> ~S|.sh("pwd")|)
    assert initial.status == :ok
    assert initial.value =~ cwd

    assert %{status: :ok, cwd: ^other} = Evaluator.eval(ev, "File.cd!(" <> inspect(other) <> ")")
    restored = Evaluator.eval(ev, command_module <> ~S|.sh("pwd")|)

    assert restored.status == :ok
    assert restored.value =~ cwd
    refute restored.value =~ other
  end

  @tag :node
  test "节点真死仍能切 standby（原有兜底不回归）" do
    {:ok, ev} = Evaluator.start(mode: :node)
    Process.sleep(2_000)

    st = :sys.get_state(ev)
    primary = st.node
    # 杀 primary 节点
    :peer.stop(st.peer)
    Process.sleep(500)

    r = Evaluator.eval(ev, "1 + 1", [])
    assert r.status == :ok
    assert r.value == "2"
    # 已切到 standby 且 restarts 累计
    st2 = :sys.get_state(ev)
    assert st2.node != primary
    assert st2.restarts >= 1

    GenServer.stop(ev)
  end

  defp marker_path(kind) do
    Path.join(
      System.tmp_dir!(),
      "newbee-evaluator-#{kind}-#{System.unique_integer([:positive, :monotonic])}.pid"
    )
  end

  defp shell_tree_command(marker) do
    marker = "'" <> String.replace(marker, "'", "'\\''") <> "'"
    "printf '%s\\n' \"$$\" > #{marker}; sleep 30 & printf '%s\\n' \"$!\" >> #{marker}; wait"
  end

  defp read_pids(marker) do
    case File.read(marker) do
      {:ok, body} ->
        body
        |> String.split()
        |> Enum.flat_map(fn value ->
          case Integer.parse(value) do
            {pid, ""} -> [pid]
            _ -> []
          end
        end)

      _ ->
        []
    end
  end

  defp process_running?(pid) do
    case System.cmd("ps", ["-o", "stat=", "-p", Integer.to_string(pid)], stderr_to_stdout: true) do
      {status, 0} ->
        status = String.trim(status)
        status != "" and not String.starts_with?(status, "Z")

      _ ->
        false
    end
  rescue
    _ -> false
  end

  defp wait_until(predicate, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait_until(predicate, deadline)
  end

  defp do_wait_until(predicate, deadline) do
    cond do
      predicate.() ->
        true

      System.monotonic_time(:millisecond) >= deadline ->
        false

      true ->
        Process.sleep(20)
        do_wait_until(predicate, deadline)
    end
  end

  defp cleanup_marker(marker) do
    marker
    |> read_pids()
    |> Enum.each(fn pid ->
      System.cmd("kill", ["-KILL", Integer.to_string(pid)], stderr_to_stdout: true)
    end)

    File.rm(marker)
  rescue
    _ -> :ok
  end
end
