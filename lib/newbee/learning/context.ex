defmodule Newbee.Learning.Context do
  @moduledoc "Host-local experiment provenance. OS isolation, not this process flag, confines Actor code."
  @key {__MODULE__, :experiment}

  def current, do: Process.get(@key)
  def experimental?, do: is_map(current())

  def run(id, phase, fun) when is_binary(id) and is_function(fun, 0) do
    previous = Process.get(@key)
    Process.put(@key, %{id: id, phase: phase, learning_enabled: false})

    try do
      fun.()
    after
      if previous, do: Process.put(@key, previous), else: Process.delete(@key)
    end
  end

  def production_write! do
    if experimental?(), do: raise(ArgumentError, "experiment cannot write production memory, signals or fitness")
    :ok
  end
end
