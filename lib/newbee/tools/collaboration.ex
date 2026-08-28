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

  def send_message(group_id, session_id, body, opts \\ []) do
    attrs = %{
      "sender_session_id" => session_id,
      "to_session_id" => Keyword.get(opts, :to),
      "kind" => to_string(Keyword.get(opts, :kind, :chat)),
      "body" => body,
      "message_id" => Keyword.get(opts, :message_id),
      "command_id" => Keyword.get(opts, :command_id)
    }

    Newbee.Host.call(Newbee.Collaboration.Coordinator, :send_message, [group_id, attrs])
  end
end
