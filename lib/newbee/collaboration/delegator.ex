defmodule Newbee.Collaboration.Delegator do
  @moduledoc """
  子代理派生编排器。副作用顺序为 preflight → workspace → session 配置/上下文 →
  session 进程 → Coordinator 单一持久事件；提交前失败会补偿清理。
  """

  alias Newbee.Collaboration.{ContextFork, Coordinator, Workspace}

  def delegate(group_id, parent_session_id, title, opts \\ [])

  def delegate(group_id, parent_session_id, title, opts)
      when is_binary(group_id) and is_binary(parent_session_id) and is_binary(title) do
    command_id = Keyword.get(opts, :command_id) || "delegate-#{System.unique_integer([:positive])}"
    child_session_id = Keyword.get(opts, :session_id) || Newbee.Web.Session.gen_session_id()

    with {:ok, group} <- Coordinator.get(group_id),
         :ok <- parent_can_delegate(group, parent_session_id),
         :ok <- Coordinator.can_delegate(group_id, parent_session_id),
         :ok <- ensure_new_session(child_session_id),
         :ok <- preflight_acceptance(opts),
         {:ok, root} <- project_root(group, parent_session_id),
         {:ok, workspace} <- Workspace.prepare(root, child_session_id, Keyword.get(opts, :isolate, :auto)) do
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
      with :ok <- Newbee.Session.mark_created(child_session_id),
           :ok <- Newbee.Session.rename(child_session_id, Keyword.get(opts, :name) || title),
           :ok <- configure_session(child_session_id, group_id, parent_session_id, opts),
           {:ok, _client} <- Newbee.Web.Session.client_for_session(child_session_id),
           {:ok, fork} <- ContextFork.seed(parent_session_id, child_session_id, Keyword.get(opts, :fork_turns, :none)),
           {:ok, _pid, ^child_session_id} <- Newbee.Web.Session.ensure(child_session_id, workspace["path"]),
           {:ok, delegated} <-
             Coordinator.delegate(group_id, %{
               "session_id" => child_session_id,
               "parent_session_id" => parent_session_id,
               "role" => Keyword.get(opts, :role, "worker"),
               "persona" => Keyword.get(opts, :persona_profile),
               "protocol_version" => Keyword.get(opts, :protocol_version, 1),
               "title" => title,
               "description" => Keyword.get(opts, :description),
               "acceptance" => Keyword.get(opts, :acceptance),
               "depends_on" => Keyword.get(opts, :depends_on, []),
               "write_scope" => Keyword.get(opts, :write_scope, []),
               "workspace" => workspace,
               "command_id" => command_id
             }) do
        {:ok,
         %{
           session_id: child_session_id,
           member: delegated.member,
           task: delegated.task,
           cwd: workspace["path"],
           workspace: workspace,
           fork: fork
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

  defp configure_session(child_id, group_id, parent_id, opts) do
    case Keyword.get(opts, :persona_profile) do
      profile when is_map(profile) ->
        profile =
          profile
          |> Map.put("group_id", group_id)
          |> Map.put("parent_session_id", parent_id)
          |> Map.put("fork_turns", to_string(Keyword.get(opts, :fork_turns, :none)))

        with :ok <- Newbee.Session.set_collaboration_profile(child_id, profile),
             :ok <- maybe_set_session(child_id, :provider, profile["provider"]),
             :ok <- maybe_set_session(child_id, :model, profile["model"]),
             :ok <- maybe_set_session(child_id, :effort, profile["reasoning_effort"]) do
          :ok
        end

      _ ->
        :ok
    end
  end

  defp maybe_set_session(_id, _field, nil), do: :ok
  defp maybe_set_session(id, :provider, value), do: Newbee.Session.set_provider(id, value)
  defp maybe_set_session(id, :model, value), do: Newbee.Session.set_model(id, value)
  defp maybe_set_session(id, :effort, value), do: Newbee.Session.set_effort(id, value)

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

  # v2 合约是无状态可判定的：在创建 workspace/session 副作用之前先拒绝非法 acceptance。
  # v1 保持兼容，不预检。
  defp preflight_acceptance(opts) do
    if Keyword.get(opts, :protocol_version, 1) == 2 do
      case Newbee.Collaboration.Verification.normalize_contract(Keyword.get(opts, :acceptance)) do
        {:ok, _} -> :ok
        {:error, _, _} = error -> error
      end
    else
      :ok
    end
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
