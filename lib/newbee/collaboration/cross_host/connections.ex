defmodule Newbee.Collaboration.CrossHost.Connections do
  @moduledoc """
  Owns outbound Worker connections to remote Hubs.

  Enrollment credentials are stored separately from the public group cache in a
  mode-0600 file. The invite password is never persisted.
  """

  use GenServer

  alias Newbee.Collaboration.CrossHost.{Store, Transport, Worker}

  @registry Newbee.Collaboration.CrossHost.WorkerRegistry
  @supervisor Newbee.Collaboration.CrossHost.WorkerSupervisor
  @default_port 4173

  @doc false
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "Join a remote Hub over pinned HTTPS, persist the device credential, and start polling."
  def join(base_url, group_id, password, fingerprint, display, opts \\ []) do
    manager = Keyword.get(opts, :manager, __MODULE__)
    enroller = Keyword.get(opts, :worker, Worker)
    allow_full_control = Keyword.get(opts, :allow_full_control, false) == true

    with {:ok, normalized_url} <- normalize_url(base_url),
         {:ok, enrollment} <- enroller.join(normalized_url, group_id, password, fingerprint, display, []),
         {:ok, public_enrollment} <-
           GenServer.call(manager, {:install, enrollment, normalized_url, fingerprint, allow_full_control}, 15_000) do
      {:ok, public_enrollment}
    end
  end

  @doc "Stop and forget this machine's outbound connection for a group."
  def disconnect(group_id, manager \\ __MODULE__) when is_binary(group_id) do
    if Process.whereis(manager), do: GenServer.call(manager, {:disconnect, group_id}), else: :ok
  end

  @doc "Change this machine's permission mode for one outbound group connection."
  def set_full_control(group_id, enabled, manager \\ __MODULE__)
      when is_binary(group_id) and is_boolean(enabled) do
    if Process.whereis(manager),
      do: GenServer.call(manager, {:set_full_control, group_id, enabled}, 15_000),
      else: {:error, "not_running", "远程连接管理器未启动"}
  end

  @doc "Ask the authoritative Hub to invoke an advertised capability on another group device."
  def invoke(group_id, device_id, capability, args, opts)
      when is_binary(group_id) and is_binary(device_id) and is_binary(capability) and is_list(args) do
    manager = Keyword.get(opts, :manager, __MODULE__)
    command_id = Keyword.get(opts, :command_id)

    if Process.whereis(manager),
      do: GenServer.call(manager, {:invoke, group_id, device_id, capability, args, command_id}, 30_000),
      else: {:error, "not_running", "远程连接管理器未启动"}
  end

  def invoke(_, _, _, _, _), do: {:error, "bad_request", "远程能力调用参数无效"}
  @doc "Forward a project chat operation using this host's private enrolled device credential."
  def chat(group_id, action, params, manager \\ __MODULE__) do
    if Process.whereis(manager),
      do: GenServer.call(manager, {:chat, group_id, action, params}, 15_000),
      else: {:error, "not_running", "远程连接管理器未启动"}
  end

  @doc "Return outbound connection state without exposing device credentials."

  def status(group_id, manager \\ __MODULE__) when is_binary(group_id) do
    if Process.whereis(manager),
      do: GenServer.call(manager, {:status, group_id}),
      else: {:error, "not_running", "远程连接管理器未启动"}
  end

  @doc "Normalize a Hub address. Bare hosts use pinned HTTPS on Newbee's default Web port."
  def normalize_url(value) when is_binary(value) do
    value = String.trim(value)
    bare? = value != "" and not String.contains?(value, "://")
    candidate = if bare?, do: "https://" <> value, else: value
    explicit_port? = Regex.match?(~r/:\d+$/, value)
    uri = URI.parse(candidate)

    cond do
      uri.scheme != "https" ->
        {:error, "bad_request", "远端 Hub 必须使用 HTTPS"}

      not is_binary(uri.host) or uri.host == "" ->
        {:error, "bad_request", "远端 Hub 地址缺少主机名"}

      uri.userinfo not in [nil, ""] or uri.query not in [nil, ""] or uri.fragment not in [nil, ""] ->
        {:error, "bad_request", "远端 Hub 地址不能包含账号、查询参数或片段"}

      uri.path not in [nil, "", "/"] ->
        {:error, "bad_request", "远端 Hub 地址不能包含路径"}

      true ->
        port = if bare? and not explicit_port?, do: @default_port, else: uri.port
        {:ok, URI.to_string(%{uri | port: port, path: nil, query: nil, fragment: nil, userinfo: nil})}
    end
  rescue
    _ -> {:error, "bad_request", "远端 Hub 地址无效"}
  end

  def normalize_url(_), do: {:error, "bad_request", "请填写远端 Hub 地址"}

  @doc "Credential file path, exposed for diagnostics and tests."
  def credentials_path do
    Path.join([Newbee.GlobalStore.root(), "xgroups", "worker-connections.json"])
  end

  @impl true
  def init(opts) do
    path = Keyword.get(opts, :path, credentials_path())
    supervisor = Keyword.get(opts, :supervisor, @supervisor)
    registry = Keyword.get(opts, :registry, @registry)
    {:ok, %{path: path, supervisor: supervisor, registry: registry, connections: load(path)}, {:continue, :restore}}
  end

  @impl true
  def handle_continue(:restore, state) do
    Enum.each(state.connections, fn {_group_id, config} -> restore_connection(config, state) end)
    {:noreply, state}
  end

  @impl true
  def handle_call({:install, enrollment, base_url, fingerprint, allow_full_control}, _from, state) do
    with {:ok, config} <- connection_config(enrollment, base_url, fingerprint, allow_full_control) do
      if authoritative_local_group?(config["group_id"]) do
        {:reply, {:ok, public_enrollment(enrollment, %{state: "local"})}, state}
      else
        next_connections = Map.put(state.connections, config["group_id"], config)

        case persist(state.path, next_connections) do
          :ok ->
            :ok = put_remote_group(config)
            connection_status = start_worker(config, state)
            next = %{state | connections: next_connections}
            {:reply, {:ok, public_enrollment(enrollment, connection_status)}, next}

          {:error, reason} ->
            {:reply, {:error, "credential_store_failed", "无法保存远程设备凭据：#{inspect(reason)}"}, state}
        end
      end
    else
      {:error, code, message} -> {:reply, {:error, code, message}, state}
    end
  end

  def handle_call({:disconnect, group_id}, _from, state) do
    stop_worker(group_id, state)
    next_connections = Map.delete(state.connections, group_id)
    result = persist(state.path, next_connections)
    {:reply, result, %{state | connections: next_connections}}
  end

  def handle_call({:set_full_control, group_id, enabled}, _from, state) do
    case Map.fetch(state.connections, group_id) do
      {:ok, config} ->
        updated = Map.put(config, "full_control", enabled)
        connections = Map.put(state.connections, group_id, updated)

        case persist(state.path, connections) do
          :ok ->
            _ = start_worker(updated, state)

            {:reply, {:ok, %{"group_id" => group_id, "mode" => if(enabled, do: "full", else: "normal")}},
             %{state | connections: connections}}

          {:error, reason} ->
            {:reply, {:error, "credential_store_failed", "无法保存权限设置：#{inspect(reason)}"}, state}
        end

      :error ->
        {:reply, {:error, "not_found", "本机没有这个远程群连接"}, state}
    end
  end

  def handle_call({:invoke, group_id, target_device_id, capability, args, command_id}, _from, state) do
    reply =
      with {:ok, config} <- Map.fetch(state.connections, group_id) do
        payload = %{
          "deviceId" => config["device_id"],
          "targetDeviceId" => target_device_id,
          "capability" => capability,
          "args" => args,
          "commandId" => command_id
        }

        Transport.rpc(config["base_url"], "xgroup.bridge.command", payload,
          device_token: config["device_token"],
          fingerprint: config["fingerprint"],
          timeout: 30_000
        )
      else
        :error -> {:error, "not_found", "本机没有这个远程群连接"}
      end

    {:reply, reply, state}
  end

  def handle_call({:chat, group_id, action, params}, _from, state) do
    reply =
      case Map.fetch(state.connections, group_id) do
        {:ok, config} ->
          Transport.rpc(
            config["base_url"],
            "xgroup.bridge.chat",
            %{"deviceId" => config["device_id"], "action" => action, "params" => params},
            device_token: config["device_token"],
            fingerprint: config["fingerprint"]
          )

        :error ->
          {:error, "not_found", "本机没有这个远程群连接"}
      end

    {:reply, reply, state}
  end

  def handle_call({:status, group_id}, _from, state) do
    reply =
      case Map.fetch(state.connections, group_id) do
        {:ok, config} -> worker_status(config, state)
        :error -> {:error, "not_found", "本机没有这个远程群连接"}
      end

    {:reply, reply, state}
  end

  defp connection_config(enrollment, base_url, fingerprint, allow_full_control) do
    group = enrollment["group"] || %{}
    device = enrollment["device"] || %{}
    group_id = group["id"]
    device_id = device["id"]
    token = device["plain"]

    cond do
      not is_binary(group_id) or group_id == "" ->
        {:error, "bad_response", "远端未返回群 ID"}

      not is_binary(device_id) or device_id == "" ->
        {:error, "bad_response", "远端未返回设备 ID"}

      not is_binary(token) or token == "" ->
        {:error, "bad_response", "远端未返回设备凭据"}

      not is_binary(fingerprint) or fingerprint == "" ->
        {:error, "bad_server_identity", "加群码缺少服务器指纹"}

      true ->
        {:ok,
         %{
           "group_id" => group_id,
           "base_url" => base_url,
           "fingerprint" => fingerprint,
           "device_id" => device_id,
           "device_token" => token,
           "full_control" => allow_full_control == true,
           "session_id" => "worker-" <> group_id,
           "group" => sanitize_group(group)
         }}
    end
  end

  defp restore_connection(config, state) do
    if valid_config?(config) and not authoritative_local_group?(config["group_id"]) do
      :ok = put_remote_group(config)
      _ = start_worker(config, state)
    end

    :ok
  end

  defp start_worker(config, state) do
    stop_worker(config["group_id"], state)
    name = {:via, Registry, {state.registry, config["group_id"]}}

    opts = [
      name: name,
      base_url: config["base_url"],
      group_id: config["group_id"],
      device_id: config["device_id"],
      device_token: config["device_token"],
      fingerprint: config["fingerprint"],
      allow_full_control: config["full_control"] == true,
      session_id: config["session_id"]
    ]

    case DynamicSupervisor.start_child(state.supervisor, {Worker, opts}) do
      {:ok, pid} -> %{state: "connecting", pid: inspect(pid)}
      {:error, {:already_started, pid}} -> %{state: "connecting", pid: inspect(pid)}
      {:error, reason} -> %{state: "retry_on_restart", error: inspect(reason)}
    end
  end

  defp stop_worker(group_id, state) do
    case Registry.lookup(state.registry, group_id) do
      [{pid, _} | _] -> DynamicSupervisor.terminate_child(state.supervisor, pid)
      [] -> :ok
    end
  end

  defp worker_status(config, state) do
    case Registry.lookup(state.registry, config["group_id"]) do
      [{pid, _} | _] -> {:ok, Worker.status(pid)}
      [] -> {:ok, %{connected: false, group_id: config["group_id"], state: "stopped"}}
    end
  catch
    :exit, _ -> {:ok, %{connected: false, group_id: config["group_id"], state: "restarting"}}
  end

  defp put_remote_group(config) do
    group =
      config["group"]
      |> Map.put("id", config["group_id"])
      |> Map.put("remote", true)
      |> Map.put("server_url", config["base_url"])
      |> Map.put("server_fp", config["fingerprint"])

    Store.put_group(group)
  end

  defp authoritative_local_group?(group_id) do
    case Store.get_group(group_id) do
      {:ok, %{"password" => password}} when is_map(password) -> true
      _ -> false
    end
  end

  defp public_enrollment(enrollment, connection_status) do
    enrollment
    |> put_in(["device"], Map.drop(enrollment["device"] || %{}, ["plain", "token_hash"]))
    |> Map.put("connection", connection_status)
  end

  defp sanitize_group(group) when is_map(group) do
    devices =
      group
      |> Map.get("devices", %{})
      |> Map.new(fn {id, device} -> {id, Map.drop(device, ["plain", "token_hash"])} end)

    group |> Map.drop(["password", "knowledge"]) |> Map.put("devices", devices)
  end

  defp sanitize_group(_), do: %{}

  defp valid_config?(config) when is_map(config) do
    Enum.all?(~w(group_id base_url fingerprint device_id device_token session_id), fn key ->
      is_binary(config[key]) and config[key] != ""
    end) and is_map(config["group"])
  end

  defp valid_config?(_), do: false

  defp load(path) do
    with {:ok, body} <- File.read(path),
         {:ok, %{"connections" => connections}} <- Jason.decode(body),
         true <- is_map(connections) do
      Map.filter(connections, fn {_group_id, config} -> valid_config?(config) end)
    else
      _ -> %{}
    end
  rescue
    _ -> %{}
  end

  defp persist(path, connections) do
    tmp = path <> ".tmp." <> Integer.to_string(System.unique_integer([:positive]))

    try do
      with :ok <- File.mkdir_p(Path.dirname(path)),
           :ok <- File.write(tmp, Jason.encode!(%{"version" => 1, "connections" => connections})),
           :ok <- File.chmod(tmp, 0o600),
           :ok <- File.rename(tmp, path) do
        :ok
      else
        {:error, reason} ->
          _ = File.rm(tmp)
          {:error, reason}
      end
    rescue
      error ->
        _ = File.rm(tmp)
        {:error, Exception.message(error)}
    end
  end
end
