defmodule Newbee.Tools.Collaboration do
  @moduledoc """
  会话群协作：派生子代理、报告任务、发消息。

  ## 函数清单
  - `delegate(title, opts \\\\ [])` — 从当前模型会话受控派生子代理并分派任务，返回 `{:ok, %{session_id, member, task, cwd}}`。
  - `report(group_id, task_id, session_id, status, opts \\\\ [])` — 报告任务状态，返回 Coordinator update 结果。
  - `renew(group_id, task_id, session_id, seconds \\\\ 300)` — 续期任务租约。
  - `tasks(group_id)` — 列出群内任务。
  - `send_message(group_id, session_id, body, opts \\\\ [])` — 向群成员发送消息。

  ## 可跑示例
      {:ok, r} = Newbee.Tools.Collaboration.delegate("修 bug", description: "复现并修复")
      :ok = Newbee.Tools.Collaboration.report("g1", "t1", "s1", :running, progress: 50)
      Newbee.Tools.Collaboration.renew("g1", "t1", "s1", 600)
      Newbee.Tools.Collaboration.tasks("g1")
      :ok = Newbee.Tools.Collaboration.send_message("g1", "s1", "hello", to: "s2", delivery: :notify)

  调用方身份由 Agent.Loop 的执行上下文提供，参数不能冒充其它会话。
  """

  @statuses [:accepted, :running, :blocked, :succeeded, :failed, :cancelled]
  @context_key {__MODULE__, :context}

  @doc """
  从当前模型会话受控派生一个子代理并分派任务。

  发送者身份由 Agent.Loop 设置的短生命周期执行上下文提供，调用参数不能冒充
  其它会话。子代理自动加入当前工作组；没有工作组时返回 no_group，需由用户或
  上层会话先创建工作组。返回 child_session_id、member、task 和 cwd。
  """
  def delegate(title, opts \\ []) when is_binary(title) do
    case Process.get(@context_key) do
      %{session_id: parent_sid, project_root: project_root} when is_binary(parent_sid) ->
        with {:ok, group} <- ensure_group(parent_sid, title),
             {:ok, group_detail} <- Newbee.Host.call(Newbee.Collaboration.Coordinator, :get, [group["group_id"]]),
             # 模型不能指定 session_id：运行时生成，避免身份冒充和 worktree 路径穿越
             child_sid <- Newbee.Host.call(Newbee.Web.Session, :gen_session_id, []),
             root <- project_root || group_detail["project_root"],
             {:ok, child_root} <- prepare_child_root(root, child_sid, Keyword.get(opts, :isolate, true)),
             {:ok, _pid, ^child_sid} <-
               Newbee.Host.call(Newbee.Web.Session, :ensure, [child_sid, child_root]),
             :ok <- Newbee.Host.call(Newbee.Session, :mark_created, [child_sid]),
             :ok <- Newbee.Host.call(Newbee.Session, :rename, [child_sid, Keyword.get(opts, :name) || title]),
             {:ok, member} <-
               Newbee.Host.call(Newbee.Collaboration.Coordinator, :add_member, [
                 group["group_id"],
                 %{
                   "session_id" => child_sid,
                   "role" => to_string(Keyword.get(opts, :role, "worker")),
                   "parent_session_id" => parent_sid,
                   "command_id" => "model-delegate-#{System.unique_integer([:positive])}:member"
                 }
               ]),
             {:ok, task} <-
               Newbee.Host.call(Newbee.Collaboration.Coordinator, :create_task, [
                 group["group_id"],
                 %{
                   "created_by_session_id" => parent_sid,
                   "assigned_session_id" => child_sid,
                   "title" => title,
                   "description" => Keyword.get(opts, :description),
                   "acceptance" => Keyword.get(opts, :acceptance),
                   "command_id" => "model-delegate-#{System.unique_integer([:positive])}:task"
                 }
               ]) do
          {:ok,
           %{
             session_id: child_sid,
             member: member,
             task: task,
             cwd: Newbee.Host.call(Newbee.Session, :cwd, [child_sid])
           }}
        else
          {:error, code, message} -> {:error, code, message}
          other -> {:error, "delegate_failed", inspect(other)}
        end

      _ ->
        {:error, "no_execution_context", "只能从模型会话的 run_elixir 执行上下文派生子代理"}
    end
  end

  defp ensure_group(parent_sid, title) do
    case Newbee.Host.call(Newbee.Collaboration.Coordinator, :groups_for_session, [parent_sid]) do
      [group | _] ->
        {:ok, group}

      [] ->
        case Newbee.Host.call(Newbee.Collaboration.Coordinator, :create_group, [
               %{
                 "session_id" => parent_sid,
                 "title" => "模型协作：#{String.slice(title, 0, 48)}",
                 "goal" => title,
                 "command_id" => "model-group-#{System.unique_integer([:positive])}"
               }
             ]) do
          {:ok, group} -> {:ok, group}
          {:error, code, message} -> {:error, code, message}
        end
    end
  end

  defp prepare_child_root(root, _child_sid, false), do: {:ok, root}

  defp prepare_child_root(root, child_sid, true) when is_binary(root) do
    path = Path.join([root, ".newbee", "worktrees", child_sid])
    File.mkdir_p!(Path.dirname(path))

    case Newbee.Host.call(Newbee.Tools.Git, :worktree_add, [root, path, "HEAD"]) do
      {:ok, _} -> {:ok, path}
      {:error, {_code, output}} -> {:error, "worktree_error", output}
    end
  rescue
    e -> {:error, "worktree_error", Exception.message(e)}
  end

  @doc "报告任务状态（accepted/running/blocked/succeeded/failed/cancelled），可带 progress/result。"
  def report(group_id, task_id, session_id, status, opts \\ []) do
    if status not in @statuses do
      {:error, "bad_request", "未知任务状态"}
    else
      attrs = %{
        "session_id" => session_id,
        "status" => to_string(status),
        "progress" => Keyword.get(opts, :progress),
        "result" => Keyword.get(opts, :result),
        "command_id" => Keyword.get(opts, :command_id)
      }

      Newbee.Host.call(Newbee.Collaboration.Coordinator, :update_task, [group_id, task_id, attrs])
    end
  end

  @doc "续期任务租约（秒），默认 300。"
  def renew(group_id, task_id, session_id, seconds \\ 300) do
    Newbee.Host.call(Newbee.Collaboration.Coordinator, :renew_task, [group_id, task_id, session_id, seconds])
  end

  @doc "列出群内全部任务。"
  def tasks(group_id) when is_binary(group_id) do
    Newbee.Host.call(Newbee.Collaboration.Coordinator, :tasks, [group_id])
  end

  @doc """
  向群成员发送消息。

  选项 `:delivery` 控制投递方式：

    * `:notify` - 只写入协作时间线，不打扰目标会话的模型
    * `:queue`  - 投递给目标会话，忙时排队、空闲立即处理（默认预算安全）
    * `:wake`   - 语义同 `:queue`，不强行打断当前工具调用
  """
  def send_message(group_id, session_id, body, opts \\ []) do
    attrs = %{
      "sender_session_id" => session_id,
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
