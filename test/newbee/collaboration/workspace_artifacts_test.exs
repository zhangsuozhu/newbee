defmodule Newbee.Collaboration.WorkspaceArtifactsTest do
  use ExUnit.Case, async: false
  alias Newbee.Collaboration.Workspace

  test "snapshot excludes worktrees, logs and tool caches" do
    root =
      Path.join(
        System.tmp_dir!(),
        "newbee-workspace-artifacts-" <> Integer.to_string(System.unique_integer([:positive]))
      )

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    File.write!(Path.join(root, "source.ex"), "defmodule Source do\nend\n")

    for dir <- [".worktrees/other/lib", ".codex/sessions", ".claude/cache", ".vscode/extensions", "coverage/report"] do
      File.mkdir_p!(Path.join(root, dir))
      File.write!(Path.join([root, dir, "large.bin"]), String.duplicate("x", 4096))
    end

    File.write!(Path.join(root, "nohup.out"), String.duplicate("log", 4096))
    File.write!(Path.join(root, "erl_crash.dump"), String.duplicate("crash", 4096))

    assert {:ok, snapshot} = Workspace.snapshot(root)
    assert Map.keys(snapshot) == ["source.ex"]
    assert {:ok, workspace} = Workspace.prepare(root, "child-artifacts", :auto)
    assert File.read!(Path.join(workspace["path"], "source.ex")) =~ "defmodule Source"
    refute File.exists?(Path.join(workspace["path"], ".worktrees"))
    refute File.exists?(Path.join(workspace["path"], "nohup.out"))

    assert {:ok, _} =
             Workspace.cleanup(%{
               "workspace" => Map.put(workspace, "review_status", "rejected"),
               "status" => "rejected"
             })
  end
end
