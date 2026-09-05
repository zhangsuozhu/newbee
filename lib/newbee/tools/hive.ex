defmodule Newbee.Tools.Hive do
  @moduledoc """
  Persistent collaboration: revision-CAS Board, DAG, event waits, Lead acceptance.

  Workers may only submit `submitted`, never rewrite task contracts; `succeeded` is written solely by the Lead
  after running structured acceptance on the host node — callers pass no attestation. Command acceptance executes
  project code and only the Lead may create it; it is not a sandbox. `write_scope` diagnoses conflicts, it is not
  a lock. Personas, forks, and spawn/payload sizes all have hard caps; capabilities bind normal tool-call identity,
  they don't isolate arbitrary BEAM/RPC code.

  ## Runnable example
      {:ok, g} = Newbee.Tools.Hive.open("Auth refactor")
      {:ok, _} = Newbee.Tools.Hive.delegate(g["group_id"], "Add tests", acceptance: checks)
      {:ok, b} = Newbee.Tools.Hive.board(g["group_id"])
      Newbee.Tools.Hive.board_put(gid, task)
      Newbee.Tools.Hive.board_claim(gid, tid, rev)
      Newbee.Tools.Hive.report(gid, tid, "submitted", expected_revision: rev, result: "done")
      Newbee.Tools.Hive.retry(gid, tid, expected_revision: b["revision"], reason: "retry after interruption")

      Newbee.Tools.Hive.verify(gid, tid)
      Newbee.Tools.Hive.wait(gid, since_revision: rev)
      Newbee.Tools.Hive.send(gid, sid, "Review")
      Newbee.Tools.Hive.inbox(gid)
      Newbee.Tools.Hive.roster(gid)
      Newbee.Tools.Hive.interrupt(gid, sid)
      Newbee.Tools.Hive.close(gid, sid)
      Newbee.Tools.Hive.personas()
  """
  @context_key {Newbee.Tools.Hive, :context}
  @report_statuses ~w(accepted running blocked submitted failed cancelled)

  @doc "Open a collaboration group; opts take goal/project_root/max_depth/max_total."
  def open(title, opts \\ [])

  def open(title, opts) when is_binary(title) and is_list(opts) do
    with {:ok, identity} <- identity() do
      host_call(Newbee.Collaboration.Coordinator, :create_group, [
        %{
          "session_id" => identity.session_id,
          "title" => title,
          "goal" => Keyword.get(opts, :goal, title),
          "project_root" => Keyword.get(opts, :project_root, identity.project_root),
          "max_depth" => Keyword.get(opts, :max_depth, 3),
          "max_total" => Keyword.get(opts, :max_total, 12),
          "command_id" => Keyword.get(opts, :command_id) || command_id("hive-open")
        }
      ])
    end
  end

  def open(_, _), do: {:error, "bad_request", "title must be a text and opts a keyword list"}

  @doc "Spawn a real subsession; structured acceptance and Board revision CAS are required. Opts take persona/fork_turns/depends_on/write_scope/isolate/expected_revision."
  def delegate(group_id, title, opts \\ [])

  def delegate(group_id, title, opts)
      when is_binary(group_id) and is_binary(title) and is_list(opts) do
    with {:ok, identity} <- identity(),
         {:ok, persona} <- Newbee.Collaboration.Persona.resolve(Keyword.get(opts, :persona, "worker")),
         {:ok, acceptance} <- Newbee.Collaboration.Verification.normalize_contract(Keyword.get(opts, :acceptance)),
         {:ok, group} <- host_call(Newbee.Collaboration.Coordinator, :get, [group_id]),
         {:ok, board} <- host_call(Newbee.Collaboration.Coordinator, :board, [group_id, identity.session_id]),
         :ok <- command_acceptance_authorized(group, identity.session_id, acceptance) do
      expected_revision = Keyword.get(opts, :expected_revision, board["revision"])

      host_call(Newbee.Collaboration.Delegator, :delegate, [
        group_id,
        identity.session_id,
        title,
        [
          name: Keyword.get(opts, :name, title),
          role: persona["role"],
          persona_profile: Newbee.Collaboration.Persona.session_profile(persona),
          protocol_version: 2,
          expected_revision: expected_revision,
          fork_turns: Keyword.get(opts, :fork_turns, :none),
          description: Keyword.get(opts, :description, title),
          acceptance: acceptance,
          depends_on: Keyword.get(opts, :depends_on, []),
          write_scope: Keyword.get(opts, :write_scope, []),
          isolate: Keyword.get(opts, :isolate, :auto),
          command_id: Keyword.get(opts, :command_id) || command_id("hive-delegate")
        ]
      ])
    end
  end

  def delegate(_, _, _), do: {:error, "bad_request", "group_id/title must be texts and opts a keyword list"}

  @doc "Read the authoritative Board visible to current members (revision/tasks/write_scope_overlaps)."
  def board(group_id) when is_binary(group_id) do
    with {:ok, identity} <- identity() do
      host_call(Newbee.Collaboration.Coordinator, :board, [group_id, identity.session_id])
    end
  end

  def board(_), do: {:error, "bad_request", "group_id must be a text"}

  @doc "Create or update a task; maps must carry expected_revision, plus task_id on update; executors can't rewrite task contracts."
  def board_put(group_id, attrs) when is_binary(group_id) and is_map(attrs) do
    with {:ok, identity} <- identity() do
      attrs = put_identity(attrs, identity.session_id) |> put_command("hive-board")

      case attrs["task_id"] || attrs[:task_id] do
        task_id when is_binary(task_id) ->
          host_call(Newbee.Collaboration.Coordinator, :board_update_task, [group_id, task_id, attrs])

        _ ->
          host_call(Newbee.Collaboration.Coordinator, :board_create_task, [group_id, attrs])
      end
    end
  end

  def board_put(_, _), do: {:error, "bad_request", "group_id must be a text and attrs a map"}

  @doc "Atomically claim a task at a Board revision; refused while dependencies are open."
  def board_claim(group_id, task_id, expected_revision)
      when is_binary(group_id) and is_binary(task_id) and is_integer(expected_revision) do
    with {:ok, identity} <- identity() do
      host_call(Newbee.Collaboration.Coordinator, :board_claim, [
        group_id,
        task_id,
        %{
          "session_id" => identity.session_id,
          "expected_revision" => expected_revision,
          "command_id" => command_id("hive-claim")
        }
      ])
    end
  end

  def board_claim(_, _, _), do: {:error, "bad_request", "group_id/task_id must be texts and revision an integer"}

  @doc "Retry a blocked, failed, or cancelled task using the current Board revision. Only the Lead is authorized by Coordinator."
  def retry(group_id, task_id, opts \\ [])

  def retry(group_id, task_id, opts)
      when is_binary(group_id) and is_binary(task_id) and is_list(opts) do
    with {:ok, identity} <- identity(),
         {:ok, board} <-
           host_call(Newbee.Collaboration.Coordinator, :board, [group_id, identity.session_id]),
         expected_revision <- Keyword.get(opts, :expected_revision, board["revision"]),
         :ok <- valid_revision(expected_revision),
         reason <- Keyword.get(opts, :reason, "manual retry"),
         :ok <- valid_reason(reason) do
      host_call(Newbee.Collaboration.Coordinator, :board_retry, [
        group_id,
        task_id,
        %{
          "session_id" => identity.session_id,
          "expected_revision" => expected_revision,
          "command_id" => Keyword.get(opts, :command_id) || command_id("hive-retry"),
          "reason" => reason
        }
      ])
    end
  end

  def retry(_, _, _), do: {:error, "bad_request", "group_id/task_id must be texts and opts a keyword list"}

  @doc "Report an atom or string status; workers finish with :submitted, never succeeded directly. Opts must carry expected_revision."
  def report(group_id, task_id, status, opts \\ [])

  def report(group_id, task_id, status, opts)
      when is_binary(group_id) and is_binary(task_id) and
             (is_atom(status) or is_binary(status)) and is_list(opts) do
    with true <- to_string(status) in @report_statuses or {:error, "bad_request", "invalid Hive status"},
         {:ok, identity} <- identity() do
      attrs = %{
        "session_id" => identity.session_id,
        "expected_revision" => Keyword.get(opts, :expected_revision),
        "status" => to_string(status),
        "progress" => Keyword.get(opts, :progress),
        "result" => Keyword.get(opts, :result),
        "evidence" => Keyword.get(opts, :evidence),
        "command_id" => Keyword.get(opts, :command_id) || command_id("hive-report")
      }

      attrs =
        if Keyword.has_key?(opts, :expected_attempt),
          do: Map.put(attrs, "expected_attempt", Keyword.get(opts, :expected_attempt)),
          else: attrs

      host_call(Newbee.Collaboration.Coordinator, :board_update_task, [group_id, task_id, attrs])
    end
  end

  def report(_, _, _, _), do: {:error, "bad_request", "invalid Hive status"}

  @doc "The Lead runs structured acceptance on the trusted host node; caller attestations rejected, commits via Board revision CAS after execution."
  def verify(group_id, task_id) when is_binary(group_id) and is_binary(task_id) do
    with {:ok, identity} <- identity(),
         {:ok, board} <-
           host_call(Newbee.Collaboration.Coordinator, :board, [
             group_id,
             identity.session_id
           ]) do
      host_call(
        Newbee.Collaboration.Coordinator,
        :board_verify,
        [
          group_id,
          task_id,
          %{
            "session_id" => identity.session_id,
            "expected_revision" => board["revision"],
            "command_id" => command_id("hive-verify")
          }
        ],
        650_000
      )
    end
  end

  def verify(_, _), do: {:error, "bad_request", "group_id and task_id must be texts"}

  @doc "Wait on a revision edge; never polls. Opts: since_revision (required), timeout_ms."
  def wait(group_id, opts \\ [])

  def wait(group_id, opts) when is_binary(group_id) and is_list(opts) do
    with {:ok, identity} <- identity(),
         {:ok, revision} <- Keyword.fetch(opts, :since_revision),
         true <- is_integer(revision) and revision >= 0 do
      timeout = normalize_wait_timeout(Keyword.get(opts, :timeout_ms, 30_000))

      host_call(
        Newbee.Collaboration.Coordinator,
        :wait,
        [group_id, identity.session_id, revision, timeout],
        timeout + 5_000
      )
    else
      :error -> {:error, "bad_request", "wait requires since_revision"}
      false -> {:error, "bad_request", "since_revision must be a non-negative integer"}
      {:error, _, _} = error -> error
      other -> {:error, "wait_failed", inspect(other)}
    end
  end

  def wait(_, _), do: {:error, "bad_request", "group_id must be a text and opts a keyword list"}

  @doc "Send a reliable message. wake:false lands on the timeline only; wake:true triggers the target model's turn."
  def send(group_id, to_session_id, body, opts \\ [])

  def send(group_id, to_session_id, body, opts)
      when is_binary(group_id) and (is_binary(to_session_id) or is_nil(to_session_id)) and
             is_binary(body) and is_list(opts) do
    with {:ok, identity} <- identity() do
      host_call(Newbee.Collaboration.Coordinator, :send_message, [
        group_id,
        %{
          "sender_session_id" => identity.session_id,
          "to_session_id" => to_session_id,
          "kind" => to_string(Keyword.get(opts, :kind, :chat)),
          "delivery" => if(Keyword.get(opts, :wake, false), do: "wake", else: "notify"),
          "body" => body,
          "message_id" => Keyword.get(opts, :message_id),
          "command_id" => Keyword.get(opts, :command_id) || command_id("hive-message")
        }
      ])
    end
  end

  def send(_, _, _, _), do: {:error, "bad_request", "invalid message arg types"}

  @doc "Read messages to the current session or broadcasts; opts: since_seq."
  def inbox(group_id, opts \\ [])

  def inbox(group_id, opts) when is_binary(group_id) and is_list(opts) do
    with {:ok, identity} <- identity() do
      host_call(Newbee.Collaboration.Coordinator, :inbox, [
        group_id,
        identity.session_id,
        Keyword.get(opts, :since_seq, 0)
      ])
    end
  end

  def inbox(_, _), do: {:error, "bad_request", "group_id must be a text and opts a keyword list"}

  @doc "Read the group roster; non-members refused."
  def roster(group_id) when is_binary(group_id) do
    with {:ok, identity} <- identity(),
         true <- host_call(Newbee.Collaboration.Coordinator, :member?, [group_id, identity.session_id]) do
      with {:ok, group} <- host_call(Newbee.Collaboration.Coordinator, :get, [group_id]),
           do: {:ok, group["members"]}
    else
      false -> {:error, "not_member", "current session is not in that group"}
      error -> error
    end
  end

  def roster(_), do: {:error, "bad_request", "group_id must be a text"}

  @doc "Only the Lead or the target's direct parent session may interrupt; tasks and messages survive."
  def interrupt(group_id, target_session_id)
      when is_binary(group_id) and is_binary(target_session_id) do
    with {:ok, identity} <- identity(),
         {:ok, group} <- host_call(Newbee.Collaboration.Coordinator, :get, [group_id]),
         :ok <- lifecycle_authorized(group, identity.session_id, target_session_id),
         {:ok, pid} <- host_call(Newbee.Web.Session, :lookup, [target_session_id]) do
      :ok = host_call(Newbee.Web.Session, :interrupt, [pid])
      {:ok, %{"interrupted" => target_session_id}}
    else
      {:error, :not_found} -> {:error, "not_found", "target session not running"}
      error -> error
    end
  end

  def interrupt(_, _), do: {:error, "bad_request", "group_id and target_session_id must be texts"}

  @doc "The Lead explicitly removes members with no live tasks/children and destroys their session processes."
  def close(group_id, target_session_id)
      when is_binary(group_id) and is_binary(target_session_id) do
    with {:ok, identity} <- identity(),
         {:ok, member} <-
           host_call(Newbee.Collaboration.Coordinator, :remove_member, [
             group_id,
             %{
               "session_id" => target_session_id,
               "actor_session_id" => identity.session_id,
               "command_id" => command_id("hive-close")
             }
           ]) do
      _ = host_call(Newbee.Web.Session, :destroy, [target_session_id])
      {:ok, member}
    end
  end

  def close(_, _), do: {:error, "bad_request", "group_id and target_session_id must be texts"}

  @doc "List strictly validated, resolvable persona names."
  def personas, do: Newbee.Collaboration.Persona.list()

  defp identity do
    case Process.get(@context_key) do
      %{capability: token} when is_binary(token) ->
        host_call(Newbee.Collaboration.Capability, :resolve, [token])

      _ ->
        {:error, "no_execution_context", "Hive must run under a capability context issued by Agent.Loop"}
    end
  end

  defp put_identity(attrs, session_id) do
    attrs |> Map.put("session_id", session_id)
  end

  defp put_command(attrs, prefix) do
    if attrs["command_id"] || attrs[:command_id],
      do: attrs,
      else: Map.put(attrs, "command_id", command_id(prefix))
  end

  defp command_acceptance_authorized(group, actor, acceptance) do
    command? = Enum.any?(acceptance, &(&1["kind"] == "command"))

    if command? and actor != group["coordinator_session_id"],
      do: {:error, "command_acceptance_forbidden", "only the Lead may create command acceptance items"},
      else: :ok
  end

  defp lifecycle_authorized(group, actor, target) do
    member = Enum.find(group["members"] || [], &(&1["session_id"] == target))

    cond do
      is_nil(member) -> {:error, "not_member", "target is not in that group"}
      actor == group["coordinator_session_id"] -> :ok
      actor == member["parent_session_id"] -> :ok
      true -> {:error, "forbidden_role", "only the Lead or a direct parent session may interrupt the target"}
    end
  end

  defp valid_revision(revision) when is_integer(revision) and revision >= 0, do: :ok
  defp valid_revision(_), do: {:error, "bad_request", "expected_revision must be a non-negative integer"}

  defp valid_reason(reason) when is_binary(reason) do
    if String.trim(reason) == "",
      do: {:error, "bad_request", "reason must be a non-empty text"},
      else: :ok
  end

  defp valid_reason(_), do: {:error, "bad_request", "reason must be a non-empty text"}

  defp normalize_wait_timeout(timeout) when is_integer(timeout),
    do: timeout |> max(1_000) |> min(120_000)

  defp normalize_wait_timeout(_timeout), do: 30_000

  defp command_id(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"
  defp host_call(module, function, args), do: Newbee.Host.call(module, function, args)

  defp host_call(module, function, args, timeout),
    do: Newbee.Host.call(module, function, args, timeout)
end
