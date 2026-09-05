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
  @max_attempt_history 16
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

  def update_workspace(group_id, task_id, attrs, server \\ __MODULE__),
    do: GenServer.call(server, {:update_workspace, group_id, task_id, attrs})

  def tasks(group_id, server \\ __MODULE__),
    do: GenServer.call(server, {:tasks, group_id})

  def set_group_status(group_id, status, session_id, server \\ __MODULE__),
    do: GenServer.call(server, {:set_group_status, group_id, status, session_id})

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
  def board_update_task(group_id, task_id, attrs, server \\ __MODULE__) do
    attrs = normalize_submission_request(attrs)

    if submission_update?(attrs),
      do: board_update_task_with_submission(group_id, task_id, attrs, server),
      else: GenServer.call(server, {:board_update_task, group_id, task_id, attrs})
  end

  @doc false
  def board_claim(group_id, task_id, attrs, server \\ __MODULE__),
    do: GenServer.call(server, {:board_claim, group_id, task_id, attrs})

  @doc false
  def board_retry(group_id, task_id, attrs, server \\ __MODULE__),
    do: GenServer.call(server, {:board_retry, group_id, task_id, attrs})

  @doc false
  def delivery_claim(group_id, session_id, attrs, server \\ __MODULE__),
    do: GenServer.call(server, {:delivery_claim, group_id, session_id, attrs})

  @doc false
  def delivery_ack(group_id, session_id, attrs, server \\ __MODULE__),
    do: GenServer.call(server, {:delivery_ack, group_id, session_id, attrs})

  @doc false
  def pending_deliveries(session_id, server \\ __MODULE__),
    do: GenServer.call(server, {:pending_deliveries, session_id})

  @doc false
  def board_verify(group_id, task_id, attrs, server \\ __MODULE__) do
    with {:ok, prepared} <-
           GenServer.call(server, {:board_verify_prepare, group_id, task_id, attrs}),
         {:ok, attestation} <- verify_prepared_submission(prepared) do
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
    {:ok, replay(state)}
  end

  @impl true
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
        "deliveries" => [],
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
         :ok <- expected_revision(group, attrs["expected_revision"]),
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
      ready = dependencies_completed?(group, attrs["depends_on"])

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
        "protocol_version" => 2,
        "title" => attrs["title"],
        "description" => attrs["description"],
        "acceptance" => attrs["acceptance"],
        "acceptance_sha256" => Newbee.Collaboration.Verification.contract_sha256(attrs["acceptance"]),
        "depends_on" => attrs["depends_on"],
        "write_scope" => attrs["write_scope"],
        "created_by_session_id" => attrs["parent_session_id"],
        "assigned_session_id" => attrs["session_id"],
        "status" => initial_board_status(attrs["session_id"], ready),
        "progress" => nil,
        "result" => nil,
        "evidence" => [],
        "verification" => %{"status" => "pending"},
        "workspace" => attrs["workspace"],
        "lease_owner" => nil,
        "lease_until" => nil,
        "attempt" => 0,
        "attempt_history" => [],
        "created_at" => now,
        "updated_at" => now
      }

      event =
        event(
          "collab_delegated",
          group_id,
          %{"member" => member, "task" => task, "deliveries" => if(ready, do: task_deliveries(group, task), else: [])},
          attrs["command_id"]
        )

      {:ok, persisted} = append(state, event)
      next = apply_event(state, persisted)
      current_task = task |> Map.put("board_revision", next.groups[group_id]["revision"])
      broadcast(persisted, next.groups[group_id])
      if ready, do: dispatch_task(current_task, task_delivery_id(next.groups[group_id], current_task))
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
        "task_id" => attrs["task_id"],
        "attempt" => attrs["attempt"],
        "created_at" => now_iso()
      }

      event =
        event(
          "collab_message_created",
          group_id,
          %{"message" => message, "deliveries" => message_deliveries(group, message)},
          attrs["command_id"]
        )

      {:ok, persisted} = append(state, event)
      next = apply_event(state, persisted)
      broadcast(persisted, next.groups[group_id])
      dispatch_message(message, next.groups[group_id])
      {:reply, {:ok, message}, next}
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

  def handle_call({:delete_group, group_id, session_id}, _from, state) do
    with {:ok, group} <- fetch_group(state, group_id),
         :ok <- ensure_coordinator(group, session_id) do
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
            "payload" => public_payload(event.data["payload"]),
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
        "attempt_history" => [],
        "created_at" => now,
        "updated_at" => now
      }

      deliveries = if ready, do: task_deliveries(group, task), else: []
      event = event("collab_task_created", group_id, %{"task" => task, "deliveries" => deliveries}, attrs["command_id"])

      {:ok, persisted} = append(state, event)
      next = apply_event(state, persisted)
      revision = next.groups[group_id]["revision"]
      delivered = Map.put(task, "board_revision", revision)
      broadcast(persisted, next.groups[group_id])
      if ready, do: dispatch_task(delivered, task_delivery_id(next.groups[group_id], task))

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

  def handle_call({:board_update_task_prepare, group_id, task_id, raw_attrs}, _from, state) do
    case prepare_board_update(state, group_id, task_id, raw_attrs) do
      {:ok, prepared} ->
        {:reply,
         {:ok, %{task: prepared.task, attrs: prepared.attrs, group: prepared.group, acceptance: prepared.acceptance}},
         state}

      {:error, code, message} ->
        {:reply, {:error, code, message}, state}
    end
  end

  def handle_call(
        {:board_update_task_commit, group_id, task_id, raw_attrs, submission},
        _from,
        state
      ) do
    with {:ok, prepared} <- prepare_board_update(state, group_id, task_id, raw_attrs),
         {:ok, bound_submission} <- bind_submission(prepared.task, prepared.attrs, submission) do
      updated =
        prepared.task
        |> build_updated_task(prepared.attrs, prepared.acceptance)
        |> Map.put("submission", bound_submission)
        |> Map.put("submission_id", bound_submission["submission_id"])
        |> Map.put("submission_tree_sha256", bound_submission["tree_sha256"])
        |> Map.put("project_root", prepared.group["project_root"])

      submitted_transition? =
        prepared.task["status"] != "submitted" and prepared.attrs["status"] == "submitted" and
          prepared.attrs["session_id"] != prepared.group["coordinator_session_id"]

      deliveries = if submitted_transition?, do: task_result_deliveries(prepared.group, updated), else: []
      payload = %{"task" => updated, "deliveries" => deliveries}
      event = event("collab_task_updated", group_id, payload, prepared.attrs["command_id"])
      {:ok, persisted} = append(state, event)
      next = apply_event(state, persisted)
      revision = next.groups[group_id]["revision"]
      broadcast(persisted, next.groups[group_id])

      if submitted_transition?, do: dispatch_result(updated, first_delivery_id(deliveries))

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

  def handle_call({:board_update_task, group_id, task_id, raw_attrs}, _from, state) do
    with {:ok, group} <- fetch_group(state, group_id),
         {:ok, task} <- fetch_task(group, task_id),
         {:ok, attrs} <- normalize_board_update(raw_attrs),
         :ok <- ensure_member(group, attrs["session_id"]),
         :ok <- expected_revision(group, attrs["expected_revision"]),
         :ok <- expected_attempt(task, attrs["expected_attempt"]),
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
      submitted_transition? =
        task["status"] != "submitted" and attrs["status"] == "submitted" and
          attrs["session_id"] != group["coordinator_session_id"]

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
        |> ready_workspace_for_review()

      deliveries = if submitted_transition?, do: task_result_deliveries(group, updated), else: []

      event =
        event("collab_task_updated", group_id, %{"task" => updated, "deliveries" => deliveries}, attrs["command_id"])

      {:ok, persisted} = append(state, event)
      next = apply_event(state, persisted)
      revision = next.groups[group_id]["revision"]
      broadcast(persisted, next.groups[group_id])
      if submitted_transition?, do: dispatch_result(updated, first_delivery_id(deliveries))

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
        |> Map.put("updated_at", now_iso())

      deliveries = task_deliveries(group, claimed)

      event =
        event(
          "collab_task_claimed",
          group_id,
          %{"task" => claimed, "deliveries" => deliveries},
          attrs["command_id"]
        )

      {:ok, persisted} = append(state, event)
      next = apply_event(state, persisted)
      revision = next.groups[group_id]["revision"]
      broadcast(persisted, next.groups[group_id])
      dispatch_task(Map.put(claimed, "board_revision", revision), task_delivery_id(next.groups[group_id], claimed))
      {:reply, {:ok, %{"task" => claimed, "revision" => revision}}, next}
    else
      {:error, code, message} -> {:reply, {:error, code, message}, state}
    end
  end

  def handle_call({:board_retry, group_id, task_id, raw_attrs}, _from, state) do
    with {:ok, group} <- fetch_group(state, group_id),
         {:ok, task} <- fetch_task(group, task_id),
         {:ok, attrs} <- normalize_board_retry(raw_attrs),
         :ok <- ensure_coordinator(group, attrs["session_id"]),
         :ok <- expected_revision(group, attrs["expected_revision"]),
         :ok <- unique_command(state, attrs["command_id"]),
         :ok <- retryable_task(task) do
      attempt = (task["attempt"] || 0) + 1
      ready = dependencies_completed?(group, task["depends_on"] || [])

      retried =
        task
        |> Map.put("attempt", attempt)
        |> Map.put("attempt_history", append_attempt_history(task, attrs["reason"]))
        |> Map.put("status", if(ready, do: "assigned", else: "pending"))
        |> Map.put("progress", nil)
        |> Map.put("result", nil)
        |> Map.put("evidence", [])
        |> Map.put("verification", %{"status" => "pending"})
        |> Map.drop(["submission", "submission_id", "submission_tree_sha256"])
        |> Map.put("lease_owner", nil)
        |> Map.put("lease_until", nil)
        |> Map.put("updated_at", now_iso())

      deliveries = if ready, do: task_deliveries(group, retried), else: []

      event =
        event(
          "collab_task_retried",
          group_id,
          %{"task" => retried, "reason" => attrs["reason"], "deliveries" => deliveries},
          attrs["command_id"]
        )

      {:ok, persisted} = append(state, event)
      next = apply_event(state, persisted)
      revision = next.groups[group_id]["revision"]
      updated = Map.put(retried, "board_revision", revision)
      broadcast(persisted, next.groups[group_id])
      if ready, do: dispatch_task(updated, task_delivery_id(next.groups[group_id], updated))

      {:reply, {:ok, %{"task" => updated, "revision" => revision}}, next}
    else
      {:error, code, message} -> {:reply, {:error, code, message}, state}
    end
  end

  def handle_call({:delivery_claim, group_id, session_id, raw_attrs}, _from, state) do
    with {:ok, group} <- fetch_group(state, group_id),
         :ok <- ensure_member(group, session_id),
         {:ok, attrs} <- normalize_delivery(raw_attrs),
         {:ok, delivery} <- find_delivery(group, session_id, attrs) do
      cond do
        delivery["state"] == "obsolete" ->
          {:reply, {:ok, %{"decision" => "obsolete"}}, state}

        delivery["state"] == "consumed" ->
          {:reply, {:ok, %{"decision" => "duplicate"}}, state}

        delivery_obsolete?(group, delivery) ->
          obsolete = delivery |> Map.put("state", "obsolete") |> Map.put("obsolete_at", now_iso())
          event = event("collab_delivery_obsoleted", group_id, %{"delivery" => obsolete}, nil)
          {:ok, persisted} = append(state, event)
          next = apply_event(state, persisted)
          broadcast(persisted, next.groups[group_id])
          {:reply, {:ok, %{"decision" => "obsolete"}}, next}

        delivery["state"] == "started" and delivery["runtime_id"] == attrs["runtime_id"] ->
          {:reply, {:ok, %{"decision" => "duplicate"}}, state}

        true ->
          claimed =
            delivery
            |> Map.put("state", "started")
            |> Map.put("runtime_id", attrs["runtime_id"])
            |> Map.put("started_at", delivery["started_at"] || now_iso())
            |> Map.put("last_claimed_at", now_iso())

          event = event("collab_delivery_claimed", group_id, %{"delivery" => claimed}, nil)
          {:ok, persisted} = append(state, event)
          next = apply_event(state, persisted)
          broadcast(persisted, next.groups[group_id])
          {:reply, {:ok, %{"decision" => "deliver"}}, next}
      end
    else
      {:error, code, message} -> {:reply, {:error, code, message}, state}
    end
  end

  def handle_call({:delivery_ack, group_id, session_id, raw_attrs}, _from, state) do
    with {:ok, group} <- fetch_group(state, group_id),
         :ok <- ensure_member(group, session_id),
         {:ok, attrs} <- normalize_delivery(raw_attrs),
         {:ok, delivery} <- find_delivery(group, session_id, attrs) do
      cond do
        delivery["state"] == "consumed" ->
          {:reply, {:ok, %{"decision" => "duplicate", "delivery_id" => delivery["delivery_id"]}}, state}

        delivery["state"] == "obsolete" ->
          {:reply, {:error, "obsolete_delivery", "delivery is obsolete"}, state}

        delivery_obsolete?(group, delivery) ->
          {:reply, {:error, "obsolete_delivery", "delivery is obsolete"}, state}

        delivery["state"] != "started" ->
          {:reply, {:error, "invalid_state", "delivery must be claimed before acknowledgement"}, state}

        delivery["runtime_id"] != attrs["runtime_id"] ->
          {:reply, {:error, "delivery_owner", "delivery is owned by another runtime"}, state}

        true ->
          consumed =
            delivery
            |> Map.put("state", "consumed")
            |> Map.put("consumed_at", now_iso())

          event = event("collab_delivery_acked", group_id, %{"delivery" => consumed}, nil)
          {:ok, persisted} = append(state, event)
          next = apply_event(state, persisted)
          broadcast(persisted, next.groups[group_id])

          {:reply,
           {:ok,
            %{
              "decision" => "consumed",
              "delivery_id" => delivery["delivery_id"],
              "status" => "consumed"
            }}, next}
      end
    else
      {:error, code, message} -> {:reply, {:error, code, message}, state}
    end
  end

  def handle_call({:pending_deliveries, session_id}, _from, state) do
    deliveries =
      state.groups
      |> Map.values()
      |> Enum.filter(&session_member?(&1, session_id))
      |> Enum.flat_map(fn group ->
        group
        |> Map.get("deliveries", [])
        |> Enum.reject(fn delivery ->
          delivery["state"] in ["consumed", "obsolete"] or delivery_obsolete?(group, delivery)
        end)
      end)
      |> Enum.take(128)

    pending =
      Enum.map(deliveries, fn delivery ->
        %{
          "kind" => delivery["kind"],
          "payload" => delivery["payload"],
          "delivery_id" => delivery["delivery_id"]
        }
      end)

    {:reply, {:ok, pending}, state}
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
        |> ready_workspace_for_review()

      event = event("collab_task_updated", group_id, %{"task" => updated}, attrs["command_id"])
      {:ok, persisted} = append(state, event)
      next = apply_event(state, persisted)
      broadcast(persisted, next.groups[group_id])
      {next, activated} = activate_ready_dependents(next, group_id)
      revision = next.groups[group_id]["revision"]

      Enum.each(activated, fn task ->
        task = Map.put(task, "board_revision", revision)
        dispatch_task(task, task_delivery_id(next.groups[group_id], task))
      end)

      if passed and updated["created_by_session_id"] != group["coordinator_session_id"],
        do: dispatch_result(updated, result_delivery_id(next.groups[group_id], updated))

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
           "payload" => %{"member" => member, "task" => task} = payload
         } = event
       ) do
    group = state.groups[group_id]

    group =
      group
      |> Map.put("members", group["members"] ++ [member])
      |> Map.put("tasks", (group["tasks"] || []) ++ [task])
      |> Map.put("total_spawned", (group["total_spawned"] || 1) + 1)
      |> Map.put("deliveries", append_deliveries(group["deliveries"] || [], payload["deliveries"]))
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
           "payload" => %{"message" => message} = payload
         } = event
       ) do
    group = state.groups[group_id]

    group =
      group
      |> Map.put("messages", group["messages"] ++ [message])
      |> Map.put("next_seq", max(group["next_seq"], message["seq"]))
      |> Map.put("deliveries", append_deliveries(group["deliveries"] || [], payload["deliveries"]))
      |> Map.put("updated_at", event["at"])

    state
    |> put_group(group)
    |> remember_command(event["command_id"])
  end

  defp apply_event(
         state,
         %{
           "topic" => topic,
           "group_id" => group_id,
           "payload" => %{"task" => task} = payload
         } = event
       )
       when topic in ["collab_task_created", "collab_task_updated", "collab_task_retried", "collab_workspace_updated"] do
    group = state.groups[group_id]

    tasks =
      (group["tasks"] || [])
      |> Enum.reject(&(&1["task_id"] == task["task_id"]))
      |> Kernel.++([task])

    group =
      group
      |> Map.put("tasks", tasks)
      |> Map.put("deliveries", append_deliveries(group["deliveries"] || [], payload["deliveries"]))
      |> Map.put("updated_at", event["at"])

    state
    |> put_group(group)
    |> remember_command(event["command_id"])
  end

  defp apply_event(
         state,
         %{
           "topic" => "collab_task_claimed",
           "group_id" => group_id,
           "payload" => %{"task" => task} = payload
         } = event
       ) do
    group = state.groups[group_id]

    tasks =
      (group["tasks"] || [])
      |> Enum.reject(&(&1["task_id"] == task["task_id"]))
      |> Kernel.++([task])

    group =
      group
      |> Map.put("tasks", tasks)
      |> Map.put("deliveries", append_deliveries(group["deliveries"] || [], payload["deliveries"]))
      |> Map.put("updated_at", event["at"])

    state
    |> put_group(group)
    |> remember_command(event["command_id"])
  end

  defp apply_event(
         state,
         %{
           "topic" => topic,
           "group_id" => group_id,
           "payload" => %{"delivery" => delivery}
         } = event
       )
       when topic in ["collab_delivery_claimed", "collab_delivery_acked", "collab_delivery_obsoleted"] do
    group = state.groups[group_id]
    deliveries = upsert_delivery(group["deliveries"] || [], delivery)
    group = group |> Map.put("deliveries", deliveries) |> Map.put("updated_at", event["at"])

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
    group = group |> Map.put_new("deliveries", []) |> Map.put("revision", revision)
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
    protocol_version = attrs["protocol_version"] || attrs[:protocol_version] || 2
    expected_revision = attrs["expected_revision"] || attrs[:expected_revision]

    cond do
      protocol_version != 2 ->
        {:error, "protocol_mismatch", "仅支持 Hive protocol=2"}

      not ((title && parent && session_id && role in @roles) and is_map(workspace)) ->
        {:error, "bad_request", "派生任务需要父会话、子会话、角色、工作区和标题"}

      true ->
        {:ok,
         %{
           "title" => title,
           "description" => description || title,
           "acceptance" => attrs["acceptance"] || attrs[:acceptance],
           "depends_on" => attrs["depends_on"] || attrs[:depends_on] || [],
           "write_scope" => attrs["write_scope"] || attrs[:write_scope] || [],
           "parent_session_id" => parent,
           "session_id" => session_id,
           "role" => role,
           "persona" => attrs["persona"] || attrs[:persona],
           "protocol_version" => protocol_version,
           "expected_revision" => expected_revision,
           "workspace" => workspace,
           "command_id" => clean(attrs["command_id"] || attrs[:command_id])
         }}
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

  defp ready_workspace_for_review(
         %{
           "status" => status,
           "workspace" => %{"review_status" => "waiting"} = workspace
         } = task
       )
       when status in ["succeeded", "failed", "cancelled"] do
    Map.put(task, "workspace", Map.put(workspace, "review_status", "pending"))
  end

  defp ready_workspace_for_review(task), do: task

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

  defp fetch_task(group, task_id) do
    case Enum.find(group["tasks"] || [], &(&1["task_id"] == task_id)) do
      nil -> {:error, "not_found", "任务不存在"}
      task -> {:ok, task}
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp normalize_message(attrs) when is_map(attrs) do
    sender = clean(attrs["sender_session_id"] || attrs[:sender_session_id])
    kind = clean(attrs["kind"] || attrs[:kind]) || "chat"
    delivery = clean(attrs["delivery"] || attrs[:delivery]) || "notify"
    delivery = if kind == "task_progress", do: "notify", else: delivery

    body = clean(attrs["body"] || attrs[:body])
    task_id = clean(attrs["task_id"] || attrs[:task_id])
    attempt = attrs["attempt"] || attrs[:attempt]

    cond do
      is_nil(sender) ->
        {:error, "bad_request", "senderSessionId cannot be empty"}

      kind not in @message_kinds ->
        {:error, "bad_request", "unknown message kind"}

      delivery not in @deliveries ->
        {:error, "bad_request", "unknown delivery; use notify, queue, or wake"}

      is_nil(body) ->
        {:error, "bad_request", "message body cannot be empty"}

      byte_size(body) > 65_536 ->
        {:error, "message_too_large", "message exceeds 64 KiB"}

      not is_nil(attempt) and (not is_integer(attempt) or attempt < 0) ->
        {:error, "bad_request", "message attempt must be a non-negative integer"}

      kind in ["task_progress", "task_result"] and
          ((is_nil(task_id) and not is_nil(attempt)) or (not is_nil(task_id) and is_nil(attempt))) ->
        {:error, "bad_request", "task progress/result requires task_id and attempt together"}

      true ->
        {:ok,
         %{
           "sender_session_id" => sender,
           "to_session_id" => clean(attrs["to_session_id"] || attrs[:to_session_id]),
           "kind" => kind,
           "delivery" => delivery,
           "body" => body,
           "message_id" => clean(attrs["message_id"] || attrs[:message_id]),
           "task_id" => task_id,
           "attempt" => attempt,
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
    |> Map.put("deliveries", Enum.map(group["deliveries"] || [], &public_delivery/1))
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
  defp dispatch_result(task, delivery_id) do
    task = if is_binary(delivery_id), do: Map.put(task, "delivery_id", delivery_id), else: task

    case Newbee.Web.Session.lookup(task["created_by_session_id"]) do
      {:ok, pid} -> Newbee.Web.Session.collaboration_result(pid, task)
      _ -> :ok
    end
  end

  # notify 只进时间线（不打扰模型）；queue 投给已运行的会话；wake 对持久会话异步恢复运行时。
  # ensure 不在 Coordinator 进程内同步调用，避免 Session/Coordinator 回调形成自调用死锁。
  defp dispatch_message(%{"kind" => "task_progress"}, _group), do: :ok

  defp dispatch_message(%{"delivery" => d} = message, group) when d in ["queue", "wake"] do
    target = message["to_session_id"] || group["coordinator_session_id"]
    delivery_id = message_delivery_id(group, message, target)
    message = if is_binary(delivery_id), do: Map.put(message, "delivery_id", delivery_id), else: message

    case Newbee.Web.Session.lookup(target) do
      {:ok, pid} -> Newbee.Web.Session.collaboration_message(pid, message)
      _ when d == "wake" -> wake_persisted_session(target, message)
      _ -> :ok
    end
  end

  defp dispatch_message(_message, _group), do: :ok

  defp wake_persisted_session(target, message) do
    case persisted_session_cwd(target) do
      cwd when is_binary(cwd) ->
        Task.start(fn ->
          case Newbee.Web.Session.ensure(target, cwd) do
            {:ok, pid, _sid} -> Newbee.Web.Session.collaboration_message(pid, message)
            _ -> :ok
          end
        end)

      _ ->
        :ok
    end
  end

  defp persisted_session_cwd(target) do
    if target in Newbee.Session.list(), do: Newbee.Session.cwd(target), else: nil
  rescue
    _ -> nil
  end

  defp dispatch_task(%{"assigned_session_id" => nil}, _delivery_id), do: :ok

  defp dispatch_task(task, delivery_id) do
    task = if is_binary(delivery_id), do: Map.put(task, "delivery_id", delivery_id), else: task

    case Newbee.Web.Session.lookup(task["assigned_session_id"]) do
      {:ok, pid} -> Newbee.Web.Session.collaboration_task(pid, task)
      _ -> :ok
    end
  end

  defp broadcast(event, group) do
    envelope =
      event
      |> public_event()
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

  defp validate_delegation_contract(attrs) do
    with :ok <- command_id_required(attrs["command_id"]),
         :ok <- delegation_revision(attrs["expected_revision"]),
         :ok <- bounded_text(attrs["title"], @max_task_title_bytes, "title"),
         :ok <- bounded_text(attrs["description"], @max_task_description_bytes, "description"),
         :ok <- bounded_json(attrs["persona"], @max_task_payload_bytes, "persona"),
         :ok <- bounded_json(attrs["workspace"], @max_task_payload_bytes, "workspace"),
         {:ok, acceptance} <- Newbee.Collaboration.Verification.normalize_contract(attrs["acceptance"]),
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
    expected_attempt = attrs["expected_attempt"] || attrs[:expected_attempt]
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
         true <- is_nil(expected_attempt) or (is_integer(expected_attempt) and expected_attempt >= 0),
         true <-
           is_nil(status) or
             status in ~w(assigned accepted running blocked submitted succeeded failed cancelled),
         {:ok, dependencies} <- optional_ids(attrs, "depends_on", :depends_on),
         {:ok, scopes} <- optional_write_scopes(attrs) do
      {:ok,
       %{
         "session_id" => session_id,
         "expected_revision" => revision,
         "expected_attempt" => expected_attempt,
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
      false -> {:error, "bad_request", "Board update requires session_id, expected_revision, and valid status/attempt"}
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

  defp delegation_revision(revision) when is_integer(revision) and revision >= 0, do: :ok
  defp delegation_revision(_), do: {:error, "bad_request", "delegation requires expected_revision"}

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

  defp validate_board_status_change(_group, %{"status" => status}, %{"status" => status}),
    do: :ok

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

      not submission_attestation_matches?(task, attestation) ->
        {:error, "stale_submission", "submission changed or attestation binding is stale"}

      true ->
        :ok
    end
  end

  defp attestation_matches(_task, _attestation),
    do: {:error, "bad_attestation", "attestation 结构无效"}

  defp submission_attestation_matches?(task, attestation) do
    if submission_present?(task) do
      submission = task["submission"] || %{}
      id = task["submission_id"] || submission_field(submission, "submission_id")
      tree = task["submission_tree_sha256"] || submission_field(submission, "tree_sha256")
      attestation["submission_id"] == id and attestation["tree_sha256"] == tree
    else
      true
    end
  end

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
      deliveries = task_deliveries(current_state.groups[group_id], updated)
      event = event("collab_task_updated", group_id, %{"task" => updated, "deliveries" => deliveries}, nil)

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
    value =
      cond do
        Map.has_key?(attrs, "write_scope") -> attrs["write_scope"]
        Map.has_key?(attrs, :write_scope) -> attrs[:write_scope]
        true -> nil
      end

    if is_nil(value), do: {:ok, nil}, else: normalize_write_scopes(value)
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

  defp expected_attempt(%{"attempt" => current}, nil) when is_integer(current) and current > 0,
    do: {:error, "attempt_required", "retry reports must include expected_attempt"}

  defp expected_attempt(%{"attempt" => current}, expected) when is_integer(expected) do
    if current == expected,
      do: :ok,
      else: {:error, "attempt_conflict", "task attempt=#{current}, expected=#{expected}"}
  end

  defp expected_attempt(_task, nil), do: :ok
  defp expected_attempt(_task, _expected), do: {:error, "attempt_conflict", "expected_attempt is invalid"}

  defp retryable_task(%{"status" => status}) when status in ["blocked", "failed", "cancelled"], do: :ok

  defp retryable_task(_task),
    do: {:error, "invalid_state", "only blocked, failed, or cancelled tasks may be retried"}

  defp append_attempt_history(task, reason) do
    entry =
      task
      |> Map.take([
        "attempt",
        "status",
        "progress",
        "result",
        "evidence",
        "verification",
        "submission",
        "lease_owner",
        "lease_until",
        "updated_at"
      ])
      |> Map.put("reason", reason)

    (task["attempt_history"] || [])
    |> Kernel.++([entry])
    |> Enum.take(-@max_attempt_history)
  end

  defp normalize_board_retry(attrs) when is_map(attrs) do
    session_id = clean(attrs["session_id"] || attrs[:session_id])
    revision = attrs["expected_revision"] || attrs[:expected_revision]
    command_id = clean(attrs["command_id"] || attrs[:command_id])
    reason = clean(attrs["reason"] || attrs[:reason])

    with :ok <- command_id_required(command_id),
         true <- is_binary(session_id) and is_integer(revision) and revision >= 0 and is_binary(reason),
         :ok <- bounded_text(reason, @max_task_description_bytes, "reason") do
      {:ok,
       %{
         "session_id" => session_id,
         "expected_revision" => revision,
         "command_id" => command_id,
         "reason" => reason
       }}
    else
      false -> {:error, "bad_request", "retry requires session_id, expected_revision, and reason"}
      {:error, _, _} = error -> error
    end
  end

  defp normalize_board_retry(_),
    do: {:error, "bad_request", "retry parameters must be a map"}

  defp normalize_delivery(attrs) when is_map(attrs) do
    delivery_id = clean(attrs["delivery_id"] || attrs[:delivery_id])
    runtime_id = clean(attrs["runtime_id"] || attrs[:runtime_id])
    kind = clean(attrs["kind"] || attrs[:kind])
    message_id = clean(attrs["message_id"] || attrs[:message_id])
    task_id = clean(attrs["task_id"] || attrs[:task_id])
    attempt = attrs["attempt"] || attrs[:attempt]

    cond do
      is_nil(delivery_id) or is_nil(runtime_id) or kind not in ["message", "task"] ->
        {:error, "bad_request", "delivery_id, runtime_id, and kind are required"}

      kind == "message" and is_nil(message_id) ->
        {:error, "bad_request", "message delivery requires message_id"}

      kind == "task" and (is_nil(task_id) or not is_integer(attempt) or attempt < 0) ->
        {:error, "bad_request", "task delivery requires task_id and non-negative attempt"}

      not is_nil(attempt) and (not is_integer(attempt) or attempt < 0) ->
        {:error, "bad_request", "attempt must be a non-negative integer"}

      true ->
        {:ok,
         %{
           "delivery_id" => delivery_id,
           "runtime_id" => runtime_id,
           "kind" => kind,
           "message_id" => message_id,
           "task_id" => task_id,
           "attempt" => attempt
         }}
    end
  end

  defp normalize_delivery(_),
    do: {:error, "bad_request", "delivery parameters must be a map"}

  defp find_delivery(group, session_id, attrs) do
    case Enum.find(group["deliveries"] || [], fn delivery ->
           delivery["delivery_id"] == attrs["delivery_id"] and
             delivery["session_id"] == session_id and
             delivery["kind"] == attrs["kind"] and
             optional_equal?(delivery["message_id"], attrs["message_id"]) and
             optional_equal?(delivery["task_id"], attrs["task_id"]) and
             optional_equal?(delivery["attempt"], attrs["attempt"])
         end) do
      nil -> {:error, "not_found", "delivery does not exist for this session"}
      delivery -> {:ok, delivery}
    end
  end

  defp optional_equal?(left, right), do: optional_value(left) == optional_value(right)

  defp optional_value(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  defp optional_value(value), do: value

  defp delivery_obsolete?(group, %{"kind" => "message", "payload" => payload}) do
    case payload do
      %{"kind" => kind, "task_id" => task_id, "attempt" => attempt}
      when kind in ["task_progress", "task_result"] and is_binary(task_id) and is_integer(attempt) ->
        case fetch_task(group, task_id) do
          {:ok, task} ->
            task["attempt"] != attempt or
              case kind do
                "task_progress" -> task["status"] not in ["assigned", "accepted", "running"]
                "task_result" -> task["status"] != "submitted"
              end

          _ ->
            true
        end

      _ ->
        false
    end
  end

  defp delivery_obsolete?(group, %{"kind" => "task", "task_id" => task_id, "attempt" => attempt} = delivery) do
    case fetch_task(group, task_id) do
      {:ok, task} ->
        valid_statuses =
          if delivery["purpose"] == "result",
            do: ["submitted", "succeeded"],
            else: ["assigned", "accepted", "running"]

        task["attempt"] != attempt or task["status"] not in valid_statuses

      _ ->
        true
    end
  end

  defp delivery_obsolete?(_group, _delivery), do: false

  defp task_result_deliveries(group, task) do
    target = task["created_by_session_id"] || group["coordinator_session_id"]
    attempt = task["attempt"] || 0

    if is_binary(target) and
         not Enum.any?(group["deliveries"] || [], fn delivery ->
           delivery["purpose"] == "result" and delivery["kind"] == "task" and
             delivery["session_id"] == target and delivery["task_id"] == task["task_id"] and
             delivery["attempt"] == attempt
         end) do
      delivery = new_delivery("task", target, task["task_id"], nil, attempt, task)
      payload = Map.put(task, "delivery_id", delivery["delivery_id"])
      [delivery |> Map.put("purpose", "result") |> Map.put("payload", payload)]
    else
      []
    end
  end

  defp first_delivery_id([%{"delivery_id" => delivery_id} | _]), do: delivery_id
  defp first_delivery_id(_), do: nil

  defp result_delivery_id(group, task) do
    case Enum.find(group["deliveries"] || [], fn delivery ->
           delivery["purpose"] == "result" and delivery["kind"] == "task" and
             delivery["session_id"] == task["created_by_session_id"] and
             delivery["task_id"] == task["task_id"] and delivery["attempt"] == (task["attempt"] || 0)
         end) do
      %{"delivery_id" => delivery_id} -> delivery_id
      _ -> nil
    end
  end

  defp task_delivery_id(group, task) do
    target = task["assigned_session_id"]
    attempt = task["attempt"] || 0

    Enum.find_value(group["deliveries"] || [], fn delivery ->
      if delivery["purpose"] != "result" and delivery["kind"] == "task" and
           delivery["session_id"] == target and delivery["task_id"] == task["task_id"] and
           delivery["attempt"] == attempt,
         do: delivery["delivery_id"]
    end)
  end

  defp task_deliveries(group, task) do
    target = task["assigned_session_id"]
    attempt = task["attempt"] || 0

    if is_binary(target) and is_nil(task_delivery_id(group, task)) do
      delivery = new_delivery("task", target, task["task_id"], nil, attempt, task)
      payload = Map.put(task, "delivery_id", delivery["delivery_id"])
      [Map.put(delivery, "payload", payload)]
    else
      []
    end
  end

  defp message_deliveries(group, message) do
    targets =
      case message["to_session_id"] do
        nil -> Enum.map(group["members"] || [], & &1["session_id"])
        target -> [target]
      end

    targets
    |> Enum.filter(&is_binary/1)
    |> Enum.uniq()
    |> Enum.map(fn target ->
      delivery =
        new_delivery(
          "message",
          target,
          message["task_id"],
          message["message_id"],
          message["attempt"],
          message
        )

      Map.put(delivery, "payload", Map.put(message, "delivery_id", delivery["delivery_id"]))
    end)
  end

  defp message_delivery_id(group, message, target) do
    Enum.find_value(group["deliveries"] || [], fn delivery ->
      if delivery["kind"] == "message" and delivery["session_id"] == target and
           delivery["message_id"] == message["message_id"] and
           delivery["task_id"] == message["task_id"] and delivery["attempt"] == message["attempt"],
         do: delivery["delivery_id"]
    end)
  end

  defp new_delivery(kind, session_id, task_id, message_id, attempt, payload) do
    %{
      "delivery_id" => id("delivery"),
      "session_id" => session_id,
      "kind" => kind,
      "message_id" => message_id,
      "task_id" => task_id,
      "attempt" => attempt,
      "payload" => payload,
      "state" => "pending",
      "runtime_id" => nil,
      "started_at" => nil,
      "last_claimed_at" => nil,
      "consumed_at" => nil
    }
  end

  defp append_deliveries(existing, nil), do: existing

  defp append_deliveries(existing, deliveries) when is_list(deliveries) do
    Enum.reduce(deliveries, existing, &upsert_delivery(&2, &1))
  end

  defp append_deliveries(existing, _), do: existing

  defp upsert_delivery(deliveries, delivery) do
    if Enum.any?(deliveries, &(&1["delivery_id"] == delivery["delivery_id"])) do
      Enum.map(deliveries, fn current ->
        if current["delivery_id"] == delivery["delivery_id"], do: delivery, else: current
      end)
    else
      deliveries ++ [delivery]
    end
  end

  defp public_event(event), do: Map.update(event, "payload", nil, &public_payload/1)

  defp public_payload(payload) when is_map(payload) do
    payload
    |> map_public_field("task", &public_task/1)
    |> map_public_field("delivery", &public_delivery/1)
    |> map_public_field("deliveries", fn deliveries -> Enum.map(deliveries || [], &public_delivery/1) end)
  end

  defp public_payload(payload), do: payload

  defp map_public_field(map, key, fun) do
    if Map.has_key?(map, key), do: Map.update!(map, key, fun), else: map
  end

  defp public_task(task) when is_map(task) do
    task
    |> Map.update("workspace", nil, &public_workspace/1)
    |> Map.update("submission", nil, &public_submission/1)
    |> Map.update("attempt_history", [], fn history -> Enum.map(history || [], &public_attempt/1) end)
    |> Map.drop(["project_root", "work_root", "root", "candidate_path"])
  end

  defp public_task(task), do: task

  defp public_attempt(attempt) when is_map(attempt) do
    attempt
    |> Map.update("submission", nil, &public_submission/1)
    |> Map.drop(["project_root", "work_root", "root", "candidate_path"])
  end

  defp public_attempt(attempt), do: attempt
  defp public_workspace(nil), do: nil

  defp public_workspace(workspace) when is_map(workspace) do
    Map.take(workspace, ["kind", "review_status", "reviewed_at", "reviewed_by_session_id", "patch_sha256", "warning"])
  end

  defp public_workspace(workspace), do: workspace
  defp public_submission(nil), do: nil

  defp public_submission(submission) when is_map(submission) do
    Map.take(submission, ["id", "task_id", "attempt", "tree_sha256", "acceptance_sha256", "result_sha256", "created_at"])
  end

  defp public_submission(submission), do: submission

  defp public_delivery(delivery) when is_map(delivery) do
    delivery
    |> Map.drop(["runtime_id"])
    |> map_public_field("payload", &public_task/1)
  end

  defp public_delivery(delivery), do: delivery

  defp prepare_board_update(state, group_id, task_id, raw_attrs) do
    with {:ok, group} <- fetch_group(state, group_id),
         {:ok, task} <- fetch_task(group, task_id),
         {:ok, attrs} <- normalize_board_update(raw_attrs),
         :ok <- ensure_member(group, attrs["session_id"]),
         :ok <- expected_revision(group, attrs["expected_revision"]),
         :ok <- expected_attempt(task, attrs["expected_attempt"]),
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
      {:ok, %{group: group, task: task, attrs: attrs, acceptance: acceptance}}
    else
      {:error, code, message} -> {:error, code, message}
    end
  end

  defp build_updated_task(task, attrs, acceptance) do
    task
    |> maybe_put("title", attrs["title"])
    |> maybe_put("description", attrs["description"])
    |> Map.put("acceptance", acceptance)
    |> Map.put("acceptance_sha256", Newbee.Collaboration.Verification.contract_sha256(acceptance))
    |> maybe_reset_verification(attrs["acceptance"])
    |> maybe_put("depends_on", attrs["depends_on"])
    |> maybe_put("write_scope", attrs["write_scope"])
    |> maybe_put("status", attrs["status"])
    |> maybe_put("progress", attrs["progress"])
    |> maybe_put("result", attrs["result"])
    |> maybe_put("evidence", attrs["evidence"])
    |> Map.put("updated_at", now_iso())
    |> ready_workspace_for_review()
  end

  defp submission_update?(attrs) when is_map(attrs) do
    status = attrs["status"] || attrs[:status]
    status == "submitted" or explicit_submit_request?(attrs)
  end

  defp submission_update?(_), do: false

  defp explicit_submit_request?(attrs) do
    action = attrs["action"] || attrs[:action]

    attrs["submit"] == true or attrs[:submit] == true or
      attrs["submit_requested"] == true or attrs[:submit_requested] == true or
      action in ["submit", :submit]
  end

  defp normalize_submission_request(attrs) when is_map(attrs) do
    status = attrs["status"] || attrs[:status]

    if explicit_submit_request?(attrs) and status != "submitted",
      do: Map.put(attrs, "status", "submitted"),
      else: attrs
  end

  defp normalize_submission_request(attrs), do: attrs

  defp board_update_task_with_submission(group_id, task_id, attrs, server) do
    with {:ok, prepared} <-
           GenServer.call(server, {:board_update_task_prepare, group_id, task_id, attrs}),
         capture_task = submission_task(prepared.task, prepared.group, prepared.attrs, prepared.acceptance),
         {:ok, source_root} <- submission_source_root(capture_task),
         {:ok, submission} <- submission_capture(capture_task, source_root),
         {:ok, bound} <- bind_submission(prepared.task, prepared.attrs, submission),
         :ok <- submission_validate(Map.put(capture_task, "submission", bound)) do
      GenServer.call(
        server,
        {:board_update_task_commit, group_id, task_id, prepared.attrs, submission}
      )
    end
  end

  defp submission_task(task, group, attrs, acceptance) do
    task
    |> Map.put_new("project_root", group["project_root"])
    |> Map.put("status", "submitted")
    |> Map.put("acceptance", acceptance)
    |> Map.put("acceptance_sha256", Newbee.Collaboration.Verification.contract_sha256(acceptance))
    |> maybe_put("progress", attrs["progress"])
    |> maybe_put("result", attrs["result"])
    |> maybe_put("evidence", attrs["evidence"])
  end

  defp submission_source_root(task) do
    workspace = task["workspace"] || task[:workspace] || %{}
    candidates = [workspace["path"] || workspace[:path], task["work_root"], task["project_root"]]

    case Enum.find(candidates, &(is_binary(&1) and File.dir?(&1))) do
      root when is_binary(root) -> {:ok, Path.expand(root)}
      _ -> {:error, "workspace_missing", "Submission source workspace is missing"}
    end
  end

  defp submission_module do
    [
      :"Elixir.Newbee.Collaboration.Submission",
      :"Elixir.Newbee.Submission",
      :"Elixir.Submission"
    ]
    |> Enum.find(fn module ->
      Code.ensure_loaded?(module) and
        function_exported?(module, :capture, 2) and
        function_exported?(module, :verification_root, 1) and
        function_exported?(module, :validate, 1)
    end)
  end

  defp submission_verification_root(task) do
    case submission_module() do
      nil -> {:error, "submission_unavailable", "Submission API is not loaded"}
      module -> normalize_submission_root(apply_submission(module, :verification_root, [task]))
    end
  end

  defp submission_capture(task, root) do
    case submission_module() do
      nil -> {:error, "submission_unavailable", "Submission API is not loaded"}
      module -> normalize_submission_capture(apply_submission(module, :capture, [task, root]))
    end
  end

  defp submission_validate(task) do
    case submission_module() do
      nil ->
        {:error, "submission_unavailable", "Submission API is not loaded"}

      module ->
        case apply_submission(module, :validate, [task]) do
          :ok -> :ok
          {:ok, _} -> :ok
          {:error, code, message} -> {:error, code, message}
          {:error, reason} -> {:error, "submission_invalid", inspect(reason)}
          other -> {:error, "submission_invalid", inspect(other)}
        end
    end
  end

  defp apply_submission(module, function, args) do
    apply(module, function, args)
  rescue
    error -> {:error, "submission_error", Exception.message(error)}
  catch
    kind, reason -> {:error, "submission_error", "#{kind}:#{inspect(reason)}"}
  end

  defp normalize_submission_root({:ok, root}) when is_binary(root), do: {:ok, root}
  defp normalize_submission_root({:error, code, message}), do: {:error, code, message}
  defp normalize_submission_root({:error, reason}), do: {:error, "submission_invalid", inspect(reason)}
  defp normalize_submission_root(other), do: {:error, "submission_invalid", inspect(other)}

  defp normalize_submission_capture({:ok, submission}) when is_map(submission), do: {:ok, submission}
  defp normalize_submission_capture({:error, code, message}), do: {:error, code, message}
  defp normalize_submission_capture({:error, reason}), do: {:error, "submission_invalid", inspect(reason)}
  defp normalize_submission_capture(other), do: {:error, "submission_invalid", inspect(other)}

  defp bind_submission(task, attrs, submission) when is_map(submission) do
    submission_id = submission_field(submission, "submission_id") || submission_field(submission, "id")
    tree_sha256 = submission_field(submission, "tree_sha256")

    cond do
      not is_binary(submission_id) or submission_id == "" ->
        {:error, "submission_invalid", "submission_id is required"}

      not is_binary(tree_sha256) or tree_sha256 == "" ->
        {:error, "submission_invalid", "tree_sha256 is required"}

      true ->
        {:ok,
         submission
         |> Map.put("submission_id", submission_id)
         |> Map.put("tree_sha256", tree_sha256)
         |> Map.put("task_id", task["task_id"])
         |> Map.put("attempt", task["attempt"] || 0)
         |> Map.put("result", attrs["result"])
         |> Map.put("acceptance_sha256", task["acceptance_sha256"])}
    end
  end

  defp bind_submission(_task, _attrs, _submission),
    do: {:error, "submission_invalid", "Submission.capture must return a map"}

  defp submission_field(map, key) do
    Map.get(map, key) || Map.get(map, String.to_atom(key))
  end

  defp verify_prepared_submission(%{task: task, root: fallback_root}) do
    if submission_present?(task) do
      with :ok <- submission_validate(task),
           {:ok, root} <- submission_verification_root(task),
           {:ok, attestation} <- Newbee.Collaboration.Verification.verify(task, root),
           :ok <- submission_validate(task),
           {:ok, attestation} <- bind_submission_attestation(task, attestation) do
        {:ok, attestation}
      end
    else
      Newbee.Collaboration.Verification.verify(task, fallback_root)
    end
  end

  defp submission_present?(task),
    do: is_map(task["submission"]) or is_binary(task["submission_id"])

  defp bind_submission_attestation(task, attestation) do
    submission = task["submission"] || %{}
    submission_id = task["submission_id"] || submission_field(submission, "submission_id")
    tree_sha256 = task["submission_tree_sha256"] || submission_field(submission, "tree_sha256")

    if is_binary(submission_id) and is_binary(tree_sha256),
      do: {:ok, attestation |> Map.put("submission_id", submission_id) |> Map.put("tree_sha256", tree_sha256)},
      else: {:error, "submission_invalid", "task submission binding is incomplete"}
  end
end
