defmodule Newbee.Web.Auth.SessionWriter do
  @moduledoc false

  use GenServer
  require Logger

  @flush_delay 25

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  def persist(path, version, body)
      when is_binary(path) and is_integer(version) and is_binary(body) do
    case Process.whereis(__MODULE__) do
      nil -> write(path, body)
      server -> GenServer.cast(server, {:persist, path, version, body})
    end
  end

  def persist_sync(path, version, body)
      when is_binary(path) and is_integer(version) and is_binary(body) do
    case Process.whereis(__MODULE__) do
      nil -> write(path, body)
      server -> GenServer.call(server, {:persist_sync, path, version, body}, 30_000)
    end
  end

  def flush do
    case Process.whereis(__MODULE__) do
      nil -> :ok
      server -> GenServer.call(server, :flush, 30_000)
    end
  end

  @impl true
  def init(_opts), do: {:ok, %{pending: %{}, versions: %{}, timer: nil}}

  @impl true
  def handle_cast({:persist, path, version, body}, state) do
    {:noreply, state |> put_pending(path, version, body) |> schedule()}
  end

  @impl true
  def handle_call({:persist_sync, path, version, body}, _from, state) do
    state = state |> put_pending(path, version, body) |> flush_pending()
    {:reply, :ok, state}
  end

  def handle_call(:flush, _from, state) do
    {:reply, :ok, flush_pending(state)}
  end

  @impl true
  def handle_info(:flush, state), do: {:noreply, flush_pending(%{state | timer: nil})}
  def handle_info(_message, state), do: {:noreply, state}

  defp put_pending(state, path, version, body) do
    current =
      case Map.get(state.pending, path) do
        {pending_version, _body} -> pending_version
        nil -> Map.get(state.versions, path, -1)
      end

    if version >= current do
      %{state | pending: Map.put(state.pending, path, {version, body})}
    else
      state
    end
  end

  defp schedule(%{timer: nil} = state),
    do: %{state | timer: Process.send_after(self(), :flush, @flush_delay)}

  defp schedule(state), do: state

  defp flush_pending(state) do
    if state.timer, do: Process.cancel_timer(state.timer)

    versions =
      Enum.reduce(state.pending, state.versions, fn {path, {version, body}}, versions ->
        write(path, body)
        Map.put(versions, path, version)
      end)

    %{state | pending: %{}, versions: versions, timer: nil}
  end

  defp write(path, body) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, body)
    :ok
  rescue
    error ->
      Logger.warning("auth session persistence failed: " <> Exception.message(error))
      :ok
  end
end
