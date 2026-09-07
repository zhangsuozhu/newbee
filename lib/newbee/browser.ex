defmodule Newbee.Browser do
  @moduledoc false
  use Supervisor

  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @stale_tmp_seconds 24 * 3_600

  @impl true
  def init(opts) do
    sweep_stale_tmp(Keyword.get(opts, :root, File.cwd!()))

    children = [
      {Registry, keys: :unique, name: Newbee.Browser.Registry},
      {DynamicSupervisor, strategy: :one_for_one, name: Newbee.Browser.Sessions, max_children: 4}
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end

  def run(token, root, request) do
    with {:ok, owner} <- authorize(token, root),
         {:ok, pid, id} <- session(owner, root, request["session"], request["idle_timeout"]),
         {:ok, payload} <- Newbee.Browser.Session.run(pid, request) do
      field = if payload["ok"] == true, do: "result", else: "error"
      {:ok, Map.update!(payload, field, &Map.put(&1, "session", id))}
    end
  catch
    :exit, _reason ->
      {:error, %{reason: :session_lost, hint: "browser session is unavailable; do not replay unverified writes"}}
  end

  defp authorize(token, root) do
    case Newbee.Collaboration.Capability.resolve(token) do
      {:ok, %{session_id: owner, project_root: ^root}} ->
        {:ok, owner}

      _ ->
        {:error,
         %{reason: :invalid_context, hint: "browser sessions require a valid capability for the active project"}}
    end
  end

  defp session(owner, root, "new", idle_ms) do
    id = :crypto.strong_rand_bytes(18) |> Base.url_encode64(padding: false)
    name = {:via, Registry, {Newbee.Browser.Registry, {owner, root, id}}}
    opts = [root: root, name: name] ++ if is_integer(idle_ms), do: [idle_ms: idle_ms], else: []

    case DynamicSupervisor.start_child(Newbee.Browser.Sessions, {Newbee.Browser.Session, opts}) do
      {:ok, pid} ->
        {:ok, pid, id}

      {:error, :max_children} ->
        {:error,
         %{reason: :session_limit, hint: "four browser sessions are already active; close one before opening another"}}

      {:error, reason} ->
        {:error, %{reason: :runtime_missing, hint: "cannot start browser worker: " <> inspect(reason)}}
    end
  end

  defp session(owner, root, id, _idle_ms) when is_binary(id) do
    case Registry.lookup(Newbee.Browser.Registry, {owner, root, id}) do
      [{pid, _}] ->
        {:ok, pid, id}

      [] ->
        {:error,
         %{
           reason: :session_expired,
           hint: "browser session was closed, expired, or belongs to another owner; explicitly open a new session"
         }}
    end
  end

  defp sweep_stale_tmp(root) do
    tmp = Path.join([root, ".newbee", "browser", "tmp"])
    cutoff = System.system_time(:second) - @stale_tmp_seconds

    for entry <- Path.wildcard(Path.join(tmp, "{session-,runtime-}*")) do
      case File.stat(entry, time: :posix) do
        {:ok, %File.Stat{mtime: mtime}} when mtime < cutoff -> File.rm_rf(entry)
        _ -> :ok
      end
    end

    :ok
  rescue
    _ -> :ok
  end
end
