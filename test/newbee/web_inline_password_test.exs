defmodule Mix.Tasks.Newbee.WebInlinePasswordTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.Newbee.Web

  describe "extract_inline_password/1" do
    test "--set-password PW 内联取值，其余参数保留" do
      assert {"h4njhmC", ["--https", "--host", "0.0.0.0"]} =
               Web.extract_inline_password(["--set-password", "h4njhmC", "--https", "--host", "0.0.0.0"])
    end

    test "--set-password=PW 等号形式取值" do
      assert {"abc123", []} = Web.extract_inline_password(["--set-password=abc123"])
    end

    test "裸 --set-password 保持原样走交互式" do
      assert {nil, ["--set-password"]} = Web.extract_inline_password(["--set-password"])
      assert {nil, ["--set-password"]} = Web.extract_inline_password(["--set-password", "--https"])
    end

    test "无该标志时原样返回" do
      args = ["--host", "127.0.0.1"]
      assert {nil, ^args} = Web.extract_inline_password(args)
    end
  end
end
