defmodule Newbee.GlobalStoreTest do
  use ExUnit.Case, async: false

  test "test 环境默认使用可清理的临时全局目录" do
    root = Newbee.GlobalStore.root()

    assert String.starts_with?(root, System.tmp_dir!())
    refute String.starts_with?(root, Path.join(System.user_home!(), ".newbee"))
  end
end
