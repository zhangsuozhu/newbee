defmodule Newbee.Colony.SourceRuntime do
  @moduledoc "Supervised, bounded reply effects; Colony's state writer never performs network calls."
  use GenServer
  alias Newbee.Colony.{Source, Store}
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  @impl true
  def init(_) do
    Process.send_after(self(), :tick, 3_000)
    {:ok, %{worker: nil}}
  end

  @impl true
  def handle_info(:tick, state) do
    Process.send_after(self(), :tick, 3_000)

    if Application.get_env(:newbee, :colony_background, true) and state.worker == nil do
      parent = self()

      {pid, ref} =
        spawn_monitor(fn ->
          sweep()
          send(parent, :source_sweep_done)
        end)

      {:noreply, %{state | worker: {pid, ref}}}
    else
      {:noreply, state}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{worker: {_worker, ref}} = state),
    do: {:noreply, %{state | worker: nil}}

  def handle_info(:source_sweep_done, state), do: {:noreply, state}
  def handle_info(_, state), do: {:noreply, state}
  @impl true
  def terminate(_, %{worker: {pid, _}}), do: Process.exit(pid, :shutdown)
  def terminate(_, _), do: :ok

  def sweep do
    :ok = Source.collect_replies()

    Store.all("source_outbox")
    |> Enum.filter(&(&1["status"] == "pending" and &1["next_at"] <= System.system_time(:millisecond)))
    |> Enum.sort_by(& &1["created_at"])
    |> Enum.take(4)
    |> Enum.each(&Source.deliver(&1["id"]))

    :ok
  end
end
