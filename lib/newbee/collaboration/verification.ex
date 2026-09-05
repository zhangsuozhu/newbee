defmodule Newbee.Collaboration.Verification do
  @moduledoc """
  Hive v2 的结构化验收契约与执行器。

  支持三种可复核检查：结构化 argv 命令、文件存在、文件 SHA-256。命令程序采用
  明确白名单，参数逐项 shell quote，并交给 `Newbee.Tools.Run` 的进程组超时/清理机制。
  验证在 Coordinator 之外执行，避免长命令阻塞协作单写者。
  """

  @programs ~w(mix cargo pytest python python3 npm pnpm yarn go make cmake ctest just)
  @max_criteria 32
  @max_args 64
  @max_arg_bytes 4_096
  @max_path_bytes 1_024
  @max_timeout_ms 600_000

  @doc "严格归一化验收契约；空契约、未知 kind、错误类型和超限输入均拒绝。"
  def normalize_contract([]),
    do: {:error, "acceptance_required", "Hive tasks need at least one structured acceptance criterion"}

  def normalize_contract(criteria) when is_list(criteria) and length(criteria) <= @max_criteria do
    criteria
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {criterion, index}, {:ok, acc} ->
      case normalize_criterion(criterion) do
        {:ok, normalized} -> {:cont, {:ok, [Map.put(normalized, "id", index + 1) | acc]}}
        {:error, message} -> {:halt, {:error, "bad_acceptance", "criterion #{index + 1}: #{message}"}}
      end
    end)
    |> case do
      {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
      error -> error
    end
  end

  def normalize_contract(criteria) when is_list(criteria),
    do: {:error, "acceptance_limit", "at most #{@max_criteria} acceptance criteria"}

  def normalize_contract(_),
    do: {:error, "bad_acceptance", "acceptance contract must be a structured array"}

  @doc "在给定工作根执行任务的结构化验收，返回带 contract_sha256 的 attestation。"
  def verify(task, root) when is_map(task) and is_binary(root) do
    with :ok <- valid_root(root),
         {:ok, criteria} <- normalize_contract(task["acceptance"]),
         {:ok, submission} <- verification_submission(task, root) do
      results = Enum.map(criteria, &run_criterion(&1, root))

      case verify_submission_after(task, root, submission) do
        :ok ->
          attestation = %{
            "contract_sha256" => contract_sha256(criteria),
            "checked_at" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
            "all_passed" => Enum.all?(results, & &1["passed"]),
            "results" => results
          }

          {:ok, put_submission_attestation(attestation, submission)}

        {:error, _code, _message} = error ->
          error
      end
    end
  end

  def verify(_, _), do: {:error, "bad_request", "task and work root are invalid"}

  @doc false
  def value_sha256(value) when is_binary(value), do: sha256(value)

  def value_sha256(value) do
    encoded =
      try do
        value |> canonical_json() |> IO.iodata_to_binary()
      rescue
        _ -> :erlang.term_to_binary(value)
      end

    sha256(encoded)
  end

  @doc "验收契约的稳定 SHA-256（Canonical JSON：map key 排序）。"
  def contract_sha256(criteria) when is_list(criteria) do
    criteria
    |> canonical_json()
    |> IO.iodata_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp valid_root(root) do
    case File.lstat(Path.expand(root)) do
      {:ok, %File.Stat{type: :directory}} -> :ok
      {:ok, %File.Stat{type: :symlink}} -> {:error, "workspace_invalid", "acceptance work root cannot be a symlink"}
      {:ok, _} -> {:error, "workspace_missing", "acceptance work root is not a directory"}
      {:error, _} -> {:error, "workspace_missing", "acceptance work root is missing"}
    end
  end

  defp verification_submission(task, root) do
    case task["submission"] do
      submission when is_map(submission) ->
        with :ok <- Newbee.Collaboration.Submission.validate(task),
             true <- Path.expand(root) == Path.expand(submission["root"]) do
          {:ok, submission}
        else
          false -> {:error, "submission_root_mismatch", "verification root is not the frozen submission"}
          {:error, _code, _message} = error -> error
        end

      _ ->
        {:ok, nil}
    end
  end

  defp verify_submission_after(_task, _root, nil), do: :ok

  defp verify_submission_after(task, root, submission) do
    with :ok <- Newbee.Collaboration.Submission.validate(task),
         true <- Path.expand(root) == Path.expand(submission["root"]) do
      :ok
    else
      false -> {:error, "submission_root_mismatch", "verification root is not the frozen submission"}
      {:error, _code, _message} = error -> error
    end
  end

  defp put_submission_attestation(attestation, nil), do: attestation

  defp put_submission_attestation(attestation, submission) do
    Map.merge(attestation, %{
      "submission_id" => submission["id"],
      "tree_sha256" => submission["tree_sha256"],
      "hermetic" => false,
      "execution_mode" => "non_hermetic",
      "execution_limitations" =>
        "commands execute on the host with configured dependency/build caches; only the frozen source tree is hashed"
    })
  end

  defp normalize_criterion(%{"kind" => "command"} = criterion) do
    program = criterion["program"]
    args = Map.get(criterion, "args", [])
    timeout = Map.get(criterion, "timeout_ms", 120_000)

    cond do
      program not in @programs ->
        {:error, "program must be one of #{Enum.join(@programs, ", ")}"}

      not is_list(args) or length(args) > @max_args or
          not Enum.all?(args, &(is_binary(&1) and byte_size(&1) <= @max_arg_bytes and not String.contains?(&1, <<0>>))) ->
        {:error, "args must be an array of texts, at most #{@max_args} items, each at most #{@max_arg_bytes} bytes"}

      not is_integer(timeout) or timeout < 1_000 or timeout > @max_timeout_ms ->
        {:error, "timeout_ms must sit in 1000..#{@max_timeout_ms}"}

      true ->
        {:ok, %{"kind" => "command", "program" => program, "args" => args, "timeout_ms" => timeout}}
    end
  end

  defp normalize_criterion(%{"kind" => "file_exists", "path" => path}) do
    with :ok <- relative_path(path) do
      {:ok, %{"kind" => "file_exists", "path" => path}}
    end
  end

  defp normalize_criterion(%{"kind" => "file_sha256", "path" => path, "sha256" => sha}) do
    with :ok <- relative_path(path),
         true <- is_binary(sha) and Regex.match?(~r/\A[0-9a-fA-F]{64}\z/, sha) do
      {:ok, %{"kind" => "file_sha256", "path" => path, "sha256" => String.downcase(sha)}}
    else
      false -> {:error, "sha256 must be 64 lowercase hex chars"}
      {:error, _} = error -> error
    end
  end

  defp normalize_criterion(_), do: {:error, "kind supports only command/file_exists/file_sha256"}

  defp run_criterion(%{"kind" => "command"} = criterion, root) do
    argv = [criterion["program"] | criterion["args"]]

    command =
      "cd #{shell_quote(root)} && " <> verification_env_prefix() <> "exec " <> Enum.map_join(argv, " ", &shell_quote/1)

    result = Newbee.Tools.Run.sh(command, timeout: criterion["timeout_ms"])
    output = result.output || ""

    criterion
    |> Map.put("passed", result.exit == 0)
    |> Map.put("exit_code", result.exit)
    |> Map.put("captured_output_sha256", sha256(output))
    |> Map.put("captured_output_bytes", byte_size(output))
    |> Map.put("output_truncated", String.contains?(output, "… [输出截断: 省略 "))
  rescue
    error ->
      criterion
      |> Map.put("passed", false)
      |> Map.put("error", "command_execution_failed: " <> Exception.message(error))
  end

  defp run_criterion(%{"kind" => "file_exists", "path" => path} = criterion, root) do
    case checked_path(root, path) do
      {:ok, absolute} -> criterion |> Map.put("passed", File.exists?(absolute))
      {:error, reason} -> criterion |> Map.put("passed", false) |> Map.put("error", reason)
    end
  end

  defp run_criterion(%{"kind" => "file_sha256", "path" => path} = criterion, root) do
    actual =
      with {:ok, absolute} <- checked_path(root, path),
           {:ok, digest} <- file_sha256(absolute) do
        digest
      else
        _ -> nil
      end

    criterion
    |> Map.put("actual_sha256", actual)
    |> Map.put("passed", actual == criterion["sha256"])
  end

  defp verification_env_prefix do
    deps_path = System.get_env("MIX_DEPS_PATH") || Path.join(File.cwd!(), "deps")

    if is_binary(deps_path) and File.dir?(deps_path),
      do: "MIX_DEPS_PATH=" <> shell_quote(Path.expand(deps_path)) <> " ",
      else: ""
  end

  defp relative_path(path) when is_binary(path) do
    candidate = Path.expand(path, "/workspace")

    if path != "" and byte_size(path) <= @max_path_bytes and Path.type(path) == :relative and
         (candidate == "/workspace" or String.starts_with?(candidate, "/workspace/")),
       do: :ok,
       else: {:error, "path must be a relative path inside the work root"}
  end

  defp relative_path(_), do: {:error, "path must be a text"}

  defp checked_path(root, path) do
    with :ok <- relative_path(path),
         :ok <- reject_symlink_components(root, path) do
      {:ok, safe_join(root, path)}
    end
  end

  defp reject_symlink_components(root, path) do
    Path.split(path)
    |> Enum.reduce_while(Path.expand(root), fn component, current ->
      candidate = Path.join(current, component)

      case File.lstat(candidate) do
        {:ok, %File.Stat{type: :symlink}} -> {:halt, {:error, "symlink_not_allowed"}}
        {:ok, _stat} -> {:cont, candidate}
        {:error, :enoent} -> {:halt, {:ok, candidate}}
        {:error, reason} -> {:halt, {:error, "path_check_failed:#{reason}"}}
      end
    end)
    |> case do
      {:error, _} = error -> error
      _path -> :ok
    end
  end

  defp file_sha256(path) do
    context =
      path
      |> File.stream!(64 * 1_024, [])
      |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))

    {:ok, context |> :crypto.hash_final() |> Base.encode16(case: :lower)}
  rescue
    _ -> {:error, "file_read_failed"}
  end

  defp safe_join(root, path) do
    candidate = Path.expand(path, root)
    root = Path.expand(root)

    if candidate == root or String.starts_with?(candidate, root <> "/"),
      do: candidate,
      else: raise(ArgumentError, "path escapes workspace")
  end

  defp shell_quote(value), do: "'" <> String.replace(to_string(value), "'", "'\"'\"'") <> "'"
  defp sha256(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)

  defp canonical_json(value) when is_map(value) do
    entries =
      value
      |> Enum.sort_by(fn {key, _value} -> to_string(key) end)
      |> Enum.map(fn {key, nested} -> [Jason.encode!(to_string(key)), ?:, canonical_json(nested)] end)
      |> Enum.intersperse(?,)

    [?{, entries, ?}]
  end

  defp canonical_json(value) when is_list(value) do
    [?[, value |> Enum.map(&canonical_json/1) |> Enum.intersperse(?,), ?]]
  end

  defp canonical_json(value), do: Jason.encode!(value)
end
