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
            # 会话工作目录（WebUI 选定）：节点 boot 后 cd 过去；nil = 全局默认
            cwd: nil,
            # 受控诊断标签；节点名仍由系统补齐角色和随机后缀。
            node_label: "runtime",
            # 宿主进程（会话 kernel）：{pid, mref}；宿主死亡时求值器随停，
            # terminate → stop_all 释放 primary/standby peer 节点（epmd 不残留）
            owner: nil

  @env_deny_prefixes ~w(OPENROUTER_ DEEPSEEK_ ANTHROPIC_ OPENAI_)
  @env_deny_suffixes ~w(_KEY _TOKEN _SECRET)

  # peer 启动包含新 BEAM + Elixir application 冷启动，不能使用默认短窗口。
  @peer_boot_timeout 60_000
  @rpc_boot_timeout 60_000
  @reboot_cooldown 5_000
  # cell 自身决定 deadline；默认无限等待但始终可由会话 interrupt 取消。
  # RPC 不再另设墙钟截止，否则会返回错误却让远端副作用继续执行。

  # 等待在途 standby boot 完成的上限 / boot 失败后的重试间隔
  @standby_wait_timeout 60_000
  @standby_retry_ms 1_000

  # ── API ──

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name))
  def start(opts), do: GenServer.start(__MODULE__, opts, name: Keyword.get(opts, :name))

  @doc "执行一段 Elixir 代码。binding 持久；节点崩溃自动切 standby，无可用节点时重建。"
  def eval(server, code, opts \\ []) do
    GenServer.call(server, {:eval, code, opts}, :infinity)
  end

  @doc "中断当前正在执行的求值 cell；不会影响求值器绑定或后续调用。"
  def interrupt(server \\ __MODULE__) do
    server = if is_atom(server), do: Process.whereis(server), else: server

    if is_pid(server) do
      case Newbee.DEE.EvalWorker.active_pid(server) do
        pid when is_pid(pid) ->
          Process.exit(pid, :kill)
          Newbee.DEE.EvalWorker.clear_active(server, pid)

        _ ->
          :ok
      end
    end

    :ok
  end

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
    if mode == :node, do: Process.flag(:trap_exit, true)

    # 会话工作目录：boot 后在求值节点上 cd（Fs/Run 工具都以节点 cwd 为根）
    cwd_opt = Keyword.get(opts, :cwd)
    node_label = normalize_node_label(Keyword.get(opts, :node_label))
    base_state = %__MODULE__{mode: mode, cwd: cwd_opt, node_label: node_label}

    state =
      case mode do
        :local ->
          {:ok, worker} = Newbee.DEE.EvalWorker.start_link()
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

    # 异步补 standby（不阻塞 init）
    if state.mode == :node, do: send(self(), :ensure_standby)
    {:ok, state}
  end

  # ── calls ──

  @impl true
  def handle_call({:eval, code, opts}, {caller, _tag}, state) do
    t0 = System.monotonic_time(:millisecond)
    Newbee.DebugLog.log(:eval, "start code=#{String.slice(code, 0, 120) |> inspect()}")

    # active key 是本地 evaluator GenServer pid；远端 worker 用它把当前 task
    # 注册回主 VM，Esc 无需等待这个已阻塞的 GenServer 处理 mailbox。
    # caller 是会话 kernel（或直接 API 调用者），self() 是本 Evaluator；
    # 任一退出时 cell 必须同步取消，否则默认无限任务会脱离会话生命周期继续运行。
    opts =
      Keyword.merge(opts,
        interrupt_key: self(),
        interrupt_node: Node.self(),
        cancel_owners: Enum.uniq([caller, self()])
      )

    result =
      case remote_call(primary_target(state), {:eval, code, opts}) do
        {:ok, result} ->
          {:reply, result, state}

        :dead ->
          Newbee.DebugLog.log(:eval, "primary dead, trying standby")

          {standby, state} = resolve_standby(state)

          case remote_call(standby, {:eval, code, opts}) do
            {:ok, result} ->
              # standby 顶替 primary，异步补新 standby
              s = promote_standby(%{state | standby: standby})
              send(self(), :ensure_standby)
              {:reply, Map.put(result, :node_restarted, true), s}

            :dead ->
              # 双死：冷却防抖重建
              Newbee.DebugLog.log(:eval, "standby also dead, full reboot")
              s = maybe_reboot(state)

              case remote_call(primary_target(s), {:eval, code, opts}) do
                {:ok, result} ->
                  {:reply, Map.put(result, :node_restarted, true), s}

                :dead ->
                  {:reply,
                   %{
                     status: :error,
                     error: "evaluator node unavailable (restarts=#{s.restarts} boot_error=#{inspect(s.boot_error)})",
                     output: ""
                   }, s}
              end
          end
      end

    Newbee.DebugLog.log(:eval, "done in #{System.monotonic_time(:millisecond) - t0}ms")
    result
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
          {:ok, w} = Newbee.DEE.EvalWorker.start_link()
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
    targets = [primary_target(state), state.standby] |> Enum.reject(&is_nil/1)
    results = Enum.map(targets, &remote_call(&1, {:set_cwd, cwd}))

    if Enum.all?(results, &match?({:ok, :ok}, &1)) do
      {:reply, :ok, %{state | cwd: cwd}}
    else
      {:reply, {:error, :node_down}, state}
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
       restarts: state.restarts,
       alive: alive?(state),
       standby: standby_info(state),
       boot_error: state.boot_error
     }, state}
  end

  # ── cast ──

  @impl true
  def handle_cast({:monitor_owner, owner}, state) do
    {:noreply, %{state | owner: {owner, Process.monitor(owner)}}}
  end

  # ── info ──

  @impl true
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
      case :peer.start_link(%{name: name, args: pa_args, wait_boot: @peer_boot_timeout, detached: false}) do
        {:ok, peer, node} ->
          Newbee.DebugLog.log(:boot, "peer up node=#{node}")

          case :rpc.call(node, :application, :ensure_all_started, [:elixir], @rpc_boot_timeout) do
            {:ok, _} ->
              filter_env(node)
              # 宿主契约（§3.4）：把主节点名注入节点 env，供 Newbee.Host 代理
              :rpc.call(node, :persistent_term, :put, [{Newbee.Host, :main_node}, Node.self()], @rpc_boot_timeout)
              :rpc.call(node, :os, :putenv, [~c"NEWBEE_MAIN_NODE", Atom.to_charlist(Node.self())], @rpc_boot_timeout)

              case :rpc.call(node, Newbee.DEE.EvalWorker, :start, [[]], @rpc_boot_timeout) do
                {:ok, worker} ->
                  Newbee.DebugLog.log(:boot, "worker up #{inspect(worker)}")
                  Newbee.Environment.Generation.load_active_into(node)
                  # 注意：保留 state.restarts —— maybe_reboot 在 boot 前自增，
                  apply_session_cwd(node, state.cwd)
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

  # 会话工作目录：节点 boot 后 cd 过去（primary/standby 都经 boot_node，重建不丢）。
  # 失败不致命——降级为全局默认目录继续。
  defp apply_session_cwd(_node, nil), do: :ok

  defp apply_session_cwd(node, dir) when is_binary(dir) do
    case :rpc.call(node, File, :cd!, [dir], @rpc_boot_timeout) do
      :ok ->
        :ok

      bad ->
        Newbee.DebugLog.log(:boot, "session cwd cd failed #{inspect(bad)} dir=#{dir}")
        :ok
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

  def set_cwd(server \\ __MODULE__, cwd), do: GenServer.call(server, {:set_cwd, cwd}, @rpc_boot_timeout)
end
