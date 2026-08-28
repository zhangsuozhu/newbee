defmodule Newbee.Plugins.Provider.OpenRouterTest do
  use ExUnit.Case, async: true

  alias Newbee.Plugins.Provider.OpenRouter

  @messages [%{role: "user", content: "hi"}]

  test "默认计划使用 Codec 工具且不携带凭证" do
    assert {:ok, plan} = OpenRouter.plan("test/model", @messages)
    assert plan.json.tools == Newbee.Codec.tools()
    assert plan.json.stream
    assert plan.credential_env == "OPENROUTER_API_KEY"
    refute Map.has_key?(plan, :api_key)
  end

  test "opts 可覆盖 tools/base_url/stream/timeout" do
    tools = [%{type: "function", function: %{name: "x"}}]

    assert {:ok, plan} =
             OpenRouter.plan("vendor/model", @messages,
               tools: tools,
               base_url: "https://proxy.example/v1/",
               stream: false,
               receive_timeout: 5_000
             )

    assert plan.url == "https://proxy.example/v1/chat/completions"
    assert plan.json.tools == tools
    refute plan.json.stream
    refute Map.has_key?(plan.json, :stream_options)
    assert plan.receive_timeout == 5_000
  end

  test "非法参数返回结构化错误" do
    assert {:error, :invalid_model_id} = OpenRouter.plan("bad", @messages)
    assert {:error, :invalid_messages} = OpenRouter.plan("a/b", [%{role: "user"}])
    assert {:error, {:invalid_option, :tools}} = OpenRouter.plan("a/b", @messages, tools: :bad)
    assert {:error, :invalid_arguments} = OpenRouter.plan("a/b", @messages, %{})
  end
end
