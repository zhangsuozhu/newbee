defmodule Newbee.Collaboration.WorkspaceTest do
  use ExUnit.Case, async: false

  alias Newbee.Collaboration.Workspace

  setup do
    root = Path.join(System.tmp_dir!(), "newbee-workspace-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, "lib"))
    File.write!(Path.join(root, "base.txt"), "base\n")
    File.write!(Path.join(root, "lib/nested.txt"), "nested\n")

    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  test "auto 在无 Git 项目创建文件系统副本并继承嵌套文件", %{root: root} do
    assert {:ok, workspace} = Workspace.prepare(root, "child-copy", :auto)
    assert workspace["kind"] == "filesystem_copy"
    assert is_binary(workspace["base_ref"])
    assert File.dir?(workspace["path"])
    assert File.read!(Path.join(workspace["path"], "base.txt")) == "base\n"
    assert File.read!(Path.join(workspace["path"], "lib/nested.txt")) == "nested\n"
    refute File.exists?(Path.join(root, ".git"))

    assert {:ok, _} = Workspace.cleanup(terminal_task(workspace, "rejected"))
    refute File.exists?(workspace["path"])
  end

  test "审查、应用和重复应用不依赖 Git", %{root: root} do
    assert {:ok, workspace} = Workspace.prepare(root, "child-apply", true)
    File.write!(Path.join(workspace["path"], "base.txt"), "base\nchild\n")
    File.write!(Path.join(workspace["path"], "new.txt"), "new\n")
    task = terminal_task(workspace, "pending")

    assert {:ok, review} = Workspace.review(task)
    assert review.dirty
    assert Enum.map(review.files, & &1.path) |> Enum.sort() == ["base.txt", "new.txt"]
    assert review.patch_sha256 =~ ~r/\A[0-9a-f]{64}\z/

    assert {:error, "stale_review", _} = Workspace.apply(task, String.duplicate("0", 64))
    assert {:ok, applied} = Workspace.apply(task, review.patch_sha256)
    assert applied.patch_sha256 == review.patch_sha256
    assert {:ok, _idempotent} = Workspace.apply(task, review.patch_sha256)
    assert File.read!(Path.join(root, "base.txt")) == "base\nchild\n"
    assert File.read!(Path.join(root, "new.txt")) == "new\n"

    assert {:ok, _} = Workspace.cleanup(terminal_task(workspace, "applied"))
    refute File.exists?(workspace["path"])
  end

  test "二进制文件快照可 JSON 编码并按原字节应用", %{root: root} do
    original = <<0x89, 0x50, 0x4E, 0x47, 0xFF>>
    changed = <<0x89, 0x50, 0x4E, 0x47, 0xFE>>
    File.write!(Path.join(root, "image.bin"), original)

    assert {:ok, workspace} = Workspace.prepare(root, "child-binary", :auto)
    assert {:ok, _json} = Jason.encode(workspace)
    File.write!(Path.join(workspace["path"], "image.bin"), changed)
    task = terminal_task(workspace, "pending")

    assert {:ok, review} = Workspace.review(task)
    assert [%{path: "image.bin", binary: true}] = review.files
    assert review.display_patch =~ "Binary files"
    assert {:ok, _} = Workspace.apply(task, review.patch_sha256)
    assert File.read!(Path.join(root, "image.bin")) == changed
    assert {:ok, _} = Workspace.cleanup(terminal_task(workspace, "applied"))
  end

  test "父目录同文件发生变化时拒绝应用", %{root: root} do
    assert {:ok, workspace} = Workspace.prepare(root, "child-conflict", true)
    File.write!(Path.join(workspace["path"], "base.txt"), "base\nchild\n")
    File.write!(Path.join(root, "base.txt"), "parent\n")
    task = terminal_task(workspace, "pending")

    assert {:ok, review} = Workspace.review(task)
    assert {:error, "workspace_conflict", _} = Workspace.apply(task, review.patch_sha256)
    assert File.read!(Path.join(root, "base.txt")) == "parent\n"
    assert {:ok, _} = Workspace.cleanup(terminal_task(workspace, "rejected"))
  end

  test "拒绝保留证据直到显式清理，路径伪造被拒绝", %{root: root} do
    assert {:ok, workspace} = Workspace.prepare(root, "child-reject", true)
    File.write!(Path.join(workspace["path"], "base.txt"), "rejected\n")
    task = terminal_task(workspace, "pending")

    assert {:ok, %{review_status: "rejected"}} = Workspace.reject(task)
    assert File.dir?(workspace["path"])
    assert {:ok, _} = Workspace.cleanup(terminal_task(workspace, "rejected"))
    refute File.exists?(workspace["path"])

    forged = put_in(task, ["workspace", "path"], root)
    assert {:error, "workspace_path_invalid", _} = Workspace.review(forged)
  end

  test "跳过构建产物但拒绝源码目录符号链接", %{root: root} do
    build_dir = Path.join(root, "_build/test/lib/demo")
    alternate_build_dir = Path.join(root, "_build-codex-calls/lib/demo")
    cache_dir = Path.join(root, ".appimage-cache/build")
    File.mkdir_p!(build_dir)
    File.mkdir_p!(alternate_build_dir)
    File.mkdir_p!(cache_dir)
    File.ln_s!(root, Path.join(build_dir, "priv"))
    File.ln_s!(root, Path.join(alternate_build_dir, "priv"))
    File.ln_s!(root, Path.join(cache_dir, "toolchain"))

    assert {:ok, workspace} = Workspace.prepare(root, "child-build-artifacts", :auto)
    refute File.exists?(Path.join(workspace["path"], "_build"))
    refute File.exists?(Path.join(workspace["path"], "_build-codex-calls"))
    refute File.exists?(Path.join(workspace["path"], ".appimage-cache"))
    assert {:ok, _} = Workspace.cleanup(terminal_task(workspace, "rejected"))

    File.ln_s!(Path.join(root, "base.txt"), Path.join(root, "source-link.txt"))

    assert {:error, "workspace_unsupported_file", message} =
             Workspace.prepare(root, "child-source-link", :auto)

    assert message =~ "source-link.txt"
  end

  test "文件快照保留可执行权限，物化副本不会把 755 降成 644", %{root: root} do
    script = Path.join(root, "run.sh")
    File.write!(script, "#!/bin/sh\necho ok\n")
    :ok = File.chmod(script, 0o755)

    assert {:ok, snapshot} = Workspace.snapshot(root)
    assert snapshot["run.sh"]["mode"] == 0o755

    target = Path.join(System.tmp_dir!(), "newbee-materialized-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(target) end)
    assert :ok = Workspace.materialize_snapshot(snapshot, target)
    assert :erlang.band(File.stat!(Path.join(target, "run.sh")).mode, 0o777) == 0o755
  end

  test "Git 工作树路径也保留可执行权限", %{root: _root} do
    git_root = Path.join(System.tmp_dir!(), "newbee-git-workspace-#{System.unique_integer([:positive])}")
    File.mkdir_p!(git_root)
    on_exit(fn -> File.rm_rf!(git_root) end)

    script = Path.join(git_root, "bin/run.sh")
    File.mkdir_p!(Path.dirname(script))
    File.write!(script, "#!/bin/sh\necho ok\n")
    :ok = File.chmod(script, 0o755)

    for args <- [
          ["init", "-q"],
          ["config", "user.email", "test@example.invalid"],
          ["config", "user.name", "Workspace Test"],
          ["add", "."],
          ["commit", "-qm", "base"]
        ] do
      {_output, 0} = System.cmd("git", args, cd: git_root, stderr_to_stdout: true)
    end

    task = %{
      "id" => "task-git-mode-#{System.unique_integer([:positive])}",
      "workflow" => %{},
      "workspace_source" => git_root
    }

    :ok = Newbee.Colony.Store.put_task(task)

    assert {:ok, workspace_path} = Newbee.Colony.Workspace.ensure(task, git_root)
    {:ok, stored_task} = Newbee.Colony.Store.get_task(task["id"])
    workspace = stored_task["workspace"]
    assert workspace["kind"] == "git_worktree"
    assert workspace_path == workspace["path"]
    assert :erlang.band(File.stat!(Path.join(workspace["path"], "bin/run.sh")).mode, 0o777) == 0o755
    assert {:ok, _} = Workspace.cleanup(terminal_task(workspace, "rejected"))
    {worktrees, 0} = System.cmd("git", ["worktree", "list", "--porcelain"], cd: git_root, stderr_to_stdout: true)
    refute worktrees =~ workspace["path"]
  end

  test "旧快照缺少 mode 仍可读取，非法 mode 被拒绝", %{root: root} do
    assert {:ok, snapshot} = Workspace.snapshot(root)
    legacy = Map.update!(snapshot, "base.txt", &Map.delete(&1, "mode"))
    target = Path.join(System.tmp_dir!(), "newbee-legacy-snapshot-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(target) end)

    assert :ok = Workspace.materialize_snapshot(legacy, target)
    assert :erlang.band(File.stat!(Path.join(target, "base.txt")).mode, 0o777) == 0o644

    invalid = put_in(snapshot, ["base.txt", "mode"], 0o1000)
    assert {:error, "workspace_snapshot_invalid", _} = Workspace.materialize_snapshot(invalid, target)
  end

  defp terminal_task(workspace, review_status) do
    %{"status" => "succeeded", "workspace" => Map.put(workspace, "review_status", review_status)}
  end
end
