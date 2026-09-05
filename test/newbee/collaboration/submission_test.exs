defmodule Newbee.Collaboration.SubmissionTest do
  use ExUnit.Case, async: false

  alias Newbee.Collaboration.{Submission, Verification, Workspace}

  setup do
    root = Path.join(System.tmp_dir!(), "newbee-submission-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, "lib"))
    File.write!(Path.join(root, "lib/source.txt"), "base\n")

    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  test "capture materializes an independent task-bound snapshot", %{root: root} do
    assert {:ok, workspace} = Workspace.prepare(root, "submission-worker", true)
    File.write!(Path.join(workspace["path"], "lib/source.txt"), "candidate\n")

    task = task(workspace, "submission-capture")
    assert {:ok, submission} = Submission.capture(task, workspace["path"])

    assert Map.keys(submission) |> Enum.sort() ==
             ~w(acceptance_sha256 attempt created_at id result_sha256 root task_id tree_sha256)

    submitted = Map.put(task, "submission", submission)
    assert :ok = Submission.validate(submitted)
    assert {:ok, root} = Submission.verification_root(submitted)
    assert root == submission["root"]
    assert File.read!(Path.join(submission["root"], "lib/source.txt")) == "candidate\n"

    File.write!(Path.join(workspace["path"], "lib/source.txt"), "worker changed later\n")
    assert :ok = Submission.validate(submitted)
    assert File.read!(Path.join(submission["root"], "lib/source.txt")) == "candidate\n"
  end

  test "minimal task shape closes capture and validate", %{root: root} do
    task = %{
      "task_id" => "submission-minimal",
      "attempt" => 0,
      "acceptance" => [%{"kind" => "file_exists", "path" => "lib/source.txt"}],
      "result" => "done"
    }

    assert {:ok, submission} = Submission.capture(task, root)
    assert :ok = Submission.validate(Map.put(task, "submission", submission))
  end

  test "tampering with frozen source is reported as submission_changed", %{root: root} do
    assert {:ok, workspace} = Workspace.prepare(root, "submission-tamper", true)
    File.write!(Path.join(workspace["path"], "lib/source.txt"), "candidate\n")
    task = task(workspace, "submission-tamper")
    assert {:ok, submission} = Submission.capture(task, workspace["path"])
    submitted = Map.put(task, "submission", submission)

    File.write!(Path.join(submission["root"], "lib/source.txt"), "tampered\n")
    assert {:error, "submission_changed", _} = Submission.validate(submitted)
    assert {:error, "submission_changed", _} = Submission.verification_root(submitted)
  end

  test "verification attestation is derived from the validated submission", %{root: root} do
    assert {:ok, workspace} = Workspace.prepare(root, "submission-verify", true)
    File.write!(Path.join(workspace["path"], "proof.txt"), "proof")
    task = task(workspace, "submission-verify")
    assert {:ok, submission} = Submission.capture(task, workspace["path"])
    submitted = Map.put(task, "submission", submission)

    assert {:ok, attestation} = Verification.verify(submitted, submission["root"])
    assert attestation["submission_id"] == submission["id"]
    assert attestation["tree_sha256"] == submission["tree_sha256"]
    assert attestation["hermetic"] == false
    assert attestation["all_passed"]
  end

  test "a command that mutates frozen source is rejected after execution", %{root: root} do
    assert {:ok, workspace} = Workspace.prepare(root, "submission-command-tamper", true)
    File.write!(Path.join(workspace["path"], "lib/source.txt"), "candidate\n")

    task = %{
      "task_id" => "submission-command-tamper",
      "attempt" => 0,
      "acceptance" => [
        %{
          "kind" => "command",
          "program" => "python3",
          "args" => ["-c", "from pathlib import Path; Path('lib/source.txt').write_text('tampered')"],
          "timeout_ms" => 5_000
        }
      ],
      "result" => "candidate result",
      "workspace" => workspace
    }

    assert {:ok, submission} = Submission.capture(task, workspace["path"])
    submitted = Map.put(task, "submission", submission)
    assert {:error, "submission_changed", _} = Verification.verify(submitted, submission["root"])
  end

  test "submitted candidates can be reviewed but cannot be applied", %{root: root} do
    assert {:ok, workspace} = Workspace.prepare(root, "submission-review", true)
    File.write!(Path.join(workspace["path"], "lib/source.txt"), "candidate\n")
    task = task(workspace, "submission-review")
    assert {:ok, submission} = Submission.capture(task, workspace["path"])
    submitted = Map.merge(task, %{"status" => "submitted", "submission" => submission})

    assert {:ok, review} = Workspace.review(submitted)
    assert review.dirty
    assert {:error, "verification_required", _} = Workspace.apply(submitted, review.patch_sha256)
  end

  test "verified apply uses the frozen candidate after worker edits", %{root: root} do
    assert {:ok, workspace} = Workspace.prepare(root, "submission-apply", true)
    File.write!(Path.join(workspace["path"], "lib/source.txt"), "candidate\n")
    task = task(workspace, "submission-apply")
    assert {:ok, submission} = Submission.capture(task, workspace["path"])
    submitted = Map.merge(task, %{"status" => "submitted", "submission" => submission})
    assert {:ok, attestation} = Verification.verify(submitted, submission["root"])

    File.write!(Path.join(workspace["path"], "lib/source.txt"), "worker edited after submit\n")
    verified_workspace = Map.put(workspace, "review_status", "pending")

    verified =
      Map.merge(submitted, %{
        "status" => "succeeded",
        "workspace" => verified_workspace,
        "verification" => Map.put(attestation, "status", "passed")
      })

    assert {:ok, review} = Workspace.review(verified)
    assert review.patch_sha256 != nil
    assert {:ok, _applied} = Workspace.apply(verified, review.patch_sha256)
    assert File.read!(Path.join(root, "lib/source.txt")) == "candidate\n"
  end

  defp task(workspace, task_id) do
    %{
      "task_id" => task_id,
      "attempt" => 0,
      "status" => "running",
      "acceptance" => [%{"kind" => "file_exists", "path" => "lib/source.txt"}],
      "acceptance_sha256" =>
        Verification.contract_sha256([
          %{"kind" => "file_exists", "path" => "lib/source.txt", "id" => 1}
        ]),
      "result" => "candidate result",
      "workspace" => workspace
    }
  end
end
