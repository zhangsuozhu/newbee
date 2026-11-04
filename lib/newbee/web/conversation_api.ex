defmodule Newbee.Web.ConversationApi do
  @moduledoc "Authenticated original-conversation work RPC. Session identity determines the project root."
  alias Newbee.Colony.{ConversationWork, Membership, Store, Work, WorkspaceReview}
  @methods ~w(list start input answer control review apply complete)

  def dispatch("conversation.work." <> action, p) when action in @methods do
    sid = p["sessionId"]
    mode = if action in ~w(list review), do: :read, else: :write

    with :ok <- valid_session(sid),
         :ok <- Membership.session_access(p["__token__"], sid, mode),
         :ok <- authorize_request(action, p),
         {:ok, uploads} <- uploads(p["uploadIds"] || []) do
      run(action, sid, p, uploads)
    end
    |> normalize()
  end

  def dispatch(_, _), do: {:error, "unknown_method", "未知会话工作操作"}

  defp run("list", sid, _p, _), do: {:ok, %{"works" => ConversationWork.list(sid)}}

  defp run("start", sid, p, uploads) do
    principal =
      case Membership.authenticate(p["__token__"]) do
        {:ok, identity, _} -> {:member, identity["bee_id"], identity["colony_id"]}
        _ -> :owner
      end

    ConversationWork.start(sid, Newbee.Session.cwd(sid), p["text"], p["requestId"],
      principal: principal,
      upload_ids: uploads
    )
  end

  defp run("input", sid, p, uploads),
    do: ConversationWork.input(sid, p["workId"], p["text"], p["requestId"], upload_ids: uploads)

  defp run("answer", sid, p, uploads),
    do:
      ConversationWork.answer(sid, p["workId"], p["questionId"], p["text"] || p["value"], p["requestId"],
        upload_ids: uploads
      )

  defp run("control", sid, p, _), do: ConversationWork.control(sid, p["workId"], p["action"])

  defp run("review", sid, p, _) do
    with {:ok, task} <- ConversationWork.fetch(sid, p["workId"]),
         {:ok, review} <- WorkspaceReview.review(task) do
      {:ok, %{"work" => ConversationWork.view(task), "review" => review}}
    end
  end

  defp run("apply", sid, p, _) do
    with :ok <- request_id(p["requestId"]),
         {:ok, task} <- ConversationWork.fetch(sid, p["workId"]),
         {:ok, _receipt} <- WorkspaceReview.apply(task, p["patchSha256"], p["requestId"]) do
      finalize(sid, task["id"])
    end
  end

  defp run("complete", sid, p, _) do
    with :ok <- request_id(p["requestId"]),
         {:ok, task} <- ConversationWork.fetch(sid, p["workId"]) do
      if task["status"] == "done" do
        {:ok, %{"work" => ConversationWork.view(task)}}
      else
        with {:ok, review} <- WorkspaceReview.review(task),
             true <- review["files"] == [],
             {:ok, _} <-
               Store.update("tasks", task["id"], task["revision"], fn current ->
                 {:ok,
                  Map.put(current, "application", %{
                    "state" => "text_accepted",
                    "request_id" => p["requestId"],
                    "context_revision" => current["context_revision"]
                  })}
               end) do
          finalize(sid, task["id"])
        else
          false -> {:error, "apply_required", "成果包含文件改动，请先查看并应用，或保留为未采用成果"}
          error -> error
        end
      end
    end
  end

  defp authorize_request(action, _p) when action in ~w(start list review), do: :ok

  defp authorize_request(_action, p) do
    case Membership.authenticate(p["__token__"]) do
      {:ok, identity, _} ->
        with {:ok, task} <- ConversationWork.fetch(p["sessionId"], p["workId"]),
             {:ok, colony} <- Store.get_colony(task["colony_id"]),
             :ok <- Newbee.Colony.Control.authorize_work(colony, task["id"], identity["bee_id"]) do
          :ok
        end

      _ ->
        :ok
    end
  end

  defp finalize(sid, id) do
    with {:ok, task} <- ConversationWork.fetch(sid, id),
         {:ok, _} <- Work.review(task["colony_id"], task["result"], "accept", task["created_by"]),
         {:ok, current} <- ConversationWork.fetch(sid, id) do
      {:ok, %{"work" => ConversationWork.view(current)}}
    end
  end

  defp valid_session(sid) when is_binary(sid) do
    if Regex.match?(~r/\A[0-9A-Za-z._-]{1,96}\z/, sid) and Newbee.Session.exists?(sid),
      do: :ok,
      else: {:error, "not_found", "原会话不存在，请先创建或恢复对话"}
  end

  defp valid_session(_), do: {:error, "bad_request", "缺少原会话"}

  defp request_id(id),
    do: if(is_binary(id) and byte_size(id) in 1..180, do: :ok, else: {:error, "bad_request", "缺少稳定请求 ID"})

  defp uploads(ids) when is_list(ids) and length(ids) <= 32 do
    if Enum.all?(ids, &(is_binary(&1) and byte_size(&1) in 1..180)),
      do: {:ok, ids},
      else: {:error, "bad_request", "附件列表无效"}
  end

  defp uploads(_), do: {:error, "bad_request", "附件列表无效"}
  defp normalize({:error, :not_found}), do: {:error, "not_found", "记录不存在"}
  defp normalize({:error, :conflict}), do: {:error, "conflict", "工作已变化，请刷新后重试"}
  defp normalize({:error, reason}), do: {:error, "operation_failed", inspect(reason)}
  defp normalize(other), do: other
end
