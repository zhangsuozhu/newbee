defmodule Newbee.Host.Command do
  @moduledoc """
  Ring0 shell job executor.

  A command runs in its own OS process group. The job monitors both the
  requesting evaluator cell and the local waiter, so timeout, interrupt, peer
  loss, or caller exit tears down the whole command tree.
  """

  @env_deny_prefixes ~w(OPENROUTER_ DEEPSEEK_ ANTHROPIC_ OPENAI_)
  @env_deny_suffixes ~w(_KEY _TOKEN _SECRET)
  @output_head_bytes 16_000
  @term_grace_ms 200
  @pidfile_attempts 20

  @doc false
  def run(owner, cmd, timeout, cwd)
      when is_pid(owner) and is_binary(cmd) and is_binary(cwd) do
    waiter = self()
    ref = make_ref()

    {_job, monitor} =
      spawn_monitor(fn ->
        execute(waiter, owner, ref, cmd, timeout, cwd)
      end)

    receive do
      {^ref, result} ->
        Process.demonitor(monitor, [:flush])
        result

      {:DOWN, ^monitor, :process, _pid, reason} ->
        receive do
          {^ref, result} -> result
        after
          0 -> error_result("shell job exited before returning a result: #{inspect(reason)}")
        end
    end
  end

  defp execute(waiter, owner, ref, cmd, timeout, cwd) do
    cancel_refs = MapSet.new([Process.monitor(owner), Process.monitor(waiter)])

    case open_shell(cmd, cwd) do
      {:ok, job} ->
        try do
          collect(job, waiter, ref, cancel_refs, deadline(timeout), {"", "", 0})
        after
          if job.pidfile, do: File.rm(job.pidfile)
        end

      {:error, reason} ->
        send(waiter, {ref, error_result("cannot start shell job: #{inspect(reason)}")})
    end
  end

  defp open_shell(cmd, cwd) do
    shell = System.find_executable("sh") || "/bin/sh"

    case System.find_executable("setsid") do
      nil ->
        open_port(shell, ["-c", cmd], cwd, nil, false)

      setsid ->
        pidfile =
          Path.join(
            System.tmp_dir!(),
            "newbee-shell-#{System.unique_integer([:positive, :monotonic])}.pid"
          )

        wrapper = ~S|printf '%s\n' "$$" > "$1"; exec "$2" -c "$3"|
        args = ["--wait", shell, "-c", wrapper, "newbee-shell", pidfile, shell, cmd]
        open_port(setsid, args, cwd, pidfile, true)
    end
  rescue
    e -> {:error, Exception.message(e)}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp open_port(executable, args, cwd, pidfile, isolated?) do
    port =
      Port.open(
        {:spawn_executable, executable},
        [
          :binary,
          :exit_status,
          :stderr_to_stdout,
          args: args,
          cd: String.to_charlist(cwd),
          env: sensitive_env_unsets()
        ]
      )

    case Port.info(port, :os_pid) do
      {:os_pid, os_pid} ->
        {:ok, %{port: port, os_pid: os_pid, pidfile: pidfile, isolated?: isolated?}}

      nil ->
        {:ok, %{port: port, os_pid: nil, pidfile: pidfile, isolated?: isolated?}}
    end
  end

  defp sensitive_env_unsets do
    System.get_env()
    |> Map.keys()
    |> Enum.filter(&sensitive_env?/1)
    |> Enum.map(&{String.to_charlist(&1), false})
  end

  defp sensitive_env?(name) do
    Enum.any?(@env_deny_prefixes, &String.starts_with?(name, &1)) or
      Enum.any?(@env_deny_suffixes, &String.ends_with?(name, &1))
  end

  defp deadline(:infinity), do: :infinity
  defp deadline(timeout), do: System.monotonic_time(:millisecond) + timeout

  defp collect(job, waiter, ref, cancel_refs, :infinity, buffer) do
    receive do
      {port, {:data, data}} when port == job.port ->
        collect(job, waiter, ref, cancel_refs, :infinity, push_output(buffer, data))

      {port, {:exit_status, status}} when port == job.port ->
        send_result(waiter, ref, status, buffer)

      {:DOWN, down_ref, :process, _pid, _reason} ->
        if MapSet.member?(cancel_refs, down_ref) do
          terminate(job)
        else
          collect(job, waiter, ref, cancel_refs, :infinity, buffer)
        end
    end
  end

  defp collect(job, waiter, ref, cancel_refs, deadline, buffer) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {port, {:data, data}} when port == job.port ->
        collect(job, waiter, ref, cancel_refs, deadline, push_output(buffer, data))

      {port, {:exit_status, status}} when port == job.port ->
        send_result(waiter, ref, status, buffer)

      {:DOWN, down_ref, :process, _pid, _reason} ->
        if MapSet.member?(cancel_refs, down_ref) do
          terminate(job)
        else
          collect(job, waiter, ref, cancel_refs, deadline, buffer)
        end
    after
      remaining ->
        terminate(job)
        send_result(waiter, ref, :timeout, buffer)
    end
  end

  defp send_result(waiter, ref, status, buffer) do
    output = bounded_output(buffer)
    send(waiter, {ref, %{exit: status, exit_code: status, output: output}})
  end

  # 固定头尾缓冲：头保留前 16KB，尾用滑动窗口保留最后 16KB。
  # 内存占用与命令输出量无关，跑几小时的构建也不会撑爆 Ring0。
  defp push_output({head, tail, dropped}, data) do
    head = take_head(head, data)
    {tail, dropped} = take_tail(tail, data, dropped)
    {head, tail, dropped}
  end

  defp take_head(head, _data) when byte_size(head) >= @output_head_bytes, do: head

  defp take_head(head, data) do
    need = @output_head_bytes - byte_size(head)
    head <> binary_part(data, 0, min(need, byte_size(data)))
  end

  defp take_tail(tail, data, dropped) do
    combined = tail <> data

    if byte_size(combined) <= @output_head_bytes do
      {combined, dropped}
    else
      keep = binary_part(combined, byte_size(combined) - @output_head_bytes, @output_head_bytes)
      {keep, dropped + byte_size(combined) - @output_head_bytes}
    end
  end

  defp bounded_output({_head, tail, 0}), do: tail

  defp bounded_output({head, tail, dropped}) do
    head <> "\n… [输出截断: 省略 " <> to_string(dropped) <> " bytes] …\n" <> tail
  end

  defp error_result(message), do: %{exit: 127, exit_code: 127, output: message}

  defp terminate(%{isolated?: true} = job) do
    case wait_for_pidfile(job.pidfile, @pidfile_attempts) do
      nil -> terminate_process_tree(job.os_pid)
      pgid -> terminate_process_group(pgid, job.os_pid)
    end

    close_port(job.port)
  end

  defp terminate(job) do
    terminate_process_tree(job.os_pid)
    close_port(job.port)
  end

  defp wait_for_pidfile(_path, 0), do: nil

  defp wait_for_pidfile(path, attempts) do
    case File.read(path) do
      {:ok, body} ->
        case Integer.parse(String.trim(body)) do
          {pid, ""} when pid > 1 -> pid
          _ -> nil
        end

      _ ->
        Process.sleep(5)
        wait_for_pidfile(path, attempts - 1)
    end
  end

  defp terminate_process_group(pgid, fallback_pid) do
    if isolated_group?(pgid) do
      signal_group(pgid, "TERM")
      Process.sleep(@term_grace_ms)
      if group_alive?(pgid), do: signal_group(pgid, "KILL")
    else
      terminate_process_tree(fallback_pid)
    end
  end

  defp isolated_group?(pid) do
    case System.cmd("ps", ["-o", "pgid=,sid=", "-p", Integer.to_string(pid)], stderr_to_stdout: true) do
      {output, 0} -> String.split(output) == [Integer.to_string(pid), Integer.to_string(pid)]
      _ -> false
    end
  rescue
    _ -> false
  end

  defp group_alive?(pgid) do
    case System.cmd("kill", ["-0", "--", "-#{pgid}"], stderr_to_stdout: true) do
      {_output, 0} -> true
      _ -> false
    end
  rescue
    _ -> false
  end

  defp signal_group(pgid, signal) do
    System.cmd("kill", ["-#{signal}", "--", "-#{pgid}"], stderr_to_stdout: true)
    :ok
  rescue
    _ -> :ok
  end

  defp terminate_process_tree(nil), do: :ok

  defp terminate_process_tree(root) do
    pids = descendants(root) ++ [root]
    signal_pids(pids, "TERM")
    Process.sleep(@term_grace_ms)
    signal_pids(Enum.filter(pids, &pid_alive?/1), "KILL")
  end

  defp descendants(root) do
    case System.cmd("ps", ["-eo", "pid=,ppid="], stderr_to_stdout: true) do
      {output, 0} ->
        children =
          output
          |> String.split("\n", trim: true)
          |> Enum.reduce(%{}, fn line, acc ->
            case String.split(line) do
              [pid, ppid] ->
                Map.update(
                  acc,
                  String.to_integer(ppid),
                  [String.to_integer(pid)],
                  &[String.to_integer(pid) | &1]
                )

              _ ->
                acc
            end
          end)

        collect_descendants(children, [root], MapSet.new())

      _ ->
        []
    end
  rescue
    _ -> []
  end

  defp collect_descendants(_children, [], seen), do: MapSet.to_list(seen)

  defp collect_descendants(children, [pid | rest], seen) do
    next = Map.get(children, pid, []) |> Enum.reject(&MapSet.member?(seen, &1))
    collect_descendants(children, next ++ rest, Enum.reduce(next, seen, &MapSet.put(&2, &1)))
  end

  defp signal_pids([], _signal), do: :ok

  defp signal_pids(pids, signal) do
    System.cmd("kill", ["-#{signal}" | Enum.map(pids, &Integer.to_string/1)], stderr_to_stdout: true)

    :ok
  rescue
    _ -> :ok
  end

  defp pid_alive?(pid) do
    case System.cmd("kill", ["-0", Integer.to_string(pid)], stderr_to_stdout: true) do
      {_output, 0} -> true
      _ -> false
    end
  rescue
    _ -> false
  end

  defp close_port(port) do
    if Port.info(port), do: Port.close(port)
    :ok
  rescue
    _ -> :ok
  end
end
