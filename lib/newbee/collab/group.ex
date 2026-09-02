defmodule Newbee.Collab.Group do
  @moduledoc """
  Collab v2 (Hive) 核心：单写者 GenServer。

  持 roster + board(任务黑板, CAS+DAG) + mailboxes + 边沿触发 wait。
  崩溃重放恢复。公理见 docs/collab-v2-analysis.md。

  - A1 协调状态 durable + CAS (expected_revision)
  - A2 等待边沿触发，禁止轮询
  - A3 递归两道硬墙 max_depth / max_total
  - A5 验收前置机检
  """

  use GenServer
  alias Newbee.EventStore

  @default_root Path.join(System.user_home!(), ".newbee/collab_v2")
  @max_members 16
  @max_tasks 128
  @max_pending_mail 64
  @default_wait_timeout_ms 30_000
  @max_wait_timeout_ms 300_000

  defstruct store: nil, path: nil, groups: %{}, waiters: [], commands: MapSet.new()

  def start_link(opts) do
    {name, opts} = Keyword.pop(opts, :name)
    gen = if name, do: [name: name], else: []
    GenServer.start_link(__MODULE__, opts, gen)
  end

  def child_spec(opts) do
    %{id: Keyword.get(opts, :name, __MODULE__), start: {__MODULE__, :start_link, [opts]}}
  end

  def create_group(attrs, server), do: GenServer.call(server, {:create_group, attrs})
  def join(group_id, attrs, server), do: GenServer.call(server, {:join, group_id, attrs})
  def close(group_id, session_id, server), do: GenServer.call(server, {:close, group_id, session_id})
  def roster(group_id, server), do: GenServer.call(server, {:roster, group_id})
  def get(group_id, server), do: GenServer.call(server, {:get, group_id})
  def board_put(group_id, task, server), do: GenServer.call(server, {:board_put, group_id, task})
  def board_claim(group_id, task_id, sid, rev, server), do: GenServer.call(server, {:board_claim, group_id, task_id, sid, rev})
  def board_add_dep(group_id, task_id, dep, rev, sid, server), do: GenServer.call(server, {:board_add_dep, group_id, task_id, dep, rev, sid})
  def board_read(group_id, server), do: GenServer.call(server, {:board_read, group_id})
  def board_scope_diagnose(group_id, server), do: GenServer.call(server, {:board_scope_diagnose, group_id})
  def send_message(group_id, attrs, server), do: GenServer.call(server, {:send_message, group_id, attrs})
  def inbox(group_id, sid, opts, server), do: GenServer.call(server, {:inbox, group_id, sid, opts})
  def ack(group_id, sid, mid, server), do: GenServer.call(server, {:ack, group_id, sid, mid})

  def wait(group_id, since_rev, sid, timeout_ms, server) do
    t = clamp_wait_timeout(timeout_ms)
    GenServer.call(server, {:wait, group_id, since_rev, sid, t}, t + 5_000)
  end

  defp clamp_wait_timeout(t) when is_integer(t), do: t |> max(1_000) |> min(@max_wait_timeout_ms)
  defp clamp_wait_timeout(_), do: @default_wait_timeout_ms

  @impl true
  def init(opts) do
    root = Keyword.get(opts, :root, @default_root)
    path = Keyword.get(opts, :path, Path.join(root, "hive_events.jsonl"))
    File.mkdir_p!(Path.dirname(path))
    {:ok, store} = EventStore.start_link(path: path, durability: Keyword.get(opts, :durability, :batch))
    {:ok, replay(%__MODULE__{store: store, path: path})}
  end

  defp replay(state) do
    Enum.reduce(EventStore.replay(state.path), state, fn ev, st ->
      apply_event(st, %{topic: ev.topic, data: ev.data})
    end)
  end

  defp append(state, topic, data) do
    {:ok, ev} = EventStore.append(state.store, topic, data)
    ev
  end

  # ── 事件应用 ──

  defp apply_event(state, %{topic: :hive_group_created, data: d}) do
    put_in(state.groups[d["group_id"]], d["group"])
  end

  defp apply_event(state, %{topic: :hive_member_joined, data: d}) do
    gid = d["group_id"]

    update_group(state, gid, fn g ->
      g
      |> Map.put("members", (g["members"] || []) ++ [d["member"]])
      |> Map.put("total_spawned", (g["total_spawned"] || 0) + 1)
      |> put_board_rev(current_rev(g) + 1)
    end)
  end

  defp apply_event(state, %{topic: :hive_member_left, data: d}) do
    update_group(state, d["group_id"], fn g ->
      g
      |> Map.put("members", Enum.reject(g["members"] || [], &(&1["session_id"] == d["session_id"])))
      |> put_board_rev(current_rev(g) + 1)
    end)
  end

  defp apply_event(state, %{topic: :hive_task_written, data: d}) do
    gid = d["group_id"]

    update_group(state, gid, fn g ->
      tasks = get_in(g, ["board", "tasks"]) || %{}
      tasks = Map.put(tasks, d["task"]["task_id"], d["task"])
      rev = current_rev(g) + 1

      g
      |> put_in(["board", "tasks"], tasks)
      |> put_board_rev(rev)
    end)
  end

  defp apply_event(state, %{topic: :hive_message_sent, data: d}) do
    update_group(state, d["group_id"], fn g ->
      boxes = g["mailboxes"] || %{}
      to = d["message"]["to_session_id"]
      box = Map.get(boxes, to, [])
      Map.put(g, "mailboxes", Map.put(boxes, to, box ++ [d["message"]]))
    end)
  end

  defp apply_event(state, %{topic: :hive_message_acked, data: d}) do
    update_group(state, d["group_id"], fn g ->
      sid = d["session_id"]
      box = get_in(g, ["mailboxes", sid]) || []

      box =
        Enum.map(box, fn m ->
          if m["message_id"] == d["message_id"], do: Map.put(m, "acked", true), else: m
        end)

      put_in(g, ["mailboxes", sid], box)
    end)
  end

  defp apply_event(state, _ev), do: state

  defp update_group(state, gid, fun) do
    case state.groups[gid] do
      nil -> state
      g -> put_in(state.groups[gid], fun.(g))
    end
  end

  defp put_board_rev(g, rev), do: put_in(g, ["board", "revision"], rev)
  defp current_rev(g), do: get_in(g, ["board", "revision"]) || 0
  defp group_rev(state, gid), do: get_in(state.groups, [gid, "board", "revision"]) || 0

  # ── 组/成员 ──

  @impl true
  def handle_call({:create_group, attrs}, _from, state) do
    with {:ok, attrs} <- normalize_group(attrs),
         :ok <- unique_command(state, attrs["command_id"]) do
      gid = "hg_" <> short_id()

      group = %{
        "group_id" => gid,
        "title" => attrs["title"],
        "goal" => attrs["goal"],
        "project_root" => attrs["project_root"],
        "lead_session_id" => attrs["session_id"],
        "status" => "running",
        "members" => [
          %{
            "session_id" => attrs["session_id"],
            "name" => "lead",
            "role" => "lead",
            "depth" => 0,
            "state" => "idle",
            "joined_at" => now_iso()
          }
        ],
        "board" => %{"tasks" => %{}, "revision" => 0},
        "mailboxes" => %{},
        "max_depth" => attrs["max_depth"],
        "max_total" => attrs["max_total"],
        "total_spawned" => 1,
        "created_at" => now_iso()
      }

      ev = append(state, :hive_group_created, %{"group_id" => gid, "group" => group})
      next = apply_event(state, ev)
      {:reply, {:ok, public_group(next.groups[gid])}, remember_command(next, attrs["command_id"])}
    else
      {:error, c, m} -> {:reply, {:error, c, m}, state}
    end
  end

  def handle_call({:join, gid, attrs}, _from, state) do
    with {:ok, group} <- fetch_group(state, gid),
         {:ok, attrs} <- normalize_join(attrs),
         :ok <- unique_command(state, attrs["command_id"]),
         :ok <- member_capacity(group),
         :ok <- not_member(group, attrs["session_id"]),
         :ok <- depth_ok(group, attrs["depth"]),
         :ok <- total_ok(group) do
      member = %{
        "session_id" => attrs["session_id"],
        "name" => unique_name(group, attrs["name"]),
        "role" => attrs["role"],
        "persona" => attrs["persona"],
        "depth" => attrs["depth"],
        "state" => "idle",
        "parent_session_id" => attrs["parent_session_id"],
        "joined_at" => now_iso()
      }

      ev = append(state, :hive_member_joined, %{"group_id" => gid, "member" => member})

      next =
        state
        |> apply_event(ev)
        |> remember_command(attrs["command_id"])

      notify = notify_waiters(next, gid)
      {:reply, {:ok, member}, notify}
    else
      {:error, c, m} -> {:reply, {:error, c, m}, state}
    end
  end

  def handle_call({:close, gid, sid}, _from, state) do
    with {:ok, _g} <- fetch_group(state, gid),
         true <- is_binary(sid) do
      ev = append(state, :hive_member_left, %{"group_id" => gid, "session_id" => sid})
      next = apply_event(state, ev)
      {:reply, {:ok, %{"left" => sid}}, notify_waiters(next, gid)}
    else
      {:error, c, m} -> {:reply, {:error, c, m}, state}
      false -> {:reply, {:error, "bad_request", "session_id 缺失"}, state}
    end
  end

  def handle_call({:roster, gid}, _from, state) do
    case fetch_group(state, gid) do
      {:ok, g} ->
        {:reply, {:ok, Enum.map(g["members"], &Map.take(&1, ["session_id", "name", "role", "state", "depth"]))}, state}

      err ->
        {:reply, err, state}
    end
  end

  def handle_call({:get, gid}, _from, state) do
    case fetch_group(state, gid) do
      {:ok, g} -> {:reply, {:ok, public_group(g)}, state}
      err -> {:reply, err, state}
    end
  end

  # ── 黑板 ──

  def handle_call({:board_put, gid, task}, _from, state) do
    with {:ok, group} <- fetch_group(state, gid),
         {:ok, task} <- normalize_task(task),
         :ok <- task_capacity(group, task),
         :ok <- cas_ok(group, task["expected_revision"]),
         :ok <- deps_acyclic(group, task["task_id"], task["depends_on"] || []) do
      existing = get_in(group, ["board", "tasks", task["task_id"]]) || %{}

      merged =
        existing
        |> Map.merge(task)
        |> Map.put("task_id", task["task_id"])
        |> Map.put("updated_at", now_iso())
        |> Map.put_new("created_at", now_iso())
        |> Map.put_new("status", "ready")
        |> Map.put_new("depends_on", [])
        |> Map.put_new("write_scope", [])
        |> Map.delete("expected_revision")

      ev = append(state, :hive_task_written, %{"group_id" => gid, "task" => merged})
      next = apply_event(state, ev)
      rev = current_rev(next.groups[gid])
      {:reply, {:ok, %{"task" => merged, "revision" => rev, "warnings" => scope_warnings(next.groups[gid], merged)}}, notify_waiters(next, gid)}
    else
      {:error, c, m} -> {:reply, {:error, c, m}, state}
    end
  end

  def handle_call({:board_claim, gid, task_id, sid, expected_rev}, _from, state) do
    with {:ok, group} <- fetch_group(state, gid),
         {:ok, task} <- fetch_task(group, task_id),
         :ok <- cas_ok(group, expected_rev),
         :ok <- claimable(task) do
      updated = Map.merge(task, %{"owner" => sid, "status" => "claimed", "updated_at" => now_iso()})
      ev = append(state, :hive_task_written, %{"group_id" => gid, "task" => updated})
      next = apply_event(state, ev)
      {:reply, {:ok, %{"task" => updated, "revision" => current_rev(next.groups[gid])}}, notify_waiters(next, gid)}
    else
      {:error, c, m} -> {:reply, {:error, c, m}, state}
    end
  end

  def handle_call({:board_add_dep, gid, task_id, dep, expected_rev, _sid}, _from, state) do
    with {:ok, group} <- fetch_group(state, gid),
         {:ok, task} <- fetch_task(group, task_id),
         :ok <- cas_ok(group, expected_rev),
         {:ok, _d} <- fetch_task(group, dep),
         :ok <- deps_acyclic(group, task_id, [dep]) do
      deps = Enum.uniq((task["depends_on"] || []) ++ [dep])
      updated = Map.merge(task, %{"depends_on" => deps, "updated_at" => now_iso()})
      ev = append(state, :hive_task_written, %{"group_id" => gid, "task" => updated})
      next = apply_event(state, ev)
      {:reply, {:ok, %{"task" => updated, "revision" => current_rev(next.groups[gid])}}, notify_waiters(next, gid)}
    else
      {:error, c, m} -> {:reply, {:error, c, m}, state}
    end
  end

  def handle_call({:board_read, gid}, _from, state) do
    case fetch_group(state, gid) do
      {:ok, g} ->
        {:reply, {:ok, %{"revision" => current_rev(g), "tasks" => Map.values(g["board"]["tasks"])}}, state}

      err ->
        {:reply, err, state}
    end
  end

  def handle_call({:board_scope_diagnose, gid}, _from, state) do
    case fetch_group(state, gid) do
      {:ok, g} -> {:reply, {:ok, %{"overlaps" => all_scope_overlaps(g)}}, state}
      err -> {:reply, err, state}
    end
  end

  # ── 信箱 ──

  def handle_call({:send_message, gid, attrs}, _from, state) do
    with {:ok, group} <- fetch_group(state, gid),
         {:ok, attrs} <- normalize_message(attrs),
         :ok <- unique_command(state, attrs["command_id"]),
         :ok <- member_check(group, attrs["from_session_id"]),
         :ok <- member_check(group, attrs["to_session_id"]),
         :ok <- mailbox_capacity(group, attrs["to_session_id"]) do
      message = %{
        "message_id" => "hm_" <> short_id(),
        "group_id" => gid,
        "from_session_id" => attrs["from_session_id"],
        "to_session_id" => attrs["to_session_id"],
        "body" => attrs["body"],
        "kind" => attrs["kind"],
        "wake" => attrs["wake"],
        "acked" => false,
        "at" => now_iso()
      }

      ev = append(state, :hive_message_sent, %{"group_id" => gid, "message" => message})
      next = state |> apply_event(ev) |> remember_command(attrs["command_id"])
      {:reply, {:ok, message}, notify_waiters(next, gid)}
    else
      {:error, c, m} -> {:reply, {:error, c, m}, state}
    end
  end

  def handle_call({:inbox, gid, sid, opts}, _from, state) do
    case fetch_group(state, gid) do
      {:ok, g} ->
        box = get_in(g, ["mailboxes", sid]) || []
        box = if Keyword.get(opts, :unacked, true), do: Enum.reject(box, & &1["acked"]), else: box
        {:reply, {:ok, box}, state}

      err ->
        {:reply, err, state}
    end
  end

  def handle_call({:ack, gid, sid, mid}, _from, state) do
    with {:ok, _g} <- fetch_group(state, gid) do
      ev = append(state, :hive_message_acked, %{"group_id" => gid, "session_id" => sid, "message_id" => mid})
      {:reply, :ok, apply_event(state, ev)}
    else
      {:error, c, m} -> {:reply, {:error, c, m}, state}
    end
  end

  # ── wait (边沿触发) ──

  def handle_call({:wait, gid, since_rev, sid, timeout_ms}, from, state) do
    case fetch_group(state, gid) do
      {:ok, g} ->
        if edge_since(g, since_rev, sid) do
          {:reply, {:ok, change_summary(g, since_rev, sid)}, state}
        else
          ref = Process.monitor(elem(from, 0))
          timer = Process.send_after(self(), {:wait_timeout, ref}, timeout_ms)
          waiter = %{ref: ref, from: from, group_id: gid, since_rev: current_rev(g), session_id: sid, timer: timer}
          {:noreply, %{state | waiters: [waiter | state.waiters]}}
        end

      {:error, c, m} ->
        {:reply, {:error, c, m}, state}
    end
  end

  @impl true
  def handle_info({:wait_timeout, ref}, state) do
    case Enum.split_with(state.waiters, &(&1.ref == ref)) do
      {[w], rest} ->
        Process.demonitor(ref, [:flush])
        GenServer.reply(w.from, {:ok, %{"kind" => "timeout", "revision" => group_rev(state, w.group_id)}})
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

  defp notify_waiters(state, gid) do
    {hit, rest} =
      Enum.split_with(state.waiters, fn w ->
        w.group_id == gid and
          case state.groups[gid] do
            nil -> false
            g -> edge_since(g, w.since_rev, w.session_id)
          end
      end)

    Enum.each(hit, fn w ->
      Process.cancel_timer(w.timer)
      Process.demonitor(w.ref, [:flush])
      GenServer.reply(w.from, {:ok, change_summary(state.groups[gid], w.since_rev, w.session_id)})
    end)

    %{state | waiters: rest}
  end

  defp edge_since(g, since_rev, sid) do
    pending = (get_in(g, ["mailboxes", sid]) || []) |> Enum.any?(&(not &1["acked"]))
    current_rev(g) > since_rev or pending
  end

  defp change_summary(g, since_rev, sid) do
    new_tasks =
      g["board"]["tasks"]
      |> Map.values()
      |> Enum.filter(fn t -> Map.get(t, "_rev", 0) > since_rev end)
      |> Enum.map(& &1["task_id"])

    pending_mail = (get_in(g, ["mailboxes", sid]) || []) |> Enum.reject(& &1["acked"]) |> length()

    %{"kind" => "edge", "revision" => current_rev(g), "new_tasks" => new_tasks, "pending_mail" => pending_mail}
  end

  # ── 校验/工具 ──

  defp fetch_group(state, gid) do
    case state.groups[gid] do
      nil -> {:error, "not_found", "协作组不存在"}
      g -> {:ok, g}
    end
  end

  defp fetch_task(group, task_id) do
    case get_in(group, ["board", "tasks", task_id]) do
      nil -> {:error, "not_found", "任务不存在"}
      t -> {:ok, t}
    end
  end

  defp normalize_group(attrs) when is_map(attrs) do
    if is_binary(attrs["session_id"]) do
      {:ok,
       %{
         "session_id" => attrs["session_id"],
         "title" => attrs["title"] || "协作组",
         "goal" => attrs["goal"] || "",
         "project_root" => attrs["project_root"],
         "command_id" => attrs["command_id"],
         "max_depth" => attrs["max_depth"] || 3,
         "max_total" => attrs["max_total"] || @max_members
       }}
    else
      {:error, "bad_request", "缺少 session_id"}
    end
  end

  defp normalize_group(_), do: {:error, "bad_request", "组参数无效"}

  defp normalize_join(attrs) when is_map(attrs) do
    if is_binary(attrs["session_id"]) do
      {:ok,
       %{
         "session_id" => attrs["session_id"],
         "name" => attrs["name"] || "agent",
         "role" => attrs["role"] || "worker",
         "persona" => attrs["persona"],
         "depth" => attrs["depth"] || 0,
         "parent_session_id" => attrs["parent_session_id"],
         "command_id" => attrs["command_id"]
       }}
    else
      {:error, "bad_request", "缺少 session_id"}
    end
  end

  defp normalize_join(_), do: {:error, "bad_request", "成员参数无效"}

  defp normalize_task(task) when is_map(task) do
    tid = task["task_id"] || ("t_" <> short_id())

    {:ok,
     %{
       "task_id" => tid,
       "title" => task["title"] || tid,
       "description" => task["description"] || "",
       "acceptance" => List.wrap(task["acceptance"] || []),
       "status" => task["status"],
       "owner" => task["owner"],
       "depends_on" => List.wrap(task["depends_on"] || []),
       "write_scope" => List.wrap(task["write_scope"] || []),
       "expected_revision" => task["expected_revision"],
       "command_id" => task["command_id"]
     }}
  end

  defp normalize_task(_), do: {:error, "bad_request", "任务参数无效"}

  defp normalize_message(attrs) when is_map(attrs) do
    from = attrs["from_session_id"] || attrs["sender_session_id"]
    to = attrs["to_session_id"] || attrs["to"]

    cond do
      not is_binary(from) -> {:error, "bad_request", "缺少 from_session_id"}
      not is_binary(to) -> {:error, "bad_request", "缺少 to_session_id"}
      not is_binary(attrs["body"]) -> {:error, "bad_request", "缺少 body"}
      true ->
        {:ok,
         %{
           "from_session_id" => from,
           "to_session_id" => to,
           "body" => attrs["body"],
           "kind" => attrs["kind"] || "chat",
           "wake" => attrs["wake"] == true,
           "command_id" => attrs["command_id"]
         }}
    end
  end

  defp normalize_message(_), do: {:error, "bad_request", "消息参数无效"}

  defp unique_command(_state, nil), do: :ok

  defp unique_command(state, cid) do
    if MapSet.member?(state.commands, cid),
      do: {:error, "conflict", "重复命令 #{cid}"},
      else: :ok
  end

  defp remember_command(state, nil), do: state
  defp remember_command(state, cid), do: %{state | commands: MapSet.put(state.commands, cid)}

  defp member_capacity(group) do
    if length(group["members"]) >= @max_members,
      do: {:error, "limit", "成员数已达上限"},
      else: :ok
  end

  defp task_capacity(group, task) do
    if is_nil(get_in(group, ["board", "tasks", task["task_id"]])) and
         map_size(group["board"]["tasks"]) >= @max_tasks,
       do: {:error, "limit", "任务数已达上限"},
       else: :ok
  end

  defp not_member(group, sid) do
    if Enum.any?(group["members"], &(&1["session_id"] == sid)),
      do: {:error, "conflict", "会话已是成员"},
      else: :ok
  end

  defp member_check(group, sid) do
    if Enum.any?(group["members"], &(&1["session_id"] == sid)),
      do: :ok,
      else: {:error, "not_member", "会话不在组内"}
  end

  defp depth_ok(group, depth) do
    if depth > group["max_depth"],
      do: {:error, "depth_limit", "派生深度超限"},
      else: :ok
  end

  defp total_ok(group) do
    if group["total_spawned"] >= group["max_total"],
      do: {:error, "limit", "代理总数超限"},
      else: :ok
  end

  defp mailbox_capacity(group, sid) do
    pending = (get_in(group, ["mailboxes", sid]) || []) |> Enum.count(&(not &1["acked"]))

    if pending >= @max_pending_mail,
      do: {:error, "limit", "信箱已满"},
      else: :ok
  end

  defp cas_ok(_group, nil), do: :ok

  defp cas_ok(group, expected) when is_integer(expected) do
    cur = current_rev(group)

    if cur == expected,
      do: :ok,
      else: {:error, "revision_conflict", "黑板版本 #{cur} 与期望 #{expected} 不一致，请重读"}
  end

  defp cas_ok(_, _), do: {:error, "bad_request", "expected_revision 须为整数"}

  defp claimable(task) do
    cond do
      task["status"] in ["succeeded", "failed", "cancelled"] -> {:error, "terminal", "任务已终态"}
      is_binary(task["owner"]) -> {:error, "conflict", "任务已被认领"}
      true -> :ok
    end
  end

  defp deps_acyclic(group, task_id, new_deps) do
    tasks = group["board"]["tasks"]
    graph = Map.new(tasks, fn {k, v} -> {k, v["depends_on"] || []} end)
    graph = Map.update(graph, task_id, new_deps, &Enum.uniq(&1 ++ new_deps))

    if has_cycle?(graph, task_id, MapSet.new()),
      do: {:error, "cycle", "依赖会形成环"},
      else: :ok
  end

  defp has_cycle?(graph, node, seen) do
    if MapSet.member?(seen, node),
      do: true,
      else: Enum.any?(Map.get(graph, node, []), &has_cycle?(graph, &1, MapSet.put(seen, node)))
  end

  defp scope_warnings(group, task) do
    mine = task["write_scope"] || []

    overlaps =
      group["board"]["tasks"]
      |> Map.values()
      |> Enum.reject(&(&1["task_id"] == task["task_id"]))
      |> Enum.flat_map(fn other ->
        (other["write_scope"] || [])
        |> Enum.filter(fn scope -> Enum.any?(mine, &paths_overlap?(&1, scope)) end)
        |> Enum.map(&%{"task" => other["task_id"], "scope" => &1})
      end)

    case overlaps do
      [] -> []
      list -> ["write_scope 重叠(诊断非阻塞): " <> inspect(list)]
    end
  end

  defp all_scope_overlaps(group) do
    tasks = Map.values(group["board"]["tasks"])

    for a <- tasks, b <- tasks, a["task_id"] < b["task_id"],
        sa <- a["write_scope"] || [], sb <- b["write_scope"] || [],
        paths_overlap?(sa, sb) do
      %{"a" => a["task_id"], "b" => b["task_id"], "scope_a" => sa, "scope_b" => sb}
    end
  end

  defp paths_overlap?(p1, p2) do
    String.starts_with?(p1, p2) or String.starts_with?(p2, p1)
  end

  defp unique_name(group, base) do
    taken = MapSet.new(Enum.map(group["members"], & &1["name"]))

    if MapSet.member?(taken, base) do
      Enum.find_value(2..99, fn n ->
        cand = "#{base}-#{n}"
        if MapSet.member?(taken, cand), do: nil, else: cand
      end) || "#{base}-#{System.unique_integer([:positive])}"
    else
      base
    end
  end

  defp public_group(g) do
    g
    |> Map.take(["group_id", "title", "goal", "status", "lead_session_id", "max_depth", "max_total", "total_spawned", "created_at"])
    |> Map.put("member_count", length(g["members"]))
    |> Map.put("board_revision", current_rev(g))
    |> Map.put("task_count", map_size(g["board"]["tasks"]))
  end

  defp short_id, do: Base.url_encode64(:crypto.strong_rand_bytes(6), padding: false)
  defp now_iso, do: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
end
