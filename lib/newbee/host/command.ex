defmodule Newbee.Host.Command do
  @moduledoc """
  Ring0 shell job executor.

  A command runs in its own OS process group. The job monitors both the
  requesting evaluator cell and the local waiter, so timeout, interrupt, peer
  loss, or caller exit tears down the whole command tree.
  """

  @env_deny_prefixes ~w(OPENROUTER_ DEEPSEEK_ ANTHROPIC_ OPENAI_)
  @env_deny_suffixes ~w(_KEY _TOKEN _SECRET)
  # NEWBEE_CWD 是启动器注入的 launch-dir, 子进程必须用显式 cd cwd 运行,
  # 继承它会导致 worktree/DEE 会话漂回主仓 (进化提案根因: 子进程目录漂移)。
  @env_deny_exact ~w(NEWBEE_CWD)
  @output_head_bytes 16_000
  # 头尾各自 16KB（合计 32KB 预算）；窗口内可精确重建的区间不算截断。
  @output_tail_bytes 16_000

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
          collect(job, waiter, ref, cancel_refs, deadline(timeout), new_buffer())
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
    name in @env_deny_exact or
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
          abort_buffer(buffer)
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
          abort_buffer(buffer)
        else
          collect(job, waiter, ref, cancel_refs, deadline, buffer)
        end
    after
      remaining ->
        terminate(job)
        send_result(waiter, ref, :timeout, buffer)
    end
  end

  defp abort_buffer(%{spill: spill}), do: Newbee.Spill.abort(spill)
  defp abort_buffer(_buffer), do: :ok

  defp send_result(waiter, ref, status, buffer) do
    output = bounded_output(buffer)
    send(waiter, {ref, %{exit: status, exit_code: status, output: output}})
  end

  # 固定头尾缓冲 + 同步流式落盘。内存占用与命令输出量无关（跑几小时的构建也不会
  # 撑爆 Ring0），但被截掉的原文一律先按内容寻址落盘，标记里给出回读句柄——
  # 于是模型既省了上下文，又不会连"为什么失败"都看不到。
  defp push_output(buffer, data) do
    %{
      buffer
      | window: Newbee.Truncate.Window.push(buffer.window, data),
        spill: spill_push(buffer.spill, data)
    }
  end

  defp new_buffer do
    %{
      window: Newbee.Truncate.Window.new(@output_head_bytes, @output_tail_bytes),
      spill: spill_open("host_command")
    }
  end

  defp bounded_output(%{window: window} = buffer) do
    case Newbee.Truncate.Window.render(window, handle: spill_finish_if_dropped(buffer)) do
      %{text: text} -> text
    end
  end

  # 没丢字节就不必留对象（否则每条短命令都会产生一个 spill 文件）。
  defp spill_finish_if_dropped(%{window: %{total: total}, spill: spill}) do
    if total <= spill_keep_bytes() do
      spill_abort(spill)
      nil
    else
      spill_finish(spill)
    end
  end

  defp spill_keep_bytes, do: @output_head_bytes + @output_tail_bytes

  # spill 永远是可选的：拿不到句柄就不落盘，绝不因此让命令失败（fail-open）。
  defp spill_open(source) do
    case Newbee.Spill.open_stream(source: source) do
      {:ok, handle} -> handle
      {:error, _reason} -> nil
    end
  rescue
    _ -> nil
  catch
    _kind, _reason -> nil
  end

  defp spill_push(nil, _data), do: nil
  defp spill_push(handle, data), do: Newbee.Spill.push(handle, data)

  defp spill_finish(nil), do: nil

  defp spill_finish(handle) do
    case Newbee.Spill.finish(handle) do
      {:ok, info} -> info
      {:error, _reason} -> nil
    end
  rescue
    _ -> nil
  catch
    _kind, _reason -> nil
  end

  defp spill_abort(nil), do: :ok
  defp spill_abort(handle), do: Newbee.Spill.abort(handle)

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
