defmodule Newbee.MediaTest do
  use ExUnit.Case, async: true

  @png Base.decode64!(
         "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=="
       )

  setup do
    suffix = System.unique_integer([:positive])
    tmp = Path.join(System.tmp_dir!(), "newbee-media-spec-#{suffix}")
    sid = "media-spec-test-#{suffix}"
    tool_sid = "media-tool-test-#{suffix}"

    File.mkdir_p!(tmp)
    File.write!(Path.join(tmp, "a.png"), @png)
    File.write!(Path.join(tmp, "b.mp3"), <<0xFF, 0xFB, 0x90>>)
    File.write!(Path.join(tmp, "c.mp4"), <<0x00, 0x00, 0x00, 0x20, "ftypmp42", 0::size(128)>>)

    on_exit(fn ->
      Newbee.Session.set_current(nil)
      Newbee.Session.delete(sid)
      Newbee.Session.delete(tool_sid)
      File.rm_rf!(tmp)
    end)

    {:ok, tmp: tmp, sid: sid, tool_sid: tool_sid}
  end

  test "show 上屏图片：落盘 + manifest + transcript", %{tmp: tmp, sid: sid} do
    assert {:ok, p} = Newbee.Media.show(sid, Path.join(tmp, "a.png"), caption: "截图")
    assert p.kind == "image"
    assert p.ext == "png"
    assert String.starts_with?(p.url, "/media/#{sid}/")
    assert File.exists?(Newbee.Media.media_path(sid, p.media_id, p.ext))

    assert {:ok, [first | _]} = Newbee.Media.list(sid)
    assert first["media_id"] == p.media_id
    assert first["kind"] == "image"

    assert {:ok, bin} = Newbee.Media.read(sid, p.media_id)
    assert bin == @png

    session = Newbee.Session.open(sid)
    msgs = Newbee.Session.messages(session)
    assert Enum.any?(msgs, &(&1["role"] == "media"))
  end

  test "类型推断：mp3 = audio / mp4 = video", %{tmp: tmp, sid: sid} do
    assert {:ok, p1} = Newbee.Media.show(sid, Path.join(tmp, "b.mp3"))
    assert p1.kind == "audio"
    assert {:ok, p2} = Newbee.Media.show(sid, Path.join(tmp, "c.mp4"))
    assert p2.kind == "video"
  end

  test "不存在的文件返回 not_found", %{tmp: tmp, sid: sid} do
    assert {:error, "not_found", _} = Newbee.Media.show(sid, Path.join(tmp, "missing.png"))
  end

  test "delete 删除文件与 manifest 条目", %{tmp: tmp, sid: sid} do
    {:ok, p} = Newbee.Media.show(sid, Path.join(tmp, "a.png"))
    assert :ok = Newbee.Media.delete(sid, p.media_id)
    assert {:error, :enoent} = Newbee.Media.read(sid, p.media_id)
    {:ok, items} = Newbee.Media.list(sid)
    refute Enum.any?(items, &(&1["media_id"] == p.media_id))
  end

  test "工具封装 show 定位当前会话", %{tmp: tmp, tool_sid: tool_sid} do
    Newbee.Session.set_current(tool_sid)
    assert {:ok, p} = Newbee.Tools.Media.show(Path.join(tmp, "a.png"), caption: "工具调用")
    assert p.kind == "image"
    assert {:ok, [first | _]} = Newbee.Media.list(tool_sid)
    assert first["media_id"] == p.media_id
  end
end
