defmodule Newbee.Plugins.Provider.OpenRouter do
  @moduledoc """
  无凭证 OpenRouter 请求计划器：验证参数并生成 Host 可执行的请求 map；不读 env、不持 key。

  ## 函数清单
  - `plan(model, messages, opts \\\\ []) :: {:ok, map()} | {:error, reason}` — `opts` 支持 `base_url:`、`tools:`、`stream:`、`receive_timeout:`。

  ## 可跑示例
      {:ok, plan} = Newbee.Plugins.Provider.OpenRouter.plan("openai/gpt-4o-mini", [%{role: "user", content: "hi"}])
      {:ok, plan} = Newbee.Plugins.Provider.OpenRouter.plan("anthropic/claude-3", messages, tools: tools, stream: false)

  返回计划交给 `Newbee.Host.Shell.execute_request_plan/1` 执行；凭证只通过 `credential_env` 由 Host 注入。
  """

  @default_base_url "https://openrouter.ai/api/v1"

  @doc "验证模型、消息与选项后生成 OpenRouter chat/completions 请求计划。"
  @spec plan(String.t(), [map()], keyword()) :: {:ok, map()} | {:error, term()}
  def plan(model, messages, opts \\ [])

  def plan(model, messages, opts) when is_binary(model) and is_list(messages) and is_list(opts) do
    with :ok <- validate_model(model),
         :ok <- validate_messages(messages),
         {:ok, base_url} <- fetch_binary_opt(opts, :base_url, @default_base_url),
         {:ok, tools} <- fetch_list_opt(opts, :tools, Newbee.Codec.tools()),
         {:ok, stream} <- fetch_boolean_opt(opts, :stream, true),
         {:ok, timeout} <- fetch_positive_integer_opt(opts, :receive_timeout, 120_000) do
      body = %{model: model, messages: messages, tools: tools, stream: stream}
      body = if stream, do: Map.put(body, :stream_options, %{include_usage: true}), else: body

      {:ok,
       %{
         method: :post,
         url: String.trim_trailing(base_url, "/") <> "/chat/completions",
         headers: %{"content-type" => "application/json"},
         json: body,
         credential_env: "OPENROUTER_API_KEY",
         stream: stream,
         receive_timeout: timeout
       }}
    end
  end

  def plan(_model, _messages, _opts), do: {:error, :invalid_arguments}

  defp validate_model(model) do
    if Regex.match?(~r/^[^\s\/]+\/[^\s\/]+$/, model), do: :ok, else: {:error, :invalid_model_id}
  end

  defp validate_messages(messages) do
    if Enum.all?(messages, &valid_message?/1), do: :ok, else: {:error, :invalid_messages}
  end

  defp valid_message?(message) when is_map(message) do
    role = Map.get(message, :role) || Map.get(message, "role")
    content = Map.get(message, :content) || Map.get(message, "content")
    is_binary(role) and (is_binary(content) or is_list(content))
  end

  defp valid_message?(_), do: false

  defp fetch_binary_opt(opts, key, default) do
    case Keyword.get(opts, key, default) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, {:invalid_option, key}}
    end
  end

  defp fetch_list_opt(opts, key, default) do
    case Keyword.get(opts, key, default) do
      value when is_list(value) -> {:ok, value}
      _ -> {:error, {:invalid_option, key}}
    end
  end

  defp fetch_boolean_opt(opts, key, default) do
    case Keyword.get(opts, key, default) do
      value when is_boolean(value) -> {:ok, value}
      _ -> {:error, {:invalid_option, key}}
    end
  end

  defp fetch_positive_integer_opt(opts, key, default) do
    case Keyword.get(opts, key, default) do
      value when is_integer(value) and value > 0 -> {:ok, value}
      _ -> {:error, {:invalid_option, key}}
    end
  end
end
