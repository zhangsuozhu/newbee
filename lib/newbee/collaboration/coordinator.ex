defmodule Newbee.Collaboration.Coordinator do
  @moduledoc """
  会话群协作域的单写者：持久化群组、成员与消息，并从 EventStore 重放恢复。

  消息语义为可靠事件：先落盘，再按 delivery 调度——notify 只进时间线，
  queue/wake 投递给目标会话的模型运行时（忙时排队，不强行打断当前 turn）。
  任务 lease 已存在；模型派生的子会话默认使用独立 worktree，避免并行修改互相污染。
  """

  use GenServer

  alias Newbee.EventStore

  @default_root Path.join(System.user_home!(), ".newbee/collaboration")
  @roles ~w(coordinator worker reviewer observer tester)
  @message_kinds ~w(chat question task_assign task_progress task_result artifact system error)
  @deliveries ~w(notify queue wake)
  @max_members 12
  @max_tasks 64
  @max_spawn_total 32
  @max_task_title_bytes 512
  @max_task_description_bytes 32_768
  @max_task_payload_bytes 65_536
  @max_evidence_items 64
  @max_dependency_count 64
  @max_write_scope_count 64
  @default_max_depth 3
  @default_wait_timeout_ms 30_000
  @max_wait_timeout_ms 120_000
  @orphan_sweep_interval_ms 60_000

  defstruct store: nil, path: nil, groups: %{}, commands: MapSet.new(), waiters: []

  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  def child_spec(opts) do
    %{id: Keyword.get(opts, :name, __MODULE__), start: {__MODULE__, :start_link, [opts]}}
  end

  def create_group(attrs, server \\ __MODULE__),
    do: GenServer.call(server, {:create_group, attrs})

  def list(session_id \\ nil, server \\ __MODULE__),
    do: GenServer.call(server, {:list, session_id})

  def get(group_id, server \\ __MODULE__), do: GenServer.call(server, {:get, group_id})

  def permission_request(session_id, preview, server \\ __MODULE__),
    do: GenServer.call(server, {:permission_request, session_id, preview})

  def can_approve_permission?(actor_session_id, target_session_id, server \\ __MODULE__),
    do: GenServer.call(server, {:can_approve_permission?, actor_session_id, target_session_id})

  def groups_for_session(session_id, server \\ __MODULE__),
    do: GenServer.call(server, {:groups_for_session, session_id})

  def add_member(group_id, attrs, server \\ __MODULE__),
    do: GenServer.call(server, {:add_member, group_id, attrs})

  def delegate(group_id, attrs, server \\ __MODULE__),
    do: GenServer.call(server, {:delegate, group_id, attrs})

  def remove_member(group_id, attrs, server \\ __MODULE__),
    do: GenServer.call(server, {:remove_member, group_id, attrs})

  def send_message(group_id, attrs, server \\ __MODULE__),
    do: GenServer.call(server, {:send_message, group_id, attrs})

  def messages(group_id, opts \\ [], server \\ __MODULE__),
    do: GenServer.call(server, {:messages, group_id, opts})

  def activity(group_id, opts \\ [], server \\ __MODULE__),
    do: GenServer.call(server, {:activity, group_id, opts})

  def member?(group_id, session_id, server \\ __MODULE__),
    do: GenServer.call(server, {:member?, group_id, session_id})

  def create_task(group_id, attrs, server \\ __MODULE__),
    do: GenServer.call(server, {:create_task, group_id, attrs})

  def update_task(group_id, task_id, attrs, server \\ __MODULE__),
    do: GenServer.call(server, {:update_task, group_id, task_id, attrs})

  def update_workspace(group_id, task_id, attrs, server \\ __MODULE__),
    do: GenServer.call(server, {:update_workspace, group_id, task_id, attrs})

  def tasks(group_id, server \\ __MODULE__),
    do: GenServer.call(server, {:tasks, group_id})

  def claim_task(group_id, task_id, session_id, server \\ __MODULE__),
    do: GenServer.call(server, {:claim_task, group_id, task_id, session_id})

  def set_group_status(group_id, status, session_id, server \\ __MODULE__),
    do: GenServer.call(server, {:set_group_status, group_id, status, session_id})

  def renew_task(group_id, task_id, session_id, seconds \\ 300, server \\ __MODULE__),
    do: GenServer.call(server, {:renew_task, group_id, task_id, session_id, seconds})

  def delete_group(group_id, session_id, server \\ __MODULE__),
    do: GenServer.call(server, {:delete_group, group_id, session_id})

  @doc false
  def can_delegate(group_id, parent_session_id, server \\ __MODULE__),
    do: GenServer.call(server, {:can_delegate, group_id, parent_session_id})

  @doc false
  def board(group_id, session_id, server \\ __MODULE__),
    do: GenServer.call(server, {:board, group_id, session_id})

  @doc false
  def board_create_task(group_id, attrs, server \\ __MODULE__),
    do: GenServer.call(server, {:board_create_task, group_id, attrs})

  @doc false
  def board_update_task(group_id, task_id, attrs, server \\ __MODULE__),
    do: GenServer.call(server, {:board_update_task, group_id, task_id, attrs})

  @doc false
  def board_claim(group_id, task_id, attrs, server \\ __MODULE__),
    do: GenServer.call(server, {:board_claim, group_id, task_id, attrs})

  @doc false
  def board_verify(group_id, task_id, attrs, server \\ __MODULE__) do
    with {:ok, prepared} <-
           GenServer.call(server, {:board_verify_prepare, group_id, task_id, attrs}),
         {:ok, attestation} <-
           Newbee.Collaboration.Verification.verify(prepared.task, prepared.root) do
      GenServer.call(
        server,
        {:board_verify_commit, group_id, task_id, prepared.attrs, attestation}
      )
    end
  end

  @doc false
  def inbox(group_id, session_id, since_seq \\ 0, server \\ __MODULE__),
    do: GenServer.call(server, {:inbox, group_id, session_id, since_seq})

  @doc false
  def wait(
        group_id,
        session_id,
        since_revision,
        timeout_ms \\ @default_wait_timeout_ms,
        server \\ __MODULE__
      ) do
    timeout = clamp_wait_timeout(timeout_ms)

    GenServer.call(
      server,
      {:wait, group_id, session_id, since_revision, timeout},
      timeout + 5_000
    )
  end

  @impl true
  def init(opts) do
    root = Keyword.get(opts, :root, @default_root)
    path = Keyword.get(opts, :path, Path.join(root, "events.jsonl"))
    File.mkdir_p!(Path.dirname(path))

    {:ok, store} =
      EventStore.start_link(path: path, durability: Keyword.get(opts, :durability, :batch))

    state = %__MODULE__{store: store, path: path}
    schedule_orphan_sweep()
    {:ok, replay(state)}
  end

  @impl true
  def handle_info(:sweep_orphans, state) do
    {:noreply, sweep_orphans(state) |> tap(fn _ -> schedule_orphan_sweep() end)}
  end

  def handle_info({:collab_wait_timeout, ref}, state) do
    case Enum.split_with(state.waiters, &(&1.ref == ref)) do
      {[waiter], rest} ->
        Process.demonitor(ref, [:flush])

        GenServer.reply(
          waiter.from,
          {:ok, %{"kind" => "timeout", "revision" => group_revision(state, waiter.group_id)}}
        )

        {:noreply, %{state | waiters: rest}}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    {dropped, rest} = Enum.split_with(state.waiters, &(&1.ref == ref))
    Enum.each(dropped, &Process.cancel_timer(&1.timer))
    {:noreply, %{state | waiters: rest}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def handle_call({:create_group, attrs}, _from, state) do
    with {:ok, attrs} <- normalize_group(attrs),
         :ok <- unique_command(state, attrs["command_id"]) do
      group_id = attrs["group_id"] || id("grp")
      member_id = id("mem")
      now = now_iso()

      group = %{
        "group_id" => group_id,
        "title" => attrs["title"],
        "goal" => attrs["goal"],
        "project_root" => attrs["project_root"],
        "created_by_session_id" => attrs["session_id"],
        "coordinator_session_id" => attrs["session_id"],
        "status" => "running",
        "members" => [
          %{
            "member_id" => member_id,
            "session_id" => attrs["session_id"],
            "role" => "coordinator",
            "depth" => 0,
            "state" => "idle",
            "parent_session_id" => nil,
            "joined_at" => now
          }
        ],
        "messages" => [],
        "tasks" => [],
        "next_seq" => 0,
        "max_depth" => attrs["max_depth"],
        "max_total" => attrs["max_total"],
        "total_spawned" => 1,
        "created_at" => now,
        "updated_at" => now
      }

      event = event("collab_group_created", group_id, %{"group" => group}, attrs["command_id"])
      {:ok, persisted} = append(state, event)
      next = apply_event(state, persisted)
      broadcast(persisted, next.groups[group_id])
      {:reply, {:ok, public_group(next.groups[group_id])}, next}
    else
      {:error, code, message} -> {:reply, {:error, code, message}, state}
    end
  end

  def handle_call({:list, session_id}, _from, state) do
    # 列出全部组（不按当前会话过滤），仅在组上标记当前会话是否成员，
    # 供前端侧栏稳定展示"哪些已分组 / 哪些未分组"——切到未分组会话不再清空组视图。
    groups =
      state.groups
      |> Map.values()
      |> Enum.sort_by(& &1["updated_at"], :desc)
      |> Enum.map(fn group ->
        summary(group)
        |> Map.put(
          "current_session_member",
          not is_nil(session_id) and session_member?(group, session_id)
        )
      end)

    {:reply, groups, state}
  end

  def handle_call({:get, group_id}, _from, state) do
    case state.groups[group_id] do
      nil -> {:reply, {:error, "not_found", "会话群不存在"}, state}
      group -> {:reply, {:ok, public_group(group)}, state}
    end
  end

  def handle_call({:groups_for_session, session_id}, _from, state) do
    groups =
      state.groups
      |> Map.values()
      |> Enum.filter(&session_member?(&1, session_id))
      |> Enum.map(&summary/1)

    {:reply, groups, state}
  end

  def handle_call({:member?, group_id, session_id}, _from, state) do
    {:reply, match?(%{}, state.groups[group_id]) and session_member?(state.groups[group_id], session_id), state}
  end

  def handle_call({:add_member, group_id, attrs}, _from, state) do
    with {:ok, group} <- fetch_group(state, group_id),
         {:ok, attrs} <- normalize_member(attrs),
         :ok <- unique_command(state, attrs["command_id"]),
         :ok <- ensure_member_capacity(group),
         :ok <- ensure_not_member(group, attrs["session_id"]) do
      member = %{
        "member_id" => id("mem"),
        "session_id" => attrs["session_id"],
        "role" => attrs["role"],
        "state" => "idle",
        "parent_session_id" => attrs["parent_session_id"],
        "joined_at" => now_iso()
      }

      event = event("collab_member_added", group_id, %{"member" => member}, attrs["command_id"])
      {:ok, persisted} = append(state, event)
      next = apply_event(state, persisted)
      broadcast(persisted, next.groups[group_id])
      {:reply, {:ok, member}, next}
    else
      {:error, code, message} -> {:reply, {:error, code, message}, state}
    end
  end

  def handle_call({:delegate, group_id, raw_attrs}, _from, state) do
    with {:ok, group} <- fetch_group(state, group_id),
         :ok <- group_accepts_tasks(group),
         {:ok, attrs} <- normalize_delegation(raw_attrs),
         {:ok, attrs} <- validate_delegation_contract(attrs),
         :ok <- unique_command(state, attrs["command_id"]),
         :ok <- ensure_member(group, attrs["parent_session_id"]),
         :ok <- command_acceptance_allowed(group, attrs["parent_session_id"], attrs["acceptance"]),
         :ok <- ensure_spawn_capacity(group, attrs["parent_session_id"]),
         :ok <- ensure_member_capacity(group),
         :ok <- ensure_task_capacity(group),
         :ok <- ensure_not_member(group, attrs["session_id"]),
         :ok <- dependencies_exist(group, attrs["depends_on"]) do
      now = now_iso()
      depth = member_depth(group, attrs["parent_session_id"]) + 1

      member = %{
        "member_id" => id("mem"),
        "session_id" => attrs["session_id"],
        "role" => attrs["role"],
        "persona" => attrs["persona"],
        "protocol_version" => attrs["protocol_version"],
        "depth" => depth,
        "state" => "idle",
        "parent_session_id" => attrs["parent_session_id"],
        "workspace" => attrs["workspace"],
        "joined_at" => now
      }

      task = %{
        "task_id" => id("task"),
        "group_id" => group_id,
        "protocol_version" => attrs["protocol_version"],
        "title" => attrs["title"],
        "description" => attrs["description"],
        "acceptance" => attrs["acceptance"],
        "acceptance_sha256" =>
          if(attrs["protocol_version"] == 2,
            do: Newbee.Collaboration.Verification.contract_sha256(attrs["acceptance"]),
            else: nil
          ),
        "depends_on" => attrs["depends_on"],
        "write_scope" => attrs["write_scope"],
        "created_by_session_id" => attrs["parent_session_id"],
        "assigned_session_id" => attrs["session_id"],
        "status" => "assigned",
        "progress" => nil,
        "result" => nil,
        "evidence" => [],
        "verification" => if(attrs["protocol_version"] == 2, do: %{"status" => "pending"}, else: nil),
        "workspace" => attrs["workspace"],
        "lease_owner" => nil,
        "lease_until" => nil,
        "attempt" => 0,
        "created_at" => now,
        "updated_at" => now
      }

      event =
        event(
          "collab_delegated",
          group_id,
          %{"member" => member, "task" => task},
          attrs["command_id"]
        )

      {:ok, persisted} = append(state, event)
      next = apply_event(state, persisted)
      current_task = task |> Map.put("board_revision", next.groups[group_id]["revision"])
      broadcast(persisted, next.groups[group_id])
      dispatch_task(current_task)
      {:reply, {:ok, %{member: member, task: current_task}}, next}
    else
      {:error, code, message} -> {:reply, {:error, code, message}, state}
    end
  end

  def handle_call({:remove_member, group_id, attrs}, _from, state) do
    with {:ok, group} <- fetch_group(state, group_id),
         {:ok, attrs} <- normalize_member_removal(attrs),
         :ok <- unique_command(state, attrs["command_id"]),
         :ok <- ensure_coordinator(group, attrs["actor_session_id"]) do
      {state, group} = cancel_orphans(state, group)

      with {:ok, member} <- removable_member(group, attrs["session_id"]) do
        event =
          event(
            "collab_member_removed",
            group_id,
            %{"member" => member, "removed_by_session_id" => attrs["actor_session_id"]},
            attrs["command_id"]
          )

        {:ok, persisted} = append(state, event)
        next = apply_event(state, persisted)
        broadcast(persisted, group)
        {:reply, {:ok, member}, next}
      else
        {:error, code, message} -> {:reply, {:error, code, message}, state}
      end
    else
      {:error, code, message} -> {:reply, {:error, code, message}, state}
    end
  end

  def handle_call({:send_message, group_id, attrs}, _from, state) do
    with {:ok, group} <- fetch_group(state, group_id),
         {:ok, attrs} <- normalize_message(attrs),
         :ok <- unique_command(state, attrs["command_id"]),
         :ok <- unique_message(group, attrs["message_id"]),
         :ok <- ensure_member(group, attrs["sender_session_id"]),
         :ok <- ensure_recipient(group, attrs["to_session_id"]) do
      seq = group["next_seq"] + 1

      message = %{
        "message_id" => attrs["message_id"] || id("msg"),
        "group_id" => group_id,
        "seq" => seq,
        "sender_session_id" => attrs["sender_session_id"],
        "to_session_id" => attrs["to_session_id"],
        "kind" => attrs["kind"],
        "delivery" => attrs["delivery"],
        "body" => attrs["body"],
        "created_at" => now_iso()
      }

      event =
        event("collab_message_created", group_id, %{"message" => message}, attrs["command_id"])

      {:ok, persisted} = append(state, event)
      next = apply_event(state, persisted)
      broadcast(persisted, next.groups[group_id])
      dispatch_message(message, next.groups[group_id])
      {:reply, {:ok, message}, next}
    else
      {:error, code, message} -> {:reply, {:error, code, message}, state}
    end
  end

  def handle_call({:create_task, group_id, attrs}, _from, state) do
    with {:ok, group} <- fetch_group(state, group_id),
         :ok <- group_accepts_tasks(group),
         {:ok, attrs} <- normalize_task(attrs),
         :ok <- unique_command(state, attrs["command_id"]),
         :ok <- ensure_member(group, attrs["created_by_session_id"]),
         :ok <- ensure_task_capacity(group),
         :ok <- ensure_recipient(group, attrs["assigned_session_id"]) do
      task = %{
        "task_id" => id("task"),
        "group_id" => group_id,
        "title" => attrs["title"],
        "description" => attrs["description"],
        "acceptance" => attrs["acceptance"],
        "created_by_session_id" => attrs["created_by_session_id"],
        "assigned_session_id" => attrs["assigned_session_id"],
        "status" => if(attrs["assigned_session_id"], do: "assigned", else: "pending"),
        "progress" => nil,
        "result" => nil,
        "lease_owner" => nil,
        "lease_until" => nil,
        "attempt" => 0,
        "created_at" => now_iso(),
        "updated_at" => now_iso()
      }

      event = event("collab_task_created", group_id, %{"task" => task}, attrs["command_id"])
      {:ok, persisted} = append(state, event)
      next = apply_event(state, persisted)
      broadcast(persisted, next.groups[group_id])
      dispatch_task(task)
      {:reply, {:ok, task}, next}
    else
      {:error, code, message} -> {:reply, {:error, code, message}, state}
    end
  end

  def handle_call({:update_task, group_id, task_id, attrs}, _from, state) do
    with {:ok, group} <- fetch_group(state, group_id),
         {:ok, task} <- fetch_task(group, task_id),
         :ok <- legacy_task_api(task),
         {:ok, attrs} <- normalize_task_update(attrs),
         :ok <- unique_command(state, attrs["command_id"]),
         :ok <- ensure_member(group, attrs["session_id"]),
         :ok <- task_actor_allowed(task, attrs["session_id"]),
         :ok <- valid_task_transition(task["status"], attrs["status"]) do
      first_result_terminal? =
        attrs["status"] in ["succeeded", "failed"] and
          task["status"] not in ["succeeded", "failed"]

      first_review_terminal? =
        attrs["status"] in ["succeeded", "failed", "cancelled"] and
          task["status"] not in ["succeeded", "failed", "cancelled"]

      updated =
        task
        |> Map.put("status", attrs["status"])
        |> maybe_put("progress", attrs["progress"])
        |> maybe_put("result", attrs["result"])
        |> maybe_mark_workspace_pending(first_review_terminal?)
        |> Map.put("updated_at", now_iso())

      event = event("collab_task_updated", group_id, %{"task" => updated}, attrs["command_id"])
      {:ok, persisted} = append(state, event)
      next = apply_event(state, persisted)
      broadcast(persisted, next.groups[group_id])
      if first_result_terminal?, do: dispatch_result(updated)
      {:reply, {:ok, updated}, next}
    else
      {:error, code, message} -> {:reply, {:error, code, message}, state}
    end
  end

  def handle_call({:update_workspace, group_id, task_id, attrs}, _from, state) do
    with {:ok, group} <- fetch_group(state, group_id),
         {:ok, task} <- fetch_task(group, task_id),
         {:ok, attrs} <- normalize_workspace_update(attrs),
         :ok <- unique_command(state, attrs["command_id"]),
         :ok <- ensure_coordinator(group, attrs["actor_session_id"]),
         {:ok, updated} <- transition_workspace(task, attrs) do
      event =
        event(
          "collab_workspace_updated",
          group_id,
          %{"task" => updated, "action" => attrs["action"]},
          attrs["command_id"]
        )

      {:ok, persisted} = append(state, event)
      next = apply_event(state, persisted)
      broadcast(persisted, next.groups[group_id])
      {:reply, {:ok, updated}, next}
    else
      {:error, code, message} -> {:reply, {:error, code, message}, state}
    end
  end

  def handle_call({:tasks, group_id}, _from, state) do
    case fetch_group(state, group_id) do
      {:ok, group} -> {:reply, {:ok, group["tasks"] || []}, state}
      error -> {:reply, error, state}
    end
  end

  def handle_call({:claim_task, group_id, task_id, session_id}, _from, state) do
    with {:ok, group} <- fetch_group(state, group_id),
         {:ok, task} <- fetch_task(group, task_id),
         :ok <- legacy_task_api(task),
         :ok <- ensure_member(group, session_id),
         :ok <- task_claimable(task, session_id) do
      claimed =
        task
        |> Map.put("assigned_session_id", session_id)
        |> Map.put("status", "running")
        |> Map.put("lease_owner", session_id)
        |> Map.put(
          "lease_until",
          DateTime.add(DateTime.utc_now(), 300, :second) |> DateTime.to_iso8601()
        )
        |> Map.put("attempt", (task["attempt"] || 0) + 1)
        |> Map.put("updated_at", now_iso())

      event = event("collab_task_claimed", group_id, %{"task" => claimed}, nil)
      {:ok, persisted} = append(state, event)
      next = apply_event(state, persisted)
      broadcast(persisted, next.groups[group_id])
      dispatch_task(claimed)
      {:reply, {:ok, claimed}, next}
    else
      {:error, code, message} -> {:reply, {:error, code, message}, state}
    end
  end

  def handle_call({:set_group_status, group_id, status, session_id}, _from, state) do
    with {:ok, group} <- fetch_group(state, group_id),
         :ok <- ensure_coordinator(group, session_id),
         true <- status in ["running", "paused", "cancelled"] do
      updated = Map.put(group, "status", status) |> Map.put("updated_at", now_iso())
      event = event("collab_group_status_changed", group_id, %{"status" => status}, nil)
      {:ok, persisted} = append(state, event)
      next = apply_event(state, persisted)
      broadcast(persisted, next.groups[group_id])
      {:reply, {:ok, public_group(updated)}, next}
    else
      false -> {:reply, {:error, "bad_request", "未知群组状态"}, state}
      {:error, code, message} -> {:reply, {:error, code, message}, state}
    end
  end

  def handle_call({:renew_task, group_id, task_id, session_id, seconds}, _from, state) do
    with {:ok, group} <- fetch_group(state, group_id),
         {:ok, task} <- fetch_task(group, task_id),
         :ok <- legacy_task_api(task),
         :ok <- ensure_member(group, session_id),
         :ok <- lease_owner(task, session_id),
         true <- is_integer(seconds) and seconds in 30..3600 do
      renewed =
        task
        |> Map.put(
          "lease_until",
          DateTime.add(DateTime.utc_now(), seconds, :second) |> DateTime.to_iso8601()
        )
        |> Map.put("updated_at", now_iso())

      event = event("collab_task_lease_renewed", group_id, %{"task" => renewed}, nil)
      {:ok, persisted} = append(state, event)
      next = apply_event(state, persisted)
      broadcast(persisted, next.groups[group_id])
      {:reply, {:ok, renewed}, next}
    else
      false -> {:reply, {:error, "bad_request", "lease 时长必须是 30-3600 秒"}, state}
      {:error, code, message} -> {:reply, {:error, code, message}, state}
    end
  end

  def handle_call({:delete_group, group_id, session_id}, _from, state) do
    with {:ok, group} <- fetch_group(state, group_id),
         :ok <- ensure_coordinator(group, session_id) do
      {state, group} = cancel_orphans(state, group)

      active_task? =
        Enum.any?(group["tasks"] || [], fn task ->
          task["status"] not in ["succeeded", "failed", "cancelled"]
        end)

      if active_task? do
        {:reply, {:error, "busy", "组内有进行中的任务，无法删除"}, state}
      else
        event = event("collab_group_deleted", group_id, %{"group_id" => group_id}, nil)
        {:ok, persisted} = append(state, event)
        next = apply_event(state, persisted)
        broadcast(persisted, group)
        {:reply, {:ok, %{"group_id" => group_id}}, next}
      end
    else
      {:error, code, message} -> {:reply, {:error, code, message}, state}
    end
  end

  def handle_call({:can_approve_permission?, actor_session_id, target_session_id}, _from, state) do
    allowed? =
      actor_session_id == target_session_id or
        Enum.any?(state.groups, fn {_id, group} ->
          target = Enum.find(group["members"], &(&1["session_id"] == target_session_id))

          target &&
            actor_session_id in [target["parent_session_id"], group["coordinator_session_id"]]
        end)

    {:reply, allowed?, state}
  end

  def handle_call({:permission_request, session_id, preview}, _from, state) do
    case Enum.find(state.groups, fn {_id, group} -> session_member?(group, session_id) end) do
      {_id, group} ->
        member = Enum.find(group["members"], &(&1["session_id"] == session_id))

        approvers =
          [member && member["parent_session_id"], group["coordinator_session_id"]]
          |> Enum.filter(&is_binary/1)
          |> Enum.uniq()

        event = %{
          "event_id" => id("perm"),
          "topic" => "collab_permission_ask",
          "group_id" => group["group_id"],
          "payload" => %{
            "request_session_id" => session_id,
            "preview" => preview,
            "approver_session_ids" => approvers
          },
          "session_ids" => approvers,
          "at" => now_iso()
        }

        if Process.whereis(Newbee.Bus), do: Newbee.Bus.emit(:collab_event, event)
        {:reply, :ok, state}

      nil ->
        {:reply, {:error, "not_member", "会话不属于任何工作组"}, state}
    end
  end

  def handle_call({:activity, group_id, opts}, _from, state) do
    with {:ok, _group} <- fetch_group(state, group_id) do
      since = Keyword.get(opts, :since, 0)
      limit = Keyword.get(opts, :limit, 100) |> max(1) |> min(500)

      activity =
        state.path
        |> EventStore.replay(since)
        |> Enum.filter(&(to_string(&1.data["group_id"]) == group_id))
        |> Enum.take(-limit)
        |> Enum.map(fn event ->
          %{
            "event_id" => event.id,
            "topic" => to_string(event.topic),
            "payload" => event.data["payload"],
            "at" => event.at
          }
        end)

      {:reply, {:ok, activity}, state}
    else
      {:error, code, message} -> {:reply, {:error, code, message}, state}
    end
  end

  def handle_call({:messages, group_id, opts}, _from, state) do
    with {:ok, group} <- fetch_group(state, group_id) do
      since = Keyword.get(opts, :since, 0)
      limit = Keyword.get(opts, :limit, 100) |> max(1) |> min(500)

      messages =
        group["messages"]
        |> Enum.filter(&(&1["seq"] > since))
        |> Enum.take(-limit)

      {:reply, {:ok, messages}, state}
    else
      {:error, code, message} -> {:reply, {:error, code, message}, state}
    end
  end

  def handle_call({:can_delegate, group_id, parent_session_id}, _from, state) do
    result =
      with {:ok, group} <- fetch_group(state, group_id),
           :ok <- group_accepts_tasks(group),
           :ok <- ensure_member(group, parent_session_id),
           :ok <- ensure_spawn_capacity(group, parent_session_id),
           :ok <- ensure_member_capacity(group),
           :ok <- ensure_task_capacity(group) do
        :ok
      end

    {:reply, result, state}
  end

  def handle_call({:board, group_id, session_id}, _from, state) do
    with {:ok, group} <- fetch_group(state, group_id),
         :ok <- ensure_member(group, session_id) do
      tasks = Enum.sort_by(group["tasks"] || [], & &1["created_at"])

      {:reply,
       {:ok,
        %{
          "group_id" => group_id,
          "revision" => group["revision"] || 0,
          "tasks" => tasks,
          "write_scope_overlaps" => write_scope_overlaps(tasks)
        }}, state}
    else
      {:error, code, message} -> {:reply, {:error, code, message}, state}
    end
  end

  def handle_call({:board_create_task, group_id, raw_attrs}, _from, state) do
    with {:ok, group} <- fetch_group(state, group_id),
         :ok <- group_accepts_tasks(group),
         {:ok, attrs} <- normalize_board_task(raw_attrs),
         :ok <- ensure_member(group, attrs["session_id"]),
         :ok <- expected_revision(group, attrs["expected_revision"]),
         :ok <- unique_command(state, attrs["command_id"]),
         :ok <- ensure_task_capacity(group),
         :ok <- ensure_recipient(group, attrs["assigned_session_id"]),
         :ok <- dependencies_exist(group, attrs["depends_on"]),
         {:ok, acceptance} <-
           Newbee.Collaboration.Verification.normalize_contract(attrs["acceptance"]),
         :ok <- command_acceptance_allowed(group, attrs["session_id"], acceptance) do
      now = now_iso()
      ready = dependencies_completed?(group, attrs["depends_on"])

      task = %{
        "task_id" => id("task"),
        "group_id" => group_id,
        "protocol_version" => 2,
        "title" => attrs["title"],
        "description" => attrs["description"],
        "acceptance" => acceptance,
        "acceptance_sha256" => Newbee.Collaboration.Verification.contract_sha256(acceptance),
        "depends_on" => attrs["depends_on"],
        "write_scope" => attrs["write_scope"],
        "created_by_session_id" => attrs["session_id"],
        "assigned_session_id" => attrs["assigned_session_id"],
        "status" => initial_board_status(attrs["assigned_session_id"], ready),
        "progress" => nil,
        "result" => nil,
        "evidence" => [],
        "verification" => %{"status" => "pending"},
        "lease_owner" => nil,
        "lease_until" => nil,
        "attempt" => 0,
        "created_at" => now,
        "updated_at" => now
      }

      event = event("collab_task_created", group_id, %{"task" => task}, attrs["command_id"])
      {:ok, persisted} = append(state, event)
      next = apply_event(state, persisted)
      revision = next.groups[group_id]["revision"]
      delivered = Map.put(task, "board_revision", revision)
      broadcast(persisted, next.groups[group_id])
      if ready, do: dispatch_task(delivered)

      {:reply,
       {:ok,
        %{
          "task" => delivered,
          "revision" => revision,
          "warnings" => task_scope_warnings(next.groups[group_id]["tasks"], task)
        }}, next}
    else
      {:error, code, message} -> {:reply, {:error, code, message}, state}
    end
  end

  def handle_call({:board_update_task, group_id, task_id, raw_attrs}, _from, state) do
    with {:ok, group} <- fetch_group(state, group_id),
         {:ok, task} <- fetch_task(group, task_id),
         {:ok, attrs} <- normalize_board_update(raw_attrs),
         :ok <- ensure_member(group, attrs["session_id"]),
         :ok <- expected_revision(group, attrs["expected_revision"]),
         :ok <- unique_command(state, attrs["command_id"]),
         :ok <- board_actor_allowed(group, task, attrs["session_id"]),
         :ok <- board_fields_allowed(group, task, attrs),
         :ok <- validate_board_status_change(group, task, attrs),
         {:ok, acceptance} <- normalize_updated_acceptance(task, attrs),
         :ok <- command_acceptance_change_allowed(group, attrs["session_id"], attrs["acceptance"], acceptance),
         :ok <- dependencies_exist(group, attrs["depends_on"] || task["depends_on"] || []),
         :ok <-
           dependency_graph_acyclic(
             group,
             task_id,
             attrs["depends_on"] || task["depends_on"] || []
           ) do
      updated =
        task
        |> maybe_put("title", attrs["title"])
        |> maybe_put("description", attrs["description"])
        |> Map.put("acceptance", acceptance)
        |> Map.put(
          "acceptance_sha256",
          Newbee.Collaboration.Verification.contract_sha256(acceptance)
        )
        |> maybe_reset_verification(attrs["acceptance"])
        |> maybe_put("depends_on", attrs["depends_on"])
        |> maybe_put("write_scope", attrs["write_scope"])
        |> maybe_put("status", attrs["status"])
        |> maybe_put("progress", attrs["progress"])
        |> maybe_put("result", attrs["result"])
        |> maybe_put("evidence", attrs["evidence"])
        |> Map.put("updated_at", now_iso())

      event = event("collab_task_updated", group_id, %{"task" => updated}, attrs["command_id"])
      {:ok, persisted} = append(state, event)
      next = apply_event(state, persisted)
      revision = next.groups[group_id]["revision"]
      broadcast(persisted, next.groups[group_id])

      {:reply,
       {:ok,
        %{
          "task" => Map.put(updated, "board_revision", revision),
          "revision" => revision,
          "warnings" => task_scope_warnings(next.groups[group_id]["tasks"], updated)
        }}, next}
    else
      {:error, code, message} -> {:reply, {:error, code, message}, state}
    end
  end

  def handle_call({:board_claim, group_id, task_id, raw_attrs}, _from, state) do
    with {:ok, group} <- fetch_group(state, group_id),
         {:ok, task} <- fetch_task(group, task_id),
         {:ok, attrs} <- normalize_board_claim(raw_attrs),
         :ok <- ensure_member(group, attrs["session_id"]),
         :ok <- expected_revision(group, attrs["expected_revision"]),
         :ok <- unique_command(state, attrs["command_id"]),
         :ok <- dependencies_completed(group, task["depends_on"] || []),
         :ok <- task_claimable(task, attrs["session_id"]) do
      claimed =
        task
        |> Map.put("assigned_session_id", attrs["session_id"])
        |> Map.put("status", "running")
        |> Map.put("lease_owner", attrs["session_id"])
        |> Map.put(
          "lease_until",
          DateTime.add(DateTime.utc_now(), 300, :second) |> DateTime.to_iso8601()
        )
        |> Map.put("attempt", (task["attempt"] || 0) + 1)
        |> Map.put("updated_at", now_iso())

      event = event("collab_task_claimed", group_id, %{"task" => claimed}, attrs["command_id"])
      {:ok, persisted} = append(state, event)
      next = apply_event(state, persisted)
      revision = next.groups[group_id]["revision"]
      broadcast(persisted, next.groups[group_id])
      dispatch_task(Map.put(claimed, "board_revision", revision))
      {:reply, {:ok, %{"task" => claimed, "revision" => revision}}, next}
    else
      {:error, code, message} -> {:reply, {:error, code, message}, state}
    end
  end

  def handle_call({:board_verify_prepare, group_id, task_id, raw_attrs}, _from, state) do
    with {:ok, group} <- fetch_group(state, group_id),
         {:ok, task} <- fetch_task(group, task_id),
         {:ok, attrs} <- normalize_board_verify(raw_attrs),
         :ok <- ensure_coordinator(group, attrs["session_id"]),
         :ok <- expected_revision(group, attrs["expected_revision"]),
         :ok <- unique_command(state, attrs["command_id"]),
         :ok <- submitted_task(task),
         {:ok, root} <- verification_root(group, task) do
      {:reply, {:ok, %{task: task, root: root, attrs: attrs}}, state}
    else
      {:error, code, message} -> {:reply, {:error, code, message}, state}
    end
  end

  def handle_call(
        {:board_verify_commit, group_id, task_id, attrs, attestation},
        _from,
        state
      ) do
    with {:ok, group} <- fetch_group(state, group_id),
         {:ok, task} <- fetch_task(group, task_id),
         :ok <- ensure_coordinator(group, attrs["session_id"]),
         :ok <- expected_revision(group, attrs["expected_revision"]),
         :ok <- unique_command(state, attrs["command_id"]),
         :ok <- submitted_task(task),
         :ok <- attestation_matches(task, attestation) do
      passed = attestation["all_passed"] == true

      updated =
        task
        |> Map.put("status", if(passed, do: "succeeded", else: "blocked"))
        |> Map.put(
          "verification",
          Map.put(attestation, "status", if(passed, do: "passed", else: "failed"))
        )
        |> Map.put("updated_at", now_iso())

      event = event("collab_task_updated", group_id, %{"task" => updated}, attrs["command_id"])
      {:ok, persisted} = append(state, event)
      next = apply_event(state, persisted)
      broadcast(persisted, next.groups[group_id])
      {next, activated} = activate_ready_dependents(next, group_id)
      revision = next.groups[group_id]["revision"]
      Enum.each(activated, &dispatch_task(Map.put(&1, "board_revision", revision)))
      if passed, do: dispatch_result(updated)
      {:reply, {:ok, %{"task" => updated, "revision" => revision}}, next}
    else
      {:error, code, message} -> {:reply, {:error, code, message}, state}
    end
  end

  def handle_call({:inbox, group_id, session_id, since_seq}, _from, state) do
    with {:ok, group} <- fetch_group(state, group_id),
         :ok <- ensure_member(group, session_id),
         true <- is_integer(since_seq) and since_seq >= 0 do
      messages =
        group["messages"]
        |> Enum.filter(fn message ->
          message["seq"] > since_seq and message["to_session_id"] in [nil, session_id]
        end)

      {:reply, {:ok, %{"last_seq" => group["next_seq"], "messages" => messages}}, state}
    else
      false -> {:reply, {:error, "bad_request", "since_seq 须为非负整数"}, state}
      {:error, code, message} -> {:reply, {:error, code, message}, state}
    end
  end

  def handle_call({:wait, group_id, session_id, since_revision, timeout_ms}, from, state) do
    with {:ok, group} <- fetch_group(state, group_id),
         :ok <- ensure_member(group, session_id),
         true <- is_integer(since_revision) and since_revision >= 0 do
      revision = group["revision"] || 0

      if revision > since_revision do
        {:reply, {:ok, %{"kind" => "edge", "revision" => revision}}, state}
      else
        ref = Process.monitor(elem(from, 0))
        timer = Process.send_after(self(), {:collab_wait_timeout, ref}, timeout_ms)

        waiter = %{
          ref: ref,
          timer: timer,
          from: from,
          group_id: group_id,
          session_id: session_id,
          since_revision: revision
        }

        {:noreply, %{state | waiters: [waiter | state.waiters]}}
      end
    else
      false -> {:reply, {:error, "bad_request", "since_revision 须为非负整数"}, state}
      {:error, code, message} -> {:reply, {:error, code, message}, state}
    end
  end

  defp replay(state) do
    state.path
    |> EventStore.replay()
    |> Enum.reduce(state, fn event, acc ->
      persisted = %{
        "event_id" => event.id,
        "topic" => to_string(event.topic),
        "group_id" => event.data["group_id"],
        "command_id" => event.data["command_id"],
        "payload" => event.data["payload"],
        "at" => event.at
      }

      apply_event(acc, persisted)
    end)
  end

  defp append(state, event) do
    data = Map.take(event, ["group_id", "command_id", "payload"])

    with {:ok, persisted} <- EventStore.append(state.store, String.to_atom(event["topic"]), data) do
      {:ok, Map.put(event, "event_id", persisted.id)}
    end
  end

  defp apply_event(
         state,
         %{"topic" => "collab_group_created", "payload" => %{"group" => group}} = event
       ) do
    state
    |> put_group(group)
    |> remember_command(event["command_id"])
  end

  defp apply_event(
         state,
         %{
           "topic" => "collab_member_added",
           "group_id" => group_id,
           "payload" => %{"member" => member}
         } = event
       ) do
    group = state.groups[group_id]
    group = %{group | "members" => group["members"] ++ [member], "updated_at" => event["at"]}

    state
    |> put_group(group)
    |> remember_command(event["command_id"])
  end

  defp apply_event(
         state,
         %{
           "topic" => "collab_delegated",
           "group_id" => group_id,
           "payload" => %{"member" => member, "task" => task}
         } = event
       ) do
    group = state.groups[group_id]

    group =
      group
      |> Map.put("members", group["members"] ++ [member])
      |> Map.put("tasks", (group["tasks"] || []) ++ [task])
      |> Map.put("total_spawned", (group["total_spawned"] || 1) + 1)
      |> Map.put("updated_at", event["at"])

    state
    |> put_group(group)
    |> remember_command(event["command_id"])
  end

  defp apply_event(
         state,
         %{
           "topic" => "collab_member_removed",
           "group_id" => group_id,
           "payload" => %{"member" => member}
         } = event
       ) do
    group = state.groups[group_id]
    members = Enum.reject(group["members"], &(&1["session_id"] == member["session_id"]))
    group = %{group | "members" => members, "updated_at" => event["at"]}

    state
    |> put_group(group)
    |> remember_command(event["command_id"])
  end

  defp apply_event(
         state,
         %{
           "topic" => "collab_message_created",
           "group_id" => group_id,
           "payload" => %{"message" => message}
         } = event
       ) do
    group = state.groups[group_id]

    group = %{
      group
      | "messages" => group["messages"] ++ [message],
        "next_seq" => max(group["next_seq"], message["seq"]),
        "updated_at" => event["at"]
    }

    state
    |> put_group(group)
    |> remember_command(event["command_id"])
  end

  defp apply_event(
         state,
         %{"topic" => topic, "group_id" => group_id, "payload" => %{"task" => task}} = event
       )
       when topic in ["collab_task_created", "collab_task_updated", "collab_workspace_updated"] do
    group = state.groups[group_id]

    tasks =
      (group["tasks"] || [])
      |> Enum.reject(&(&1["task_id"] == task["task_id"]))
      |> Kernel.++([task])

    group = %{group | "tasks" => tasks, "updated_at" => event["at"]}

    state
    |> put_group(group)
    |> remember_command(event["command_id"])
  end

  defp apply_event(
         state,
         %{
           "topic" => "collab_task_claimed",
           "group_id" => group_id,
           "payload" => %{"task" => task}
         } = event
       ) do
    group = state.groups[group_id]

    tasks =
      (group["tasks"] || [])
      |> Enum.reject(&(&1["task_id"] == task["task_id"]))
      |> Kernel.++([task])

    group = %{group | "tasks" => tasks, "updated_at" => event["at"]}

    state
    |> put_group(group)
    |> remember_command(event["command_id"])
  end

  defp apply_event(
         state,
         %{
           "topic" => "collab_group_status_changed",
           "group_id" => group_id,
           "payload" => %{"status" => status}
         } = event
       ) do
    group = Map.merge(state.groups[group_id], %{"status" => status, "updated_at" => event["at"]})

    state
    |> put_group(group)
    |> remember_command(event["command_id"])
  end

  defp apply_event(
         state,
         %{
           "topic" => "collab_task_lease_renewed",
           "group_id" => group_id,
           "payload" => %{"task" => task}
         } = event
       ) do
    group = state.groups[group_id]

    tasks =
      (group["tasks"] || [])
      |> Enum.reject(&(&1["task_id"] == task["task_id"]))
      |> Kernel.++([task])

    group = %{group | "tasks" => tasks, "updated_at" => event["at"]}

    state
    |> put_group(group)
    |> remember_command(event["command_id"])
  end

  defp apply_event(state, %{"topic" => "collab_group_deleted", "group_id" => group_id} = event) do
    state
    |> notify_deleted_waiters(group_id)
    |> Map.update!(:groups, &Map.delete(&1, group_id))
    |> remember_command(event["command_id"])
  end

  defp put_group(state, group) do
    group_id = group["group_id"]
    revision = group_revision(state, group_id) + 1
    group = Map.put(group, "revision", revision)
    next = %{state | groups: Map.put(state.groups, group_id, group)}
    notify_waiters(next, group_id)
  end

  defp notify_deleted_waiters(state, group_id) do
    {ready, waiting} = Enum.split_with(state.waiters, &(&1.group_id == group_id))

    Enum.each(ready, fn waiter ->
      Process.cancel_timer(waiter.timer)
      Process.demonitor(waiter.ref, [:flush])
      GenServer.reply(waiter.from, {:error, "group_deleted", "协作组已删除"})
    end)

    %{state | waiters: waiting}
  end

  defp notify_waiters(state, group_id) do
    revision = group_revision(state, group_id)

    {ready, waiting} =
      Enum.split_with(state.waiters, &(&1.group_id == group_id and revision > &1.since_revision))

    Enum.each(ready, fn waiter ->
      Process.cancel_timer(waiter.timer)
      Process.demonitor(waiter.ref, [:flush])
      GenServer.reply(waiter.from, {:ok, %{"kind" => "edge", "revision" => revision}})
    end)

    %{state | waiters: waiting}
  end

  defp group_revision(state, group_id), do: get_in(state.groups, [group_id, "revision"]) || 0

  defp remember_command(state, nil), do: state

  defp remember_command(state, command_id),
    do: %{state | commands: MapSet.put(state.commands, command_id)}

  defp unique_command(_state, nil), do: :ok

  defp unique_command(state, command_id) do
    if MapSet.member?(state.commands, command_id),
      do: {:error, "duplicate_command", "请求已处理"},
      else: :ok
  end

  defp ensure_member_capacity(group) do
    if length(group["members"] || []) < @max_members,
      do: :ok,
      else: {:error, "member_limit", "工作组成员已达到上限"}
  end

  defp ensure_task_capacity(group) do
    active =
      Enum.count(
        group["tasks"] || [],
        &(&1["status"] not in ["succeeded", "failed", "cancelled"])
      )

    if active < @max_tasks,
      do: :ok,
      else: {:error, "task_limit", "工作组活动任务已达到上限"}
  end

  defp fetch_group(state, group_id) do
    case state.groups[group_id] do
      nil -> {:error, "not_found", "会话群不存在"}
      group -> {:ok, group}
    end
  end

  defp unique_message(_group, nil), do: :ok

  defp unique_message(group, message_id) do
    if Enum.any?(group["messages"], &(&1["message_id"] == message_id)),
      do: {:error, "duplicate_message", "消息已处理"},
      else: :ok
  end

  defp group_accepts_tasks(%{"status" => "running"}), do: :ok
  defp group_accepts_tasks(_), do: {:error, "group_paused", "群组当前不接受新任务"}

  defp ensure_coordinator(group, session_id) do
    if group["coordinator_session_id"] == session_id,
      do: :ok,
      else: {:error, "forbidden_role", "只有协调会话可以修改群组状态"}
  end

  defp ensure_member(group, session_id) do
    if session_member?(group, session_id), do: :ok, else: {:error, "not_member", "发送会话不属于该群"}
  end

  defp ensure_not_member(group, session_id) do
    if session_member?(group, session_id), do: {:error, "already_member", "会话已在群中"}, else: :ok
  end

  defp removable_member(group, session_id) do
    member = Enum.find(group["members"], &(&1["session_id"] == session_id))
    terminal = ~w(succeeded failed cancelled)

    cond do
      is_nil(member) ->
        {:error, "not_member", "会话不属于该群"}

      Enum.any?(group["members"], &(&1["parent_session_id"] == session_id)) ->
        {:error, "member_has_children", "请先移出该会话创建的协作会话"}

      Enum.any?(group["tasks"] || [], fn task ->
        task["assigned_session_id"] == session_id and task["status"] not in terminal
      end) ->
        {:error, "member_has_active_tasks", "请先完成或取消该会话的进行中任务"}

      true ->
        {:ok, member}
    end
  end

  defp ensure_recipient(_group, nil), do: :ok

  defp ensure_recipient(group, session_id) do
    if session_member?(group, session_id), do: :ok, else: {:error, "bad_recipient", "接收会话不属于该群"}
  end

  defp session_member?(group, session_id) do
    Enum.any?(group["members"], &(&1["session_id"] == session_id))
  end

  defp normalize_group(attrs) when is_map(attrs) do
    title = clean(attrs["title"] || attrs[:title])
    goal = clean(attrs["goal"] || attrs[:goal])
    session_id = clean(attrs["session_id"] || attrs[:session_id])
    max_depth = attrs["max_depth"] || attrs[:max_depth] || @default_max_depth
    max_total = attrs["max_total"] || attrs[:max_total] || @max_members

    cond do
      is_nil(session_id) ->
        {:error, "bad_request", "sessionId 不能为空"}

      is_nil(title) and is_nil(goal) ->
        {:error, "bad_request", "title 或 goal 至少填写一项"}

      not is_integer(max_depth) or max_depth < 0 or max_depth > 8 ->
        {:error, "bad_request", "max_depth 须在 0..8"}

      not is_integer(max_total) or max_total < 1 or max_total > @max_spawn_total ->
        {:error, "bad_request", "max_total 须在 1..#{@max_spawn_total}"}

      true ->
        {:ok,
         %{
           "group_id" => clean(attrs["group_id"] || attrs[:group_id]),
           "title" => title || String.slice(goal, 0, 48),
           "goal" => goal || title,
           "session_id" => session_id,
           "project_root" => clean(attrs["project_root"] || attrs[:project_root]),
           "max_depth" => max_depth,
           "max_total" => max_total,
           "command_id" => clean(attrs["command_id"] || attrs[:command_id])
         }}
    end
  end

  defp normalize_member(attrs) when is_map(attrs) do
    session_id = clean(attrs["session_id"] || attrs[:session_id])
    role = clean(attrs["role"] || attrs[:role]) || "worker"

    cond do
      is_nil(session_id) ->
        {:error, "bad_request", "sessionId 不能为空"}

      role not in @roles ->
        {:error, "bad_request", "未知成员角色"}

      true ->
        {:ok,
         %{
           "session_id" => session_id,
           "role" => role,
           "parent_session_id" => clean(attrs["parent_session_id"] || attrs[:parent_session_id]),
           "command_id" => clean(attrs["command_id"] || attrs[:command_id])
         }}
    end
  end

  defp normalize_member(_), do: {:error, "bad_request", "成员参数格式错误"}

  defp normalize_delegation(attrs) when is_map(attrs) do
    title = clean(attrs["title"] || attrs[:title])
    description = clean(attrs["description"] || attrs[:description])
    parent = clean(attrs["parent_session_id"] || attrs[:parent_session_id])
    session_id = clean(attrs["session_id"] || attrs[:session_id])
    role = clean(attrs["role"] || attrs[:role]) || "worker"
    workspace = attrs["workspace"] || attrs[:workspace]
    protocol_version = attrs["protocol_version"] || attrs[:protocol_version] || 1

    if title && parent && session_id && role in @roles && is_map(workspace) &&
         protocol_version in [1, 2] do
      {:ok,
       %{
         "title" => title,
         "description" => description || title,
         "acceptance" => attrs["acceptance"] || attrs[:acceptance] || [],
         "depends_on" => attrs["depends_on"] || attrs[:depends_on] || [],
         "write_scope" => attrs["write_scope"] || attrs[:write_scope] || [],
         "parent_session_id" => parent,
         "session_id" => session_id,
         "role" => role,
         "persona" => attrs["persona"] || attrs[:persona],
         "protocol_version" => protocol_version,
         "workspace" => workspace,
         "command_id" => clean(attrs["command_id"] || attrs[:command_id])
       }}
    else
      {:error, "bad_request", "派生任务需要父会话、子会话、角色、工作区和标题"}
    end
  end

  defp normalize_member_removal(attrs) when is_map(attrs) do
    session_id = clean(attrs["session_id"] || attrs[:session_id])
    actor_session_id = clean(attrs["actor_session_id"] || attrs[:actor_session_id])

    if session_id && actor_session_id do
      {:ok,
       %{
         "session_id" => session_id,
         "actor_session_id" => actor_session_id,
         "command_id" => clean(attrs["command_id"] || attrs[:command_id])
       }}
    else
      {:error, "bad_request", "sessionId 和 actorSessionId 不能为空"}
    end
  end

  defp normalize_member_removal(_), do: {:error, "bad_request", "成员移除参数格式错误"}

  defp lease_owner(task, session_id) do
    cond do
      task["lease_owner"] != session_id -> {:error, "lease_lost", "当前会话不是 lease 持有者"}
      not lease_active?(task) -> {:error, "lease_lost", "任务 lease 已过期"}
      true -> :ok
    end
  end

  defp lease_active?(task) do
    case task["lease_until"] do
      until when is_binary(until) ->
        case DateTime.from_iso8601(until) do
          {:ok, dt, _} -> DateTime.compare(dt, DateTime.utc_now()) == :gt
          _ -> false
        end

      _ ->
        false
    end
  end

  # ── 孤儿任务回收 ──
  # 子会话崩溃/结束后，其任务会永久卡在 assigned/running，阻塞删组与成员移除。
  # 孤儿判据：指派会话进程已不存在 + 租约已过期（或从未租出）。
  # 协调者自建的 pending 任务（无指派）不算孤儿，留给协调者处置。

  defp task_active?(task), do: task["status"] not in ["succeeded", "failed", "cancelled"]

  defp orphan_task?(%{"assigned_session_id" => nil}, _now), do: false

  defp orphan_task?(task, _now) do
    task_active?(task) and not session_alive?(task["assigned_session_id"]) and
      not lease_active?(task)
  end

  defp session_alive?(session_id) do
    try do
      case Registry.lookup(Newbee.Web.SessionRegistry, session_id) do
        [] -> false
        [{pid, _}] -> Process.alive?(pid)
        _ -> false
      end
    rescue
      # registry 未启动（非 Web 环境）时视为无活跃会话进程
      _ -> false
    end
  end

  defp cancel_orphans(state, group) do
    now = now_iso()

    (group["tasks"] || [])
    |> Enum.filter(&orphan_task?(&1, now))
    |> Enum.reduce({state, group}, fn task, {acc_state, acc_group} ->
      updated =
        task
        |> Map.put("status", "cancelled")
        |> Map.put("result", "orphan: 子会话已结束且租约过期，自动取消")
        |> Map.put("updated_at", now)

      event = event("collab_task_updated", acc_group["group_id"], %{"task" => updated}, nil)
      {:ok, persisted} = append(acc_state, event)
      next = apply_event(acc_state, persisted)
      broadcast(persisted, next.groups[acc_group["group_id"]])
      {next, next.groups[acc_group["group_id"]]}
    end)
  end

  defp sweep_orphans(state) do
    Enum.reduce(state.groups, state, fn {_group_id, group}, acc ->
      {next, _group} = cancel_orphans(acc, group)
      next
    end)
  end

  defp schedule_orphan_sweep do
    Process.send_after(self(), :sweep_orphans, @orphan_sweep_interval_ms)
  end

  defp task_claimable(task, session_id) do
    lease_active? =
      case task["lease_until"] do
        until when is_binary(until) ->
          case DateTime.from_iso8601(until) do
            {:ok, dt, _} -> DateTime.compare(dt, DateTime.utc_now()) == :gt
            _ -> false
          end

        _ ->
          false
      end

    cond do
      task["assigned_session_id"] not in [nil, session_id] ->
        {:error, "forbidden_role", "任务未指派给当前会话"}

      lease_active? and task["lease_owner"] != session_id ->
        {:error, "lease_lost", "任务已被其它会话占用"}

      task["status"] in ["succeeded", "failed", "cancelled"] ->
        {:error, "invalid_state", "任务已结束"}

      true ->
        :ok
    end
  end

  defp normalize_task(attrs) when is_map(attrs) do
    title = clean(attrs["title"] || attrs[:title])
    description = clean(attrs["description"] || attrs[:description])
    creator = clean(attrs["created_by_session_id"] || attrs[:created_by_session_id])

    if creator && (title || description) do
      {:ok,
       %{
         "title" => title || String.slice(description, 0, 80),
         "description" => description || title,
         "acceptance" => attrs["acceptance"] || attrs[:acceptance] || [],
         "created_by_session_id" => creator,
         "assigned_session_id" => clean(attrs["assigned_session_id"] || attrs[:assigned_session_id]),
         "command_id" => clean(attrs["command_id"] || attrs[:command_id])
       }}
    else
      {:error, "bad_request", "任务需要创建会话和标题/描述"}
    end
  end

  defp normalize_task(_), do: {:error, "bad_request", "任务参数格式错误"}

  defp normalize_task_update(attrs) when is_map(attrs) do
    status = clean(attrs["status"] || attrs[:status])
    session_id = clean(attrs["session_id"] || attrs[:session_id])

    if status in ~w(accepted running blocked succeeded failed cancelled) and session_id do
      {:ok,
       %{
         "status" => status,
         "session_id" => session_id,
         "progress" => attrs["progress"] || attrs[:progress],
         "result" => attrs["result"] || attrs[:result],
         "command_id" => clean(attrs["command_id"] || attrs[:command_id])
       }}
    else
      {:error, "bad_request", "任务状态或 sessionId 无效"}
    end
  end

  defp normalize_task_update(_), do: {:error, "bad_request", "任务更新参数格式错误"}

  defp normalize_workspace_update(attrs) when is_map(attrs) do
    actor = clean(attrs["actor_session_id"] || attrs[:actor_session_id])
    action = clean(attrs["action"] || attrs[:action])

    if actor && action in ~w(applied rejected cleaned) do
      {:ok,
       %{
         "actor_session_id" => actor,
         "action" => action,
         "patch_sha256" => clean(attrs["patch_sha256"] || attrs[:patch_sha256]),
         "command_id" => clean(attrs["command_id"] || attrs[:command_id])
       }}
    else
      {:error, "bad_request", "工作区操作或 actorSessionId 无效"}
    end
  end

  defp normalize_workspace_update(_), do: {:error, "bad_request", "工作区操作参数格式错误"}

  defp transition_workspace(%{"workspace" => workspace} = task, attrs) when is_map(workspace) do
    current = workspace["review_status"]
    action = attrs["action"]

    valid? =
      case {current, action} do
        {"pending", next} when next in ["applied", "rejected"] -> true
        {previous, "cleaned"} when previous in ["applied", "rejected"] -> true
        _ -> false
      end

    if valid? do
      workspace = %{
        workspace
        | "review_status" => action,
          "reviewed_at" => now_iso(),
          "reviewed_by_session_id" => attrs["actor_session_id"]
      }

      workspace =
        if attrs["patch_sha256"],
          do: Map.put(workspace, "patch_sha256", attrs["patch_sha256"]),
          else: workspace

      {:ok, task |> Map.put("workspace", workspace) |> Map.put("updated_at", now_iso())}
    else
      {:error, "invalid_workspace_state", "工作区状态不允许该操作"}
    end
  end

  defp transition_workspace(_, _), do: {:error, "workspace_missing", "任务没有隔离工作区"}

  defp maybe_mark_workspace_pending(
         %{"workspace" => %{"review_status" => "waiting"} = workspace} = task,
         true
       ) do
    Map.put(task, "workspace", Map.put(workspace, "review_status", "pending"))
  end

  defp maybe_mark_workspace_pending(task, _), do: task

  defp fetch_task(group, task_id) do
    case Enum.find(group["tasks"] || [], &(&1["task_id"] == task_id)) do
      nil -> {:error, "not_found", "任务不存在"}
      task -> {:ok, task}
    end
  end

  defp legacy_task_api(%{"protocol_version" => 2}),
    do: {:error, "protocol_mismatch", "Hive v2 任务必须使用 Hive Board 生命周期 API"}

  defp legacy_task_api(_task), do: :ok

  defp task_actor_allowed(task, session_id) do
    if session_id in [task["created_by_session_id"], task["assigned_session_id"]],
      do: :ok,
      else: {:error, "forbidden_role", "当前会话不能更新该任务"}
  end

  defp valid_task_transition(from, to) do
    allowed = %{
      "pending" => ~w(cancelled assigned),
      "assigned" => ~w(accepted running cancelled),
      "accepted" => ~w(running blocked succeeded failed cancelled),
      "running" => ~w(blocked succeeded failed cancelled),
      "blocked" => ~w(running failed cancelled)
    }

    if to in Map.get(allowed, from, []), do: :ok, else: {:error, "invalid_state", "非法任务状态转换"}
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp normalize_message(attrs) when is_map(attrs) do
    sender = clean(attrs["sender_session_id"] || attrs[:sender_session_id])
    kind = clean(attrs["kind"] || attrs[:kind]) || "chat"
    delivery = clean(attrs["delivery"] || attrs[:delivery]) || "notify"
    body = clean(attrs["body"] || attrs[:body])

    cond do
      is_nil(sender) ->
        {:error, "bad_request", "senderSessionId 不能为空"}

      kind not in @message_kinds ->
        {:error, "bad_request", "未知消息类型"}

      delivery not in @deliveries ->
        {:error, "bad_request", "未知投递方式，只支持 notify / queue / wake"}

      is_nil(body) ->
        {:error, "bad_request", "消息内容不能为空"}

      byte_size(body) > 65_536 ->
        {:error, "message_too_large", "消息超过 64 KiB"}

      true ->
        {:ok,
         %{
           "sender_session_id" => sender,
           "to_session_id" => clean(attrs["to_session_id"] || attrs[:to_session_id]),
           "kind" => kind,
           "delivery" => delivery,
           "body" => body,
           "message_id" => clean(attrs["message_id"] || attrs[:message_id]),
           "command_id" => clean(attrs["command_id"] || attrs[:command_id])
         }}
    end
  end

  defp normalize_message(_), do: {:error, "bad_request", "消息参数格式错误"}

  defp summary(group) do
    %{
      "group_id" => group["group_id"],
      "title" => group["title"],
      "goal" => group["goal"],
      "status" => group["status"],
      "coordinator_session_id" => group["coordinator_session_id"],
      "members" =>
        Enum.map(group["members"], fn member ->
          Map.take(member, ["session_id", "role", "state", "parent_session_id"])
        end),
      "member_count" => length(group["members"]),
      "message_count" => length(group["messages"]),
      "task_count" => length(group["tasks"] || []),
      "last_seq" => group["next_seq"],
      "updated_at" => group["updated_at"]
    }
  end

  defp public_group(group) do
    group
    |> Map.drop(["next_seq"])
    |> Map.put("last_seq", group["next_seq"])
  end

  defp event(topic, group_id, payload, command_id) do
    %{
      "topic" => topic,
      "group_id" => group_id,
      "command_id" => command_id,
      "payload" => payload,
      "at" => now_iso()
    }
  end

  # 终态只通知一次：终态间不再转换；重放路径不走 dispatch，重启后不重复打扰。
  defp dispatch_result(task) do
    case Newbee.Web.Session.lookup(task["created_by_session_id"]) do
      {:ok, pid} -> Newbee.Web.Session.collaboration_result(pid, task)
      _ -> :ok
    end
  end

  # notify 只进时间线（不打扰模型）；queue/wake 投给目标会话运行时：
  # 忙时运行时自行排队，空闲立即处理。重启重放不走 dispatch（事件流即事实）。
  defp dispatch_message(%{"delivery" => d} = message, group) when d in ["queue", "wake"] do
    target = message["to_session_id"] || group["coordinator_session_id"]

    case Newbee.Web.Session.lookup(target) do
      {:ok, pid} -> Newbee.Web.Session.collaboration_message(pid, message)
      _ -> :ok
    end
  end

  defp dispatch_message(_message, _group), do: :ok

  defp dispatch_task(%{"assigned_session_id" => nil}), do: :ok

  defp dispatch_task(task) do
    case Newbee.Web.Session.lookup(task["assigned_session_id"]) do
      {:ok, pid} -> Newbee.Web.Session.collaboration_task(pid, task)
      _ -> :ok
    end
  end

  defp broadcast(event, group) do
    envelope =
      event
      |> Map.put("session_ids", Enum.map(group["members"], & &1["session_id"]))

    if Process.whereis(Newbee.Bus), do: Newbee.Bus.emit(:collab_event, envelope)
    :ok
  end

  defp command_id_required(command_id) when is_binary(command_id) and byte_size(command_id) <= 256,
    do: :ok

  defp command_id_required(_command_id),
    do: {:error, "command_id_required", "Board 写操作必须提供至多 256 字节的 command_id"}

  defp bounded_text(nil, _limit, _field), do: :ok

  defp bounded_text(value, limit, field) when is_binary(value) do
    if byte_size(value) <= limit,
      do: :ok,
      else: {:error, "payload_too_large", "#{field} 超过 #{limit} 字节"}
  end

  defp bounded_text(_value, _limit, field),
    do: {:error, "bad_request", "#{field} 必须是字符串"}

  defp bounded_json(nil, _limit, _field), do: :ok

  defp bounded_json(value, limit, field) do
    case Jason.encode(value) do
      {:ok, encoded} when byte_size(encoded) <= limit -> :ok
      {:ok, _encoded} -> {:error, "payload_too_large", "#{field} 超过 #{limit} 字节"}
      {:error, _reason} -> {:error, "bad_request", "#{field} 必须是 JSON 可编码值"}
    end
  end

  defp bounded_evidence(nil), do: :ok

  defp bounded_evidence(evidence) when is_list(evidence) and length(evidence) <= @max_evidence_items,
    do: bounded_json(evidence, @max_task_payload_bytes, "evidence")

  defp bounded_evidence(_evidence),
    do: {:error, "bad_request", "evidence 必须是不超过 #{@max_evidence_items} 项的数组"}

  defp clean(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  defp clean(_), do: nil

  defp id(prefix) do
    suffix = :crypto.strong_rand_bytes(10) |> Base.url_encode64(padding: false)
    prefix <> "_" <> suffix
  end

  defp now_iso, do: DateTime.utc_now() |> DateTime.to_iso8601()

  defp clamp_wait_timeout(value) when is_integer(value),
    do: value |> max(1_000) |> min(@max_wait_timeout_ms)

  defp clamp_wait_timeout(_), do: @default_wait_timeout_ms

  defp ensure_spawn_capacity(group, parent_session_id) do
    depth = member_depth(group, parent_session_id) + 1
    max_depth = group["max_depth"] || @default_max_depth
    max_total = group["max_total"] || @max_members
    total = group["total_spawned"] || length(group["members"] || [])

    cond do
      depth > max_depth ->
        {:error, "depth_limit", "派生深度 #{depth} 超过组上限 #{max_depth}"}

      total >= max_total ->
        {:error, "spawn_limit", "累计派生数 #{total} 已达组上限 #{max_total}"}

      true ->
        :ok
    end
  end

  defp member_depth(group, session_id) do
    case Enum.find(group["members"] || [], &(&1["session_id"] == session_id)) do
      %{"depth" => depth} when is_integer(depth) -> depth
      _ -> 0
    end
  end

  defp validate_delegation_contract(%{"protocol_version" => 2} = attrs) do
    with :ok <- command_id_required(attrs["command_id"]),
         :ok <- bounded_text(attrs["title"], @max_task_title_bytes, "title"),
         :ok <- bounded_text(attrs["description"], @max_task_description_bytes, "description"),
         :ok <- bounded_json(attrs["persona"], @max_task_payload_bytes, "persona"),
         :ok <- bounded_json(attrs["workspace"], @max_task_payload_bytes, "workspace"),
         {:ok, acceptance} <-
           Newbee.Collaboration.Verification.normalize_contract(attrs["acceptance"]),
         true <- valid_id_list?(attrs["depends_on"]),
         {:ok, scopes} <- normalize_write_scopes(attrs["write_scope"]) do
      {:ok,
       %{
         attrs
         | "acceptance" => acceptance,
           "depends_on" => normalize_ids(attrs["depends_on"]),
           "write_scope" => scopes
       }}
    else
      false -> {:error, "bad_dependency", "depends_on 须为非空任务 id 数组"}
      error -> error
    end
  end

  defp validate_delegation_contract(attrs), do: {:ok, attrs}

  defp normalize_board_task(attrs) when is_map(attrs) do
    session_id = clean(attrs["session_id"] || attrs[:session_id])
    title = clean(attrs["title"] || attrs[:title])
    description = clean(attrs["description"] || attrs[:description])
    revision = attrs["expected_revision"] || attrs[:expected_revision]
    dependencies = attrs["depends_on"] || attrs[:depends_on] || []
    command_id = clean(attrs["command_id"] || attrs[:command_id])

    with :ok <- command_id_required(command_id),
         :ok <- bounded_text(title, @max_task_title_bytes, "title"),
         :ok <- bounded_text(description, @max_task_description_bytes, "description"),
         true <- is_binary(session_id) and (is_binary(title) or is_binary(description)),
         true <- is_integer(revision) and revision >= 0,
         true <- valid_id_list?(dependencies),
         {:ok, scopes} <-
           normalize_write_scopes(attrs["write_scope"] || attrs[:write_scope] || []) do
      {:ok,
       %{
         "session_id" => session_id,
         "title" => title || String.slice(description, 0, 80),
         "description" => description || title,
         "acceptance" => attrs["acceptance"] || attrs[:acceptance],
         "depends_on" => normalize_ids(dependencies),
         "write_scope" => scopes,
         "assigned_session_id" => clean(attrs["assigned_session_id"] || attrs[:assigned_session_id]),
         "expected_revision" => revision,
         "command_id" => command_id
       }}
    else
      false -> {:error, "bad_request", "Board 任务需要合法 session、标题、revision 与 depends_on"}
      {:error, _, _} = error -> error
    end
  end

  defp normalize_board_task(_), do: {:error, "bad_request", "Board 任务参数格式错误"}

  defp normalize_board_update(attrs) when is_map(attrs) do
    session_id = clean(attrs["session_id"] || attrs[:session_id])
    revision = attrs["expected_revision"] || attrs[:expected_revision]
    status = clean(attrs["status"] || attrs[:status])
    title = clean(attrs["title"] || attrs[:title])
    description = clean(attrs["description"] || attrs[:description])
    progress = attrs["progress"] || attrs[:progress]
    result = attrs["result"] || attrs[:result]
    evidence = attrs["evidence"] || attrs[:evidence]
    command_id = clean(attrs["command_id"] || attrs[:command_id])

    with :ok <- command_id_required(command_id),
         :ok <- bounded_text(title, @max_task_title_bytes, "title"),
         :ok <- bounded_text(description, @max_task_description_bytes, "description"),
         :ok <- bounded_json(progress, @max_task_payload_bytes, "progress"),
         :ok <- bounded_json(result, @max_task_payload_bytes, "result"),
         :ok <- bounded_evidence(evidence),
         true <- is_binary(session_id) and is_integer(revision) and revision >= 0,
         true <-
           is_nil(status) or
             status in ~w(assigned accepted running blocked submitted succeeded failed cancelled),
         {:ok, dependencies} <- optional_ids(attrs, "depends_on", :depends_on),
         {:ok, scopes} <- optional_write_scopes(attrs) do
      {:ok,
       %{
         "session_id" => session_id,
         "expected_revision" => revision,
         "title" => title,
         "description" => description,
         "acceptance" => attrs["acceptance"] || attrs[:acceptance],
         "depends_on" => dependencies,
         "write_scope" => scopes,
         "status" => status,
         "progress" => progress,
         "result" => result,
         "evidence" => evidence,
         "command_id" => command_id
       }}
    else
      false -> {:error, "bad_request", "Board 更新需要 session_id、expected_revision 和合法状态"}
      {:error, _, _} = error -> error
    end
  end

  defp normalize_board_update(_), do: {:error, "bad_request", "Board 更新参数格式错误"}

  defp normalize_board_claim(attrs) when is_map(attrs) do
    session_id = clean(attrs["session_id"] || attrs[:session_id])
    revision = attrs["expected_revision"] || attrs[:expected_revision]

    if is_binary(session_id) and is_integer(revision) and revision >= 0 do
      {:ok,
       %{
         "session_id" => session_id,
         "expected_revision" => revision,
         "command_id" => clean(attrs["command_id"] || attrs[:command_id])
       }}
    else
      {:error, "bad_request", "认领需要 session_id 与 expected_revision"}
    end
  end

  defp normalize_board_claim(_), do: {:error, "bad_request", "认领参数格式错误"}

  defp normalize_board_verify(attrs) when is_map(attrs) do
    session_id = clean(attrs["session_id"] || attrs[:session_id])
    revision = attrs["expected_revision"] || attrs[:expected_revision]

    if is_binary(session_id) and is_integer(revision) and revision >= 0 do
      {:ok,
       %{
         "session_id" => session_id,
         "expected_revision" => revision,
         "command_id" => clean(attrs["command_id"] || attrs[:command_id])
       }}
    else
      {:error, "bad_request", "验证需要 session_id 与 expected_revision"}
    end
  end

  defp normalize_board_verify(_), do: {:error, "bad_request", "验证参数格式错误"}

  defp expected_revision(group, expected) do
    actual = group["revision"] || 0

    if expected == actual,
      do: :ok,
      else: {:error, "revision_conflict", "Board revision=#{actual}，期望=#{inspect(expected)}；请重读后重试"}
  end

  defp board_actor_allowed(group, task, session_id) do
    if session_id in [
         group["coordinator_session_id"],
         task["created_by_session_id"],
         task["assigned_session_id"]
       ],
       do: :ok,
       else: {:error, "forbidden_role", "当前会话不能修改该任务"}
  end

  defp board_fields_allowed(group, task, attrs) do
    contract_changed? =
      Enum.any?(["title", "description", "acceptance", "depends_on", "write_scope"], fn key ->
        not is_nil(attrs[key])
      end)

    contract_owner? =
      attrs["session_id"] in [group["coordinator_session_id"], task["created_by_session_id"]]

    cond do
      contract_changed? and not contract_owner? ->
        {:error, "contract_forbidden", "执行者不能修改任务契约、依赖或 write_scope"}

      contract_changed? and task["status"] in ["accepted", "running", "submitted"] ->
        {:error, "contract_locked", "任务已开始执行，须先转为 blocked 才能修改契约"}

      true ->
        :ok
    end
  end

  defp validate_board_status_change(_group, %{"status" => status}, _attrs)
       when status in ["succeeded", "failed", "cancelled"],
       do: {:error, "invalid_state", "终态任务不可再修改"}

  defp validate_board_status_change(_group, _task, %{"status" => nil}), do: :ok

  defp validate_board_status_change(_group, _task, %{"status" => "succeeded"}),
    do: {:error, "verification_required", "Hive v2 任务只能由 verify/3 进入 succeeded"}

  defp validate_board_status_change(_group, task, attrs) do
    allowed = %{
      "pending" => ~w(assigned running cancelled),
      "assigned" => ~w(accepted running blocked submitted failed cancelled),
      "accepted" => ~w(running blocked submitted failed cancelled),
      "running" => ~w(blocked submitted failed cancelled),
      "blocked" => ~w(running submitted failed cancelled),
      "submitted" => ~w(blocked cancelled)
    }

    cond do
      attrs["status"] not in Map.get(allowed, task["status"], []) ->
        {:error, "invalid_state", "非法 Hive 状态转换 #{task["status"]} -> #{attrs["status"]}"}

      attrs["status"] == "submitted" and is_nil(clean(attrs["result"])) ->
        {:error, "result_required", "submitted 必须带可审查的 result"}

      true ->
        :ok
    end
  end

  defp maybe_reset_verification(task, nil), do: task

  defp maybe_reset_verification(task, _changed),
    do: Map.put(task, "verification", %{"status" => "pending"})

  defp normalize_updated_acceptance(task, %{"acceptance" => nil}), do: {:ok, task["acceptance"]}

  defp normalize_updated_acceptance(_task, %{"acceptance" => acceptance}),
    do: Newbee.Collaboration.Verification.normalize_contract(acceptance)

  defp submitted_task(%{"status" => "submitted"}), do: :ok
  defp submitted_task(_), do: {:error, "invalid_state", "只有 submitted 任务可验证"}

  defp attestation_matches(task, attestation) when is_map(attestation) do
    results = attestation["results"]
    expected_count = length(task["acceptance"] || [])

    cond do
      attestation["contract_sha256"] != task["acceptance_sha256"] ->
        {:error, "stale_attestation", "验收契约已变化，请重新验证"}

      not is_boolean(attestation["all_passed"]) or not is_list(results) ->
        {:error, "bad_attestation", "attestation 结构无效"}

      length(results) != expected_count ->
        {:error, "bad_attestation", "验收结果数量与契约不一致"}

      not result_specs_match?(task["acceptance"], results) ->
        {:error, "bad_attestation", "验收结果与契约项目不一致"}

      attestation["all_passed"] != Enum.all?(results, &(&1["passed"] == true)) ->
        {:error, "bad_attestation", "all_passed 与逐项结果不一致"}

      true ->
        :ok
    end
  end

  defp attestation_matches(_task, _attestation),
    do: {:error, "bad_attestation", "attestation 结构无效"}

  defp result_specs_match?(criteria, results) do
    Enum.zip(criteria, results)
    |> Enum.all?(fn {criterion, result} ->
      Enum.all?(criterion, fn {key, value} -> result[key] == value end)
    end)
  end

  defp command_acceptance_change_allowed(_group, _actor_session_id, nil, _acceptance), do: :ok

  defp command_acceptance_change_allowed(group, actor_session_id, _changed, acceptance),
    do: command_acceptance_allowed(group, actor_session_id, acceptance)

  defp command_acceptance_allowed(group, actor_session_id, acceptance) do
    has_command? =
      is_list(acceptance) and
        Enum.any?(acceptance, fn
          %{"kind" => "command"} -> true
          _ -> false
        end)

    if has_command? and actor_session_id != group["coordinator_session_id"],
      do: {:error, "command_acceptance_forbidden", "只有 Lead 可创建或修改 command 验收项"},
      else: :ok
  end

  defp verification_root(group, task) do
    root = get_in(task, ["workspace", "path"]) || group["project_root"]

    if is_binary(root) and File.dir?(root),
      do: {:ok, root},
      else: {:error, "workspace_missing", "无可验证工作根"}
  end

  defp activate_ready_dependents(state, group_id) do
    group = state.groups[group_id]

    ready =
      Enum.filter(group["tasks"] || [], fn task ->
        task["status"] == "pending" and is_binary(task["assigned_session_id"]) and
          dependencies_completed?(group, task["depends_on"] || [])
      end)

    Enum.reduce(ready, {state, []}, fn task, {current_state, activated} ->
      updated = task |> Map.put("status", "assigned") |> Map.put("updated_at", now_iso())
      event = event("collab_task_updated", group_id, %{"task" => updated}, nil)
      {:ok, persisted} = append(current_state, event)
      next = apply_event(current_state, persisted)
      broadcast(persisted, next.groups[group_id])
      {next, activated ++ [updated]}
    end)
  end

  defp dependencies_exist(group, ids) do
    known = MapSet.new(group["tasks"] || [], & &1["task_id"])
    missing = Enum.reject(ids, &MapSet.member?(known, &1))

    if missing == [],
      do: :ok,
      else: {:error, "missing_dependency", "依赖任务不存在：#{Enum.join(missing, ", ")}"}
  end

  defp dependencies_completed(group, ids) do
    if dependencies_completed?(group, ids),
      do: :ok,
      else: {:error, "dependency_blocked", "依赖尚未全部验证成功"}
  end

  defp dependencies_completed?(group, ids) do
    tasks = Map.new(group["tasks"] || [], &{&1["task_id"], &1})
    Enum.all?(ids, &(get_in(tasks, [&1, "status"]) == "succeeded"))
  end

  defp dependency_graph_acyclic(group, task_id, dependencies) do
    graph = Map.new(group["tasks"] || [], &{&1["task_id"], &1["depends_on"] || []})
    graph = Map.put(graph, task_id, dependencies)

    if graph_cycle?(graph, task_id, MapSet.new()),
      do: {:error, "dependency_cycle", "任务依赖会形成环"},
      else: :ok
  end

  defp graph_cycle?(graph, node, path) do
    if MapSet.member?(path, node),
      do: true,
      else: Enum.any?(Map.get(graph, node, []), &graph_cycle?(graph, &1, MapSet.put(path, node)))
  end

  defp initial_board_status(nil, _ready), do: "pending"
  defp initial_board_status(_assigned, true), do: "assigned"
  defp initial_board_status(_assigned, false), do: "pending"

  defp valid_id_list?(ids) when is_list(ids) and length(ids) <= @max_dependency_count,
    do: Enum.all?(ids, &(is_binary(&1) and String.trim(&1) != ""))

  defp valid_id_list?(_), do: false

  defp normalize_ids(ids) when is_list(ids),
    do:
      ids
      |> Enum.filter(&is_binary/1)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

  defp normalize_ids(_), do: []

  defp optional_ids(attrs, string_key, atom_key) do
    value =
      cond do
        Map.has_key?(attrs, string_key) -> attrs[string_key]
        Map.has_key?(attrs, atom_key) -> attrs[atom_key]
        true -> nil
      end

    cond do
      is_nil(value) -> {:ok, nil}
      valid_id_list?(value) -> {:ok, normalize_ids(value)}
      true -> {:error, "bad_dependency", "depends_on 须为非空任务 id 数组"}
    end
  end

  defp optional_write_scopes(attrs) do
    cond do
      Map.has_key?(attrs, "write_scope") -> normalize_write_scopes(attrs["write_scope"])
      Map.has_key?(attrs, :write_scope) -> normalize_write_scopes(attrs[:write_scope])
      true -> {:ok, nil}
    end
  end

  defp normalize_write_scopes(scopes) when is_list(scopes) and length(scopes) <= @max_write_scope_count do
    if Enum.all?(scopes, &valid_write_scope?/1),
      do: {:ok, scopes |> Enum.map(&normalize_scope/1) |> Enum.uniq()},
      else: {:error, "bad_write_scope", "write_scope 须是工作根内的相对路径前缀"}
  end

  defp normalize_write_scopes(_), do: {:error, "bad_write_scope", "write_scope 须是数组"}

  defp valid_write_scope?(scope) when is_binary(scope) do
    scope = String.trim(scope)

    scope != "" and byte_size(scope) <= 1_024 and Path.type(scope) == :relative and
      not Enum.member?(Path.split(scope), "..")
  end

  defp valid_write_scope?(_), do: false

  defp normalize_scope(scope),
    do: scope |> String.trim() |> Path.expand("/") |> String.trim_leading("/")

  defp task_scope_warnings(tasks, task) do
    mine = task["write_scope"] || []

    tasks
    |> Enum.reject(&(&1["task_id"] == task["task_id"]))
    |> Enum.flat_map(fn other ->
      for left <- mine,
          right <- other["write_scope"] || [],
          scopes_overlap?(left, right) do
        %{"task_id" => other["task_id"], "scope" => right}
      end
    end)
  end

  defp write_scope_overlaps(tasks) do
    for left <- tasks,
        right <- tasks,
        left["task_id"] < right["task_id"],
        a <- left["write_scope"] || [],
        b <- right["write_scope"] || [],
        scopes_overlap?(a, b) do
      %{
        "left_task" => left["task_id"],
        "right_task" => right["task_id"],
        "left_scope" => a,
        "right_scope" => b
      }
    end
  end

  defp scopes_overlap?(left, right) do
    left == right or String.starts_with?(left, right <> "/") or
      String.starts_with?(right, left <> "/")
  end
end
