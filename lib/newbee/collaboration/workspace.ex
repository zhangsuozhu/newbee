defmodule Newbee.Collaboration.Workspace do
  @moduledoc """
  通用子会话工作区：默认文件系统副本，不依赖 Git。
  `isolate: false` 才使用共享目录，旧的 Git worktree 元数据仍可兼容读取。
  """

  @display_patch_limit 600_000
  @session_id_re ~r/\A[0-9A-Za-z._-]{1,96}\z/
  @terminal_review_states ~w(applied rejected)
  @default_snapshot_max_files 16_384
  @default_snapshot_max_bytes 128 * 1_024 * 1_024
  @default_snapshot_max_file_bytes 32 * 1_024 * 1_024

  @excluded_entries MapSet.new([
                      ".appimage-cache",
                      ".cache",
                      ".git",
                      ".newbee",
                      ".newbee-tmp",
                      ".elixir_ls",
                      "_build",
                      "build",
                      "deps",
                      "dist",
                      "cover",
                      "node_modules",
                      "tmp",
                      "erl_crash.dump",
                      "nohup.out",
                      "pal"
                    ])

  def prepare(root, child_session_id, mode \\ :auto)

  def prepare(root, child_session_id, mode)
      when is_binary(root) and is_binary(child_session_id) and mode in [true, false, :auto] do
    with :ok <- valid_session_id(child_session_id),
         {:ok, expanded_root} <- existing_directory(root) do
      case mode do
        false ->
          {:ok, shared_workspace(expanded_root)}

        true ->
          prepare_filesystem_workspace(expanded_root, child_session_id)

        :auto ->
          prepare_filesystem_workspace(expanded_root, child_session_id)
      end
    end
  end

  def prepare(_, _, _), do: {:error, "bad_request", "invalid workspace args"}

  def review(task) when is_map(task) do
    with :ok <- reviewable_task(task),
         {:ok, workspace} <- task_workspace(task),
         {:ok, candidate} <- candidate_root(task, workspace),
         {:ok, patch_info} <- build_patch(workspace, candidate) do
      {:ok,
       patch_info
       |> Map.put(:review_status, workspace["review_status"] || "waiting")
       |> Map.put(:workspace_path, workspace["path"])
       |> Map.put(:candidate_path, candidate)
       |> Map.put(:base_ref, workspace["base_ref"])}
    end
  end

  def apply(task, expected_sha256) when is_map(task) and is_binary(expected_sha256) do
    with :ok <- applyable_task(task),
         {:ok, workspace} <- task_workspace(task),
         :ok <- require_review_state(workspace, "pending"),
         {:ok, candidate} <- candidate_root(task, workspace),
         {:ok, patch_info} <- build_patch(workspace, candidate),
         :ok <- same_review(expected_sha256, patch_info.patch_sha256),
         :ok <- revalidate_candidate(task),
         :ok <- apply_files(workspace, candidate, patch_info.changes) do
      {:ok, Map.drop(patch_info, [:patch, :changes])}
    end
  end

  def apply(_, _), do: {:error, "bad_request", "need a task plus a reviewed revision"}

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
         :ok <- cleanup_submission(task),
         :ok <- remove_workspace(workspace) do
      {:ok, %{workspace_path: workspace["path"], review_status: "cleaned"}}
    end
  end

  @doc false
  def discard_orphan(%{"kind" => kind} = workspace) when kind in ["filesystem_copy", "git_worktree"],
    do: remove_workspace(workspace)

  def discard_orphan(_), do: :ok

  defp prepare_filesystem_workspace(root, child_session_id) do
    with {:ok, base_snapshot} <- snapshot(root),
         path <- Path.join([root, ".newbee", "workspaces", child_session_id]),
         :ok <- ensure_workspace_path(root, path),
         :ok <- ensure_absent(path),
         :ok <- File.mkdir_p(path),
         :ok <- materialize_snapshot(base_snapshot, path),
         :ok <- write_base_snapshot(path, base_snapshot) do
      {:ok,
       %{
         "kind" => "filesystem_copy",
         "root" => root,
         "path" => path,
         "base_ref" => snapshot_ref(base_snapshot),
         "review_status" => "waiting",
         "reviewed_at" => nil,
         "reviewed_by_session_id" => nil
       }}
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

  defp reviewable_task(%{"status" => "submitted"} = task) do
    if is_map(task["submission"]),
      do: :ok,
      else: {:error, "submission_missing", "submitted task has no frozen submission"}
  end

  defp reviewable_task(%{"status" => status}) when status in ["succeeded", "failed", "cancelled"], do: :ok
  defp reviewable_task(_), do: {:error, "task_not_terminal", "changes are reviewable only after the task ends"}

  defp applyable_task(%{"submission" => submission} = task) when is_map(submission) do
    with :ok <- succeeded_task(task),
         :ok <- verification_matches_submission(task),
         :ok <- Newbee.Collaboration.Submission.validate(task) do
      :ok
    end
  end

  defp applyable_task(task), do: terminal_task(task)

  defp succeeded_task(%{"status" => "succeeded"}), do: :ok
  defp succeeded_task(_), do: {:error, "verification_required", "只有已通过验收的任务可应用"}

  defp verification_matches_submission(%{"submission" => submission, "verification" => verification}) do
    cond do
      not is_map(verification) or verification["status"] != "passed" or
          verification["all_passed"] != true ->
        {:error, "verification_required", "submission 尚未通过验收"}

      verification["submission_id"] != submission["id"] or
          verification["tree_sha256"] != submission["tree_sha256"] ->
        {:error, "stale_attestation", "验收结果与冻结候选不一致"}

      true ->
        :ok
    end
  end

  defp verification_matches_submission(_),
    do: {:error, "verification_required", "submission 缺少可信验收结果"}

  defp candidate_root(%{"submission" => submission} = task, _workspace) when is_map(submission) do
    with :ok <- Newbee.Collaboration.Submission.validate(task),
         root when is_binary(root) <- submission["root"] do
      {:ok, root}
    else
      {:error, _code, _message} = error -> error
      _ -> {:error, "submission_invalid", "冻结候选根目录无效"}
    end
  end

  defp candidate_root(_task, workspace), do: {:ok, workspace["path"]}

  defp revalidate_candidate(%{"submission" => submission} = task) when is_map(submission),
    do: Newbee.Collaboration.Submission.validate(task)

  defp revalidate_candidate(_task), do: :ok

  defp cleanup_submission(%{"submission" => submission} = task) when is_map(submission),
    do: Newbee.Collaboration.Submission.cleanup(task)

  defp cleanup_submission(_task), do: :ok

  defp cleanup_workspace(%{"workspace" => workspace}) when is_map(workspace) do
    with :ok <- validate_workspace(workspace), do: {:ok, workspace}
  end

  defp cleanup_workspace(_), do: {:error, "workspace_invalid", "isolated workspace metadata is invalid"}

  defp task_workspace(%{"workspace" => workspace}) when is_map(workspace) do
    with :ok <- reviewable(workspace),
         :ok <- validate_workspace(workspace) do
      {:ok, workspace}
    end
  end

  defp task_workspace(_), do: {:error, "workspace_missing", "task has no reviewable isolated workspace"}

  defp reviewable(%{"kind" => "shared"}),
    do: {:error, "not_reviewable", "that subagent shares a directory; no standalone diff to review"}

  defp reviewable(%{"review_status" => "cleaned"}),
    do: {:error, "workspace_cleaned", "isolated workspace already cleaned"}

  defp reviewable(%{"kind" => kind}) when kind in ["filesystem_copy", "git_worktree"], do: :ok
  defp reviewable(_), do: {:error, "workspace_invalid", "isolated workspace metadata is invalid"}

  defp validate_workspace(%{"kind" => kind, "root" => root, "path" => path})
       when kind in ["filesystem_copy", "git_worktree"] and is_binary(root) and is_binary(path) do
    ensure_workspace_path(root, path)
  end

  defp validate_workspace(%{"kind" => "shared", "root" => root, "path" => path}) when is_binary(root) and root == path,
    do: :ok

  defp validate_workspace(_), do: {:error, "workspace_invalid", "isolated workspace metadata is invalid"}

  defp terminal_task(%{"status" => status}) when status in ["succeeded", "failed", "cancelled"], do: :ok
  defp terminal_task(_), do: {:error, "task_not_terminal", "changes are reviewable only after the task ends"}

  defp require_review_state(workspace, expected) when is_binary(expected) do
    if workspace["review_status"] == expected,
      do: :ok,
      else: {:error, "invalid_workspace_state", "workspace state forbids this op"}
  end

  defp require_review_state(workspace, allowed) when is_list(allowed) do
    if workspace["review_status"] in allowed,
      do: :ok,
      else: {:error, "invalid_workspace_state", "workspace state forbids cleanup"}
  end

  defp baseline_matches_workspace(%{"base_ref" => expected}, base) when is_binary(expected) do
    if snapshot_ref(base) == expected,
      do: :ok,
      else: {:error, "workspace_conflict", "workspace baseline manifest changed"}
  end

  defp baseline_matches_workspace(_workspace, _base), do: :ok

  defp build_patch(workspace, source_path) do
    with {:ok, base} <- snapshot_from_workspace(workspace),
         :ok <- baseline_matches_workspace(workspace, base),
         {:ok, current} <- snapshot(source_path) do
      changes = changes(base, current)
      patch = render_patch(changes, base, current)
      sha = sha256(patch)

      {:ok,
       %{
         patch: patch,
         display_patch: truncate_patch(patch),
         patch_truncated: byte_size(patch) > @display_patch_limit,
         patch_sha256: sha,
         bytes: byte_size(patch),
         dirty: changes != [],
         files: Enum.map(changes, &file_summary(&1, base, current)),
         changes: changes
       }}
    end
  end

  defp snapshot_from_workspace(%{"base_snapshot" => snapshot}) when is_map(snapshot), do: {:ok, snapshot}

  defp snapshot_from_workspace(%{"path" => path}) when is_binary(path) do
    case File.read(base_snapshot_path(path)) do
      {:ok, binary} ->
        try do
          snapshot = :erlang.binary_to_term(binary, [:safe])

          if is_map(snapshot),
            do: {:ok, snapshot},
            else: {:error, "workspace_snapshot_invalid", "baseline snapshot has a bad shape"}
        rescue
          _ -> {:error, "workspace_snapshot_invalid", "baseline snapshot has a bad shape"}
        end

      {:error, :enoent} ->
        {:error, "workspace_snapshot_missing", "workspace lacks a baseline snapshot"}

      {:error, reason} ->
        {:error, "workspace_snapshot_failed", inspect(reason)}
    end
  end

  defp snapshot_from_workspace(_), do: {:error, "workspace_snapshot_missing", "workspace lacks a baseline snapshot"}

  defp write_base_snapshot(path, snapshot) do
    sidecar = base_snapshot_path(path)
    File.write(sidecar, :erlang.term_to_binary(snapshot, [:compressed]))
  end

  defp base_snapshot_path(path), do: path <> ".base_snapshot.term"

  defp changes(base, current) do
    paths = (Map.keys(base) ++ Map.keys(current)) |> Enum.uniq() |> Enum.sort()

    Enum.flat_map(paths, fn path ->
      case {Map.get(base, path), Map.get(current, path)} do
        {nil, current_file} when is_map(current_file) ->
          [{:added, path}]

        {base_file, nil} when is_map(base_file) ->
          [{:deleted, path}]

        {base_file, current_file} when is_map(base_file) and is_map(current_file) ->
          if base_file["sha256"] != current_file["sha256"], do: [{:modified, path}], else: []

        _ ->
          []
      end
    end)
  end

  defp file_summary({status, path}, base, current) do
    old_entry = Map.get(base, path)
    new_entry = Map.get(current, path)
    old = decode_snapshot_file(old_entry)
    new = decode_snapshot_file(new_entry)
    binary? = binary_snapshot?(old_entry) or binary_snapshot?(new_entry)
    old_lines = if binary?, do: 0, else: line_count(old)
    new_lines = if binary?, do: 0, else: line_count(new)

    %{
      path: path,
      status: Atom.to_string(status),
      added: max(new_lines - old_lines, 0),
      deleted: max(old_lines - new_lines, 0),
      binary: binary?
    }
  end

  defp render_patch(changes, base, current) do
    Enum.map_join(changes, "\n", fn {status, path} ->
      old_entry = Map.get(base, path)
      new_entry = Map.get(current, path)

      if binary_snapshot?(old_entry) or binary_snapshot?(new_entry) do
        "Binary files " <>
          if(status == :added, do: "/dev/null", else: "a/" <> path) <>
          " and " <> if(status == :deleted, do: "/dev/null", else: "b/" <> path) <> " differ"
      else
        old = decode_snapshot_file(old_entry)
        new = decode_snapshot_file(new_entry)
        old_lines = if old == nil, do: [], else: String.split(old, "\n")
        new_lines = if new == nil, do: [], else: String.split(new, "\n")

        header =
          "--- " <>
            if(status == :added, do: "/dev/null", else: "a/" <> path) <>
            "\n+++ " <> if(status == :deleted, do: "/dev/null", else: "b/" <> path)

        body =
          Enum.map_join(old_lines, "\n", &("-" <> &1)) <>
            if(old_lines == [], do: "", else: "\n") <> Enum.map_join(new_lines, "\n", &("+" <> &1))

        header <> if(body == "", do: "", else: "\n" <> body)
      end
    end)
  end

  defp decode_snapshot_file(%{"encoding" => "base64", "content" => content}), do: Base.decode64!(content)
  defp decode_snapshot_file(%{"content" => content}), do: content
  defp decode_snapshot_file(_), do: nil
  defp binary_snapshot?(%{"encoding" => "base64"}), do: true
  defp binary_snapshot?(_), do: false

  defp apply_files(workspace, source_path, changes) do
    root = workspace["root"]

    with {:ok, base} <- snapshot_from_workspace(workspace),
         :ok <- baseline_matches_workspace(workspace, base),
         {:ok, root_now} <- snapshot(root),
         {:ok, candidate_now} <- snapshot(source_path),
         :ok <- check_conflicts(changes, base, root_now, candidate_now),
         :ok <- Enum.reduce(changes, :ok, fn change, :ok -> apply_change(change, root, source_path) end) do
      :ok
    end
  end

  defp check_conflicts(changes, base, root_now, child_now) do
    Enum.reduce_while(changes, :ok, fn {status, path}, :ok ->
      base_file = Map.get(base, path)
      root_file = Map.get(root_now, path)
      child_file = Map.get(child_now, path)

      unchanged_or_applied? = unchanged_or_applied?(base_file, root_file, child_file)

      allowed? =
        case status do
          :added -> unchanged_or_applied?
          :modified -> unchanged_or_applied?
          :deleted -> unchanged_or_applied?
        end

      if allowed?,
        do: {:cont, :ok},
        else: {:halt, {:error, "workspace_conflict", "parent workspace touched " <> path}}
    end)
  end

  defp unchanged_or_applied?(nil, nil, _child), do: true
  defp unchanged_or_applied?(_base, nil, nil), do: true
  defp unchanged_or_applied?(_base, nil, _child), do: false
  defp unchanged_or_applied?(base, root, child), do: same_file?(root, base) or same_file?(root, child)

  defp same_file?(%{"sha256" => left}, %{"sha256" => right}), do: left == right
  defp same_file?(_, _), do: false

  defp apply_change({:added, rel}, root, child), do: copy_child_file(child, root, rel)
  defp apply_change({:modified, rel}, root, child), do: copy_child_file(child, root, rel)

  defp apply_change({:deleted, rel}, root, _child) do
    path = safe_join(root, rel)

    case File.rm(path) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, "workspace_apply_failed", "cannot delete " <> rel <> ": " <> inspect(reason)}
    end
  end

  defp copy_child_file(child, root, rel) do
    source = safe_join(child, rel)
    target = safe_join(root, rel)

    with {:ok, %File.Stat{type: :regular}} <- File.lstat(source),
         :ok <- reject_symlink_path(Path.dirname(target)),
         :ok <- File.mkdir_p(Path.dirname(target)),
         :ok <- File.cp(source, target) do
      :ok
    else
      {:error, :enoent} -> {:error, "workspace_apply_failed", "candidate file is missing " <> rel}
      {:error, "symlink_not_allowed"} -> {:error, "workspace_apply_failed", "symlink path is not allowed " <> rel}
      {:error, reason} -> {:error, "workspace_apply_failed", "cannot apply " <> rel <> ": " <> inspect(reason)}
      other -> other
    end
  end

  defp remove_workspace(%{"root" => root, "path" => path}) do
    with :ok <- ensure_workspace_path(root, path) do
      File.rm(base_snapshot_path(path))

      case File.rm_rf(path) do
        {:ok, _} -> :ok
        {:error, reason, _} -> {:error, "workspace_cleanup_failed", inspect(reason)}
      end
    end
  end

  defp remove_workspace(_), do: {:error, "workspace_invalid", "隔离工作区元数据无效"}

  @doc false
  def snapshot(root, opts \\ [])

  def snapshot(root, opts) when is_binary(root) and is_list(opts) do
    with :ok <- valid_snapshot_options(opts),
         :ok <- safe_directory(root) do
      case snapshot_dir(Path.expand(root), "", %{}, 0, snapshot_limits(opts)) do
        {:ok, manifest, _bytes} -> {:ok, manifest}
        error -> error
      end
    end
  end

  def snapshot(_, _), do: {:error, "bad_request", "snapshot root and options are invalid"}

  @doc false
  def snapshot_digest(snapshot) when is_map(snapshot), do: snapshot_ref(snapshot)
  def snapshot_digest(_), do: nil

  @doc false
  def materialize_snapshot(snapshot, target) when is_map(snapshot) and is_binary(target) do
    with :ok <- validate_snapshot(snapshot),
         :ok <- reject_symlink_path(target),
         :ok <- File.mkdir_p(target),
         :ok <- reject_symlink_path(target) do
      snapshot
      |> Enum.sort_by(fn {relative, _entry} -> relative end)
      |> Enum.reduce_while(:ok, fn {relative, entry}, :ok ->
        destination = safe_join(target, relative)

        with :ok <- reject_symlink_path(Path.dirname(destination)),
             :ok <- File.mkdir_p(Path.dirname(destination)),
             {:ok, content} <- decode_snapshot_file_safe(entry),
             :ok <- File.write(destination, content) do
          {:cont, :ok}
        else
          {:error, reason} -> {:halt, {:error, "workspace_copy_failed", inspect(reason)}}
        end
      end)
    end
  end

  def materialize_snapshot(_, _), do: {:error, "bad_request", "snapshot and target are invalid"}

  defp snapshot_dir(dir, rel, acc, bytes, limits) do
    with {:ok, names} <- File.ls(dir) do
      Enum.reduce_while(names, {:ok, acc, bytes}, fn name, {:ok, files, total_bytes} ->
        if excluded_entry?(name) do
          {:cont, {:ok, files, total_bytes}}
        else
          child = Path.join(dir, name)
          child_rel = if rel == "", do: name, else: Path.join(rel, name)

          case {safe_relative_path(child_rel), File.lstat(child)} do
            {{:error, reason}, _} ->
              {:halt, {:error, "workspace_unsupported_file", reason}}

            {:ok, {:ok, %File.Stat{type: :directory}}} ->
              case snapshot_dir(child, child_rel, files, total_bytes, limits) do
                {:ok, next, next_bytes} -> {:cont, {:ok, next, next_bytes}}
                error -> {:halt, error}
              end

            {:ok, {:ok, %File.Stat{type: :regular, size: size}}} when size > limits.max_file_bytes ->
              {:halt, {:error, "workspace_snapshot_limit", "文件超过冻结大小上限 " <> child_rel}}

            {:ok, {:ok, %File.Stat{type: :regular}}} ->
              case File.read(child) do
                {:ok, content} ->
                  next_bytes = total_bytes + byte_size(content)

                  cond do
                    map_size(files) >= limits.max_files ->
                      {:halt, {:error, "workspace_snapshot_limit", "冻结文件数量超过上限"}}

                    next_bytes > limits.max_bytes ->
                      {:halt, {:error, "workspace_snapshot_limit", "冻结源树超过字节上限"}}

                    true ->
                      {:cont, {:ok, Map.put(files, child_rel, snapshot_file(content)), next_bytes}}
                  end

                {:error, reason} ->
                  {:halt, {:error, "workspace_snapshot_failed", inspect(reason)}}
              end

            {:ok, {:ok, %File.Stat{type: :symlink}}} ->
              {:halt, {:error, "workspace_unsupported_file", "不支持符号链接 " <> child_rel}}

            {:ok, {:ok, _}} ->
              {:cont, {:ok, files, total_bytes}}

            {:ok, {:error, reason}} ->
              {:halt, {:error, "workspace_snapshot_failed", inspect(reason)}}
          end
        end
      end)
    end
  end

  defp excluded_entry?(name),
    do: MapSet.member?(@excluded_entries, name) or String.starts_with?(name, "_build") or sensitive_entry?(name)

  defp sensitive_entry?(name) do
    downcased = String.downcase(name)

    downcased in [".env", ".env.local", ".env.production", "auth.json", "credentials.json", "secrets.json"] or
      String.starts_with?(downcased, ".env.") or String.ends_with?(downcased, ".pem") or
      String.ends_with?(downcased, ".key") or
      String.ends_with?(downcased, ".p12") or String.ends_with?(downcased, ".pfx")
  end

  defp snapshot_file(content) do
    {encoding, stored} = if String.valid?(content), do: {"utf8", content}, else: {"base64", Base.encode64(content)}
    %{"sha256" => sha256(content), "bytes" => byte_size(content), "encoding" => encoding, "content" => stored}
  end

  defp snapshot_ref(snapshot), do: sha256(:erlang.term_to_binary(snapshot))
  defp sha256(content), do: :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)
  defp line_count(nil), do: 0
  defp line_count(content), do: length(String.split(content, "\n"))

  defp valid_snapshot_options(opts) do
    values = [
      Keyword.get(opts, :max_files, @default_snapshot_max_files),
      Keyword.get(opts, :max_bytes, @default_snapshot_max_bytes),
      Keyword.get(opts, :max_file_bytes, @default_snapshot_max_file_bytes)
    ]

    if Enum.all?(values, &(is_integer(&1) and &1 > 0)),
      do: :ok,
      else: {:error, "bad_request", "snapshot limits must be positive integers"}
  end

  defp snapshot_limits(opts) do
    %{
      max_files: Keyword.get(opts, :max_files, @default_snapshot_max_files),
      max_bytes: Keyword.get(opts, :max_bytes, @default_snapshot_max_bytes),
      max_file_bytes: Keyword.get(opts, :max_file_bytes, @default_snapshot_max_file_bytes)
    }
  end

  defp validate_snapshot(snapshot) do
    limits = snapshot_limits([])

    snapshot
    |> Enum.sort_by(fn {relative, _entry} -> relative end)
    |> Enum.reduce_while({:ok, 0, 0}, fn {relative, entry}, {:ok, count, bytes} ->
      with :ok <- safe_relative_path(relative),
           {:ok, content} <- decode_snapshot_file_safe(entry),
           true <- count < limits.max_files,
           true <- byte_size(content) <= limits.max_file_bytes,
           true <- bytes + byte_size(content) <= limits.max_bytes,
           true <- entry["bytes"] == byte_size(content),
           true <- entry["sha256"] == sha256(content) do
        {:cont, {:ok, count + 1, bytes + byte_size(content)}}
      else
        false -> {:halt, {:error, "workspace_snapshot_invalid", "snapshot entry metadata is invalid"}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, _count, _bytes} -> :ok
      error -> error
    end
  rescue
    _ -> {:error, "workspace_snapshot_invalid", "snapshot entry is invalid"}
  end

  defp decode_snapshot_file_safe(entry) do
    try do
      case decode_snapshot_file(entry) do
        content when is_binary(content) -> {:ok, content}
        _ -> {:error, "snapshot entry has no content"}
      end
    rescue
      _ -> {:error, "snapshot entry content is invalid"}
    end
  end

  defp safe_directory(path) do
    case File.lstat(Path.expand(path)) do
      {:ok, %File.Stat{type: :directory}} -> :ok
      {:ok, %File.Stat{type: :symlink}} -> {:error, "workspace_path_invalid", "工作根不能是符号链接"}
      {:ok, _} -> {:error, "workspace_missing", "工作根不是目录"}
      {:error, reason} -> {:error, "workspace_missing", inspect(reason)}
    end
  end

  defp safe_relative_path(relative) when is_binary(relative) do
    expanded = Path.expand(relative, "/workspace")
    components = Path.split(relative)

    if relative != "" and byte_size(relative) <= 1_024 and Path.type(relative) == :relative and
         not String.contains?(relative, <<0>>) and
         not Enum.any?(components, &(&1 in ["", ".", ".."])) and
         (expanded == "/workspace" or String.starts_with?(expanded, "/workspace/")),
       do: :ok,
       else: {:error, "unsafe relative path"}
  end

  defp safe_relative_path(_), do: {:error, "unsafe relative path"}

  defp reject_symlink_path(path) when is_binary(path) do
    path
    |> Path.expand()
    |> Path.split()
    |> Enum.reduce_while({:ok, ""}, fn component, {:ok, current} ->
      next = if component == "/", do: "/", else: Path.join(current, component)

      case File.lstat(next) do
        {:ok, %File.Stat{type: :symlink}} -> {:halt, {:error, "symlink_not_allowed"}}
        {:ok, _} -> {:cont, {:ok, next}}
        {:error, :enoent} -> {:halt, {:ok, next}}
        {:error, reason} -> {:halt, {:error, inspect(reason)}}
      end
    end)
    |> case do
      {:ok, _} -> :ok
      {:error, _} = error -> error
    end
  end

  defp reject_symlink_path(_), do: {:error, "symlink_not_allowed"}

  defp ensure_absent(path) do
    case File.lstat(path) do
      {:ok, _} -> {:error, "workspace_exists", "隔离工作区已存在"}
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, "workspace_path_invalid", inspect(reason)}
    end
  end

  defp ensure_workspace_path(root, path) do
    root = Path.expand(root)
    path = Path.expand(path)
    parent = Path.join([root, ".newbee", "workspaces"]) |> Path.expand()
    rel = Path.relative_to(path, parent)

    if rel != "." and not String.starts_with?(rel, "..") and Path.dirname(rel) == ".",
      do: :ok,
      else: {:error, "workspace_path_invalid", "隔离工作区路径越界"}
  end

  defp safe_join(root, rel) do
    path = Path.expand(Path.join(root, rel))

    if String.starts_with?(path, Path.expand(root) <> "/") or path == Path.expand(root),
      do: path,
      else: raise(ArgumentError, "workspace path escaped root")
  end

  defp existing_directory(path) do
    expanded = Path.expand(path)
    if File.dir?(expanded), do: {:ok, expanded}, else: {:error, "project_root_missing", "项目目录不存在"}
  end

  defp valid_session_id(session_id) do
    if Regex.match?(@session_id_re, session_id), do: :ok, else: {:error, "invalid_session_id", "子会话 ID 含非法字符"}
  end

  defp same_review(expected, actual) do
    if byte_size(expected) == byte_size(actual) and Plug.Crypto.secure_compare(expected, actual),
      do: :ok,
      else: {:error, "stale_review", "子代理变更已更新，请重新审查后再应用"}
  rescue
    _ -> {:error, "stale_review", "审查版本无效"}
  end

  defp truncate_patch(patch) when byte_size(patch) <= @display_patch_limit, do: patch
  defp truncate_patch(patch), do: binary_part(patch, 0, @display_patch_limit) <> "\n… diff 已截断 …\n"
end
