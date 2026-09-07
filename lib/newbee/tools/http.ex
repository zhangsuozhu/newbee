defmodule Newbee.Tools.Http do
  @moduledoc """
  HTTP POST/headers/status; plain-GET bodies via `Newbee.read/1`.
  URLs also resolve through unified `Newbee.read/1`.

  ## Functions
  - `get(url, headers \\\\ []) :: {:ok, %{status: integer(), body: String.t()}} | {:error, reason}` — GET request. Errors split three ways: `{:error, %{reason: :invalid_url}}` (malformed URL) vs `{:error, %{reason: :network_error}}` (network down) vs `{:error, %{reason: :request_failed}}` (anything else).
  - `post(url, json, headers \\ []) :: {:ok, %{status, body}} | {:error, reason}` — POST; `json` takes a `map` (auto `Jason.encode!`) or a JSON `String.t()` sent as-is.

  Runs on `Req`, 30_000ms default timeout, bodies cut at 512KB.

  ## Runnable example
      {:ok, %{status: 200, body: body}} = Newbee.Tools.Http.get("https://example.com")
      {:ok, %{status: 200}} = Newbee.Tools.Http.post("https://api.example.com/v1/chat", %{model: "gpt-4", messages: []})
      {:ok, html} = Newbee.read("https://example.com")
  """

  @default_timeout 30_000
  @max_body 512 * 1024

  @doc "GET request. Errors split three ways: `{:error, %{reason: :invalid_url}}` (malformed URL) vs `{:error, %{reason: :network_error}}` (network down) vs `{:error, %{reason: :request_failed}}` (anything else). Returns {:ok, %{status, body}} | {:error, reason}."
  def get(url, headers \\ []) do
    request(:get, url, nil, headers)
  end

  @doc "POST request (json takes map, or a JSON string sent as-is). Returns `{:ok, %{status: integer(), body: String.t()}} | {:error, reason}` (same error split as `get/2`)."
  def post(url, json, headers \\ []) do
    request(:post, url, json, headers)
  end

  # 负载发送方式：字符串按契约原样发送（body:），仅 map 走 Req 的 JSON 编码（json:）。
  # GET 负载恒为 nil，沿用 json: nil，行为不变。
  defp payload_options(nil), do: [json: nil]

  defp payload_options(json) when is_binary(json), do: [body: json]
  defp payload_options(json), do: [json: json]

  # 请求头：透传用户头（user-agent 除外）；JSON 字符串负载默认补 content-type/accept
  # （与旧 json: 选项路径对齐，多数服务端按 CT 解析请求体）；用户已提供 content-type 时不覆盖。
  defp request_headers(headers, json) do
    has_ct? = Enum.any?(headers, fn {k, _} -> String.downcase(to_string(k)) == "content-type" end)

    json_defaults =
      if is_binary(json) and not has_ct? do
        [{"content-type", "application/json"}, {"accept", "application/json"}]
      else
        []
      end

    (headers
     |> Enum.reject(fn {k, _} -> String.downcase(to_string(k)) == "user-agent" end)
     |> Enum.map(fn {k, v} -> {to_string(k), to_string(v)} end)) ++
      json_defaults ++ [{"user-agent", Newbee.LLM.Client.user_agent()}]
  end

  defp request(method, url, json, headers) do
    # Req 的默认 adapter 是 Finch，注册表 `Req.Finch` 由 `Req.Application` 启动；
    # 求值节点可能不引导 :req 应用，这里幂等自举（Host.Shell 使用同一条路径）。
    Newbee.Host.Shell.ensure_finch!()
    user_headers = request_headers(headers, json)

    # 先校验 URL 格式
    case URI.parse(url) do
      %URI{scheme: scheme} when scheme not in ["http", "https"] ->
        {:error, %{reason: :invalid_url, hint: "URL scheme must be http or https: " <> url}}

      %URI{host: host} when host in [nil, ""] ->
        {:error, %{reason: :invalid_url, hint: "URL has no host: " <> url}}

      _uri ->
        req =
          Req.new(
            # 负载：字符串按契约原样发送（body:），map 走 Req 的 JSON 编码（json:）
            [
              url: url,
              method: method,
              headers: user_headers,
              # Req 默认按 content-type 自动解码 application/json 响应（body 会变成 map/list），
              # 而本工具契约是 body 始终为原始文本，这里关闭响应体自动解码。
              decode_body: false,
              receive_timeout: @default_timeout,
              retry: false
            ] ++
              payload_options(json)
          )

        case Req.request(req) do
          {:ok, %{status: status, body: body}} when is_binary(body) ->
            {:ok, %{status: status, body: String.slice(body, 0, @max_body)}}

          {:ok, %{status: status}} ->
            # 走到这里只剩 Req 原生空体响应（204/304 等）；body 原样为 ""
            {:ok, %{status: status, body: ""}}

          {:error, %Req.TransportError{reason: reason}} ->
            {:error, %{reason: :network_error, hint: "network error: " <> inspect(reason)}}

          {:error, reason} ->
            {:error, %{reason: :request_failed, hint: "request failed: " <> inspect(reason)}}
        end
    end
  rescue
    e -> {:error, %{reason: :request_failed, hint: "request raised: " <> Exception.message(e)}}
  end
end
