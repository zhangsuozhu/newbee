defmodule Newbee.Tools.Scaffold do
  @moduledoc """
  工程脚手架工具 (DESIGN §3.2 工程)：`mix new` / `mix deps.get` 等。
  内部复用 `Newbee.Tools.Run.sh`（超时 + 输出上限）。

  ## 函数清单
  - `new_project(name :: String.t()) :: {:ok, output} | {:error, output}` — `mix new <name>` 在当前目录下创建。
  - `deps_get() :: {:ok, output} | {:error, output}` — `mix deps.get`。
  - `compile() :: {:ok, output} | {:error, output}` — `mix compile`（委托 `Run.mix_compile`）。
  - `test(files \\ []) :: {:ok, output} | {:error, output}` — `mix test [files...]`（委托 `Run.mix_test`）。

  ## 可跑示例
      {:ok, out} = Newbee.Tools.Scaffold.new_project("my_app")
      {:ok, out} = Newbee.Tools.Scaffold.deps_get()
      {:ok, out} = Newbee.Tools.Scaffold.compile()
      {:ok, out} = Newbee.Tools.Scaffold.test(["test/my_app_test.exs"])

  """

  @doc "创建新 mix 工程（当前目录下）。返回 {:ok, output} | {:error, output}。"
  def new_project(name) do
    result = Newbee.Tools.Run.sh("mix new #{name}")
    if result.exit == 0, do: {:ok, result.output}, else: {:error, result.output}
  end

  @doc "拉取依赖（mix deps.get）。"
  def deps_get do
    result = Newbee.Tools.Run.sh("mix deps.get")
    if result.exit == 0, do: {:ok, result.output}, else: {:error, result.output}
  end

  @doc "编译（mix compile）。"
  def compile do
    Newbee.Tools.Run.mix_compile()
  end

  @doc "跑测试（mix test，可传文件列表）。"
  def test(files \\ []) do
    Newbee.Tools.Run.mix_test(files)
  end
end
