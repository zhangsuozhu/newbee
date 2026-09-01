defmodule Newbee.Collaboration.Workspace do
  @moduledoc """
  通用子会话工作区：默认文件系统副本，不依赖 Git。
  `isolate: false` 才使用共享目录，旧的 Git worktree 元数据仍可兼容读取。
  """

  @display_patch_limit 600_000
  @session_id_re ~r/\A[0-9A-Za-z._-]{1,96}\z/
  @terminal_review_states ~w(applied rejected)

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
         :ok <- apply_files(workspace, patch_info.changes) do
      {:ok, Map.drop(patch_info, [:patch, :changes])}
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

  defp cleanup_workspace(%{"workspace" => workspace}) when is_map(workspace) do
    with :ok <- validate_workspace(workspace), do: {:ok, workspace}
  end

  defp cleanup_workspace(_), do: {:error, "workspace_invalid", "隔离工作区元数据无效"}

  defp task_workspace(%{"workspace" => workspace}) when is_map(workspace) do
    with :ok <- reviewable(workspace),
         :ok <- validate_workspace(workspace) do
      {:ok, workspace}
    end
  end

  defp task_workspace(_), do: {:error, "workspace_missing", "任务没有可审查的隔离工作区"}

  defp reviewable(%{"kind" => "shared"}), do: {:error, "not_reviewable", "该子代理使用共享目录，没有独立变更可审查"}
  defp reviewable(%{"review_status" => "cleaned"}), do: {:error, "workspace_cleaned", "隔离工作区已清理"}
  defp reviewable(%{"kind" => kind}) when kind in ["filesystem_copy", "git_worktree"], do: :ok
  defp reviewable(_), do: {:error, "workspace_invalid", "隔离工作区元数据无效"}

  defp validate_workspace(%{"kind" => kind, "root" => root, "path" => path})
       when kind in ["filesystem_copy", "git_worktree"] and is_binary(root) and is_binary(path) do
    ensure_workspace_path(root, path)
  end

  defp validate_workspace(%{"kind" => "shared", "root" => root, "path" => path}) when is_binary(root) and root == path,
    do: :ok

  defp validate_workspace(_), do: {:error, "workspace_invalid", "隔离工作区元数据无效"}

  defp terminal_task(%{"status" => status}) when status in ["succeeded", "failed", "cancelled"], do: :ok
  defp terminal_task(_), do: {:error, "task_not_terminal", "任务结束后才能审查变更"}

  defp require_review_state(workspace, expected) when is_binary(expected) do
    if workspace["review_status"] == expected, do: :ok, else: {:error, "invalid_workspace_state", "当前工作区状态不允许此操作"}
  end

  defp require_review_state(workspace, allowed) when is_list(allowed) do
    if workspace["review_status"] in allowed, do: :ok, else: {:error, "invalid_workspace_state", "当前工作区状态不允许清理"}
  end

  defp build_patch(workspace) do
    with {:ok, base} <- snapshot_from_workspace(workspace),
         {:ok, current} <- snapshot(workspace["path"]) do
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
          if is_map(snapshot), do: {:ok, snapshot}, else: {:error, "workspace_snapshot_invalid", "基线快照格式无效"}
        rescue
          _ -> {:error, "workspace_snapshot_invalid", "基线快照格式无效"}
        end

      {:error, :enoent} ->
        {:error, "workspace_snapshot_missing", "工作区缺少基线快照"}

      {:error, reason} ->
        {:error, "workspace_snapshot_failed", inspect(reason)}
    end
  end

  defp snapshot_from_workspace(_), do: {:error, "workspace_snapshot_missing", "工作区缺少基线快照"}

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

  defp apply_files(workspace, changes) do
    root = workspace["root"]
    path = workspace["path"]

    with {:ok, base} <- snapshot_from_workspace(workspace),
         {:ok, root_now} <- snapshot(root),
         {:ok, child_now} <- snapshot(path),
         :ok <- check_conflicts(changes, base, root_now, child_now),
         :ok <- Enum.reduce(changes, :ok, fn change, :ok -> apply_change(change, root, path) end) do
      :ok
    end
  end

  defp check_conflicts(changes, base, root_now, child_now) do
    Enum.reduce_while(changes, :ok, fn {status, path}, :ok ->
      base_file = Map.get(base, path)
      root_file = Map.get(root_now, path)
      child_file = Map.get(child_now, path)

      unchanged_or_applied? =
        is_nil(root_file) or same_file?(root_file, base_file) or same_file?(root_file, child_file)

      allowed? =
        case status do
          :added -> unchanged_or_applied?
          :modified -> unchanged_or_applied?
          :deleted -> unchanged_or_applied?
        end

      if allowed?,
        do: {:cont, :ok},
        else: {:halt, {:error, "workspace_conflict", "父工作区已修改 " <> path}}
    end)
  end

  defp same_file?(%{"sha256" => left}, %{"sha256" => right}), do: left == right
  defp same_file?(_, _), do: false

  defp apply_change({:added, rel}, root, child), do: copy_child_file(child, root, rel)
  defp apply_change({:modified, rel}, root, child), do: copy_child_file(child, root, rel)

  defp apply_change({:deleted, rel}, root, _child) do
    path = safe_join(root, rel)

    case File.rm(path) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, "workspace_apply_failed", "无法删除 " <> rel <> ": " <> inspect(reason)}
    end
  end

  defp copy_child_file(child, root, rel) do
    source = safe_join(child, rel)
    target = safe_join(root, rel)

    with :ok <- File.mkdir_p(Path.dirname(target)),
         :ok <- File.cp(source, target) do
      :ok
    else
      {:error, reason} -> {:error, "workspace_apply_failed", "无法应用 " <> rel <> ": " <> inspect(reason)}
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

  defp snapshot(root), do: snapshot_dir(root, "", %{})

  defp snapshot_dir(dir, rel, acc) do
    with {:ok, names} <- File.ls(dir) do
      Enum.reduce_while(names, {:ok, acc}, fn name, {:ok, files} ->
        if excluded_entry?(name) do
          {:cont, {:ok, files}}
        else
          child = Path.join(dir, name)
          child_rel = if rel == "", do: name, else: Path.join(rel, name)

          case File.lstat(child) do
            {:ok, %File.Stat{type: :directory}} ->
              case snapshot_dir(child, child_rel, files) do
                {:ok, next} -> {:cont, {:ok, next}}
                error -> {:halt, error}
              end

            {:ok, %File.Stat{type: :regular}} ->
              case File.read(child) do
                {:ok, content} -> {:cont, {:ok, Map.put(files, child_rel, snapshot_file(content))}}
                {:error, reason} -> {:halt, {:error, "workspace_snapshot_failed", inspect(reason)}}
              end

            {:ok, %File.Stat{type: :symlink}} ->
              {:halt, {:error, "workspace_unsupported_file", "不支持符号链接 " <> child_rel}}

            {:ok, _} ->
              {:cont, {:ok, files}}

            {:error, reason} ->
              {:halt, {:error, "workspace_snapshot_failed", inspect(reason)}}
          end
        end
      end)
    end
  end

  defp excluded_entry?(name), do: MapSet.member?(@excluded_entries, name) or String.starts_with?(name, "_build")

  defp snapshot_file(content) do
    {encoding, stored} = if String.valid?(content), do: {"utf8", content}, else: {"base64", Base.encode64(content)}
    %{"sha256" => sha256(content), "bytes" => byte_size(content), "encoding" => encoding, "content" => stored}
  end

  defp snapshot_ref(snapshot), do: sha256(:erlang.term_to_binary(snapshot))
  defp sha256(content), do: :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)
  defp line_count(nil), do: 0
  defp line_count(content), do: length(String.split(content, "\n"))

  defp materialize_snapshot(snapshot, target) do
    snapshot
    |> Task.async_stream(
      fn {relative, entry} ->
        destination = safe_join(target, relative)

        with :ok <- File.mkdir_p(Path.dirname(destination)),
             :ok <- File.write(destination, decode_snapshot_file(entry)) do
          :ok
        end
      end,
      max_concurrency: max(System.schedulers_online(), 4),
      ordered: false,
      timeout: :infinity
    )
    |> Enum.reduce_while(:ok, fn
      {:ok, :ok}, :ok -> {:cont, :ok}
      {:ok, {:error, reason}}, :ok -> {:halt, {:error, "workspace_copy_failed", inspect(reason)}}
      {:exit, reason}, :ok -> {:halt, {:error, "workspace_copy_failed", inspect(reason)}}
    end)
  end

  defp ensure_absent(path) do
    if File.exists?(path), do: {:error, "workspace_exists", "隔离工作区已存在"}, else: :ok
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
