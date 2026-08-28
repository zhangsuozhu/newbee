defmodule Newbee.LLM.ResponsesTest do
  use ExUnit.Case, async: true

  alias Newbee.LLM.{Client, Responses}

  test "stream_chat uses Responses API and restores tool calls" do
    test_pid = self()

    plug = fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:request, conn.request_path, Jason.decode!(body)})

      Req.Test.json(conn, %{
        "output" => [
          %{
            "type" => "message",
            "content" => [%{"type" => "output_text", "text" => "working"}]
          },
          %{
            "type" => "function_call",
            "call_id" => "call-1",
            "name" => "run_elixir",
            "arguments" => ~s({"code":"1 + 1"})
          }
        ],
        "usage" => %{
          "input_tokens" => 20,
          "output_tokens" => 5,
          "total_tokens" => 25,
          "input_tokens_details" => %{"cached_tokens" => 8}
        }
      })
    end

    client =
      Client.new(
        api: "openai-responses",
        model: "muse-spark-1.2-contributor",
        api_key: "test",
        base_url: "http://localhost",
        reasoning_effort: "max",
        req_options: [plug: plug, retry: false]
      )

    assert {:ok, message, usage} =
             Client.stream_chat(client, [%{"role" => "user", "content" => "hi"}], fn text ->
               send(test_pid, {:text, text})
             end)

    assert_received {:request, "/responses", body}
    assert_received {:text, "working"}
    assert body["input"] == [%{"role" => "user", "content" => "hi"}]
    assert body["reasoning"] == %{"effort" => "high"}
    assert [%{"type" => "function", "name" => "run_elixir"} | _] = body["tools"]
    assert message["content"] == "working"

    assert message["tool_calls"] == [
             %{
               "id" => "call-1",
               "type" => "function",
               "function" => %{"name" => "run_elixir", "arguments" => ~s({"code":"1 + 1"})}
             }
           ]

    assert usage["prompt_tokens"] == 20
    assert usage["cache_read_tokens"] == 8
  end

  test "legacy off effort is sent as none" do
    test_pid = self()

    plug = fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:reasoning_body, Jason.decode!(body)})
      Req.Test.json(conn, %{"output" => [], "usage" => %{}})
    end

    client =
      %Client{
        api: "openai-responses",
        model: "test/m",
        api_key: "test",
        base_url: "http://localhost",
        reasoning_effort: "off",
        req_options: [plug: plug, retry: false]
      }

    assert {:ok, _message, _usage} =
             Client.stream_chat(client, [%{"role" => "user", "content" => "hi"}], fn _ -> :ok end)

    assert_received {:reasoning_body, %{"reasoning" => %{"effort" => "none"}}}
  end

  test "input converts prior tool calls and outputs" do
    messages = [
      %{
        "role" => "assistant",
        "content" => "",
        "tool_calls" => [
          %{
            "id" => "call-1",
            "type" => "function",
            "function" => %{"name" => "run_elixir", "arguments" => ~s({"code":"1 + 1"})}
          }
        ]
      },
      %{"role" => "tool", "tool_call_id" => "call-1", "content" => "2"}
    ]

    assert Responses.input(messages) == [
             %{
               "type" => "function_call",
               "call_id" => "call-1",
               "name" => "run_elixir",
               "arguments" => ~s({"code":"1 + 1"})
             },
             %{"type" => "function_call_output", "call_id" => "call-1", "output" => "2"}
           ]
  end
end
