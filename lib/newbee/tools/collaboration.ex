defmodule Newbee.Tools.Collaboration do
  @moduledoc """
  Group collaboration (legacy): split parallel tasks. Prefer Hive.

  ## When to delegate

  Delegate when a task splits, parallelizes, would pollute the mainline context, or needs a different role's eyes.
  Don't spawn for single-step tweaks or tightly integrated edits.

  delegate returns `%{session_id, group_id, task_id}`. The subagent runs on its own;
  you don't block on it — follow up by polling `tasks/1` or pinging point-to-point with `send_message/4`.
  Subagents must `report/5` before finishing.

  ## Leases

  A subagent holds its task on a 5-minute lease by default; long tasks must periodically `renew/4` or lose it.
  The mainline never renews for them.

  ## Message addressing

  `send_message(group_id, sid, body)` is point-to-point; `to: nil` broadcasts.
  Broadcast status reports and help requests; point-to-point for follow-ups and private context.

  ## Isolation

  `isolate: :auto` gives each subagent its own project copy by default, reviewed + applied by the coordinator before finishing;
  non-Git projects share instead. Don't reach for `isolate: false`.

  ## Functions

  - `delegate(title, opts \\\\ [])` — spawn a subagent; opts: `name:/role:/description:/acceptance:/isolate:`
  - `claim_task(group_id, task_id)` — claim a task under the current session and take its lease
  - `report(group_id, task_id, session_id, status, opts \\\\ [])` — subagents call this
  - `renew(group_id, task_id, session_id, seconds \\\\ 300)` — subagent lease renewal
  - `tasks(group_id)` — list a group's tasks
  - `send_message(group_id, session_id, body, opts \\\\ [])` — send a message; opts: `to:/kind:/delivery:`


  ## Safety constraints

  - Identity comes from a short-lived capability token issued by Agent.Loop; no impersonating other sessions
  - Tokenless calls are all refused with `{:error, "no_execution_context", _}`
  - Each session sees only its own groups

  ## Runnable example
    Newbee.Tools.Collaboration.delegate("Fix token expiry path", name: "auth fix", role: "worker")
    Newbee.Tools.Collaboration.delegate("Add concurrency tests", name: "concurrency tests", role: "tester")
    {:ok, _task} = Newbee.Tools.Collaboration.claim_task("g1", "t1")
    Newbee.Tools.Collaboration.report("g1", "t1", "s1", :accepted)

    Newbee.Tools.Collaboration.report("g1", "t1", "s1", :running, progress: "50%")
    Newbee.Tools.Collaboration.renew("g1", "t1", "s1", 600)
    Newbee.Tools.Collaboration.tasks("g1")
    Newbee.Tools.Collaboration.send_message("g1", "s1", "How is it going?", kind: "question")
  """

  @statuses [:accepted, :running, :blocked, :succeeded, :failed, :cancelled]
  @context_key {__MODULE__, :context}

  @doc "Spawn a controlled subagent from the current model session; builds a work group when none exists."
  def delegate(title, opts \\ []) when is_binary(title) do
    with {:ok, identity} <- collaboration_identity(),
         {:ok, group} <- ensure_group(identity.session_id, identity.project_root, title) do
      Newbee.Host.call(Newbee.Collaboration.Delegator, :delegate, [
        group["group_id"],
        identity.session_id,
        title,
        [
          name: Keyword.get(opts, :name),
          role: to_string(Keyword.get(opts, :role, "worker")),
          description: Keyword.get(opts, :description),
          acceptance: Keyword.get(opts, :acceptance),
          isolate: Keyword.get(opts, :isolate, :auto),
          command_id: Keyword.get(opts, :command_id)
        ]
      ])
    end
  end

  defp ensure_group(parent_sid, project_root, title) do
    groups = Newbee.Host.call(Newbee.Collaboration.Coordinator, :groups_for_session, [parent_sid])

    case Enum.find(groups, &(&1["status"] == "running")) do
      group when is_map(group) ->
        {:ok, group}

      nil ->
        Newbee.Host.call(Newbee.Collaboration.Coordinator, :create_group, [
          %{
            "session_id" => parent_sid,
            "title" => "Model collaboration: #{String.slice(title, 0, 48)}",
            "goal" => title,
            "project_root" => project_root,
            "command_id" => "model-group-#{System.unique_integer([:positive])}"
          }
        ])
    end
  end

  @doc "Report task status (accepted/running/blocked/succeeded/failed/cancelled); takes progress/result."
  def report(group_id, task_id, session_id, status, opts \\ []) do
    with true <- status in @statuses or {:error, "bad_request", "unknown task status"},
         {:ok, identity} <- collaboration_identity(),
         :ok <- same_identity(identity.session_id, session_id) do
      attrs = %{
        "session_id" => identity.session_id,
        "status" => to_string(status),
        "progress" => Keyword.get(opts, :progress),
        "result" => Keyword.get(opts, :result),
        "command_id" => Keyword.get(opts, :command_id)
      }

      Newbee.Host.call(Newbee.Collaboration.Coordinator, :update_task, [group_id, task_id, attrs])
    end
  end

  @doc "Claim a task under the current capability and take its lease."
  def claim_task(group_id, task_id) when is_binary(group_id) and is_binary(task_id) do
    with {:ok, identity} <- collaboration_identity() do
      Newbee.Host.call(Newbee.Collaboration.Coordinator, :claim_task, [
        group_id,
        task_id,
        identity.session_id
      ])
    end
  end

  def claim_task(_group_id, _task_id), do: {:error, "bad_request", "group_id and task_id must be strings"}

  @doc "Renew a task lease (seconds), default 300; claim_task/2 first."
  def renew(group_id, task_id, session_id, seconds \\ 300) do
    with {:ok, identity} <- collaboration_identity(),
         :ok <- same_identity(identity.session_id, session_id) do
      Newbee.Host.call(Newbee.Collaboration.Coordinator, :renew_task, [
        group_id,
        task_id,
        identity.session_id,
        seconds
      ])
    end
  end

  @doc "List every task in the current session's group."
  def tasks(group_id) when is_binary(group_id) do
    with {:ok, identity} <- collaboration_identity(),
         true <-
           Newbee.Host.call(Newbee.Collaboration.Coordinator, :member?, [
             group_id,
             identity.session_id
           ]) or {:error, "not_member", "current session is not in that work group"} do
      Newbee.Host.call(Newbee.Collaboration.Coordinator, :tasks, [group_id])
    end
  end

  @doc """
  Send a message to group members. `:delivery` takes `:notify`, `:queue`, or `:wake`.
  """

  def send_message(group_id, session_id, body, opts \\ []) do
    with {:ok, identity} <- collaboration_identity(),
         :ok <- same_identity(identity.session_id, session_id) do
      attrs = %{
        "sender_session_id" => identity.session_id,
        "to_session_id" => Keyword.get(opts, :to),
        "kind" => to_string(Keyword.get(opts, :kind, :chat)),
        "body" => body,
        "message_id" => Keyword.get(opts, :message_id),
        "command_id" => Keyword.get(opts, :command_id),
        "delivery" => to_string(Keyword.get(opts, :delivery, :notify))
      }

      Newbee.Host.call(Newbee.Collaboration.Coordinator, :send_message, [group_id, attrs])
    end
  end

  defp collaboration_identity do
    case Process.get(@context_key) do
      %{capability: token} when is_binary(token) ->
        Newbee.Host.call(Newbee.Collaboration.Capability, :resolve, [token])

      _ ->
        {:error, "no_execution_context", "collaboration calls must run under a capability context issued by Agent.Loop"}
    end
  end

  defp same_identity(session_id, session_id), do: :ok
  defp same_identity(_, _), do: {:error, "identity_mismatch", "session_id does not match the current model session"}
end
