# 证明（产品路径）：用户项目没有 .git 但位于某 git 仓内时，
# Newbee.Colony.Workspace.ensure/2 会把沙箱注册到**外层仓**，
# 沙箱里的 git 身份 = 外层仓（作业树的 commit/status 都是别人的项目）。
# 用法: MIX_ENV=dev mix run baseline-r3/poc/colony-workspace-wrong-repo.exs <scratch>
[scratch] = System.argv()
outer = Path.join(scratch, "outer")
proj = Path.join(outer, "proj")
File.rm_rf!(scratch)
File.mkdir_p!(proj)
File.write!(Path.join(outer, "other_project_secret.txt"), "TOPSECRET=other\n")
File.write!(Path.join(proj, "main.txt"), "user code\n")

git = fn cwd, args ->
  {out, code} = System.cmd("git", args, cd: cwd, stderr_to_stdout: true)
  {String.trim(out), code}
end

{_, 0} = git.(outer, ["init", "-q", "."])
{_, 0} = git.(outer, ["add", "-A"])
{_, 0} = git.(outer, ["-c", "user.email=a@b", "-c", "user.name=a", "commit", "-q", "-m", "outer"])

IO.puts("proj_has_dot_git=#{File.exists?(Path.join(proj, ".git"))}")
IO.puts("proj_rev_parse_toplevel=#{elem(git.(proj, ["rev-parse", "--show-toplevel"]), 0)}")

task = %{
  "id" => "task_poc_1",
  "colony_id" => "colony_poc",
  "workflow" => %{},
  "workspace_source" => proj
}

case Newbee.Colony.Workspace.ensure(task, proj) do
  {:ok, path} ->
    IO.puts("workspace=#{path}")
    IO.puts("workspace_dot_git=#{String.trim(File.read!(Path.join(path, ".git")))}")
    IO.puts("workspace_toplevel=#{elem(git.(path, ["rev-parse", "--show-toplevel"]), 0)}")
    IO.puts("workspace_log=#{elem(git.(path, ["log", "--oneline", "-1"]), 0)}")
    {status, _} = git.(path, ["status", "--porcelain"])
    IO.puts("workspace_status_first=#{status |> String.split("\n") |> Enum.take(2) |> Enum.join(" | ")}")
    IO.puts("outer_registrations=#{elem(git.(outer, ["worktree", "list", "--porcelain"]), 0) |> String.split("\n") |> Enum.count(&String.starts_with?(&1, "worktree "))}")
    IO.puts("leaked_foreign_file_visible=#{File.exists?(Path.join(path, "other_project_secret.txt"))}")

  other ->
    IO.puts("ensure_returned=#{inspect(other)}")
end
