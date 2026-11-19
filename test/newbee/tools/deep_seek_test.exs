defmodule Newbee.Tools.DeepSeekTest do
  use ExUnit.Case, async: false
  alias Newbee.Tools.DeepSeek

  setup do
    root = Path.join(System.tmp_dir!(), "newbee-deepseek-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    vars = ["NEWBEE_DEEPSEEK_CONFIG", "DEEPSEEK_API_KEY", "NEWBEE_DEEPSEEK_TEST_KEY"]
    previous = Map.new(vars, &{&1, System.get_env(&1)})
    original_req_options = Application.fetch_env(:req, :default_options)
    Req.default_options(plug: {Req.Test, __MODULE__})
    System.put_env("NEWBEE_DEEPSEEK_CONFIG", Path.join(root, "config.json"))
    System.put_env("DEEPSEEK_API_KEY", "test-secret-not-for-output")
    System.delete_env("NEWBEE_DEEPSEEK_TEST_KEY")

    on_exit(fn ->
      case original_req_options do
        {:ok, options} -> Application.put_env(:req, :default_options, options)
        :error -> Application.delete_env(:req, :default_options)
      end

      Enum.each(previous, fn {k, v} -> if v, do: System.put_env(k, v), else: System.delete_env(k) end)
      File.rm_rf!(root)
    end)

    %{root: root}
  end

  defp configure(spec), do: File.write!(System.fetch_env!("NEWBEE_DEEPSEEK_CONFIG"), Jason.encode!(spec))

  defp perform(tool, input, opts \\ []) do
    case tool do
      tool when tool in [:fetch, :asr] -> apply(DeepSeek, tool, [input])
      tool -> apply(DeepSeek, tool, [input, opts])
    end
  end

  defp reply(conn, value, status \\ 200), do: Req.Test.json(Plug.Conn.put_status(conn, status), value)

  test "missing key is unavailable, omitted from prompt, and does not send requests" do
    System.delete_env("DEEPSEEK_API_KEY")
    assert {:ok, %{configured: false, tools: []}} = DeepSeek.status()
    assert {:error, %{reason: :not_configured}} = DeepSeek.search("Elixir")
    refute Newbee.Plugins.prompt_section() =~ "Newbee.Tools.DeepSeek"
  end

  test "configured tools are registered and discoverable without exposing secrets" do
    assert {:ok, %{configured: true, tools: [:search, :fetch, :ocr, :tts, :asr]}} = DeepSeek.status()
    assert Newbee.Plugins.module_for("DeepSeek") == DeepSeek
    assert Newbee.Plugins.builtin("tool.deepseek").capabilities == [:net, :fs]
    section = Newbee.Plugins.prompt_section()
    assert section =~ "Newbee.Tools.DeepSeek"
    assert byte_size(section) <= 1800
    refute inspect(DeepSeek.status()) =~ "test-secret"
    assert :ok = Newbee.Environment.ToolContract.validate_builtin(DeepSeek)
  end

  test "explicitly disabled configuration wins over environment key" do
    configure(%{"enabled" => false})
    assert {:ok, %{configured: false}} = DeepSeek.status()
    assert {:error, %{reason: :not_configured}} = DeepSeek.fetch("https://example.com")
  end

  test "configuration accepts env references and normalizes /v1 exactly once" do
    System.put_env("NEWBEE_DEEPSEEK_TEST_KEY", "alternate-secret")

    configure(%{
      "apiKey" => "${NEWBEE_DEEPSEEK_TEST_KEY}",
      "baseUrl" => "https://gateway.example/prefix/v1/",
      "timeoutMs" => 1234
    })

    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.host == "gateway.example"
      assert conn.request_path == "/prefix/v1/tools/search"
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer alternate-secret"]
      reply(conn, %{"results" => []})
    end)

    assert {:ok, %{"results" => []}} = perform(:search, "Elixir")
  end

  test "invalid configurations fail closed without returning their contents" do
    for spec <- [
          [],
          %{"enabled" => "yes"},
          %{"apiKey" => 7},
          %{"timeoutMs" => 0},
          %{"baseUrl" => "http://example.com"},
          %{"baseUrl" => "https://user:pass@example.com"},
          %{"baseUrl" => "https://example.com?token=secret"}
        ] do
      configure(spec)
      assert {:error, %{reason: :invalid_config}} = DeepSeek.status()
    end

    File.write!(System.fetch_env!("NEWBEE_DEEPSEEK_CONFIG"), "{secret")
    assert {:error, %{reason: :invalid_config}} = DeepSeek.status()
  end

  test "search preserves every option and full structured response" do
    result = %{"title" => "Elixir", "url" => "https://elixir-lang.org", "content" => String.duplicate("文", 200_000)}

    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.method == "POST"
      assert conn.request_path == "/v1/tools/search"
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer test-secret-not-for-output"]
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      assert Jason.decode!(body) == %{
               "query" => "Elixir site:elixir-lang.org",
               "count" => 5,
               "ori_question" => "什么是 Elixir？",
               "localization" => "1.2.3.4",
               "need_content" => true
             }

      reply(conn, %{"results" => [result]})
    end)

    assert {:ok, %{"results" => [^result]}} =
             perform(:search, "Elixir site:elixir-lang.org",
               count: 5,
               ori_question: "什么是 Elixir？",
               localization: "1.2.3.4",
               need_content: true
             )
  end

  test "search rejects invalid inputs and unknown or duplicate options" do
    for {query, opts} <- [
          {"", []},
          {" \t\n", []},
          {String.duplicate("中", 129), []},
          {nil, []},
          {"ok", [count: 0]},
          {"ok", [count: 51]},
          {"ok", [count: 1.5]},
          {"ok", [need_content: "true"]},
          {"ok", [ori_question: ""]},
          {"ok", [localization: nil]},
          {"ok", [typo: true]},
          {"ok", %{}},
          {"ok", [count: 1, count: 99]}
        ] do
      assert {:error, %{reason: :invalid_argument}} = perform(:search, query, opts)
    end
  end

  test "Unicode boundary counts codepoints, not bytes or graphemes" do
    Req.Test.expect(__MODULE__, fn conn -> reply(conn, %{"results" => []}) end)
    assert {:ok, _} = perform(:search, String.duplicate("中", 128), ori_question: nil)
    assert {:error, %{field: :query}} = perform(:search, String.duplicate("a\u0301", 65))
  end

  test "fetch sends URL and returns Markdown" do
    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.request_path == "/v1/tools/fetch"
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert Jason.decode!(body) == %{"url" => "https://example.com/a?q=1"}
      reply(conn, %{"title" => "Example", "content" => "# Markdown\n正文"})
    end)

    assert {:ok, %{"content" => "# Markdown\n正文"}} = perform(:fetch, "https://example.com/a?q=1")
  end

  test "fetch rejects non-HTTP URLs, missing hosts and credentials" do
    for url <- [
          nil,
          "",
          "/relative",
          "file:///etc/passwd",
          "https://",
          "https://u:p@example.com",
          "https://example.com/" <> String.duplicate("x", 8192)
        ] do
      assert {:error, %{reason: :invalid_argument, field: :url}} = perform(:fetch, url)
    end
  end

  test "OCR uploads bytes, filename and purpose using multipart", %{root: root} do
    path = Path.join(root, "report.pdf")
    File.write!(path, "%PDF-test")

    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.request_path == "/v1/tools/ocr"
      assert [type] = Plug.Conn.get_req_header(conn, "content-type")
      assert type =~ "multipart/form-data; boundary="
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert body =~ "filename=\"report.pdf\""
      assert body =~ "%PDF-test"
      assert body =~ "rich_layout_recognition"
      reply(conn, %{"pages" => [%{"index" => 0, "text" => "正文"}]})
    end)

    assert {:ok, %{"pages" => [_]}} = perform(:ocr, path, purpose: "rich_layout_recognition")
  end

  test "ASR uploads audio and preserves transcript metadata", %{root: root} do
    path = Path.join(root, "speech.wav")
    File.write!(path, <<"RIFF", 0, 255, 0, 128>>)

    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.request_path == "/v1/tools/asr"
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert body =~ "filename=\"speech.wav\""
      refute body =~ "name=\"purpose\""
      reply(conn, %{"text" => "你好", "duration_ms" => 1200})
    end)

    assert {:ok, %{"text" => "你好", "duration_ms" => 1200}} = perform(:asr, path)
  end

  test "uploads reject missing, empty, directory and oversized files", %{root: root} do
    empty = Path.join(root, "empty.pdf")
    File.write!(empty, "")

    for path <- [root, empty, Path.join(root, "missing")] do
      assert {:error, %{reason: :file_error}} = perform(:ocr, path)
    end

    large = Path.join(root, "large.wav")

    File.open!(large, [:write], fn io ->
      :file.position(io, 8 * 1024 * 1024)
      IO.binwrite(io, <<0>>)
    end)

    assert {:error, %{field: :file_size}} = perform(:asr, large)
    assert {:error, %{field: :purpose}} = perform(:ocr, empty, purpose: "wrong")
  end

  test "TTS returns non-UTF8 audio intact, not decoded or truncated" do
    audio = <<"RIFF", 0, 255, 128, 0>> <> :binary.copy(<<0, 255>>, 300_000)

    Req.Test.expect(__MODULE__, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      assert Jason.decode!(body) == %{
               "text" => "你好",
               "voice_id" => "tide",
               "format" => "pcm",
               "filter_markdown" => false
             }

      conn |> Plug.Conn.put_resp_content_type("audio/pcm") |> Plug.Conn.send_resp(200, audio)
    end)

    assert {:ok, %{audio: ^audio, format: "pcm"}} =
             perform(:tts, "你好", voice_id: "tide", format: "pcm", filter_markdown: false)
  end

  test "TTS validates text and options" do
    for {text, opts} <- [
          {"", []},
          {nil, []},
          {String.duplicate("x", 65_536), []},
          {"ok", [voice_id: "unknown"]},
          {"ok", [format: "mp3"]},
          {"ok", [filter_markdown: nil]}
        ] do
      assert {:error, %{reason: :invalid_argument}} = perform(:tts, text, opts)
    end
  end

  test "HTTP errors are classified, never retried or credential-echoed" do
    for status <- [400, 401, 402, 403, 404, 408, 429, 500, 504] do
      Req.Test.expect(__MODULE__, fn conn -> reply(conn, %{"error" => "test-secret-not-for-output"}, status) end)
      assert {:error, error} = perform(:search, "Elixir")
      assert error == %{reason: :http_error, status: status, retryable: status in [408, 429] or status >= 500}
      refute inspect(error) =~ "test-secret"
    end
  end

  test "redirects are not followed" do
    Req.Test.expect(__MODULE__, fn conn ->
      conn |> Plug.Conn.put_resp_header("location", "https://other.example") |> Plug.Conn.send_resp(302, "")
    end)

    assert {:error, %{reason: :http_error, status: 302}} = perform(:search, "Elixir")
  end

  test "HTTP 200 API errors are not treated as OCR or TTS success" do
    for tool <- [:ocr, :tts] do
      Req.Test.expect(__MODULE__, fn conn -> reply(conn, %{"error" => %{"message" => "failure"}}) end)

      if tool == :tts do
        assert {:error, %{reason: :api_error}} = perform(tool, "Hello")
      else
        path = System.fetch_env!("NEWBEE_DEEPSEEK_CONFIG")
        configure(%{})
        assert {:error, %{reason: :api_error}} = perform(tool, path)
      end
    end
  end

  test "malformed and wrong-shape responses return invalid_response" do
    for body <- ["<html>error</html>", "{}", "[]", "null"] do
      Req.Test.expect(__MODULE__, fn conn -> Plug.Conn.send_resp(conn, 200, body) end)
      assert {:error, %{reason: :invalid_response}} = perform(:search, "Elixir")
    end
  end

  test "transport errors are values and not automatically retried" do
    Req.Test.expect(__MODULE__, fn conn -> Req.Test.transport_error(conn, :timeout) end)
    assert {:error, %{reason: :network_error}} = perform(:search, "Elixir")
  end

  test "oversized responses fail explicitly instead of returning truncated JSON" do
    Req.Test.expect(__MODULE__, fn conn ->
      Plug.Conn.send_resp(conn, 200, String.duplicate("x", 16 * 1024 * 1024 + 1))
    end)

    assert {:error, %{reason: :response_too_large}} = perform(:search, "Elixir")
  end

  test "TTS enforces weighted text limit and accepts its exact boundary" do
    Req.Test.expect(__MODULE__, fn conn ->
      conn |> Plug.Conn.put_resp_content_type("audio/wav") |> Plug.Conn.send_resp(200, "RIFF-data")
    end)

    assert {:ok, %{format: "wav"}} = perform(:tts, String.duplicate("中", 5000))
    assert {:error, %{field: :text}} = perform(:tts, String.duplicate("中", 5001))
    assert {:error, %{field: :text}} = perform(:tts, String.duplicate("a", 10001))
  end

  test "TTS rejects successful HTML/empty responses instead of presenting them as audio" do
    for {type, body} <- [{"text/html", "<html>Error</html>"}, {"audio/wav", ""}] do
      Req.Test.expect(__MODULE__, fn conn ->
        conn |> Plug.Conn.put_resp_content_type(type) |> Plug.Conn.send_resp(200, body)
      end)

      assert {:error, %{reason: :invalid_response}} = perform(:tts, "Hello")
    end
  end

  test "invalid URL syntax and ports fail before transport" do
    for url <- ["https://exa mple.com", "https://example.com:bad", "https://example.com:99999", "https://[::1"] do
      assert {:error, %{reason: :invalid_argument, field: :url}} = perform(:fetch, url)
      configure(%{"baseUrl" => url})
      assert {:error, %{reason: :invalid_config}} = DeepSeek.status()
      configure(%{})
    end
  end

  test "unreadable config does not fall back to environment credentials", %{root: root} do
    System.put_env("NEWBEE_DEEPSEEK_CONFIG", root)
    assert {:error, %{reason: :config_unreadable}} = DeepSeek.status()
  end
end
