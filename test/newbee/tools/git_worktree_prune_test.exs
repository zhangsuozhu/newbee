defmodule Newbee.Tools.GitWorktreePruneTest do
  # Real git repositories under tmp; serial because they spawn processes and share /tmp.
  use ExUnit.Case, async: false

  alias Newbee.Tools.Git

  setup do
    root = Path.join(System.tmp_dir!(), "nbee-prune-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    git!(root, ["init", "-q"])
    git!(root, ["config", "user.email", "t@example.invalid"])
    git!(root, ["config", "user.name", "T"])
    File.write!(Path.join(root, "a.txt"), "a\n")
    git!(root, ["add", "."])
    git!(root, ["commit", "-qm", "base"])

    on_exit(fn -> File.rm_rf(root) end)
    %{root: root}
  end

  test "prune drops only registrations whose directory is gone", %{root: root} do
    gone = Path.join(root, "gone")
    kept = Path.join(root, "kept")
    assert {:ok, _} = Git.worktree_add(root, gone, "HEAD")
    assert {:ok, _} = Git.worktree_add(root, kept, "HEAD")

    # Deleting the directory by hand is what leaks the registration.
    File.rm_rf!(gone)
    assert registered?(root, gone)
    assert registered?(root, kept)

    assert {:ok, 1} = Git.worktree_prune(root)
    refute registered?(root, gone)
    # A live worktree must survive the prune.
    assert registered?(root, kept)
    assert File.dir?(kept)
  end

  test "prune is a no-op when nothing is stale", %{root: root} do
    assert {:ok, _} = Git.worktree_add(root, Path.join(root, "live"), "HEAD")
    assert {:ok, 0} = Git.worktree_prune(root)
  end

  defp registered?(root, path) do
    {output, 0} = System.cmd("git", ["worktree", "list", "--porcelain"], cd: root, stderr_to_stdout: true)
    String.contains?(output, "worktree " <> Path.expand(path))
  end

  defp git!(dir, args) do
    {_output, 0} = System.cmd("git", args, cd: dir, stderr_to_stdout: true)
    :ok
  end
end
