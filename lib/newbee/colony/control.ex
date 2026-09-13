defmodule Newbee.Colony.Control do
  @moduledoc "Persistent scoped execution gates; state reflects real session acknowledgements."
  import Kernel, except: [binding: 1]
  alias Newbee.Colony.Store

  def set(cid, scope, target, action, opts \\ []) do
    with true <- scope in ["colony", "bee", "work"],
         true <- action in ["pause", "resume", "interrupt"],
         {:ok, colony} <- Store.get_colony(cid),
         :ok <- authorize(colony, Keyword.get(opts, :actor_bee_id)),
         :ok <- valid_target(cid, scope, target) do
      id = key(cid, scope, target)

      result =
        Store.transaction(fn data ->
          current = get_in(data, ["controls", id]) || %{"revision" => 0}
          expected = Keyword.get(opts, :revision)

          if expected != nil and expected != current["revision"] do
            {:error, "conflict", "控制状态已变化，请刷新后重试"}
          else
            gate = %{
              "id" => id,
              "colony_id" => cid,
              "scope" => scope,
              "target_id" => target,
              "paused" => action != "resume",
              "action" => action,
              "revision" => current["revision"] + 1,
              "actor_bee_id" => Keyword.get(opts, :actor_bee_id),
              "updated_at" => now()
            }

            {:ok, {:ok, gate}, put_in(data, ["controls", id], gate)}
          end
        end)

      with {:ok, gate} <- result do
        affected_sessions(cid, scope, target)
        |> Enum.each(fn sid ->
          case Newbee.Web.Session.lookup(sid) do
            {:ok, pid} ->
              if action == "interrupt", do: Newbee.Web.Session.interrupt(pid)
              if action == "resume", do: GenServer.cast(pid, :colony_resume)

            _ ->
              :ok
          end
        end)

        Store.append_trace(%{
          "colony_id" => cid,
          "type" => "control",
          "channel" => "colony",
          "bee_id" => Keyword.get(opts, :actor_bee_id),
          "text" => label(action),
          "data" => gate,
          "created_at" => now()
        })

        {:ok, Map.put(gate, "state", state(cid, scope, target))}
      end
    else
      false -> {:error, "bad_request", "无效的控制范围或动作"}
      error -> error
    end
  end

  def authorize(colony, actor) do
    admins = colony["admin_bee_ids"] || [colony["queen_bee_id"]]
    if is_binary(actor) and actor in admins, do: :ok, else: {:error, "forbidden", "需要当前蜂群管理员权限"}
  end

  defp valid_target(_cid, "colony", _), do: :ok

  defp valid_target(cid, scope, target) do
    table = if scope == "bee", do: "bees", else: "tasks"

    case Store.get(table, target) do
      {:ok, %{"colony_id" => ^cid} = item} ->
        if scope == "bee" and item["kind"] == "human",
          do: {:error, "human_member", "真人只能接收暂停通知"},
          else: :ok

      _ ->
        {:error, "not_found", "当前群中没有该对象"}
    end
  end

  def key(cid, scope, target), do: Enum.join([cid, scope, target || cid], ":")

  def gate(cid, scope, target) do
    case Store.get("controls", key(cid, scope, target)) do
      {:ok, gate} -> gate
      _ -> %{"paused" => false, "revision" => 0}
    end
  end

  def blocked?(cid, bid, tid \\ nil) do
    colony_inactive?(cid) or remote_disconnected?(cid) or gate(cid, "colony", cid)["paused"] or
      (is_binary(bid) and gate(cid, "bee", bid)["paused"]) or
      work_blocked?(cid, tid, MapSet.new())
  end

  defp colony_inactive?(cid) do
    case Store.get_colony(cid) do
      {:ok, colony} -> colony["status"] == "dissolved"
      _ -> true
    end
  end

  defp remote_disconnected?(cid) do
    case Store.get("identities", "connection:" <> cid) do
      {:ok, connection} -> now() - (connection["last_sync_at"] || 0) > 15_000
      _ -> false
    end
  end

  defp work_blocked?(_, nil, _), do: false

  defp work_blocked?(cid, tid, seen) do
    if MapSet.member?(seen, tid) do
      true
    else
      case Store.get_task(tid) do
        {:ok, task} ->
          task["status"] in ["done", "cancelled", "failed"] or gate(cid, "work", tid)["paused"] or
            work_blocked?(cid, task["parent_task_id"], MapSet.put(seen, tid))

        _ ->
          true
      end
    end
  end

  def binding(sid) do
    case Store.get("conversations", sid) do
      {:ok, %{"visibility" => "upload"}} ->
        nil

      {:ok, value} ->
        value

      _ ->
        case Enum.find(Store.list_bees(), fn b ->
               b["kind"] != "human" and sid in session_ids(b)
             end) do
          nil -> nil
          bee -> %{"colony_id" => bee["colony_id"], "bee_id" => bee["id"]}
        end
    end
  end

  def blocked_session?(sid) when is_binary(sid) do
    case binding(sid) do
      nil -> false
      b -> blocked?(b["colony_id"], b["bee_id"], b["task_id"]) or stale_execution?(b["task_id"])
    end
  end

  def blocked_session?(_), do: false
  defp stale_execution?(nil), do: false

  defp stale_execution?(tid) do
    case Store.get_task(tid) do
      {:ok, task} ->
        Store.all("deliveries")
        |> Enum.any?(
          &(&1["task_id"] == tid and &1["status"] == "accepted" and
              (&1["context_revision"] || 0) < (task["context_revision"] || 0))
        )

      _ ->
        false
    end
  end

  def loop_blocked?({:web_session, sid}), do: blocked_session?(sid)
  def loop_blocked?(_), do: false

  def session_ids(bee) do
    ([bee["session_id"]] ++ (bee["conversations"] || bee["session_ids"] || []))
    |> Enum.filter(&is_binary/1)
    |> Enum.uniq()
  end

  def affected_sessions(cid, scope, target) do
    bees = Store.bees_for_colony(cid) |> Enum.reject(&(&1["kind"] == "human"))

    candidates =
      Enum.flat_map(bees, &session_ids/1) ++
        (Store.all("conversations")
         |> Enum.filter(&(&1["colony_id"] == cid and &1["kind"] != "human"))
         |> Enum.map(& &1["id"]))

    candidates
    |> Enum.uniq()
    |> Enum.filter(fn sid ->
      case binding(sid) do
        %{"colony_id" => ^cid} = b ->
          scope == "colony" or (scope == "bee" and b["bee_id"] == target) or
            (scope == "work" and descendant?(b["task_id"], target, MapSet.new()))

        _ ->
          false
      end
    end)
  end

  defp descendant?(nil, _, _), do: false
  defp descendant?(id, id, _), do: true

  defp descendant?(id, target, seen) do
    if MapSet.member?(seen, id) do
      false
    else
      case Store.get_task(id) do
        {:ok, work} -> descendant?(work["parent_task_id"], target, MapSet.put(seen, id))
        _ -> false
      end
    end
  end

  def state(cid, scope, target) do
    direct = gate(cid, scope, target)
    group = gate(cid, "colony", cid)

    task =
      if scope == "work",
        do:
          (case Store.get_task(target) do
             {:ok, t} -> t
             _ -> %{}
           end),
        else: %{}

    inherited =
      if scope == "work",
        do: gate(cid, "bee", task["assigned_bee_id"]),
        else: %{"paused" => false}

    requested =
      direct["paused"] or group["paused"] or inherited["paused"] or
        (scope == "work" and not Newbee.Colony.Task.terminal?(task) and
           work_blocked?(cid, target, MapSet.new()))

    if requested do
      sessions = affected_sessions(cid, scope, target)

      relevant =
        Store.bees_for_colony(cid)
        |> Enum.filter(fn b ->
          is_binary(b["remote_member_id"]) and
            (scope == "colony" or b["id"] == target or b["id"] == task["assigned_bee_id"])
        end)

      remote_unknown =
        Enum.any?(relevant, fn bee ->
          active_gate = Enum.find([direct, group, inherited], & &1["paused"]) || direct
          ack = get_in(bee, ["remote_controls", active_gate["id"]]) || %{}

          now() - (bee["last_seen_at"] || 0) > 15_000 or
            ack["revision"] != active_gate["revision"] or ack["state"] != "paused"
        end)

      if remote_unknown or Enum.any?(sessions, &(session_status(&1) != "idle")),
        do: "pausing",
        else: "paused"
    else
      "running"
    end
  end

  def session_status(sid) do
    case Newbee.Web.Session.lookup(sid) do
      {:ok, pid} -> if GenServer.call(pid, :peek_busy, 1_000), do: "working", else: "idle"
      _ -> "unknown"
    end
  catch
    :exit, _ -> "unknown"
  end

  defp label("pause"), do: "已请求暂停 AI，等待执行器确认"
  defp label("resume"), do: "已恢复此范围；其他独立暂停仍有效"
  defp label("interrupt"), do: "已请求立即中止，已有外部效果不会自动撤回"
  defp now, do: System.system_time(:millisecond)
end
