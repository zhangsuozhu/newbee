defmodule Newbee.Agent.Protocol do
  @moduledoc """
  协作消息协议（DESIGN §7.2）：所有消息**是事件流中的一类事件**
  （messages.jsonl 只是其派生物理视图）。

  传递语义：**at-least-once + 幂等 effect**，不宣称分布式 exactly-once：

  - sender 首次发送前将 `message_id = {agent_id, monotonic_seq}` 持久化到
    outbox；重试复用同一 ID，agent 重启后序列号不得回退；
  - Coordinator inbox 先按 `message_id` 去重，再追加受理事件；
  - 副作用操作另带**操作级 idempotency key**：激活 `{change_id,
    candidate_revision}`、回退 `{rollback_change_id, target_revision}`、
    预算扣减 `{change_id, attempt, budget_kind}`；
  - `feedback` 允许同一 release 多次上报，只按 message_id 去重。
  """

  alias Newbee.Environment.Store

  @kinds [
    :need,
    :candidate_ready,
    :feedback,
    :rollback_request,
    :module_ready,
    :module_rejected,
    :evaluation_failed,
    :rolled_back
  ]

  def kinds, do: @kinds

  # ── message_id：{agent_id, monotonic_seq}，重启不回退 ──

  @doc "生成消息 id。序列号持久化在 outbox，重启后从水位续。"
  def gen_message_id(agent_id) do
    seq = next_seq(agent_id)
    "#{agent_id}:#{seq}"
  end

  defp next_seq(agent_id) do
    path = outbox_path(agent_id)
    File.mkdir_p!(Path.dirname(path))

    seq =
      case File.read(path) do
        {:ok, body} ->
          case Integer.parse(String.trim(body)) do
            {n, _} -> n + 1
            _ -> 1
          end

        _ ->
          1
      end

    File.write!(path, to_string(seq))
    seq
  end

  defp outbox_path(agent_id) do
    Path.join(Store.dir(:locks), "outbox_#{safe(agent_id)}.seq")
  end

  # ── 发送 ──

  @doc """
  发送消息（at-least-once）：经 Events.emit 落 EventStore（§7.2 消息是事件流
  中的一类事件；messages.jsonl 保留为派生物理视图）+ 总线广播。
  standalone（无项目 store）时优雅降级只写派生视图 + Bus。
  payload 含 message_id/request_id/project_id/sender/created_at。
  """
  def send_message(kind, sender, payload) when kind in @kinds do
    message = %{
      "message_id" => gen_message_id(sender),
      "request_id" => payload[:request_id] || payload["request_id"],
      "project_id" => File.cwd!(),
      "sender" => to_string(sender),
      "kind" => to_string(kind),
      "created_at" => now_iso(),
      "payload" => json_safe(payload)
    }

    Store.ensure!()
    Store.append_jsonl!(Store.path(:messages), message)
    Newbee.Events.emit(kind, message)
    {:ok, message["message_id"]}
  end

  # ── 具体消息（§7.2 载荷）──

  @doc "worker → adapter：进化线索（一句话便宜事，urgency: low 默认）。"
  def need(capability, opts \\ []) do
    send_message(:need, Keyword.get(opts, :sender, "worker"), %{
      capability: capability,
      expected_api: Keyword.get(opts, :expected_api),
      context: Keyword.get(opts, :context),
      evidence: Keyword.get(opts, :evidence),
      urgency: Keyword.get(opts, :urgency, :low),
      request_id: Keyword.get(opts, :request_id)
    })
  end

  @doc "worker → adapter/coordinator：版本级 feedback（score 必须绑定具体 release）。"
  def feedback(plugin_id, release_id, outcome, opts \\ []) do
    send_message(:feedback, Keyword.get(opts, :sender, "worker"), %{
      request_id: Keyword.get(opts, :request_id),
      plugin_id: plugin_id,
      release_id: release_id,
      outcome: outcome,
      score: Keyword.get(opts, :score),
      errors: Keyword.get(opts, :errors, []),
      latency: Keyword.get(opts, :latency),
      output_size: Keyword.get(opts, :output_size),
      comment: Keyword.get(opts, :comment),
      suggested_action: Keyword.get(opts, :suggested_action)
    })
  end

  @doc "worker → coordinator：回退请求（target 只是线索，§8.4）。"
  def rollback_request(plugin_id, release_id, target, reason, opts \\ []) do
    send_message(:rollback_request, Keyword.get(opts, :sender, "worker"), %{
      request_id: Keyword.get(opts, :request_id),
      plugin_id: plugin_id,
      release_id: release_id,
      target: target,
      reason: reason
    })
  end

  @doc "adapter → coordinator：候选就绪。"
  def candidate_ready(change_id, plugin_id, release_id, evaluation_plan, opts \\ []) do
    send_message(:candidate_ready, Keyword.get(opts, :sender, "adapter"), %{
      change_id: change_id,
      plugin_id: plugin_id,
      release_id: release_id,
      evaluation_plan: evaluation_plan
    })
  end

  # ── inbox 去重（§7.2）──

  @doc """
  inbox 去重检查：message_id 已受理过 → :duplicate。
  受理水位持久化，崩溃后重放不重复 effect。
  """
  def dedupe(message_id, opts \\ []) do
    inbox = inbox_set(opts)

    if MapSet.member?(inbox, message_id) do
      :duplicate
    else
      mark_inbox(message_id, opts)
      :new
    end
  end

  defp inbox_set(opts) do
    path = Keyword.get(opts, :inbox_path, inbox_path())

    path
    |> Store.read_jsonl()
    |> Enum.map(& &1["message_id"])
    |> MapSet.new()
  end

  defp mark_inbox(message_id, opts) do
    path = Keyword.get(opts, :inbox_path, inbox_path())
    Store.append_jsonl!(path, %{"message_id" => message_id, "at" => now_iso()})
  end

  defp inbox_path do
    Path.join(Store.dir(:locks), "inbox.jsonl")
  end

  @doc "读取消息流（adapter 消费 need；TUI 展示协议）。"
  def messages(opts \\ []) do
    Store.read_jsonl(Store.path(:messages))
    |> then(fn msgs ->
      case Keyword.get(opts, :kind) do
        nil -> msgs
        kind -> Enum.filter(msgs, &(&1["kind"] == to_string(kind)))
      end
    end)
  end

  @doc "未消费的消息（adapter 启动时 resume，§11.5）。"
  def pending_needs do
    consumed =
      messages(kind: :module_ready)
      |> Enum.map(&get_in(&1, ["payload", "change_id"]))
      |> MapSet.new()

    messages(kind: :need)
    |> Enum.reject(fn m -> MapSet.member?(consumed, m["message_id"]) end)
  end

  defp safe(id), do: id |> to_string() |> String.replace(~r/[^\w\.\-]/, "_")

  defp json_safe(v) when is_map(v) and not is_struct(v),
    do: Map.new(v, fn {k, val} -> {to_string(k), json_safe(val)} end)

  defp json_safe(v) when is_list(v), do: Enum.map(v, &json_safe/1)
  defp json_safe(v) when is_tuple(v), do: v |> Tuple.to_list() |> Enum.map(&json_safe/1)
  defp json_safe(v) when is_atom(v), do: to_string(v)
  defp json_safe(v), do: v

  defp now_iso, do: DateTime.utc_now() |> DateTime.to_iso8601()
end
