defmodule Newbee.Collaboration.WorkspaceTest do
  use ExUnit.Case, async: false

  alias Newbee.Collaboration.Workspace

  setup do
    root = Path.join(System.tmp_dir!(), "newbee-workspace-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    git!(root, ["init", "-q"])
    git!(root, ["config", "user.email", "workspace@test.local"])
    git!(root, ["config", "user.name", "Workspace Test"])
    File.write!(Path.join(root, "base.txt"), "base\n")
    git!(root, ["add", "base.txt"])
    git!(root, ["commit", "-q", "-m", "base"])

    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  test "子代理继承父工作区未提交快照，审查只包含子代理新增变化", %{root: root} do
    File.write!(Path.join(root, "base.txt"), "base\nparent\n")
    File.write!(Path.join(root, "parent-only.txt"), "parent\n")
    staged_before = git!(root, ["diff", "--cached", "--name-only"])

    assert {:ok, workspace} = Workspace.prepare(root, "child-snapshot", true)
    assert File.read!(Path.join(workspace["path"], "base.txt")) == "base\nparent\n"
    assert File.read!(Path.join(workspace["path"], "parent-only.txt")) == "parent\n"
    assert git!(root, ["diff", "--cached", "--name-only"]) == staged_before
    assert is_binary(workspace["snapshot_ref"])

    File.write!(Path.join(workspace["path"], "base.txt"), "base\nparent\nchild\n")
    task = terminal_task(workspace, "pending")
    assert {:ok, review} = Workspace.review(task)
    assert Enum.map(review.files, & &1.path) == ["base.txt"]
    refute String.contains?(review.display_patch, "parent-only.txt")

    rejected_task = put_in(task, ["workspace", "review_status"], "rejected")
    assert {:ok, _} = Workspace.cleanup(rejected_task)

    assert {_, exit_code} =
             System.cmd("git", ["-C", root, "show-ref", "--verify", workspace["snapshot_ref"]], stderr_to_stdout: true)

    assert exit_code != 0
  end

  test "审查包含已跟踪和未跟踪文件，应用前检测版本并保持 index 干净", %{root: root} do
    assert {:ok, workspace} = Workspace.prepare(root, "child-review", true)
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
    assert {:ok, _already_applied} = Workspace.apply(task, review.patch_sha256)
    assert File.read!(Path.join(root, "base.txt")) == "base\nchild\n"
    assert File.read!(Path.join(root, "new.txt")) == "new\n"
    assert String.trim(git!(root, ["diff", "--cached", "--name-only"])) == ""

    applied_task = put_in(task, ["workspace", "review_status"], "applied")
    assert {:ok, _} = Workspace.cleanup(applied_task)
    refute File.exists?(workspace["path"])
    assert {:ok, _already_cleaned} = Workspace.cleanup(applied_task)
  end

  test "拒绝保留证据直到显式清理，路径伪造被拒绝", %{root: root} do
    assert {:ok, workspace} = Workspace.prepare(root, "child-reject", true)
    File.write!(Path.join(workspace["path"], "base.txt"), "rejected\n")
    task = terminal_task(workspace, "pending")

    assert {:ok, %{review_status: "rejected"}} = Workspace.reject(task)
    assert File.dir?(workspace["path"])

    rejected_task = put_in(task, ["workspace", "review_status"], "rejected")
    assert {:ok, _} = Workspace.cleanup(rejected_task)
    refute File.exists?(workspace["path"])

    forged = put_in(task, ["workspace", "path"], root)
    assert {:error, "workspace_path_invalid", _} = Workspace.review(forged)
  end

  test "auto 在非 Git 项目退化为共享目录并明确不可审查" do
    root = Path.join(System.tmp_dir!(), "newbee-shared-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)

    assert {:ok, workspace} = Workspace.prepare(root, "shared-child", :auto)
    assert workspace["kind"] == "shared"
    assert is_binary(workspace["warning"])

    assert {:error, "not_reviewable", _} =
             Workspace.review(terminal_task(workspace, "not_applicable"))
  end

  defp terminal_task(workspace, review_status) do
    %{
      "status" => "succeeded",
      "workspace" => Map.put(workspace, "review_status", review_status)
    }
  end

  defp git!(dir, args) do
    case System.cmd("git", ["-C", dir | args], stderr_to_stdout: true) do
      {output, 0} -> output
      {output, code} -> flunk("git #{Enum.join(args, " ")} failed (#{code}): #{output}")
    end
  end
end
