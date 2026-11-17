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

    agents_link = Path.join(root, ".agents/skills/git-commit-conventions")
    File.mkdir_p!(Path.dirname(agents_link))
    File.ln_s!(root, agents_link)
    assert {:ok, tool_workspace} = Workspace.prepare(root, "child-tool-links", :auto)

    assert {:ok, _} = Workspace.cleanup(terminal_task(tool_workspace, "rejected"))

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
    assert :ok = Workspace.discard_orphan(workspace)

    # A registration must be gone, not just the directory: .git/worktrees is
    # shared by every worktree, so a leftover entry keeps reporting a dead path.
    assert worktree_registered?(git_root, workspace["path"]) == false
  end

  test "cleanup drops a registration whose directory was already deleted", %{root: root} do
    git_root = Path.join(root, "repo")
    File.mkdir_p!(git_root)
    File.write!(Path.join(git_root, "a.txt"), "a\n")
    git!(git_root, ["init", "-q"])
    git!(git_root, ["config", "user.email", "test@example.invalid"])
    git!(git_root, ["config", "user.name", "Workspace Test"])
    git!(git_root, ["add", "."])
    git!(git_root, ["commit", "-qm", "base"])

    task = %{
      "id" => "task-orphan-#{System.unique_integer([:positive])}",
      "workflow" => %{},
      "workspace_source" => git_root
    }

    :ok = Newbee.Colony.Store.put_task(task)
    assert {:ok, _path} = Newbee.Colony.Workspace.ensure(task, git_root)
    {:ok, stored} = Newbee.Colony.Store.get_task(task["id"])
    workspace = stored["workspace"]
    assert workspace["kind"] == "git_worktree"
    assert worktree_registered?(git_root, workspace["path"])

    # Simulate an interrupted cleanup / external delete: directory gone, entry left.
    File.rm_rf!(workspace["path"])
    assert worktree_registered?(git_root, workspace["path"])

    assert {:ok, _} = Workspace.cleanup(terminal_task(workspace, "rejected"))
    refute worktree_registered?(git_root, workspace["path"])
  end

  defp worktree_registered?(root, path) do
    {output, 0} = System.cmd("git", ["worktree", "list", "--porcelain"], cd: root, stderr_to_stdout: true)
    String.contains?(output, "worktree " <> Path.expand(path) <> "\n")
  end

  defp git!(dir, args) do
    {_output, 0} = System.cmd("git", args, cd: dir, stderr_to_stdout: true)
    :ok
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

  ## ── 构建产物自动接入（deps/_build）────────────────────────────────────────

  test "prepare 把源项目 deps 以符号链接接入，不复制字节", %{root: root} do
    seed_deps!(root, [{"demo", "源码内容" <> String.duplicate("x", 4096)}])

    assert {:ok, workspace} = Workspace.prepare(root, "child-deps", :auto)
    link = Path.join(workspace["path"], "deps")

    # 链接本身存在，且解析到源项目真实目录（不是副本）
    assert {:ok, target} = File.read_link(link)
    assert Path.expand(target, Path.dirname(link)) == Path.expand(Path.join(root, "deps"))
    assert :erlang.band(File.lstat!(link).mode, 0o170000) == 0o120000
    assert File.read!(Path.join(link, "demo/lib/demo.ex")) == "源码内容" <> String.duplicate("x", 4096)

    # 不复制字节：隔离目录里的 deps 只有链接一个条目
    assert File.ls!(workspace["path"]) |> Enum.count(&(&1 == "deps")) == 1

    entry = Enum.find(workspace["build_artifacts"], &(&1["name"] == "deps"))
    assert entry["status"] == "linked"
    assert Path.expand(entry["target"]) == Path.expand(Path.join(root, "deps"))
    assert workspace["warning"] == nil

    assert {:ok, _} = Workspace.cleanup(terminal_task(workspace, "rejected"))
    refute File.exists?(workspace["path"])
  end

  test "源项目没有 deps 时不建悬空链接，并给出可读提示", %{root: root} do
    refute File.exists?(Path.join(root, "deps"))

    assert {:ok, workspace} = Workspace.prepare(root, "child-no-deps", :auto)

    link = Path.join(workspace["path"], "deps")
    refute File.exists?(link)
    assert {:error, :enoent} = File.lstat(link)

    entry = Enum.find(workspace["build_artifacts"], &(&1["name"] == "deps"))
    assert entry["status"] == "missing"
    assert entry["target"] == nil
    assert is_binary(workspace["warning"])
    assert workspace["warning"] =~ "deps"

    # 仍可正常审阅与清理：提示不是错误
    File.write!(Path.join(workspace["path"], "base.txt"), "base\nchild\n")
    assert {:ok, review} = Workspace.review(terminal_task(workspace, "pending"))
    assert review.dirty
    assert {:ok, _} = Workspace.cleanup(terminal_task(workspace, "rejected"))
    refute File.exists?(workspace["path"])
  end

  test "link_build: true 时同时接入 _build，默认不接入", %{root: root} do
    seed_deps!(root, [{"demo", "dep"}])
    File.mkdir_p!(Path.join(root, "_build/test/lib/demo/ebin"))
    File.write!(Path.join(root, "_build/test/lib/demo/ebin/demo.beam"), <<0x46, 0x4F, 0x52, 0x1A>>)

    assert {:ok, plain} = Workspace.prepare(root, "child-no-build", :auto)
    refute File.exists?(Path.join(plain["path"], "_build"))
    assert {:ok, _} = Workspace.cleanup(terminal_task(plain, "rejected"))

    assert {:ok, workspace} = Workspace.prepare(root, "child-build", :auto, link_build: true)
    build_link = Path.join(workspace["path"], "_build")

    assert {:ok, target} = File.read_link(build_link)
    assert Path.expand(target, Path.dirname(build_link)) == Path.expand(Path.join(root, "_build"))
    assert File.read!(Path.join(build_link, "test/lib/demo/ebin/demo.beam")) == <<0x46, 0x4F, 0x52, 0x1A>>

    assert workspace["build_artifacts"] |> Enum.map(& &1["name"]) |> Enum.sort() == ["_build", "deps"]
    assert workspace["warning"] == nil

    assert {:ok, _} = Workspace.cleanup(terminal_task(workspace, "rejected"))
    refute File.exists?(workspace["path"])
  end

  test "cleanup 只删链接，源项目 deps/_build 逐项不变", %{root: root} do
    seed_deps!(root, [{"alpha", "A" <> String.duplicate("1", 2048)}, {"beta", <<0, 1, 2, 255>>}])
    File.mkdir_p!(Path.join(root, "_build/dev/lib/alpha/ebin"))
    File.write!(Path.join(root, "_build/dev/lib/alpha/ebin/alpha.beam"), <<9, 8, 7>>)

    before = tree_fingerprint(Path.join(root, "deps"))
    build_before = tree_fingerprint(Path.join(root, "_build"))

    assert {:ok, workspace} = Workspace.prepare(root, "child-cleanup", :auto, link_build: true)
    assert File.exists?(Path.join(workspace["path"], "deps"))
    assert File.exists?(Path.join(workspace["path"], "_build"))

    assert {:ok, _} = Workspace.cleanup(terminal_task(workspace, "rejected"))

    refute File.exists?(workspace["path"])
    refute File.exists?(workspace["path"] <> ".base_snapshot.term")

    # 源项目逐字节/逐项一致，且仍是真实目录（不是退化成的链接或空壳）
    assert tree_fingerprint(Path.join(root, "deps")) == before
    assert tree_fingerprint(Path.join(root, "_build")) == build_before
    assert File.dir?(Path.join(root, "deps")) and not link?(Path.join(root, "deps"))
    assert File.dir?(Path.join(root, "_build")) and not link?(Path.join(root, "_build"))
  end

  test "快照文件已被删除时 cleanup 仍成功", %{root: root} do
    seed_deps!(root, [{"demo", "dep"}])
    assert {:ok, workspace} = Workspace.prepare(root, "child-no-snapshot", :auto)

    # 模拟旧工作区或外部已清掉快照文件的情形
    File.rm!(workspace["path"] <> ".base_snapshot.term")

    assert {:ok, _} = Workspace.cleanup(terminal_task(workspace, "rejected"))
    refute File.exists?(workspace["path"])
    assert File.read!(Path.join(root, "deps/demo/lib/demo.ex")) == "dep"
  end

  test "cleanup 不会进入链接目标：把链接指向含哨兵文件的目录", %{root: root} do
    # 手工把工作区里的产物替换成指向受保护目录的链接，确认拆链接只删链接本身
    guard = Path.join(System.tmp_dir!(), "newbee-cleanup-guard-#{System.unique_integer([:positive])}")
    File.mkdir_p!(guard)
    File.write!(Path.join(guard, "sentinel.txt"), "must survive\n")
    on_exit(fn -> File.rm_rf!(guard) end)

    assert {:ok, workspace} = Workspace.prepare(root, "child-guard", :auto)
    link = Path.join(workspace["path"], "deps")
    File.ln_s!(guard, link)
    assert File.read!(Path.join(link, "sentinel.txt")) == "must survive\n"

    # 记录里仍保留 deps 这一项，cleanup 才会走到拆链接分支
    workspace = Map.put(workspace, "build_artifacts", [%{"name" => "deps", "status" => "linked", "target" => guard}])

    assert {:ok, _} = Workspace.cleanup(terminal_task(workspace, "rejected"))

    refute File.exists?(workspace["path"])
    assert File.dir?(guard)
    assert File.read!(Path.join(guard, "sentinel.txt")) == "must survive\n"
  end

  test "源项目 deps 本身是相对链接时，工作区链接指向解析后的真实目录", %{root: root} do
    # 模拟 AGENTS.md 里的 `ln -sfn ../../../deps deps`：源项目里的 deps 本身是相对链接。
    outside = Path.join(Path.dirname(Path.expand(root)), "newbee-deps-outside-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(outside, "demo/lib"))
    File.write!(Path.join(outside, "demo/lib/demo.ex"), "outside\n")
    on_exit(fn -> File.rm_rf!(outside) end)

    relative = Path.join(["..", Path.basename(outside)])
    File.ln_s!(relative, Path.join(root, "deps"))
    assert File.read_link!(Path.join(root, "deps")) == relative

    assert {:ok, workspace} = Workspace.prepare(root, "child-relative", :auto)
    link = Path.join(workspace["path"], "deps")

    assert {:ok, target} = File.read_link(link)
    assert Path.type(target) == :absolute
    assert Path.expand(target) == Path.expand(outside)
    assert File.read!(Path.join(link, "demo/lib/demo.ex")) == "outside\n"

    assert {:ok, _} = Workspace.cleanup(terminal_task(workspace, "rejected"))
    assert File.read!(Path.join(outside, "demo/lib/demo.ex")) == "outside\n"
    assert link?(Path.join(root, "deps"))
  end

  test "deps 是悬空链接时提示且不建悬空链接", %{root: root} do
    File.ln_s!(Path.join(root, "missing-deps"), Path.join(root, "deps"))

    assert {:ok, workspace} = Workspace.prepare(root, "child-dangling", :auto)
    refute File.exists?(Path.join(workspace["path"], "deps"))
    assert {:error, :enoent} = File.lstat(Path.join(workspace["path"], "deps"))

    entry = Enum.find(workspace["build_artifacts"], &(&1["name"] == "deps"))
    assert entry["status"] == "missing"
    assert is_binary(workspace["warning"])
  end

  test "重复 prepare 同名字不会删掉已存在的工作区", %{root: root} do
    seed_deps!(root, [{"demo", "dep"}])
    assert {:ok, workspace} = Workspace.prepare(root, "child-dup", :auto)
    File.write!(Path.join(workspace["path"], "work-in-progress.txt"), "keep me\n")

    assert {:error, "workspace_exists", _} = Workspace.prepare(root, "child-dup", :auto)
    assert File.read!(Path.join(workspace["path"], "work-in-progress.txt")) == "keep me\n"
    assert File.read!(Path.join(root, "deps/demo/lib/demo.ex")) == "dep"

    assert {:ok, _} = Workspace.cleanup(terminal_task(workspace, "rejected"))
  end

  test "非法 prepare 选项被拒绝", %{root: root} do
    assert {:error, "bad_request", _} = Workspace.prepare(root, "child-bad-opt", :auto, link_build: "yes")
    assert {:error, "bad_request", _} = Workspace.prepare(root, "child-bad-opt", :auto, bogus: true)
    refute File.exists?(Path.join([root, ".newbee", "workspaces", "child-bad-opt"]))
  end

  ## ── helpers ──────────────────────────────────────────────────────────────

  # 造一个像真实项目的 deps：每个依赖有 mix.exs、lib 源码和字节内容。
  defp seed_deps!(root, deps) do
    for {name, content} <- deps do
      lib = Path.join([root, "deps", name, "lib"])
      File.mkdir_p!(lib)
      File.write!(Path.join(lib, String.replace(name, "-", "_") <> ".ex"), content)
      File.write!(Path.join([root, "deps", name, "mix.exs"]), "defmodule #{Macro.camelize(name)}.MixProject do\nend\n")
    end

    :ok
  end

  # 逐项 + 逐字节指纹：路径、类型、大小、权限、内容 hash。用来断言「源目录没被动过」。
  defp tree_fingerprint(path) do
    path
    |> walk("")
    |> Enum.sort()
  end

  defp walk(path, rel) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :directory}} ->
        path
        |> File.ls!()
        |> Enum.sort()
        |> Enum.flat_map(fn name ->
          child = Path.join(path, name)
          child_rel = if rel == "", do: name, else: Path.join(rel, name)
          [{child_rel, fingerprint_stat(File.lstat!(child))} | walk(child, child_rel)]
        end)

      {:ok, stat} ->
        [{rel, fingerprint_stat(stat)}]

      {:error, reason} ->
        [{rel, {:error, reason}}]
    end
  end

  defp fingerprint_stat(%File.Stat{type: :regular, size: size, mode: mode} = stat) do
    {:file, size, :erlang.band(mode, 0o777), :erlang.phash2({stat.mtime, size})}
  end

  defp fingerprint_stat(%File.Stat{type: type, size: size, mode: mode}),
    do: {type, size, :erlang.band(mode, 0o777)}

  defp link?(path), do: match?({:ok, %File.Stat{type: :symlink}}, File.lstat(path))

  defp terminal_task(workspace, review_status) do
    %{"status" => "succeeded", "workspace" => Map.put(workspace, "review_status", review_status)}
  end
end
