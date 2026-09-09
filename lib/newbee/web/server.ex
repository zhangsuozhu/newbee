defmodule Newbee.Web.Server do
  @moduledoc """
  WebUI HTTP/HTTPS 服务器（Bandit 承载 Router，受监督生命周期）。

  默认绑定 127.0.0.1:4173（HTTP，本地零摩擦）。

  ## HTTPS
  - `https: true`：用 ~/.newbee/web/{cert,key}.pem（自签 RSA 2048，首启自动生成）起 TLS。
  - `certfile/keyfile`：挂用户自己的证书（mkcert/CA 签发），优先级高于自签。
  - 远程暴露（绑非回环地址）时应配合 HTTPS 使用。

  ## HTTP→HTTPS 重定向
  `redirect: {http_port, https_port}` 时另起一个仅做 308 跳转的 HTTP server。
  """

  @default_port 4173
  @pt_port {__MODULE__, :port}
  @pt_https {__MODULE__, :https}

  def child_spec(opts) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}}
  end

  @doc "Actual listening port of the WebUI server (defaults to 4173 before startup)."
  def port, do: :persistent_term.get(@pt_port, @default_port)

  @doc "Whether the WebUI server is serving TLS."
  def https?, do: :persistent_term.get(@pt_https, false)

  @doc """
  Connection facts other machines need to reach this Hub.

  Addresses are non-loopback IPv4 candidates in preference order; the port is the
  real listening port, so a group invite always matches this process.
  """
  def endpoint_info do
    scheme = if https?(), do: "https", else: "http"
    port = port()
    addresses = local_addresses()
    bind = bind_ip_string()

    %{
      "scheme" => scheme,
      "port" => port,
      "https" => https?(),
      "bind_ip" => bind,
      "loopback_only" => bind in ["127.0.0.1", "::1", "localhost"],
      "addresses" => addresses,
      "suggested" =>
        case addresses do
          [first | _] -> scheme <> "://" <> first <> ":" <> Integer.to_string(port)
          [] -> nil
        end
    }
  end

  defp bind_ip_string do
    case Newbee.Web.Router.bind_ip() do
      {a, b, c, d} -> "#{a}.#{b}.#{c}.#{d}"
      other -> to_string(other)
    end
  end

  # Prefer real LAN ranges over VPN/Docker/benchmark interfaces; the first entry
  # becomes the default invite address, so ordering matters more than coverage.
  defp local_addresses do
    case :inet.getifaddrs() do
      {:ok, ifaddrs} ->
        ifaddrs
        |> Enum.flat_map(fn {_name, opts} ->
          case Keyword.get(opts, :addr) do
            {a, b, c, d} = ip ->
              text = "#{a}.#{b}.#{c}.#{d}"
              if usable_address?(ip), do: [{lan_rank(ip), text}], else: []

            _ ->
              []
          end
        end)
        |> Enum.uniq_by(&elem(&1, 1))
        |> Enum.sort_by(fn {rank, text} -> {rank, text} end)
        |> Enum.map(&elem(&1, 1))

      _ ->
        []
    end
  end

  defp usable_address?({127, _, _, _}), do: false
  defp usable_address?({169, 254, _, _}), do: false
  defp usable_address?({0, _, _, _}), do: false
  defp usable_address?({255, 255, 255, 255}), do: false
  defp usable_address?({a, _, _, _}) when a in 224..239, do: false
  defp usable_address?(_), do: true

  defp lan_rank({192, 168, _, _}), do: 0
  defp lan_rank({10, _, _, _}), do: 1
  defp lan_rank({172, second, _, _}) when second in 16..31, do: 2
  defp lan_rank({198, 18, _, _}), do: 4
  defp lan_rank({198, 19, _, _}), do: 4
  defp lan_rank(_), do: 3

  @doc """
  opts:
    :port      主端口（默认 4173）
    :host      绑定 IP 元组（默认 {127,0,0,1}）
    :https     true 启用 HTTPS（自签或 certfile/keyfile）
    :certfile  用户证书路径（可选）
    :keyfile   用户私钥路径（可选）
  """
  def start_link(opts) do
    port = Keyword.get(opts, :port, @default_port)
    https? = Keyword.get(opts, :https, false)
    ip = Keyword.get(opts, :host, {127, 0, 0, 1})

    # 记录绑定 IP（决定本地免认证 / 远程强制认证）+ 恢复已签发 token
    Newbee.Web.Router.set_bind_ip(ip)
    Newbee.Web.Auth.load_sessions()

    result = if https?, do: start_https(opts, port, ip), else: start_http(port, ip)

    case result do
      {:ok, _pid} = ok ->
        :persistent_term.put(@pt_port, port)
        :persistent_term.put(@pt_https, https?)
        ok

      other ->
        other
    end
  end

  defp start_http(port, ip) do
    Bandit.start_link(
      plug: Newbee.Web.Router,
      port: port,
      ip: ip,
      thousand_island_options: [num_acceptors: 8]
    )
  end

  defp start_https(opts, port, ip) do
    tls = tls_opts(opts)

    Bandit.start_link(
      plug: Newbee.Web.Router,
      scheme: :https,
      port: port,
      ip: ip,
      thousand_island_options: [num_acceptors: 8, transport_options: tls]
    )
  end

  # 组装 TLS transport_options：优先用户 certfile/keyfile，否则自签 RSA 证书 certfile+keyfile
  defp tls_opts(opts) do
    base = [versions: [:"tlsv1.2", :"tlsv1.3"]]

    case {Keyword.get(opts, :certfile), Keyword.get(opts, :keyfile)} do
      {cert, key} when is_binary(cert) and is_binary(key) ->
        base ++ [certfile: String.to_charlist(cert), keyfile: String.to_charlist(key)]

      _ ->
        case Newbee.Web.Cert.ensure() do
          {:ok, %{cert: cert, key_der: key_der}} ->
            # 内存传 key 绕开 :ssl 对无密码 PEM 的 wrong_password 误判
            base ++ [certfile: String.to_charlist(cert), key: {:RSAPrivateKey, key_der}]

          {:error, reason} ->
            raise "无法准备 HTTPS 证书: " <> inspect(reason)
        end
    end
  end

  @doc "起一个仅做 HTTP→HTTPS 308 重定向的轻量 server。"
  def start_redirect(http_port, https_port, ip) do
    Bandit.start_link(
      plug: {Newbee.Web.Redirector, [https_port: https_port]},
      port: http_port,
      ip: ip,
      thousand_island_options: [num_acceptors: 2]
    )
  end
end

defmodule Newbee.Web.Redirector do
  @moduledoc "仅做 HTTP→HTTPS 308 重定向。"
  @behaviour Plug

  import Plug.Conn

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, opts) do
    https_port = Keyword.fetch!(opts, :https_port)
    host = conn.host |> String.split(":") |> hd()
    target = "https://" <> host <> ":" <> Integer.to_string(https_port) <> conn.request_path <> qs(conn)

    conn
    |> put_resp_header("location", target)
    |> send_resp(308, "redirecting to https")
  end

  defp qs(%{query_string: ""}), do: ""
  defp qs(%{query_string: q}), do: "?" <> q
end
