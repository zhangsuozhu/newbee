defmodule Newbee.Collaboration.CrossHost.Bridge do
  @moduledoc "Application-layer bridge for remote Workers. The Hub owns the device-scoped outbox and redacted snapshots; Transport owns TLS pinning."

  alias Newbee.Collaboration.CrossHost.{Auth, Join, Store}
  alias Newbee.Collaboration.SharedContext

  @max_poll 64
  @statuses ~w(accepted running done failed cancelled unknown waiting_input)

  @doc "Enroll a Worker after it has pinned the Hub certificate and verified the group password."
  def join(params) when is_map(params) do
    group_id = text(params, "group_id")
    fingerprint = text(params, "fingerprint")
    password = text(params, "password")
    display = limit_text(text(params, "display") || "worker", 128)

    with {:ok, group} <- Store.get_group(group_id),
         {:ok, joined_group, out} <-
           Join.join(group, %{
             "expected_fp" => group["server_fp"] || "",
             "presented_fp" => fingerprint,
             "password" => password,
             "display" => display
           }) do
      device = out["device"]
      device_id = device["id"]

      device_meta =
        device |> Map.drop(["plain"]) |> Map.merge(%{"bridge" => true, "remote" => true, "last_seen" => now()})

      joined_group = put_in(joined_group, ["devices", device_id], device_meta)
      :ok = Store.put_group(joined_group)

      {:ok,
       %{
         "protocol" => "xbridge.v1",
         "group" => Store.public_group(joined_group),
         "device" => Map.drop(device, ["token_hash"]),
         "caps" => out["caps"],
         "quota" => out["quota"]
       }}
    end
  end

  def join(_), do: {:error, "bad_request", "远端加入参数无效"}

  @doc "Poll a Hub outbox using the device credential; pending deliveries remain until acked."
  def poll(params) when is_map(params) do
    with {:ok, group, device} <- authenticate(params),
         {:ok, _group} <- touch(group, device["id"]),
         limit <- poll_limit(params["limit"]),
         :ok <- reclaim_queued(group["id"], device["id"]),
         deliveries <- Store.pending_deliveries(device["id"], limit),
         {:ok, snapshot} <- SharedContext.remote_snapshot(group["id"]) do
      {:ok,
       %{
         "protocol" => "xbridge.v1",
         "server_time" => now(),
         "deliveries" => Enum.map(deliveries, &public_delivery/1),
         "snapshot" => snapshot
       }}
    end
  end

  def poll(_), do: {:error, "bad_request", "远端轮询参数无效"}

  # Tasks deferred while a Worker was unreachable stay "queued" in Hub storage;
  # reclaim them into the outbox on the next poll so a reconnect resumes delivery.
  # Store.enqueue_delivery is idempotent per (device, task, attempt), so repeated
  # polls never duplicate pending entries.
  defp reclaim_queued(group_id, device_id) do
    group_id
    |> Store.list_tasks()
    |> Enum.filter(&(&1["status"] == "queued" and &1["assigned_device_id"] == device_id))
    |> Enum.take(64)
    |> Enum.each(fn task -> _ = enqueue(group_id, device_id, task) end)

    :ok
  end

  @doc "Ack a delivery and persist its observed task state; duplicate acks are harmless."
  def ack(params) when is_map(params) do
    with {:ok, group, device} <- authenticate(params),
         delivery_id when is_binary(delivery_id) <- text(params, "delivery_id"),
         {:ok, entry} <- Store.delivery(delivery_id),
         true <- entry["device_id"] == device["id"],
         {:ok, _acked} <- Store.ack_delivery(device["id"], delivery_id),
         status <- normalize_status(params["status"]),
         :ok <- update_task(group["id"], entry["task_id"], status, params["result"]) do
      {:ok, %{"acknowledged" => true, "delivery_id" => delivery_id, "status" => status}}
    else
      false -> {:error, "forbidden", "投递不属于该设备"}
      nil -> {:error, "bad_request", "缺少 delivery_id"}
      {:error, _, _} = error -> error
    end
  end

  def ack(_), do: {:error, "bad_request", "远端确认参数无效"}

  @doc "Return an authorized, redacted snapshot for a Worker reconnect."
  def sync(params) when is_map(params) do
    with {:ok, group, device} <- authenticate(params),
         {:ok, _group} <- touch(group, device["id"]),
         {:ok, snapshot} <- SharedContext.remote_snapshot(group["id"]) do
      {:ok, snapshot}
    end
  end

  def sync(_), do: {:error, "bad_request", "远端同步参数无效"}

  @doc "Update the device liveness marker without exposing device secrets."
  def heartbeat(params) when is_map(params) do
    with {:ok, group, device} <- authenticate(params),
         {:ok, _group} <- touch(group, device["id"]) do
      {:ok, %{"server_time" => now()}}
    end
  end

  def heartbeat(_), do: {:error, "bad_request", "远端心跳参数无效"}

  @doc "Queue a task for a remote device after the Hub scheduler selected it."
  def enqueue(group_id, device_id, task)
      when is_binary(group_id) and is_binary(device_id) and is_map(task) do
    with {:ok, group, device} <- Store.find_device(device_id),
         true <- group["id"] == group_id,
         false <- Map.get(device, "paused", false) == true,
         {:ok, _entry} <- Store.enqueue_delivery(group_id, device_id, task) do
      :ok
    else
      true -> {:error, "device_paused", "设备已暂停接收新任务"}
      false -> {:error, "not_found", "设备不属于该协作群"}
      {:error, _, _} = error -> error
    end
  end

  def enqueue(_, _, _), do: {:error, "bad_request", "远端任务投递参数无效"}

  defp authenticate(params) do
    device_id = text(params, "device_id")
    token = text(params, "token")

    with {:ok, group, device} <- Store.find_device(device_id),
         true <- Auth.verify_device(group, device_id, token) do
      {:ok, group, device}
    else
      false -> {:error, "unauthorized", "设备凭据无效或已暂停"}
      {:error, _, _} = error -> error
    end
  end

  defp touch(group, device_id) do
    group = Auth.touch_device(group, device_id)
    :ok = Store.put_group(group)
    {:ok, group}
  end

  defp update_task(group_id, task_id, status, result) do
    case Enum.find(Store.list_tasks(group_id), &(&1["id"] == task_id)) do
      nil ->
        {:error, "not_found", "任务不存在"}

      task ->
        next = Map.put(task, "status", status)
        next = if is_nil(result), do: next, else: Map.put(next, "result", SharedContext.sanitize(result))
        :ok = Store.put_task(next)

        _ =
          Store.add_activity(group_id, %{
            "event" => "task_remote_ack",
            "task_id" => task_id,
            "status" => status,
            "assigned_device_id" => task["assigned_device_id"]
          })

        :ok
    end
  end

  defp public_delivery(entry) do
    %{
      "delivery_id" => entry["id"],
      "task_id" => entry["task_id"],
      "attempt" => entry["attempt"],
      "created_at" => entry["created_at"],
      "task" => Map.put(entry["task"] || %{}, "status", "queued")
    }
  end

  defp normalize_status(status) when status in @statuses, do: status
  defp normalize_status(_), do: "unknown"

  defp poll_limit(limit) when is_integer(limit), do: max(1, min(limit, @max_poll))
  defp poll_limit(_), do: @max_poll

  defp text(map, key) do
    case Map.get(map, key) do
      value when is_binary(value) -> String.trim(value)
      _ -> nil
    end
  end

  defp limit_text(value, max) when is_binary(value), do: String.slice(value, 0, max)
  defp limit_text(_, _), do: "worker"

  defp now, do: System.system_time(:millisecond)
end
