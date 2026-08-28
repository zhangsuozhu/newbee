defmodule Newbee.Web.Router do
  @moduledoc """
  WebUI 顶层路由：API(RPC) + WebSocket + 静态资源(SPA fallback)。

  ## 认证（远程强制 / 本地免）
  pipeline 顶部 require_auth：绑定回环地址（本地）时全放行；绑定非回环地址
  （远程暴露）时，除 auth.login/auth.setup/auth.captcha/auth.status 与静态资源外，
  一律要求 Authorization: Bearer <token>（WebSocket 用 ?token=），否则 401。
  """
  use Plug.Router

  plug(Plug.Logger)
  plug(:security_headers)
  plug(:require_auth)
  plug(:match)
  plug(:dispatch)

  get "/ws" do
    conn = fetch_query_params(conn)
    sid = conn.query_params["session"] || ""

    conn
    |> WebSockAdapter.upgrade(Newbee.Web.Socket, %{assigns: %{session: sid}}, timeout: :infinity)
    |> halt()
  end

  forward("/api", to: Newbee.Web.Api)
  # ── 媒体上屏：模型上屏的多媒体文件（图片/音频/视频），以不透明 id 作为令牌 ──
  # 认证：受整体 require_auth（远程强制 Bearer）保护；浏览器 <img>/<video> 标签
  # 无法带 Authorization 头，故本地回环（auth_required? == false）直接放行；
  # 远程暴露时通过 ?token= 查询参数鉴权（见 require_auth 的 bearer_token 兜底）。
  # ── 扫码授权页（手机扫码后打开；服务端渲染模板核对配对码）──
  # 该页本身免 token，但页内 JS 校验手机已有登录会话。配对码只在此 URL 的 ?c=
  # 参数里，由服务端从 ETS 核对，一次性消费——不上二维码、不经 RPC 回传。
  get "/pair" do
    serve_pair_page(conn)
  end

  get "/media/:sid/:media_id" do
    sid = URI.decode(sid)
    media_id = URI.decode(media_id)

    with {:ok, item} <- Newbee.Media.info(sid, media_id),
         {:ok, bin} <- Newbee.Media.read(sid, media_id) do
      ext = item["ext"] || ""
      mime = if ext != "", do: content_type("." <> ext), else: "application/octet-stream"

      conn
      |> put_resp_content_type(mime)
      |> put_resp_header("cache-control", "private, max-age=3600")
      |> send_resp(200, bin)
      |> halt()
    else
      _ ->
        send_resp(conn, 404, "media not found")
    end
  end

  match _ do
    serve_static(conn)
  end

  @priv_web Path.expand("../../../priv/web", __DIR__)
  @index Path.join(@priv_web, "index.html")

  # ── 认证 gate ──

  @auth_free_prefixes [
    "/api/auth.",
    "/api/health",
    "/api/webauthn.has_credentials",
    "/api/webauthn.login_challenge",
    "/api/webauthn.login",
    "/api/pair.",
    "/api/quick_access.redeem"
  ]

  defp require_auth(conn, _opts) do
    if Newbee.Web.Auth.auth_required?(bind_ip()) and not auth_free?(conn) do
      case bearer_token(conn) do
        {:ok, token} ->
          case Newbee.Web.Auth.check_token(token) do
            :ok -> conn
            {:error, _} -> unauthorized(conn)
          end

        :error ->
          unauthorized(conn)
      end
    else
      conn
    end
  end

  defp auth_free?(conn) do
    path = conn.request_path

    Enum.any?(@auth_free_prefixes, &String.starts_with?(path, &1)) or
      not String.starts_with?(path, "/api")
  end

  defp bearer_token(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> tok | _] ->
        {:ok, String.trim(tok)}

      _ ->
        conn = fetch_query_params(conn)

        case conn.query_params["token"] do
          t when is_binary(t) and byte_size(t) > 0 -> {:ok, t}
          _ -> :error
        end
    end
  end

  defp unauthorized(conn) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(401, Jason.encode!(%{error: %{code: "unauthorized", message: "未登录或会话已过期"}}))
    |> halt()
  end

  @doc "Server 启动时记录绑定 IP，供 require_auth 判断本地/远程。"
  def set_bind_ip(ip), do: :persistent_term.put({__MODULE__, :bind_ip}, ip)

  @doc "读取绑定 IP（供 API/require_auth 判断本地/远程）。"
  def bind_ip, do: :persistent_term.get({__MODULE__, :bind_ip}, {127, 0, 0, 1})

  # ── 静态资源 + SPA fallback ──

  defp serve_static(conn) do
    path = conn.request_path |> String.trim_leading("/")
    path = if path == "", do: "index.html", else: path
    file = Path.join(@priv_web, path)

    cond do
      not inside_root?(Path.expand(file), Path.expand(@priv_web)) ->
        send_resp(conn, 403, "forbidden")

      File.regular?(file) ->
        conn
        |> put_resp_content_type(content_type(file))
        |> put_resp_header("cache-control", "no-store, no-cache, must-revalidate")
        |> send_file(200, file)

      File.regular?(@index) ->
        conn
        |> put_resp_content_type("text/html")
        |> put_resp_header("cache-control", "no-store, no-cache, must-revalidate")
        |> send_file(200, @index)

      true ->
        send_resp(conn, 404, "newbee webui 前端未构建：priv/web/index.html 不存在")
    end
  end

  # ── 扫码授权页渲染 ──

  @pair_template Path.expand("../../../priv/web/pair.html.eex", __DIR__)
  require EEx

  EEx.function_from_file(
    :defp,
    :render_pair_page,
    @pair_template,
    [:ok, :error, :pairing_id_json, :ua_short, :ip, :time_ago, :auth_required], trim: true)

  defp serve_pair_page(conn) do
    conn = fetch_query_params(conn)
    code = conn.query_params["c"] || ""

    html =
      case Newbee.Web.Pair.consume_code(code) do
        {:ok, info} ->
          render_pair_page(
            true,
            nil,
            Jason.encode!(info.pairing_id),
            ua_summary(info.ua),
            info.ip,
            time_ago(info.created),
            Newbee.Web.Auth.auth_required?(bind_ip())
          )

        {:error, _code, msg} ->
          render_pair_page(false, msg, "null", "", "", "", false)
      end

    conn
    |> put_resp_content_type("text/html")
    |> put_resp_header("cache-control", "no-store")
    |> send_resp(200, html)
    |> halt()
  end

  # 浏览器 UA → 人类可读的"设备/浏览器"摘要
  defp ua_summary(ua) when is_binary(ua) do
    cond do
      String.contains?(ua, "Edg") -> "Edge 浏览器"
      String.contains?(ua, "Firefox") -> "Firefox 浏览器"
      String.contains?(ua, "Chrome") -> "Chrome 浏览器"
      String.contains?(ua, "Safari") -> "Safari 浏览器"
      ua == "" -> "未知设备"
      true -> String.slice(ua, 0, 40)
    end
  end

  defp ua_summary(_), do: "未知设备"

  defp time_ago(created_ms) when is_integer(created_ms) do
    sec = div(System.system_time(:millisecond) - created_ms, 1000)

    cond do
      sec < 5 -> "刚刚"
      sec < 60 -> "#{sec} 秒前"
      true -> "#{div(sec, 60)} 分钟前"
    end
  end

  defp time_ago(_), do: "刚刚"

  defp inside_root?(path, root) do
    path == root or String.starts_with?(path, root <> "/")
  end

  defp security_headers(conn, _opts) do
    conn
    |> Plug.Conn.put_resp_header("x-content-type-options", "nosniff")
    |> Plug.Conn.put_resp_header("x-frame-options", "DENY")
    |> Plug.Conn.put_resp_header("referrer-policy", "no-referrer")
  end

  defp content_type(file) do
    case Path.extname(file) do
      ".html" -> "text/html"
      ".js" -> "text/javascript"
      ".css" -> "text/css"
      ".png" -> "image/png"
      ".json" -> "application/json"
      ".svg" -> "image/svg+xml"
      ".jpg" -> "image/jpeg"
      ".jpeg" -> "image/jpeg"
      ".gif" -> "image/gif"
      ".webp" -> "image/webp"
      ".wav" -> "audio/wav"
      ".ogg" -> "audio/ogg"
      ".m4a" -> "audio/mp4"
      ".flac" -> "audio/flac"
      ".aac" -> "audio/aac"
      ".mp4" -> "video/mp4"
      ".webm" -> "video/webm"
      ".mov" -> "video/quicktime"
      ".mkv" -> "video/x-matroska"
      ".webmanifest" -> "application/manifest+json"
      _ -> "application/octet-stream"
    end
  end
end
