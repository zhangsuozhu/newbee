defmodule Newbee.LLM.AnthropicTest do
  use ExUnit.Case, async: true

  alias Newbee.LLM.{Anthropic, Client}

  setup do
    Client.clear_interrupt()
    :ok
  end

  test "normalizes Anthropic protocol modes" do
    assert Client.new(api: "anthropic", api_key: "test").responses_mode == :anthropic
    assert Client.new(api: "anthropic-messages", api_key: "test").responses_mode == :anthropic
  end

  test "converts system, assistant tool calls, and tool results" do
    messages = [
      %{"role" => "system", "content" => "You are concise."},
      %{"role" => "user", "content" => "Run it."},
      %{
        "role" => "assistant",
        "content" => "",
        "tool_calls" => [
          %{
            "id" => "call-1",
            "type" => "function",
            "function" => %{
              "name" => "run_elixir",
              "arguments" => ~s({"code":"1 + 1"})
            }
          }
        ]
      },
      %{"role" => "tool", "tool_call_id" => "call-1", "content" => "2"}
    ]

    assert {"You are concise.", [user, assistant, tool_result]} = Anthropic.to_wire_messages(messages)
    assert user == %{"role" => "user", "content" => [%{"type" => "text", "text" => "Run it."}]}

    assert assistant == %{
             "role" => "assistant",
             "content" => [
               %{
                 "type" => "tool_use",
                 "id" => "call-1",
                 "name" => "run_elixir",
                 "input" => %{"code" => "1 + 1"}
               }
             ]
           }

    assert tool_result == %{
             "role" => "user",
             "content" => [
               %{"type" => "tool_result", "tool_use_id" => "call-1", "content" => "2"}
             ]
           }
  end

  test "complete posts Anthropic Messages request and restores response" do
    test_pid = self()

    plug = fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)

      send(test_pid, {
        :request,
        conn.request_path,
        Jason.decode!(raw),
        Plug.Conn.get_req_header(conn, "x-api-key"),
        Plug.Conn.get_req_header(conn, "anthropic-version"),
        Plug.Conn.get_req_header(conn, "x-opencode-session")
      })

      Req.Test.json(conn, %{
        "id" => "msg-1",
        "type" => "message",
        "role" => "assistant",
        "content" => [
          %{"type" => "text", "text" => "done"},
          %{"type" => "tool_use", "id" => "call-1", "name" => "run_elixir", "input" => %{"code" => "1 + 1"}}
        ],
        "usage" => %{"input_tokens" => 4, "output_tokens" => 3}
      })
    end

    client =
      Client.new(
        provider: "opencode",
        api: "anthropic",
        model: "union-alpha",
        api_key: "test-key",
        base_url: "http://localhost",
        session_id: "session-1",
        req_options: [plug: plug, retry: false]
      )

    assert {:ok, "done", %{usage: usage, logprobs: nil}} =
             Client.complete(client, [%{"role" => "user", "content" => "hi"}], max_tokens: 128)

    assert_received {:request, "/messages", body, ["test-key"], ["2023-06-01"], ["session-1"]}
    assert body["model"] == "union-alpha"
    assert body["max_tokens"] == 128
    assert body["stream"] == false
    assert usage["prompt_tokens"] == 4
    assert usage["completion_tokens"] == 3
  end

  test "stream_chat consumes Anthropic SSE text and tool calls" do
    test_pid = self()

    plug = fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:stream_request, conn.request_path, Jason.decode!(raw)})

      events =
        [
          %{
            "type" => "message_start",
            "message" => %{"id" => "msg-stream", "usage" => %{"input_tokens" => 5}}
          },
          %{
            "type" => "content_block_start",
            "index" => 0,
            "content_block" => %{"type" => "text", "text" => ""}
          },
          %{
            "type" => "content_block_delta",
            "index" => 0,
            "delta" => %{"type" => "text_delta", "text" => "hel"}
          },
          %{
            "type" => "content_block_delta",
            "index" => 0,
            "delta" => %{"type" => "text_delta", "text" => "lo"}
          },
          %{
            "type" => "content_block_start",
            "index" => 1,
            "content_block" => %{"type" => "tool_use", "id" => "call-2", "name" => "run_elixir", "input" => %{}}
          },
          %{
            "type" => "content_block_delta",
            "index" => 1,
            "delta" => %{"type" => "input_json_delta", "partial_json" => ~s({"code":"1 + 1"})}
          },
          %{
            "type" => "message_delta",
            "delta" => %{"stop_reason" => "tool_use"},
            "usage" => %{"output_tokens" => 7}
          },
          %{"type" => "message_stop"}
        ]
        |> Enum.map_join(fn event -> "event: " <> event["type"] <> "\ndata: " <> Jason.encode!(event) <> "\n\n" end)

      conn =
        conn
        |> Plug.Conn.put_resp_header("content-type", "text/event-stream")
        |> Plug.Conn.send_chunked(200)

      {:ok, conn} = Plug.Conn.chunk(conn, events)
      conn
    end

    client =
      Client.new(
        provider: "opencode",
        api: "anthropic-messages",
        model: "union-alpha",
        api_key: "test-key",
        base_url: "http://localhost",
        session_id: "session-stream",
        req_options: [plug: plug, retry: false]
      )

    assert {:ok, message, usage} =
             Client.stream_chat(
               client,
               [%{"role" => "user", "content" => "hi"}],
               fn delta -> send(test_pid, {:text, delta}) end
             )

    assert_received {:stream_request, "/messages", body}
    assert body["stream"] == true
    assert_received {:text, "hel"}
    assert_received {:text, "lo"}
    assert message["content"] == "hello"

    assert message["tool_calls"] == [
             %{
               "id" => "call-2",
               "type" => "function",
               "function" => %{"name" => "run_elixir", "arguments" => ~s({"code":"1 + 1"})}
             }
           ]

    assert usage["prompt_tokens"] == 5
    assert usage["completion_tokens"] == 7
  end

  # ── 完成门禁：200 + 空流/截断流绝不能变成"成功的空回复" ──
  # 线上事故：网关抖动时返回 200 但流里没有任何可识别事件，适配器返回空 assistant，
  # 主循环把"无工具调用"当成收尾 → 用户看到"跑着跑着就停了"，且全程没有报错。

  test "200 + JSON 错误体（挂在 SSE content-type 下）：报上游错误，不当空回复" do
    plug = fn conn ->
      _ = Plug.Conn.read_body(conn)

      conn
      |> Plug.Conn.put_resp_content_type("text/event-stream")
      |> Plug.Conn.send_resp(
        200,
        ~s({"type":"error","error":{"type":"api_error","message":"Endpoint is unavailable."}})
      )
    end

    client = anthropic_client(plug)

    assert {:error, {:response_error, error, ""}} =
             Client.stream_chat(client, [%{"role" => "user", "content" => "hi"}], fn _ -> :ok end)

    assert error["message"] == "Endpoint is unavailable."
  end

  test "200 + 空 body：判空流错误，并按 @stream_retries 重发" do
    counter = start_supervised!({Agent, fn -> 0 end})

    plug = fn conn ->
      _ = Plug.Conn.read_body(conn)
      Agent.update(counter, &(&1 + 1))
      conn |> Plug.Conn.put_resp_content_type("text/event-stream") |> Plug.Conn.send_resp(200, "")
    end

    assert {:error, {:anthropic_stream_error, :empty_stream, ""}} =
             Client.stream_chat(
               anthropic_client(plug),
               [%{"role" => "user", "content" => "hi"}],
               fn _ -> :ok end
             )

    # 首次 + 2 次重发
    assert Agent.get(counter, & &1) == 3
  end

  test "流缺 message_stop：判截断错误，不当完整回答" do
    plug = fn conn ->
      _ = Plug.Conn.read_body(conn)

      events = [
        %{
          "type" => "message_start",
          "message" => %{"id" => "msg-cut", "usage" => %{"input_tokens" => 3}}
        },
        %{
          "type" => "content_block_delta",
          "index" => 0,
          "delta" => %{"type" => "text_delta", "text" => "半截"}
        }
      ]

      conn
      |> Plug.Conn.put_resp_content_type("text/event-stream")
      |> Plug.Conn.send_resp(200, sse_body(events))
    end

    assert {:error, {:anthropic_stream_error, :incomplete_stream, "半截"}} =
             Client.stream_chat(
               anthropic_client(plug),
               [%{"role" => "user", "content" => "hi"}],
               fn _ -> :ok end
             )
  end

  test "空流后重发成功：返回正常消息并提示用户" do
    test_pid = self()
    counter = start_supervised!({Agent, fn -> 0 end})

    plug = fn conn ->
      _ = Plug.Conn.read_body(conn)
      attempt = Agent.get_and_update(counter, fn n -> {n + 1, n + 1} end)

      events =
        if attempt == 1 do
          []
        else
          [
            %{
              "type" => "message_start",
              "message" => %{"id" => "msg-retry", "usage" => %{"input_tokens" => 4}}
            },
            %{
              "type" => "content_block_delta",
              "index" => 0,
              "delta" => %{"type" => "text_delta", "text" => "恢复了"}
            },
            %{
              "type" => "message_delta",
              "delta" => %{"stop_reason" => "end_turn"},
              "usage" => %{"output_tokens" => 3}
            },
            %{"type" => "message_stop"}
          ]
        end

      conn
      |> Plug.Conn.put_resp_content_type("text/event-stream")
      |> Plug.Conn.send_resp(200, sse_body(events))
    end

    assert {:ok, message, usage} =
             Client.stream_chat(
               anthropic_client(plug),
               [%{"role" => "user", "content" => "hi"}],
               fn delta -> send(test_pid, {:text, delta}) end,
               fn _ -> :ok end,
               on_retry: fn reason -> send(test_pid, {:retry, reason}) end
             )

    assert message["content"] == "恢复了"
    assert usage["completion_tokens"] == 3
    assert_received {:retry, reason}
    assert reason =~ "empty_stream"
    assert Agent.get(counter, & &1) == 2
  end

  test "stop_reason=max_tokens：标记截断，供主循环续跑" do
    plug = fn conn ->
      _ = Plug.Conn.read_body(conn)

      events = [
        %{
          "type" => "message_start",
          "message" => %{"id" => "msg-max", "usage" => %{"input_tokens" => 2}}
        },
        %{
          "type" => "content_block_delta",
          "index" => 0,
          "delta" => %{"type" => "text_delta", "text" => "写一半"}
        },
        %{
          "type" => "message_delta",
          "delta" => %{"stop_reason" => "max_tokens"},
          "usage" => %{"output_tokens" => 8_192}
        },
        %{"type" => "message_stop"}
      ]

      conn
      |> Plug.Conn.put_resp_content_type("text/event-stream")
      |> Plug.Conn.send_resp(200, sse_body(events))
    end

    assert {:ok, message, _usage} =
             Client.stream_chat(
               anthropic_client(plug),
               [%{"role" => "user", "content" => "hi"}],
               fn _ -> :ok end
             )

    assert message["content"] == "写一半"
    assert message["_stop_reason"] == "max_tokens"
  end

  defp anthropic_client(plug) do
    Client.new(
      provider: "opencode",
      api: "anthropic",
      model: "union-alpha",
      api_key: "test-key",
      base_url: "http://localhost",
      session_id: "session-gate",
      req_options: [plug: plug, retry: false]
    )
  end

  defp sse_body(events) do
    Enum.map_join(events, fn event ->
      "event: " <> event["type"] <> "\ndata: " <> Jason.encode!(event) <> "\n\n"
    end)
  end
end
