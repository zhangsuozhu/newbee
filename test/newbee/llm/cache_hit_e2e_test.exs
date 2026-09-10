defmodule Newbee.LLM.CacheHitE2ETest do
  @moduledoc """
  真 provider 上的前缀缓存命中验证（F）。

  形状单测只能证明"我们发了什么"，证明不了"provider 认了这个前缀"。这里对真实端点
  断言 `cache_read_tokens > 0`，把已上线的缓存链路（请求投影 → envelope 快照 →
  摘要回放）从"看起来对"变成"测过对"。

  默认跳过；需要真实凭据与端点时显式打开：

      NEWBEE_CACHE_E2E=1 mix test test/newbee/llm/cache_hit_e2e_test.exs

  读的是与运行时同一份配置（$NEWBEE_MODEL_JSON → ./model.json → ~/.newbee/model.json），
  因而验证的是真实路由，不是测试专用 stub。
  """
  use ExUnit.Case, async: false

  alias Newbee.LLM.Client

  @moduletag :cache_e2e

  @moduletag skip: System.get_env("NEWBEE_CACHE_E2E") != "1"

  # 前缀要足够长才会进入 provider 的缓存阈值（OpenAI 系 1024 token 起）。
  @padding_repeat 220

  setup_all do
    case client() do
      {:ok, client} ->
        {:ok, client: client}

      {:error, reason} ->
        {:skip, "无法构建真实 client（#{inspect(reason)}）：配置 model.json 或导出密钥后重试"}
    end
  end

  test "同一请求重复发送：第二次报告 cache_read_tokens > 0", %{client: client} do
    messages = base_messages()

    u1 = usage!(client, messages, :first)
    u2 = usage!(client, messages, :second)

    prompt = u2["prompt_tokens"] || 0

    assert prompt > 0, "provider 未报告 prompt_tokens：#{inspect(u2)}"

    assert u2["cache_read_tokens"] > 0,
           """
           第二次相同请求未命中前缀缓存（cache_read_tokens=0）。
           usage(first)=#{inspect(u1)}
           usage(second)=#{inspect(u2)}
           前缀约 #{prompt} prompt token。若 provider 不支持前缀缓存或路由漂移，
           这条断言会失败——这正是它要暴露的事实。
           """
  end

  test "前缀扩展：同前缀 + 追加一轮，仍命中缓存", %{client: client} do
    messages = base_messages()

    _ = usage!(client, messages, :first)

    extended =
      messages ++
        [
          %{"role" => "assistant", "content" => "好的。"},
          %{"role" => "user", "content" => "再确认一次：只回复 OK。"}
        ]

    u2 = usage!(client, extended, :extended)

    assert u2["cache_read_tokens"] > 0,
           """
           前缀扩展请求未命中缓存（cache_read_tokens=0）。
           usage(extended)=#{inspect(u2)}
           这是 agent loop 的真实形态：历史只追加、前缀不变。
           """
  end

  describe "envelope 摘要回放路径" do
    test "回放上次请求的严格前缀 + 指令：命中缓存", %{client: client} do
      messages = base_messages()
      tools = Newbee.Codec.tools()

      # ① 路由请求（与 loop 同形：带 tools 的流式请求）
      {:ok, _message, routed_usage} =
        Client.stream_chat(client, messages, fn _ -> :ok end, fn _ -> :ok end, tools: tools)

      assert (routed_usage["prompt_tokens"] || 0) > 0,
             "路由请求未报告 prompt_tokens：#{inspect(routed_usage)}"

      # ② 记下"真正发出去的那份"快照
      session = tmp_session()

      :ok = Newbee.RequestEnvelope.record(session, client, messages, tools)

      env = Newbee.RequestEnvelope.load(session)
      assert is_map(env)
      assert Newbee.RequestEnvelope.hit_eligible?(env, client), "快照与当前 route 不一致，回放路径不会被选中"

      # ③ 摘要回放请求 = 快照严格前缀 + 尾部指令，tools 同源
      replay = env["messages"] ++ [%{"role" => "user", "content" => compact_instruction()}]

      # complete/3 的第三元素是 %{usage, logprobs}（与 chat 路径同契约）；
      # stream_chat 返回的是裸 usage map——两条路径形状不同，别混用。
      {:ok, _content, %{usage: replay_usage}} =
        Client.complete(client, replay, tools: tools, tool_choice: "none", extra: %{max_tokens: 64})

      hit = replay_usage["cache_read_tokens"] || 0
      prompt = replay_usage["prompt_tokens"] || 0

      assert prompt > 0, "回放请求未报告 prompt_tokens：#{inspect(replay_usage)}"

      assert hit > 0,
             """
             摘要回放未命中缓存（cache_read_tokens=0）——前缀缓存优化没有真正生效。
             routed usage=#{inspect(routed_usage)}
             replay usage=#{inspect(replay_usage)}
             """
    end
  end

  # ── helpers ──

  # complete/3 返回 `{:ok, content, %{usage:, logprobs:}}`；这里统一解包成 usage map，
  # 同时把形状不符合契约的情况当成失败报出来（而不是安静地拿到一个空 map）。
  defp usage!(client, messages, label) do
    case Client.complete(client, messages, tools: [], extra: %{max_tokens: 16}) do
      {:ok, _content, %{usage: usage}} when is_map(usage) ->
        usage

      {:ok, _content, other} ->
        flunk("#{label}: complete/3 第三元素不是 %{usage: _}：#{inspect(other)}")

      other ->
        flunk("#{label}: 请求失败 #{inspect(other)}")
    end
  end

  defp base_messages do
    [
      %{"role" => "system", "content" => system_prompt()},
      %{"role" => "user", "content" => "这是一次缓存命中验证。只回复 OK。"}
    ]
  end

  defp system_prompt do
    "你是缓存命中验证用的助手。以下是与本验证无关的固定背景，逐字重复两次请求以求前缀稳定。\n" <>
      String.duplicate("稳定前缀填充：缓存命中要求这段文字逐字节不变。\n", @padding_repeat)
  end

  defp compact_instruction do
    "以上是一次编程 agent 会话。用 ≤100 字中文写要点摘要：任务目标、关键决策、未完成事项。只输出摘要正文。"
  end

  defp tmp_session do
    dir =
      Path.join(
        System.tmp_dir!(),
        "newbee-cache-e2e-#{System.system_time(:native)}_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    %Newbee.Session{id: "cache-e2e", dir: dir}
  end

  defp client do
    try do
      client = Newbee.LLM.Config.client_for("default")

      if is_binary(client.api_key) and client.api_key != "" and is_binary(client.base_url) do
        {:ok, %{client | cache_key: "newbee-cache-e2e"}}
      else
        {:error, :missing_credential}
      end
    rescue
      e -> {:error, e}
    end
  end
end
