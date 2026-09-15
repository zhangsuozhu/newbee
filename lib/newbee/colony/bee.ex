defmodule Newbee.Colony.Bee do
  @moduledoc """
  Bee（工蜂）：蜂群成员，可以是人或 AI。

  关键设计（附录 L）：
  - Bee 在 Colony 成员层永远平级（membership_role: peer）。
  - 上下级只存在于 Task 图（coordinator_bee_id / parent_task_id），任务结束即消失。
  - 协调权来自任务授权，不来自 Bee 身份；危险动作权限不随父子关系继承。
  """

  alias Newbee.Colony.Id

  @human_default_capabilities ["review", "decide", "communicate"]
  @ai_default_capabilities ["edit", "shell", "research"]
  @kinds ~w(human ai)

  @doc "新建 Bee。attrs: colony_id, kind, display, capabilities?, session_id?, garden_id?, role?"
  def new(attrs) when is_map(attrs) do
    kind = normalize_kind(Map.get(attrs, "kind"))
    now = Map.get(attrs, "joined_at") || now_ms()

    %{
      "id" => Map.get(attrs, "id") || Id.new(:bee, scope_for(attrs)),
      "colony_id" => Map.get(attrs, "colony_id"),
      "kind" => kind,
      "display" => blank_to_nil(Map.get(attrs, "display")) || default_display(kind),
      "capabilities" => normalize_capabilities(Map.get(attrs, "capabilities"), kind),
      "thresholds" => Map.get(attrs, "thresholds") || %{},
      "session_id" => blank_to_nil(Map.get(attrs, "session_id")),
      "conversations" => normalize_conversations(attrs),
      "garden_id" => blank_to_nil(Map.get(attrs, "garden_id")),
      "role" => Map.get(attrs, "role") || "member",
      "status" => Map.get(attrs, "status") || "idle",
      "last_seen_at" => Map.get(attrs, "last_seen_at") || now,
      "joined_at" => now
    }
  end

  @doc "Bee 是否具备任务所需能力（capability 硬门槛）。"
  def can?(bee, task) when is_map(bee) and is_map(task) do
    required = List.wrap(Map.get(task, "requires", []))
    capabilities = List.wrap(Map.get(bee, "capabilities", []))
    Enum.all?(required, &(&1 in capabilities))
  end

  @doc "Bee 对某类任务的响应阈值：越低越容易被触发。"
  def threshold(bee, task) do
    kind = Map.get(task, "kind") || Map.get(task, "type") || "default"
    thresholds = Map.get(bee, "thresholds", %{}) |> Map.new(fn {k, v} -> {to_string(k), v} end)
    Map.get(thresholds, kind, default_threshold(Map.get(bee, "kind")))
  end

  defp default_threshold("human"), do: 0.75
  defp default_threshold(_), do: 0.35

  @doc "可见性视图（前端展示用，不含敏感会话内部数据）。"
  def public(bee) when is_map(bee) do
    Map.drop(bee, ["session_token", "plain", "secret"])
  end

  def kinds, do: @kinds

  def human_default_capabilities, do: @human_default_capabilities
  def ai_default_capabilities, do: @ai_default_capabilities

  @doc "根据显示名猜测 Bee 类型：AI 名字常见 *_bot/助手/agent/ai。"
  def infer_kind(nil), do: "human"

  def infer_kind(display) when is_binary(display) do
    d = String.downcase(display)

    cond do
      String.contains?(d, "bot") -> "ai"
      String.contains?(d, "agent") -> "ai"
      String.contains?(d, "ai") -> "ai"
      String.contains?(display, "助手") -> "ai"
      true -> "human"
    end
  end

  defp normalize_kind("AI"), do: "ai"
  defp normalize_kind("ai"), do: "ai"
  defp normalize_kind("人"), do: "human"
  defp normalize_kind("human"), do: "human"
  defp normalize_kind(_), do: "human"

  # 一只 Bee 的全部对话（会话 id 列表）。缺省 = 绑定会话那一条。
  defp normalize_conversations(attrs) do
    list =
      attrs
      |> Map.get("conversations")
      |> List.wrap()
      |> Enum.filter(&is_binary/1)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

    case {list, blank_to_nil(Map.get(attrs, "session_id"))} do
      {[], nil} -> []
      {[], sid} -> [sid]
      {list, sid} -> if sid && sid not in list, do: [sid | list], else: list
    end
  end

  defp normalize_capabilities(nil, kind), do: defaults(kind)

  defp normalize_capabilities(list, kind) when is_list(list) do
    list
    |> Enum.map(&to_string/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> case do
      [] -> defaults(kind)
      caps -> Enum.uniq(caps)
    end
  end

  defp normalize_capabilities(_, kind), do: defaults(kind)

  defp defaults("ai"), do: @ai_default_capabilities
  defp defaults(_), do: @human_default_capabilities

  defp default_display("ai"), do: "ai-bee"
  defp default_display(_), do: "bee"

  defp scope_for(%{"scope" => "xhost"}), do: :xhost
  defp scope_for(_), do: :local

  defp blank_to_nil(v) when is_binary(v),
    do: if(String.trim(v) == "", do: nil, else: String.trim(v))

  defp blank_to_nil(v), do: v

  defp now_ms, do: System.system_time(:millisecond)
end
