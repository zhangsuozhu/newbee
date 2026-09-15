defmodule Newbee.Colony.Trace do
  @moduledoc """
  工作记录（stigmergy 数字化）：工具调用、Bee 间信号、任务生命周期、成果与验收
  全部进入同一条追加式日志。

  条目 schema：
    %{"id","seq","colony_id","ts","type","channel","bee_id","to_bee_id","task_id","text","data"}

  - `type`: message | signal | task | honey | lifecycle | command | tool_call
  - `channel`: colony（群聊）| dm（一对一）| task（任务上下文）
  - `text`: 服务端预生成的可读摘要，前端直接展示
  """

  @types ~w(message signal task honey lifecycle command tool_call)

  def types, do: @types

  @doc "构造 Trace 条目（不落库；由 Store.append_trace 入库并分配 seq）。"
  def entry(attrs) when is_map(attrs) do
    type = Map.get(attrs, "type") || "message"

    %{
      "id" => Map.get(attrs, "id") || Newbee.Colony.Id.new(:trace, scope_for(attrs)),
      "colony_id" => Map.get(attrs, "colony_id"),
      "type" => type,
      "channel" => Map.get(attrs, "channel") || default_channel(type),
      "bee_id" => blank_to_nil(Map.get(attrs, "bee_id")),
      "to_bee_id" => blank_to_nil(Map.get(attrs, "to_bee_id")),
      "task_id" => blank_to_nil(Map.get(attrs, "task_id")),
      "text" => Map.get(attrs, "text") || "",
      "data" => Map.get(attrs, "data") || %{},
      "ts" => Map.get(attrs, "ts") || System.system_time(:millisecond)
    }
  end

  defp default_channel("signal"), do: "colony"
  defp default_channel("message"), do: "colony"
  defp default_channel("task"), do: "task"
  defp default_channel("honey"), do: "colony"
  defp default_channel("command"), do: "task"
  defp default_channel("tool_call"), do: "task"
  defp default_channel(_), do: "colony"

  defp blank_to_nil(v) when is_binary(v),
    do: if(String.trim(v) == "", do: nil, else: String.trim(v))

  defp blank_to_nil(v), do: v

  defp scope_for(%{"scope" => "xhost"}), do: :xhost
  defp scope_for(_), do: :local
end
