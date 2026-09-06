defmodule Newbee.Tools.Browser do
  @behaviour Newbee.Environment.PluginContract

  @moduledoc """
  Browser automation: isolated Playwright + optional X11 visible window.

  The default backend is an isolated browser; the existing desktop window is focused and driven only when the user
  explicitly passes `backend: \"screen\"`. Actions run inside one ordered plan so the browser isn't relaunched per click.
  Output files stay in the project dir, `~/.newbee`, or `/tmp`.

  ## Runnable example
      {:ok, result} = Newbee.Tools.Browser.run(%{
        url: \"https://example.com\",
        actions: [
          %{action: \"snapshot\"},
          %{action: \"screenshot\", path: \"/tmp/example.png\", full_page: true}
        ]
      })

      {:ok, _result} = Newbee.Tools.Browser.run(%{
        backend: \"screen\",
        window_title: \"Google Chrome\",
        actions: [%{action: \"screenshot\", path: \"/tmp/chrome.png\"}]
      })

  ## Playwright 动作
  `goto/navigate`、`reload`、`back`、`forward`、`click`、`fill`、`type`、`press`、`select`、
  `check/uncheck`、`hover`、`focus`、`scroll`、`wait`、`evaluate`、`set_content`、`set_viewport`、
  `title`、`url`、`snapshot`、`text/html/value/attribute/count/visible/enabled/bounds`、`links`、
  `select_text`、`drag_and_drop`、`bring_to_front`、`screenshot`、`pdf`、
  `new_tab/switch_tab/close_tab/tabs`、`cookies/set_cookie/clear_cookies`、`storage`、
  ## Playwright actions
  `goto/navigate`, `reload`, `back`, `forward`, `click`, `fill`, `type`, `press`, `select`,
  `check/uncheck`, `hover`, `focus`, `scroll`, `wait`, `evaluate`, `set_content`, `set_viewport`,
  `title`, `url`, `snapshot`, `text/html/value/attribute/count/visible/enabled/bounds`, `links`,
  `select_text`, `drag_and_drop`, `bring_to_front`, `screenshot`, `pdf`,
  `new_tab/switch_tab/close_tab/tabs`, `cookies/set_cookie/clear_cookies`, `storage`,
  `headers`, `permissions`, `download`, `upload`, `browser_version` and `close`.
  Locators span CSS, XPath, id, text, role, label, placeholder, alt, title, test_id, and iframes.
  The isolated backend needs Python Playwright plus matching browsers; when Chromium is missing, run `playwright install chromium`.

  ## Screen actions
  `list_windows`, `focus`, `navigate`, coordinate `click`/`double_click`, `scroll`, `press`, ASCII `type`, `wait` and `screenshot`.
  The screen backend drives the real desktop — use only when the user has authorized control of the currently visible browser.

  """

  @runner_path "priv/browser/playwright_runner.py"
  @max_request_bytes 256 * 1024
  @default_timeout 30_000
  @max_timeout 120_000

  @doc false
  def id, do: "tool.browser"

  @doc false
  def version, do: "1.0.0"

  @doc false
  def dependencies, do: []

  @doc false
  def describe do
    %{
      kind: :tool,
      summary: "Drive an isolated or visible browser: page interaction, DOM queries, downloads, PDFs, screenshots",
      when_to_use: "When you need a real browser render, page interaction, login state, downloads, PDFs, screenshots, or explicitly authorized visible-Chrome control",
      avoid_when: "For plain public HTTP content use Newbee.read/1 or Newbee.Tools.Http; never use the screen backend unauthorized",
      capabilities: [:browser, :net, :fs, :shell],
      effects: [:process, :external, :fs],
      state_policy: :stateless,
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

  @doc "Run one ordered browser-action plan. Takes a URL or a map with `url`, `backend`, `actions`, `timeout`, `profile`, `viewport`, `storage_state`, and `save_storage`. Returns `{:ok, result}` with action results and produced file paths, else `{:error, reason}`."
  def run(url) when is_binary(url), do: run(%{url: url})

  def run(request) when is_map(request) do
    with {:ok, request} <- normalize_request(request),
         {:ok, json} <- encode_request(request),
         :ok <- validate_request_size(json),
         {:ok, result} <- invoke(json, request["timeout"]) do
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
         {:ok, timeout} <- normalize_timeout(timeout) do
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

  defp invoke(json, timeout) do
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

        result = Newbee.Tools.Run.sh(command, timeout: min(timeout + 5_000, @max_timeout + 5_000))
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
