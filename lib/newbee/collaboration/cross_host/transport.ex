defmodule Newbee.Collaboration.CrossHost.Transport do
  @moduledoc "Pinned HTTPS RPC client for a Worker-to-Hub connection. HTTP is only available with an explicit test-only opt-in."

  @default_timeout 10_000
  @max_response_bytes 2_000_000

  @doc "Call a Hub bridge RPC with server certificate pinning and an optional device token."
  def rpc(base_url, method, payload, opts \\ [])

  def rpc(base_url, method, payload, opts)
      when is_binary(base_url) and is_binary(method) and is_map(payload) and is_list(opts) do
    with {:ok, uri} <- validate_url(base_url, opts),
         :ok <- validate_method(method),
         {:ok, url} <- endpoint(uri, method),
         {:ok, body} <- encode_request(method, payload),
         {:ok, response} <- request(uri, url, body, opts),
         {:ok, response_body} <- response_body(response),
         {:ok, decoded} <- decode_response(response_body) do
      decode_result(decoded)
    end
  end

  def rpc(_, _, _, _), do: {:error, "bad_request", "远端 RPC 参数无效"}

  @doc "Join a Hub over a pinned connection; the returned device plain token is shown once."
  def join(base_url, group_id, password, fingerprint, display, opts \\ []) do
    rpc(
      base_url,
      "xgroup.bridge.join",
      %{"groupId" => group_id, "password" => password, "fingerprint" => fingerprint, "display" => display},
      opts
    )
  end

  defp validate_url(url, opts) do
    uri = URI.parse(url)
    insecure? = Keyword.get(opts, :allow_insecure, false) == true

    cond do
      uri.scheme == "https" and valid_pin?(Keyword.get(opts, :fingerprint)) -> {:ok, uri}
      uri.scheme == "http" and insecure? -> {:ok, uri}
      uri.scheme in ["http", "https"] -> {:error, "bad_server_identity", "远端连接必须使用已钉选的 HTTPS 服务器指纹"}
      true -> {:error, "bad_request", "远端地址必须是 http(s) URL"}
    end
  end

  defp endpoint(%URI{host: host} = uri, method) when is_binary(host) do
    base_path = String.trim_trailing(uri.path || "", "/")
    path = base_path <> "/api/" <> method
    {:ok, URI.to_string(%{uri | path: path, query: nil, fragment: nil, userinfo: nil})}
  end

  defp endpoint(_, _), do: {:error, "bad_request", "远端地址缺少主机名"}

  defp encode_request(method, payload) do
    Jason.encode(%{
      "rpcId" => "bridge-" <> Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false),
      "method" => method,
      "payload" => payload
    })
  end

  defp request(%URI{scheme: "https"} = uri, url, body, opts) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    headers = [{"content-type", "application/json"}, {"accept", "application/json"}]
    headers = add_device_header(headers, Keyword.get(opts, :device_token))
    pinned_request(uri, url, body, headers, opts, timeout)
  end

  defp request(%URI{scheme: "http"}, url, body, opts) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    headers = [{"content-type", "application/json"}, {"accept", "application/json"}]
    headers = add_device_header(headers, Keyword.get(opts, :device_token))
    request_opts = [body: body, headers: headers, receive_timeout: timeout, redirect: false]
    request_opts = Keyword.put(request_opts, :connect_options, timeout: timeout)

    case Req.post(url, request_opts) do
      {:ok, %Req.Response{} = response} -> {:ok, response}
      {:error, %Req.TransportError{reason: reason}} -> {:error, "network_unavailable", transport_reason(reason)}
      {:error, _reason} -> {:error, "network_unavailable", "无法连接协作 Hub"}
    end
  rescue
    _ -> {:error, "network_unavailable", "无法连接协作 Hub"}
  end

  # Pinned TLS: verify_none at handshake, then check peercert hash BEFORE sending
  # any secret on the same connection. No CA chain involved, no TOCTOU.
  defp pinned_request(uri, url, body, headers, opts, timeout) do
    host = uri.host || "127.0.0.1"
    port = uri.port || 443
    fingerprint = Keyword.get(opts, :fingerprint)
    path = url_path(url)

    with {:ok, sock} <- ssl_probe(host, port, timeout),
         {:ok, :pinned} <- verify_pinned(sock, fingerprint),
         :ok <- ssl_send(sock, path, host, port, body, headers),
         {:ok, status, resp_body} <- ssl_recv(sock, timeout) do
      :ssl.close(sock)
      {:ok, %{status: status, body: resp_body}}
    else
      {:error, code, _message} = err when is_binary(code) ->
        err

      {:error, reason} ->
        {:error, "network_unavailable", transport_reason(reason)}
    end
  rescue
    _ -> {:error, "network_unavailable", "无法连接协作 Hub"}
  end

  defp ssl_probe(host, port, timeout) do
    host_cl = String.to_charlist(host)

    ip_opts =
      case :inet.parse_address(host_cl) do
        {:ok, _} -> []
        _ -> []
      end

    case :ssl.connect(
           host_cl,
           port,
           [
             versions: [:"tlsv1.2", :"tlsv1.3"],
             verify: :verify_none,
             server_name_indication: host_cl,
             active: false,
             mode: :binary,
             packet: :raw
           ] ++ ip_opts,
           timeout
         ) do
      {:ok, sock} -> {:ok, sock}
      {:error, reason} -> {:error, reason}
    end
  end

  defp verify_pinned(sock, expected) do
    with {:ok, der} <- :ssl.peercert(sock),
         actual when is_binary(actual) <- "sha256:" <> Base.encode16(:crypto.hash(:sha256, der), case: :lower),
         true <- String.downcase(to_string(expected || "")) == actual do
      {:ok, :pinned}
    else
      _ ->
        _ =
          try do
            :ssl.close(sock)
          rescue
            _ -> :ok
          end

        {:error, "bad_server_identity", "服务器证书指纹不匹配，已拒绝发送凭据"}
    end
  end

  defp ssl_send(sock, path, host, port, body, headers) do
    lines = [
      "POST " <> path <> " HTTP/1.1",
      "Host: " <> host <> ":" <> Integer.to_string(port),
      "Connection: close",
      "Content-Length: " <> Integer.to_string(byte_size(body))
    ]

    lines = Enum.reduce(headers, lines, fn {k, v}, acc -> acc ++ [k <> ": " <> v] end)
    req = Enum.join(lines, "\r\n") <> "\r\n\r\n" <> body

    case :ssl.send(sock, req) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp ssl_recv(sock, timeout) do
    ssl_recv_loop(sock, timeout, <<>>)
  end

  defp ssl_recv_loop(sock, timeout, acc) do
    if byte_size(acc) > @max_response_bytes + 16_384 do
      _ =
        try do
          :ssl.close(sock)
        rescue
          _ -> :ok
        end

      {:error, "response_too_large", "远端响应超过大小限制"}
    else
      case :ssl.recv(sock, 0, timeout) do
        {:ok, data} -> ssl_recv_loop(sock, timeout, acc <> IO.iodata_to_binary(data))
        {:error, :closed} -> parse_http_response(acc)
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp parse_http_response(raw) do
    case :binary.split(raw, "\r\n\r\n") do
      [head, body] ->
        [status_line | _] = String.split(head, "\r\n")

        case String.split(status_line, " ", parts: 3) do
          [_ver, code | _] ->
            case Integer.parse(code) do
              {status, _} -> {:ok, status, body}
              :error -> {:error, "bad_response", "远端响应状态行无效"}
            end

          _ ->
            {:error, "bad_response", "远端响应状态行无效"}
        end

      _ ->
        {:error, "bad_response", "远端响应不是有效 HTTP"}
    end
  end

  defp url_path(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{path: path, query: query} ->
        p = if path in [nil, ""], do: "/", else: path
        if query in [nil, ""], do: p, else: p <> "?" <> query
    end
  end

  defp url_path(_), do: "/"

  defp add_device_header(headers, token) when is_binary(token) and token != "" do
    [{"x-newbee-device-token", token} | headers]
  end

  defp add_device_header(headers, _), do: headers

  defp response_body(%{status: status, body: body}) when is_integer(status) and status in 200..299 do
    body = if is_binary(body), do: body, else: Jason.encode!(body)
    if byte_size(body) <= @max_response_bytes, do: {:ok, body}, else: {:error, "response_too_large", "远端响应超过大小限制"}
  end

  defp response_body(%{status: status}) when is_integer(status) do
    {:error, "remote_http", "远端返回 HTTP 状态 " <> Integer.to_string(status)}
  end

  defp decode_response(body) do
    case Jason.decode(body) do
      {:ok, value} when is_map(value) -> {:ok, value}
      _ -> {:error, "bad_response", "远端响应不是有效 JSON"}
    end
  end

  defp decode_result(%{"result" => %{"ok" => value}}), do: {:ok, value}

  defp decode_result(%{"result" => %{"error" => %{"code" => code, "message" => message}}})
       when is_binary(code) and is_binary(message),
       do: {:error, code, message}

  defp decode_result(_), do: {:error, "bad_response", "远端响应缺少 RPC 结果"}

  defp validate_method(method) do
    if Regex.match?(~r/^xgroup\.bridge\.(join|poll|ack|sync|heartbeat|publish|command|chat)$/, method),
      do: :ok,
      else: {:error, "forbidden", "不是允许的 Bridge RPC"}
  end

  defp valid_pin?(pin) when is_binary(pin), do: Regex.match?(~r/^sha256:[0-9a-fA-F]{64}$/, pin)
  defp valid_pin?(_), do: false

  defp transport_reason(:timeout), do: "连接超时"
  defp transport_reason(:closed), do: "远端连接已关闭"
  defp transport_reason(_), do: "网络连接失败"
end
