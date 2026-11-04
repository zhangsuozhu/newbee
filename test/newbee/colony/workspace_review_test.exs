defmodule Newbee.Colony.WorkspaceReviewTest do
  use ExUnit.Case, async: false

  alias Newbee.Colony.{Store, Work, WorkspaceReview}
  alias Newbee.Collaboration.Workspace

  setup do
    Store.clear_all()
    root = tmp_dir("newbee-review-root")
    File.mkdir_p!(Path.join(root, "lib"))
    File.write!(Path.join(root, "base.txt"), "base\n")
    File.write!(Path.join(root, "lib/nested.txt"), "nested\n")
    File.write!(Path.join(root, "keep.txt"), "keep\n")

    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, colony} = Newbee.Colony.Engine.create_colony(%{"name" => "审阅", "cwd" => root})
    {:ok, bee} = Newbee.Colony.Engine.add_bee(colony["id"], %{"display" => "worker", "kind" => "ai"})

    %{root: root, colony: colony, bee: bee, actor: colony["queen_bee_id"]}
  end

  test "no git: review lists added/modified/deleted and apply writes only those", ctx do
    task = isolated_task(ctx.root, ctx.colony["id"], ctx.bee["id"])
    workspace = task["workspace"]
    File.write!(Path.join(workspace["path"], "base.txt"), "base\nchild\n")
    File.write!(Path.join(workspace["path"], "new.txt"), "new\n")
    File.rm!(Path.join(workspace["path"], "lib/nested.txt"))
    pending!(ctx, task)

    assert {:ok, review} = WorkspaceReview.review(task)
    assert review["patch_sha256"] =~ ~r/\A[0-9a-f]{64}\z/
    assert review["target_root"] == Path.expand(ctx.root)
    assert review["workspace_path"] == workspace["path"]
    assert review["clean"] == true
    assert review["conflicts"] == []

    kinds = Map.new(review["files"], &{&1["path"], &1["kind"]})
    assert kinds == %{"base.txt" => "modified", "new.txt" => "added", "lib/nested.txt" => "deleted"}

    assert review["summary"] =~ "3 个文件变更"
    assert review["display_patch"] =~ "+child"
    assert review["files"] |> Enum.all?(&(&1["target_state"] == "pending"))

    assert {:ok, receipt} = WorkspaceReview.apply(task, review["patch_sha256"], "req-apply-1")
    assert receipt["state"] == "applied"
    assert receipt["patch_sha256"] == review["patch_sha256"]
    assert receipt["target_root"] == Path.expand(ctx.root)

    assert File.read!(Path.join(ctx.root, "base.txt")) == "base\nchild\n"
    assert File.read!(Path.join(ctx.root, "new.txt")) == "new\n"
    refute File.exists?(Path.join(ctx.root, "lib/nested.txt"))
    # 未在差异里的用户文件不动
    assert File.read!(Path.join(ctx.root, "keep.txt")) == "keep\n"

    stored = task!(task)
    assert stored["application"]["state"] == "applied"
    assert stored["application"]["patch_sha256"] == review["patch_sha256"]
    # 应用不改 Task 状态，也不代替 Honey 验收
    assert stored["status"] == "pending_review"
    assert get_in(stored, ["review"]) == nil
    honey = Store.get_honey(stored["result"]) |> elem(1)
    assert honey["review"]["state"] == "pending_review"
  end

  test "git worktree baseline keeps executable bit and applies it", ctx do
    repo = tmp_dir("newbee-review-git")
    File.mkdir_p!(Path.join(repo, "bin"))
    script = Path.join(repo, "bin/run.sh")
    File.write!(script, "#!/bin/sh\necho old\n")
    :ok = File.chmod(script, 0o755)
    File.write!(Path.join(repo, "app.txt"), "v1\n")
    git!(repo, ["init", "-q"])
    git!(repo, ["add", "."])
    git!(repo, ["-c", "user.email=t@e.invalid", "-c", "user.name=T", "commit", "-qm", "base"])
    on_exit(fn -> File.rm_rf!(repo) end)

    task = git_task(repo, ctx.colony["id"], ctx.bee["id"])
    assert task["workspace"]["kind"] == "git_worktree"

    candidate_script = Path.join(task["workspace"]["path"], "bin/run.sh")
    File.write!(candidate_script, "#!/bin/sh\necho new\n")
    :ok = File.chmod(candidate_script, 0o755)
    pending!(ctx, task)

    # 用户 dirty 改动在目标目录里仍保留，且与候选无关时被忽略
    File.write!(Path.join(repo, "local-dirty.txt"), "user notes\n")

    assert {:ok, review} = WorkspaceReview.review(task)
    [file] = review["files"]
    assert file["path"] == "bin/run.sh"
    assert file["kind"] == "modified"
    assert file["after_mode"] == 0o755

    assert {:ok, _receipt} = WorkspaceReview.apply(task, review["patch_sha256"], "req-git-1")
    assert File.read!(Path.join(repo, "bin/run.sh")) == "#!/bin/sh\necho new\n"
    assert :erlang.band(File.stat!(Path.join(repo, "bin/run.sh")).mode, 0o777) == 0o755
    assert File.read!(Path.join(repo, "local-dirty.txt")) == "user notes\n"

    {out, 0} = System.cmd("git", ["status", "--porcelain"], cd: repo, stderr_to_stdout: true)
    assert out =~ "bin/run.sh"
    assert out =~ "local-dirty.txt"
  end

  test "target modified after review is not overwritten", ctx do
    task = isolated_task(ctx.root, ctx.colony["id"], ctx.bee["id"])
    File.write!(Path.join(task["workspace"]["path"], "base.txt"), "base\nchild\n")
    pending!(ctx, task)

    assert {:ok, review} = WorkspaceReview.review(task)
    File.write!(Path.join(ctx.root, "base.txt"), "parent changed\n")

    assert {:ok, reread} = WorkspaceReview.review(task)
    assert reread["patch_sha256"] == review["patch_sha256"]
    assert reread["clean"] == false
    assert [%{"path" => "base.txt", "reason" => "target_changed"}] = reread["conflicts"]

    assert {:error, "workspace_conflict", message} =
             WorkspaceReview.apply(task, review["patch_sha256"], "req-conflict")

    assert message =~ "base.txt"
    assert File.read!(Path.join(ctx.root, "base.txt")) == "parent changed\n"
    assert task!(task)["application"] == nil
  end

  test "candidate changed after review refuses the reviewed hash", ctx do
    task = isolated_task(ctx.root, ctx.colony["id"], ctx.bee["id"])
    File.write!(Path.join(task["workspace"]["path"], "base.txt"), "base\nchild\n")
    pending!(ctx, task)

    assert {:ok, review} = WorkspaceReview.review(task)
    File.write!(Path.join(task["workspace"]["path"], "base.txt"), "base\nchild\nextra\n")
    pending!(ctx, task)

    assert {:error, "stale_review", _} =
             WorkspaceReview.apply(task, review["patch_sha256"], "req-stale-candidate")

    assert File.read!(Path.join(ctx.root, "base.txt")) == "base\n"
  end

  test "symlink and path escape in the candidate are rejected", ctx do
    task = isolated_task(ctx.root, ctx.colony["id"], ctx.bee["id"])
    outside = tmp_dir("newbee-review-outside")
    File.write!(Path.join(outside, "secret.txt"), "secret\n")
    on_exit(fn -> File.rm_rf!(outside) end)
    File.ln_s!(outside, Path.join(task["workspace"]["path"], "escape"))
    pending!(ctx, task)

    # 符号链接不能进入快照，所以 review 直接拒绝，不会把它当普通文件
    assert {:error, code, message} = WorkspaceReview.review(task)
    assert code == "workspace_unsupported_file"
    assert message =~ "escape"
  end

  test "symlink at the target path is refused and the link is kept", ctx do
    task = isolated_task(ctx.root, ctx.colony["id"], ctx.bee["id"])
    File.write!(Path.join(task["workspace"]["path"], "lib/nested.txt"), "safe\n")
    pending!(ctx, task)

    assert {:ok, review} = WorkspaceReview.review(task)

    real = Path.join(ctx.root, "real.txt")
    File.write!(real, "real\n")
    File.rm!(Path.join(ctx.root, "lib/nested.txt"))
    File.ln_s!(real, Path.join(ctx.root, "lib/nested.txt"))

    assert {:error, "symlink_not_allowed", _} =
             WorkspaceReview.apply(task, review["patch_sha256"], "req-symlink-target")

    assert File.read!(real) == "real\n"
    assert {:ok, %File.Stat{type: :symlink}} = File.lstat(Path.join(ctx.root, "lib/nested.txt"))
  end

  test "repeated apply is idempotent and returns the same receipt", ctx do
    task = isolated_task(ctx.root, ctx.colony["id"], ctx.bee["id"])
    File.write!(Path.join(task["workspace"]["path"], "base.txt"), "base\nchild\n")
    pending!(ctx, task)

    assert {:ok, review} = WorkspaceReview.review(task)
    assert {:ok, first} = WorkspaceReview.apply(task, review["patch_sha256"], "req-dup")
    assert first["idempotent"] == false

    assert {:ok, second} = WorkspaceReview.apply(task, review["patch_sha256"], "req-dup")
    assert second["idempotent"] == true
    assert second["applied_at"] == first["applied_at"]
    assert second["patch_sha256"] == first["patch_sha256"]

    assert {:ok, third} = WorkspaceReview.apply(task, review["patch_sha256"], "req-dup-other")
    assert third["applied_at"] == first["applied_at"]

    assert File.read!(Path.join(ctx.root, "base.txt")) == "base\nchild\n"
  end

  test "a different hash after apply is refused instead of overwriting", ctx do
    task = isolated_task(ctx.root, ctx.colony["id"], ctx.bee["id"])
    File.write!(Path.join(task["workspace"]["path"], "base.txt"), "base\nchild\n")
    pending!(ctx, task)
    assert {:ok, review} = WorkspaceReview.review(task)
    assert {:ok, _} = WorkspaceReview.apply(task, review["patch_sha256"], "req-once")

    assert {:error, "already_applied", _} =
             WorkspaceReview.apply(task, String.duplicate("a", 64), "req-twice")

    assert File.read!(Path.join(ctx.root, "base.txt")) == "base\nchild\n"
  end

  test "interrupted apply is recovered from actual before/after fingerprints", ctx do
    task = isolated_task(ctx.root, ctx.colony["id"], ctx.bee["id"])
    File.write!(Path.join(task["workspace"]["path"], "base.txt"), "base\nchild\n")
    File.write!(Path.join(task["workspace"]["path"], "new.txt"), "new\n")
    pending!(ctx, task)
    assert {:ok, review} = WorkspaceReview.review(task)

    # 模拟「写盘中途崩溃」：内容已经被写进目标，但 Store 里还停在 applying
    File.write!(Path.join(ctx.root, "base.txt"), "base\nchild\n")
    assert {:ok, stored} = Store.get_task(task["id"])
    intent = intent_for(review) |> Map.put("state", "applying")
    assert {:ok, _} = Store.update("tasks", task["id"], nil, &{:ok, Map.put(&1, "application", intent)})
    assert {:ok, _} = Store.get_task(task["id"])

    # 第二个文件仍是未应用 → 状态不确定，必须保留诊断而不是盲目重放
    assert {:error, "apply_unknown", message} =
             WorkspaceReview.apply(stored, review["patch_sha256"], "req-recover")

    assert message =~ "new.txt"
    after_task = task!(task)
    assert after_task["application"]["state"] == "unknown"
    assert after_task["application"]["diagnostics"]["reason"] == "state_unknown"

    # 人工核对后把剩下的文件补齐，再重试：这次按实际状态识别为已应用
    File.write!(Path.join(ctx.root, "new.txt"), "new\n")
    assert {:ok, receipt} = WorkspaceReview.apply(task!(task), review["patch_sha256"], "req-recover-2")
    assert receipt["state"] == "applied"
    assert File.read!(Path.join(ctx.root, "new.txt")) == "new\n"
    assert task!(task)["application"]["state"] == "applied"
  end

  test "missing intent file record refuses blind replay", ctx do
    task = isolated_task(ctx.root, ctx.colony["id"], ctx.bee["id"])
    File.write!(Path.join(task["workspace"]["path"], "base.txt"), "base\nchild\n")
    pending!(ctx, task)
    assert {:ok, review} = WorkspaceReview.review(task)

    broken = %{"state" => "applying", "patch_sha256" => review["patch_sha256"], "request_id" => "x"}
    assert {:ok, _} = Store.update("tasks", task["id"], nil, &{:ok, Map.put(&1, "application", broken)})

    assert {:error, "apply_unknown", _} =
             WorkspaceReview.apply(task!(task), review["patch_sha256"], "req-broken")

    assert File.read!(Path.join(ctx.root, "base.txt")) == "base\n"
  end

  test "stale honey and non pending work are refused", ctx do
    task = isolated_task(ctx.root, ctx.colony["id"], ctx.bee["id"])
    File.write!(Path.join(task["workspace"]["path"], "base.txt"), "base\nchild\n")
    pending!(ctx, task)

    # 要求变化：Task 的 context_revision 前进，Honey 仍指向旧版本
    assert {:ok, _} =
             Store.update("tasks", task["id"], nil, &{:ok, Map.update!(&1, "context_revision", fn r -> r + 1 end)})

    assert {:error, "stale_result", _} = WorkspaceReview.review(task!(task))
    assert {:error, "stale_result", _} = WorkspaceReview.apply(task!(task), String.duplicate("b", 64), "req-stale")

    # 工作未到待验收
    assert {:ok, _} = Store.update("tasks", task["id"], nil, &{:ok, Map.put(&1, "status", "running")})
    assert {:error, "task_not_pending_review", _} = WorkspaceReview.review(task!(task))
  end

  test "accepted honey cannot be applied again", ctx do
    task = isolated_task(ctx.root, ctx.colony["id"], ctx.bee["id"])
    File.write!(Path.join(task["workspace"]["path"], "base.txt"), "base\nchild\n")
    pending!(ctx, task)
    assert {:ok, review} = WorkspaceReview.review(task)

    assert {:ok, _} = Work.review(ctx.colony["id"], task!(task)["result"], "accept", ctx.actor, "ok")

    # 验收完成后 Task 已 done：再应用被拒（不会重复写盘，也不冒充验收）
    assert {:error, code, _} =
             WorkspaceReview.apply(task!(task), review["patch_sha256"], "req-accepted")

    assert code in ["task_not_pending_review", "already_reviewed"]
    assert File.read!(Path.join(ctx.root, "base.txt")) == "base\n"
  end

  test "bad request inputs and forged workspaces are refused", ctx do
    task = isolated_task(ctx.root, ctx.colony["id"], ctx.bee["id"])
    File.write!(Path.join(task["workspace"]["path"], "base.txt"), "base\nchild\n")
    pending!(ctx, task)
    assert {:ok, review} = WorkspaceReview.review(task)

    assert {:error, "bad_request", _} = WorkspaceReview.apply(task, "not-a-hash", "req-1")
    assert {:error, "bad_request", _} = WorkspaceReview.apply(task, review["patch_sha256"], "")

    # 客户端不能自带 root：只能来自 Task 记录的工作区（伪造的入参被忽略）
    assert {:ok, _} = WorkspaceReview.review(Map.put(task, "workspace", %{"kind" => "shared"}))

    shared = %{"kind" => "shared", "root" => ctx.root, "path" => ctx.root}
    assert {:error, "not_reviewable", _} = with_workspace(task, shared) |> WorkspaceReview.review()

    escaped = Path.join([ctx.root, "..", "outside"])

    assert {:error, "workspace_invalid", _} =
             with_workspace(task, %{task["workspace"] | "path" => escaped}) |> WorkspaceReview.review()

    assert {:error, "workspace_invalid", _} =
             with_workspace(task, %{task["workspace"] | "kind" => "copy"}) |> WorkspaceReview.review()

    missing_baseline =
      with_workspace(task, %{task["workspace"] | "base_ref" => String.duplicate("0", 64)})

    assert {:error, "workspace_conflict", _} = WorkspaceReview.review(missing_baseline)
  end

  test "display is bounded but the hash covers the whole diff", ctx do
    task = isolated_task(ctx.root, ctx.colony["id"], ctx.bee["id"])
    big = String.duplicate("x", 8_000) <> "\n"
    File.write!(Path.join(task["workspace"]["path"], "big.txt"), big)
    pending!(ctx, task)

    assert {:ok, review} = WorkspaceReview.review(task)
    [file] = review["files"]
    assert file["after_truncated"] == true
    assert byte_size(file["after"]) == 6_000
    assert review["display_truncated"] == true

    # 尾部差异必须影响 hash：只改截断窗口之后的内容，hash 仍要变化
    assert {:ok, review1} = WorkspaceReview.review(task)
    File.write!(Path.join(task["workspace"]["path"], "big.txt"), String.duplicate("x", 8_000) <> "y\n")
    pending!(ctx, task)
    assert {:ok, review2} = WorkspaceReview.review(task)

    refute review1["patch_sha256"] == review2["patch_sha256"]
    assert review2["files"] |> hd() |> Map.get("after_truncated") == true
  end

  test "files beyond the display limit are counted but omitted", ctx do
    task = isolated_task(ctx.root, ctx.colony["id"], ctx.bee["id"])

    for i <- 1..45 do
      File.write!(Path.join(task["workspace"]["path"], "many-#{i}.txt"), "n#{i}\n")
    end

    pending!(ctx, task)
    assert {:ok, review} = WorkspaceReview.review(task)
    assert review["file_count"] == 45
    assert length(review["files"]) == 40
    assert review["omitted_files"] == 5
    assert review["display_truncated"] == true

    assert {:ok, receipt} = WorkspaceReview.apply(task, review["patch_sha256"], "req-many")
    assert length(receipt["files"]) == 45
    assert File.read!(Path.join(ctx.root, "many-45.txt")) == "n45\n"
  end

  test "binary content is applied byte for byte", ctx do
    original = <<0x89, 0x50, 0x4E, 0x47, 0x00>>
    changed = <<0x89, 0x50, 0x4E, 0x47, 0xFF, 0xFE>>
    File.write!(Path.join(ctx.root, "image.bin"), original)

    task = isolated_task(ctx.root, ctx.colony["id"], ctx.bee["id"])
    File.write!(Path.join(task["workspace"]["path"], "image.bin"), changed)
    pending!(ctx, task)

    assert {:ok, review} = WorkspaceReview.review(task)
    [file] = review["files"]
    assert file["binary"] == true
    assert file["after"] == nil
    assert review["display_patch"] =~ "Binary files"

    assert {:ok, _} = WorkspaceReview.apply(task, review["patch_sha256"], "req-binary")
    assert File.read!(Path.join(ctx.root, "image.bin")) == changed
  end

  test "no changes is reported and never applied as a no-op", ctx do
    task = isolated_task(ctx.root, ctx.colony["id"], ctx.bee["id"])
    pending!(ctx, task)

    assert {:ok, review} = WorkspaceReview.review(task)
    assert review["no_changes"] == true
    assert review["clean"] == false

    assert {:error, "no_changes", _} =
             WorkspaceReview.apply(task, review["patch_sha256"], "req-empty")
  end

  test "deleted target recreated after review is a conflict and survives", ctx do
    task = isolated_task(ctx.root, ctx.colony["id"], ctx.bee["id"])
    File.rm!(Path.join(task["workspace"]["path"], "lib/nested.txt"))
    pending!(ctx, task)
    assert {:ok, review} = WorkspaceReview.review(task)

    # 用户重新创建了同一个文件
    File.write!(Path.join(ctx.root, "lib/nested.txt"), "recreated\n")

    assert {:error, "workspace_conflict", _} =
             WorkspaceReview.apply(task, review["patch_sha256"], "req-delete-conflict")

    assert File.read!(Path.join(ctx.root, "lib/nested.txt")) == "recreated\n"
  end

  test "target symlink on an ancestor directory is refused", ctx do
    task = isolated_task(ctx.root, ctx.colony["id"], ctx.bee["id"])
    File.mkdir_p!(Path.join(task["workspace"]["path"], "linked"))
    File.write!(Path.join(task["workspace"]["path"], "linked/file.txt"), "hi\n")
    pending!(ctx, task)
    assert {:ok, review} = WorkspaceReview.review(task)

    # 目标目录里把祖先目录换成指向外面的符号链接
    elsewhere = tmp_dir("newbee-review-elsewhere")
    on_exit(fn -> File.rm_rf!(elsewhere) end)
    File.ln_s!(elsewhere, Path.join(ctx.root, "linked"))

    assert {:error, "symlink_not_allowed", _} =
             WorkspaceReview.apply(task, review["patch_sha256"], "req-symlink-ancestor")

    refute File.exists?(Path.join(elsewhere, "file.txt"))
  end

  test "concurrent applies do not double-write or duplicate receipts", ctx do
    task = isolated_task(ctx.root, ctx.colony["id"], ctx.bee["id"])
    File.write!(Path.join(task["workspace"]["path"], "base.txt"), "base\nchild\n")
    pending!(ctx, task)
    assert {:ok, review} = WorkspaceReview.review(task)

    results =
      1..4
      |> Elixir.Task.async_stream(
        fn i -> WorkspaceReview.apply(task, review["patch_sha256"], "req-concurrent-#{i}") end,
        max_concurrency: 4,
        timeout: 60_000
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.all?(results, &match?({:ok, _}, &1))
    applied_at = results |> Enum.map(fn {:ok, r} -> r["applied_at"] end) |> Enum.uniq()
    assert length(applied_at) == 1
    assert Enum.count(results, fn {:ok, r} -> r["idempotent"] == false end) == 1
    assert File.read!(Path.join(ctx.root, "base.txt")) == "base\nchild\n"
  end

  test "source file permissions are preserved on apply", ctx do
    task = isolated_task(ctx.root, ctx.colony["id"], ctx.bee["id"])
    script = Path.join(task["workspace"]["path"], "run.sh")
    File.write!(script, "#!/bin/sh\necho ok\n")
    :ok = File.chmod(script, 0o755)
    pending!(ctx, task)

    assert {:ok, review} = WorkspaceReview.review(task)
    [file] = review["files"]
    assert file["after_mode"] == 0o755

    assert {:ok, receipt} = WorkspaceReview.apply(task, review["patch_sha256"], "req-mode")
    assert [entry] = receipt["files"]
    assert entry["mode"] == 0o755
    assert :erlang.band(File.stat!(Path.join(ctx.root, "run.sh")).mode, 0o777) == 0o755
  end

  test "missing baseline snapshot is refused instead of guessing", ctx do
    task = isolated_task(ctx.root, ctx.colony["id"], ctx.bee["id"])
    File.write!(Path.join(task["workspace"]["path"], "base.txt"), "base\nchild\n")
    pending!(ctx, task)

    File.rm!(task["workspace"]["path"] <> ".base_snapshot.term")
    assert {:error, "workspace_snapshot_missing", _} = WorkspaceReview.review(task)

    assert {:error, "workspace_snapshot_missing", _} =
             WorkspaceReview.apply(task, String.duplicate("c", 64), "req-nobase")
  end

  test "cleaned workspace and absent work are refused", ctx do
    task = isolated_task(ctx.root, ctx.colony["id"], ctx.bee["id"])
    File.write!(Path.join(task["workspace"]["path"], "base.txt"), "base\nchild\n")
    pending!(ctx, task)

    cleaned = with_workspace(task, Map.put(task["workspace"], "review_status", "cleaned"))
    assert {:error, "workspace_cleaned", _} = WorkspaceReview.review(cleaned)

    assert {:error, "not_found", _} = WorkspaceReview.review(%{"id" => "task_missing"})

    assert {:error, "not_found", _} =
             WorkspaceReview.apply(%{"id" => "task_missing"}, String.duplicate("d", 64), "req-x")
  end

  ## ── helpers ────────────────────────────────────────────────────────────

  defp isolated_task(root, colony_id, bee_id) do
    name = "review-" <> Integer.to_string(System.unique_integer([:positive]))
    {:ok, workspace} = Workspace.prepare(root, name, true)

    task = %{
      "id" => "task_" <> Integer.to_string(System.unique_integer([:positive])),
      "colony_id" => colony_id,
      "title" => "审阅测试",
      "status" => "claimed",
      "assigned_bee_id" => bee_id,
      "created_by" => bee_id,
      "revision" => 0,
      "context_revision" => 0,
      "workspace" => workspace
    }

    :ok = Store.put_task(task)
    task
  end

  # 把工作推进到「待验收」：Honey 与当前 context_revision 对应。
  # 重复调用先把上一次的待验收成果退回执行态，模拟负责人重新提交。
  defp pending!(ctx, task) do
    {:ok, _} =
      Store.update("tasks", task["id"], nil, fn current ->
        if current["status"] == "pending_review",
          do: {:ok, Map.merge(current, %{"status" => "running", "result" => nil})},
          else: {:ok, current}
      end)

    {:ok, honey} =
      Work.submit(
        ctx.colony["id"],
        task["id"],
        %{
          "content" => "改动已完成，测试通过",
          "kind" => "code",
          "work_revision" => task["context_revision"] || 0,
          "evidence" => ["mix test"]
        },
        ctx.bee["id"]
      )

    honey
  end

  defp intent_for(review) do
    %{
      "state" => "applying",
      "request_id" => "req-recover",
      "patch_sha256" => review["patch_sha256"],
      "target_root" => review["target_root"],
      "workspace_path" => review["workspace_path"],
      "base_ref" => review["base_ref"],
      "files" =>
        Enum.map(review["files"], fn file ->
          %{
            "path" => file["path"],
            "kind" => file["kind"],
            "before_sha256" => file["before_sha256"],
            "before_mode" => file["before_mode"],
            "after_sha256" => file["after_sha256"],
            "after_mode" => file["after_mode"]
          }
        end)
    }
  end

  defp with_workspace(task, workspace) do
    {:ok, updated} = Store.update("tasks", task["id"], nil, &{:ok, Map.put(&1, "workspace", workspace)})
    updated
  end

  defp git_task(root, colony_id, bee_id) do
    task = %{
      "id" => "task_" <> Integer.to_string(System.unique_integer([:positive])),
      "colony_id" => colony_id,
      "title" => "审阅测试（git）",
      "status" => "claimed",
      "assigned_bee_id" => bee_id,
      "created_by" => bee_id,
      "revision" => 0,
      "context_revision" => 0,
      "workflow_root" => root,
      "workspace_source" => root
    }

    :ok = Store.put_task(task)
    {:ok, _path} = Newbee.Colony.Workspace.ensure(task, root)
    task!(task)
  end

  defp task!(task) do
    {:ok, stored} = Store.get_task(task["id"])
    stored
  end

  defp tmp_dir(prefix) do
    path = Path.join(System.tmp_dir!(), "#{prefix}-#{System.unique_integer([:positive])}")
    File.mkdir_p!(path)
    path
  end

  defp git!(dir, args) do
    {out, 0} = System.cmd("git", args, cd: dir, stderr_to_stdout: true)
    out
  end
end
