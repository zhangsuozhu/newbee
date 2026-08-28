defmodule Newbee.Tools.CommandJobTest do
  use ExUnit.Case, async: false

  test "finite timeout terminates the whole command tree" do
    marker = marker_path("timeout")
    on_exit(fn -> cleanup_marker(marker) end)

    result = run_shell(shell_tree_command(marker), timeout: 200)
    pids = read_pids(marker)

    assert result.exit == :timeout
    assert length(pids) == 2
    assert wait_until(fn -> Enum.all?(pids, &(not process_running?(&1))) end, 3_000)
  end

  test "caller exit cancels an unbounded command tree" do
    marker = marker_path("owner")

    caller = spawn(fn -> run_long(shell_tree_command(marker)) end)

    on_exit(fn ->
      if Process.alive?(caller), do: Process.exit(caller, :kill)
      cleanup_marker(marker)
    end)

    assert wait_until(fn -> length(read_pids(marker)) == 2 end, 3_000)
    pids = read_pids(marker)

    Process.exit(caller, :kill)

    assert wait_until(fn -> Enum.all?(pids, &(not process_running?(&1))) end, 3_000)
  end

  test "long-task entry has no default wall-clock deadline" do
    assert %{exit: 0, output: "long-ok"} = run_long("sleep 0.15; printf long-ok")
  end

  test "host executor preserves cwd and strips provider secrets" do
    secret_name = "OPENROUTER_NEWBEE_COMMAND_TEST"
    System.put_env(secret_name, "must-not-leak")
    on_exit(fn -> System.delete_env(secret_name) end)

    command =
      "printf '%s\\n' \"$PWD\"; " <>
        "if [ -z \"${#{secret_name}+x}\" ]; then printf secret-unset; else printf secret-leaked; fi"

    assert %{exit: 0, output: output} = run_shell(command, timeout: 2_000)
    assert output == File.cwd!() <> "\nsecret-unset"
  end

  test "timeout rejects invalid values" do
    assert_raise ArgumentError, ~r/non-negative integer or :infinity/, fn ->
      run_shell("true", timeout: -1)
    end
  end

  defp command_module do
    String.to_existing_atom("Elixir.Newbee.Tools." <> "Run")
  end

  defp run_shell(command, opts), do: apply(command_module(), :sh, [command, opts])
  defp run_long(command), do: apply(command_module(), :sh, [command, [timeout: :infinity]])

  defp marker_path(kind) do
    Path.join(
      System.tmp_dir!(),
      "newbee-command-#{kind}-#{System.unique_integer([:positive, :monotonic])}.pid"
    )
  end

  defp shell_tree_command(marker) do
    marker = shell_quote(marker)
    "printf '%s\\n' \"$$\" > #{marker}; sleep 30 & printf '%s\\n' \"$!\" >> #{marker}; wait"
  end

  defp shell_quote(value), do: "'" <> String.replace(value, "'", "'\\''") <> "'"

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
