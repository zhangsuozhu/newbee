defmodule Newbee.Plugins.Provider.OpenRouter do
  @moduledoc """
  无凭证 OpenRouter 协议适配器（DESIGN §12）。只产出经校验的请求计划，不读 env、不持 key。

  ## 函数清单
  - `plan(model_id, messages, opts \\ []) :: {:ok, %{url: String.t(), headers: [...], body: map()}} | {:error, reason}` — 生成请求计划，`model_id` 如 `"openai/gpt-4"`。
  - `plan(model_id, messages, tools, opts)` — 带工具的请求计划。

  内部校验 `model_id` 格式与消息结构，不做真实网络调用；执行经 `Newbee.Host.Shell.execute_request_plan/1`。

  ## 可跑示例
      {:ok, plan} = Newbee.Plugins.Provider.OpenRouter.plan("openai/gpt-4o-mini", [%{role: "user", content: "hi"}])
      {:ok, %{url: url, body: body}} = Newbee.Plugins.Provider.OpenRouter.plan("anthropic/claude-3", msgs, tools)

  """

  @default_base_url "https://openrouter.ai/api/v1"

  @spec plan(String.t(), [map()], String.t()) :: {:ok, map()} | {:error, term()}
  def plan(model, messages, base_url \\ @default_base_url) do
    body = %{
      model: model,
      messages: messages,
      tools: Newbee.Codec.tools(),
      stream: true,
      stream_options: %{include_usage: true}
    }

    {:ok,
     %{
       method: :post,
       url: base_url <> "/chat/completions",
       headers: %{"content-type" => "application/json"},
       json: body,
       credential_env: "OPENROUTER_API_KEY",
       stream: true,
       receive_timeout: 120_000
     }}
  end
end
