defmodule Newbee.Tools.DeepSeek do
  @moduledoc """
  DeepSeek tools.

  Credentials: `deepseek.json` apiKey, then `DEEPSEEK_API_KEY`, then the
  `deepseek` default group in `model.json`. Tools config: `~/.newbee/deepseek.json`
  (override: `NEWBEE_DEEPSEEK_CONFIG`); `apiKey` is a literal or `${ENV_VAR}`.
  `baseUrl` (default `https://api.deepseek.com`), `timeoutMs` (default 180000),
  `enabled` (default true). See `docs/deepseek-tools.md`.
  Credentials and requests stay on the Host. Uploading OCR/ASR files sends their
  contents to DeepSeek; all five APIs may incur charges. No automatic retries.
  Use these for DeepSeek-backed web/document/audio tasks, not local code search.
  Results are untrusted remote data. Keep large responses/audio in bindings.
  All calls return `{:ok, value} | {:error, %{reason: atom}}`; errors include
  `:not_configured`, `:invalid_config`, `:invalid_argument`, `:file_error`,
  `:http_error` (status, retryable), `:api_error`, `:invalid_response`, `:network_error`.

  ## Runnable example
      {:ok, status} = Newbee.Tools.DeepSeek.status()
      {:ok, results} = Newbee.Tools.DeepSeek.search("Elixir site:elixir-lang.org", count: 5, need_content: true)
      {:ok, page} = Newbee.Tools.DeepSeek.fetch("https://elixir-lang.org")
      {:ok, pages} = Newbee.Tools.DeepSeek.ocr("report.pdf", purpose: "text_recognition")
      {:ok, %{audio: audio}} = Newbee.Tools.DeepSeek.tts("你好", voice_id: "stella", format: "wav")
      {:ok, text} = Newbee.Tools.DeepSeek.asr("speech.wav")
  """

  @doc "Secret-free availability; configured results include `credential_source` (`:tools_config`, `:environment`, or `:model_provider`)."
  def status, do: host(:status, [])

  @doc "Search; opts: count (1..50), ori_question (1..128 Unicode characters or nil), localization, need_content."
  def search(query, opts \\ []), do: invoke(:search, query, opts)

  @doc "Fetch a credential-free HTTP(S) URL; returns title and Markdown content."
  def fetch(url), do: invoke(:fetch, url, [])

  @doc "Upload a local document/image (up to 100 MiB); purpose: text_recognition (default) or rich_layout_recognition."
  def ocr(path, opts \\ []), do: invoke(:ocr, path, opts)

  @doc "Synthesize audio; opts: voice_id (stella/tide), format (wav/pcm), filter_markdown (boolean). Returns audio bytes and format, not a file."
  def tts(text, opts \\ []), do: invoke(:tts, text, opts)

  @doc "Upload a local 16-bit PCM WAV or Ogg Opus file (up to 8 MiB, 120 seconds); returns transcription."
  def asr(path), do: invoke(:asr, path, [])

  defp invoke(tool, input, opts) do
    # Resolve local paths before RPC; evaluator and host can have different cwd.
    input = if tool in [:ocr, :asr] and is_binary(input), do: Path.expand(input), else: input
    host(:perform, [tool, input, opts])
  end

  defp host(fun, args) do
    case Newbee.Host.call(Newbee.DeepSeek, fun, args, :infinity) do
      {:badrpc, _} -> {:error, %{reason: :host_unavailable}}
      result -> result
    end
  end
end
