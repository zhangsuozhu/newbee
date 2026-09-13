# responses 能力探测缓存落在 /tmp/newbee-test-caps（跨运行共享）。用例用
# System.unique_integer 生成模型 id，而该计数器每次 VM 从 1 起——上一次运行写入的
# continuation:false 会被下一次运行的同名模型读到，断言随运行历史随机失败。
# 每次套件启动清空，保证同一次运行内唯一即可（VM 内计数器本就单调）。
File.rm_rf(Path.join(System.tmp_dir!(), "newbee-test-caps"))

# Tests drive the durable dispatcher explicitly; never start real AI work from fixtures.
Application.put_env(:newbee, :colony_background, false)
ExUnit.start(exclude: [:node])

test_tmp_root = Path.expand(System.tmp_dir!())
user_store_root = Path.expand(Path.join(System.user_home!(), ".newbee"))
existing_global_root = Application.get_env(:newbee, :global_root_override)

if is_binary(existing_global_root) do
  expanded = Path.expand(existing_global_root)

  if expanded == user_store_root or String.starts_with?(expanded, user_store_root <> "/") do
    raise "refusing to run tests against the user store: " <> expanded
  end
end

if is_nil(existing_global_root) do
  test_global_root =
    Path.join(
      test_tmp_root,
      "newbee-test-global-#{System.pid()}-#{System.unique_integer([:positive])}"
    )

  # Always override the durable store in tests, even if GlobalStore was compiled in dev.
  File.mkdir_p!(test_global_root)
  Application.put_env(:newbee, :global_root_override, test_global_root)
  Application.put_env(:newbee, :test_global_root, test_global_root)

  ExUnit.after_suite(fn _results ->
    Application.delete_env(:newbee, :global_root_override)
    Application.delete_env(:newbee, :test_global_root)

    if Path.dirname(test_global_root) == test_tmp_root do
      File.rm_rf!(test_global_root)
    else
      raise "refusing to remove test root outside the temp directory: " <> test_global_root
    end
  end)
end
