defmodule Newbee.Colony.Workspace do
  @moduledoc "Isolated worktrees include uncommitted source; plain directories use snapshots."
  alias Newbee.Colony.{Store, Workflow}

  def ensure(task, cwd) do
    cond do
      not Workflow.managed?(task) ->
        {:ok, cwd}

      is_map(task["workspace"]) ->
        path = task["workspace"]["path"]

        if is_binary(path) and File.dir?(path),
          do: {:ok, path},
          else: {:error, "workspace_missing", "工作目录丢失，不能在源项目上自动重放"}

      true ->
        source = task["workspace_source"] || cwd
        name = "colony-" <> String.replace(task["id"], ~r/[^a-zA-Z0-9._-]/, "_")

        with {:ok, snapshot} <- Newbee.Collaboration.Workspace.prepare(source, name, true),
             {:ok, workspace} <- attach_git(snapshot, source),
             {:ok, _} <- Store.update("tasks", task["id"], nil, &{:ok, Map.put(&1, "workspace", workspace)}) do
          {:ok, workspace["path"]}
        end
    end
  end

  # The snapshot is the current source (including dirty/untracked files), not only HEAD.
  # Checkout the index without touching files, then overlay that snapshot. No commit or push.
  defp attach_git(snapshot, source) do
    case git(source, ["rev-parse", "--verify", "HEAD"]) do
      {:ok, ref} ->
        ref = String.trim(ref)
        path = snapshot["path"]
        backup = path <> ".source"

        with :ok <- File.rename(path, backup),
             {:ok, _} <- git(source, ["worktree", "add", "--detach", "--no-checkout", path, ref]),
             {:ok, _} <- git(path, ["reset", "--mixed", ref]),
             {:ok, files} <- File.ls(backup),
             :ok <- copy_source(files, backup, path) do
          File.rm_rf(backup)
          {:ok, Map.merge(snapshot, %{"kind" => "git_worktree", "git_base" => ref})}
        else
          error -> {:error, "workspace_git_failed", "创建工作树失败；原始快照保留在 #{backup}：#{inspect(error)}"}
        end

      {:error, _} ->
        {:ok, snapshot}
    end
  end

  defp copy_source(files, source, target) do
    Enum.reduce_while(files, :ok, fn file, :ok ->
      case File.cp_r(Path.join(source, file), Path.join(target, file)) do
        {:ok, _} -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp git(cwd, args) do
    case System.cmd("git", args, cd: cwd, stderr_to_stdout: true, env: [{"GIT_TERMINAL_PROMPT", "0"}]) do
      {out, 0} -> {:ok, out}
      {out, _} -> {:error, out}
    end
  rescue
    error in ErlangError -> {:error, Exception.message(error)}
  end
end
