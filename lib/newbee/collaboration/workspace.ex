defmodule Newbee.Collaboration.Workspace do
  @moduledoc """
  子代理工作区生命周期：创建隔离 Git 工作目录、生成可复核补丁、应用或拒绝，
  最后安全清理。调用方只能使用 Task 持久化的 workspace 元数据，不能传任意路径。
  """

  @display_patch_limit 600_000
  @session_id_re ~r/\A[0-9A-Za-z._-]{1,96}\z/
  @terminal_review_states ~w(applied rejected)

  def prepare(root, child_session_id, mode \\ :auto)

  def prepare(root, child_session_id, mode)
      when is_binary(root) and is_binary(child_session_id) and mode in [true, false, :auto] do
    with :ok <- valid_session_id(child_session_id),
         {:ok, expanded_root} <- existing_directory(root) do
      case mode do
        false ->
          {:ok, shared_workspace(expanded_root)}

        true ->
          prepare_git_workspace(expanded_root, child_session_id)

        :auto ->
          case git_repository?(expanded_root) do
            true -> prepare_git_workspace(expanded_root, child_session_id)
            false -> {:ok, Map.put(shared_workspace(expanded_root), "warning", "非 Git 项目使用共享目录")}
          end
      end
    end
  end

  def prepare(_, _, _), do: {:error, "bad_request", "工作区参数无效"}

  def review(task) when is_map(task) do
    with :ok <- terminal_task(task),
         {:ok, workspace} <- task_workspace(task),
         {:ok, patch_info} <- build_patch(workspace) do
      {:ok,
       patch_info
       |> Map.put(:review_status, workspace["review_status"] || "waiting")
       |> Map.put(:workspace_path, workspace["path"])
       |> Map.put(:base_ref, workspace["base_ref"])}
    end
  end

  def apply(task, expected_sha256) when is_map(task) and is_binary(expected_sha256) do
    with :ok <- terminal_task(task),
         {:ok, workspace} <- task_workspace(task),
         :ok <- require_review_state(workspace, "pending"),
         {:ok, patch_info} <- build_patch(workspace),
         :ok <- same_review(expected_sha256, patch_info.patch_sha256),
         :ok <- maybe_apply_patch(workspace["root"], patch_info) do
      {:ok, Map.drop(patch_info, [:patch])}
    end
  end

  def apply(_, _), do: {:error, "bad_request", "需要任务和审查版本"}

  def reject(task) when is_map(task) do
    with :ok <- terminal_task(task),
         {:ok, workspace} <- task_workspace(task),
         :ok <- require_review_state(workspace, "pending") do
      {:ok, %{workspace_path: workspace["path"], review_status: "rejected"}}
    end
  end

  def cleanup(task) when is_map(task) do
    with {:ok, workspace} <- cleanup_workspace(task),
         :ok <- require_review_state(workspace, @terminal_review_states),
         :ok <- remove_git_workspace(workspace) do
      {:ok, %{workspace_path: workspace["path"], review_status: "cleaned"}}
    end
  end

  @doc false
  def discard_orphan(%{"kind" => "git_worktree"} = workspace), do: remove_git_workspace(workspace)
  def discard_orphan(_), do: :ok

  defp prepare_git_workspace(root, child_session_id) do
    with {:ok, repo_root} <- repository_root(root),
         {:ok, snapshot} <- snapshot_parent_workspace(repo_root, child_session_id) do
      case materialize_git_workspace(repo_root, child_session_id, snapshot) do
        {:ok, workspace} ->
          {:ok, workspace}

        {:error, _, _} = error ->
          delete_snapshot_ref(repo_root, snapshot.ref)
          error
      end
    end
  end

  defp materialize_git_workspace(repo_root, child_session_id, snapshot) do
    path = Path.join([repo_root, ".newbee", "worktrees", child_session_id])

    with :ok <- ensure_expected_path(repo_root, path),
         :ok <- File.mkdir_p(Path.dirname(path)),
         {:ok, _} <- normalize_git_result(Newbee.Tools.Git.worktree_add(repo_root, path, snapshot.commit)),
         {:ok, common_dir} <- common_git_dir(repo_root) do
      {:ok,
       %{
         "kind" => "git_worktree",
         "root" => repo_root,
         "path" => path,
         "base_ref" => snapshot.commit,
         "snapshot_ref" => snapshot.ref,
         "common_git_dir" => common_dir,
         "review_status" => "waiting",
         "reviewed_at" => nil,
         "reviewed_by_session_id" => nil
       }}
    end
  end

  defp snapshot_parent_workspace(repo_root, child_session_id) do
    tmp_index = Path.join(System.tmp_dir!(), "newbee-snapshot-#{System.unique_integer([:positive])}")
    env = [{"GIT_INDEX_FILE", tmp_index}]
    snapshot_ref = "refs/newbee/collaboration/" <> child_session_id

    try do
      with {:ok, head} <- git(repo_root, ["rev-parse", "HEAD"]),
           head = String.trim(head),
           {:ok, _} <- git(repo_root, ["read-tree", head], env),
           {:ok, _} <- git(repo_root, ["add", "-A", "--"], env),
           {:ok, tree} <- git(repo_root, ["write-tree"], env),
           tree = String.trim(tree),
           {:ok, head_tree} <- git(repo_root, ["rev-parse", head <> "^{tree}"]) do
        if tree == String.trim(head_tree) do
          {:ok, %{commit: head, ref: nil}}
        else
          commit_env =
            env ++
              [
                {"GIT_AUTHOR_NAME", "newbee snapshot"},
                {"GIT_AUTHOR_EMAIL", "snapshot@newbee.local"},
                {"GIT_COMMITTER_NAME", "newbee snapshot"},
                {"GIT_COMMITTER_EMAIL", "snapshot@newbee.local"}
              ]

          with {:ok, commit} <-
                 git(repo_root, ["commit-tree", tree, "-p", head, "-m", "newbee collaboration snapshot"], commit_env),
               commit = String.trim(commit),
               {:ok, _} <- git(repo_root, ["update-ref", snapshot_ref, commit]) do
            {:ok, %{commit: commit, ref: snapshot_ref}}
          end
        end
      end
    after
      File.rm(tmp_index)
      File.rm(tmp_index <> ".lock")
    end
  end

  defp shared_workspace(root) do
    %{
      "kind" => "shared",
      "root" => root,
      "path" => root,
      "base_ref" => nil,
      "review_status" => "not_applicable",
      "reviewed_at" => nil,
      "reviewed_by_session_id" => nil
    }
  end

  defp cleanup_workspace(%{
         "workspace" =>
           %{
             "kind" => "git_worktree",
             "root" => root,
             "path" => path,
             "base_ref" => base_ref
           } = workspace
       })
       when is_binary(root) and is_binary(path) and is_binary(base_ref) do
    with :ok <- ensure_expected_path(root, path), do: {:ok, workspace}
  end

  defp cleanup_workspace(_), do: {:error, "workspace_invalid", "隔离工作区元数据无效"}

  defp task_workspace(%{"workspace" => workspace}) when is_map(workspace) do
    with :ok <- reviewable(workspace),
         :ok <- validate_git_workspace(workspace) do
      {:ok, workspace}
    end
  end

  defp task_workspace(_), do: {:error, "workspace_missing", "任务没有可审查的隔离工作区"}

  defp reviewable(%{"kind" => "git_worktree", "review_status" => status})
       when status != "cleaned",
       do: :ok

  defp reviewable(%{"kind" => "shared"}),
    do: {:error, "not_reviewable", "该子代理使用共享目录，没有独立变更可审查"}

  defp reviewable(_), do: {:error, "workspace_cleaned", "隔离工作区已清理或元数据无效"}

  defp terminal_task(%{"status" => status}) when status in ["succeeded", "failed", "cancelled"], do: :ok
  defp terminal_task(_), do: {:error, "task_not_terminal", "任务结束后才能审查变更"}

  defp require_review_state(workspace, expected) when is_binary(expected) do
    if workspace["review_status"] == expected,
      do: :ok,
      else: {:error, "invalid_workspace_state", "当前工作区状态不允许此操作"}
  end

  defp require_review_state(workspace, allowed) when is_list(allowed) do
    if workspace["review_status"] in allowed,
      do: :ok,
      else: {:error, "invalid_workspace_state", "当前工作区状态不允许清理"}
  end

  defp build_patch(workspace) do
    tmp_index = Path.join(System.tmp_dir!(), "newbee-index-#{System.unique_integer([:positive])}")
    env = [{"GIT_INDEX_FILE", tmp_index}]
    path = workspace["path"]
    base_ref = workspace["base_ref"]

    try do
      with {:ok, _} <- git(path, ["read-tree", "HEAD"], env),
           {:ok, _} <- git(path, ["add", "-A"], env),
           {:ok, patch} <-
             git(
               path,
               ["diff", "--cached", "--binary", "--full-index", "--no-ext-diff", base_ref, "--"],
               env
             ),
           {:ok, names} <- git(path, ["diff", "--cached", "--name-status", base_ref, "--"], env),
           {:ok, numstat} <- git(path, ["diff", "--cached", "--numstat", base_ref, "--"], env) do
        sha = :crypto.hash(:sha256, patch) |> Base.encode16(case: :lower)

        {:ok,
         %{
           patch: patch,
           display_patch: truncate_patch(patch),
           patch_truncated: byte_size(patch) > @display_patch_limit,
           patch_sha256: sha,
           bytes: byte_size(patch),
           dirty: patch != "",
           files: parse_files(names, numstat)
         }}
      end
    after
      File.rm(tmp_index)
      File.rm(tmp_index <> ".lock")
    end
  end

  defp apply_patch(root, patch) do
    patch_file =
      Path.join(System.tmp_dir!(), "newbee-review-#{System.unique_integer([:positive])}.patch")

    try do
      :ok = File.write(patch_file, patch)

      case git(root, ["apply", "--check", patch_file]) do
        {:ok, _} ->
          case git(root, ["apply", "--whitespace=nowarn", patch_file]) do
            {:ok, _} -> :ok
            {:error, _, _} = error -> error
          end

        {:error, _, _} = forward_error ->
          case git(root, ["apply", "--reverse", "--check", patch_file]) do
            {:ok, _} -> :ok
            {:error, _, _} -> forward_error
          end
      end
    after
      File.rm(patch_file)
    end
  end

  defp remove_git_workspace(%{"root" => root, "path" => path} = workspace) do
    with :ok <- ensure_expected_path(root, path),
         :ok <- remove_workspace_directory(root, path, workspace),
         :ok <- delete_snapshot_ref(root, workspace["snapshot_ref"]) do
      :ok
    end
  end

  defp remove_workspace_directory(root, path, workspace) do
    if File.dir?(path) do
      with :ok <- validate_git_workspace(workspace) do
        case apply(Newbee.Tools.Git, :worktree_remove, [root, path]) do
          {:ok, _} ->
            :ok

          {:error, {exit_code, output}} ->
            {:error, "workspace_cleanup_failed", "git exit " <> Integer.to_string(exit_code) <> ": " <> output}
        end
      end
    else
      :ok
    end
  end

  defp delete_snapshot_ref(_root, nil), do: :ok

  defp delete_snapshot_ref(root, "refs/newbee/collaboration/" <> session_id = ref) do
    with :ok <- valid_session_id(session_id) do
      case git(root, ["update-ref", "-d", ref]) do
        {:ok, _} -> :ok
        {:error, _, _} = error -> error
      end
    end
  end

  defp delete_snapshot_ref(_root, _ref), do: {:error, "workspace_ref_invalid", "临时快照引用无效"}

  defp validate_git_workspace(%{
         "kind" => "git_worktree",
         "root" => root,
         "path" => path,
         "base_ref" => base_ref
       })
       when is_binary(root) and is_binary(path) and is_binary(base_ref) do
    with :ok <- ensure_expected_path(root, path),
         {:ok, root_common} <- common_git_dir(root),
         {:ok, child_common} <- common_git_dir(path),
         true <- root_common == child_common,
         {:ok, _} <- git(path, ["cat-file", "-e", base_ref <> "^{commit}"]) do
      :ok
    else
      false -> {:error, "workspace_mismatch", "隔离工作区不属于同一 Git 仓库"}
      {:error, _, _} = error -> error
    end
  end

  defp validate_git_workspace(_), do: {:error, "workspace_invalid", "隔离工作区元数据无效"}

  defp ensure_expected_path(root, path) do
    root = Path.expand(root)
    path = Path.expand(path)
    expected = Path.join([root, ".newbee", "worktrees"]) |> Path.expand()
    relative = Path.relative_to(path, expected)

    if relative != "." and not String.starts_with?(relative, "..") and
         Path.dirname(relative) == ".",
       do: :ok,
       else: {:error, "workspace_path_invalid", "隔离工作区路径越界"}
  end

  defp git_repository?(path) do
    case System.cmd("git", ["-C", path, "rev-parse", "--is-inside-work-tree"], stderr_to_stdout: true) do
      {output, 0} -> String.trim(output) == "true"
      _ -> false
    end
  rescue
    _ -> false
  end

  defp repository_root(path) do
    with {:ok, root} <- git(path, ["rev-parse", "--show-toplevel"]) do
      {:ok, root |> String.trim() |> Path.expand()}
    end
  end

  defp common_git_dir(path) do
    with {:ok, common} <- git(path, ["rev-parse", "--git-common-dir"]) do
      common = String.trim(common)
      {:ok, if(Path.type(common) == :absolute, do: Path.expand(common), else: Path.expand(common, path))}
    end
  end

  defp existing_directory(path) do
    expanded = Path.expand(path)
    if File.dir?(expanded), do: {:ok, expanded}, else: {:error, "project_root_missing", "项目目录不存在"}
  end

  defp valid_session_id(session_id) do
    if Regex.match?(@session_id_re, session_id),
      do: :ok,
      else: {:error, "invalid_session_id", "子会话 ID 含非法字符"}
  end

  defp normalize_git_result({:ok, output}), do: {:ok, output}

  defp normalize_git_result({:error, {code, output}}),
    do: {:error, "workspace_create_failed", "git exit #{code}: #{output}"}

  defp maybe_apply_patch(root, %{dirty: true, patch: patch}), do: apply_patch(root, patch)
  defp maybe_apply_patch(_root, %{dirty: false}), do: :ok

  defp same_review(expected, actual) do
    if byte_size(expected) == byte_size(actual) and Plug.Crypto.secure_compare(expected, actual),
      do: :ok,
      else: {:error, "stale_review", "子代理变更已更新，请重新审查后再应用"}
  rescue
    _ -> {:error, "stale_review", "审查版本无效"}
  end

  defp truncate_patch(patch) when byte_size(patch) <= @display_patch_limit, do: patch

  defp truncate_patch(patch),
    do: binary_part(patch, 0, @display_patch_limit) <> "\n… diff 已截断 …\n"

  defp parse_files(names, numstat) do
    stats =
      numstat
      |> String.split("\n", trim: true)
      |> Map.new(fn line ->
        case String.split(line, "\t") do
          [added, deleted, path] ->
            {path, %{added: parse_count(added), deleted: parse_count(deleted)}}

          _ ->
            {line, %{added: 0, deleted: 0}}
        end
      end)

    names
    |> String.split("\n", trim: true)
    |> Enum.map(fn line ->
      parts = String.split(line, "\t")
      status = List.first(parts) || "M"
      path = List.last(parts) || line
      Map.merge(%{path: path, status: status}, Map.get(stats, path, %{added: 0, deleted: 0}))
    end)
  end

  defp parse_count("-"), do: 0

  defp parse_count(value) do
    case Integer.parse(value) do
      {number, ""} -> number
      _ -> 0
    end
  end

  defp git(dir, args, env \\ []) do
    case System.cmd("git", ["-C", dir | args], stderr_to_stdout: true, env: env) do
      {output, 0} ->
        {:ok, output}

      {output, code} ->
        {:error, "git_error", "git exit #{code}: #{String.slice(String.trim(output), 0, 1_000)}"}
    end
  rescue
    error -> {:error, "git_error", Exception.message(error)}
  end
end
