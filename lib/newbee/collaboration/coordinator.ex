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
  @orphan_sweep_interval_ms 60_000

  defstruct store: nil, path: nil, groups: %{}, commands: MapSet.new()

  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  def child_spec(opts) do
    %{id: Keyword.get(opts, :name, __MODULE__), start: {__MODULE__, :start_link, [opts]}}
  end

  def create_group(attrs, server \\ __MODULE__), do: GenServer.call(server, {:create_group, attrs})
  def list(session_id \\ nil, server \\ __MODULE__), do: GenServer.call(server, {:list, session_id})
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

  @impl true
  def init(opts) do
    root = Keyword.get(opts, :root, @default_root)
    path = Keyword.get(opts, :path, Path.join(root, "events.jsonl"))
    File.mkdir_p!(Path.dirname(path))
    {:ok, store} = EventStore.start_link(path: path, durability: Keyword.get(opts, :durability, :batch))

    state = %__MODULE__{store: store, path: path}
    schedule_orphan_sweep()
    {:ok, replay(state)}
  end

  @impl true
  def handle_info(:sweep_orphans, state) do
    {:noreply, sweep_orphans(state) |> tap(fn _ -> schedule_orphan_sweep() end)}
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
            "state" => "idle",
            "parent_session_id" => nil,
            "joined_at" => now
          }
        ],
        "messages" => [],
        "tasks" => [],
        "next_seq" => 0,
        "created_at" => now,
        "updated_at" => now
      }

      event = event("collab_group_created", group_id, %{"group" => group}, attrs["command_id"])
      {:ok, persisted} = append(state, event)
      next = apply_event(state, persisted)
      broadcast(persisted, group)
      {:reply, {:ok, public_group(group)}, next}
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
        |> Map.put("current_session_member", not is_nil(session_id) and session_member?(group, session_id))
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

  def handle_call({:delegate, group_id, attrs}, _from, state) do
    with {:ok, group} <- fetch_group(state, group_id),
         :ok <- group_accepts_tasks(group),
         {:ok, attrs} <- normalize_delegation(attrs),
         :ok <- unique_command(state, attrs["command_id"]),
         :ok <- ensure_member(group, attrs["parent_session_id"]),
         :ok <- ensure_member_capacity(group),
         :ok <- ensure_task_capacity(group),
         :ok <- ensure_not_member(group, attrs["session_id"]) do
      now = now_iso()

      member = %{
        "member_id" => id("mem"),
        "session_id" => attrs["session_id"],
        "role" => attrs["role"],
        "state" => "idle",
        "parent_session_id" => attrs["parent_session_id"],
        "workspace" => attrs["workspace"],
        "joined_at" => now
      }

      task = %{
        "task_id" => id("task"),
        "group_id" => group_id,
        "title" => attrs["title"],
        "description" => attrs["description"],
        "acceptance" => attrs["acceptance"],
        "created_by_session_id" => attrs["parent_session_id"],
        "assigned_session_id" => attrs["session_id"],
        "status" => "assigned",
        "progress" => nil,
        "result" => nil,
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
      broadcast(persisted, next.groups[group_id])
      dispatch_task(task)
      {:reply, {:ok, %{member: member, task: task}}, next}
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

      event = event("collab_message_created", group_id, %{"message" => message}, attrs["command_id"])
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
         {:ok, attrs} <- normalize_task_update(attrs),
         :ok <- unique_command(state, attrs["command_id"]),
         :ok <- ensure_member(group, attrs["session_id"]),
         :ok <- task_actor_allowed(task, attrs["session_id"]),
         :ok <- valid_task_transition(task["status"], attrs["status"]) do
      first_result_terminal? =
        attrs["status"] in ["succeeded", "failed"] and task["status"] not in ["succeeded", "failed"]

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
         :ok <- ensure_member(group, session_id),
         :ok <- task_claimable(task, session_id) do
      claimed =
        task
        |> Map.put("assigned_session_id", session_id)
        |> Map.put("status", "running")
        |> Map.put("lease_owner", session_id)
        |> Map.put("lease_until", DateTime.add(DateTime.utc_now(), 300, :second) |> DateTime.to_iso8601())
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
         :ok <- ensure_member(group, session_id),
         :ok <- lease_owner(task, session_id),
         true <- is_integer(seconds) and seconds in 30..3600 do
      renewed =
        task
        |> Map.put("lease_until", DateTime.add(DateTime.utc_now(), seconds, :second) |> DateTime.to_iso8601())
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

  defp apply_event(state, %{"topic" => "collab_group_created", "payload" => %{"group" => group}} = event) do
    state
    |> put_group(group)
    |> remember_command(event["command_id"])
  end

  defp apply_event(
         state,
         %{"topic" => "collab_member_added", "group_id" => group_id, "payload" => %{"member" => member}} = event
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

    group = %{
      group
      | "members" => group["members"] ++ [member],
        "tasks" => (group["tasks"] || []) ++ [task],
        "updated_at" => event["at"]
    }

    state
    |> put_group(group)
    |> remember_command(event["command_id"])
  end

  defp apply_event(
         state,
         %{"topic" => "collab_member_removed", "group_id" => group_id, "payload" => %{"member" => member}} = event
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
         %{"topic" => "collab_message_created", "group_id" => group_id, "payload" => %{"message" => message}} = event
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
    tasks = (group["tasks"] || []) |> Enum.reject(&(&1["task_id"] == task["task_id"])) |> Kernel.++([task])
    group = %{group | "tasks" => tasks, "updated_at" => event["at"]}

    state
    |> put_group(group)
    |> remember_command(event["command_id"])
  end

  defp apply_event(
         state,
         %{"topic" => "collab_task_claimed", "group_id" => group_id, "payload" => %{"task" => task}} = event
       ) do
    group = state.groups[group_id]
    tasks = (group["tasks"] || []) |> Enum.reject(&(&1["task_id"] == task["task_id"])) |> Kernel.++([task])
    group = %{group | "tasks" => tasks, "updated_at" => event["at"]}

    state
    |> put_group(group)
    |> remember_command(event["command_id"])
  end

  defp apply_event(
         state,
         %{"topic" => "collab_group_status_changed", "group_id" => group_id, "payload" => %{"status" => status}} = event
       ) do
    group = Map.merge(state.groups[group_id], %{"status" => status, "updated_at" => event["at"]})

    state
    |> put_group(group)
    |> remember_command(event["command_id"])
  end

  defp apply_event(
         state,
         %{"topic" => "collab_task_lease_renewed", "group_id" => group_id, "payload" => %{"task" => task}} = event
       ) do
    group = state.groups[group_id]
    tasks = (group["tasks"] || []) |> Enum.reject(&(&1["task_id"] == task["task_id"])) |> Kernel.++([task])
    group = %{group | "tasks" => tasks, "updated_at" => event["at"]}

    state
    |> put_group(group)
    |> remember_command(event["command_id"])
  end

  defp apply_event(state, %{"topic" => "collab_group_deleted", "group_id" => group_id} = event) do
    state
    |> Map.update!(:groups, &Map.delete(&1, group_id))
    |> remember_command(event["command_id"])
  end

  defp put_group(state, group), do: %{state | groups: Map.put(state.groups, group["group_id"], group)}

  defp remember_command(state, nil), do: state
  defp remember_command(state, command_id), do: %{state | commands: MapSet.put(state.commands, command_id)}

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
    active = Enum.count(group["tasks"] || [], &(&1["status"] not in ["succeeded", "failed", "cancelled"]))

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

    cond do
      is_nil(session_id) ->
        {:error, "bad_request", "sessionId 不能为空"}

      is_nil(title) and is_nil(goal) ->
        {:error, "bad_request", "title 或 goal 至少填写一项"}

      true ->
        {:ok,
         %{
           "group_id" => clean(attrs["group_id"] || attrs[:group_id]),
           "title" => title || String.slice(goal, 0, 48),
           "goal" => goal || title,
           "session_id" => session_id,
           "project_root" => clean(attrs["project_root"] || attrs[:project_root]),
           "command_id" => clean(attrs["command_id"] || attrs[:command_id])
         }}
    end
  end

  defp normalize_group(_), do: {:error, "bad_request", "群组参数格式错误"}

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

    if (title && parent && session_id && role in @roles) and is_map(workspace) do
      {:ok,
       %{
         "title" => title,
         "description" => description || title,
         "acceptance" => attrs["acceptance"] || attrs[:acceptance] || [],
         "parent_session_id" => parent,
         "session_id" => session_id,
         "role" => role,
         "workspace" => workspace,
         "command_id" => clean(attrs["command_id"] || attrs[:command_id])
       }}
    else
      {:error, "bad_request", "派生任务需要父会话、子会话、角色、工作区和标题"}
    end
  end

  defp normalize_delegation(_), do: {:error, "bad_request", "派生参数格式错误"}

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
      task["assigned_session_id"] not in [nil, session_id] -> {:error, "forbidden_role", "任务未指派给当前会话"}
      lease_active? and task["lease_owner"] != session_id -> {:error, "lease_lost", "任务已被其它会话占用"}
      task["status"] in ["succeeded", "failed", "cancelled"] -> {:error, "invalid_state", "任务已结束"}
      true -> :ok
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

  defp maybe_mark_workspace_pending(%{"workspace" => %{"review_status" => "waiting"} = workspace} = task, true) do
    Map.put(task, "workspace", Map.put(workspace, "review_status", "pending"))
  end

  defp maybe_mark_workspace_pending(task, _), do: task

  defp fetch_task(group, task_id) do
    case Enum.find(group["tasks"] || [], &(&1["task_id"] == task_id)) do
      nil -> {:error, "not_found", "任务不存在"}
      task -> {:ok, task}
    end
  end

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
end
