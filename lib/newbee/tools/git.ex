defmodule Newbee.Tools.Git do
  @moduledoc """
  Git 结构化操作工具；优先于手写 `Run.sh("git ...")`。

  ## 函数清单
  - `status(dir \\\\ ".")` — `git status --short`，返回 `{:ok, output} | {:error, {code, output}}`。
  - `diff(dir \\\\ ".")` — `git diff --stat`。
  - `diff_full(dir \\\\ ".")` — `git diff` 全量。
  - `log(dir \\\\ ".", n \\\\ 10)` — `git log --oneline -n`。
  - `add_all(dir \\\\ ".")` — `git add -A`。
  - `commit(dir \\\\ ".", msg)` — `git -c user.email=newbee@local -c user.name=newbee commit -m msg`。
  - `rollback(dir \\\\ ".")` — 回滚工作区到 `HEAD`（`checkout -- .` + `clean -fd lib/ test/`），宽松沙箱的撤销键（§8）。
  - `worktree_add(path, ref \\\\ "HEAD")` — 为子代理开独立 worktree。
  - `worktree_remove(path)` — 移除 worktree（`--force`）。

  内部 `run/2` 统一经 `System.cmd("git", ["-C", dir | args])`，失败返回 `{:error, {code, output}}`。

  ## 可跑示例
      {:ok, out} = Newbee.Tools.Git.status()
      {:ok, stat} = Newbee.Tools.Git.diff()
      {:ok, full} = Newbee.Tools.Git.diff_full()
      {:ok, recent} = Newbee.Tools.Git.log(".", 5)
      {:ok, _} = Newbee.Tools.Git.add_all()
      {:ok, _} = Newbee.Tools.Git.commit("fix: update")
      {:ok, _} = Newbee.Tools.Git.commit("/tmp/repo", "fix: update")
      {:ok, _} = Newbee.Tools.Git.worktree_add("/tmp/repo-wt", "HEAD")
      {:ok, _} = Newbee.Tools.Git.worktree_remove("/tmp/repo-wt")
      {:ok, _} = Newbee.Tools.Git.rollback("/tmp/disposable-repo")

  `commit`、`rollback` 和 worktree 示例会改变仓库，只能用于明确选定的临时/隔离仓库；检查类函数可直接在当前工程调用。

  """

  @doc "返回 git status --short：{:ok, output} | {:error, {code, output}}。"
  def status(dir \\ "."), do: run(dir, ["status", "--short"])
  @doc "返回 git diff --stat。"
  def diff(dir \\ "."), do: run(dir, ["diff", "--stat"])
  @doc "返回完整 git diff。"
  def diff_full(dir \\ "."), do: run(dir, ["diff"])
  @doc "返回最近 n 条 git log --oneline。"
  def log(dir \\ ".", n \\ 10), do: run(dir, ["log", "--oneline", "-#{n}"])

  @doc "执行 git add -A；会修改索引。"
  def add_all(dir \\ "."), do: run(dir, ["add", "-A"])

  @doc "提交已暂存改动；commit(msg) 使用当前目录，commit(dir, msg) 使用指定仓库。"
  def commit(dir \\ ".", msg),
    do: run(dir, ["-c", "user.email=newbee@local", "-c", "user.name=newbee", "commit", "-m", msg])

  @doc "回滚工作区到 HEAD（宽松沙箱的撤销键，§8）。"
  def rollback(dir \\ ".") do
    run(dir, ["checkout", "--", "."])
    run(dir, ["clean", "-fd", "lib/", "test/"])
  end

  @doc "worktree 隔离：为子代理开独立工作树（默认在当前仓库根，ref 默认 HEAD）。"
  def worktree_add(path, ref \\ "HEAD"), do: worktree_add(".", path, ref)

  @doc "worktree_add/3：在指定根仓库 root 下开独立工作树。"
  def worktree_add(root, path, ref), do: run(root, ["worktree", "add", path, ref])

  @doc "强制移除指定 Git worktree（默认当前仓库根）。"
  def worktree_remove(path), do: worktree_remove(".", path)

  @doc "worktree_remove/2：在指定根仓库 root 下强制移除 worktree。"
  def worktree_remove(root, path), do: run(root, ["worktree", "remove", "--force", path])

  defp run(dir, args) do
    case System.cmd("git", ["-C", dir | args], stderr_to_stdout: true) do
      {out, 0} -> {:ok, String.trim(out)}
      {out, code} -> {:error, {code, String.trim(out)}}
    end
  end
end
