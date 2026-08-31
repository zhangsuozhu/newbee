defmodule Newbee.Environment.Generation do
  @moduledoc """
  Generation Manager + Binding Continuity Protocol（DESIGN §4.4）⭐。

  Pool 管理多 generation：active 服务 worker；candidate 加载候选环境跑
  compile/contract/health/回放；通过后走 **Binding Continuity**：

  ```text
  0. quiesce      旧 generation 静默——拒收新 step、等在途调用完成（超时兜底）
  1. snapshot     bindings + 元数据（session/generation/revision/seq/校验哈希）
  2. encode       codec 白名单 + 大小预算（BindingCodec）；超预算取消切换
  3. restore      按 binding 粒度恢复到 candidate（单值失败只 tombstone）
  4. switch       原子切换路由指针（Pool GenServer 单写者）
  5. drain        旧 generation 排空后停止
  ```

  切换失败则 binding 随旧 generation 原样存活，零损失；旧 generation
  unquiesce 恢复接流量，不带半迁移状态继续。

  三类状态各归其主：session_bindings 属会话（本模块迁移）；plugin_state
  按 state_policy 处理（PluginSupervisor）；environment 属 revision（Coordinator）。
  """

  alias Newbee.Environment.{BindingCodec, PluginManager}

  require Logger

  defstruct id: nil,
            revision: 0,
            active_map: %{},
            evaluator: nil,
            status: :booting,
            created_at: nil

  @type t :: %__MODULE__{}

  @quiesce_timeout 5_000

  def new(id, revision, active_map, evaluator) do
    %__MODULE__{
      id: id,
      revision: revision,
      active_map: active_map,
      evaluator: evaluator,
      status: :booting,
      created_at: DateTime.utc_now() |> DateTime.to_iso8601()
    }
  end

  def gen_id, do: "gen_" <> (:crypto.strong_rand_bytes(6) |> Base.encode16(case: :lower))

  # ── Binding Continuity ──

  @doc """
  执行完整迁移协议：quiesce → snapshot → encode → restore → （调用方切换路由）。
  返回 {:ok, snapshot, restore_summary} | {:error, reason}。
  失败时已自动 unquiesce 旧 generation（零损失语义）。
  """
  def migrate_bindings(%__MODULE__{} = from, %__MODULE__{} = to, opts \\ []) do
    metadata = %{
      session_id: Keyword.get(opts, :session_id),
      from_generation: from.id,
      to_generation: to.id,
      revision: to.revision,
      seq: System.unique_integer([:positive, :monotonic])
    }

    with :ok <- quiesce(from.evaluator),
         {:ok, snapshot} <- snapshot(from.evaluator, metadata, opts),
         {:ok, restore_summary} <- restore(to.evaluator, snapshot) do
      {:ok, snapshot, restore_summary}
    else
      {:error, reason} = err ->
        # 取消切换：旧 generation 恢复接流量，binding 原样存活
        unquiesce(from.evaluator)
        Logger.info("generation switch cancelled: #{inspect(reason)}")
        err
    end
  end

  @doc "step 0：quiesce（带超时兜底——GenServer.call 排队天然等在途调用完成）。"
  def quiesce(evaluator, timeout \\ @quiesce_timeout) do
    GenServer.call(evaluator, :quiesce, timeout)
    :ok
  catch
    :exit, _ -> {:error, :quiesce_timeout}
  end

  def unquiesce(evaluator) do
    GenServer.call(evaluator, :unquiesce, 5_000)
    :ok
  catch
    :exit, _ -> :ok
  end

  @doc """
  step 1+2：快照 + 白名单编码。附校验哈希（内容完整性）。
  超预算 → {:error, {:over_budget, ...}}（提示 worker 先显式 artifactize）。
  """
  def snapshot(evaluator, metadata, opts \\ []) do
    binding = Newbee.DEE.Evaluator.dump_bindings(evaluator)

    case BindingCodec.encode(binding, opts) do
      {:ok, %{entries: entries, summary: summary}} ->
        checksum = :crypto.hash(:sha256, Jason.encode_to_iodata!(entries)) |> Base.encode16(case: :lower)

        {:ok,
         %{
           metadata: Map.put(metadata, :checksum, checksum),
           entries: entries,
           summary: summary
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "step 3：恢复（先校验哈希；按 binding 粒度隔离失败）。"
  def restore(evaluator, %{metadata: %{checksum: checksum}, entries: entries}) do
    actual = :crypto.hash(:sha256, Jason.encode_to_iodata!(entries)) |> Base.encode16(case: :lower)

    if actual != checksum do
      {:error, :checksum_mismatch}
    else
      {binding, summary} = BindingCodec.decode(%{entries: entries})

      case Newbee.DEE.Evaluator.restore_bindings(evaluator, binding) do
        :ok -> {:ok, summary}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc "step 5：排空后停止旧 generation（quiesce 状态下无在途，直接停）。"
  def drain(%__MODULE__{evaluator: evaluator}, timeout \\ @quiesce_timeout) do
    ref = Process.monitor(evaluator)
    GenServer.stop(evaluator, :normal, timeout)

    receive do
      {:DOWN, ^ref, :process, _, _} -> :ok
    after
      timeout -> {:error, :drain_timeout}
    end
  catch
    :exit, _ -> :ok
  end

  # ── 候选构建 ──

  @doc """
  candidate generation 物化：启动求值器 + 加载候选 release set。
  `evaluator_opts` 透传 DEE.Evaluator（测试可用 mode: :local）。
  """
  def boot(revision, active_map, evaluator_opts \\ []) do
    case Newbee.DEE.Evaluator.start(evaluator_opts) do
      {:ok, evaluator} ->
        gen = new(gen_id(), revision, active_map, evaluator)

        with :ok <- materialize(gen),
             :ok <- health_check(gen) do
          {:ok, %{gen | status: :ready}}
        else
          {:error, reason} ->
            GenServer.stop(evaluator, :normal, 5_000)
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # generation 健康门（§15.9 的触发点）：冒烟 eval，失败即启动失败
  defp health_check(%__MODULE__{evaluator: evaluator}) do
    case Newbee.DEE.Evaluator.eval(evaluator, "1 + 1", timeout: 30_000) do
      %{status: :ok} -> :ok
      %{status: :error, error: err} -> {:error, {:health_check_failed, err}}
    end
  rescue
    e -> {:error, {:health_check_failed, Exception.message(e)}}
  catch
    :exit, reason -> {:error, {:health_check_failed, reason}}
  end

  @doc "把 generation 的 active release set 加载进其求值器节点。"
  def materialize(%__MODULE__{evaluator: evaluator, active_map: active_map}) do
    node = evaluator_node(evaluator)

    case PluginManager.materialize_active(active_map, node) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc false
  def evaluator_node(evaluator) do
    case Newbee.DEE.Evaluator.info(evaluator) do
      %{mode: :local} -> Node.self()
      %{node: node} when is_atom(node) and not is_nil(node) -> node
      _ -> Node.self()
    end
  rescue
    _ -> Node.self()
  catch
    _, _ -> Node.self()
  end

  @doc """
  求值器节点启动时的 release 加载钩子（DEE.Evaluator boot 调用）。
  项目 store 存在且有 active 图 → 物化源码 release 进节点；否则 no-op。
  """
  def load_active_into(node) do
    store = Newbee.Environment.Store

    if File.exists?(store.path(:environment)) do
      case store.load_environment() do
        {:ok, %{"active" => active}} when map_size(active) > 0 ->
          case PluginManager.materialize_active(active, node) do
            {:ok, _} ->
              :ok

            {:error, reason} ->
              Logger.warning("load_active_into #{node}: #{inspect(reason)}")
              :ok
          end

        _ ->
          :ok
      end
    else
      :ok
    end
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end
end
