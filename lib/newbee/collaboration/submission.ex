defmodule Newbee.Collaboration.Submission do
  @moduledoc false

  alias Newbee.Collaboration.{Verification, Workspace}

  @submission_id_re ~r/\Asubmission-[0-9a-f]{32}\z/
  @max_files 4_096
  @max_bytes 64 * 1_024 * 1_024
  @max_file_bytes 16 * 1_024 * 1_024
  @digest_re ~r/\A[0-9a-f]{64}\z/
  @required_fields ~w(id task_id attempt root tree_sha256 acceptance_sha256 result_sha256 created_at)

  @doc "Capture an independently materialized, task-bound source candidate."
  def capture(task, work_root) when is_map(task) and is_binary(work_root) and work_root != "" do
    with {:ok, context} <- capture_context(task, work_root),
         {:ok, acceptance_sha256} <- acceptance_digest(task),
         {:ok, result_sha256} <- result_digest(task),
         {:ok, manifest} <-
           Workspace.snapshot(context.source_root,
             max_files: @max_files,
             max_bytes: @max_bytes,
             max_file_bytes: @max_file_bytes
           ),
         {:ok, id} <- new_id(),
         {:ok, paths} <- submission_paths(context.storage_root, id) do
      capture_files(context, manifest, paths, acceptance_sha256, result_sha256)
    end
  rescue
    error -> {:error, "capture_failed", Exception.message(error)}
  end

  def capture(_, _), do: {:error, "bad_request", "task and work root are invalid"}

  @doc "Return the validated frozen candidate root for a task."
  def verification_root(task) when is_map(task) do
    with :ok <- validate(task),
         {:ok, submission} <- fetch_submission(task) do
      {:ok, submission["root"]}
    end
  end

  def verification_root(_), do: {:error, "bad_request", "task is invalid"}

  @doc "Validate ownership, task contract, metadata, and the frozen source digest."
  def validate(task) when is_map(task) do
    with {:ok, submission} <- fetch_submission(task),
         :ok <- validate_submission_shape(submission),
         {:ok, context} <- validation_context(task),
         :ok <- validate_task_binding(task, submission),
         :ok <- validate_location(context, submission),
         {:ok, metadata} <- read_metadata(submission),
         :ok <- validate_metadata(metadata, context, submission),
         :ok <- validate_frozen_tree(submission) do
      :ok
    end
  end

  def validate(_), do: {:error, "bad_request", "task is invalid"}

  @doc false
  def cleanup(task) when is_map(task) do
    with {:ok, submission} <- fetch_submission(task),
         :ok <- validate_submission_shape(submission),
         {:ok, context} <- validation_context(task),
         :ok <- validate_location(context, submission),
         {:ok, paths} <- submission_paths(context.storage_root, submission["id"]),
         :ok <- remove_paths(paths) do
      :ok
    end
  end

  def cleanup(_), do: {:error, "bad_request", "task is invalid"}

  defp capture_files(context, manifest, paths, acceptance_sha256, result_sha256) do
    with :ok <- prepare_paths(paths),
         :ok <- Workspace.materialize_snapshot(manifest, paths.root),
         tree_sha256 <- Workspace.snapshot_digest(manifest),
         true <- is_binary(tree_sha256),
         created_at <- DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
         submission <- %{
           "id" => paths.id,
           "task_id" => context.task_id,
           "attempt" => context.attempt,
           "root" => paths.root,
           "tree_sha256" => tree_sha256,
           "acceptance_sha256" => acceptance_sha256,
           "result_sha256" => result_sha256,
           "created_at" => created_at
         },
         metadata <- metadata(context, submission),
         :ok <- write_metadata(paths.meta, metadata),
         :ok <- validate_frozen_tree(submission) do
      {:ok, submission}
    else
      false ->
        cleanup_capture(paths)
        {:error, "capture_failed", "workspace did not produce a source digest"}

      {:error, _code, _message} = error ->
        cleanup_capture(paths)
        error

      other ->
        cleanup_capture(paths)
        {:error, "capture_failed", inspect(other)}
    end
  end

  defp capture_context(task, work_root) do
    source_root = Path.expand(work_root)
    workspace = task["workspace"]
    workspace = if is_map(workspace), do: workspace, else: %{}

    with :ok <- safe_existing_directory(source_root),
         :ok <- expected_source(workspace, task, source_root),
         {:ok, project_root} <- project_root(workspace, source_root),
         true <-
           path_inside?(project_root, source_root) or
             {:error, "workspace_invalid", "source workspace is outside project root"},
         {:ok, storage_root} <- storage_root(project_root) do
      {:ok,
       %{
         task_id: task_id(task),
         attempt: attempt(task),
         source_root: source_root,
         project_root: project_root,
         storage_root: storage_root,
         base_ref: workspace["base_ref"]
       }}
    end
    |> unwrap_context()
  end

  defp unwrap_context({:ok, context}) do
    with {:ok, task_id} <- required_task_id(context.task_id),
         {:ok, attempt} <- required_attempt(context.attempt) do
      {:ok, %{context | task_id: task_id, attempt: attempt}}
    end
  end

  defp unwrap_context(error), do: error

  defp validation_context(task) do
    workspace = task["workspace"]
    workspace = if is_map(workspace), do: workspace, else: %{}
    source_root = workspace["path"] || task["work_root"]

    if is_binary(source_root) do
      validation_from_source(task, workspace, source_root)
    else
      validation_from_submission(task)
    end
  end

  defp validation_from_source(task, workspace, source_root) do
    source_root = Path.expand(source_root)

    with :ok <- safe_existing_directory(source_root),
         {:ok, project_root} <- project_root(workspace, source_root),
         true <-
           path_inside?(project_root, source_root) or
             {:error, "workspace_invalid", "source workspace is outside project root"},
         {:ok, storage_root} <- storage_root(project_root),
         {:ok, task_id} <- required_task_id(task_id(task)),
         {:ok, attempt} <- required_attempt(attempt(task)) do
      {:ok,
       %{
         task_id: task_id,
         attempt: attempt,
         source_root: source_root,
         project_root: project_root,
         storage_root: storage_root,
         base_ref: workspace["base_ref"]
       }}
    else
      {:error, _code, _message} = error -> error
    end
  end

  defp validation_from_submission(task) do
    with {:ok, submission} <- fetch_submission(task),
         root when is_binary(root) <- submission["root"],
         {:ok, metadata} <- read_metadata(submission),
         source_root when is_binary(source_root) <- metadata["source_root"],
         project_root <- inferred_project_root(root),
         :ok <- safe_existing_directory(source_root),
         :ok <- safe_existing_directory(project_root),
         true <-
           path_inside?(project_root, source_root) or
             {:error, "workspace_invalid", "source workspace is outside project root"},
         {:ok, storage_root} <- storage_root(project_root),
         {:ok, task_id} <- required_task_id(task_id(task)),
         {:ok, attempt} <- required_attempt(attempt(task)) do
      {:ok,
       %{
         task_id: task_id,
         attempt: attempt,
         source_root: source_root,
         project_root: project_root,
         storage_root: storage_root,
         base_ref: metadata["base_ref"]
       }}
    else
      {:error, _code, _message} = error -> error
      _ -> {:error, "workspace_missing", "task has no source workspace"}
    end
  end

  defp inferred_project_root(root) do
    root
    |> Path.expand()
    |> Path.dirname()
    |> Path.dirname()
    |> Path.dirname()
  end

  defp expected_source(workspace, task, source_root) do
    expected = workspace["path"] || task["work_root"] || task["root"]

    cond do
      is_binary(expected) and Path.expand(expected) == source_root -> :ok
      is_binary(expected) -> {:error, "workspace_mismatch", "capture root is not the task workspace"}
      true -> :ok
    end
  end

  defp project_root(workspace, source_root) do
    root = workspace["root"]
    root = if is_binary(root), do: Path.expand(root), else: source_root

    with :ok <- safe_existing_directory(root),
         true <-
           path_inside?(root, source_root) or {:error, "workspace_invalid", "source workspace is outside project root"} do
      {:ok, root}
    else
      {:error, _code, _message} = error -> error
    end
  end

  defp storage_root(project_root) do
    root = Path.join(project_root, ".newbee/submissions")

    case reject_symlink_components(root) do
      :ok -> {:ok, root}
      {:error, _} -> {:error, "workspace_path_invalid", "submission storage path contains a symlink"}
    end
  end

  defp submission_paths(storage_root, id) when is_binary(storage_root) and is_binary(id) do
    if Regex.match?(@submission_id_re, id) do
      storage_root = Path.expand(storage_root)
      root = Path.join(storage_root, id)
      meta = Path.join(storage_root, "." <> id <> ".meta")

      if path_inside?(storage_root, root) and Path.basename(root) == id,
        do: {:ok, %{id: id, root: root, meta: meta}},
        else: {:error, "workspace_path_invalid", "submission path escaped storage"}
    else
      {:error, "submission_invalid", "submission id is invalid"}
    end
  end

  defp prepare_paths(paths) do
    with :ok <- reject_symlink_components(Path.dirname(paths.root)),
         :ok <- ensure_absent(paths.root),
         :ok <- File.mkdir_p(Path.dirname(paths.root)),
         :ok <- File.mkdir(paths.root),
         :ok <- File.chmod(paths.root, 0o700) do
      :ok
    else
      {:error, :eexist} -> {:error, "submission_exists", "submission directory already exists"}
      {:error, reason} -> {:error, "capture_failed", inspect(reason)}
    end
  end

  defp write_metadata(path, metadata) do
    with :ok <- reject_symlink_components(Path.dirname(path)),
         :ok <- File.write(path, :erlang.term_to_binary(metadata, [:compressed])),
         :ok <- File.chmod(path, 0o600) do
      :ok
    else
      {:error, reason} -> {:error, "capture_failed", "cannot persist submission metadata: " <> inspect(reason)}
    end
  end

  defp metadata(context, submission) do
    %{
      "version" => 1,
      "id" => submission["id"],
      "task_id" => submission["task_id"],
      "attempt" => submission["attempt"],
      "root" => Path.expand(submission["root"]),
      "source_root" => context.source_root,
      "project_root" => context.project_root,
      "base_ref" => context.base_ref,
      "tree_sha256" => submission["tree_sha256"],
      "acceptance_sha256" => submission["acceptance_sha256"],
      "result_sha256" => submission["result_sha256"],
      "created_at" => submission["created_at"]
    }
  end

  defp validate_task_binding(task, submission) do
    with {:ok, task_id} <- required_task_id(task_id(task)),
         {:ok, attempt} <- required_attempt(attempt(task)),
         {:ok, acceptance_sha256} <- acceptance_digest(task),
         {:ok, result_sha256} <- result_digest(task),
         true <- submission["task_id"] == task_id,
         true <- submission["attempt"] == attempt,
         true <- submission["acceptance_sha256"] == acceptance_sha256,
         true <- submission["result_sha256"] == result_sha256 do
      :ok
    else
      false -> {:error, "submission_invalid", "submission is bound to a different task contract"}
      {:error, _code, _message} = error -> error
    end
  end

  defp validate_location(context, submission) do
    with {:ok, paths} <- submission_paths(context.storage_root, submission["id"]),
         true <- Path.expand(submission["root"]) == Path.expand(paths.root),
         true <- Path.basename(Path.expand(submission["root"])) == submission["id"],
         :ok <- safe_existing_directory(submission["root"]) do
      :ok
    else
      false -> {:error, "submission_invalid", "submission root is not owned by the task"}
      {:error, "workspace_missing", _} -> {:error, "submission_missing", "frozen submission root is missing"}
      {:error, _code, _message} = error -> error
    end
  end

  defp read_metadata(submission) do
    meta = Path.join(Path.dirname(Path.expand(submission["root"])), "." <> submission["id"] <> ".meta")

    case File.read(meta) do
      {:ok, binary} ->
        try do
          case :erlang.binary_to_term(binary, [:safe]) do
            metadata when is_map(metadata) -> {:ok, metadata}
            _ -> {:error, "submission_invalid", "submission metadata has an invalid shape"}
          end
        rescue
          _ -> {:error, "submission_invalid", "submission metadata is unreadable"}
        end

      {:error, :enoent} ->
        {:error, "submission_missing", "submission metadata is missing"}

      {:error, reason} ->
        {:error, "submission_invalid", "cannot read submission metadata: " <> inspect(reason)}
    end
  end

  defp validate_metadata(metadata, context, submission) do
    expected = metadata(context, submission)

    if Enum.all?(@required_fields, &(metadata[&1] == expected[&1])) and
         metadata["version"] == 1 and metadata["source_root"] == context.source_root and
         metadata["project_root"] == context.project_root and
         metadata["root"] == Path.expand(submission["root"]) do
      :ok
    else
      {:error, "submission_invalid", "submission metadata does not match its task"}
    end
  end

  defp validate_frozen_tree(submission) do
    case Workspace.snapshot(submission["root"],
           max_files: @max_files,
           max_bytes: @max_bytes,
           max_file_bytes: @max_file_bytes
         ) do
      {:ok, manifest} ->
        actual = Workspace.snapshot_digest(manifest)

        if actual == submission["tree_sha256"],
          do: :ok,
          else: {:error, "submission_changed", "frozen submission source digest changed"}

      {:error, _code, message} ->
        {:error, "submission_changed", "frozen submission cannot be read: " <> message}
    end
  end

  defp fetch_submission(%{"submission" => submission}) when is_map(submission), do: {:ok, submission}
  defp fetch_submission(_), do: {:error, "submission_missing", "task has no frozen submission"}

  defp validate_submission_shape(submission) do
    cond do
      not Enum.all?(@required_fields, &Map.has_key?(submission, &1)) ->
        {:error, "submission_invalid", "submission is missing required fields"}

      not is_binary(submission["id"]) or not Regex.match?(@submission_id_re, submission["id"]) ->
        {:error, "submission_invalid", "submission id is invalid"}

      not is_binary(submission["task_id"]) or submission["task_id"] == "" ->
        {:error, "submission_invalid", "submission task id is invalid"}

      not is_integer(submission["attempt"]) or submission["attempt"] < 0 ->
        {:error, "submission_invalid", "submission attempt is invalid"}

      not is_binary(submission["root"]) ->
        {:error, "submission_invalid", "submission root is invalid"}

      not valid_digest?(submission["tree_sha256"]) or
        not valid_digest?(submission["acceptance_sha256"]) or
          not valid_digest?(submission["result_sha256"]) ->
        {:error, "submission_invalid", "submission digest is invalid"}

      not is_binary(submission["created_at"]) ->
        {:error, "submission_invalid", "submission timestamp is invalid"}

      true ->
        :ok
    end
  end

  defp acceptance_digest(task) do
    case Verification.normalize_contract(task["acceptance"]) do
      {:ok, criteria} ->
        digest = Verification.contract_sha256(criteria)

        if is_nil(task["acceptance_sha256"]) or task["acceptance_sha256"] == digest,
          do: {:ok, digest},
          else: {:error, "submission_invalid", "task acceptance digest is stale"}

      {:error, _code, _message} = error ->
        error
    end
  end

  defp result_digest(task) do
    result = task["result"]

    if is_nil(result) do
      {:error, "result_required", "submission requires a task result"}
    else
      digest = Verification.value_sha256(result)

      if is_nil(task["result_sha256"]) or task["result_sha256"] == digest,
        do: {:ok, digest},
        else: {:error, "submission_invalid", "task result digest is stale"}
    end
  end

  defp task_id(task), do: task["task_id"]
  defp attempt(task), do: task["attempt"]

  defp required_task_id(value) when is_binary(value) and value != "", do: {:ok, value}
  defp required_task_id(_), do: {:error, "submission_invalid", "task id is required"}

  defp required_attempt(value) when is_integer(value) and value >= 0, do: {:ok, value}
  defp required_attempt(_), do: {:error, "submission_invalid", "task attempt is required"}

  defp new_id do
    {:ok, "submission-" <> Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)}
  rescue
    _ -> {:error, "capture_failed", "unable to allocate submission id"}
  end

  defp safe_existing_directory(path) when is_binary(path) do
    expanded = Path.expand(path)

    with :ok <- reject_symlink_components(expanded),
         {:ok, %File.Stat{type: :directory}} <- File.lstat(expanded) do
      :ok
    else
      {:ok, %File.Stat{type: :symlink}} -> {:error, "workspace_path_invalid", "path cannot be a symlink"}
      {:ok, _} -> {:error, "workspace_missing", "path is not a directory"}
      {:error, :enoent} -> {:error, "workspace_missing", "directory is missing"}
      {:error, reason} -> {:error, "workspace_path_invalid", inspect(reason)}
    end
  end

  defp safe_existing_directory(_), do: {:error, "workspace_missing", "directory is invalid"}

  defp reject_symlink_components(path) when is_binary(path) do
    path
    |> Path.expand()
    |> Path.split()
    |> Enum.reduce_while({:ok, ""}, fn component, {:ok, current} ->
      next = if component == "/", do: "/", else: Path.join(current, component)

      case File.lstat(next) do
        {:ok, %File.Stat{type: :symlink}} -> {:halt, {:error, :symlink}}
        {:ok, _} -> {:cont, {:ok, next}}
        {:error, :enoent} -> {:halt, {:ok, next}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp path_inside?(root, path) do
    root = Path.expand(root)
    path = Path.expand(path)
    path == root or String.starts_with?(path, root <> "/")
  end

  defp ensure_absent(path) do
    case File.lstat(path) do
      {:error, :enoent} -> :ok
      {:ok, _} -> {:error, :eexist}
      {:error, reason} -> {:error, reason}
    end
  end

  defp valid_digest?(value), do: is_binary(value) and Regex.match?(@digest_re, value)

  defp remove_paths(paths) do
    with :ok <- reject_symlink_components(Path.dirname(paths.root)),
         {:ok, _} <- File.rm_rf(paths.root),
         :ok <- remove_file(paths.meta) do
      :ok
    else
      {:error, reason} -> {:error, "submission_cleanup_failed", inspect(reason)}
      other -> other
    end
  end

  defp remove_file(path) do
    case File.rm(path) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp cleanup_capture(paths) do
    _ = File.rm_rf(paths.root)
    _ = File.rm(paths.meta)
    :ok
  end
end
