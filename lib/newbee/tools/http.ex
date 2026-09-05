defmodule Newbee.Tools.Http do
  @moduledoc """
  HTTP POST/headers/status; plain-GET bodies via `Newbee.read/1`.
  URLs also resolve through unified `Newbee.read/1`.

  ## Functions
  - `get(url, headers \\\\ []) :: {:ok, %{status: integer(), body: String.t()}} | {:error, reason}` — GET request. Errors split three ways: `{:error, %{reason: :invalid_url}}` (malformed URL) vs `{:error, %{reason: :network_error}}` (network down) vs `{:error, %{reason: :request_failed}}` (anything else).
  - `post(url, json, headers \\\\ []) :: {:ok, %{status, body}} | {:error, reason}` — POST; `json` takes a `map` (auto `Jason.encode!`) or a `String.t()`.

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

  @doc "POST request (json takes map/string). Returns `{:ok, %{status: integer(), body: String.t()}} | {:error, reason}` (same error split as `get/2`)."
  def post(url, json, headers \\ []) do
    request(:post, url, json, headers)
  end

  defp request(method, url, json, headers) do
    # Req 的默认 adapter 是 Finch，注册表 `Req.Finch` 由 `Req.Application` 启动；
    # 求值节点可能不引导 :req 应用，这里幂等自举（Host.Shell 使用同一条路径）。
    Newbee.Host.Shell.ensure_finch!()

    # 先校验 URL 格式
    case URI.parse(url) do
      %URI{scheme: scheme} when scheme not in ["http", "https"] ->
        {:error, %{reason: :invalid_url, hint: "URL scheme must be http or https: " <> url}}

      %URI{host: host} when host in [nil, ""] ->
        {:error, %{reason: :invalid_url, hint: "URL has no host: " <> url}}

      _uri ->
        req =
          Req.new(
            url: url,
            method: method,
            headers:
              (headers
               |> Enum.reject(fn {k, _} -> String.downcase(to_string(k)) == "user-agent" end)
               |> Enum.map(fn {k, v} -> {to_string(k), to_string(v)} end)) ++
                [{"user-agent", "newbee"}],
            json: json,
            receive_timeout: @default_timeout,
            retry: false
          )

        case Req.request(req) do
          {:ok, %{status: status, body: body}} when is_binary(body) ->
            {:ok, %{status: status, body: String.slice(body, 0, @max_body)}}

          {:ok, %{status: status}} ->
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
