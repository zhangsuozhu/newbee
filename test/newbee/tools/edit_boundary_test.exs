defmodule Newbee.Tools.EditBoundaryTest do
  use ExUnit.Case, async: false

  test "show and patch reject paths outside the workspace" do
    outside =
      Path.join(System.tmp_dir!(), "newbee-edit-outside-" <> Integer.to_string(System.unique_integer([:positive])))

    File.write!(outside, "original\n")
    on_exit(fn -> File.rm(outside) end)

    assert_raise Newbee.Tools.Edit.RejectError, fn -> Newbee.Tools.Edit.show(outside) end
    assert File.read!(outside) == "original\n"
  end

  test "relative traversal is rejected" do
    assert_raise Newbee.Tools.Edit.RejectError, fn -> Newbee.Tools.Edit.show("../../etc/hosts") end
  end
end
