defmodule Newbee.Collaboration.CrossHost.Store do
  @moduledoc "跨主机群本地存取：ETS 按需建表，口令与令牌哈希不进公开视图。"
  @gt :xh_groups
  @tt :xh_tasks
  @kt :xh_knowledge
  @mt :xh_messages
  @at :xh_activity
  @ot :xh_outbox
  @rt :xh_remote_resources
  @max_outbox 10_000
  @max_delivery_batch 64

  @spec put_group(map()) :: :ok
  def put_group(g) when is_map(g) do
    ensure()
    :ets.insert(@gt, {Map.get(g, "id"), g})
    :ok
  end

  @spec get_group(binary()) :: {:ok, map()} | {:error, term(), term()}
  def get_group(id) when is_binary(id) do
    ensure()

    case :ets.lookup(@gt, id) do
      [{_, g}] -> {:ok, g}
      [] -> {:error, "not_found", "协作群不存在"}
    end
  end

  def get_group(_), do: {:error, "not_found", "协作群不存在"}
  @spec list_public() :: [map()]
  def list_public do
    ensure()
    :ets.tab2list(@gt) |> Enum.map(fn {_, g} -> public_group(g) end)
  end

  @spec public_group(map()) :: map()
  def public_group(group) when is_map(group) do
    devices = Map.get(group, "devices", %{}) |> Map.new(fn {id, device} -> {id, Map.drop(device, ["token_hash"])} end)

    group
    |> Map.drop(["password", "knowledge"])
    |> Map.put("devices", devices)
    |> Map.put("device_count", map_size(devices))
    |> Map.put("knowledge_count", length(list_knowledge(Map.get(group, "id", ""))))
  end

  @spec put_task(map()) :: :ok
  def put_task(task) when is_map(task) do
    ensure()
    id = Map.get(task, "id")

    previous =
      case :ets.lookup(@tt, id) do
        [{_, value}] -> value
        _ -> nil
      end

    :ets.insert(@tt, {id, task})

    if is_binary(Map.get(task, "group_id")) and previous != task do
      topic = if previous, do: "cross_host_task_updated", else: "cross_host_task_created"
      emit_group_event(task["group_id"], topic, Map.take(task, ["id", "title", "status", "created_at", "attempts"]))
    end

    :ok
  end

  @spec list_tasks(binary()) :: [map()]
  def list_tasks(gid) when is_binary(gid) do
    ensure()
    :ets.tab2list(@tt) |> Enum.map(fn {_, t} -> t end) |> Enum.filter(fn t -> Map.get(t, "group_id") == gid end)
  end

  @spec list_knowledge(binary()) :: [map()]
  def list_knowledge(gid) when is_binary(gid) do
    ensure()

    :ets.tab2list(@kt)
    |> Enum.map(fn {_, entry} -> entry end)
    |> Enum.filter(fn entry -> Map.get(entry, "group_id") == gid end)
    |> Enum.sort_by(&Map.get(&1, "created_at", 0), :desc)
  end

  @spec list_messages(binary(), keyword()) :: [map()]
  def list_messages(gid, opts \\ []) when is_binary(gid) and is_list(opts) do
    ensure()
    limit = Keyword.get(opts, :limit, 200)

    :ets.tab2list(@mt)
    |> Enum.map(fn {_, message} -> message end)
    |> Enum.filter(fn message -> Map.get(message, "group_id") == gid end)
    |> Enum.sort_by(&Map.get(&1, "created_at", 0), :desc)
    |> Enum.take(limit)
  end

  @spec list_activity(binary(), keyword()) :: [map()]
  def list_activity(gid, opts \\ []) when is_binary(gid) and is_list(opts) do
    ensure()
    limit = Keyword.get(opts, :limit, 200)

    :ets.tab2list(@at)
    |> Enum.map(fn {_, event} -> event end)
    |> Enum.filter(fn event -> Map.get(event, "group_id") == gid end)
    |> Enum.sort_by(&Map.get(&1, "created_at", 0), :desc)
    |> Enum.take(limit)
  end

  @spec add_message(binary(), map()) :: {:ok, map()} | {:error, term(), term()}
  def add_message(gid, message) when is_binary(gid) and is_map(message) do
    ensure()

    with {:ok, _group} <- get_group(gid) do
      key = Map.get(message, "message_id") || Map.get(message, "command_id")

      existing =
        if is_binary(key) and key != "" do
          Enum.find(list_messages(gid), fn item ->
            Map.get(item, "message_id") == key or Map.get(item, "command_id") == key
          end)
        end

      if existing do
        {:ok, existing}
      else
        stored =
          message
          |> Map.put(
            "id",
            Map.get(message, "id") || "m_" <> Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false)
          )
          |> Map.put("group_id", gid)
          |> Map.put_new("created_at", System.system_time(:millisecond))

        :ets.insert(@mt, {stored["id"], stored})
        emit_group_event(gid, "cross_host_message_added", Map.take(stored, ["id", "message_id", "kind", "created_at"]))

        {:ok, stored}
      end
    end
  end

  def add_message(_, _), do: {:error, "bad_request", "共享消息格式无效"}

  @spec add_activity(binary(), map()) :: {:ok, map()} | {:error, term(), term()}
  def add_activity(gid, event) when is_binary(gid) and is_map(event) do
    ensure()

    with {:ok, _group} <- get_group(gid) do
      stored =
        event
        |> Map.put(
          "id",
          Map.get(event, "id") || "a_" <> Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false)
        )
        |> Map.put("group_id", gid)
        |> Map.put_new("created_at", System.system_time(:millisecond))

      :ets.insert(@at, {stored["id"], stored})
      emit_group_event(gid, "cross_host_activity_added", Map.take(stored, ["id", "event", "created_at"]))

      {:ok, stored}
    end
  end

  def add_activity(_, _), do: {:error, "bad_request", "共享活动格式无效"}

  @spec add_knowledge(binary(), map()) :: {:ok, map()} | {:error, term(), term()}
  def add_knowledge(gid, entry) when is_binary(gid) and is_map(entry) do
    ensure()

    case get_group(gid) do
      {:error, code, message} ->
        {:error, code, message}

      {:ok, _group} ->
        command_id = Map.get(entry, "command_id")
        existing = Enum.find(list_knowledge(gid), &(command_id && Map.get(&1, "command_id") == command_id))

        if existing do
          {:ok, existing}
        else
          stored =
            entry
            |> Map.put(
              "id",
              Map.get(entry, "id") || "k_" <> Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false)
            )
            |> Map.put("group_id", gid)
            |> Map.put_new("created_at", System.system_time(:millisecond))

          :ets.insert(@kt, {stored["id"], stored})
          {:ok, stored}
        end
    end
  end

  def add_knowledge(_, _), do: {:error, "bad_request", "知识条目格式无效"}
  @doc "根据设备 ID 找到所属群和设备记录；令牌只在鉴权函数中使用。"
  @spec find_device(String.t()) :: {:ok, map(), map()} | {:error, String.t(), String.t()}
  def find_device(device_id) when is_binary(device_id) and device_id != "" do
    ensure()

    case Enum.find(:ets.tab2list(@gt), fn {_id, group} ->
           is_map(get_in(group, ["devices", device_id]))
         end) do
      {_group_id, group} -> {:ok, group, Map.put(get_in(group, ["devices", device_id]), "id", device_id)}
      nil -> {:error, "not_found", "设备不存在"}
    end
  end

  def find_device(_), do: {:error, "not_found", "设备不存在"}

  @doc "将任务以设备幂等键写入 Hub 待投递箱；确认前保留记录以支持重连。"
  @spec enqueue_delivery(String.t(), String.t(), map()) :: {:ok, map()} | {:error, String.t(), String.t()}
  def enqueue_delivery(group_id, device_id, task)
      when is_binary(group_id) and is_binary(device_id) and is_map(task) do
    ensure()
    task_id = Map.get(task, "task_id") || Map.get(task, "id")
    attempt = Map.get(task, "attempt") || Map.get(task, "attempts", 0)

    with true <- is_binary(task_id) and task_id != "",
         {:ok, group, _device} <- find_device(device_id),
         true <- group["id"] == group_id do
      existing =
        :ets.tab2list(@ot)
        |> Enum.map(fn {_id, entry} -> entry end)
        |> Enum.find(fn entry ->
          entry["device_id"] == device_id and entry["task_id"] == task_id and
            entry["attempt"] == attempt and entry["status"] == "pending"
        end)

      cond do
        existing ->
          {:ok, existing}

        :ets.info(@ot, :size) >= @max_outbox ->
          {:error, "queue_full", "远端任务待投递箱已满"}

        true ->
          entry = %{
            "id" => "delivery_" <> Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false),
            "group_id" => group_id,
            "device_id" => device_id,
            "task_id" => task_id,
            "attempt" => attempt,
            "task" => task,
            "status" => "pending",
            "created_at" => System.system_time(:millisecond)
          }

          :ets.insert(@ot, {entry["id"], entry})
          {:ok, entry}
      end
    else
      false -> {:error, "bad_request", "远端任务缺少有效 task_id"}
      {:error, _, _} = error -> error
    end
  end

  def enqueue_delivery(_, _, _), do: {:error, "bad_request", "远端投递参数无效"}

  @doc "返回设备尚未确认的任务，顺序稳定且批量有上限。"
  @spec pending_deliveries(String.t(), non_neg_integer()) :: [map()]
  def pending_deliveries(device_id, limit \\ 32)

  def pending_deliveries(device_id, limit) when is_binary(device_id) and is_integer(limit) do
    ensure()
    limit = max(1, min(limit, @max_delivery_batch))

    :ets.tab2list(@ot)
    |> Enum.map(fn {_id, entry} -> entry end)
    |> Enum.filter(&(&1["device_id"] == device_id and &1["status"] == "pending"))
    |> Enum.sort_by(&{Map.get(&1, "created_at", 0), Map.get(&1, "id", "")})
    |> Enum.take(limit)
  end

  def pending_deliveries(_, _), do: []

  @doc "按设备确认投递；重复确认返回原记录，避免重连导致副作用重复。"
  @spec ack_delivery(String.t(), String.t()) :: {:ok, map()} | {:error, String.t(), String.t()}
  def ack_delivery(device_id, delivery_id) when is_binary(device_id) and is_binary(delivery_id) do
    ensure()

    case :ets.lookup(@ot, delivery_id) do
      [{_, entry}] ->
        if entry["device_id"] == device_id do
          if entry["status"] == "acked" do
            {:ok, entry}
          else
            next = Map.merge(entry, %{"status" => "acked", "acked_at" => System.system_time(:millisecond)})
            :ets.insert(@ot, {delivery_id, next})
            {:ok, next}
          end
        else
          {:error, "forbidden", "投递不属于该设备"}
        end

      [] ->
        {:error, "not_found", "投递不存在"}
    end
  end

  def ack_delivery(_, _), do: {:error, "bad_request", "投递确认参数无效"}

  @doc "读取设备投递记录，供确认前更新任务状态。"
  def delivery(delivery_id) when is_binary(delivery_id) do
    ensure()

    case :ets.lookup(@ot, delivery_id) do
      [{_, entry}] -> {:ok, entry}
      [] -> {:error, "not_found", "投递不存在"}
    end
  end

  def delivery(_), do: {:error, "not_found", "投递不存在"}
  @doc "取消任务时撤回其尚未确认的投递；已确认的不受影响，返回撤回条数。"
  @spec drop_deliveries_for_task(String.t()) :: {:ok, non_neg_integer()}
  def drop_deliveries_for_task(task_id) when is_binary(task_id) and task_id != "" do
    ensure()

    dropped =
      :ets.tab2list(@ot)
      |> Enum.filter(fn {_id, entry} -> entry["task_id"] == task_id and entry["status"] == "pending" end)
      |> Enum.map(fn {id, _} -> :ets.delete(@ot, id) end)
      |> length()

    {:ok, dropped}
  end

  def drop_deliveries_for_task(_), do: {:ok, 0}

  @doc "缓存远端 Hub 已授权的共享资源；Worker 只写入经过 Bridge 快照脱敏的数据。"
  def put_remote_resource(group_id, resource, value)
      when is_binary(group_id) and is_binary(resource) and is_map(value) do
    ensure()
    :ets.insert(@rt, {{group_id, resource}, value})
    :ok
  end

  def put_remote_resource(_, _, _), do: {:error, "bad_request", "远端共享资源格式无效"}

  @doc "读取 Worker 最近一次成功同步的共享资源。"
  def remote_resource(group_id, resource) when is_binary(group_id) and is_binary(resource) do
    ensure()

    case :ets.lookup(@rt, {group_id, resource}) do
      [{{_, _}, value}] -> {:ok, value}
      [] -> :error
    end
  end

  def remote_resource(_, _), do: :error

  @doc "写入一份 Hub 快照，单个资源失败不会污染其他资源。"
  def put_remote_snapshot(group_id, snapshot) when is_binary(group_id) and is_map(snapshot) do
    Enum.each(~w(board messages activity knowledge capabilities history), fn resource ->
      case Map.get(snapshot, resource) do
        value when is_map(value) ->
          put_remote_resource(group_id, resource, value)

        value when is_list(value) ->
          key = if resource == "history", do: "sessions", else: "items"
          put_remote_resource(group_id, resource, Map.put(%{}, key, value))

        _ ->
          :ok
      end
    end)

    :ok
  end

  def put_remote_snapshot(_, _), do: {:error, "bad_request", "远端共享快照格式无效"}

  @st :xh_sessions
  @spec clear() :: :ok
  def clear do
    ensure()
    :ets.delete_all_objects(@gt)
    :ets.delete_all_objects(@tt)
    :ets.delete_all_objects(@st)
    :ets.delete_all_objects(@kt)
    :ets.delete_all_objects(@mt)
    :ets.delete_all_objects(@at)
    :ets.delete_all_objects(@ot)
    :ets.delete_all_objects(@rt)

    :ok
  end

  @spec bind_session(map()) :: :ok
  def bind_session(b) when is_map(b) do
    ensure()
    :ets.insert(@st, {Map.get(b, "session_id"), b})
    :ok
  end

  @spec sessions_for_group(binary()) :: [map()]
  def sessions_for_group(gid) when is_binary(gid) do
    ensure()
    :ets.tab2list(@st) |> Enum.map(fn {_, b} -> b end) |> Enum.filter(fn b -> Map.get(b, "group_id") == gid end)
  end

  @spec unbind_session(binary()) :: :ok
  def unbind_session(sid) when is_binary(sid) do
    ensure()
    :ets.delete(@st, sid)
    :ok
  end

  @online_window_ms 90_000

  @doc "设备连接状态（纯函数，可测试）：paused/online/offline + 可操作的断线提示。"
  @spec device_status(map(), list(), non_neg_integer(), integer()) :: map()
  def device_status(device, tasks, pending, now_ms)
      when is_map(device) and is_list(tasks) and is_integer(pending) and is_integer(now_ms) do
    paused = Map.get(device, "paused", false) == true
    remote = Map.get(device, "remote", false) == true or Map.get(device, "bridge", false) == true
    last_seen = Map.get(device, "last_seen")
    age_ms = if is_integer(last_seen), do: max(0, now_ms - last_seen), else: nil
    online = not paused and (is_nil(last_seen) or (is_integer(last_seen) and now_ms - last_seen < @online_window_ms))
    active_tasks = Enum.count(tasks, fn t -> Map.get(t, "status") in ["queued", "running", "waiting_input"] end)
    state = if paused, do: "paused", else: if(online, do: "online", else: "offline")

    %{
      "state" => state,
      "remote" => remote,
      "paused" => paused,
      "age_ms" => age_ms,
      "age_text" => age_text(age_ms),
      "active_tasks" => active_tasks,
      "pending" => pending,
      "hint" => status_hint(state, remote, age_ms, is_nil(last_seen), active_tasks, pending)
    }
  end

  @doc "整群设备状态（供 xgroup.device.status 用）。"
  @spec group_device_statuses(binary(), integer()) :: [map()]
  def group_device_statuses(gid, now_ms) when is_binary(gid) and is_integer(now_ms) do
    ensure()

    case get_group(gid) do
      {:ok, group} ->
        devices = Map.get(group, "devices", %{})
        tasks = list_tasks(gid)

        devices
        |> Enum.map(fn {id, device} ->
          assigned = Enum.filter(tasks, fn t -> Map.get(t, "assigned_device_id") == id end)
          pending = length(pending_deliveries(id))

          device_status(device, assigned, pending, now_ms)
          |> Map.merge(%{"id" => id, "display" => Map.get(device, "display", id)})
        end)
        |> Enum.sort_by(&Map.get(&1, "id"))

      _ ->
        []
    end
  end

  defp age_text(nil), do: "从未上报"
  defp age_text(ms) when ms < 5_000, do: "刚刚活跃"
  defp age_text(ms) when ms < 60_000, do: Integer.to_string(div(ms, 1000)) <> " 秒前活跃"
  defp age_text(ms), do: Integer.to_string(div(ms, 60_000)) <> " 分钟前活跃"

  defp status_hint("paused", _remote, _age, _never, active, _pending) do
    extra = if active > 0, do: "，" <> Integer.to_string(active) <> " 个任务继续执行", else: ""
    "已暂停接收新任务" <> extra <> "；点恢复可继续接单"
  end

  defp status_hint("online", true, _age, true, _active, pending) do
    extra = if pending > 0, do: "；" <> Integer.to_string(pending) <> " 个任务待投递，启动轮询后自动继续", else: ""
    "远端 Worker 已加入，等待首次心跳" <> extra
  end

  defp status_hint("online", true, _age, _never, _active, pending) do
    extra = if pending > 0, do: "，" <> Integer.to_string(pending) <> " 个任务待投递", else: ""
    "远端 Worker 连接正常" <> extra
  end

  defp status_hint("online", false, _age, _never, _active, _pending), do: "本机设备在线"

  defp status_hint("offline", _remote, _age, _never, _active, pending) do
    extra = if pending > 0, do: "（当前 " <> Integer.to_string(pending) <> " 个待投递）", else: ""
    "心跳超时：检查 Worker 进程、到 Hub 的网络、Hub 地址/指纹是否变化；任务保留待投递，重连后自动继续" <> extra
  end

  @spec unbind_group(binary()) :: :ok
  def unbind_group(gid) when is_binary(gid) do
    ensure()
    sessions_for_group(gid) |> Enum.each(fn b -> :ets.delete(@st, Map.get(b, "session_id")) end)
    :ok
  end

  defp ensure do
    ensure_owned(@gt)
    ensure_owned(@mt)
    ensure_owned(@at)

    ensure_owned(@tt)
    ensure_owned(@st)
    ensure_owned(@kt)
    ensure_owned(@ot)
    ensure_owned(@rt)
    :ok
  end

  @doc "建表并指定常驻继承者：短命请求进程退出后表不丢。"
  @spec ensure_owned(atom()) :: :ok
  def ensure_owned(table) when is_atom(table) do
    if :ets.whereis(table) == :undefined do
      try do
        :ets.new(table, [
          {:heir, heir_pid()},
          :named_table,
          :public,
          :set,
          {:read_concurrency, true},
          {:write_concurrency, true}
        ])
      rescue
        ArgumentError -> :ok
      end
    end

    :ok
  end

  defp heir_pid do
    case Process.whereis(:xh_store_heir) do
      nil ->
        pid =
          spawn(fn ->
            receive do
            after
              :infinity -> :ok
            end
          end)

        try do
          true = Process.register(pid, :xh_store_heir)
          pid
        rescue
          ArgumentError ->
            Process.exit(pid, :kill)
            heir_pid()
        end

      pid when is_pid(pid) ->
        if Process.alive?(pid), do: pid, else: heir_pid()
    end
  end

  @spec delete_group(binary()) :: :ok
  def delete_group(gid) when is_binary(gid) do
    ensure()
    :ets.delete(@gt, gid)

    :ets.tab2list(@tt)
    |> Enum.each(fn {tid, task} -> if Map.get(task, "group_id") == gid, do: :ets.delete(@tt, tid) end)

    sessions_for_group(gid) |> Enum.each(fn binding -> :ets.delete(@st, Map.get(binding, "session_id")) end)
    list_knowledge(gid) |> Enum.each(fn entry -> :ets.delete(@kt, Map.get(entry, "id")) end)

    :ets.tab2list(@mt)
    |> Enum.each(fn {mid, message} -> if Map.get(message, "group_id") == gid, do: :ets.delete(@mt, mid) end)

    :ets.tab2list(@at)
    |> Enum.each(fn {aid, event} -> if Map.get(event, "group_id") == gid, do: :ets.delete(@at, aid) end)

    :ets.tab2list(@ot)
    |> Enum.each(fn {delivery_id, entry} -> if Map.get(entry, "group_id") == gid, do: :ets.delete(@ot, delivery_id) end)

    :ets.tab2list(@rt)
    |> Enum.each(fn {{group_id, resource}, _value} ->
      if group_id == gid, do: :ets.delete(@rt, {group_id, resource})
    end)

    :ok
  end

  defp emit_group_event(gid, topic, payload) do
    session_ids = sessions_for_group(gid) |> Enum.map(&Map.get(&1, "session_id")) |> Enum.filter(&is_binary/1)

    if session_ids != [] and Process.whereis(Newbee.Bus) do
      Newbee.Bus.emit(:collab_event, %{
        "event_id" => "xh:" <> Integer.to_string(:erlang.unique_integer([:positive])),
        "group_id" => gid,
        "topic" => topic,
        "payload" => payload,
        "session_ids" => session_ids
      })
    end

    :ok
  end
end
