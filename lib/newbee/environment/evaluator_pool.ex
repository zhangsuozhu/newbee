defmodule Newbee.Environment.EvaluatorPool do
  @moduledoc """
  Evaluator Pool（DESIGN §4.4）：隔离 BEAM 节点池 + generation 路由。

  - active generation 服务 worker；candidate generation 供 adapter 加载候选环境；
  - **原子切换 = 路由指针切换**（本 GenServer 是唯一路由写入者）；
    快照与大值持久化在切换前完成，不宣称跨节点数据传输本身原子；
  - 切换失败：active 不变，旧 generation unquiesce 恢复接流量；
  - 崩溃隔离：模型代码只在求值器节点跑（见 DEE.Evaluator 的双节点冗余）。
  """

  use GenServer
  require Logger

  alias Newbee.Environment.Generation

  defstruct active: nil,
            candidate: nil,
            generations: %{},
            evaluator_opts: []

  # ── API ──

  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  def start(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name)
    gen_opts = if name, do: [name: name], else: []
    GenServer.start(__MODULE__, opts, gen_opts)
  end

  @registry_key {__MODULE__, :default_pool}

  @doc "注册为默认 pool（generation 切换由 Coordinator 驱动时定位）。"
  def register_default(pid) when is_pid(pid), do: :persistent_term.put(@registry_key, pid)

  @doc "默认 pool（CLI/TUI 启动的 worker 求值路由）；未注册返回 nil。"
  def current do
    case :persistent_term.get(@registry_key, nil) do
      pid when is_pid(pid) -> if Process.alive?(pid), do: pid
      _ -> nil
    end
  end

  @doc "恢复绑定（会话恢复用，灌回 active generation）。"
  def restore_bindings(pool, binding), do: GenServer.call(pool, {:restore_bindings, binding}, 30_000)

  @doc "导出绑定（会话挂起用）。"
  def dump_bindings(pool), do: GenServer.call(pool, :dump_bindings, 30_000)

  @doc "路由到 active generation 执行。静默期（切换中）返回 {:error, :quiescing}。"
  def eval(pool, code, opts \\ []) do
    GenServer.call(pool, {:eval, code, opts}, :infinity)
  end

  @doc "当前 active generation。"
  def active(pool), do: GenServer.call(pool, :active)

  @doc "求值器信息（诊断）。"
  def info(pool), do: GenServer.call(pool, :info)

  @doc "绑定摘要（/bindings）。"
  def bindings_summary(pool), do: GenServer.call(pool, :bindings_summary, 10_000)

  @doc "中断当前 cell。"
  def interrupt(pool), do: GenServer.cast(pool, :interrupt)

  @doc "重置 active generation（丢弃绑定——用户显式 /reset）。"
  def reset(pool), do: GenServer.call(pool, :reset, 60_000)

  @doc """
  构建 candidate generation：启动求值器 + 物化候选 release set。
  """
  def boot_candidate(pool, revision, active_map) do
    GenServer.call(pool, {:boot_candidate, revision, active_map}, 120_000)
  end

  @doc """
  切换：Binding Continuity 协议 + 原子路由切换 + 排空旧 generation。
  成功 {:ok, summary}；失败 {:error, reason} 且 active 不变。
  """
  def switch(pool, opts \\ []) do
    GenServer.call(pool, {:switch, opts}, 120_000)
  end

  @doc "放弃 candidate（评测失败/取消）。"
  def discard_candidate(pool), do: GenServer.call(pool, :discard_candidate, 30_000)

  # ── GenServer ──

  @impl true
  def init(opts) do
    evaluator_opts = Keyword.get(opts, :evaluator_opts, [])
    revision = Keyword.get(opts, :revision, 0)
    active_map = Keyword.get(opts, :active_map, %{})

    state = %__MODULE__{evaluator_opts: evaluator_opts}

    case Generation.boot(revision, active_map, evaluator_opts) do
      {:ok, gen} ->
        gen = %{gen | status: :active}
        {:ok, %{state | active: gen, generations: %{gen.id => gen}}}

      {:error, reason} ->
        Logger.error("evaluator pool boot failed: #{inspect(reason)}")
        {:ok, state}
    end
  end

  @impl true
  def handle_call({:eval, _code, _opts}, _from, %{active: nil} = state) do
    {:reply, %{status: :error, error: "no active generation", output: ""}, state}
  end

  def handle_call({:eval, code, opts}, _from, state) do
    result = Newbee.DEE.Evaluator.eval(state.active.evaluator, code, opts)
    {:reply, result, state}
  end

  def handle_call(:active, _from, state), do: {:reply, state.active, state}

  def handle_call(:info, _from, state) do
    evaluator_info =
      if state.active, do: Newbee.DEE.Evaluator.info(state.active.evaluator), else: nil

    {:reply,
     %{
       active: state.active && %{id: state.active.id, revision: state.active.revision, status: state.active.status},
       candidate:
         state.candidate &&
           %{id: state.candidate.id, revision: state.candidate.revision, status: state.candidate.status},
       evaluator: evaluator_info
     }, state}
  end

  def handle_call(:bindings_summary, _from, %{active: nil} = state), do: {:reply, [], state}

  def handle_call(:bindings_summary, _from, state) do
    {:reply, Newbee.DEE.Evaluator.bindings_summary(state.active.evaluator), state}
  end

  def handle_call({:restore_bindings, _binding}, _from, %{active: nil} = state),
    do: {:reply, {:error, :no_active}, state}

  def handle_call({:restore_bindings, binding}, _from, state) do
    {:reply, Newbee.DEE.Evaluator.restore_bindings(state.active.evaluator, binding), state}
  end

  def handle_call(:dump_bindings, _from, %{active: nil} = state), do: {:reply, [], state}

  def handle_call(:dump_bindings, _from, state) do
    {:reply, Newbee.DEE.Evaluator.dump_bindings(state.active.evaluator), state}
  end

  def handle_call(:reset, _from, %{active: nil} = state), do: {:reply, :ok, state}

  def handle_call(:reset, _from, state) do
    :ok = Newbee.DEE.Evaluator.reset(state.active.evaluator)
    {:reply, :ok, state}
  end

  def handle_call({:boot_candidate, revision, active_map}, _from, state) do
    state = discard_candidate_impl(state)

    case Generation.boot(revision, active_map, state.evaluator_opts) do
      {:ok, gen} ->
        gen = %{gen | status: :candidate}
        {:reply, {:ok, gen}, %{state | candidate: gen, generations: Map.put(state.generations, gen.id, gen)}}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:switch, _opts}, _from, %{active: nil} = state), do: {:reply, {:error, :no_active}, state}
  def handle_call({:switch, _opts}, _from, %{candidate: nil} = state), do: {:reply, {:error, :no_candidate}, state}

  def handle_call({:switch, opts}, _from, state) do
    old = state.active
    new = state.candidate

    case Generation.migrate_bindings(old, new, opts) do
      {:ok, snapshot, restore_summary} ->
        # step 4：原子切换路由指针（本 GenServer 状态即路由）
        new = %{new | status: :active}
        old = %{old | status: :draining}

        state = %{
          state
          | active: new,
            candidate: nil,
            generations:
              state.generations
              |> Map.put(new.id, new)
              |> Map.put(old.id, old)
        }

        # step 5：排空（quiesce 后无在途，同步停；失败仅记录）
        case Generation.drain(old) do
          :ok -> :ok
          {:error, reason} -> Logger.warning("old generation drain: #{inspect(reason)}")
        end

        state = %{state | generations: Map.delete(state.generations, old.id)}

        {:reply, {:ok, Map.merge(snapshot.summary, restore_summary)}, state}

      {:error, reason} ->
        # 取消切换：active 不变；migrate_bindings 内部已 unquiesce 旧 generation
        {:reply, {:error, reason}, discard_candidate_impl(state)}
    end
  end

  def handle_call(:discard_candidate, _from, state) do
    {:reply, :ok, discard_candidate_impl(state)}
  end

  @impl true
  def handle_cast(:interrupt, %{active: nil} = state), do: {:noreply, state}

  def handle_cast(:interrupt, state) do
    Newbee.DEE.Evaluator.interrupt(state.active.evaluator)
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    for {_id, gen} <- state.generations do
      if gen.evaluator && Process.alive?(gen.evaluator) do
        GenServer.stop(gen.evaluator, :normal, 5_000)
      end
    end

    :ok
  end

  defp discard_candidate_impl(%{candidate: nil} = state), do: state

  defp discard_candidate_impl(%{candidate: gen} = state) do
    if gen.evaluator && Process.alive?(gen.evaluator) do
      GenServer.stop(gen.evaluator, :normal, 5_000)
    end

    %{state | candidate: nil, generations: Map.delete(state.generations, gen.id)}
  end
end
