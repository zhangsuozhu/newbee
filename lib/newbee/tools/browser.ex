defmodule Newbee.Tools.Browser do
  @behaviour Newbee.Environment.PluginContract

  @moduledoc """
  浏览器自动化：隔离 Playwright + 可选 X11 可见窗口。

  默认后端是隔离浏览器；只有用户明确传 `backend: \"screen\"` 时才会聚焦和操作现有桌面窗口。
  动作在一次有序计划中执行，避免每个点击都重新启动浏览器。输出文件限制在工程目录、`~/.newbee` 或 `/tmp`。

  ## 可跑示例
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
  `headers`、`permissions`、`download`、`upload`、`browser_version` 和 `close`。
  定位支持 CSS、XPath、id、text、role、label、placeholder、alt、title、test_id 以及 iframe。
  隔离后端需要 Python Playwright 和对应浏览器；缺少 Chromium 时运行 `playwright install chromium`。

  ## Screen 动作
  `list_windows`、`focus`、`navigate`、坐标 `click`/`double_click`、`scroll`、`press`、ASCII `type`、`wait` 和 `screenshot`。
  screen 后端直接影响桌面，只在用户已授权控制当前可见浏览器时使用。

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
      summary: "操作隔离或可见浏览器，支持页面交互、DOM 查询、下载、PDF 和截图",
      when_to_use: "需要真实浏览器渲染、页面交互、登录态、下载、PDF、截图或明确授权的可见 Chrome 控制时",
      avoid_when: "只需要公开 HTTP 内容时用 Newbee.read/1 或 Newbee.Tools.Http；不要未经授权使用 screen 后端",
      capabilities: [:browser, :net, :fs, :shell],
      effects: [:process, :external, :fs],
      state_policy: :stateless,
      error_contract: %{recoverable: :error_tuple, unexpected: :raise},
      api: [
        %{
          name: :run,
          arity: 1,
          returns: "{:ok, result} | {:error, %{reason: atom(), hint: String.t(), ...}}",
          errors: "请求、运行时、超时、定位和页面错误均作为可恢复值返回"
        }
      ],
      examples: [
        "Newbee.Tools.Browser.run(%{url: url, actions: [%{action: \"screenshot\"}]})",
        "Newbee.Tools.Browser.run(%{backend: \"screen\", actions: [%{action: \"screenshot\"}]})"
      ]
    }
  end

  @doc "执行一个有序浏览器动作计划。输入可为 URL 字符串，或包含 `url`、`backend`、`actions`、`timeout`、`profile`、`viewport`、`storage_state` 和 `save_storage` 的 map。返回动作结果和生成文件路径。"
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
