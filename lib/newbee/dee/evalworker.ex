defmodule Newbee.DEE.EvalWorker do
  @moduledoc """
  求值工人：持有持久 binding、执行 cell、捕获 stdout。
  可跑在本 VM 或求值器节点（§3.4）——Evaluator 负责路由。
  """
  use GenServer

  @default_timeout :infinity

  @doc false
  def default_timeout, do: @default_timeout
  @active_key :newbee_eval_active_task

  defstruct binding: [], count: 0, quiesced: false

  @doc false
  def active_pid(key) do
    :persistent_term.get({@active_key, key}, nil)
  end

  @doc false
  def clear_active(key, pid) do
    active_key = {@active_key, key}

    if :persistent_term.get(active_key, nil) == pid do
      :persistent_term.erase(active_key)
    end

    :ok
  end

  @doc false
  def register_active(key, pid), do: :persistent_term.put({@active_key, key}, pid)

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts)
  def start(opts \\ []), do: GenServer.start(__MODULE__, opts)

  @impl true
  def init(_), do: {:ok, %__MODULE__{}}

  @impl true
  def handle_call({:eval, _code, _opts}, _from, %{quiesced: true} = state) do
    # Binding Continuity step 0（§4.4 quiesce）：静默期拒收新 step
    {:reply,
     %{status: :error, error: "generation quiescing (switch in progress)", output: "", warnings: "", quiesced: true},
     state}
  end

  def handle_call({:eval, code, opts}, _from, state) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    {result, new_binding, count} = run_cell(code, state.binding, timeout, state.count, opts)
    # §9.1：绑定 GC——LRU + 大小预算，冷值逐出为 ArtifactRef（pin 不动）
    {new_binding, _evicted} = maybe_gc(new_binding, count)
    {:reply, result, %{state | binding: new_binding, count: count}}
  end

  def handle_call(:quiesce, _from, state), do: {:reply, :ok, %{state | quiesced: true}}
  def handle_call(:unquiesce, _from, state), do: {:reply, :ok, %{state | quiesced: false}}

  def handle_call(:bindings_summary, _from, state) do
    {:reply, summarize(state.binding), state}
  end

  def handle_call(:dump_bindings, _from, state) do
    {:reply, state.binding, state}
  end

  def handle_call({:set_cwd, cwd}, _from, state) when is_binary(cwd) do
    reply =
      case File.cd(cwd) do
        :ok -> :ok
        {:error, reason} -> {:error, reason}
      end

    {:reply, reply, state}
  end

  def handle_call({:set_cwd, nil}, _from, state), do: {:reply, :ok, state}

  def handle_call({:restore_bindings, binding}, _from, state) do
    {:reply, :ok, %{state | binding: binding}}
  end

  # ── cell 执行 ──

  def run_cell(code, binding, timeout, count, opts \\ []) do
    parent = self()
    interrupt_key = Keyword.get(opts, :interrupt_key)
    interrupt_node = Keyword.get(opts, :interrupt_node, Node.self())

    task =
      Task.async(fn ->
        register_remote_active(interrupt_node, interrupt_key, self())

        # 当前 cell 的媒体能力令牌：由 Agent.Loop 在主节点签发，
        # 只在本次 cell 进程中短暂可见；Tools.Media 会回主节点校验令牌。
        media_capability = opts[:media_capability]
        if is_binary(media_capability), do: Process.put({Newbee.Tools.Media, :capability}, media_capability)

        try do
          {:ok, io} = StringIO.open("")
          Process.group_leader(self(), io)

          outcome =
            try do
              {value, new_binding} = Code.eval_string(code, binding, file: "cell_#{count}")
              {:ok, value, new_binding}
            rescue
              e -> {:error, Exception.format(:error, e, __STACKTRACE__)}
            catch
              kind, reason -> {:error, "#{kind}: #{safe_inspect(reason)}"}
            end

          {_in, out} = StringIO.contents(io)
          GenServer.stop(io, :normal, 5_000)
          send(parent, {:cell_done, self(), outcome, out})
        after
          clear_remote_active(interrupt_node, interrupt_key, self())
          if is_binary(media_capability), do: Process.delete({Newbee.Tools.Media, :capability})
        end
      end)

    # Task.async/1 links the worker; unlink so cancellation kills only the cell,
    # not the long-lived EvalWorker GenServer that owns the bindings.
    Process.unlink(task.pid)

    cancel_owners = List.wrap(Keyword.get(opts, :cancel_owners) || Keyword.get(opts, :cancel_owner))
    watcher = start_owner_watcher(cancel_owners, task.pid)

    result =
      case Task.yield(task, timeout) do
        nil ->
          Task.shutdown(task, :brutal_kill)
          {%{status: :error, error: "timeout after #{timeout}ms", output: "", warnings: ""}, binding, count + 1}

        {:ok, _} ->
          receive do
            {:cell_done, _, {:ok, value, new_binding}, out} ->
              {warnings, clean_out} = split_warnings(out)

              {%{status: :ok, value: safe_inspect(value), output: clean_out, warnings: warnings}, new_binding,
               count + 1}

            {:cell_done, _, {:error, msg}, out} ->
              {warnings, clean_out} = split_warnings(out)
              # 异常里也可能含编译 warning 尾巴，统一拆出
              {extra_w, clean_err} = split_warnings(msg)
              warnings = if extra_w != "", do: warnings <> "\n" <> extra_w, else: warnings
              {%{status: :error, error: clean_err, output: clean_out, warnings: warnings}, binding, count + 1}
          after
            1_000 ->
              {%{status: :error, error: "cell result lost", output: "", warnings: ""}, binding, count + 1}
          end

        {:exit, :killed} ->
          {%{status: :error, error: "interrupted", output: "", warnings: ""}, binding, count + 1}

        {:exit, reason} ->
          {%{status: :error, error: "cell task exited: #{inspect(reason)}", output: "", warnings: ""}, binding,
           count + 1}
      end

    if watcher, do: send(watcher, :stop)
    clear_remote_active(interrupt_node, interrupt_key, task.pid)
    result
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
  defp register_remote_active(_node, key, _pid) when is_nil(key), do: :ok

  defp register_remote_active(node, key, pid) do
    if node == Node.self() do
      register_active(key, pid)
    else
      :rpc.call(node, __MODULE__, :register_active, [key, pid])
    end
  end

  defp clear_remote_active(_node, key, _pid) when is_nil(key), do: :ok

  defp clear_remote_active(node, key, pid) do
    if node == Node.self() do
      clear_active(key, pid)
    else
      :rpc.call(node, __MODULE__, :clear_active, [key, pid])
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
