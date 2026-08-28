defmodule Newbee.Tools.Git do
  @moduledoc """
  Git 工具集 (DESIGN M3)：DEE 里的版本化操作。

  ## 函数清单
  - `status(dir \\ ".")` — `git status --short`，返回 `{:ok, output} | {:error, {code, output}}`。
  - `diff(dir \\ ".")` — `git diff --stat`。
  - `diff_full(dir \\ ".")` — `git diff` 全量。
  - `log(dir \\ ".", n \\ 10)` — `git log --oneline -n`。
  - `add_all(dir \\ ".")` — `git add -A`。
  - `commit(dir, msg)` — `git -c user.email=newbee@local -c user.name=newbee commit -m msg`。
  - `rollback(dir \\ ".")` — 回滚工作区到 `HEAD`（`checkout -- .` + `clean -fd lib/ test/`），宽松沙箱的撤销键（§8）。
  - `worktree_add(path, ref \\ "HEAD")` — 为子代理开独立 worktree。
  - `worktree_remove(path)` — 移除 worktree（`--force`）。

  内部 `run/2` 统一经 `System.cmd("git", ["-C", dir | args])`，失败返回 `{:error, {code, output}}`。

  ## 可跑示例
      {:ok, out} = Newbee.Tools.Git.status()
      {:ok, out} = Newbee.Tools.Git.diff()
      {:ok, out} = Newbee.Tools.Git.log(".", 5)
      {:ok, _} = Newbee.Tools.Git.add_all()
      {:ok, _} = Newbee.Tools.Git.commit(".", "fix: update")

  """

  def status(dir \\ "."), do: run(dir, ["status", "--short"])
  def diff(dir \\ "."), do: run(dir, ["diff", "--stat"])
  def diff_full(dir \\ "."), do: run(dir, ["diff"])
  def log(dir \\ ".", n \\ 10), do: run(dir, ["log", "--oneline", "-#{n}"])

  def add_all(dir \\ "."), do: run(dir, ["add", "-A"])

  def commit(dir \\ ".", msg),
    do: run(dir, ["-c", "user.email=newbee@local", "-c", "user.name=newbee", "commit", "-m", msg])

  @doc "回滚工作区到 HEAD（宽松沙箱的撤销键，§8）。"
  def rollback(dir \\ ".") do
    run(dir, ["checkout", "--", "."])
    run(dir, ["clean", "-fd", "lib/", "test/"])
  end

  @doc "worktree 隔离：为子代理开独立工作树。"
  def worktree_add(path, ref \\ "HEAD"), do: worktree_add(".", path, ref)
  def worktree_add(root, path, ref), do: run(root, ["worktree", "add", path, ref])
  def worktree_remove(path), do: worktree_remove(".", path)
  def worktree_remove(root, path), do: run(root, ["worktree", "remove", "--force", path])

  defp run(dir, args) do
    case System.cmd("git", ["-C", dir | args], stderr_to_stdout: true) do
      {out, 0} -> {:ok, String.trim(out)}
      {out, code} -> {:error, {code, String.trim(out)}}
    end
  end
end

:ok
