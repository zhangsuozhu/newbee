defmodule Newbee.Tools.Hive do
  @moduledoc """
  持久协作 API：revision CAS Board、DAG、事件等待和 Lead 验收。

  worker 只能提交 `submitted`，不能改任务契约；`succeeded` 仅由 Lead 在主节点运行
  结构化验收后写入，调用方不能传 attestation。command 验收会执行项目代码、仅 Lead
  可创建，不是 sandbox。`write_scope` 是冲突诊断，不是锁。Persona、fork 和派生/载荷
  均有硬上限；capability 绑定正常工具调用身份，不隔离任意 BEAM/RPC 代码。

  ## 可跑示例
      {:ok, g} = Newbee.Tools.Hive.open("认证重构")
      {:ok, _} = Newbee.Tools.Hive.delegate(g["group_id"], "补测试", acceptance: checks)
      {:ok, b} = Newbee.Tools.Hive.board(g["group_id"])
      Newbee.Tools.Hive.board_put(gid, task)
      Newbee.Tools.Hive.board_claim(gid, tid, rev)
      Newbee.Tools.Hive.report(gid, tid, :submitted, expected_revision: rev, result: "done")
      Newbee.Tools.Hive.verify(gid, tid)
      Newbee.Tools.Hive.wait(gid, since_revision: rev)
      Newbee.Tools.Hive.send(gid, sid, "复核")
      Newbee.Tools.Hive.inbox(gid)
      Newbee.Tools.Hive.roster(gid)
      Newbee.Tools.Hive.interrupt(gid, sid)
      Newbee.Tools.Hive.close(gid, sid)
      Newbee.Tools.Hive.personas()
  """

  @context_key {Newbee.Tools.Collaboration, :context}
  @report_statuses ~w(accepted running blocked submitted failed cancelled)

  @doc "建立协作组；opts 支持 goal/project_root/max_depth/max_total。"
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

  def open(_, _), do: {:error, "bad_request", "title 必须是字符串且 opts 必须是 keyword list"}

  @doc "派生真实子会话；必须给结构化 acceptance。opts 支持 persona/fork_turns/depends_on/write_scope/isolate。"
  def delegate(group_id, title, opts \\ [])

  def delegate(group_id, title, opts)
      when is_binary(group_id) and is_binary(title) and is_list(opts) do
    with {:ok, identity} <- identity(),
         {:ok, persona} <- Newbee.Collaboration.Persona.resolve(Keyword.get(opts, :persona, "worker")),
         {:ok, acceptance} <- Newbee.Collaboration.Verification.normalize_contract(Keyword.get(opts, :acceptance)),
         {:ok, group} <- host_call(Newbee.Collaboration.Coordinator, :get, [group_id]),
         :ok <- command_acceptance_authorized(group, identity.session_id, acceptance) do
      host_call(Newbee.Collaboration.Delegator, :delegate, [
        group_id,
        identity.session_id,
        title,
        [
          name: Keyword.get(opts, :name, title),
          role: persona["role"],
          persona_profile: Newbee.Collaboration.Persona.session_profile(persona),
          protocol_version: 2,
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

  def delegate(_, _, _), do: {:error, "bad_request", "group_id/title 必须是字符串且 opts 必须是 keyword list"}

  @doc "读取当前成员可见的权威 Board（revision/tasks/write_scope_overlaps）。"
  def board(group_id) when is_binary(group_id) do
    with {:ok, identity} <- identity() do
      host_call(Newbee.Collaboration.Coordinator, :board, [group_id, identity.session_id])
    end
  end

  def board(_), do: {:error, "bad_request", "group_id 必须是字符串"}

  @doc "创建或更新任务；map 必须携带 expected_revision，更新时再带 task_id；执行者不能改任务契约。"
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

  def board_put(_, _), do: {:error, "bad_request", "group_id 必须是字符串且 attrs 必须是 map"}

  @doc "用 Board revision 原子认领任务；依赖未完成时拒绝。"
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

  def board_claim(_, _, _), do: {:error, "bad_request", "group_id/task_id 必须是字符串且 revision 必须是整数"}

  @doc "报告状态；worker 完成用 :submitted，不能直接 succeeded。opts 必须含 expected_revision。"
  def report(group_id, task_id, status, opts \\ [])

  def report(group_id, task_id, status, opts)
      when is_binary(group_id) and is_binary(task_id) and status in @report_statuses and
             is_list(opts) do
    with {:ok, identity} <- identity() do
      host_call(Newbee.Collaboration.Coordinator, :board_update_task, [
        group_id,
        task_id,
        %{
          "session_id" => identity.session_id,
          "expected_revision" => Keyword.get(opts, :expected_revision),
          "status" => to_string(status),
          "progress" => Keyword.get(opts, :progress),
          "result" => Keyword.get(opts, :result),
          "evidence" => Keyword.get(opts, :evidence),
          "command_id" => Keyword.get(opts, :command_id) || command_id("hive-report")
        }
      ])
    end
  end

  def report(_, _, _, _), do: {:error, "bad_request", "Hive 状态无效"}

  @doc "Lead 在受信主节点运行结构化验收；不接收调用方证明，执行后以 Board revision CAS 提交。"
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

  def verify(_, _), do: {:error, "bad_request", "group_id 和 task_id 必须是字符串"}

  @doc "等待 revision 边沿；不会轮询。opts: since_revision（必填）、timeout_ms。"
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
      :error -> {:error, "bad_request", "wait 必须提供 since_revision"}
      false -> {:error, "bad_request", "since_revision 必须是非负整数"}
      {:error, _, _} = error -> error
      other -> {:error, "wait_failed", inspect(other)}
    end
  end

  def wait(_, _), do: {:error, "bad_request", "group_id 必须是字符串且 opts 必须是 keyword list"}

  @doc "发送可靠消息。wake:false 只落时间线；wake:true 才触发目标模型 turn。"
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

  def send(_, _, _, _), do: {:error, "bad_request", "消息参数类型无效"}

  @doc "读取发给当前会话或广播的消息；opts: since_seq。"
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

  def inbox(_, _), do: {:error, "bad_request", "group_id 必须是字符串且 opts 必须是 keyword list"}

  @doc "读取组名册；非成员拒绝。"
  def roster(group_id) when is_binary(group_id) do
    with {:ok, identity} <- identity(),
         true <- host_call(Newbee.Collaboration.Coordinator, :member?, [group_id, identity.session_id]) do
      with {:ok, group} <- host_call(Newbee.Collaboration.Coordinator, :get, [group_id]),
           do: {:ok, group["members"]}
    else
      false -> {:error, "not_member", "当前会话不属于该组"}
      error -> error
    end
  end

  def roster(_), do: {:error, "bad_request", "group_id 必须是字符串"}

  @doc "仅 Lead 或目标直接父会话可中断；保留任务和消息。"
  def interrupt(group_id, target_session_id)
      when is_binary(group_id) and is_binary(target_session_id) do
    with {:ok, identity} <- identity(),
         {:ok, group} <- host_call(Newbee.Collaboration.Coordinator, :get, [group_id]),
         :ok <- lifecycle_authorized(group, identity.session_id, target_session_id),
         {:ok, pid} <- Newbee.Web.Session.lookup(target_session_id) do
      :ok = Newbee.Web.Session.interrupt(pid)
      {:ok, %{"interrupted" => target_session_id}}
    else
      {:error, :not_found} -> {:error, "not_found", "目标会话未运行"}
      error -> error
    end
  end

  def interrupt(_, _), do: {:error, "bad_request", "group_id 和 target_session_id 必须是字符串"}

  @doc "Lead 显式移除已无活动任务/子代的成员，并销毁其会话进程。"
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
      _ = Newbee.Web.Session.destroy(target_session_id)
      {:ok, member}
    end
  end

  def close(_, _), do: {:error, "bad_request", "group_id 和 target_session_id 必须是字符串"}

  @doc "列出严格校验后可解析的 persona 名。"
  def personas, do: Newbee.Collaboration.Persona.list()

  defp identity do
    case Process.get(@context_key) do
      %{capability: token} when is_binary(token) ->
        host_call(Newbee.Collaboration.Capability, :resolve, [token])

      _ ->
        {:error, "no_execution_context", "Hive 必须运行在 Agent.Loop 签发的 capability 上下文中"}
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
      do: {:error, "command_acceptance_forbidden", "只有 Lead 可创建 command 验收项"},
      else: :ok
  end

  defp lifecycle_authorized(group, actor, target) do
    member = Enum.find(group["members"] || [], &(&1["session_id"] == target))

    cond do
      is_nil(member) -> {:error, "not_member", "目标不属于该组"}
      actor == group["coordinator_session_id"] -> :ok
      actor == member["parent_session_id"] -> :ok
      true -> {:error, "forbidden_role", "只有 Lead 或直接父会话可中断目标"}
    end
  end

  defp normalize_wait_timeout(timeout) when is_integer(timeout),
    do: timeout |> max(1_000) |> min(120_000)

  defp normalize_wait_timeout(_timeout), do: 30_000

  defp command_id(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"
  defp host_call(module, function, args), do: Newbee.Host.call(module, function, args)

  defp host_call(module, function, args, timeout),
    do: Newbee.Host.call(module, function, args, timeout)
end
