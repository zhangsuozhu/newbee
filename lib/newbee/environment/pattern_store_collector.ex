defmodule Newbee.Environment.PatternStore.Collector do
  @moduledoc """
  Token 归因收集器（R1 场景缺口 G1 解法）。

  问题：loop.ex 的 tool_start 事件不含 token 数；token 计数在 LLM 层 usage
  事件里且与工具调用无关联 ID——TCE 假设的 pattern→tokens 观测脱节。

  方案：订阅既有 Bus（零旁路 [D9]），维护最近工具名游标：
  - :tool_start → 更新归因游标
  - :usage      → tokens 归因给游标工具
  - 定期/批量 flush 到 PatternStore

  投影器定位：不做决策；崩溃只丢未 flush 尾部（Event Store 是权威，投影幂等可重建）。
  """

  use GenServer
  require Logger

  alias Newbee.Environment.{PatternStats, PatternStore}

  @flush_interval 20_000
  @batch_size 25

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    if Process.whereis(Newbee.Bus), do: Newbee.Bus.subscribe()
    schedule_flush()
    {:ok, %{current_tool: nil, pending: %{}, pending_count: 0}}
  end

  @impl true
  def handle_info({:newbee_event, :tool_start, event}, state) do
    case extract_name(event) do
      nil -> {:noreply, state}
      name -> {:noreply, %{state | current_tool: name}}
    end
  end

  def handle_info({:newbee_event, :usage, event}, %{current_tool: tool} = state)
      when is_binary(tool) do
    tokens = extract_tokens(event)

    if is_number(tokens) and tokens > 0 do
      key = {{:tool_use, tool}, "general"}
      pending = Map.update(state.pending, key, [], &[tokens | &1])
      state = %{state | pending: pending, pending_count: state.pending_count + 1}

      if state.pending_count >= @batch_size do
        flush(state)
      else
        {:noreply, state}
      end
    else
      {:noreply, state}
    end
  end

  def handle_info({:newbee_event, _topic, _event}, state), do: {:noreply, state}

  def handle_info(:flush, state) do
    schedule_flush()
    flush(state)
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # internals

  defp flush(%{pending_count: 0} = state), do: {:noreply, state}

  defp flush(state) do
    stats_map =
      case PatternStore.restore() do
        m when is_map(m) and map_size(m) > 0 -> m
        _ -> %{}
      end

    stats_map =
      Enum.reduce(state.pending, stats_map, fn {key, tokens_list}, acc ->
        cur = Map.get(acc, key, PatternStats.new())
        updated = Enum.reduce(tokens_list, cur, &PatternStats.observe(&2, %{saved_tokens: &1 * 1.0}))
        Map.put(acc, key, updated)
      end)

    case PatternStore.persist(stats_map) do
      :ok ->
        {:noreply, %{state | pending: %{}, pending_count: 0}}

      err ->
        Logger.warning("PatternStore flush failed: " <> inspect(err))
        {:noreply, %{state | pending: %{}, pending_count: 0}}
    end
  end

  defp extract_name(event) do
    case event do
      %{"payload" => [_t, name | _]} when is_binary(name) -> name
      {:tool_start, name, _, _} when is_binary(name) -> name
      _ -> nil
    end
  end

  defp extract_tokens(event) do
    case event do
      {:usage, usage} when is_map(usage) -> total_tokens(usage)
      _ -> nil
    end
  end

  defp total_tokens(usage) when is_map(usage) do
    p = usage["prompt_tokens"] || 0
    c = usage["completion_tokens"] || 0

    if is_number(p) and is_number(c), do: p + c, else: nil
  end

  defp schedule_flush, do: Process.send_after(self(), :flush, @flush_interval)
end
