defmodule Newbee.Environment.RealEventStreamTest do
  @moduledoc """
  R12 真实事件流防线：从生产 events.jsonl 形状提取模式时——
  (a) tool_error payload 第二元素是错误消息，不得当作工具名产生假模式
  (b) 字符串-topic + atom-key map 的归一化裂缝必须被覆盖
  这是否定之否定第三次否定用真实数据逼出的缺陷修复。
  """

  use ExUnit.Case, async: true

  alias Newbee.Environment.PatternStore

  @tag :real_stream
  test "tool_error 的 payload 第二元素（错误消息）不产生 tool_use 模式" do
    err_ev = %{topic: :tool_error, payload: ["tool_error", "** (MatchError) no match...", "ctx"]}
    assert PatternStore.key_of(err_ev) == nil

    stats = PatternStore.project([err_ev])
    assert map_size(stats) == 0
  end

  @tag :real_stream
  test "字符串 topic + atom key（JSON 解码后消费端形状）能提取模式" do
    ev = %{topic: "tool_start", payload: ["tool_start", "run_elixir", "title", "code"]}
    assert {{:tool_use, "run_elixir"}, _tt} = PatternStore.key_of(ev)
  end

  @tag :real_stream
  test "混合真实形状事件流：只提取真实工具模式" do
    events = [
      %{topic: :tool_start, payload: ["tool_start", "run_elixir", "t", "code"], tokens: 3000},
      %{topic: "tool_start", payload: ["tool_start", "run_elixir", "t", "code"], tokens: 3000},
      %{topic: :tool_error, payload: ["tool_error", "** (CaseClauseError)...", "ctx"]},
      %{topic: "tool_error", payload: ["tool_error", "** (MatchError)...", "ctx"]}
    ]

    stats = PatternStore.project(events)
    keys = Map.keys(stats)

    assert length(keys) == 1
    assert {{:tool_use, "run_elixir"}, _} = hd(keys)
    refute Enum.any?(keys, fn {{:tool_use, name}, _} -> String.contains?(name, "Error") end)
  end
end
