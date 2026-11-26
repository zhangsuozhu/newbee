defmodule Newbee.DeepSeek do
  @moduledoc false
  @tools [:search, :fetch, :ocr, :tts, :asr]
  @default_url "https://api.deepseek.com"

  def status do
    case config() do
      {:ok, cfg} -> {:ok, %{configured: true, tools: @tools, credential_source: cfg.source}}
      {:error, %{reason: :not_configured}} -> {:ok, %{configured: false, tools: []}}
      error -> error
    end
  end

  # Host entry point: credentials never travel back to the evaluator.
  def perform(tool, input, opts) do
    with {:ok, cfg} <- config(),
         {:ok, payload} <- payload(tool, input, opts) do
      request(tool, payload, cfg)
    end
  end

  defp config do
    path = System.get_env("NEWBEE_DEEPSEEK_CONFIG") || Path.join(System.user_home!(), ".newbee/deepseek.json")

    with {:ok, spec} <- read_config(path),
         :ok <- check(is_map(spec), :invalid_config, :config),
         :ok <- check(is_boolean(Map.get(spec, "enabled", true)), :invalid_config, :enabled),
         {:ok, credentials} <- credentials(spec) do
      if spec["enabled"] == false, do: error(:not_configured), else: resolve_config(spec, credentials)
    end
  rescue
    _ -> error(:invalid_config)
  end

  defp read_config(path) do
    case File.read(path) do
      {:ok, bytes} ->
        case Jason.decode(bytes) do
          {:ok, spec} -> {:ok, spec}
          _ -> error(:invalid_config)
        end

      {:error, :enoent} ->
        {:ok, %{}}

      {:error, _} ->
        error(:config_unreadable)
    end
  end

  defp resolve_config(spec, credentials) do
    {key, source} = credentials
    base = Map.get(spec, "baseUrl", @default_url)
    timeout = Map.get(spec, "timeoutMs", 180_000)

    with :ok <- check(is_nil(key) or is_binary(key), :invalid_config, :apiKey),
         :ok <- check(is_binary(base) and endpoint?(base), :invalid_config, :baseUrl),
         :ok <- check(is_integer(timeout) and timeout in 1..1_800_000, :invalid_config, :timeoutMs),
         :ok <- check(is_binary(key) and String.trim(key) != "", :not_configured, :apiKey),
         :ok <- check(not String.contains?(key, ["\r", "\n"]), :invalid_config, :apiKey) do
      base = base |> String.trim_trailing("/") |> String.trim_trailing("/v1")
      {:ok, %{key: key, base: base, timeout: timeout, source: source}}
    end
  end

  # Explicit tool credentials must never silently switch accounts. Only an absent
  # apiKey and an absent/blank environment key permit the model-provider fallback.
  defp credentials(%{"apiKey" => key}) do
    key =
      case key do
        "${" <> rest -> System.get_env(String.trim_trailing(rest, "}"))
        value -> value
      end

    {:ok, {key, :tools_config}}
  end

  defp credentials(_spec) do
    case System.get_env("DEEPSEEK_API_KEY") do
      key when is_binary(key) and key != "" ->
        if String.trim(key) == "", do: model_credentials(), else: {:ok, {key, :environment}}

      _ ->
        model_credentials()
    end
  end

  defp model_credentials do
    case Newbee.LLM.Config.provider_api_key_strict("deepseek") do
      {:ok, key} -> {:ok, {key, :model_provider}}
      {:error, _reason} -> error(:invalid_config)
    end
  end

  defp endpoint?(url) do
    case URI.new(url) do
      {:ok, %URI{scheme: "https", host: host, port: port, userinfo: nil, query: nil, fragment: nil}}
      when is_binary(host) and host != "" and port in 1..65535 ->
        true

      _ ->
        false
    end
  end

  defp payload(tool, input, opts) do
    with :ok <- check(Keyword.keyword?(opts), :invalid_argument, :options) do
      build_payload(tool, input, opts)
    end
  end

  defp build_payload(:search, query, opts) do
    with :ok <- check(short_text?(query), :invalid_argument, :query),
         :ok <- options(opts, [:count, :ori_question, :localization, :need_content]),
         :ok <-
           check(
             is_integer(Keyword.get(opts, :count, 10)) and Keyword.get(opts, :count, 10) in 1..50,
             :invalid_argument,
             :count
           ),
         :ok <- check(is_nil(opts[:ori_question]) or short_text?(opts[:ori_question]), :invalid_argument, :ori_question),
         :ok <- check(is_binary(Keyword.get(opts, :localization, "")), :invalid_argument, :localization),
         :ok <- check(is_boolean(Keyword.get(opts, :need_content, false)), :invalid_argument, :need_content) do
      {:ok, [json: Map.new(opts) |> Map.put(:query, query)]}
    end
  end

  defp build_payload(:fetch, url, opts) do
    with :ok <- options(opts, []),
         :ok <- check(fetch_url?(url), :invalid_argument, :url) do
      {:ok, [json: %{url: url}]}
    end
  end

  defp build_payload(:tts, text, opts) do
    with :ok <- options(opts, [:voice_id, :format, :filter_markdown]),
         :ok <- check(is_binary(text) and String.valid?(text) and String.trim(text) != "", :invalid_argument, :text),
         :ok <- check(Keyword.get(opts, :voice_id, "stella") in ["stella", "tide"], :invalid_argument, :voice_id),
         :ok <- check(Keyword.get(opts, :format, "wav") in ["wav", "pcm"], :invalid_argument, :format),
         :ok <- check(is_boolean(Keyword.get(opts, :filter_markdown, true)), :invalid_argument, :filter_markdown),
         :ok <- check(tts_length(text) <= 10_000, :invalid_argument, :text),
         body = Map.new(opts) |> Map.put(:text, text),
         :ok <- check(byte_size(Jason.encode!(body)) <= 65_536, :invalid_argument, :text) do
      {:ok, [json: body]}
    end
  end

  defp build_payload(tool, path, opts) when tool in [:ocr, :asr] do
    allowed = if tool == :ocr, do: [:purpose], else: []
    purpose = Keyword.get(opts, :purpose, "text_recognition")
    limit = if tool == :ocr, do: 100 * 1024 * 1024, else: 8 * 1024 * 1024

    with :ok <- options(opts, allowed),
         :ok <-
           check(
             tool != :ocr or purpose in ["text_recognition", "rich_layout_recognition"],
             :invalid_argument,
             :purpose
           ),
         :ok <- check(is_binary(path) and path != "", :invalid_argument, :file),
         {:ok, bytes} <- read_upload(path, limit) do
      fields = [file: {bytes, filename: Path.basename(path)}]
      fields = if tool == :ocr, do: fields ++ [purpose: purpose], else: fields
      {:ok, [form_multipart: fields]}
    end
  end

  defp build_payload(_, _, _), do: error(:invalid_argument, :tool)

  defp read_upload(path, limit) do
    case File.stat(path) do
      {:ok, %{type: :regular, size: size}} when size > 0 and size <= limit ->
        # Bound the actual read too (file could grow after stat).
        case File.open(path, [:read, :binary], &IO.binread(&1, limit + 1)) do
          {:ok, bytes} when is_binary(bytes) and byte_size(bytes) > 0 and byte_size(bytes) <= limit -> {:ok, bytes}
          _ -> error(:file_error, :file)
        end

      {:ok, %{size: size}} when size > limit ->
        error(:invalid_argument, :file_size)

      _ ->
        error(:file_error, :file)
    end
  end

  defp request(tool, payload, cfg) do
    Newbee.Host.Shell.ensure_finch!()
    limit = if tool == :tts, do: 100 * 1024 * 1024, else: 16 * 1024 * 1024

    opts =
      [
        method: :post,
        url: cfg.base <> "/v1/tools/" <> Atom.to_string(tool),
        headers: [{"authorization", "Bearer " <> cfg.key}, {"user-agent", Newbee.LLM.Client.user_agent()}],
        receive_timeout: cfg.timeout,
        connect_options: [timeout: 10_000],
        retry: false,
        redirect: false,
        decode_body: false,
        into: fn {:data, data}, {req, resp} ->
          size = Map.get(resp.private, :deepseek_bytes, 0) + byte_size(data)
          if size > limit, do: throw(:deepseek_response_too_large)
          resp = %{resp | body: [resp.body || "", data], private: Map.put(resp.private, :deepseek_bytes, size)}
          {:cont, {req, resp}}
        end
      ] ++ payload

    case Req.request(opts) do
      {:ok, %{status: status, body: body} = response} ->
        body = IO.iodata_to_binary(body || "")

        cond do
          status not in 200..299 ->
            {:error, %{reason: :http_error, status: status, retryable: status in [408, 429] or status >= 500}}

          tool == :tts ->
            audio_response(body, payload, response)

          true ->
            json_response(tool, body)
        end

      {:error, _} ->
        error(:network_error)
    end
  rescue
    # Never return exception/request/body text: they may contain credentials or file contents.
    _ -> error(:network_error)
  catch
    :throw, :deepseek_response_too_large -> error(:response_too_large)
  end

  defp audio_response(body, payload, response) do
    format = Map.get(payload[:json], :format, "wav")
    content_types = Req.Response.get_header(response, "content-type")

    cond do
      Enum.any?(content_types, &String.contains?(&1, "json")) ->
        json_response(:tts, body)

      body == "" ->
        error(:invalid_response)

      Enum.any?(content_types, &(String.split(&1, ";") |> hd() |> String.trim() == "audio/" <> format)) ->
        {:ok, %{audio: body, format: format}}

      true ->
        error(:invalid_response)
    end
  end

  defp json_response(tool, body) do
    case Jason.decode(body) do
      {:ok, %{"error" => _}} ->
        error(:api_error)

      {:ok, %{"results" => results} = value} when tool == :search and is_list(results) ->
        {:ok, value}

      {:ok, %{"title" => title, "content" => text} = value}
      when tool == :fetch and is_binary(title) and is_binary(text) ->
        {:ok, value}

      {:ok, %{"pages" => pages} = value} when tool == :ocr and is_list(pages) ->
        {:ok, value}

      {:ok, %{"text" => text} = value} when tool == :asr and is_binary(text) ->
        {:ok, value}

      _ ->
        error(:invalid_response)
    end
  end

  defp options(opts, allowed),
    do:
      check(
        Enum.all?(opts, fn {k, _} -> k in allowed end) and
          length(Keyword.keys(opts)) == length(Enum.uniq(Keyword.keys(opts))),
        :invalid_argument,
        :options
      )

  defp short_text?(s),
    do: is_binary(s) and String.valid?(s) and String.trim(s) != "" and length(String.to_charlist(s)) in 1..128

  defp tts_length(text) do
    # DeepSeek bills Han characters as two characters, all others as one.
    length(String.to_charlist(text)) + length(Regex.scan(~r/\p{Han}/u, text))
  end

  defp fetch_url?(url) when is_binary(url) do
    String.valid?(url) and length(String.to_charlist(url)) in 1..8192 and
      case URI.new(url) do
        {:ok, %URI{scheme: scheme, host: host, port: port, userinfo: nil}}
        when scheme in ["http", "https"] and is_binary(host) and host != "" and port in 1..65535 ->
          true

        _ ->
          false
      end
  end

  defp fetch_url?(_), do: false
  defp check(true, _, _), do: :ok
  defp check(false, reason, field), do: error(reason, field)
  defp error(reason), do: {:error, %{reason: reason}}
  defp error(reason, field), do: {:error, %{reason: reason, field: field}}
end
