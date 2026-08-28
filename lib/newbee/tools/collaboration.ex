defmodule Newbee.Tools.Collaboration do
  @moduledoc "会话群协作工具：子会话报告任务状态，或向群成员发送消息。"
  @statuses [:accepted, :running, :blocked, :succeeded, :failed, :cancelled]

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

  def renew(group_id, task_id, session_id, seconds \\ 300) do
    Newbee.Host.call(Newbee.Collaboration.Coordinator, :renew_task, [group_id, task_id, session_id, seconds])
  end

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
