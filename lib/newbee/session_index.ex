defmodule Newbee.SessionIndex do
  @moduledoc false
  use Agent
  @table :newbee_session_index

  def start_link(_opts \\ []) do
    if Process.whereis(__MODULE__) == nil do
      Agent.start_link(
        fn ->
          :ets.new(@table, [:named_table, :public, :set, {:read_concurrency, true}])
        end,
        name: __MODULE__
      )
    else
      {:ok, Process.whereis(__MODULE__)}
    end
  end

  def fetch(key) do
    case :ets.lookup(@table, key) do
      [{^key, value}] -> {:ok, value}
      [] -> :error
    end
  end

  def put(key, value), do: :ets.insert(@table, {key, value})
end
