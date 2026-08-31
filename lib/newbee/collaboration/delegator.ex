defmodule Newbee.Collaboration.Delegator do
  @moduledoc """
  子代理派生编排器。副作用顺序为 workspace → session → 单一 Coordinator 事件；
  在持久事件提交前失败会补偿清理，提交后由 Task.workspace 接管生命周期。
  """

  alias Newbee.Collaboration.{Coordinator, Workspace}

  def delegate(group_id, parent_session_id, title, opts \\ [])

  def delegate(group_id, parent_session_id, title, opts)
      when is_binary(group_id) and is_binary(parent_session_id) and is_binary(title) do
    command_id =
      Keyword.get(opts, :command_id) || "delegate-#{System.unique_integer([:positive])}"

    child_session_id = Keyword.get(opts, :session_id) || Newbee.Web.Session.gen_session_id()

    with {:ok, group} <- Coordinator.get(group_id),
         :ok <- parent_can_delegate(group, parent_session_id),
         :ok <- ensure_new_session(child_session_id),
         {:ok, root} <- project_root(group, parent_session_id),
         {:ok, workspace} <-
           Workspace.prepare(root, child_session_id, Keyword.get(opts, :isolate, :auto)) do
      create_session_and_delegate(
        group_id,
        parent_session_id,
        child_session_id,
        title,
        workspace,
        command_id,
        opts
      )
    end
  end

  def delegate(_, _, _, _), do: {:error, "bad_request", "派生参数无效"}

  defp create_session_and_delegate(
         group_id,
         parent_session_id,
         child_session_id,
         title,
         workspace,
         command_id,
         opts
       ) do
    result =
      with {:ok, _pid, ^child_session_id} <-
             Newbee.Web.Session.ensure(child_session_id, workspace["path"]),
           :ok <- Newbee.Session.mark_created(child_session_id),
           :ok <- Newbee.Session.rename(child_session_id, Keyword.get(opts, :name) || title),
           {:ok, delegated} <-
             Coordinator.delegate(group_id, %{
               "session_id" => child_session_id,
               "parent_session_id" => parent_session_id,
               "role" => Keyword.get(opts, :role, "worker"),
               "title" => title,
               "description" => Keyword.get(opts, :description),
               "acceptance" => Keyword.get(opts, :acceptance),
               "workspace" => workspace,
               "command_id" => command_id
             }) do
        {:ok,
         %{
           session_id: child_session_id,
           member: delegated.member,
           task: delegated.task,
           cwd: workspace["path"],
           workspace: workspace
         }}
      end

    case result do
      {:ok, _} = success ->
        success

      {:error, code, message} ->
        compensate(child_session_id, workspace)
        {:error, code, message}

      {:error, reason} ->
        compensate(child_session_id, workspace)
        {:error, "session_error", inspect(reason)}

      other ->
        compensate(child_session_id, workspace)
        {:error, "delegate_failed", inspect(other)}
    end
  end

  defp compensate(session_id, workspace) do
    Newbee.Web.Session.destroy(session_id)
    Workspace.discard_orphan(workspace)
    :ok
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  defp ensure_new_session(session_id) do
    if session_id in Newbee.Session.list() or match?({:ok, _}, Newbee.Web.Session.lookup(session_id)),
      do: {:error, "session_exists", "会话已经存在"},
      else: :ok
  end

  defp parent_can_delegate(group, parent_session_id) do
    if Enum.any?(group["members"] || [], &(&1["session_id"] == parent_session_id)),
      do: :ok,
      else: {:error, "not_member", "当前会话不属于该工作组"}
  end

  defp project_root(group, parent_session_id) do
    root = group["project_root"] || Newbee.Session.cwd(parent_session_id) || File.cwd!()
    if File.dir?(root), do: {:ok, root}, else: {:error, "project_root_missing", "项目目录不存在"}
  end
end
