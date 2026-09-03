defmodule Newbee.Environment.Boot do
  @moduledoc """
  启动恢复（DESIGN §11.5）：

  ```text
  discover project root → ensure/read environment.json → validate schema/active revision
  → resolve release 依赖图 → materialize active release set
  → boot candidate generation → health/self-test → Binding 快照恢复
  → switch active generation → build worker projection → resume 未完成消息
  ```

  失败则逐级回退 known-good revision + 标 degraded + 保留证据（§8.4）。
  不覆盖损坏 manifest（Store 原子写 + 事件流重放兜底）。
  """

  require Logger

  alias Newbee.Environment.{Coordinator, EvaluatorPool, PluginManager, Store}
  alias Newbee.Agent.Protocol

  @doc """
  完整启动序列。opts: evaluator_opts（测试用 mode: :local）、session_id（绑定恢复）。
  返回 {:ok, %{coordinator, pool, manifest, pending_needs}} | {:error, reason}。
  """
  def start(opts \\ []) do
    with :ok <- ensure_coordinator(),
         {:ok, manifest_state} <- validate_and_resolve(),
         {:ok, pool} <- boot_pool(manifest_state, opts),
         :ok <- restore_bindings(pool, opts),
         {:ok, pending} <- resume_messages() do
      {:ok,
       %{
         coordinator: Coordinator,
         pool: pool,
         revision: manifest_state.revision,
         active: manifest_state.active,
         pending_needs: pending
       }}
    end
  end

  @doc """
  CLI/TUI/Web 入口：**每个会话一个独立求值器**（会话级隔离）。

  不再共享全局 EvaluatorPool——绑定/中断/节点崩溃都是会话私有的：
  Esc 只杀本会话的求值 cell；某会话节点崩溃只重建该会话的，不波及其它。
  绑定快照按会话目录落盘，恢复时灌回本会话求值器。

  起独立 DEE.Evaluator（:node 自带 primary+standby 冗余与自动重建），
  调用方（Loop）持有 pid 并注册到 SessionEvaluators。
  """
  def evaluator_or_fallback, do: evaluator_or_fallback([])

  def evaluator_or_fallback(opts) do
    evaluator_opts = [
      mode: :node,
      cwd: Keyword.get(opts, :cwd),
      node_label: Keyword.get(opts, :node_label, Keyword.get(opts, :session_id))
    ]

    start =
      if Keyword.get(opts, :link, false),
        do: &Newbee.DEE.Evaluator.start_link/1,
        else: &Newbee.DEE.Evaluator.start/1

    case start.(evaluator_opts) do
      {:ok, ev} ->
        ev

      {:error, reason} ->
        if Keyword.get(opts, :log, true) do
          IO.puts("\e[33m⚠ 求值器节点启动失败，降级为会话私有本地 evaluator：#{inspect(reason)}\e[0m")
        end

        case Keyword.get(opts, :session_id) do
          sid when is_binary(sid) ->
            local_opts = [mode: :local, cwd: Keyword.get(opts, :cwd), node_label: sid]
            {:ok, ev} = start.(local_opts)
            ev

          _ ->
            case Process.whereis(Newbee.DEE.Evaluator) do
              nil ->
                {:ok, ev} = Newbee.DEE.Evaluator.start(name: Newbee.DEE.Evaluator)
                ev

              pid ->
                pid
            end
        end
    end
  end

  @doc """
  会话私有求值器 + 归属标记：返回 `{evaluator, owned?}`。

  `owned? = false` 表示降级到了具名共享兜底求值器（`Newbee.DEE.Evaluator`）——
  调用方必须把 `owned?` 原样透传为 Loop 的 `evaluator_owned`，
  保证共享求值器绝不随单个会话释放（私有求值器则随 kernel 死亡自停，
  见 `Newbee.DEE.Evaluator.monitor_owner/2`）。
  """
  def session_evaluator(opts \\ []) do
    ev = evaluator_or_fallback(opts)
    {ev, ev != Process.whereis(Newbee.DEE.Evaluator)}
  end

  # ── step 1-2: store + coordinator（事件流重放恢复 manifest）──

  defp ensure_coordinator do
    case Process.whereis(Coordinator) do
      nil ->
        case Coordinator.start_link([]) do
          {:ok, _} -> :ok
          {:error, {:already_started, _}} -> :ok
          {:error, reason} -> {:error, {:coordinator_boot_failed, reason}}
        end

      _pid ->
        :ok
    end
  end

  # ── step 3-4: schema 校验 + 依赖图解析 + active set 确认 ──

  defp validate_and_resolve do
    with {:ok, env} <- Store.load_environment(),
         {:ok, _env} <- Store.migrate(env) do
      current = Coordinator.current()

      case resolve_active(current.active) do
        :ok -> {:ok, current}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  # 依赖图解析：active set 内每个 release 的依赖必须可解析（§8.4 同规则）
  defp resolve_active(active) do
    releases =
      Enum.reduce_while(active, {:ok, []}, fn {_pid, rid}, {:ok, acc} ->
        case PluginManager.fetch_or_builtin(rid) do
          {:ok, r} -> {:cont, {:ok, [r | acc]}}
          {:error, _} -> {:halt, {:error, {:unresolvable_release, rid}}}
        end
      end)

    case releases do
      {:ok, rs} ->
        case PluginManager.topo_sort(rs) do
          {:ok, _} -> :ok
          {:error, reason} -> {:error, reason}
        end

      err ->
        err
    end
  end

  # ── step 5-7: boot generation（失败 → known-good 逐级回退 + degraded）──

  defp boot_pool(current, opts) do
    case EvaluatorPool.current() do
      nil ->
        evaluator_opts = Keyword.get(opts, :evaluator_opts, [])

        case EvaluatorPool.start(
               revision: current.revision,
               active_map: current.active,
               evaluator_opts: evaluator_opts
             ) do
          {:ok, pool} ->
            EvaluatorPool.register_default(pool)

            # pool 起来了但 generation boot 可能失败（init 不崩溃，active=nil）
            case EvaluatorPool.active(pool) do
              nil -> recover_pool(pool, current)
              _gen -> {:ok, pool}
            end

          {:error, reason} ->
            {:error, {:pool_boot_failed, reason}}
        end

      pool ->
        {:ok, pool}
    end
  end

  # generation 启动失败：回退最近 known-good revision 重建（§15.9）
  defp recover_pool(pool, failed_current) do
    Logger.error("generation boot failed at rev #{failed_current.revision}，回退 known-good")

    case Coordinator.recover_known_good(failed_current.revision, "boot health check failed") do
      {:ok, good_rev, _change} ->
        recovered = Coordinator.current()

        case EvaluatorPool.boot_candidate(pool, recovered.revision, recovered.active) do
          {:ok, _} ->
            case EvaluatorPool.switch(pool) do
              {:ok, _} -> {:ok, pool}
              {:error, reason} -> {:error, {:recovery_switch_failed, reason}}
            end

          {:error, reason} ->
            {:error, {:recovery_boot_failed, reason, recovered_to: good_rev}}
        end

      {:error, reason} ->
        {:error, {:no_known_good, reason}}
    end
  end

  # ── step 8: Binding 快照恢复（会话恢复时）──

  defp restore_bindings(pool, opts) do
    case Keyword.get(opts, :session_id) do
      nil ->
        :ok

      session_id ->
        session = Newbee.Session.open(session_id)

        case Newbee.Session.load_bindings(session) do
          [] -> :ok
          bindings -> EvaluatorPool.restore_bindings(pool, bindings) |> then(fn _ -> :ok end)
        end
    end
  rescue
    _ -> :ok
  end

  # ── step 10: resume 未完成消息（§11.5：adapter 的 need 队列不丢）──

  defp resume_messages do
    pending = Protocol.pending_needs()

    if pending != [] do
      Logger.info("恢复 #{length(pending)} 条未消费 need 消息")
    end

    {:ok, pending}
  rescue
    _ -> {:ok, []}
  end
end
