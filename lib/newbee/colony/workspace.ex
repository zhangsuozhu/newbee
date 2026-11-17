defmodule Newbee.Colony.Workspace do
  @moduledoc """
  Colony 任务的隔离工作目录。

  - 受管任务首次执行时物化独立工作区；Git 源用 detached worktree，非 Git 源用快照副本。
  - 快照只含源码：`deps` 与 `_build` 按排除规则留在源项目，物化后用绝对符号链接接入，
    使工作区里的 `mix` 无需手工 `ln -s`。链接目标缺失时只记录可读提示，不建悬空链接。
  - 工作树路径会整体 rename 后再就地重建，因此链接在 `attach_git/2` 之后重建。
  - 清理只按链接本身删除，并核对源项目 `deps`/`_build` 仍在。

  详见 `docs/isolated-workspace.md`。
  """

  alias Newbee.Colony.{Store, Workflow}
  alias Newbee.Collaboration.Workspace, as: Isolated

  @artifacts ["deps", "_build"]

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

        if Path.expand(source) == "/" do
          {:ok, "/"}
        else
          create(task, source)
        end
    end
  end

  @doc "清理已结束任务的隔离目录；共享目录和缺失工作区不会被误删。"
  def cleanup(%{"workspace" => %{"review_status" => "cleaned"}}), do: :ok

  def cleanup(%{"workspace" => %{"kind" => kind} = workspace})
      when kind in ["filesystem_copy", "git_worktree"],
      do: Isolated.discard_orphan(workspace)

  def cleanup(_), do: {:error, "workspace_missing", "任务没有可清理的隔离工作区"}

  defp create(task, source) do
    name = "colony-" <> String.replace(task["id"], ~r/[^a-zA-Z0-9._-]/, "_")

    case do_create(task, source, name) do
      {:ok, _path} = ok ->
        ok

      {:error, _code, _message} = error ->
        _ = rollback(source, name)
        error
    end
  end

  defp do_create(task, source, name) do
    with {:ok, snapshot} <- Isolated.prepare(source, name, true),
         {:ok, workspace} <- attach_git(snapshot, source),
         {:ok, workspace} <- relink_build_artifacts(workspace, source),
         {:ok, _} <- Store.update("tasks", task["id"], nil, &{:ok, Map.put(&1, "workspace", workspace)}) do
      {:ok, workspace["path"]}
    end
  end

  # 创建失败的补偿：删掉本次可能建出的工作区，源项目本身不受影响。
  # 按工作区真实 kind 删除——`attach_git/2` 之后它是注册过的 worktree，
  # 当普通目录删会留下过期的 .git/worktrees 条目。拿不到记录时按路径探测。
  defp rollback(source, name) do
    path = Path.join([Path.expand(source), ".newbee", "workspaces", name])

    kind =
      case worktree_registered?(source, path) do
        true -> "git_worktree"
        false -> "filesystem_copy"
      end

    _ = Isolated.discard_orphan(%{"kind" => kind, "root" => source, "path" => path})
    # attach 半途失败时目录可能还没建出来，注册也可能残留，统一兜一次 prune。
    _ = git(source, ["worktree", "prune"])
    :ok
  end

  defp worktree_registered?(source, path) do
    case git(source, ["worktree", "list", "--porcelain"]) do
      {:ok, out} -> String.contains?(out, "worktree " <> Path.expand(path) <> "\n")
      _ -> false
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

  # `attach_git/2` renames the materialized snapshot away and recreates the worktree in
  # place, so deps/_build links from `prepare/4` would point at the moved (then deleted)
  # directory. Rebuild them against the source so no dangling link survives.
  defp relink_build_artifacts(%{"path" => path} = workspace, source) when is_binary(path) do
    workspace
    |> requested_artifacts()
    |> Enum.reduce_while({:ok, workspace}, fn name, {:ok, acc} ->
      case relink_artifact(source, path, name) do
        {:ok, entry} -> {:cont, {:ok, put_artifact(acc, entry)}}
        {:error, _code, _message} = error -> {:halt, error}
      end
    end)
  end

  defp relink_build_artifacts(workspace, _source), do: {:ok, workspace}

  # 只有 prepare 记录过、或历史上手工接入过的产物才重建；默认至少覆盖 deps。
  defp requested_artifacts(workspace) do
    names =
      workspace["build_artifacts"]
      |> case do
        entries when is_list(entries) ->
          Enum.flat_map(entries, fn
            %{"name" => name} when is_binary(name) -> [name]
            _ -> []
          end)

        _ ->
          Enum.filter(@artifacts, &symlink?(Path.join(workspace["path"] || "", &1)))
      end
      |> Enum.uniq()

    if names == [], do: ["deps"], else: names
  end

  defp relink_artifact(source, path, name) do
    link = Path.join(path, name)
    if symlink?(link), do: File.rm(link)

    case Isolated.build_artifact_target(Path.join(source, name)) do
      {:ok, target} ->
        case File.ln_s(target, link) do
          :ok ->
            {:ok, %{"name" => name, "status" => "linked", "target" => target, "message" => nil}}

          {:error, reason} ->
            {:error, "workspace_link_failed", "无法把源项目 #{name} 接入工作树：#{inspect(reason)}"}
        end

      {:error, :enoent} ->
        {:ok,
         %{
           "name" => name,
           "status" => "missing",
           "target" => nil,
           "message" => "源项目没有 #{name}，未建立链接；工作树内的 mix 需自行准备依赖"
         }}

      {:error, reason} ->
        {:error, "workspace_link_failed", "无法解析源项目 #{name}：#{inspect(reason)}"}
    end
  end

  defp put_artifact(workspace, entry) do
    entries =
      workspace["build_artifacts"]
      |> case do
        list when is_list(list) -> Enum.reject(list, &(is_map(&1) and &1["name"] == entry["name"]))
        _ -> []
      end
      |> Kernel.++([entry])

    missing =
      entries
      |> Enum.filter(&(is_map(&1) and &1["status"] != "linked" and is_binary(&1["message"])))
      |> Enum.map(& &1["message"])

    workspace = Map.put(workspace, "build_artifacts", entries)

    if missing == [],
      do: Map.delete(workspace, "warning"),
      else: Map.put(workspace, "warning", Enum.join(missing, "；"))
  end

  defp symlink?(path), do: match?({:ok, %File.Stat{type: :symlink}}, File.lstat(path))

  defp git(cwd, args) do
    case System.cmd("git", args, cd: cwd, stderr_to_stdout: true, env: [{"GIT_TERMINAL_PROMPT", "0"}]) do
      {out, 0} -> {:ok, out}
      {out, _} -> {:error, out}
    end
  rescue
    error in ErlangError -> {:error, Exception.message(error)}
  end
end
