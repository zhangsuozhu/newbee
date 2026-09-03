defmodule Newbee.Environment.Change do
  @moduledoc """
  Change (DESIGN §3.4)：可回退的最小审计单元。

  ```text
  requested → building → evaluating → canary → active → promoted
  任何阶段 → rejected
  active/promoted → degraded → rolled_back
  ```

  补丁纪律：**小**（最小相关单元）、**有据**（指向事件日志具体证据）、
  **带 before/after 快照**。禁止把无关变更揉成"自动更新"。

  每个 Change 必须能回答（§15.10）：谁、何时、基于哪条证据、
  改了哪个 release、如何回退。
  """

  @statuses ~w(requested building evaluating canary active rejected degraded rolled_back promoted)a

  defstruct change_id: nil,
            base_revision: 0,
            candidate_revision: nil,
            changes: [],
            reason: nil,
            evidence: [],
            request_id: nil,
            author_agent: :system,
            expected_version: nil,
            attempt: 1,
            deadline: nil,
            evaluation_plan: %{},
            evaluation_result: nil,
            rollback_of: nil,
            human_brief: nil,
            status: :requested,
            created_at: nil,
            updated_at: nil

  @type t :: %__MODULE__{}

  def statuses, do: @statuses

  def new(attrs) do
    attrs = Map.new(attrs)
    now = now_iso()

    %__MODULE__{
      change_id: Map.get(attrs, :change_id) || gen_id(),
      base_revision: Map.get(attrs, :base_revision, 0),
      candidate_revision: Map.get(attrs, :candidate_revision),
      changes: Map.get(attrs, :changes, []),
      reason: Map.get(attrs, :reason),
      evidence: Map.get(attrs, :evidence, []),
      request_id: Map.get(attrs, :request_id),
      author_agent: to_atom(Map.get(attrs, :author_agent, :system)),
      expected_version: Map.get(attrs, :expected_version),
      attempt: Map.get(attrs, :attempt, 1),
      deadline: Map.get(attrs, :deadline),
      evaluation_plan: Map.get(attrs, :evaluation_plan, %{}),
      evaluation_result: Map.get(attrs, :evaluation_result),
      rollback_of: Map.get(attrs, :rollback_of),
      human_brief: Map.get(attrs, :human_brief),
      status: to_atom(Map.get(attrs, :status, :requested)),
      created_at: Map.get(attrs, :created_at) || now,
      updated_at: Map.get(attrs, :updated_at) || now
    }
  end

  def transition(%__MODULE__{} = c, status) when status in @statuses do
    %{c | status: status, updated_at: now_iso()}
  end

  @doc "终态？"
  def terminal?(%__MODULE__{status: s}), do: s in [:rejected, :rolled_back, :promoted]

  @doc "可激活？（仅 evaluating/canary 通过评测后）"
  def activatable?(%__MODULE__{status: s}), do: s in [:canary, :evaluating]

  def gen_id, do: "chg_" <> (:crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower))

  def to_map(%__MODULE__{} = c) do
    %{
      "change_id" => c.change_id,
      "base_revision" => c.base_revision,
      "candidate_revision" => c.candidate_revision,
      "changes" => c.changes,
      "reason" => c.reason,
      "evidence" => c.evidence,
      "request_id" => c.request_id,
      "author_agent" => to_string(c.author_agent),
      "expected_version" => c.expected_version,
      "attempt" => c.attempt,
      "deadline" => c.deadline,
      "evaluation_plan" => c.evaluation_plan,
      "evaluation_result" => c.evaluation_result,
      "rollback_of" => c.rollback_of,
      "human_brief" => c.human_brief,
      "status" => to_string(c.status),
      "created_at" => c.created_at,
      "updated_at" => c.updated_at
    }
  end

  def from_map(m) when is_map(m) do
    %__MODULE__{
      change_id: m["change_id"],
      base_revision: m["base_revision"] || 0,
      candidate_revision: m["candidate_revision"],
      changes: m["changes"] || [],
      reason: m["reason"],
      evidence: m["evidence"] || [],
      request_id: m["request_id"],
      author_agent: to_atom(m["author_agent"] || "system"),
      expected_version: m["expected_version"],
      attempt: m["attempt"] || 1,
      deadline: m["deadline"],
      evaluation_plan: m["evaluation_plan"] || %{},
      evaluation_result: m["evaluation_result"],
      rollback_of: m["rollback_of"],
      human_brief: m["human_brief"],
      status: to_atom(m["status"] || "requested"),
      created_at: m["created_at"],
      updated_at: m["updated_at"]
    }
  end

  defp to_atom(a) when is_atom(a), do: a
  defp to_atom(s) when is_binary(s), do: String.to_atom(s)

  defp now_iso, do: DateTime.utc_now() |> DateTime.to_iso8601()
end
