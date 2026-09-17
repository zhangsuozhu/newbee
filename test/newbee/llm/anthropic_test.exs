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
end
