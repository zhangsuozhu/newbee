defmodule Newbee.Tools.Collaboration do
  @moduledoc """
  会话群协作：把大任务拆给子代理并行干，自己保留主线。

  ## 何时 delegate

  任务可拆、可并行、子任务会污染主线上下文、需要不同角色视角时用。
  单步小改、紧密集成的改动不要派生。

  delegate 返回 `%{session_id, group_id, task_id}`。子代理独立运行，
  你不阻塞等它；跟进用 `tasks/1` 轮询或 `send_message/4` 点对点问。
  子代理被要求完成前必须 `report/5`。

  ## 租约

  子代理拿到任务默认持有 5 分钟租约，长任务必须周期 `renew/4` 续期，
  否则被回收。主线不替子代理续期。

  ## 消息寻址

  `send_message(group_id, sid, body)` 点对点；`to: nil` 广播。
  状态通报/求助用广播；追问/私密上下文用点对点。

  ## 隔离

  `isolate: :auto` 默认给子代理一份独立的项目副本，完成前协调者
  review + apply；非 Git 项目降级共享。不要轻易 `isolate: false`。

  ## 函数清单

  - `delegate(title, opts \\ [])` — 派生子代理；opts: `name:/role:/description:/acceptance:/isolate:`
  - `claim_task(group_id, task_id)` — 以当前会话身份领取任务并取得 lease
  - `report(group_id, task_id, session_id, status, opts \\ [])` — 子代理调用
  - `renew(group_id, task_id, session_id, seconds \\ 300)` — 子代理续期
  - `tasks(group_id)` — 列出组内任务
  - `send_message(group_id, session_id, body, opts \\ [])` — 发消息；opts: `to:/kind:/delivery:`


  ## 安全约束

  - 身份来自 Agent.Loop 签发的短时 capability token，不能冒充其它会话
  - 无 token 调用一律拒绝 `{:error, "no_execution_context", _}`
  - 每个会话只能看见自己所在的组

  ## 可跑示例

    Newbee.Tools.Collaboration.delegate("修复 token 过期路径", name: "认证修复", role: "worker")
    Newbee.Tools.Collaboration.delegate("补充并发测试", name: "并发测试", role: "tester")
    {:ok, _task} = Newbee.Tools.Collaboration.claim_task("g1", "t1")
    Newbee.Tools.Collaboration.report("g1", "t1", "s1", :accepted)

    Newbee.Tools.Collaboration.report("g1", "t1", "s1", :running, progress: "50%")
    Newbee.Tools.Collaboration.renew("g1", "t1", "s1", 600)
    Newbee.Tools.Collaboration.tasks("g1")
    Newbee.Tools.Collaboration.send_message("g1", "s1", "进展如何？", kind: "question")

  """

  @statuses [:accepted, :running, :blocked, :succeeded, :failed, :cancelled]
  @context_key {__MODULE__, :context}

  @doc "从当前模型会话受控派生子代理；无工作组时自动建立。"
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
            "title" => "模型协作：#{String.slice(title, 0, 48)}",
            "goal" => title,
            "project_root" => project_root,
            "command_id" => "model-group-#{System.unique_integer([:positive])}"
          }
        ])
    end
  end

  @doc "报告任务状态（accepted/running/blocked/succeeded/failed/cancelled），可带 progress/result。"
  def report(group_id, task_id, session_id, status, opts \\ []) do
    with true <- status in @statuses or {:error, "bad_request", "未知任务状态"},
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

  @doc "以当前 capability 身份领取任务并取得 lease。"
  def claim_task(group_id, task_id) when is_binary(group_id) and is_binary(task_id) do
    with {:ok, identity} <- collaboration_identity() do
      Newbee.Host.call(Newbee.Collaboration.Coordinator, :claim_task, [
        group_id,
        task_id,
        identity.session_id
      ])
    end
  end

  def claim_task(_group_id, _task_id), do: {:error, "bad_request", "group_id 和 task_id 必须是字符串"}

  @doc "续期任务租约（秒），默认 300；必须先 claim_task/2。"
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

  @doc "列出当前会话所属群的全部任务。"
  def tasks(group_id) when is_binary(group_id) do
    with {:ok, identity} <- collaboration_identity(),
         true <-
           Newbee.Host.call(Newbee.Collaboration.Coordinator, :member?, [
             group_id,
             identity.session_id
           ]) or {:error, "not_member", "当前会话不属于该工作组"} do
      Newbee.Host.call(Newbee.Collaboration.Coordinator, :tasks, [group_id])
    end
  end

  @doc """
  向群成员发送消息。`:delivery` 可为 `:notify`、`:queue` 或 `:wake`。
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
        {:error, "no_execution_context", "协作调用必须运行在 Agent.Loop 签发的 capability 上下文中"}
    end
  end

  defp same_identity(session_id, session_id), do: :ok
  defp same_identity(_, _), do: {:error, "identity_mismatch", "session_id 与当前模型会话不一致"}
end
