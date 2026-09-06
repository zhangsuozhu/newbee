defmodule Newbee.Tools.Git do
  @moduledoc """
  Structured Git operations; prefer over hand-written `Run.sh("git ...")`.

  ## Functions
  - `status(dir \\\\ ".")` — `git status --short`; `{:ok, output} | {:error, {code, output}}`.
  - `diff(dir \\\\ ".")` — `git diff --stat`.
  - `diff_full(dir \\\\ ".")` — full `git diff`.
  - `log(dir \\\\ ".", n \\\\ 10)` — last n `git log --oneline`.
  - `add_all(dir \\\\ ".")` — `git add -A`.
  - `commit(dir \\\\ ".", msg)` — `git -c user.email=newbee@local -c user.name=newbee commit -m msg`.
  - `rollback(dir \\\\ ".")` — roll the workspace back to `HEAD` (`checkout -- .` + `clean -fd lib/ test/`); the undo key of the lenient sandbox.
  - `worktree_add(path, ref \\\\ "HEAD")` — open an isolated worktree for a subagent.
  - `worktree_remove(path)` — remove a worktree (`--force`).

  `run/2` funnels everything through `System.cmd("git", ["-C", dir | args])`, failing as `{:error, {code, output}}`.

  ## Runnable example
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

  `commit`, `rollback`, and the worktree examples mutate repos — use only on explicitly chosen temp/isolated repos; read-only fns are safe on the current project.

  """

  @doc "git status --short: {:ok, output} | {:error, {code, output}}."
  def status(dir \\ "."), do: run(dir, ["status", "--short"])
  @doc "git diff --stat. Returns `{:ok, output} | {:error, {code, output}}`."
  def diff(dir \\ "."), do: run(dir, ["diff", "--stat"])
  @doc "Full git diff. Returns `{:ok, output} | {:error, {code, output}}`."
  def diff_full(dir \\ "."), do: run(dir, ["diff"])
  @doc "Last n git log --oneline entries. Returns `{:ok, output} | {:error, {code, output}}`."
  def log(dir \\ ".", n \\ 10), do: run(dir, ["log", "--oneline", "-#{n}"])

  @doc "Run git add -A; mutates the index. Returns `{:ok, output} | {:error, {code, output}}`."
  def add_all(dir \\ "."), do: run(dir, ["add", "-A"])

  @doc "Commit staged changes; commit(msg) uses the current dir, commit(dir, msg) targets a repo. Returns `{:ok, output} | {:error, {code, output}}`."
  def commit(dir \\ ".", msg),
    do: run(dir, ["-c", "user.email=newbee@local", "-c", "user.name=newbee", "commit", "-m", msg])

  @doc "Roll the workspace back to HEAD (the lenient sandbox's undo key). Returns `{:ok, output} | {:error, {code, output}}`. (checkout + clean)."
  def rollback(dir \\ ".") do
    run(dir, ["checkout", "--", "."])
    run(dir, ["clean", "-fd", "lib/", "test/"])
  end

  @doc "Worktree isolation: open a detached worktree for a subagent (root defaults to the current repo, ref to HEAD). Returns `{:ok, output} | {:error, {code, output}}`."
  def worktree_add(path, ref \\ "HEAD"), do: worktree_add(".", path, ref)

  @doc "worktree_add/3: open a detached worktree under the root repo. Returns `{:ok, output} | {:error, {code, output}}`."
  def worktree_add(root, path, ref), do: run(root, ["worktree", "add", path, ref])

  @doc "Force-remove a Git worktree (root defaults to the current repo). Returns `{:ok, output} | {:error, {code, output}}`."
  def worktree_remove(path), do: worktree_remove(".", path)

  @doc "worktree_remove/2: force-remove a worktree under the root repo. Returns `{:ok, output} | {:error, {code, output}}`."
  def worktree_remove(root, path), do: run(root, ["worktree", "remove", "--force", path])

  defp run(dir, args) do
    case System.cmd("git", ["-C", dir | args], stderr_to_stdout: true) do
      {out, 0} -> {:ok, String.trim(out)}
      {out, code} -> {:error, {code, String.trim(out)}}
    end
  end
end
