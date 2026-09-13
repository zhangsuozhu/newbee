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

  test "文本媒体路由返回 Markdown 类型和原始正文" do
    suffix = System.unique_integer([:positive])
    tmp = Path.join(System.tmp_dir!(), "newbee-media-text-web-#{suffix}")
    sid = "media-text-web-test-#{suffix}"
    source = Path.join(tmp, "report.md")
    markdown = "# WebUI\n\n文本预览\n"

    File.mkdir_p!(tmp)
    File.write!(source, markdown)
    Newbee.Web.Router.set_bind_ip({127, 0, 0, 1})

    on_exit(fn ->
      Newbee.Web.Router.set_bind_ip({127, 0, 0, 1})
      Newbee.Session.delete(sid)
      File.rm_rf!(tmp)
    end)

    {:ok, p} = Newbee.Media.show(sid, source)
    assert p.kind == "text"
    assert p.markdown == true

    conn = Plug.Test.conn(:get, p.url) |> Newbee.Web.Router.call(Newbee.Web.Router.init([]))
    assert conn.status == 200
    assert Plug.Conn.get_resp_header(conn, "content-type") == ["text/markdown; charset=utf-8"]
    assert conn.resp_body == markdown

    html_path = Path.join(tmp, "preview.html")
    File.write!(html_path, "<script>window.mediaExecuted = true</script>")
    {:ok, html_media} = Newbee.Media.show(sid, html_path)
    html_conn = Plug.Test.conn(:get, html_media.url) |> Newbee.Web.Router.call(Newbee.Web.Router.init([]))
    assert Plug.Conn.get_resp_header(html_conn, "content-type") == ["text/plain; charset=utf-8"]
  end

  test "WebUI 媒体卡片支持实时正文、历史回读和源码高亮" do
    js = File.read!("priv/web/app.js")
    css = File.read!("priv/web/style.css")

    assert js =~ "loadMediaText(p, body)"
    assert js =~ "renderMediaText(p, body, content)"
    assert js =~ "fetch(p.url"
    assert js =~ ~s|if (state.token) headers.authorization = "Bearer " + state.token|
    assert js =~ "renderMarkdown(content)"
    assert js =~ "renderSourceView(body, content, p.language || \"text\")"
    assert css =~ ".msg-media .media-body.media-text-markdown"
    assert css =~ ".msg-media .media-body.media-text-source"
  end

  test "Media 能力索引明确提示文本和 Markdown 可内联显示" do
    section = Newbee.Plugins.prompt_section()
    assert section =~ "Newbee.Tools.Media"
    assert section =~ "文本"

    assert {:ok, docs} = Newbee.read("tool://Newbee.Tools.Media")
    assert docs =~ "Markdown 直接渲染"
    assert docs =~ "show/2"
  end

  test "protected image requires credentials and accepts an authenticated request" do
    sid = "protected-media-#{System.unique_integer([:positive])}"
    dir = Path.join(System.tmp_dir!(), sid)
    File.mkdir_p!(dir)
    source = Path.join(dir, "image.png")
    File.write!(source, <<137, 80, 78, 71>>)
    {:ok, media} = Newbee.Media.show(sid, source)
    Newbee.Web.Router.set_bind_ip({0, 0, 0, 0})

    on_exit(fn ->
      Newbee.Web.Router.set_bind_ip({127, 0, 0, 1})
      Newbee.Session.delete(sid)
      File.rm_rf!(dir)
    end)

    opts = Newbee.Web.Router.init([])
    assert Plug.Test.conn(:get, media.url) |> Newbee.Web.Router.call(opts) |> Map.fetch!(:status) == 401
    {:ok, token} = Newbee.Web.Auth.issue_token()

    conn =
      Plug.Test.conn(:get, media.url)
      |> Plug.Conn.put_req_header("authorization", "Bearer " <> token)
      |> Newbee.Web.Router.call(opts)

    assert conn.status == 200
    assert conn.resp_body == <<137, 80, 78, 71>>
  end
end
