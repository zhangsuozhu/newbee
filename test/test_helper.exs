ExUnit.start(exclude: [:node])

if is_nil(Application.get_env(:newbee, :global_root_override)) do
  test_global_root = Newbee.GlobalStore.root()

  ExUnit.after_suite(fn _results ->
    File.rm_rf!(test_global_root)
    Application.delete_env(:newbee, :test_global_root)
  end)
end
