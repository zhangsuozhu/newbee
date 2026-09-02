defmodule Newbee.Environment.Coordinator do
  @moduledoc """
  Environment Coordinator（DESIGN §4.3）：Change/Release/Revision 状态机的
  **唯一驾驶者**。收消息、排评测、动 active 指针、发通知、做回退。
  任何模块不得自维护另一份 active 状态。

  - **OTP 单写者串行化**（邮箱即顺序保证）；`expected_version` 乐观校验，
    过期请求直接拒绝；
  - 状态转换只由 **durable 事件驱动**——daemon 崩溃后从最后一个已落盘事件
    重新驱动（init 时从 checkpoint 重放），不产生半成品状态；
  - 候选构建/编译/回放/模型调用委托给有界任务队列（并行），完成后以事件
    回报 Coordinator——唯一写入者不做计算瓶颈；
  - 评测超 `deadline` → `rejected(reason: timeout)`；重复 `candidate_ready`
    按 `change_id` 去重；同一 plugin 允许多并行 candidate，激活按到达顺序
    串行裁决；
  - 幂等键（§7.2）：激活 `{change_id, candidate_revision}`、
    回退 `{rollback_change_id, target_revision}`；
  - 通知语义（§7.3）：①更新 active revision ②广播 module_ready
    ③通知进 worker 下一次投影 ④worker 执行中排队不打断 ⑤附版本/契约/
    用法/评测摘要；
  - 回退是一等公民（§8.4）：release graph 级操作，优先整图切历史 revision，
    单插件回退构造候选 revision 重解析依赖图，不兼容则拒绝并解释。
  """

  use GenServer

  alias Newbee.Environment.{
    Antibodies,
    Autonomy,
    Change,
    Manifest,
    PluginManager,
    Release,
    Store,
    Verifier
  }

  alias Newbee.Environment.Revision

  @max_eval_tasks 4
  @default_eval_timeout 120_000

  defstruct manifest: nil,
            changes: %{},
            event_store: nil,
            eval_tasks: %{},
            pending_notices: [],
            idempotency: %{},
            autonomy: nil,
            started: false

  # ── API ──

  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  def start(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start(__MODULE__, opts, name: name)
  end

  @doc "当前 active 状态（revision 号 + release 图 + checkpoint）。"
  def current(server \\ __MODULE__), do: GenServer.call(server, :current)

  @doc "全部 revision 历史（版本图，/environment revisions）。"
  def revisions(server \\ __MODULE__), do: GenServer.call(server, :revisions)

  @doc "全部 change（含历史）。"
  def changes(server \\ __MODULE__), do: GenServer.call(server, :changes, 60_000)

  @doc """
  提议变更（worker/adapter/system 均可发起）。
  attrs: reason, evidence（指向事件日志具体证据）, author_agent, expected_version,
         evaluation_plan, deadline。
  """
  def propose_change(server \\ __MODULE__, attrs) do
    GenServer.call(server, {:propose_change, Map.new(attrs)}, 60_000)
  end

  @doc """
  候选就绪（adapter → coordinator）：附 release 定义与评测计划。
  按 change_id 去重；异步构建+评测，完成后以事件回报。
  """
  def candidate_ready(server \\ __MODULE__, change_id, release_attrs, opts \\ []) do
    GenServer.call(server, {:candidate_ready, change_id, Map.new(release_attrs), opts}, 60_000)
  end

  @doc "manual 档下人工授权（§8.1：带签名的授权事件，进 Event Store，可审计）。"
  def approve(server \\ __MODULE__, change_id, approver \\ "user") do
    GenServer.call(server, {:approve, change_id, approver}, 60_000)
  end

  @doc "将基线过期的候选绑定到当前 revision 并重新运行完整验证。"
  def reevaluate(change_id), do: reevaluate(__MODULE__, change_id)

  def reevaluate(server, change_id) do
    GenServer.call(server, {:reevaluate, change_id}, 60_000)
  end

  @doc "激活（合取判定：Host Safety ∧ Capability ∧ Autonomy ∧ Ring Gate ∧ 预算）。"
  def activate(server \\ __MODULE__, change_id, opts \\ []) do
    GenServer.call(server, {:activate, change_id, opts}, 60_000)
  end

  @doc """
  回退（一等公民，§8.4）。target:
    - {:revision, n} —— 整图切到历史 revision；
    - {:plugin, plugin_id, release_id} —— 构造候选 revision 重解析依赖图。
  """
  def rollback(server \\ __MODULE__, target, reason, opts \\ []) do
    GenServer.call(server, {:rollback, target, reason, opts}, 60_000)
  end

  @doc "worker feedback：版本级评价样本（§7.2，允许同 release 多次上报）。"
  def feedback(server \\ __MODULE__, attrs) do
    GenServer.call(server, {:feedback, Map.new(attrs)})
  end

  @doc "取走 worker 的待投递通知（Projection 构建时调用，§7.3③④）。"
  def drain_notices(server \\ __MODULE__), do: GenServer.call(server, :drain_notices)

  @doc "自治升档证据汇总（§8.1 挣来的自治）。"
  def autonomy_evidence(server \\ __MODULE__), do: GenServer.call(server, :autonomy_evidence)

  @doc "同步运行中 Coordinator 的自治档位，并记录审计事件。"
  def set_autonomy(server \\ __MODULE__, level) do
    GenServer.call(server, {:set_autonomy, level})
  end

  # ── init：崩溃恢复 = 从最近 checkpoint 重放事件流重建快照（§4.6）──

  @impl true
  def init(opts) do
    Store.ensure!()

    {:ok, store} =
      Newbee.EventStore.start_link(path: Store.path(:events), durability: :batch)

    # 注册为项目 Event Store（Newbee.Events 的 durable 落盘目标）
    Newbee.Events.register_store(store)

    manifest = recover_manifest(store)
    changes = recover_changes()

    # 打开即推进 checkpoint（快照与事件流不一致时以事件流为准）
    persist_manifest(manifest, store)

    {:ok,
     %__MODULE__{
       manifest: manifest,
       changes: changes,
       event_store: store,
       autonomy: Keyword.get(opts, :autonomy) || Autonomy.get(),
       started: true
     }}
  end

  # 从事件流重建 manifest（以事件流为准，environment.json 只是快照）
  defp recover_manifest(store) do
    {:ok, env} = Store.load_environment()
    checkpoint = env["checkpoint"] || 0
    base = Manifest.from_map(env["manifest"] || %{})

    events = Newbee.EventStore.replay(Store.path(:events), base.checkpoint)

    Enum.reduce(events, base, fn ev, m -> apply_event(m, ev) end)
    |> Map.put(:checkpoint, max(checkpoint, Newbee.EventStore.watermark(store)))
  end

  defp apply_event(manifest, %{topic: :revision_advanced, id: event_id, data: data}) do
    rev = Revision.from_map(data["revision"])

    %{
      manifest
      | revision: rev.rev,
        active: rev.active,
        revisions: upsert_revision(manifest.revisions, rev),
        checkpoint: event_id
    }
  end

  defp apply_event(manifest, %{topic: :revision_degraded, id: event_id, data: data}) do
    manifest
    |> Manifest.mark_health(data["rev"], :degraded)
    |> Map.put(:checkpoint, event_id)
  end

  defp apply_event(manifest, %{topic: :revision_healthy, id: event_id, data: data}) do
    manifest
    |> Manifest.mark_health(data["rev"], :healthy)
    |> Map.put(:checkpoint, event_id)
  end

  defp apply_event(manifest, %{id: event_id}), do: %{manifest | checkpoint: event_id}

  defp upsert_revision(revs, rev) do
    case Enum.find_index(revs, &(&1.rev == rev.rev)) do
      nil -> revs ++ [rev]
      idx -> List.replace_at(revs, idx, rev)
    end
  end

  defp recover_changes do
    Store.dir(:changes)
    |> Path.join("*/change.json")
    |> Path.wildcard()
    |> Enum.flat_map(fn f ->
      case File.read(f) do
        {:ok, body} ->
          case Jason.decode(body) do
            {:ok, m} -> [Change.from_map(m)]
            _ -> []
          end

        _ ->
          []
      end
    end)
    |> Map.new(&{&1.change_id, &1})
  end

  # ── propose ──

  @impl true
  def handle_call({:propose_change, attrs}, _from, state) do
    change =
      Change.new(
        Map.merge(attrs, %{
          base_revision: state.manifest.revision,
          deadline: attrs[:deadline] || default_deadline()
        })
      )

    case check_expected_version(change, state) do
      :ok ->
        state = put_change(state, change)
        append_event(state, :change_requested, Change.to_map(change))
        {:reply, {:ok, change}, state}

      {:error, _} = err ->
        {:reply, err, state}
    end
  end

  # ── candidate_ready（去重 + 异步评测）──

  def handle_call({:candidate_ready, change_id, release_attrs, opts}, _from, state) do
    case Map.fetch(state.changes, change_id) do
      :error ->
        {:reply, {:error, :change_not_found}, state}

      {:ok, %Change{status: s}} when s not in [:requested, :building] ->
        # 重复 candidate_ready 按 change_id 去重（§3.4）：幂等返回现状
        {:reply, {:ok, :duplicate, s}, state}

      {:ok, change} ->
        release =
          Release.new(
            Map.merge(release_attrs, %{
              change_id: change_id,
              author: change.author_agent
            })
          )

        case PluginManager.materialize(release) do
          {:ok, _dir} ->
            change = %{
              Change.transition(change, :building)
              | candidate_revision: release.release_id
            }

            state = put_change(state, change)

            append_event(state, :change_building, %{
              "change_id" => change_id,
              "release_id" => release.release_id
            })

            # 异步评测（有界任务队列，完成后事件回报）
            state = start_evaluation(state, change, release, opts)
            {:reply, {:ok, release}, state}

          {:error, reason} ->
            {change, state} =
              reject_change(state, change, "materialize_failed: #{inspect(reason)}")

            {:reply, {:error, reason}, put_change(state, change)}
        end
    end
  end

  # ── approve（授权事件）──

  def handle_call({:approve, change_id, approver}, _from, state) do
    case Map.fetch(state.changes, change_id) do
      :error ->
        {:reply, {:error, :change_not_found}, state}

      {:ok, change} ->
        append_event(state, :change_approved, %{
          "change_id" => change_id,
          "approver" => approver,
          "at" => now_iso()
        })

        # 授权即尝试激活
        case do_activate(state, change, approved: true) do
          {:ok, state} -> {:reply, :ok, state}
          {:error, reason, state} -> {:reply, {:error, reason}, state}
        end
    end
  end

  # ── reevaluate（显式重基后重新越过验证门）──

  def handle_call({:reevaluate, change_id}, _from, state) do
    with {:ok, change} <- Map.fetch(state.changes, change_id),
         :ok <- check_reevaluable(change, state),
         {:ok, release} <- fetch_candidate(change) do
      previous_base = change.base_revision

      change = %{
        Change.transition(change, :building)
        | base_revision: state.manifest.revision,
          attempt: change.attempt + 1,
          deadline: default_deadline(),
          evaluation_result: nil
      }

      state = put_change(state, change)

      append_event(state, :change_rebased, %{
        "change_id" => change_id,
        "from_revision" => previous_base,
        "to_revision" => change.base_revision,
        "attempt" => change.attempt,
        "release_id" => release.release_id
      })

      state = start_evaluation(state, change, release, [])
      {:reply, {:ok, change}, state}
    else
      :error -> {:reply, {:error, :change_not_found}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  # ── activate ──

  def handle_call({:activate, change_id, opts}, _from, state) do
    case Map.fetch(state.changes, change_id) do
      :error ->
        {:reply, {:error, :change_not_found}, state}

      # 已激活的同一候选：幂等成功（at-least-once + 幂等 effect，§7.2）
      {:ok, %Change{status: s, candidate_revision: cand}} when s in [:active, :promoted] ->
        state = %{
          state
          | idempotency: Map.put(state.idempotency, {:activate, change_id, cand}, :ok)
        }

        {:reply, :ok, state}

      {:ok, change} ->
        # 幂等键：{change_id, candidate_revision}（§7.2）
        idem = {:activate, change_id, change.candidate_revision}

        if Map.has_key?(state.idempotency, idem) do
          {:reply, Map.fetch!(state.idempotency, idem), state}
        else
          case do_activate(state, change, opts) do
            {:ok, state} ->
              state = %{state | idempotency: Map.put(state.idempotency, idem, :ok)}
              {:reply, :ok, state}

            {:error, reason, state} ->
              {:reply, {:error, reason}, state}
          end
        end
    end
  end

  # ── rollback ──

  def handle_call({:rollback, target, reason, opts}, _from, state) do
    # 幂等键（§7.2）：回退 {rollback_change_id/request_id, target_revision}
    idem = {:rollback, Keyword.get(opts, :request_id, {target, state.manifest.revision}), target}

    if Map.has_key?(state.idempotency, idem) do
      {:reply, Map.fetch!(state.idempotency, idem), state}
    else
      case do_rollback(state, target, reason, opts) do
        {:ok, change, state} ->
          state = %{state | idempotency: Map.put(state.idempotency, idem, {:ok, change})}
          {:reply, {:ok, change}, state}

        {:error, reason, state} ->
          {:reply, {:error, reason}, state}
      end
    end
  end

  # ── feedback ──

  def handle_call({:feedback, attrs}, _from, state) do
    release_id = attrs[:release_id]

    # ReleaseObservation 记账（价签，§3.3）+ 评价证据
    Newbee.Environment.Fitness.observe(release_id, %{
      success: attrs[:outcome] == :ok,
      latency_ms: attrs[:latency_ms] || 0,
      tokens: attrs[:tokens] || 0,
      output_bytes: attrs[:output_size] || 0,
      model: attrs[:model],
      task_type: attrs[:task_type]
    })

    append_event(state, :feedback, Map.new(attrs, fn {k, v} -> {to_string(k), v} end))

    # 负反馈 + suggested_action: rollback → 自动受理回退（§7.1）
    state =
      if attrs[:suggested_action] == :rollback and attrs[:plugin_id] do
        case do_rollback(
               state,
               {:plugin, attrs[:plugin_id], attrs[:target]},
               attrs[:comment] || "worker feedback",
               []
             ) do
          {:ok, _change, state} -> state
          {:error, _reason, state} -> state
        end
      else
        state
      end

    {:reply, :ok, state}
  end

  def handle_call({:set_autonomy, level}, _from, state) do
    if level in Autonomy.levels() do
      append_event(state, :autonomy_changed, %{
        "from" => to_string(state.autonomy),
        "to" => to_string(level)
      })

      {:reply, :ok, %{state | autonomy: level}}
    else
      {:reply, {:error, :invalid_level}, state}
    end
  end

  def handle_call(:current, _from, state) do
    {:reply,
     %{
       revision: state.manifest.revision,
       active: state.manifest.active,
       checkpoint: state.manifest.checkpoint,
       autonomy: state.autonomy,
       degraded: state.manifest.degraded
     }, state}
  end

  def handle_call(:revisions, _from, state) do
    {:reply, Enum.map(state.manifest.revisions, &Revision.to_map/1), state}
  end

  def handle_call(:changes, _from, state) do
    {:reply, state.changes |> Map.values() |> Enum.sort_by(& &1.created_at), state}
  end

  def handle_call(:drain_notices, _from, state) do
    {:reply, Enum.reverse(state.pending_notices), %{state | pending_notices: []}}
  end

  def handle_call({:recover_known_good, failed_rev, reason}, _from, state) do
    manifest = Manifest.mark_health(state.manifest, failed_rev, :degraded)
    append_event(state, :revision_degraded, %{"rev" => failed_rev, "reason" => reason})

    known_good = Manifest.last_known_good(manifest)

    case do_rollback(
           %{state | manifest: manifest},
           {:revision, known_good},
           "recover to known-good rev #{known_good}: #{reason}",
           []
         ) do
      {:ok, change, state} ->
        notify(state, :rolled_back, %{revision: known_good, reason: "degraded recovery"})

        {:reply, {:ok, known_good, change}, state}

      {:error, r, state} ->
        {:reply, {:error, r}, state}
    end
  end

  def handle_call({:mark_healthy, rev}, _from, state) do
    manifest = Manifest.mark_health(state.manifest, rev, :healthy)
    append_event(state, :revision_healthy, %{"rev" => rev})
    persist_manifest(manifest, state.event_store)
    {:reply, :ok, %{state | manifest: manifest}}
  end

  # §4.4 step4：generation 切换成功 → 绑定迁移摘要作为 notice 进
  # pending_notices，worker 下一次投影（Projection.build → drain_notices）可见
  def handle_call({:mark_healthy, rev, notice}, _from, state) do
    manifest = Manifest.mark_health(state.manifest, rev, :healthy)
    append_event(state, :revision_healthy, %{"rev" => rev})
    persist_manifest(manifest, state.event_store)

    {:reply, :ok, %{state | manifest: manifest, pending_notices: [notice | state.pending_notices]}}
  end

  def handle_call(:autonomy_evidence, _from, state) do
    {:reply,
     %{
       verified_antibodies: Antibodies.verified_count(),
       replay_coverage: replay_coverage(state),
       recent_changes: state.changes |> Map.values() |> Enum.sort_by(& &1.created_at, :desc)
     }, state}
  end

  defp check_reevaluable(%Change{} = change, state) do
    cond do
      change.status in [:active, :promoted] -> {:error, :already_active}
      Change.terminal?(change) -> {:error, {:terminal, change.status}}
      change.candidate_revision == nil -> {:error, :no_candidate}
      Map.has_key?(state.eval_tasks, change.change_id) -> {:error, :evaluation_in_progress}
      change.base_revision == state.manifest.revision -> {:error, :base_is_current}
      true -> :ok
    end
  end

  # ── 评测任务回报（事件驱动状态转换）──

  @impl true
  def handle_info({:evaluation_done, change_id, result}, state) do
    case {Map.fetch(state.changes, change_id), Map.pop(state.eval_tasks, change_id)} do
      {{:ok, change}, {_task, tasks}} ->
        state = %{state | eval_tasks: tasks}

        cond do
          change.status in [:rejected, :rolled_back] ->
            {:noreply, state}

          expired?(change) ->
            {_change, state} = reject_change(state, change, "timeout")
            {:noreply, state}

          result.passed ->
            change = %{Change.transition(change, :canary) | evaluation_result: json_safe(result)}
            state = put_change(state, change)
            append_event(state, :change_evaluated, %{"change_id" => change_id, "passed" => true})

            state = maybe_auto_activate(state, change)
            {:noreply, state}

          true ->
            reason = "evaluation failed: #{inspect(result.failed_layers)}"

            append_event(state, :change_evaluated, %{
              "change_id" => change_id,
              "passed" => false,
              "result" => inspect(result.layers, limit: 8)
            })

            # 通知双方（§7.2 module_rejected）
            notify(state, :module_rejected, %{
              change_id: change_id,
              reason: reason,
              evidence: result.failed_layers,
              next_action: "fix and resubmit (attempt #{change.attempt + 1})"
            })

            {_change, state} = reject_change(state, change, reason)
            {:noreply, state}
        end

      _ ->
        {:noreply, state}
    end
  end

  def handle_info({:eval_task_timeout, change_id}, state) do
    case Map.fetch(state.changes, change_id) do
      {:ok, change} when change.status in [:building, :evaluating] ->
        case Map.pop(state.eval_tasks, change_id) do
          {nil, _} ->
            {:noreply, state}

          {task, tasks} ->
            Task.shutdown(task, :brutal_kill)
            {_change, state} = reject_change(%{state | eval_tasks: tasks}, change, "timeout")
            {:noreply, state}
        end

      _ ->
        {:noreply, state}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # ── 内部：评测 ──

  defp start_evaluation(state, change, release, opts) do
    if map_size(state.eval_tasks) >= @max_eval_tasks do
      # 有界队列：超限直接拒绝（避免唯一写入者变瓶颈；adapter 可重试）
      {change, state} = reject_change(state, change, "evaluation queue full")
      put_change(state, change)
    else
      change = Change.transition(change, :evaluating)
      state = put_change(state, change)

      coordinator = self()

      task =
        Task.async(fn ->
          parent = parent_release(release)
          result = Verifier.evaluate(release, Keyword.merge([parent: parent], opts))
          send(coordinator, {:evaluation_done, change.change_id, result})
        end)

      timeout = eval_timeout(change)
      Process.send_after(self(), {:eval_task_timeout, change.change_id}, timeout)

      %{state | eval_tasks: Map.put(state.eval_tasks, change.change_id, task)}
    end
  end

  defp parent_release(%Release{parent_release: nil}), do: nil

  defp parent_release(%Release{parent_release: parent_id}) do
    case PluginManager.fetch_or_builtin(parent_id) do
      {:ok, r} -> r
      _ -> nil
    end
  end

  defp eval_timeout(%Change{deadline: nil}), do: @default_eval_timeout

  defp eval_timeout(%Change{deadline: deadline}) do
    case DateTime.from_iso8601(deadline) do
      {:ok, dt, _} ->
        max(DateTime.to_unix(dt, :millisecond) - System.system_time(:millisecond), 1)

      _ ->
        @default_eval_timeout
    end
  end

  defp default_deadline do
    (System.system_time(:millisecond) + @default_eval_timeout)
    |> DateTime.from_unix!(:millisecond)
    |> DateTime.to_iso8601()
  end

  defp expired?(%Change{deadline: nil}), do: false

  defp expired?(%Change{deadline: deadline}) do
    case DateTime.from_iso8601(deadline) do
      {:ok, dt, _} -> System.system_time(:millisecond) > DateTime.to_unix(dt, :millisecond)
      _ -> false
    end
  end

  # ── 内部：激活（合取判定）──

  defp do_activate(state, %Change{} = change, opts) do
    with :ok <- check_change_activatable(change),
         :ok <- check_stale_base(change, state),
         {:ok, release} <- fetch_candidate(change),
         {:allow, via} <- activation_gate(release, change, state, opts) do
      # canary 路径：rule/prompt 先进 canary 状态（§8.1 自治上限）
      if via == :canary do
        change = Change.transition(change, :canary)
        append_event(state, :change_canary, %{"change_id" => change.change_id})
        {:ok, put_change(state, change)}
      else
        activate_change(state, change, release, via)
      end
    else
      {:deny, reason} -> {:error, reason, state}
      {:error, reason} -> {:error, reason, state}
    end
  end

  defp check_change_activatable(%Change{status: s} = change) do
    cond do
      s in [:active, :promoted] -> {:error, :already_active}
      s in [:rejected, :rolled_back] -> {:error, {:terminal, s}}
      s == :requested -> {:error, :no_candidate}
      true -> :ok
    end
    |> case do
      :ok -> if(change.evaluation_result == nil, do: {:error, :not_evaluated}, else: :ok)
      other -> other
    end
  end

  defp fetch_candidate(%Change{candidate_revision: nil}), do: {:error, :no_candidate}

  defp fetch_candidate(%Change{candidate_revision: release_id}) do
    PluginManager.fetch_or_builtin(release_id)
  end

  defp check_stale_base(%Change{base_revision: base}, state) when base != nil do
    if base == state.manifest.revision,
      do: :ok,
      else: {:error, {:stale_base, base, state.manifest.revision}}
  end

  defp check_stale_base(_, _), do: :ok

  defp activation_gate(%Release{} = release, change, state, opts) do
    Autonomy.activation_decision(release.kind, state.autonomy,
      approved: Keyword.get(opts, :approved, false),
      canary_done: change.status == :canary,
      rollback: change.rollback_of != nil
    )
  end

  defp maybe_auto_activate(state, %Change{} = change) do
    case do_activate(state, change, []) do
      {:ok, state} -> state
      {:error, _reason, state} -> state
    end
  end

  # 激活主流程（§7.3 通知语义）
  defp activate_change(state, %Change{} = change, %Release{} = release, via) do
    delta = %{release.plugin_id => release.release_id}
    manifest = Manifest.advance(state.manifest, delta, change.change_id)
    rev = manifest.revision

    change = Change.transition(change, :active)
    state = %{state | manifest: manifest} |> put_change(change)

    # ① 更新 active revision（durable 事件 + 快照）
    append_event(state, :revision_advanced, %{
      "revision" => Revision.to_map(Revision.new(rev, manifest.active, change.change_id))
    })

    append_event(state, :change_activated, %{
      "change_id" => change.change_id,
      "release_id" => release.release_id,
      "via" => to_string(via),
      "revision" => rev
    })

    persist_manifest(state.manifest, state.event_store)

    # ② 广播 module_ready ③进 worker 下一次投影 ⑤附版本/契约/用法/评测摘要
    notice = %{
      change_id: change.change_id,
      plugin_id: release.plugin_id,
      release_id: release.release_id,
      revision: rev,
      usage: release.usage,
      contract_version: release.contract_version,
      evaluation_summary: summarize_evaluation(change.evaluation_result)
    }

    notify(state, :module_ready, notice)

    state = %{state | pending_notices: [notice | state.pending_notices]}

    # §4.2/§4.4：active 变化 → 驱动 generation 切换（Binding Continuity）
    # + rule/prompt release 挂载进运行时（§6.3 存储身份 → 运行时身份）
    after_revision_change(state)

    {:ok, state}
  end

  # ── 内部：回退（§8.4 graph 级）──

  defp do_rollback(state, {:revision, target_rev}, reason, _opts) when is_integer(target_rev) do
    change =
      Change.new(%{
        reason: "rollback: #{reason}",
        author_agent: :coordinator,
        rollback_of: state.manifest.revision,
        base_revision: state.manifest.revision
      })

    case Manifest.rollback(state.manifest, target_rev, change.change_id) do
      {:ok, manifest} ->
        change = Change.transition(change, :active)
        state = %{state | manifest: manifest} |> put_change(change)

        append_event(state, :revision_advanced, %{
          "revision" => Revision.to_map(Revision.new(manifest.revision, manifest.active, change.change_id))
        })

        append_event(state, :change_rolled_back, %{
          "change_id" => change.change_id,
          "target_revision" => target_rev,
          "reason" => reason
        })

        persist_manifest(state.manifest, state.event_store)

        notify(state, :rolled_back, %{
          revision: manifest.revision,
          target_revision: target_rev,
          reason: reason
        })

        after_revision_change(state)

        {:ok, change, state}

      {:error, :revision_not_found} ->
        {:error, :revision_not_found, state}
    end
  end

  defp do_rollback(state, {:plugin, plugin_id, target_release}, reason, _opts) do
    plugin_id = to_string(plugin_id)
    current = state.manifest.active

    target_release =
      target_release ||
        case parent_of(current[plugin_id]) do
          nil -> nil
          parent -> parent
        end

    cond do
      not Map.has_key?(current, plugin_id) ->
        {:error, {:plugin_not_active, plugin_id}, state}

      is_nil(target_release) ->
        {:error, :no_rollback_target, state}

      true ->
        # 构造候选 revision：X 置目标 release，其余插件重新解析依赖图
        candidate = Map.put(current, plugin_id, target_release)

        case resolve_graph(candidate) do
          {:ok, resolved} ->
            do_rollback_via_revision(state, resolved, reason, "#{plugin_id} → #{target_release}")

          {:error, incompatible} ->
            {:error, {:incompatible_dependencies, incompatible}, state}
        end
    end
  end

  defp do_rollback_via_revision(state, active_map, reason, label) do
    change =
      Change.new(%{
        reason: "rollback: #{reason} (#{label})",
        author_agent: :coordinator,
        rollback_of: state.manifest.revision,
        base_revision: state.manifest.revision
      })

    manifest = %{
      state.manifest
      | revision: state.manifest.revision + 1,
        active: active_map,
        revisions:
          state.manifest.revisions ++
            [Revision.new(state.manifest.revision + 1, active_map, change.change_id)]
    }

    change = Change.transition(change, :active)
    state = %{state | manifest: manifest} |> put_change(change)

    append_event(state, :revision_advanced, %{
      "revision" => Revision.to_map(Revision.new(manifest.revision, active_map, change.change_id))
    })

    append_event(state, :change_rolled_back, %{
      "change_id" => change.change_id,
      "reason" => reason,
      "label" => label
    })

    persist_manifest(state.manifest, state.event_store)

    notify(state, :rolled_back, %{revision: manifest.revision, reason: reason})

    after_revision_change(state)

    {:ok, change, state}
  end

  # 依赖图重解析：每个 active release 的 dependencies 必须在图内可解析
  defp resolve_graph(active_map) do
    releases =
      Enum.reduce_while(active_map, {:ok, []}, fn {_pid, rid}, {:ok, acc} ->
        case PluginManager.fetch_or_builtin(rid) do
          {:ok, r} -> {:cont, {:ok, [r | acc]}}
          {:error, _} -> {:halt, {:error, [rid]}}
        end
      end)

    case releases do
      {:error, missing} ->
        {:error, missing}

      {:ok, rs} ->
        available = MapSet.new(Enum.map(rs, & &1.plugin_id))

        incompatible =
          Enum.flat_map(rs, fn r ->
            r.dependencies
            |> Enum.map(fn
              {id, _} -> to_string(id)
              id -> to_string(id)
            end)
            |> Enum.reject(&MapSet.member?(available, &1))
            |> Enum.map(&{r.plugin_id, &1})
          end)

        if incompatible == [], do: {:ok, active_map}, else: {:error, incompatible}
    end
  end

  defp parent_of(nil), do: nil

  defp parent_of(release_id) do
    case PluginManager.fetch_or_builtin(release_id) do
      {:ok, %Release{parent_release: parent}} -> parent
      _ -> nil
    end
  end

  # ── 内部：拒绝 / 降级 ──

  defp reject_change(state, %Change{} = change, reason) do
    change = Change.transition(change, :rejected)

    change = %{
      change
      | evaluation_result: change.evaluation_result || %{"rejected_reason" => reason}
    }

    append_event(state, :change_rejected, %{"change_id" => change.change_id, "reason" => reason})
    persist_change(change)

    {change, put_change(state, change)}
  end

  @doc """
  generation 启动失败/健康失败 → 逐级回退 known-good + 标 degraded + 保留证据（§8.4/§15.9）。
  不覆盖损坏 manifest。
  """
  def recover_known_good(server \\ __MODULE__, failed_rev, reason) do
    GenServer.call(server, {:recover_known_good, failed_rev, reason})
  end

  # ── revision 变化后的运行时驱动（§4.2 generation 切换 + §6.3 规则挂载）──

  defp after_revision_change(state) do
    drive_generation_switch(state)
    sync_runtime_rules(state.manifest.active)
    sync_runtime_prompts(state.manifest.active)
    :ok
  end

  # generation 切换：异步执行（Coordinator 不被切换阻塞）；失败 → known-good 恢复（§15.9）
  defp drive_generation_switch(state) do
    case Newbee.Environment.EvaluatorPool.current() do
      nil ->
        :ok

      pool ->
        rev = state.manifest.revision
        active_map = state.manifest.active
        coordinator = self()

        Task.start(fn ->
          case Newbee.Environment.EvaluatorPool.boot_candidate(pool, rev, active_map) do
            {:ok, _gen} ->
              case Newbee.Environment.EvaluatorPool.switch(pool) do
                {:ok, summary} ->
                  Newbee.Events.emit(:generation_switched, %{
                    revision: rev,
                    bindings: summary
                  })

                  # §4.4 step4：迁移摘要（迁了几个/tombstone 几个）进 worker 下一次投影
                  notice =
                    summary
                    |> Map.new(fn {k, v} -> {to_string(k), v} end)
                    |> Map.merge(%{"kind" => "generation_switched", "revision" => rev})

                  GenServer.call(coordinator, {:mark_healthy, rev, notice})

                {:error, reason} ->
                  Newbee.Events.emit(:generation_switch_failed, %{
                    revision: rev,
                    reason: inspect(reason)
                  })

                  recover_generation(coordinator, pool, rev, reason)
              end

            {:error, reason} ->
              Newbee.Events.emit(:generation_switch_failed, %{
                revision: rev,
                reason: inspect(reason)
              })

              recover_generation(coordinator, pool, rev, reason)
          end
        end)
    end

    :ok
  end

  # generation 启动/切换失败 → 逐级回退 known-good + 标 degraded（§8.4/§15.9）
  defp recover_generation(coordinator, pool, failed_rev, reason) do
    case recover_known_good(coordinator, failed_rev, inspect(reason)) do
      {:ok, good_rev, _change} ->
        # 用恢复后的 active 图重建 generation（不再递归恢复——失败则保持降级态）
        current = GenServer.call(coordinator, :current)

        with {:ok, _} <-
               Newbee.Environment.EvaluatorPool.boot_candidate(
                 pool,
                 current.revision,
                 current.active
               ),
             {:ok, _} <- Newbee.Environment.EvaluatorPool.switch(pool) do
          Newbee.Events.emit(:generation_switched, %{revision: good_rev, recovered: true})
        else
          _ ->
            Newbee.Events.emit(:generation_switch_failed, %{
              revision: good_rev,
              reason: "recovery boot failed (degraded)"
            })
        end

      {:error, _} ->
        :ok
    end
  end

  # rule release 挂载：active 图里的规则编译进规则引擎；不在图里的 release 规则卸载
  defp sync_runtime_rules(active_map) do
    mounted_key = {__MODULE__, :mounted_rules}

    active_rules =
      active_map
      |> Enum.flat_map(fn {plugin_id, release_id} ->
        if String.starts_with?(plugin_id, "rule.") do
          case PluginManager.fetch_or_builtin(release_id) do
            {:ok, release} -> [{plugin_id, release}]
            _ -> []
          end
        else
          []
        end
      end)

    mounted = :persistent_term.get(mounted_key, %{})

    # 挂载新激活的
    newly =
      Enum.flat_map(active_rules, fn {plugin_id, release} ->
        if Map.get(mounted, plugin_id) == release.release_id do
          []
        else
          case mount_rule(release) do
            :ok -> [{plugin_id, release.release_id}]
            _ -> []
          end
        end
      end)

    # 卸载不再 active 的
    active_ids = MapSet.new(Enum.map(active_rules, &elem(&1, 0)))

    for {plugin_id, _} <- mounted, not MapSet.member?(active_ids, plugin_id) do
      Newbee.DEE.Rules.remove(plugin_id)
    end

    kept = Map.take(mounted, MapSet.to_list(active_ids))
    :persistent_term.put(mounted_key, Map.merge(kept, Map.new(newly)))
    :ok
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  defp mount_rule(release) do
    # 编译 release 源码取 describe（pattern/injection 即 contract 数据）
    with [{_name, source} | _] <- Map.to_list(release.source_files),
         {:ok, %{envelope: env}} <- Newbee.Environment.PluginContract.validate_source(source, release.kind),
         %{pattern: pattern, injection: injection}
         when is_binary(pattern) and is_binary(injection) <-
           env.describe do
      Newbee.DEE.Rules.add(release.plugin_id, pattern, injection,
        source: :release,
        scope: Map.get(env.describe, :scope, :all)
      )
    else
      _ -> {:error, :bad_rule_release}
    end
  end

  # prompt release（L1 教训）挂载：usage 片段进投影 Guidance（persistent_term 供 Projection 读）
  defp sync_runtime_prompts(active_map) do
    prompts =
      active_map
      |> Enum.flat_map(fn {plugin_id, release_id} ->
        if String.starts_with?(plugin_id, "prompt.") do
          case PluginManager.fetch_or_builtin(release_id) do
            {:ok, release} ->
              [%{plugin_id: plugin_id, release_id: release_id, usage: release.usage}]

            _ ->
              []
          end
        else
          []
        end
      end)

    :persistent_term.put({__MODULE__, :active_prompts}, prompts)
    :ok
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  @doc "active prompt releases（L1 教训，Projection Guidance 用）。"
  def active_prompts do
    :persistent_term.get({__MODULE__, :active_prompts}, [])
  end

  # ── helpers ──

  defp check_expected_version(%Change{expected_version: nil}, _state), do: :ok

  defp check_expected_version(%Change{expected_version: v}, state) do
    if v == state.manifest.revision, do: :ok, else: {:error, :stale_expected_version}
  end

  defp put_change(state, change) do
    persist_change(change)
    %{state | changes: Map.put(state.changes, change.change_id, change)}
  end

  defp persist_change(%Change{} = change) do
    dir = Store.change_dir(change.change_id)
    File.mkdir_p!(dir)

    Store.write_atomic!(
      Path.join(dir, "change.json"),
      Jason.encode_to_iodata!(Change.to_map(change), pretty: true)
    )
  end

  defp append_event(state, topic, data) do
    {:ok, _ev} = Newbee.EventStore.append(state.event_store, topic, data)
    Newbee.Bus.emit(topic, data)
    :ok
  end

  defp persist_manifest(manifest, store) do
    manifest = %{manifest | checkpoint: Newbee.EventStore.watermark(store)}

    env = %{
      "revision" => manifest.revision,
      "active" => manifest.active,
      "checkpoint" => manifest.checkpoint,
      "manifest" => Manifest.to_map(manifest)
    }

    Store.save_environment(env)
  end

  # 通知 = 事件流中的消息 + 总线广播（§7.2/§7.3）；worker 忙时投影侧排队
  defp notify(state, kind, payload) do
    message = %{
      message_id: Newbee.Agent.Protocol.gen_message_id("coordinator"),
      project_id: File.cwd!(),
      sender: "coordinator",
      created_at: now_iso(),
      kind: kind,
      payload: payload
    }

    Store.append_jsonl!(Store.path(:messages), message)
    append_event(state, kind, Map.new(payload, fn {k, v} -> {to_string(k), safe_json(v)} end))
    Newbee.Bus.emit(kind, payload)
    :ok
  end

  defp safe_json(v) when is_atom(v), do: to_string(v)
  defp safe_json(v), do: v

  defp summarize_evaluation(nil), do: nil

  defp summarize_evaluation(result) when is_map(result) do
    %{
      passed: result["passed"] || result[:passed],
      failed_layers: result["failed_layers"] || result[:failed_layers] || []
    }
  end

  defp replay_coverage(state) do
    # 回放覆盖率 = 真正执行 counterfactual 的 change / 全部已评测 change。
    # Ring 不要求回放时 Verifier 会写 skipped=true，这不构成回放证据。
    evaluated =
      state.changes
      |> Map.values()
      |> Enum.filter(&is_map(&1.evaluation_result))

    case evaluated do
      [] ->
        0.0

      changes ->
        covered = Enum.count(changes, &counterfactual_evidence?/1)
        covered / length(changes)
    end
  end

  defp counterfactual_evidence?(change) do
    result = change.evaluation_result
    layers = result["layers"] || result[:layers] || %{}
    counterfactual = layers["counterfactual"] || layers[:counterfactual]

    is_map(counterfactual) and map_size(counterfactual) > 0 and
      not truthy?(counterfactual["skipped"] || counterfactual[:skipped])
  end

  defp truthy?(value), do: value in [true, "true"]

  defp now_iso, do: DateTime.utc_now() |> DateTime.to_iso8601()

  # 评测结果递归转 JSON 可编码形态（change.json 持久化用）
  defp json_safe(v) when is_map(v) and not is_struct(v),
    do: Map.new(v, fn {k, val} -> {to_string(k), json_safe(val)} end)

  defp json_safe(v) when is_list(v), do: Enum.map(v, &json_safe/1)
  defp json_safe(v) when is_tuple(v), do: v |> Tuple.to_list() |> Enum.map(&json_safe/1)
  defp json_safe(v) when is_atom(v), do: to_string(v)
  defp json_safe(v), do: v
end
