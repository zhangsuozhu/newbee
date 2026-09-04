defmodule Newbee.Plugins.Provider.OpenRouter do
  @moduledoc """
  OpenRouter planner: validated Host-executable request maps; holds no keys.

  ## Functions
  - `plan(model, messages, opts \\\\ []) :: {:ok, map()} | {:error, reason}` — `opts` takes `base_url:`, `tools:`, `stream:`, `receive_timeout:`.

  ## Runnable example
      {:ok, plan} = Newbee.Plugins.Provider.OpenRouter.plan("openai/gpt-4o-mini", [%{role: "user", content: "hi"}])
      {:ok, plan} = Newbee.Plugins.Provider.OpenRouter.plan("anthropic/claude-3", messages, tools: tools, stream: false)

  Hand the returned plan to `Newbee.Host.Shell.execute_request_plan/1`; credentials enter only via `credential_env`, injected by the Host.
  """

  @default_base_url "https://openrouter.ai/api/v1"
  @doc "Validate model, messages, and options, then build an OpenRouter chat/completions request plan."
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
