# responses 能力探测缓存落在 /tmp/newbee-test-caps（跨运行共享）。用例用
# System.unique_integer 生成模型 id，而该计数器每次 VM 从 1 起——上一次运行写入的
# continuation:false 会被下一次运行的同名模型读到，断言随运行历史随机失败。
# 每次套件启动清空，保证同一次运行内唯一即可（VM 内计数器本就单调）。
File.rm_rf(Path.join(System.tmp_dir!(), "newbee-test-caps"))

# Tests drive the durable dispatcher explicitly; never start real AI work from fixtures.
Application.put_env(:newbee, :colony_background, false)
ExUnit.start(exclude: [:node])

original_override = Application.get_env(:newbee, :global_root_override)
original_test_root = Application.get_env(:newbee, :test_global_root)

test_global_root =
  Path.join(
    System.tmp_dir!(),
    "newbee-test-global-#{System.pid()}-#{System.unique_integer([:positive])}"
  )

Application.put_env(:newbee, :global_root_override, test_global_root)

project_root = File.cwd!()

ExUnit.after_suite(fn _results ->
  # ExUnit.after_suite/1 replaces any earlier callback, so everything the suite must
  # do on the way out lives in this one function.
  expanded_root = Path.expand(test_global_root)
  expanded_tmp = Path.expand(System.tmp_dir!())

  if Path.dirname(expanded_root) == expanded_tmp and
       String.starts_with?(Path.basename(expanded_root), "newbee-test-global-") do
    File.rm_rf!(expanded_root)
  else
    raise "refusing to remove unsafe test global root: #{expanded_root}"
  end

  case original_override do
    nil -> Application.delete_env(:newbee, :global_root_override)
    path -> Application.put_env(:newbee, :global_root_override, path)
  end

  case original_test_root do
    nil -> Application.delete_env(:newbee, :test_global_root)
    path -> Application.put_env(:newbee, :test_global_root, path)
  end

  # Tests create worktrees for this repo. Deleting a worktree directory with
  # File.rm_rf leaves its entry in .git/worktrees forever, so `git worktree list`
  # keeps reporting dead paths. Prune drops exactly those entries; live worktrees
  # are untouched. Uses the load-time root because tests may leave the cwd in tmp.
  # `.git` is a directory in the main repo but a plain file in a worktree, so test
  # for either; prune itself always targets the shared common dir.
  if File.exists?(Path.join(project_root, ".git")) do
    _ = System.cmd("git", ["worktree", "prune"], cd: project_root, stderr_to_stdout: true)
  end
end)
