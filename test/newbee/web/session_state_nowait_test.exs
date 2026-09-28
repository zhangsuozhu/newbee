defmodule Newbee.Web.SessionStateNowaitTest do
  use ExUnit.Case, async: false

  # 回归：session.state 轮询里不许再做同步网络探测。
  # 现场证据：GET openrouter /models 实测 7.3-8.7s，而 GenServer.call(:state, 5000) 只给 5s，
  # 每次 VM 冷启首屏必超时一次（[error] rpc session.state exit ... Sent 200 in 5063ms）。

  alias Newbee.LLM.Client

  defp uncached_client(tag) do
    Client.new(
      provider: "stub-" <> tag,
      model: "model-" <> tag,
      api_key: "test",
      base_url: "http://127.0.0.1:1/" <> tag
    )
  end

  test "context_window_nowait 未命中缓存时立刻返回 nil，不阻塞调用方" do
    client = uncached_client("nowait#{System.unique_integer([:positive])}")

    t0 = System.monotonic_time(:millisecond)
    assert Client.context_window_nowait(client) == nil
    assert System.monotonic_time(:millisecond) - t0 < 500
  end

  test "context_window_nowait 显式配置直接返回" do
    client = Client.new(model: "m", api_key: "t", base_url: "http://127.0.0.1:1/x", context_window: 123_456)
    assert Client.context_window_nowait(client) == 123_456
  end

  test "context_window 同步语义保持：拿不到就回退默认整数窗口" do
    client = uncached_client("sync#{System.unique_integer([:positive])}")
    n = Client.context_window(client)
    assert is_integer(n) and n > 0
  end

  test "handle_call(:state) 在窗口未缓存时毫秒级返回，且 context_window 为 nil" do
    sid = "test_state_nowait_#{System.unique_integer([:positive])}"
    client = uncached_client("st#{System.unique_integer([:positive])}")

    st = %Newbee.Web.Session{
      sid: sid,
      kernel: nil,
      client: client,
      busy: false,
      booting: false,
      queue: :queue.new()
    }

    t0 = System.monotonic_time(:millisecond)
    assert {:reply, state, ^st} = Newbee.Web.Session.handle_call(:state, {self(), make_ref()}, st)
    took = System.monotonic_time(:millisecond) - t0

    assert state.context_window == nil
    assert took < 1000, "session.state 不应等待网络探测，实测 #{took}ms"

    t1 = System.monotonic_time(:millisecond)
    assert {:reply, _, ^st} = Newbee.Web.Session.handle_call(:state, {self(), make_ref()}, st)
    assert System.monotonic_time(:millisecond) - t1 < 1000
  end
end
