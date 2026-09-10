# responses 能力探测缓存落在 /tmp/newbee-test-caps（跨运行共享）。用例用
# System.unique_integer 生成模型 id，而该计数器每次 VM 从 1 起——上一次运行写入的
# continuation:false 会被下一次运行的同名模型读到，断言随运行历史随机失败。
# 每次套件启动清空，保证同一次运行内唯一即可（VM 内计数器本就单调）。
File.rm_rf(Path.join(System.tmp_dir!(), "newbee-test-caps"))

ExUnit.start(exclude: [:node])

if is_nil(Application.get_env(:newbee, :global_root_override)) do
  test_global_root = Newbee.GlobalStore.root()

  ExUnit.after_suite(fn _results ->
    File.rm_rf!(test_global_root)
    Application.delete_env(:newbee, :test_global_root)
  end)
end
