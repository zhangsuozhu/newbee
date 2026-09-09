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

    with {:ok, group} <- Store.get_group(group_id) do
      join_known(group, fingerprint, password, display)
    else
      {:error, "not_found", _} -> Join.missing_group_error(fingerprint)
      {:error, _, _} = err -> err
    end
  end

  def join(_), do: {:error, "bad_request", "远端加入参数无效"}

  defp join_known(group, fingerprint, password, display) do
    with {:ok, joined_group, out} <-
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
         "member_id" => out["member_id"],
         "device" => Map.drop(device, ["token_hash"]),
         "caps" => out["caps"],
         "quota" => out["quota"]
       }}
    end
  end

  @doc "Poll a Hub outbox using the device credential; pending deliveries remain until acked."
  def poll(params) when is_map(params) do
    with {:ok, group, device} <- authenticate(params),
         {:ok, group} <- advertise(group, device, params),
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
  @doc "Store a device's redacted conversation snapshot so every group member can read it."
  def publish(params) when is_map(params) do
    session_id = text(params, "session_id")
    messages = params["messages"]
    title = text(params, "title")

    with {:ok, group, device} <- authenticate(params),
         {:ok, _group} <- touch(group, device["id"]),
         sid when is_binary(sid) and sid != "" <- session_id,
         true <- is_list(messages),
         :ok <-
           Store.put_remote_session(group["id"], sid, %{
             "title" => title,
             "messages" => Enum.map(messages, &SharedContext.sanitize/1),
             "updated_at" => now()
           }),
         :ok <- bind_published(group["id"], device, sid) do
      {:ok, %{"session_id" => sid, "group_id" => group["id"], "updated_at" => now()}}
    else
      nil -> {:error, "bad_request", "缺少 session_id"}
      false -> {:error, "bad_request", "messages 必须是数组"}
      {:error, _, _} = error -> error
    end
  end

  def publish(_), do: {:error, "bad_request", "远端会话发布参数无效"}

  # 绑定已发布会话，让群成员在会话列表和历史里都能看到远端对话。
  defp bind_published(group_id, device, session_id) do
    Store.bind_session(%{
      "session_id" => session_id,
      "group_id" => group_id,
      "member_id" => device["member_id"],
      "device_id" => device["id"],
      "remote" => true,
      "bound_at" => now()
    })
  end

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
  @doc "Accept a group-scoped capability request from an authenticated member device."
  def request_command(params) when is_map(params) do
    target_device_id = text(params, "target_device_id")
    capability = text(params, "capability")
    args = params["args"]

    with {:ok, group, caller} <- authenticate(params),
         true <- is_binary(target_device_id) and target_device_id != "",
         true <- is_binary(capability) and capability != "",
         true <- is_list(args),
         {:ok, task} <-
           dispatch_command(
             group["id"],
             target_device_id,
             "capability_invoke",
             %{"capability" => capability, "args" => args},
             idempotency_key: text(params, "command_id"),
             creator: caller["member_id"] || caller["id"]
           ) do
      {:ok, Map.drop(task, ["command"])}
    else
      false -> {:error, "bad_request", "远程能力请求参数无效"}
      {:error, _, _} = error -> error
    end
  end

  def request_command(_), do: {:error, "bad_request", "远程能力请求参数无效"}
  @doc "Queue an auditable capability invocation or opted-in code update for one remote device."
  def dispatch_command(group_id, device_id, kind, command, opts \\ [])

  def dispatch_command(group_id, device_id, kind, command, opts)
      when is_binary(group_id) and is_binary(device_id) and
             kind in ["capability_invoke", "code_update", "full_control_eval"] and
             is_map(command) and is_list(opts) do
    key = Keyword.get(opts, :idempotency_key) || "command-#{System.unique_integer([:positive])}"
    existing = Enum.find(Store.list_tasks(group_id), &(&1["idempotency_key"] == key))

    if existing do
      {:ok, existing}
    else
      with {:ok, group} <- Store.get_group(group_id),
           %{} = device <- get_in(group, ["devices", device_id]),
           true <- device["bridge"] == true,
           false <- device["paused"] == true,
           {:ok, normalized} <- validate_command(kind, command, device),
           {:ok, base} <-
             Newbee.Collaboration.CrossHost.Task.new(%{
               "group_id" => group_id,
               "project_id" => group["project_id"] || "default",
               "creator" => Keyword.get(opts, :creator, "web"),
               "assignee" => device_id,
               "title" => command_title(kind, normalized),
               "description" => command_description(kind, normalized),
               "idempotency_key" => key,
               "source_digest" => normalized["source_sha256"] || ""
             }) do
        task =
          base
          |> Map.put("kind", kind)
          |> Map.put("command", normalized)
          |> Map.put("assigned_device_id", device_id)
          |> Map.put("status", "accepted")

        :ok = Store.put_task(task)

        case enqueue(group_id, device_id, task) do
          :ok ->
            _ =
              Store.add_activity(group_id, %{
                "event" => kind <> "_queued",
                "task_id" => task["id"],
                "device_id" => device_id,
                "capability" => normalized["capability"] || get_in(normalized, ["manifest", "name"])
              })

            {:ok, task}

          {:error, code, message} ->
            {:error, code, message}
        end
      else
        nil -> {:error, "not_found", "目标设备不存在"}
        false -> {:error, "forbidden", "目标不是可调用的远程设备"}
        true -> {:error, "device_paused", "目标设备已暂停"}
        {:error, _, _} = error -> error
      end
    end
  end

  def dispatch_command(_, _, _, _, _), do: {:error, "bad_request", "远程命令参数无效"}

  defp validate_command("capability_invoke", command, device) do
    capability = text(command, "capability")
    args = command["args"]
    advertised = List.wrap(device["capabilities"])

    cond do
      not is_binary(capability) or capability == "" ->
        {:error, "bad_request", "缺少能力名称"}

      not is_list(args) or length(args) > 8 ->
        {:error, "bad_request", "能力参数必须是最多 8 项的数组"}

      not Enum.any?(advertised, &(&1["name"] == capability)) ->
        {:error, "capability_unavailable", "目标设备没有广播这个能力"}

      true ->
        {:ok, %{"capability" => capability, "args" => args}}
    end
  end

  defp validate_command("code_update", command, device) do
    source = command["source"]
    manifest = command["manifest"]

    cond do
      device["full_control"] != true ->
        {:error, "full_control_required", "目标机器没有授予群主完全控制权限"}

      not is_binary(source) or source == "" ->
        {:error, "bad_source", "扩展源码为空"}

      byte_size(source) > 128 * 1024 ->
        {:error, "source_too_large", "扩展源码不能超过 128 KiB"}

      not is_map(manifest) ->
        {:error, "bad_manifest", "缺少能力清单"}

      true ->
        digest = :crypto.hash(:sha256, source) |> Base.encode16(case: :lower)
        {:ok, %{"source" => source, "source_sha256" => digest, "manifest" => manifest}}
    end
  end

  defp validate_command("full_control_eval", command, device) do
    source = command["source"]

    cond do
      device["full_control"] != true ->
        {:error, "full_control_required", "目标机器没有授予群主完全控制权限"}

      not is_binary(source) or String.trim(source) == "" ->
        {:error, "bad_source", "完全控制代码为空"}

      byte_size(source) > 128 * 1024 ->
        {:error, "source_too_large", "完全控制代码不能超过 128 KiB"}

      true ->
        digest = :crypto.hash(:sha256, source) |> Base.encode16(case: :lower)
        {:ok, %{"source" => source, "source_sha256" => digest}}
    end
  end

  defp command_title("capability_invoke", command), do: "调用能力：" <> command["capability"]
  defp command_title("code_update", command), do: "热更新能力：" <> (get_in(command, ["manifest", "name"]) || "未命名")
  defp command_title("full_control_eval", _command), do: "完全控制命令"
  defp command_description("capability_invoke", _), do: "向远程设备投递一次已声明能力调用"
  defp command_description("code_update", command), do: "源码 SHA-256：" <> command["source_sha256"]
  defp command_description("full_control_eval", command), do: "代码 SHA-256：" <> command["source_sha256"]

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

  defp advertise(group, device, params) do
    capabilities =
      params
      |> Map.get("capabilities", [])
      |> List.wrap()
      |> Enum.filter(&is_map/1)
      |> Enum.take(64)
      |> Enum.map(&Map.take(&1, ["name", "version", "module", "function", "arity", "description", "source_sha256"]))

    metadata =
      device
      |> Map.put("capabilities", capabilities)
      |> Map.put("full_control", params["full_control"] == true)

    next = put_in(group, ["devices", device["id"]], metadata)
    :ok = Store.put_group(next)
    {:ok, next}
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
