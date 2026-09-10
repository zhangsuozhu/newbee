defmodule Newbee.Collaboration.CrossHost.Worker do
  @moduledoc "Outbound Worker connector. It never listens for Hub connections; it polls, executes through a local session, and acknowledges only terminal results."

  use GenServer

  alias Newbee.Collaboration.CrossHost.{Extensions, Store, Transport}

  require Logger

  @default_poll_ms 2_000
  @default_timeout 10_000
  @terminal_statuses ~w(done failed cancelled unknown waiting_input)

  @doc "Enroll a Worker with a pinned Hub, returning the one-time device credential."
  def join(base_url, group_id, password, fingerprint, display, opts \\ []) do
    opts = Keyword.put(opts, :fingerprint, fingerprint)

    with {:ok, enrollment} <- Transport.join(base_url, group_id, password, fingerprint, display, opts) do
      {:ok, enrollment}
    end
  end

  @doc "Start an outbound Worker connector. Required opts: base_url, group_id, device_id, device_token, fingerprint."
  def start_link(opts) when is_list(opts) do
    name_opts = if Keyword.get(opts, :name), do: [name: Keyword.fetch!(opts, :name)], else: []
    GenServer.start_link(__MODULE__, opts, name_opts)
  end

  @doc "Connect a just-enrolled Worker to a local session and begin polling."
  def connect(enrollment, base_url, opts \\ []) when is_map(enrollment) and is_binary(base_url) do
    device = enrollment["device"] || %{}
    group = enrollment["group"] || %{}

    start_link(
      Keyword.merge(opts,
        base_url: base_url,
        group_id: group["id"] || Keyword.get(opts, :group_id),
        device_id: device["id"],
        device_token: device["plain"],
        fingerprint: Keyword.get(opts, :fingerprint),
        session_id: Keyword.get(opts, :session_id)
      )
    )
  end

  @doc "Return connection state without exposing the device token."
  def status(pid), do: GenServer.call(pid, :status, 5_000)

  @doc "Stop a Worker connector."
  def stop(pid), do: GenServer.stop(pid, :normal)

  @impl true
  def init(opts) do
    with {:ok, config} <- validate_config(opts),
         {:ok, session_pid, session_id} <- ensure_session(Keyword.get(opts, :session_id), opts) do
      Process.send(self(), :poll, [])

      {:ok,
       %{
         base_url: config.base_url,
         group_id: config.group_id,
         device_id: config.device_id,
         device_token: config.device_token,
         fingerprint: config.fingerprint,
         allow_insecure: config.allow_insecure,
         allow_full_control: config.allow_full_control,
         session_id: session_id,
         session_pid: session_pid,
         poll_ms: config.poll_ms,
         request_timeout: config.request_timeout,
         connected: false,
         last_success_at: nil,
         last_error: nil,
         consecutive_failures: 0,
         inflight: %{},
         seen_deliveries: MapSet.new(),
         command_results: %{},
         last_publish_at: 0,
         published_digest: nil
       }}
    else
      {:error, reason} -> {:stop, {:invalid_worker_config, reason}}
    end
  end

  @impl true
  def handle_call(:status, _from, state) do
    {:reply,
     %{
       connected: state.connected,
       group_id: state.group_id,
       device_id: state.device_id,
       session_id: state.session_id,
       last_success_at: state.last_success_at,
       last_error: state.last_error,
       consecutive_failures: state.consecutive_failures,
       inflight: map_size(state.inflight)
     }, state}
  end

  @impl true
  def handle_info(:poll, state) do
    case poll_once(state) do
      {:ok, next} ->
        Process.send_after(self(), :poll, next.poll_ms)
        {:noreply, next}

      {:error, code, message, next} ->
        delay = backoff(next)
        Process.send_after(self(), :poll, delay)
        {:noreply, %{next | connected: false, last_error: %{code: code, message: message}}}
    end
  end

  defp poll_once(state) do
    opts = transport_opts(state)

    poll_payload = %{
      "deviceId" => state.device_id,
      "limit" => 64,
      "capabilities" => Extensions.manifests(),
      "fullControl" => state.allow_full_control
    }

    case Transport.rpc(state.base_url, "xgroup.bridge.poll", poll_payload, opts) do
      {:ok, payload} when is_map(payload) ->
        state = %{state | connected: true, last_success_at: now(), last_error: nil, consecutive_failures: 0}
        state = apply_snapshot(state, payload["snapshot"])
        Newbee.Collaboration.Chat.Runner.enqueue(payload["chat_jobs"] || [], {state.base_url, state.device_id, opts})
        state = flush_terminal(state)
        state = process_deliveries(state, List.wrap(payload["deliveries"]))
        state = maybe_publish_history(state)
        {:ok, state}
        {:ok, state}

      {:error, code, message} ->
        {:error, code, message, %{state | consecutive_failures: state.consecutive_failures + 1}}
    end
  end

  defp process_deliveries(state, deliveries) do
    Enum.reduce(deliveries, state, fn delivery, acc ->
      process_delivery(acc, delivery)
    end)
  end

  defp process_delivery(state, %{"delivery_id" => delivery_id, "task" => %{"kind" => kind} = task})
       when kind in ["capability_invoke", "code_update", "full_control_eval"] and is_binary(delivery_id) do
    {status, result, state} =
      case Map.fetch(state.command_results, delivery_id) do
        {:ok, {status, result}} ->
          {status, result, state}

        :error ->
          {status, result} = execute_command(task, state)
          next_results = state.command_results |> Map.put(delivery_id, {status, result}) |> trim_command_results()
          {status, result, %{state | command_results: next_results}}
      end

    _ = ack(state, delivery_id, status, result)
    state
  end

  defp process_delivery(state, %{"delivery_id" => delivery_id, "task" => task})
       when is_binary(delivery_id) and is_map(task) do
    task_id = task["task_id"] || task["id"]

    task =
      task
      |> Map.put("delivery_id", delivery_id)
      |> Map.put("task_id", task_id)
      |> Map.put("group_id", state.group_id)
      |> Map.put("source", "cross_host")
      |> Map.put("assigned_session_id", state.session_id)
      |> Map.put("assigned_device_id", state.device_id)
      |> Map.put("status", "queued")

    if is_binary(task_id) and not MapSet.member?(state.seen_deliveries, delivery_id) do
      Logger.info("cross_host delivery received",
        delivery_id: delivery_id,
        task_id: task_id,
        device_id: state.device_id
      )

      merge_local_task(task)

      %{
        state
        | seen_deliveries: MapSet.put(state.seen_deliveries, delivery_id),
          inflight: Map.put(state.inflight, delivery_id, task_id)
      }
    else
      state
    end
  end

  defp process_delivery(state, _), do: state

  defp execute_command(%{"kind" => "capability_invoke", "command" => command}, _state) when is_map(command) do
    case Extensions.invoke(command["capability"], List.wrap(command["args"])) do
      {:ok, result} -> {"done", %{ok: true, value: result}}
      {:error, code, message} -> {"failed", %{ok: false, code: code, message: message}}
    end
  end

  defp execute_command(%{"kind" => "code_update", "command" => command}, state) when is_map(command) do
    case Extensions.install_remote(
           command["source"],
           command["manifest"],
           command["source_sha256"],
           state.allow_full_control
         ) do
      {:ok, manifest} -> {"done", %{ok: true, capability: manifest}}
      {:error, code, message} -> {"failed", %{ok: false, code: code, message: message}}
    end
  end

  defp execute_command(%{"kind" => "full_control_eval", "command" => command}, state) when is_map(command) do
    if state.allow_full_control do
      task =
        Task.async(fn ->
          try do
            {value, _binding} = Code.eval_string(command["source"], [], file: "remote_full_control.exs")
            {:ok, inspect(value, limit: 100, printable_limit: 32_000)}
          rescue
            error -> {:error, Exception.format(:error, error, __STACKTRACE__) |> String.slice(0, 32_000)}
          catch
            kind, reason -> {:error, "#{kind}: #{inspect(reason)}"}
          end
        end)

      case Task.yield(task, 60_000) || Task.shutdown(task, :brutal_kill) do
        {:ok, {:ok, value}} -> {"done", %{ok: true, value: value}}
        {:ok, {:error, message}} -> {"failed", %{ok: false, code: "full_control_failed", message: message}}
        nil -> {"failed", %{ok: false, code: "full_control_timeout", message: "完全控制命令执行超过 60 秒"}}
      end
    else
      {"failed", %{ok: false, code: "full_control_required", message: "本机没有授予群主完全控制权限"}}
    end
  end

  defp execute_command(_, _state), do: {"failed", %{ok: false, code: "bad_command", message: "远程命令格式无效"}}

  defp trim_command_results(results) when map_size(results) <= 256, do: results
  defp trim_command_results(results), do: results |> Enum.take(-256) |> Map.new()

  defp flush_terminal(state) do
    Enum.reduce(state.inflight, state, fn {delivery_id, task_id}, acc ->
      case local_task(acc.group_id, task_id) do
        %{"status" => status} = task when status in @terminal_statuses ->
          result = Map.get(task, "result")

          case ack(acc, delivery_id, status, result) do
            :ok ->
              %{
                acc
                | inflight: Map.delete(acc.inflight, delivery_id),
                  seen_deliveries: MapSet.delete(acc.seen_deliveries, delivery_id)
              }

            _ ->
              acc
          end

        _ ->
          acc
      end
    end)
  end

  defp ack(state, delivery_id, status, result) do
    payload = %{"deviceId" => state.device_id, "deliveryId" => delivery_id, "status" => status}
    payload = if is_nil(result), do: payload, else: Map.put(payload, "result", result)

    case Transport.rpc(state.base_url, "xgroup.bridge.ack", payload, transport_opts(state)) do
      {:ok, _} ->
        Logger.info("cross_host delivery acked", delivery_id: delivery_id, status: status)
        :ok

      {:error, code, message} ->
        Logger.warning("cross_host delivery ack failed", delivery_id: delivery_id, code: code, message: message)
        :error

      _ ->
        :error
    end
  end

  @publish_interval_ms 5_000
  @publish_max_messages 200

  # 把本机会话最近的消息发布给 Hub，让群里其他机器也能看到这段对话。
  # 用摘要去重，避免每 2 秒轮询都重复上传；失败只记录，不影响任务投递。
  defp maybe_publish_history(state) do
    now_ms = now()

    if is_integer(state.last_publish_at) and now_ms - state.last_publish_at < @publish_interval_ms do
      state
    else
      state = %{state | last_publish_at: now_ms}

      case local_history(state.session_id) do
        [] ->
          state

        messages ->
          digest = :crypto.hash(:sha256, :erlang.term_to_binary(messages)) |> Base.encode16(case: :lower)

          if digest == state.published_digest do
            state
          else
            payload = %{
              "deviceId" => state.device_id,
              "sessionId" => state.session_id,
              "title" => session_title(state.session_id),
              "messages" => messages
            }

            case Transport.rpc(state.base_url, "xgroup.bridge.publish", payload, transport_opts(state)) do
              {:ok, _} ->
                %{state | published_digest: digest}

              {:error, code, message} ->
                Logger.debug("cross_host history publish failed",
                  code: code,
                  message: message,
                  device_id: state.device_id
                )

                state
            end
          end
      end
    end
  rescue
    _ -> state
  end

  defp local_history(session_id) when is_binary(session_id) do
    session_id
    |> Newbee.Session.open()
    |> Newbee.Session.messages()
    |> Enum.take(-@publish_max_messages)
    |> Enum.map(fn message ->
      %{
        "role" => to_string(Map.get(message, "role", "unknown")),
        "content" => publishable_content(Map.get(message, "content"))
      }
    end)
  rescue
    _ -> []
  end

  defp local_history(_), do: []

  defp publishable_content(value) when is_binary(value), do: String.slice(value, 0, 8_000)
  defp publishable_content(value) when is_nil(value), do: ""
  defp publishable_content(value), do: inspect(value, limit: 40, printable_limit: 4_000)

  defp session_title(session_id) do
    Newbee.Session.custom_title(session_id) || session_id
  rescue
    _ -> session_id
  end

  defp apply_snapshot(state, snapshot) when is_map(snapshot) do
    group = snapshot["group"] || %{}

    if is_binary(group["id"]) do
      :ok = merge_hub_group(group)

      :ok =
        Store.bind_session(%{
          "session_id" => state.session_id,
          "group_id" => state.group_id,
          "device_id" => state.device_id,
          "remote" => true
        })

      :ok = Store.put_remote_snapshot(state.group_id, snapshot)
      merge_snapshot_entities(state.group_id, snapshot)
    end

    state
  end

  defp apply_snapshot(state, _), do: state

  # Same-host Hub+Worker share ETS: never overwrite password hashes or device
  # token hashes with the redacted public snapshot.
  defp merge_hub_group(public_group) do
    existing =
      case Store.get_group(public_group["id"]) do
        {:ok, group} -> group
        _ -> %{}
      end

    existing_devices = Map.get(existing, "devices", %{})
    public_devices = Map.get(public_group, "devices", %{})

    devices =
      Map.merge(existing_devices, public_devices, fn _id, old, new ->
        Map.merge(new, Map.take(old, ["token_hash", "plain"]))
      end)

    merged =
      existing
      |> Map.merge(Map.drop(public_group, ["password", "devices"]))
      |> Map.put("devices", devices)
      |> Map.put("remote", true)
      |> Map.put_new("password", Map.get(existing, "password"))

    Store.put_group(merged)
  end

  defp merge_snapshot_entities(group_id, snapshot) do
    snapshot
    |> get_in(["board", "tasks"])
    |> List.wrap()
    |> Enum.each(fn task -> merge_local_task(Map.put(task, "group_id", group_id)) end)

    snapshot
    |> get_in(["messages", "messages"])
    |> List.wrap()
    |> Enum.each(fn message -> _ = Store.add_message(group_id, message) end)

    snapshot
    |> get_in(["activity", "activity"])
    |> List.wrap()
    |> Enum.each(fn event -> _ = Store.add_activity(group_id, event) end)

    snapshot
    |> get_in(["knowledge", "entries"])
    |> List.wrap()
    |> Enum.each(fn entry -> _ = Store.add_knowledge(group_id, entry) end)
  end

  defp merge_local_task(task) do
    if is_map(task) do
      task_id = task["id"] || task["task_id"]

      if is_binary(task_id) do
        task = task |> Map.put("id", task_id) |> Map.put_new("task_id", task_id)

        case local_task(task["group_id"], task_id) do
          %{"status" => existing_status} when existing_status in @terminal_statuses ->
            if Map.get(task, "status") in @terminal_statuses, do: Store.put_task(task), else: :ok

          _ ->
            Store.put_task(task)
        end
      else
        :ok
      end
    else
      :ok
    end
  end

  defp local_task(group_id, task_id) when is_binary(group_id) and is_binary(task_id) do
    Enum.find(Store.list_tasks(group_id), &(&1["id"] == task_id))
  end

  defp local_task(_, _), do: nil

  defp ensure_session(session_id, opts) do
    session_id = session_id || "worker-" <> Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false)

    case Newbee.Web.Session.lookup(session_id) do
      {:ok, pid} ->
        {:ok, pid, session_id}

      _ ->
        case Newbee.Web.Session.ensure(session_id, Keyword.get(opts, :cwd)) do
          {:ok, pid, ^session_id} -> {:ok, pid, session_id}
          {:ok, pid, sid} -> {:ok, pid, sid}
          other -> {:error, {:session_unavailable, other}}
        end
    end
  end

  defp validate_config(opts) do
    base_url = Keyword.get(opts, :base_url)
    group_id = Keyword.get(opts, :group_id)
    device_id = Keyword.get(opts, :device_id)
    device_token = Keyword.get(opts, :device_token)
    fingerprint = Keyword.get(opts, :fingerprint)

    cond do
      not is_binary(base_url) or base_url == "" ->
        {:error, "缺少 base_url"}

      not is_binary(group_id) or group_id == "" ->
        {:error, "缺少 group_id"}

      not is_binary(device_id) or device_id == "" ->
        {:error, "缺少 device_id"}

      not is_binary(device_token) or device_token == "" ->
        {:error, "缺少 device_token"}

      not is_binary(fingerprint) and not Keyword.get(opts, :allow_insecure, false) ->
        {:error, "缺少服务器指纹"}

      true ->
        {:ok,
         %{
           base_url: String.trim_trailing(base_url, "/"),
           group_id: group_id,
           device_id: device_id,
           device_token: device_token,
           fingerprint: fingerprint || "",
           allow_insecure: Keyword.get(opts, :allow_insecure, false) == true,
           allow_full_control: Keyword.get(opts, :allow_full_control, false) == true,
           poll_ms: max(250, Keyword.get(opts, :poll_ms, @default_poll_ms)),
           request_timeout: max(500, Keyword.get(opts, :request_timeout, @default_timeout))
         }}
    end
  end

  defp transport_opts(state) do
    [
      device_token: state.device_token,
      fingerprint: state.fingerprint,
      allow_insecure: state.allow_insecure,
      timeout: state.request_timeout
    ]
  end

  defp backoff(state), do: min(state.poll_ms * trunc(:math.pow(2, min(state.consecutive_failures, 5))), 60_000)
  defp now, do: System.system_time(:millisecond)
end
