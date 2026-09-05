defmodule Newbee.Tools.Scaffold do
  @moduledoc """
  Mix scaffolding: new projects + deps only; compile/test via `Run`.
  Compiling and testing are not re-wrapped here — call `Newbee.Tools.Run.mix_compile/1` and `Run.mix_test/2`.

  ## Functions
  - `new_project(name) :: {:ok, output} | {:error, output}` — run `mix new <name>` in the current directory.
  - `deps_get() :: {:ok, output} | {:error, output}` — run `mix deps.get` in the current project.

  ## Runnable example
      {:ok, out} = Newbee.Tools.Scaffold.new_project("my_app")
      {:ok, out} = Newbee.Tools.Scaffold.deps_get()
  """

  @doc "Create a new mix project (under the current dir). Returns {:ok, output} | {:error, output}."
  def new_project(name) do
    result = Newbee.Tools.Run.sh("mix new #{name}")
    if result.exit == 0, do: {:ok, result.output}, else: {:error, result.output}
  end

  @doc "Fetch deps (mix deps.get). Returns `{:ok, output} | {:error, output}`."
  def deps_get do
    result = Newbee.Tools.Run.sh("mix deps.get")
    if result.exit == 0, do: {:ok, result.output}, else: {:error, result.output}
  end
end
