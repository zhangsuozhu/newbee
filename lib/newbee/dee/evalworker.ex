defmodule Newbee.DEE.EvalWorker do
  @moduledoc """
  求值工人：持有持久 binding、执行 cell、捕获 stdout。
  可跑在本 VM 或求值器节点（§3.4）——Evaluator 负责路由。
  """
  use GenServer

  @default_output_limit 1_048_576
  @default_heap_bytes 256 * 1024 * 1024
  @sample_interval 100

  @doc false
  def default_timeout, do: Newbee.DEE.EvalJob.default_timeout()
  @doc false
  def max_timeout, do: Newbee.DEE.EvalJob.max_timeout()
  @doc false
  def default_reductions_limit, do: Newbee.DEE.EvalJob.default_reductions_limit()

  @active_key :newbee_eval_active_task

  defstruct binding: [], count: 0, quiesced: false, cwd: nil, active: nil

  @doc false
  def active_job(key), do: :persistent_term.get({@active_key, key}, nil)

  @doc false
  def active_pid(key) do
    case active_job(key) do
      %{pid: pid} when is_pid(pid) ->
        if Process.alive?(pid) do
          pid
        else
          erase_active(key)
          nil
        end

      pid when is_pid(pid) ->
        if Process.alive?(pid) do
          pid
        else
          erase_active(key)
          nil
        end

      _ ->
        nil
    end
  end

  defp erase_active(key) do
    try do
      :persistent_term.erase({@active_key, key})
    rescue
      _ -> :ok
    catch
      _, _ -> :ok
    end
  end

  @doc false
  def clear_active(key, job_id, pid) do
    case :persistent_term.get({@active_key, key}, nil) do
      %{job_id: ^job_id, pid: ^pid} -> :persistent_term.erase({@active_key, key})
      ^pid when job_id == :legacy -> :persistent_term.erase({@active_key, key})
      _ -> :ok
    end

    :ok
  end

  @doc false
  def clear_active(key, pid), do: clear_active(key, :legacy, pid)

  @doc false
  def register_active(key, job_id, pid) when is_pid(pid) do
    case :persistent_term.get({@active_key, key}, nil) do
      %{pid: old_pid, job_id: old_job} when is_pid(old_pid) ->
        if old_pid != pid and Process.alive?(old_pid) and old_job != job_id do
          Newbee.DebugLog.log(:node, "active registration overwrites live job")
        end

        :ok

      _ ->
        :ok
    end

    :persistent_term.put(
      {@active_key, key},
      %{
        job_id: job_id,
        pid: pid,
        node: node(pid),
        registered_at: System.monotonic_time(:millisecond)
      }
    )

    :ok
  end

  @doc false
  def register_active(key, pid), do: register_active(key, :legacy, pid)

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts)
  def start(opts \\ []), do: GenServer.start(__MODULE__, opts)

  @impl true
  def init(opts) do
    requested = Keyword.get(opts, :cwd)

    with {:ok, cwd} <- normalize_cwd(requested),
         :ok <- restore_cwd(cwd) do
      {:ok, %__MODULE__{cwd: cwd}}
    else
      {:error, reason} -> {:stop, {:invalid_cwd, requested, reason}}
    end
  end

  @impl true
  def handle_call({:eval, _code, _opts}, _from, %{quiesced: true} = state) do
    {:reply,
     %{
       status: :error,
       error: "generation quiescing (switch in progress)",
       output: "",
       warnings: "",
       quiesced: true
     }, state}
  end

  def handle_call({:eval, _code, _opts}, _from, %{active: active} = state)
      when not is_nil(active) do
    {:reply, %{status: :error, error: "evaluator busy", output: "", warnings: ""}, state}
  end

  def handle_call({:eval, code, opts}, from, state) do
    case restore_cwd(state.cwd) do
      :ok ->
        timeout = normalize_timeout(Keyword.get(opts, :timeout, default_timeout()))
        job_id = Keyword.get(opts, :job_id, new_job_id())
        parent = self()

        {runner, monitor} =
          spawn_monitor(fn ->
            owners = [
              self(),
              parent,
              elem(from, 0)
              | List.wrap(Keyword.get(opts, :cancel_owners) || Keyword.get(opts, :cancel_owner))
            ]

            job_opts =
              opts
              |> Keyword.put(:job_id, job_id)
              |> Keyword.put(:cancel_owners, Enum.uniq(owners))

            result = run_cell(code, state.binding, timeout, state.count, job_opts)
            send(parent, {:eval_job_finished, job_id, self(), result})
          end)

        active = %{job_id: job_id, runner: runner, monitor: monitor, from: from, timeout: timeout}
        {:noreply, %{state | active: active}}

      {:error, reason} ->
        result = %{
          status: :error,
          error: "session working directory unavailable: #{inspect(state.cwd)} (#{inspect(reason)})",
          output: "",
          warnings: "",
          cwd: current_cwd()
        }

        {:reply, result, state}
    end
  end

  def handle_call({:cancel, job_id}, _from, %{active: %{job_id: job_id, runner: runner}} = state) do
    Process.exit(runner, :kill)
    {:reply, :ok, state}
  end

  def handle_call({:cancel, _job_id}, _from, state), do: {:reply, {:error, :not_active}, state}

  def handle_call(:quiesce, _from, state), do: {:reply, :ok, %{state | quiesced: true}}
  def handle_call(:unquiesce, _from, state), do: {:reply, :ok, %{state | quiesced: false}}
  def handle_call(:bindings_summary, _from, state), do: {:reply, summarize(state.binding), state}
  def handle_call(:dump_bindings, _from, state), do: {:reply, state.binding, state}

  def handle_call({:set_cwd, _cwd}, _from, %{active: active} = state) when not is_nil(active) do
    {:reply, {:error, :busy}, state}
  end

  def handle_call({:set_cwd, cwd}, _from, state) when is_binary(cwd) do
    with {:ok, expanded} <- normalize_cwd(cwd),
         :ok <- restore_cwd(expanded) do
      {:reply, :ok, %{state | cwd: expanded}}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:set_cwd, nil}, _from, state), do: {:reply, :ok, %{state | cwd: nil}}

  def handle_call({:restore_bindings, _binding}, _from, %{active: active} = state)
      when not is_nil(active) do
    {:reply, {:error, :busy}, state}
  end

  def handle_call({:restore_bindings, binding}, _from, state),
    do: {:reply, :ok, %{state | binding: binding}}

  @impl true
  def handle_info(
        {:eval_job_finished, job_id, runner, {result, new_binding, count}},
        %{active: %{job_id: job_id, runner: runner} = active} = state
      ) do
    Process.demonitor(active.monitor, [:flush])
    result = Map.put(result, :cwd, current_cwd())
    {new_binding, _evicted} = maybe_gc(new_binding, count)
    GenServer.reply(active.from, result)
    {:noreply, %{state | binding: new_binding, count: count, active: nil}}
  end

  def handle_info(
        {:DOWN, monitor, :process, runner, reason},
        %{active: %{monitor: monitor, runner: runner} = active} = state
      ) do
    error =
      if reason == :killed, do: "interrupted", else: "cell runner exited: #{inspect(reason)}"

    GenServer.reply(active.from, %{
      status: :error,
      error: error,
      output: "",
      warnings: "",
      outcome_unknown: reason != :killed
    })

    {:noreply, %{state | count: state.count + 1, active: nil}}
  end

  def handle_info({:eval_job_finished, _job_id, _runner, _result}, state), do: {:noreply, state}
  def handle_info({:DOWN, _monitor, :process, _runner, _reason}, state), do: {:noreply, state}

  defp new_job_id, do: {System.unique_integer([:positive, :monotonic]), make_ref()}
  defp normalize_timeout(:infinity), do: default_timeout()

  defp normalize_timeout(value) when is_integer(value) and value >= 0,
    do: min(value, max_timeout())

  defp normalize_timeout(value),
    do: raise(ArgumentError, "invalid eval timeout: #{inspect(value)}")

  defp positive_limit(value, _default) when is_integer(value) and value > 0, do: value
  defp positive_limit(_value, default), do: default

  defp normalize_cwd(nil), do: {:ok, nil}

  defp normalize_cwd(cwd) when is_binary(cwd) do
    expanded = Path.expand(cwd)
    if File.dir?(expanded), do: {:ok, expanded}, else: {:error, :enoent}
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp restore_cwd(nil), do: :ok
  defp restore_cwd(cwd), do: File.cd(cwd)

  defp current_cwd do
    case File.cwd() do
      {:ok, cwd} -> cwd
      {:error, _} -> nil
    end
  end

  # ── cell 执行 ──

  def run_cell(code, binding, timeout, count, opts \\ []) do
    timeout = normalize_timeout(timeout)
    job_id = Keyword.get(opts, :job_id, new_job_id())
    interrupt_key = Keyword.get(opts, :interrupt_key)
    interrupt_node = Keyword.get(opts, :interrupt_node, Node.self())

    reductions_limit =
      positive_limit(Keyword.get(opts, :reductions_limit), default_reductions_limit())

    output_limit = positive_limit(Keyword.get(opts, :output_limit), @default_output_limit)
    heap_bytes = positive_limit(Keyword.get(opts, :max_heap_bytes), @default_heap_bytes)

    task =
      Task.async(fn ->
        register_remote_active(interrupt_node, interrupt_key, job_id, self())

        Process.flag(:max_heap_size, %{
          size: div(heap_bytes, :erlang.system_info(:wordsize)),
          kill: true
        })

        media_capability = opts[:media_capability]
        if is_binary(media_capability), do: Process.put({Newbee.Tools.Media, :capability}, media_capability)

        # collaboration capability 也必须在实际执行代码的 cell Task 内注入；
        # 前一个 eval 的进程字典不会跨 Task 存活。
        collaboration_capability = opts[:collaboration_capability]

        if is_binary(collaboration_capability) do
          Process.put({Newbee.Tools.Hive, :context}, %{capability: collaboration_capability})
        end

        {:ok, io} = Newbee.DEE.BoundedIO.start_link(output_limit)
        Process.group_leader(self(), io)

        try do
          outcome =
            try do
              {value, new_binding} = Code.eval_string(code, binding, file: "cell_#{count}")
              {:ok, value, new_binding}
            rescue
              e -> {:error, Exception.format(:error, e, __STACKTRACE__)}
            catch
              kind, reason -> {:error, "#{kind}: #{safe_inspect(reason)}"}
            end

          {outcome, Newbee.DEE.BoundedIO.contents(io)}
        after
          Newbee.DEE.BoundedIO.stop(io)
          clear_remote_active(interrupt_node, interrupt_key, job_id, self())
          if is_binary(media_capability), do: Process.delete({Newbee.Tools.Media, :capability})
          if is_binary(collaboration_capability), do: Process.delete({Newbee.Tools.Hive, :context})
        end
      end)

    Process.unlink(task.pid)
    owners = List.wrap(Keyword.get(opts, :cancel_owners) || Keyword.get(opts, :cancel_owner))
    watcher = start_owner_watcher(owners, task.pid)
    result = await_cell(task, timeout, reductions_limit)
    if watcher, do: send(watcher, :stop)
    clear_remote_active(interrupt_node, interrupt_key, job_id, task.pid)

    case result do
      {:ok, {outcome, out}} ->
        case outcome do
          {:ok, value, new_binding} ->
            {warnings, clean_out} = split_warnings(out)

            {%{status: :ok, value: safe_inspect(value), output: clean_out, warnings: warnings}, new_binding, count + 1}

          {:error, msg} ->
            {warnings, clean_out} = split_warnings(out)
            {extra_w, clean_err} = split_warnings(msg)
            warnings = if extra_w != "", do: warnings <> "\n" <> extra_w, else: warnings

            {%{status: :error, error: clean_err, output: clean_out, warnings: warnings}, binding, count + 1}
        end

      {:error, :timeout} ->
        Task.shutdown(task, :brutal_kill)

        {%{
           status: :error,
           error: "timeout after #{timeout}ms",
           output: "",
           warnings: "",
           recycle_node: true
         }, binding, count + 1}

      {:error, :reductions} ->
        Task.shutdown(task, :brutal_kill)

        {%{
           status: :error,
           error: "execution budget exceeded (reductions)",
           output: "",
           warnings: "",
           recycle_node: true
         }, binding, count + 1}

      {:exit, :killed} ->
        {%{status: :error, error: "interrupted", output: "", warnings: "", recycle_node: true}, binding, count + 1}

      {:exit, reason} ->
        {%{
           status: :error,
           error: "cell task exited: #{inspect(reason)}",
           output: "",
           warnings: ""
         }, binding, count + 1}
    end
  end

  defp await_cell(task, timeout, reductions_limit) do
    deadline = System.monotonic_time(:millisecond) + timeout
    await_cell_until(task, deadline, reductions_limit)
  end

  defp await_cell_until(task, deadline, reductions_limit) do
    remaining = deadline - System.monotonic_time(:millisecond)
    wait = min(max(remaining, 0), @sample_interval)

    case Task.yield(task, wait) do
      {:ok, result} ->
        {:ok, result}

      {:exit, reason} ->
        {:exit, reason}

      nil when remaining <= 0 ->
        {:error, :timeout}

      nil ->
        reductions =
          case Process.info(task.pid, :reductions) do
            {:reductions, value} -> value
            _ -> 0
          end

        if reductions >= reductions_limit,
          do: {:error, :reductions},
          else: await_cell_until(task, deadline, reductions_limit)
    end
  end

  # 监控全部 owner（调用者 + Evaluator）与 cell 本身；任一 owner 退出即杀 cell，
  # cell 结束或被叫停时 watcher 自行退出，不泄漏进程。
  defp start_owner_watcher(owners, task_pid) do
    owners = owners |> Enum.filter(&is_pid/1) |> Enum.uniq()

    if owners == [] do
      nil
    else
      spawn(fn ->
        owner_refs = Map.new(owners, &{Process.monitor(&1), &1})
        task_ref = Process.monitor(task_pid)
        owner_watch_loop(owner_refs, task_ref, task_pid)
      end)
    end
  end

  defp owner_watch_loop(owner_refs, task_ref, task_pid) do
    receive do
      {:DOWN, ref, :process, _pid, _reason} ->
        cond do
          ref == task_ref ->
            :ok

          Map.has_key?(owner_refs, ref) ->
            if Process.alive?(task_pid), do: Process.exit(task_pid, :kill)

          true ->
            owner_watch_loop(owner_refs, task_ref, task_pid)
        end

      :stop ->
        :ok
    end
  end

  # 编译 warning 单独拆出：BEAM 的 warning: 行 + 后续缩进行归一处，transcript 只留徽标
  defp split_warnings(text) when is_binary(text) do
    lines = String.split(text, "\n")
    {warnings, clean} = Enum.split_with(lines, &String.starts_with?(&1, "warning:"))
    {Enum.join(warnings, "\n"), Enum.join(clean, "\n") |> String.trim_leading("\n")}
  end

  defp split_warnings(other), do: {"", to_string(other)}
  defp register_remote_active(_node, key, _job_id, _pid) when is_nil(key), do: :ok

  defp register_remote_active(node, key, job_id, pid) do
    if node == Node.self() do
      register_active(key, job_id, pid)
    else
      :rpc.call(node, __MODULE__, :register_active, [key, job_id, pid])
    end
  end

  defp clear_remote_active(_node, key, _job_id, _pid) when is_nil(key), do: :ok

  defp clear_remote_active(node, key, job_id, pid) do
    if node == Node.self() do
      clear_active(key, job_id, pid)
    else
      :rpc.call(node, __MODULE__, :clear_active, [key, job_id, pid])
    end
  end

  # GC 失败绝不拖累 cell（绑定保活优先）
  defp maybe_gc(binding, count) do
    Newbee.Environment.BindingGC.maybe_gc(binding, count)
  rescue
    _ -> {binding, []}
  catch
    _, _ -> {binding, []}
  end

  def summarize(binding) do
    Enum.map(binding, fn {name, value} ->
      %{name: name, type: type_of(value), size: byte_size(safe_inspect(value))}
    end)
  end

  defp type_of(v) when is_binary(v), do: :binary
  defp type_of(v) when is_list(v), do: :list
  defp type_of(v) when is_map(v), do: :map
  defp type_of(v) when is_tuple(v), do: :tuple
  defp type_of(v) when is_atom(v), do: :atom
  defp type_of(v) when is_number(v), do: :number
  defp type_of(v) when is_pid(v), do: :pid
  defp type_of(v) when is_function(v), do: :function
  defp type_of(_), do: :other

  @max_inspect 10_000
  defp safe_inspect(v) do
    s = inspect(v, limit: 100, printable_limit: @max_inspect)
    if byte_size(s) > @max_inspect, do: binary_part(s, 0, @max_inspect) <> "…(truncated)", else: s
  end
end
