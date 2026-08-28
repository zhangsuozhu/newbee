defmodule Newbee.Tools.Scaffold do
  @moduledoc """
  Mix 脚手架工具：仅创建工程和拉取依赖；编译/测试用 `Run`。
  编译与测试不在此重复封装，分别调用 `Newbee.Tools.Run.mix_compile/1` 和 `Run.mix_test/2`。

  ## 函数清单
  - `new_project(name) :: {:ok, output} | {:error, output}` — 在当前目录执行 `mix new <name>`。
  - `deps_get() :: {:ok, output} | {:error, output}` — 在当前工程执行 `mix deps.get`。

  ## 可跑示例
      {:ok, out} = Newbee.Tools.Scaffold.new_project("my_app")
      {:ok, out} = Newbee.Tools.Scaffold.deps_get()
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
end
