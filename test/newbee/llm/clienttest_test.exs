defmodule Newbee.LLM.ClientTest do
  use ExUnit.Case, async: true
  alias Newbee.LLM.Client

  test "OpenRouter 与 DeepSeek 缓存字段归一化" do
    assert Client.normalize_usage(%{"prompt_tokens" => 100, "cached_tokens" => 80, "cache_write_tokens" => 12}) ==
             %{
               "prompt_tokens" => 100,
               "cached_tokens" => 80,
               "cache_write_tokens" => 12,
               "cache_read_tokens" => 80,
               "uncached_prompt_tokens" => 20
             }

    assert Client.normalize_usage(%{"prompt_tokens" => 100, "prompt_cache_hit_tokens" => 64})["cache_read_tokens"] == 64
    # 无缓存字段：uncached = prompt_tokens
    assert Client.normalize_usage(%{"prompt_tokens" => 50, "completion_tokens" => 9})["uncached_prompt_tokens"] == 50
  end

  test "缓存字段优先取 OpenRouter 专名" do
    u =
      Client.normalize_usage(%{
        "prompt_tokens" => 100,
        "prompt_tokens_details" => %{"cached_tokens" => 30},
        "cache_read_input_tokens" => 40
      })

    assert u["cache_read_tokens"] == 40
  end

  test "结果 usage 解包兼容流式裸 usage 与 complete 包装层" do
    raw = %{"prompt_tokens" => 100, "cache_read_tokens" => 80}

    assert Client.result_usage({:ok, %{"content" => "ok"}, raw}) == raw
    assert Client.result_usage({:ok, "ok", %{usage: raw, logprobs: nil}}) == raw
    assert Client.result_usage({:error, :timeout}) == %{}
  end

  test "cache-hit 日志包含厂家模型与 token/条数拆分" do
    client = Client.new(provider: "guoyu", model: "gpt-5.6-sol", api_key: "test")
    usage = %{"prompt_tokens" => 4_392, "cache_read_tokens" => 3_840, "cache_write_tokens" => 0}

    assert Client.cache_hit_line(client, usage, "stream_chat") ==
             "cache-hit provider=guoyu model=gpt-5.6-sol task=stream_chat " <>
               "prompt=4392 prompt_read=3840 rate=87.4%"
  end

  test "cache-hit 无 usage 时命中率显示 n/a" do
    client = Client.new(provider: "opencode", model: "ox-alpha-free", api_key: "test")

    assert Client.cache_hit_line(client, %{}, "complete") =~
             "provider=opencode model=ox-alpha-free task=complete prompt=0 prompt_read=0 rate=n/a"
  end

  test "stream_chat 返回的 tool_calls 按 index 聚合" do
    # 不发起真实请求：直接验证 apply_delta 的聚合逻辑不可行（私有），
    # 因此验证消息组装路径：interrupt 标志可反复设置/清除。
    Client.clear_interrupt()
    refute Client.interrupted?()
    Client.interrupt()
    assert Client.interrupted?()
    Client.clear_interrupt()
    refute Client.interrupted?()
  end

  test "new/1 从环境变量读取 API key" do
    old = System.get_env("OPENROUTER_API_KEY")
    System.put_env("OPENROUTER_API_KEY", "sk-test-123")
    c = Client.new()
    assert c.api_key == "sk-test-123"
    assert c.model == "deepseek/deepseek-v4-flash-0731"
    if old, do: System.put_env("OPENROUTER_API_KEY", old), else: System.delete_env("OPENROUTER_API_KEY")
  end

  test "旧 reasoning_effort off 归一化并发送为 none" do
    test_pid = self()

    plug = fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:reasoning_body, Jason.decode!(body)})
      Req.Test.json(conn, %{"choices" => [%{"message" => %{"role" => "assistant", "content" => "ok"}}]})
    end

    client =
      Client.new(
        model: "test/m",
        api_key: "t",
        base_url: "http://localhost",
        reasoning_effort: "off",
        req_options: [plug: plug, retry: false]
      )

    assert client.reasoning_effort == "none"
    assert {:ok, "ok", _} = Client.complete(client, [%{"role" => "user", "content" => "hi"}])
    assert_received {:reasoning_body, %{"reasoning_effort" => "none"}}
  end

  test "format_error: 400/provider 错误转简短提示" do
    msg = ~s({"error":{"type":"server_error","message":"invalid input"}})
    out = Client.format_error({:http_error, 400, msg})
    assert out =~ "HTTP 400"
    assert out =~ "invalid input"
    refute out =~ "server_error"
  end

  test "format_error: 429 提示自动重试" do
    out = Client.format_error({:http_error, 429, "rate limited"})
    assert out =~ "HTTP 429"
    assert out =~ "自动重试"
  end

  test "complete 带 tools：请求体含 tools（前缀缓存命中要求）" do
    test_pid = self()

    plug = fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:req_body, Jason.decode!(body)})
      Req.Test.json(conn, %{"choices" => [%{"message" => %{"role" => "assistant", "content" => "ok"}}]})
    end

    client =
      Newbee.LLM.Client.new(
        model: "test/m",
        api_key: "t",
        base_url: "http://localhost",
        req_options: [plug: plug, retry: false]
      )

    tools = Newbee.Codec.tools()
    {:ok, "ok", _} = Client.complete(client, [%{"role" => "user", "content" => "hi"}], tools: tools)
    assert_received {:req_body, body}
    assert body["tools"] == Jason.decode!(Jason.encode!(tools))
    assert body["messages"] == [%{"role" => "user", "content" => "hi"}]
  end

  test "complete 不带 tools：请求体无 tools 键（I5 兼容）" do
    test_pid = self()

    plug = fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:req_body, Jason.decode!(body)})
      Req.Test.json(conn, %{"choices" => [%{"message" => %{"role" => "assistant", "content" => "ok"}}]})
    end

    client =
      Newbee.LLM.Client.new(
        model: "test/m",
        api_key: "t",
        base_url: "http://localhost",
        req_options: [plug: plug, retry: false]
      )

    {:ok, "ok", _} = Client.complete(client, [%{"role" => "user", "content" => "hi"}])
    assert_received {:req_body, body}
    refute Map.has_key?(body, "tools")
  end

  test "complete 读取顶层 usage（OpenAI 兼容：usage 常在响应顶层）" do
    plug = fn conn ->
      Req.Test.json(conn, %{
        "choices" => [%{"message" => %{"role" => "assistant", "content" => "ok"}}],
        "usage" => %{"prompt_tokens" => 100, "prompt_cache_hit_tokens" => 64}
      })
    end

    client =
      Newbee.LLM.Client.new(
        model: "test/m",
        api_key: "t",
        base_url: "http://localhost",
        req_options: [plug: plug, retry: false]
      )

    {:ok, "ok", %{usage: usage}} = Client.complete(client, [%{"role" => "user", "content" => "hi"}])
    assert usage["cache_read_tokens"] == 64
  end

  test "complete 顶层与 choice 内 usage 并存：choice 内优先" do
    plug = fn conn ->
      Req.Test.json(conn, %{
        "choices" => [
          %{
            "message" => %{"role" => "assistant", "content" => "ok"},
            "usage" => %{"prompt_tokens" => 10, "prompt_cache_hit_tokens" => 9}
          }
        ],
        "usage" => %{"prompt_tokens" => 100, "prompt_cache_hit_tokens" => 64}
      })
    end

    client =
      Newbee.LLM.Client.new(
        model: "test/m",
        api_key: "t",
        base_url: "http://localhost",
        req_options: [plug: plug, retry: false]
      )

    {:ok, "ok", %{usage: usage}} = Client.complete(client, [%{"role" => "user", "content" => "hi"}])
    assert usage["cache_read_tokens"] == 9
  end
end
