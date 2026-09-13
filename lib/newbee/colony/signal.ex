defmodule Newbee.Colony.Signal do
  @moduledoc """
  Bee 间信号（附录 C）。每种信号对应一个经实证的蜂群功能：

  - `recommend`  摇摆舞：通告有价值的方向，带质量评分（quality 必填 0..1）；
  - `rebalance`  颤抖舞：某环节积压，招募更多处理者；
  - `inhibit`    停止信号：交叉抑制竞争方案（必须指向 target_proposal_id，且有冷却）；
  - `report`     向上汇报进展或结果；
  - `command`    向平级 Bee 或任务执行者下发工作指令（任务范围内有效）；
  - `notify`     普通知会；
  - `escalate`   升级给人类 Queen（子 Bee 拒绝危险指令时使用）；
  - `handoff`    平级交接（附上下文成果）。
  """

  @kinds ~w(recommend rebalance inhibit report command notify escalate handoff)
  @inhibit_cooldown_ms 5 * 60 * 1000

  def kinds, do: @kinds

  @doc """
  新建信号。attrs: colony_id, kind, from_bee_id, to_bee_id?, task_id?, payload?,
  quality?（recommend 必填）, target_proposal_id?（inhibit 必填）。
  """
  def new(attrs) when is_map(attrs) do
    kind = Map.get(attrs, "kind")

    with :ok <- validate_kind(kind),
         :ok <- validate_quality(kind, Map.get(attrs, "quality")),
         :ok <- validate_target(kind, Map.get(attrs, "target_proposal_id")) do
      {:ok,
       %{
         "id" => Map.get(attrs, "id") || Newbee.Colony.Id.new(:signal, scope_for(attrs)),
         "colony_id" => Map.get(attrs, "colony_id"),
         "kind" => kind,
         "from_bee_id" => blank_to_nil(Map.get(attrs, "from_bee_id")),
         "to_bee_id" => blank_to_nil(Map.get(attrs, "to_bee_id")),
         "task_id" => blank_to_nil(Map.get(attrs, "task_id")),
         "quality" => Map.get(attrs, "quality"),
         "target_proposal_id" => blank_to_nil(Map.get(attrs, "target_proposal_id")),
         "payload" => Map.get(attrs, "payload") || %{},
         "created_at" => Map.get(attrs, "created_at") || now_ms()
       }}
    end
  end

  @doc "冷却校验：同一 Bee 对同一竞争方案的 inhibit 在冷却期内不再生效。"
  def allowed?(signal, recent_signals) do
    case Map.get(signal, "kind") do
      "inhibit" ->
        now = Map.get(signal, "created_at") || now_ms()
        target = Map.get(signal, "target_proposal_id")
        from = Map.get(signal, "from_bee_id")

        recent =
          recent_signals
          |> Enum.filter(fn s -> Map.get(s, "kind") == "inhibit" end)
          |> Enum.filter(fn s ->
            Map.get(s, "from_bee_id") == from and Map.get(s, "target_proposal_id") == target
          end)

        Enum.all?(recent, fn s -> now - Map.get(s, "created_at", 0) > @inhibit_cooldown_ms end)

      _ ->
        true
    end
  end

  @doc "人类可读的信号摘要（Trace/聊天流直接展示）。"
  def describe(signal) do
    kind = Map.get(signal, "kind")

    case kind do
      "recommend" ->
        "推荐方向（质量 #{format_quality(Map.get(signal, "quality"))}）：#{payload_text(signal)}"

      "rebalance" ->
        "负载信号：#{payload_text(signal)}"

      "inhibit" ->
        "抑制竞争方案 #{Map.get(signal, "target_proposal_id")}"

      "report" ->
        "汇报：#{payload_text(signal)}"

      "command" ->
        "指令：#{payload_text(signal)}"

      "notify" ->
        "知会：#{payload_text(signal)}"

      "escalate" ->
        "升级给 Queen：#{payload_text(signal)}"

      "handoff" ->
        "交接：#{payload_text(signal)}"

      _ ->
        payload_text(signal)
    end
  end

  @doc "前端视图：附上可读摘要。"
  def public_view(signal) do
    signal |> Map.put("text", describe(signal))
  end

  defp payload_text(signal) do
    payload = Map.get(signal, "payload", %{})

    cond do
      is_map(payload) and is_binary(Map.get(payload, "text")) -> Map.get(payload, "text")
      is_map(payload) and payload != %{} -> inspect(payload)
      true -> ""
    end
  end

  defp format_quality(nil), do: "?"
  defp format_quality(q) when is_number(q), do: :erlang.float_to_binary(q / 1, decimals: 2)
  defp format_quality(_), do: "?"

  defp validate_kind(kind) when kind in @kinds, do: :ok
  defp validate_kind(_), do: {:error, :invalid_kind}

  defp validate_quality("recommend", q) when is_number(q) and q >= 0 and q <= 1, do: :ok
  defp validate_quality("recommend", _), do: {:error, :quality_required}
  defp validate_quality(_, _), do: :ok

  defp validate_target("inhibit", t) when is_binary(t) and t != "", do: :ok
  defp validate_target("inhibit", _), do: {:error, :target_required}
  defp validate_target(_, _), do: :ok

  defp blank_to_nil(v) when is_binary(v),
    do: if(String.trim(v) == "", do: nil, else: String.trim(v))

  defp blank_to_nil(v), do: v

  defp scope_for(%{"scope" => "xhost"}), do: :xhost
  defp scope_for(_), do: :local

  defp now_ms, do: System.system_time(:millisecond)
end
