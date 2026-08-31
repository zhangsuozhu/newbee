defmodule Newbee.LLM.ImageTest do
  use ExUnit.Case, async: true

  test "构造图片 data URL user message" do
    path =
      Path.join(
        System.tmp_dir!(),
        "newbee-image-#{System.system_time(:native)}_#{System.unique_integer([:positive])}.png"
      )

    File.write!(path, <<137, 80, 78, 71, 1, 2, 3>>)
    on_exit(fn -> File.rm(path) end)

    assert {:ok, message} = Newbee.LLM.Image.message(path, "找出截图里的错误")
    assert message["role"] == "user"
    assert [%{"type" => "text", "text" => "找出截图里的错误"}, %{"type" => "image_url"} = image] = message["content"]
    assert image["image_url"]["url"] =~ "data:image/png;base64,"
  end

  test "拒绝不存在和不支持的图片" do
    assert {:error, :image_not_found} = Newbee.LLM.Image.message("/tmp/does-not-exist.png")
    assert {:error, {:unsupported_image_type, ".txt"}} = Newbee.LLM.Image.message("/tmp/error.txt")
  end
end
