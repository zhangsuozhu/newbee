defmodule Newbee.Tools.Browser do
  @behaviour Newbee.Environment.PluginContract

  @moduledoc """
  Browser automation: isolated Playwright, resumable sessions, or authorized X11 control.

  Omit `session` for a one-shot plan. For interactive work, open `session: "new"` and
  reuse the returned `result["session"]` in later calls. Sessions require the active
  newbee capability, are owner/project scoped, and keep the actual page alive.
  At most four sessions run at once; idle sessions expire after two minutes unless
  `idle_timeout` (10000..1800000 ms) is set when opening. An
  expired handle returns an error, never a silently recreated browser. Close when done.

  `timeout` is the whole-plan budget (500..120000 ms, default 30000), including startup;
  `action_timeout` bounds individual actions (default at most 10000 ms). Errors include
  the failing action and completed results; inspect before retrying submissions.
  Chromium temporary files live under the project `.newbee/browser/tmp` and are cleaned
  up on normal shutdown. Python Playwright and matching browsers must be installed.

  Human-in-the-loop CAPTCHAs: automated solving is not supported. Pause the plan,
  `screenshot` the challenge element to a stable path, report the path and wait for
  the user, then `fill` their answer and continue. Open such sessions with a generous
  `idle_timeout` so the page survives the round-trip.

  ## Runnable example
      {:ok, opened} = Newbee.Tools.Browser.run(%{session: "new", url: "https://example.com"})
      {:ok, _page} = Newbee.Tools.Browser.run(%{session: opened["session"], actions: [
        %{action: "snapshot"}
      ]})
      {:ok, _closed} = Newbee.Tools.Browser.run(%{session: opened["session"], actions: [
        %{action: "close"}
      ]})

      {:ok, result} = Newbee.Tools.Browser.run(%{url: "https://example.com", actions: [
        %{action: "screenshot", path: "/tmp/example.png"}
      ]})

  ## Playwright actions
  `goto/navigate`, `reload`, `back`, `forward`, `click`, `fill`, `type`, `press`, `select`,
  `check/uncheck`, `hover`, `focus`, `scroll`, `wait`, `evaluate`, `set_content`, `set_viewport`,
  `title`, `url`, `snapshot`, `text/html/value/attribute/count/visible/enabled/bounds`, `links`,
  `select_text`, `drag_and_drop`, `bring_to_front`, `screenshot`, `pdf`,
  `new_tab/switch_tab/close_tab/tabs`, `cookies/set_cookie/clear_cookies`, `storage`,
  `headers`, `permissions`, `download`, `upload`, `browser_version` and `close`.
  Pass `record_video_dir` (plus optional `video_size` as `"W,H"`) when opening a session or
  one-shot run to record; `close_tab` then reports its `video`, and `close` (or the end of a
  one-shot run) flushes every page and reports `videos`. Videos must live outside
  `.newbee/browser/tmp`; idle expiry without `close` does not guarantee a recording.
  Locators support CSS, XPath, id, text, role, label, placeholder, alt, title, test_id and frames.
  `snapshot` returns bounded text, links and visible controls with labels and state; use
  `max_chars` and `limit` to bound it. There are at most four tabs per browser session.
  `wait` supports selector, URL, load-state and function conditions; prefer these to sleeps.

  ## Screen actions
  Explicit `backend: "screen"` drives the real X11 desktop, only with user authorization:
  `list_windows`, `focus`, `navigate`, coordinate `click/double_click`, `scroll`, `press`,
  ASCII `type`, `wait`, `screenshot`. Screen mode does not support session handles.
  Artifacts stay inside the project, `~/.newbee`, or `/tmp`.
  """

  @runner_path "priv/browser/playwright_runner.py"
  @max_request_bytes 256 * 1024
  @default_timeout 30_000
  @max_timeout 120_000

  @doc false
  def id, do: "tool.browser"

  @doc false
  def version, do: "1.1.0"

  @doc false
  def dependencies, do: []

  @doc false
  def describe do
    %{
      kind: :tool,
      summary: "Drive an isolated or visible browser: page interaction, DOM queries, downloads, PDFs, screenshots",
      when_to_use:
        "When you need a real browser render, page interaction, login state, downloads, PDFs, screenshots, or explicitly authorized visible-Chrome control",
      avoid_when:
        "For plain public HTTP content use Newbee.read/1 or Newbee.Tools.Http; never use the screen backend unauthorized",
      capabilities: [:browser, :net, :fs, :shell],
      effects: [:process, :external, :fs],
      state_policy: :ephemeral,
      error_contract: %{recoverable: :error_tuple, unexpected: :raise},
      api: [
        %{
          name: :run,
          arity: 1,
          returns: "{:ok, result} | {:error, %{reason: atom(), hint: String.t(), ...}}",
          errors: "Request, runtime, timeout, locator, and page errors all return as recoverable values"
        }
      ],
      examples: [
        "Newbee.Tools.Browser.run(%{url: url, actions: [%{action: \"screenshot\"}]})",
        "Newbee.Tools.Browser.run(%{backend: \"screen\", actions: [%{action: \"screenshot\"}]})"
      ]
    }
  end

  @doc "Run one ordered browser-action plan. Takes a URL or a map with `url`, `backend`, `session`, `actions`, `timeout`, `action_timeout`, `idle_timeout`, `profile`, `viewport`, `storage_state`, `save_storage`, `record_video_dir`, and `video_size`. Returns `{:ok, result}` with action results and produced file paths, else `{:error, reason}`."
  def run(url) when is_binary(url), do: run(%{url: url})

  def run(request) when is_map(request) do
    with {:ok, request} <- normalize_request(request),
         {:ok, json} <- encode_request(request),
         :ok <- validate_request_size(json),
         {:ok, result} <- invoke(request, json) do
      {:ok, result}
    end
  rescue
    error in [ArgumentError, Protocol.UndefinedError] ->
      {:error, %{reason: :invalid_request, hint: Exception.message(error)}}
  end

  def run(other),
    do: {:error, %{reason: :invalid_request, hint: "browser request must be a URL or map, got: #{inspect(other)}"}}

  defp normalize_request(request) do
    request = stringify_keys(request)
    backend = request |> Map.get("backend", "playwright") |> to_string() |> String.downcase()
    timeout = Map.get(request, "timeout", @default_timeout)

    with :ok <- validate_backend(backend),
         {:ok, timeout} <- normalize_timeout(timeout),
         :ok <- validate_session(request["session"], backend),
         :ok <- validate_action_timeout(request["action_timeout"]),
         :ok <- validate_idle_timeout(request["idle_timeout"]) do
      {:ok, request |> Map.put("backend", backend) |> Map.put("timeout", timeout)}
    end
  end

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), stringify_value(value)} end)
  end

  defp stringify_value(value) when is_map(value), do: stringify_keys(value)
  defp stringify_value(value) when is_list(value), do: Enum.map(value, &stringify_value/1)
  defp stringify_value(value), do: value

  defp validate_backend(backend) when backend in ["playwright", "isolated", "screen"], do: :ok

  defp validate_backend(backend) do
    {:error, %{reason: :invalid_backend, hint: "backend must be \"playwright\" or \"screen\", got: #{backend}"}}
  end

  defp normalize_timeout(nil), do: {:ok, @default_timeout}

  defp normalize_timeout(timeout) when is_integer(timeout) and timeout >= 500 and timeout <= @max_timeout,
    do: {:ok, timeout}

  defp normalize_timeout(timeout) do
    {:error,
     %{
       reason: :invalid_timeout,
       hint: "timeout must be an integer from 500 to #{@max_timeout} ms, got: #{inspect(timeout)}"
     }}
  end

  defp encode_request(request) do
    case Jason.encode(request) do
      {:ok, json} ->
        {:ok, json}

      {:error, error} ->
        {:error,
         %{reason: :invalid_request, hint: "browser request is not JSON encodable: #{Exception.message(error)}"}}
    end
  end

  defp validate_request_size(json) when byte_size(json) <= @max_request_bytes, do: :ok

  defp validate_request_size(json) do
    {:error,
     %{reason: :request_too_large, hint: "browser request exceeds #{@max_request_bytes} bytes", bytes: byte_size(json)}}
  end

  defp validate_session(nil, _backend), do: :ok

  defp validate_session(session, backend)
       when is_binary(session) and byte_size(session) in 1..80 and backend in ["playwright", "isolated"], do: :ok

  defp validate_session(_session, _backend),
    do:
      {:error,
       %{
         reason: :invalid_session,
         hint: "session must be new or a returned handle, and is only supported by Playwright"
       }}

  defp validate_action_timeout(nil), do: :ok
  defp validate_action_timeout(timeout) when is_integer(timeout) and timeout in 1..120_000, do: :ok

  defp validate_action_timeout(_),
    do: {:error, %{reason: :invalid_action_timeout, hint: "action_timeout must be an integer from 1 to 120000 ms"}}

  defp validate_idle_timeout(nil), do: :ok
  defp validate_idle_timeout(timeout) when is_integer(timeout) and timeout in 10_000..1_800_000, do: :ok

  defp validate_idle_timeout(_),
    do:
      {:error,
       %{
         reason: :invalid_idle_timeout,
         hint: "idle_timeout must be an integer from 10000 to 1800000 ms and is only set when opening a session"
       }}

  defp invoke(%{"session" => session} = request, _json) when is_binary(session) do
    token =
      case Process.get({Newbee.Tools.Hive, :context}) do
        %{capability: capability} -> capability
        _ -> Process.get({Newbee.Tools.Media, :capability})
      end

    case Newbee.Host.call(Newbee.Browser, :run, [token, File.cwd!(), request], request["timeout"] + 5_000) do
      {:ok, payload} -> decode_result(%{exit: 0, output: Jason.encode!(payload)})
      {:error, _} = error -> error
      other -> {:error, %{reason: :session_lost, hint: "browser session call failed: " <> inspect(other)}}
    end
  end

  defp invoke(request, json) do
    timeout = request["timeout"]
    runner = Path.join(File.cwd!(), @runner_path)

    cond do
      not File.regular?(runner) ->
        {:error, %{reason: :runtime_missing, hint: "browser runner is missing: #{runner}"}}

      is_nil(python_executable()) ->
        {:error, %{reason: :runtime_missing, hint: "python3 is not available for the browser runner"}}

      true ->
        encoded = Base.encode64(json)

        command =
          [python_executable(), runner, encoded]
          |> Enum.map(&shell_quote/1)
          |> Enum.join(" ")

        result =
          Newbee.Tools.Run.sh(command, timeout: min(timeout + 5_000, @max_timeout + 5_000), shared_terminal: false)

        decode_result(result)
    end
  end

  defp python_executable do
    cond do
      executable_file?("/usr/bin/python3") -> "/usr/bin/python3"
      is_binary(System.find_executable("python3")) -> System.find_executable("python3")
      true -> nil
    end
  end

  defp executable_file?(path) do
    case File.stat(path) do
      {:ok, %File.Stat{mode: mode}} -> Bitwise.band(mode, 0o111) != 0
      _ -> false
    end
  end

  defp shell_quote(value) do
    replacement = "'" <> "\"" <> "'" <> "\"" <> "'"
    "'" <> String.replace(to_string(value), "'", replacement) <> "'"
  end

  defp decode_result(%{exit: :timeout} = result) do
    {:error, %{reason: :runner_timeout, hint: "browser runner timed out", output: result.output}}
  end

  defp decode_result(%{exit: :denied} = result) do
    {:error, %{reason: :runner_denied, hint: result.output}}
  end

  defp decode_result(%{exit: exit, output: output}) do
    case last_json(output) do
      {:ok, %{"ok" => true, "result" => result}} ->
        {:ok, result}

      {:ok, %{"ok" => false, "error" => error}} when is_map(error) ->
        {:error,
         %{
           reason: :browser_error,
           code: Map.get(error, "code", "runner_failed"),
           hint: Map.get(error, "message", "browser runner failed"),
           details: Map.drop(error, ["code", "message"])
         }}

      _ ->
        {:error,
         %{
           reason: :runner_failed,
           hint: "browser runner exited with #{inspect(exit)}",
           output: String.slice(output, 0, 8_000)
         }}
    end
  end

  defp last_json(output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.reverse()
    |> Enum.find_value(fn line ->
      case Jason.decode(line) do
        {:ok, value} -> {:ok, value}
        _ -> nil
      end
    end)
    |> case do
      nil -> :error
      result -> result
    end
  end
end
