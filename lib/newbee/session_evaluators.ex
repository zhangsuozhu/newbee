defmodule Newbee.SessionEvaluators do
  @moduledoc """
  会话 → 求值器 注册表（会话级隔离）。

  每个会话（Agent.Loop kernel）在 init 时把自己的 evaluator 注册进来
  （key = kernel pid），`Loop.interrupt/1` 据此只杀**本会话**的求值 cell，
  不触碰其它会话的求值器。

  底层用 `Registry`（keys: :unique），进程死亡自动注销，无需手动清理。
  """

  @registry __MODULE__

  @doc "启动注册表（Application 监督树挂载）。"
  def start_link(_opts \\ []) do
    Registry.start_link(keys: :unique, name: @registry)
  end

  def child_spec(opts) do
    %{
      id: @registry,
      start: {__MODULE__, :start_link, [opts]},
      type: :supervisor
    }
  end

  @doc "注册 kernel → evaluator 映射（Loop init 调用）。重复注册覆盖旧的。"
  def register(kernel, value) when is_pid(kernel) do
    case Registry.register(@registry, kernel, value) do
      {:ok, _} ->
        :ok

      {:error, {:already_registered, _}} ->
        Registry.unregister(@registry, kernel)

        case Registry.register(@registry, kernel, value) do
          {:ok, _} -> :ok
          _ -> :ok
        end

      _ ->
        :ok
    end
  rescue
    _ -> :ok
  end

  @doc "查 kernel 对应的 evaluator；未注册返回 :error。"
  def lookup(kernel) when is_pid(kernel) do
    case Registry.lookup(@registry, kernel) do
      [{_pid, {evaluator, scope}}] ->
        if is_pid(evaluator) and Process.alive?(evaluator),
          do: {:ok, {evaluator, scope}},
          else: :error

      [{_pid, evaluator}] when is_pid(evaluator) ->
        if Process.alive?(evaluator), do: {:ok, evaluator}, else: :error

      _ ->
        :error
    end
  rescue
    _ -> :error
  end
end
