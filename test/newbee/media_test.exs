defmodule Newbee.MediaTest do
  use ExUnit.Case, async: true

  @sid "media-spec-test"
  @png Base.decode64!("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==")

  setup do
    File.mkdir_p!("/tmp/newbee-media-spec")
    File.write!("/tmp/newbee-media-spec/a.png", @png)
    File.write!("/tmp/newbee-media-spec/b.mp3", <<0xFF, 0xFB, 0x90>>)
    File.write!("/tmp/newbee-media-spec/c.mp4", <<0x00, 0x00, 0x00, 0x20, "ftypmp42", 0::size(128)>>)
    :ok
  end

  test "show 上屏图片：落盘 + manifest + transcript" do
    assert {:ok, p} = Newbee.Media.show(@sid, "/tmp/newbee-media-spec/a.png", caption: "截图")
    assert p.kind == "image"
    assert p.ext == "png"
    assert String.starts_with?(p.url, "/media/#{@sid}/")
    assert File.exists?(Newbee.Media.media_path(@sid, p.media_id, p.ext))

    assert {:ok, [first | _]} = Newbee.Media.list(@sid)
    assert first["media_id"] == p.media_id
    assert first["kind"] == "image"

    assert {:ok, bin} = Newbee.Media.read(@sid, p.media_id)
    assert bin == @png

    session = Newbee.Session.open(@sid)
    msgs = Newbee.Session.messages(session)
    assert Enum.any?(msgs, &(&1["role"] == "media"))
  end

  test "类型推断：mp3 = audio / mp4 = video" do
    assert {:ok, p1} = Newbee.Media.show(@sid, "/tmp/newbee-media-spec/b.mp3")
    assert p1.kind == "audio"
    assert {:ok, p2} = Newbee.Media.show(@sid, "/tmp/newbee-media-spec/c.mp4")
    assert p2.kind == "video"
  end

  test "不存在的文件返回 not_found" do
    assert {:error, "not_found", _} = Newbee.Media.show(@sid, "/tmp/newbee-media-spec/missing.png")
  end

  test "delete 删除文件与 manifest 条目" do
    {:ok, p} = Newbee.Media.show(@sid, "/tmp/newbee-media-spec/a.png")
    assert :ok = Newbee.Media.delete(@sid, p.media_id)
    assert {:error, :enoent} = Newbee.Media.read(@sid, p.media_id)
    {:ok, items} = Newbee.Media.list(@sid)
    refute Enum.any?(items, &(&1["media_id"] == p.media_id))
  end

  test "工具封装 show 定位当前会话" do
    Newbee.Session.set_current("media-tool-test")
    assert {:ok, p} = Newbee.Tools.Media.show("/tmp/newbee-media-spec/a.png", caption: "工具调用")
    assert p.kind == "image"
    assert {:ok, [first | _]} = Newbee.Media.list("media-tool-test")
    assert first["media_id"] == p.media_id
    Newbee.Session.set_current(nil)
  end
end
