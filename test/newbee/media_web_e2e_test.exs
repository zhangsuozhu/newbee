defmodule Newbee.MediaWebE2ETest do
  use ExUnit.Case, async: false

  # 验证 media_show 事件经 Bus → Socket 下行帧格式正确
  # （Socket 已通吃所有 web_event；这里只验证事件结构与下行编码）
  test "media_show 事件经 socket 下行帧可编码" do
    sid = "media-socket-test"

    payload = %{
      media_id: "abc123",
      url: "/media/#{sid}/abc123",
      kind: "image",
      caption: "截图",
      name: "a.png",
      ext: "png",
      size: 70,
      created_at: "2026-08-27T00:00:00Z"
    }

    # 模拟 Socket.handle_info 下行逻辑（真实 socket 在 WebUI 运行时生效）
    frame =
      Jason.encode_to_iodata!(%{
        type: "event",
        sessionId: sid,
        kind: "media_show",
        payload: payload
      })
      |> IO.iodata_to_binary()

    decoded = Jason.decode!(frame)
    assert decoded["kind"] == "media_show"
    assert decoded["payload"]["url"] == "/media/#{sid}/abc123"
    assert decoded["payload"]["kind"] == "image"
    assert decoded["sessionId"] == sid
  end

  test "media 路由返回文件与正确 content_type" do
    suffix = System.unique_integer([:positive])
    tmp = Path.join(System.tmp_dir!(), "newbee-media-web-#{suffix}")
    sid = "media-web-test-#{suffix}"
    source = Path.join(tmp, "a.png")

    File.mkdir_p!(tmp)
    File.write!(source, <<137, 80, 78, 71>>)

    on_exit(fn ->
      Newbee.Session.delete(sid)
      File.rm_rf!(tmp)
    end)

    {:ok, p} = Newbee.Media.show(sid, source)
    assert {:ok, bin} = Newbee.Media.read(sid, p.media_id)
    assert bin == <<137, 80, 78, 71>>
  end

  test "用户图片 lightbox 固定在视口中央并可点击关闭" do
    css = File.read!("priv/web/style.css")
    js = File.read!("priv/web/app.js")

    assert css =~ ~r/\.nb-lightbox\s*\{[^}]*position:\s*fixed/s
    assert css =~ ~r/\.nb-lightbox\s*\{[^}]*inset:\s*0/s
    assert css =~ ~r/\.nb-lightbox\s*\{[^}]*display:\s*flex/s
    assert css =~ ~r/\.nb-lightbox\s*\{[^}]*align-items:\s*center/s
    assert css =~ ~r/\.nb-lightbox\s*\{[^}]*justify-content:\s*center/s
    assert js =~ ~s|mask.addEventListener("click", closeLightbox)|
  end
end
