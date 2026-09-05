defmodule Newbee.DEE.Evaluator do
  @moduledoc """
  求值器 (DESIGN §3.3/§3.4)：模型代码运行在**独立 BEAM 节点**（:peer 启动，同机分布式），
  主进程一对一监督：崩溃只杀节点，自动重启、当前调用重试一次；TUI/会话不受影响。

  **双节点冗余**：同时持有 primary + standby 两个 peer 节点。primary 死亡时
  立即切 standby（零等待），并异步补一个新 standby；standby 死亡也异步补位。
  节点启动失败不设上限——每次用随机新名字重建（"拉不来就生成一个新的"），
  由调用方冷却防抖，绝不永久 unavailable。

  - 绑定持久：存于求值器节点内的 EvalWorker，跨轮存活（节点切换后丢失，可接受）
  - env 过滤：节点启动后剥离 LLM 凭证（denylist 后缀/前缀）
  - reset 语义 = 重置 worker（或重建节点）
  - mode: :node（默认）| :local（调试/测试用本 VM）
  """
  use GenServer
  require Logger

  defstruct mode: :node,
            # primary（保持兼容旧字段名）
            peer: nil,
            node: nil,
            worker: nil,
            # standby：%{peer, node, worker} | nil
            standby: nil,
            # 后台 standby boot 任务（不阻塞 GenServer）
            standby_boot: nil,
            restarts: 0,
            boot_error: nil,
            last_boot_attempt: nil,
            # 会话稳定工作根；nil 仅供无会话的测试/诊断 evaluator。
            cwd: nil,
            # 受控诊断标签；节点名仍由系统补齐角色和随机后缀。
            node_label: "runtime",
            # 宿主进程（会话 kernel）：{pid, mref}；宿主死亡时求值器随停，
            # terminate → stop_all 释放 primary/standby peer 节点（epmd 不残留）
            owner: nil,
            active_job: nil,
            pending_evals: :queue.new()

  @env_deny_prefixes ~w(OPENROUTER_ DEEPSEEK_ ANTHROPIC_ OPENAI_)
  @env_deny_suffixes ~w(_KEY _TOKEN _SECRET)

  @peer_boot_timeout 60_000
  @rpc_boot_timeout 60_000
  @reboot_cooldown 5_000
  @standby_wait_timeout 60_000
  @standby_retry_ms 1_000
  @max_node_memory_bytes 1_500_000_000
  @max_node_processes 20_000
  @budget_rpc_timeout 500

  # ── API ──

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name))
  def start(opts), do: GenServer.start(__MODULE__, opts, name: Keyword.get(opts, :name))

  @doc "执行一段 Elixir 代码。binding 持久；节点崩溃自动切 standby，无可用节点时重建。"
  def eval(server, code, opts \\ []) do
    GenServer.call(server, {:eval, code, opts}, :infinity)
  end

  @doc "中断当前正在执行的求值 cell；不会影响求值器绑定或后续调用。"
  def interrupt(server \\ __MODULE__), do: interrupt(server, :current)

  def interrupt(server, job_id), do: GenServer.call(server, {:cancel_job, job_id}, 1000)

  def bindings_summary(server \\ __MODULE__, timeout \\ 5_000), do: GenServer.call(server, :bindings_summary, timeout)

  @doc "Binding Continuity step 0（§4.4）：进入静默——拒收新 step。"
  def quiesce(server \\ __MODULE__), do: GenServer.call(server, :quiesce, 30_000)

  @doc "取消静默（切换取消时恢复旧 generation 接流量）。"
  def unquiesce(server \\ __MODULE__), do: GenServer.call(server, :unquiesce, 30_000)
  def reset, do: reset(__MODULE__)
  def reset(server), do: GenServer.call(server, :reset, @rpc_boot_timeout)
  def dump_bindings(server \\ __MODULE__), do: GenServer.call(server, :dump_bindings)
  def restore_bindings(server \\ __MODULE__, binding), do: GenServer.call(server, {:restore_bindings, binding})

  @doc "节点信息（给 /dump 用）"
  def info(server \\ __MODULE__), do: GenServer.call(server, :info)

  @doc """
  登记宿主进程（会话 kernel）：宿主死亡（正常停止**或崩溃**）时求值器随之停止，
  terminate → stop_all 停掉 primary/standby peer 节点。只用于会话私有求值器——
  具名共享兜底求值器（Newbee.DEE.Evaluator）绝不可登记，否则一个会话结束会
  杀掉其它会话在用的求值器。
  """
  def monitor_owner(server, owner) when is_pid(owner), do: GenServer.cast(server, {:monitor_owner, owner})

  # ── init ──

  @impl true
  def init(opts) do
    mode = Keyword.get(opts, :mode, :node)

    # 初始化阶段保留 start_link 的父子取消语义；primary 就绪后才接管 peer EXIT。
    # 否则 bootstrap owner 的 :shutdown 会被排队并被通用 EXIT 分支忽略。

    # 会话工作目录是 evaluator 的稳定根；每个 cell 开始前由 EvalWorker 重新恢复。
    cwd_opt = Keyword.get(opts, :cwd) |> normalize_cwd()
    node_label = normalize_node_label(Keyword.get(opts, :node_label))
    base_state = %__MODULE__{mode: mode, cwd: cwd_opt, node_label: node_label}

    state =
      case mode do
        :local ->
          {:ok, worker} = Newbee.DEE.EvalWorker.start_link(cwd: cwd_opt)
          %{base_state | worker: worker}

        :node ->
          # 主备并行 boot：standby 提前开跑。boot 必须在独立进程跑（不阻塞
          # GenServer），但该进程必须**存活**——:peer 把 origin（调用
          # :peer.start_link 的进程）绑进 peer，origin 死则整个 peer BEAM
          # halt（peer.erl origin_link）。所以 spawn_standby_boot 返回的
          # keeper 在 boot 完成后继续存活，直到 peer 死或 evaluator 停。
          standby_boot = spawn_standby_boot(base_state)

          case boot_node(base_state) do
            {:ok, s} ->
              %{s | standby_boot: standby_boot}

            {:error, reason} ->
              Logger.error("evaluator node 初始启动失败: #{inspect(reason)}")
              %{base_state | boot_error: reason, standby_boot: standby_boot}
          end
      end

    if state.mode == :node, do: Process.flag(:trap_exit, true)

    if state.mode == :node do
      send(self(), :ensure_standby)
      send(self(), :reconcile_orphans)
    end

    {:ok, state}
  end

  # ── calls ──

  @impl true
  def handle_call({:eval, code, opts}, from, %{active_job: job} = state) when not is_nil(job) do
    if :queue.len(state.pending_evals) < 32 do
      {:noreply, %{state | pending_evals: :queue.in({from, code, opts}, state.pending_evals)}}
    else
      {:reply, %{status: :error, error: "evaluator queue full", output: "", warnings: ""}, state}
    end
  end

  def handle_call({:eval, code, opts}, from, state) do
    previous_restarts = state.restarts
    state = prepare_primary(state)
    restarted = state.restarts != previous_restarts

    case primary_target(state) do
      nil ->
        {:reply, %{status: :error, error: "evaluator unavailable; not started", output: "", warnings: ""}, state}

      target ->
        case check_node_budget(target) do
          :ok ->
            admit_eval(state, target, code, opts, from, restarted)

          {:error, :node_dead} ->
            state = isolate_failed_target(state, target)

            {:reply,
             %{
               status: :error,
               error: "evaluation outcome unknown; code was not replayed",
               output: "",
               warnings: "",
               outcome_unknown: true
             }, state}

          {:error, {:over_budget, _detail}} ->
            state = isolate_over_budget_primary(state, target)
            send(self(), :ensure_standby)

            {:reply,
             %{
               status: :error,
               error: "node over resource budget; recycled without replay",
               output: "",
               warnings: "",
               outcome_unknown: false
             }, state}
        end
    end
  end

  def handle_call({:cancel_job, requested}, _from, %{active_job: job} = state) do
    if job != nil and (requested == :current or requested == job.job_id) do
      send(job.guardian, {:cancel, job.job_id, :interrupted})
      cancel_cell(job)
      Process.send_after(self(), {:eval_deadline, job.job_id}, 1000)
      {:reply, :ok, %{state | active_job: %{job | reason: :interrupted}}}
    else
      {:reply, {:error, :not_active}, state}
    end
  end

  def handle_call(:bindings_summary, _from, state) do
    case remote_call(primary_target(state), :bindings_summary) do
      {:ok, summary} ->
        {:reply, summary, state}

      _dead_or_timeout ->
        case remote_call(state.standby, :bindings_summary) do
          {:ok, summary} -> {:reply, summary, promote_standby(state)}
          _dead_or_timeout -> {:reply, [], state}
        end
    end
  end

  def handle_call(:reset, _from, state) do
    state =
      case state.mode do
        :local ->
          GenServer.stop(state.worker)
          {:ok, w} = Newbee.DEE.EvalWorker.start_link(cwd: state.cwd)
          %{state | worker: w}

        :node ->
          stopped = stop_all(state)

          case boot_node(stopped) do
            {:ok, next} ->
              send(self(), :ensure_standby)
              next

            {:error, reason} ->
              %{stopped | boot_error: reason}
          end
      end

    {:reply, :ok, state}
  end

  def handle_call(:dump_bindings, _from, state) do
    case remote_call(primary_target(state), :dump_bindings) do
      {:ok, binding} -> {:reply, binding, state}
      _dead_or_timeout -> {:reply, [], state}
    end
  end

  def handle_call({:set_cwd, cwd}, _from, state) when is_binary(cwd) do
    cwd = normalize_cwd(cwd)
    targets = [primary_target(state), state.standby] |> Enum.reject(&is_nil/1)
    results = Enum.map(targets, &remote_call(&1, {:set_cwd, cwd}))

    if Enum.all?(results, &match?({:ok, :ok}, &1)) do
      {:reply, :ok, %{state | cwd: cwd}}
    else
      {:reply, {:error, {:cwd_unavailable, results}}, state}
    end
  end

  def handle_call({:restore_bindings, binding}, _from, state) do
    case remote_call(primary_target(state), {:restore_bindings, binding}) do
      {:ok, res} -> {:reply, res, state}
      _dead_or_timeout -> {:reply, {:error, :node_down}, state}
    end
  end

  def handle_call(:quiesce, _from, state) do
    case remote_call(primary_target(state), :quiesce) do
      {:ok, res} -> {:reply, res, state}
      _ -> {:reply, :ok, state}
    end
  end

  def handle_call(:unquiesce, _from, state) do
    case remote_call(primary_target(state), :unquiesce) do
      {:ok, res} -> {:reply, res, state}
      _ -> {:reply, :ok, state}
    end
  end

  def handle_call(:info, _from, state) do
    {:reply,
     %{
       mode: state.mode,
       node: state.node,
       peer: state.peer,
       cwd: state.cwd,
       restarts: state.restarts,
       alive: alive?(state),
       standby: standby_info(state),
       boot_error: state.boot_error,
       active_job: if(state.active_job, do: Map.take(state.active_job, [:job_id, :reason]), else: nil)
     }, state}
  end

  # ── cast ──

  @impl true
  def handle_cast({:monitor_owner, owner}, state) do
    {:noreply, %{state | owner: {owner, Process.monitor(owner)}}}
  end

  # ── info ──

  def handle_info(:reconcile_orphans, state) do
    _ = reconcile_orphans()
    {:noreply, state}
  end

  @impl true
  def handle_info({:guardian_cancel, id, reason}, %{active_job: %{job_id: id} = job} = state) do
    {:noreply, %{state | active_job: %{job | reason: reason}}}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{active_job: %{guardian_ref: ref}} = state) do
    {:noreply, fail_unknown_job(state)}
  end

  def handle_info({:eval_result, id, {:ok, result}}, %{active_job: %{job_id: id} = job} = state) when is_map(result) do
    result = if job.restarted, do: Map.put(result, :node_restarted, true), else: result

    result =
      case job.reason do
        :interrupted -> Map.merge(result, %{status: :error, error: "interrupted"})
        :timed_out -> Map.merge(result, %{status: :error, error: "timeout: execution lease expired"})
        _ -> result
      end

    {:noreply, finish_job(state, result)}
  end

  def handle_info({:eval_result, id, _unknown}, %{active_job: %{job_id: id}} = state) do
    {:noreply, fail_unknown_job(state)}
  end

  def handle_info({:DOWN, ref, :process, pid, _reason}, %{active_job: %{ref: ref, pid: pid}} = state) do
    {:noreply, fail_unknown_job(state)}
  end

  def handle_info({:eval_deadline, id}, %{active_job: %{job_id: id} = job} = state) do
    cancel_cell(job)
    Process.exit(job.pid, :kill)
    state = isolate_failed_primary(state, job)

    error =
      if job.reason == :interrupted,
        do: "interrupted",
        else: "evaluation outcome unknown after deadline; code was not replayed"

    {:noreply, finish_job(state, %{status: :error, error: error, output: "", warnings: "", outcome_unknown: true})}
  end

  # 宿主（会话 kernel）死亡：随停，terminate 释放 primary/standby peer 节点。
  # 覆盖 GenServer.stop 与崩溃两种死因——link 传不动的 :normal 停止也走这里。
  def handle_info({:DOWN, mref, :process, pid, reason}, %{owner: {pid, mref}} = state) do
    Newbee.DebugLog.log(:node, "owner down reason=#{inspect(reason)}; stopping evaluator node=#{inspect(state.node)}")
    {:stop, :normal, state}
  end

  def handle_info({:EXIT, pid, reason}, state) do
    cond do
      # primary 死：只清空 primary，不主动提升 standby——切换留给下一次调用
      # 的 :dead 回退路径（这样调用方能观察到 node_restarted=true 与
      # 新节点绑定丢失语义，见 evaluatornodetest/双节点冗余）。
      state.worker != nil and pid == state.peer ->
        Newbee.DebugLog.log(
          :node,
          "primary exited reason=#{inspect(reason)} node=#{inspect(state.node)} restarts=#{state.restarts}"
        )

        Logger.warning("evaluator primary node exited; standby will take over on next call")
        {:noreply, %{state | peer: nil, node: nil, worker: nil}}

      # standby 死
      state.standby != nil and pid == state.standby.peer ->
        Newbee.DebugLog.log(:node, "standby exited reason=#{inspect(reason)}; replenishing")
        send(self(), :ensure_standby)
        {:noreply, %{state | standby: nil}}

      true ->
        {:noreply, state}
    end
  end

  # 异步补 standby：keeper 进程 boot 一个全新节点（每次随机新名字）。
  # 不能在 handle_info 里同步 boot——standby boot 1-3s（负载下更久），
  # 同步会阻塞 GenServer，把紧随其后的 eval call 卡在信箱里（实测首调延迟 1s+）。
  def handle_info(:ensure_standby, state) do
    if state.mode == :node and state.standby == nil and state.standby_boot == nil do
      boot =
        spawn_standby_boot(%{
          state
          | peer: nil,
            node: nil,
            worker: nil,
            standby: nil,
            standby_boot: nil,
            last_boot_attempt: System.monotonic_time(:millisecond)
        })

      {:noreply, %{state | standby_boot: boot}}
    else
      {:noreply, state}
    end
  end

  def handle_info({:standby_boot_result, keeper, {:ok, s}}, %{standby_boot: keeper} = state) do
    Newbee.DebugLog.log(:node, "standby up node=#{s.node}")
    # keeper 与 peer 的 link 随 keeper 存活；本进程再 link 一份，
    # 保证 standby 死后 EXIT 仍能通知到（一对一监督）。
    try do
      Process.link(s.peer)
    rescue
      _ -> :ok
    end

    {:noreply, %{state | standby: %{peer: s.peer, node: s.node, worker: s.worker}, standby_boot: nil}}
  end

  def handle_info({:standby_boot_result, keeper, {:error, reason}}, %{standby_boot: keeper} = state) do
    Newbee.DebugLog.log(:node, "standby boot failed #{inspect(reason)}; retry in #{@standby_retry_ms}ms")
    Process.send_after(self(), :ensure_standby, @standby_retry_ms)
    {:noreply, %{state | standby_boot: nil}}
  end

  def handle_info(:dequeue_eval, %{active_job: nil} = state) do
    case :queue.out(state.pending_evals) do
      {:empty, _} ->
        {:noreply, state}

      {{:value, {from, code, opts}}, rest} ->
        state = %{state | pending_evals: rest}

        if Process.alive?(elem(from, 0)) do
          case handle_call({:eval, code, opts}, from, state) do
            {:noreply, next} ->
              {:noreply, next}

            {:reply, reply, next} ->
              GenServer.reply(from, reply)
              send(self(), :dequeue_eval)
              {:noreply, next}
          end
        else
          send(self(), :dequeue_eval)
          {:noreply, state}
        end
    end
  end

  def handle_info(_, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    case state.mode do
      :node ->
        stop_all(state)

      # local 模式 worker 是 start_link 的，:normal 退出不会经 link 传播，需显式停
      :local ->
        if is_pid(state.worker) and Process.alive?(state.worker) do
          try do
            GenServer.stop(state.worker, :normal, 5_000)
          catch
            _, _ -> :ok
          end
        end
    end

    :ok
  end

  # ── boot ──

  # 启动失败返回 {:error, reason}，绝不抛异常：抛异常会触发 supervisor
  # 无限重启循环（one_for_one），CPU 打满且 eval call 永久挂起（实际事故）。
  # 不设硬性重启上限：每次用随机新名字重建（"拉不来就生成一个新的"）。
  defp boot_node(state), do: boot_node(state, :primary)

  defp boot_node(state, role) do
    try do
      ensure_distribution!()
      name = unique_peer_name(role, state.node_label)

      # Evaluator peers only need their one-to-one RPC link to the origin. Hidden
      # nodes stay out of global's fully connected topology, preventing parallel
      # sessions/test runners from forming overlapping partitions.
      pa_args = [~c"-noshell", ~c"-noinput", ~c"-hidden" | Enum.flat_map(:code.get_path(), &[~c"-pa", &1])]

      # detached: false —— peer 必须自带独立 user 进程。
      # 默认 detached: true 时 peer 的 standard_io 是 relay，io 请求转发给
      # origin 进程的 group leader；若 origin 是 DEE cell（GL 为 StringIO），
      # elixir 启动时 io:setopts(standard_io, [binary]) 会得到 {error, :enotsup}
      # 导致 elixir application 启动失败（实际事故：在 DEE 里跑 mix test /
      # 嵌套起 evaluator 全部 unavailable）。
      case :peer.start_link(%{
             name: name,
             args: pa_args,
             wait_boot: @peer_boot_timeout,
             detached: false,
             connection: {{127, 0, 0, 1}, 0}
           }) do
        {:ok, peer, node} ->
          Newbee.DebugLog.log(:boot, "peer up node=#{node}")

          case :rpc.call(node, :application, :ensure_all_started, [:elixir], @rpc_boot_timeout) do
            {:ok, _} ->
              filter_env(node)
              # 宿主契约（§3.4）：把主节点名注入节点 env，供 Newbee.Host 代理
              :rpc.call(node, :persistent_term, :put, [{Newbee.Host, :main_node}, Node.self()], @rpc_boot_timeout)
              :rpc.call(node, :os, :putenv, [~c"NEWBEE_MAIN_NODE", Atom.to_charlist(Node.self())], @rpc_boot_timeout)

              case :rpc.call(node, Newbee.DEE.EvalWorker, :start, [[cwd: state.cwd]], @rpc_boot_timeout) do
                {:ok, worker} ->
                  Newbee.DebugLog.log(:boot, "worker up #{inspect(worker)}")
                  Newbee.Environment.Generation.load_active_into(node)
                  # 注意：保留 state.restarts —— maybe_reboot 在 boot 前自增。
                  {:ok, %{state | peer: peer, node: node, worker: worker, boot_error: nil}}

                bad ->
                  Newbee.DebugLog.log(:boot, "worker failed #{inspect(bad)}")
                  stop_peer(peer)
                  {:error, {:worker, bad}}
              end

            bad ->
              Newbee.DebugLog.log(:boot, "elixir ensure failed #{inspect(bad)}")
              stop_peer(peer)
              {:error, {:boot, bad}}
          end

        bad ->
          Newbee.DebugLog.log(:boot, "peer.start_link failed #{inspect(bad)}")
          {:error, {:peer, bad}}
      end
    rescue
      e ->
        Newbee.DebugLog.log(:boot, "raised #{inspect(e)}")
        {:error, {:exception, e}}
    catch
      kind, reason ->
        Newbee.DebugLog.log(:boot, "caught #{kind} #{inspect(reason)}")
        {:error, {kind, reason}}
    end
  end

  defp stop_peer(peer) do
    try do
      :peer.stop(peer)
    catch
      _, _ -> :ok
    end
  end

  # 冷却期防抖的全量重建（主备都死时）：boot 失败进入 5s 冷却，冷却后再试。
  defp maybe_reboot(%{mode: :node} = state) do
    now = System.monotonic_time(:millisecond)

    if state.last_boot_attempt && now - state.last_boot_attempt < @reboot_cooldown do
      Newbee.DebugLog.log(:node, "boot cooldown active, skip reboot")
      state
    else
      stopped = stop_all(state)

      case boot_node(%{stopped | restarts: stopped.restarts + 1, last_boot_attempt: now}) do
        {:ok, s} ->
          send(self(), :ensure_standby)
          s

        {:error, reason} ->
          Newbee.DebugLog.log(:node, "boot failed #{inspect(reason)} restarts=#{stopped.restarts + 1}")
          %{stopped | restarts: stopped.restarts + 1, boot_error: reason, last_boot_attempt: now}
      end
    end
  end

  # 停主 + 备（含在途的 standby boot keeper）
  defp stop_all(state) do
    if state.standby_boot do
      Process.exit(state.standby_boot, :shutdown)
    end

    if state.standby do
      stop_peer(state.standby.peer)
    end

    stop_node(state)
  end

  defp stop_node(state) do
    if state.peer do
      try do
        :peer.stop(state.peer)
      catch
        _, _ -> :ok
      end
    end

    %{state | peer: nil, node: nil, worker: nil, standby_boot: nil}
  end

  # standby 顶替 primary
  defp promote_standby(state) do
    %{
      state
      | peer: state.standby.peer,
        node: state.standby.node,
        worker: state.standby.worker,
        standby: nil,
        restarts: state.restarts + 1,
        boot_error: nil
    }
  end

  # primary 死后解析 standby：已就绪直接用；在途 boot 则等它完成（不 reboot）。
  defp resolve_standby(%{standby: s} = state) when s != nil, do: {s, state}
  defp resolve_standby(state), do: await_standby_boot(state)

  # 等待在途的 standby boot（standby boot 与 primary 并行开跑，kill 测试里
  # primary 死时 standby 往往还在 boot：等它完成比从零 reboot 更快且不丢计数）。
  # 返回 {standby_map | nil, state}。
  defp await_standby_boot(%{standby_boot: nil} = state), do: {nil, state}

  defp await_standby_boot(state) do
    keeper = state.standby_boot

    receive do
      {:standby_boot_result, ^keeper, {:ok, s}} ->
        try do
          Process.link(s.peer)
        rescue
          _ -> :ok
        end

        {%{peer: s.peer, node: s.node, worker: s.worker}, %{state | standby_boot: nil}}

      {:standby_boot_result, ^keeper, {:error, _}} ->
        Process.send_after(self(), :ensure_standby, @standby_retry_ms)
        {nil, %{state | standby_boot: nil}}
    after
      @standby_wait_timeout ->
        # boot 卡死：关闭 keeper（其 peer 随之 halt），稍后重试，本调用走 reboot
        Process.exit(keeper, :shutdown)
        Process.send_after(self(), :ensure_standby, @standby_retry_ms)
        {nil, %{state | standby_boot: nil}}
    end
  end

  # ── standby boot keeper ──

  # 后台 boot standby，返回 keeper pid（存 state.standby_boot）。
  # keeper 与 GenServer link：evaluator 崩 → keeper 死 → peer BEAM halt，不留孤儿节点。
  defp spawn_standby_boot(state) do
    gen = self()

    keeper =
      spawn(fn ->
        result = boot_node(state, :standby)
        send(gen, {:standby_boot_result, self(), result})

        case result do
          {:ok, s} ->
            # 保持存活：peer 以本进程为 origin，origin 死则整个 peer BEAM halt。
            # peer 死（DOWN）或 evaluator 停（:stop）才退出。
            Process.monitor(s.peer)

            receive do
              {:DOWN, _, :process, _, _} -> :ok
              :stop -> :ok
            end

          _ ->
            :ok
        end
      end)

    Process.link(keeper)
    keeper
  end

  # ── rpc ──
  defp default_timeout, do: Newbee.DEE.EvalJob.default_timeout()

  defp prepare_primary(%{mode: :local} = state), do: state

  defp prepare_primary(state) do
    if state.peer != nil and Process.alive?(state.peer) do
      state
    else
      {standby, state} = resolve_standby(state)

      if standby != nil do
        next = promote_standby(%{state | standby: standby})
        send(self(), :ensure_standby)
        next
      else
        maybe_reboot(state)
      end
    end
  end

  defp cancel_cell(job) do
    spawn(fn ->
      try do
        case job.target do
          %{mode: :local, worker: worker} ->
            GenServer.call(worker, {:cancel, job.job_id}, 500)

          %{node: remote, worker: worker} ->
            :rpc.call(remote, GenServer, :call, [worker, {:cancel, job.job_id}, 500], 750)
        end
      catch
        _, _ -> :ok
      end
    end)
  end

  defp finish_job(%{active_job: job} = state, result) do
    send(job.guardian, {:finished, job.job_id})
    Process.demonitor(job.guardian_ref, [:flush])
    Process.cancel_timer(job.timer)
    Process.demonitor(job.ref, [:flush])
    GenServer.reply(job.from, result)
    send(self(), :dequeue_eval)
    %{state | active_job: nil}
  end

  defp fail_unknown_job(%{active_job: job} = state) do
    cancel_cell(job)
    state = isolate_failed_primary(state, job)

    finish_job(state, %{
      status: :error,
      error: "evaluation outcome unknown; code was not replayed",
      output: "",
      warnings: "",
      outcome_unknown: true
    })
  end

  defp isolate_failed_primary(%{mode: :node} = state, job) do
    if is_pid(job.peer), do: spawn(fn -> stop_peer(job.peer) end)
    if state.peer == job.peer, do: %{state | peer: nil, node: nil, worker: nil}, else: state
  end

  defp isolate_failed_primary(state, _job), do: state

  defp admit_eval(state, target, code, opts, from, restarted) do
    {caller, _tag} = from
    job_id = make_ref()
    timeout = Newbee.DEE.EvalJob.normalize_timeout(Keyword.get(opts, :timeout, default_timeout()))
    parent = self()

    opts =
      Keyword.merge(opts,
        job_id: job_id,
        timeout: timeout,
        interrupt_key: parent,
        interrupt_node: node(),
        cancel_owners: [caller, parent]
      )

    {pid, ref} =
      spawn_monitor(fn ->
        result =
          try do
            remote_call(target, {:eval, code, opts})
          catch
            kind, reason -> {:unknown, {kind, reason}}
          end

        send(parent, {:eval_result, job_id, result})
      end)

    {guardian, guardian_ref} = Newbee.DEE.EvalGuardian.start(parent, caller, target, state.peer, job_id, timeout)
    timer = Process.send_after(self(), {:eval_deadline, job_id}, timeout + 2000)

    job = %{
      job_id: job_id,
      pid: pid,
      ref: ref,
      timer: timer,
      from: from,
      target: target,
      peer: state.peer,
      reason: nil,
      restarted: restarted,
      guardian: guardian,
      guardian_ref: guardian_ref
    }

    {:noreply, %{state | active_job: job}}
  end

  @doc false
  def check_node_budget(%{mode: :local}), do: :ok

  def check_node_budget(%{node: node}) when is_atom(node) do
    max_mem = Application.get_env(:newbee, :eval_max_node_memory_bytes, @max_node_memory_bytes)
    max_procs = Application.get_env(:newbee, :eval_max_node_processes, @max_node_processes)

    with {:memory, mem} when is_integer(mem) <- {:memory, safe_rpc(node, :erlang, :memory, [:total])},
         {:procs, count} when is_integer(count) <- {:procs, safe_rpc(node, :erlang, :system_info, [:process_count])} do
      cond do
        is_integer(max_mem) and mem > max_mem -> {:error, {:over_budget, %{memory: mem, limit: max_mem}}}
        is_integer(max_procs) and count > max_procs -> {:error, {:over_budget, %{processes: count, limit: max_procs}}}
        true -> :ok
      end
    else
      {:memory, _} -> {:error, :node_dead}
      {:procs, _} -> {:error, :node_dead}
    end
  end

  def check_node_budget(_), do: {:error, :node_dead}

  defp safe_rpc(node, mod, fun, args) do
    case :rpc.call(node, mod, fun, args, @budget_rpc_timeout) do
      {:badrpc, _} -> {:badrpc, :dead}
      other -> other
    end
  end

  defp isolate_failed_target(%{mode: :node} = state, %{node: node}) do
    if state.node == node, do: %{state | peer: nil, node: nil, worker: nil}, else: state
  end

  defp isolate_failed_target(state, _), do: state

  defp isolate_over_budget_primary(%{mode: :node} = state, %{node: node} = target) do
    if state.node == node do
      if is_pid(state.peer), do: spawn(fn -> stop_peer(state.peer) end)
      %{state | peer: nil, node: nil, worker: nil}
    else
      if target[:peer] && is_pid(target[:peer]), do: spawn(fn -> stop_peer(target[:peer]) end)
      state
    end
  end

  defp isolate_over_budget_primary(state, _), do: state

  @doc "Reconcile orphan peer nodes whose origin is gone. Never kills live origins."
  def reconcile_orphans do
    self_node = Node.self()
    known = [self_node | Node.list()]

    Node.list()
    |> Enum.filter(fn n -> String.starts_with?(Atom.to_string(n), "newbee_eval_") end)
    |> Enum.reduce({:ok, []}, fn peer_node, {:ok, killed} ->
      origin =
        try do
          :rpc.call(peer_node, :persistent_term, :get, [{Newbee.Host, :main_node}, nil], @budget_rpc_timeout)
        catch
          _, _ -> nil
        end

      cond do
        origin == self_node ->
          {:ok, killed}

        origin == nil ->
          {:ok, killed}

        origin in known ->
          {:ok, killed}

        true ->
          try do
            :rpc.call(peer_node, :init, :stop, [], 1000)
          catch
            _, _ -> :ok
          end

          try do
            Node.disconnect(peer_node)
          catch
            _, _ -> :ok
          end

          {:ok, [peer_node | killed]}
      end
    end)
  end

  defp primary_target(%{mode: :local, worker: w}), do: %{mode: :local, worker: w}
  defp primary_target(%{node: node, worker: w}) when is_pid(w), do: %{node: node, worker: w}
  defp primary_target(_), do: nil

  defp remote_call(%{mode: :local, worker: w}, msg), do: {:ok, GenServer.call(w, msg, :infinity)}

  defp remote_call(nil, _msg) do
    Newbee.DebugLog.log(:rpc, "worker nil (node down)")
    :dead
  end

  defp remote_call(%{node: node, worker: w}, msg) when is_pid(w) do
    # 远端 GenServer.call 使用 cell 自身的 deadline。RPC 层只负责区分节点死亡，
    # 不叠加第二个截止；后者会在任务仍运行时向用户谎报超时，并可能造成重复副作用。
    ref = :rpc.async_call(node, GenServer, :call, [w, msg, :infinity])

    case :rpc.nb_yield(ref, :infinity) do
      {:value, {:badrpc, reason}} ->
        Newbee.DebugLog.log(:rpc, "badrpc #{inspect(reason)} msg=#{msg_name(msg)}")
        :dead

      {:value, result} ->
        {:ok, result}
    end
  end

  defp msg_name(msg) when is_tuple(msg), do: elem(msg, 0)
  defp msg_name(msg), do: msg

  defp alive?(state) do
    state.mode == :local or
      (state.node != nil and :rpc.call(state.node, :erlang, :is_alive, []) == true)
  end

  defp standby_info(state) do
    case state.standby do
      nil -> nil
      %{node: node} -> %{node: node, alive: :rpc.call(node, :erlang, :is_alive, []) == true}
    end
  end

  # ── env ──

  defp ensure_distribution! do
    if :persistent_term.get({Newbee.Host, :main_node}, nil) == nil and Node.alive?() do
      :persistent_term.put({Newbee.Host, :main_node}, Node.self())
    end

    unless Node.alive?() do
      name = String.to_atom("newbee_#{:crypto.strong_rand_bytes(8) |> Base.encode32(case: :lower, padding: false)}")

      case :net_kernel.start([name, :shortnames]) do
        {:ok, _} ->
          :ok

        # 并发 boot（async 测试多 evaluator 同启）时另一个进程已启动 distribution
        {:error, {:already_started, _}} ->
          :ok

        {:error, reason} ->
          raise "net_kernel start failed: #{inspect(reason)}"
      end
    end

    :ok
  end

  defp unique_peer_name(role, label) do
    suffix = :crypto.strong_rand_bytes(8) |> Base.encode32(case: :lower, padding: false)
    String.to_atom("newbee_eval_#{role}_#{label}_#{suffix}")
  end

  defp normalize_node_label(nil), do: "runtime"

  defp normalize_node_label(label) when is_atom(label), do: label |> Atom.to_string() |> normalize_node_label()

  defp normalize_node_label(label) when is_binary(label) do
    label
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "_")
    |> String.trim("_")
    |> String.slice(0, 24)
    |> case do
      "" -> "runtime"
      normalized -> normalized
    end
  end

  defp normalize_node_label(_label), do: "runtime"
  defp normalize_cwd(nil), do: nil
  defp normalize_cwd(cwd) when is_binary(cwd), do: Path.expand(cwd)

  defp filter_env(node) do
    :rpc.call(node, __MODULE__, :__filter_env__, [@env_deny_prefixes, @env_deny_suffixes])
  end

  @doc false
  def __filter_env__(prefixes, suffixes) do
    System.get_env()
    |> Map.keys()
    |> Enum.filter(fn k ->
      Enum.any?(prefixes, &String.starts_with?(k, &1)) or
        Enum.any?(suffixes, &String.ends_with?(k, &1))
    end)
    |> Enum.each(&:os.unsetenv(String.to_charlist(&1)))
  end

  @doc "切换并持久化 evaluator 的稳定工作根；所有可用 worker 必须同时成功。"
  def set_cwd(server \\ __MODULE__, cwd), do: GenServer.call(server, {:set_cwd, cwd}, @rpc_boot_timeout)
end
