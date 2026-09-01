defmodule Newbee.LLM.ResponsesTest do
  use ExUnit.Case, async: true

  alias Newbee.LLM.{Client, Responses}

  setup do
    Client.register_interrupt_scope()
    Client.clear_interrupt()
    :ok
  end

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
        cache_key: "newbee-responses-session",
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
    assert body["prompt_cache_key"] == "newbee-responses-session"
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
        responses_mode: :responses,
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

  test "continuation survives client recreation and sends only strict delta" do
    test_pid = self()
    checkpoint = Path.join(System.tmp_dir!(), "newbee-responses-#{System.unique_integer([:positive])}.json")
    on_exit(fn -> File.rm(checkpoint) end)

    plug = fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      body = Jason.decode!(raw)
      send(test_pid, {:continuation_request, body})

      {id, text} =
        if body["previous_response_id"], do: {"resp-2", "two"}, else: {"resp-1", "one"}

      Req.Test.json(conn, response(id, text))
    end

    client_opts = [
      api: "openai-responses",
      model: "test/continuation-persist-6084",
      api_key: "test",
      base_url: "http://localhost",
      cache_key: "newbee-session",
      responses_continuation: true,
      responses_checkpoint: checkpoint,
      req_options: [plug: plug, retry: false]
    ]

    first = Client.new(client_opts)
    assert {:ok, %{"content" => "one"}, _usage} = Client.stream_chat(first, [user("hi")])
    assert_received {:continuation_request, first_body}
    refute Map.has_key?(first_body, "previous_response_id")
    assert first_body["store"] == true
    refute Map.has_key?(Jason.decode!(File.read!(checkpoint)), "input")

    recreated = Client.new(client_opts)
    history = [user("hi"), assistant("one"), user("interrupted work"), user("continue")]
    assert {:ok, %{"content" => "two"}, _usage} = Client.stream_chat(recreated, history)
    assert_received {:continuation_request, second_body}
    assert second_body["previous_response_id"] == "resp-1"
    assert second_body["store"] == true
    assert second_body["input"] == [user("interrupted work"), user("continue")]
  end

  test "missing previous response retries once with the full request" do
    test_pid = self()
    checkpoint = Path.join(System.tmp_dir!(), "newbee-responses-fallback-#{System.unique_integer([:positive])}.json")
    on_exit(fn -> File.rm(checkpoint) end)
    counter = :atomics.new(1, [])

    # 网关对带 previous_response_id 的请求一律回 400 previous_response_not_found；
    # 不带 previous 的（含 continuation 被禁用后的全量重放）正常回 200。
    plug = fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      body = Jason.decode!(raw)
      n = :atomics.add_get(counter, 1, 1)
      send(test_pid, {:fallback_request, n, body})

      cond do
        # 带 previous_response_id 的续接：网关一律拒绝（模拟不保留 store 的网关）
        body["previous_response_id"] ->
          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.send_resp(400, Jason.encode!(%{"error" => %{"code" => "previous_response_not_found"}}))

        n == 1 ->
          Req.Test.json(conn, response("resp-1", "one"))

        true ->
          Req.Test.json(conn, response("resp-#{n}", "three"))
      end
    end

    client =
      Client.new(
        api: "openai-responses",
        model: "test/fallback-#{System.unique_integer([:positive])}",
        api_key: "test",
        base_url: "http://localhost",
        cache_key: "newbee-session",
        responses_continuation: true,
        responses_checkpoint: checkpoint,
        req_options: [plug: plug, retry: false]
      )

    assert {:ok, %{"content" => "one"}, _usage} = Client.stream_chat(client, [user("hi")])
    history = [user("hi"), assistant("one"), user("continue")]
    assert {:ok, %{"content" => "three"}, _usage} = Client.stream_chat(client, history)

    # 第 2 次：尝试续接（带 previous_response_id）→ 被拒
    assert_received {:fallback_request, 2, incremental}
    assert incremental["previous_response_id"] == "resp-1"
    # 第 3 次：continuation 已被禁用，全量重放且不再带 previous_response_id / store
    assert_received {:fallback_request, 3, full}
    refute Map.has_key?(full, "previous_response_id")
    refute Map.has_key?(full, "store")
    assert full["input"] == history
  end

  test "Responses SSE streams text and reasoning while preserving encrypted reasoning items" do
    test_pid = self()

    plug = fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      body = Jason.decode!(raw)
      send(test_pid, {:streaming_request, body})

      payload =
        [
          %{"type" => "response.output_text.delta", "delta" => "work"},
          %{"type" => "response.output_text.delta", "delta" => "ing"},
          %{
            "type" => "response.reasoning_summary_text.delta",
            "delta" => "thinking",
            "summary_index" => 0
          },
          %{
            "type" => "response.output_item.added",
            "output_index" => 0,
            "item" => %{
              "type" => "function_call",
              "id" => "fc-1",
              "call_id" => "call-1",
              "name" => "run_elixir",
              "arguments" => ""
            }
          },
          %{
            "type" => "response.function_call_arguments.delta",
            "item_id" => "fc-1",
            "output_index" => 0,
            "delta" => ~s({"code":)
          },
          %{
            "type" => "response.function_call_arguments.delta",
            "item_id" => "fc-1",
            "output_index" => 0,
            "delta" => ~s("1 + 1"})
          },
          %{
            "type" => "response.output_item.done",
            "output_index" => 0,
            "item" => %{
              "type" => "function_call",
              "id" => "fc-1",
              "call_id" => "call-1",
              "name" => "run_elixir",
              "arguments" => ~s({"code":"1 + 1"})
            }
          },
          %{
            "type" => "response.output_item.done",
            "output_index" => 1,
            "item" => %{
              "type" => "reasoning",
              "id" => "rs-1",
              "encrypted_content" => "ciphertext",
              "summary" => [%{"type" => "summary_text", "text" => "thinking"}]
            }
          },
          %{
            "type" => "response.completed",
            "response" => %{
              "id" => "resp-stream-1",
              "usage" => %{
                "input_tokens" => 20,
                "output_tokens" => 5,
                "total_tokens" => 25,
                "input_tokens_details" => %{"cached_tokens" => 8}
              }
            }
          }
        ]
        |> Enum.map_join(fn event -> "data: " <> Jason.encode!(event) <> "\n\n" end)

      split = div(byte_size(payload), 2)
      <<first::binary-size(^split), second::binary>> = payload

      conn =
        conn
        |> Plug.Conn.put_resp_header("content-type", "text/event-stream")
        |> Plug.Conn.send_chunked(200)

      {:ok, conn} = Plug.Conn.chunk(conn, first)
      {:ok, conn} = Plug.Conn.chunk(conn, second)
      conn
    end

    client =
      Client.new(
        api: "openai-responses",
        model: "test/streaming-responses",
        api_key: "test",
        base_url: "http://localhost",
        req_options: [plug: plug, retry: false]
      )

    assert {:ok, message, usage} =
             Client.stream_chat(
               client,
               [user("hi")],
               fn delta -> send(test_pid, {:text_delta, delta}) end,
               fn delta -> send(test_pid, {:reasoning_delta, delta}) end
             )

    assert_received {:streaming_request, body}
    assert body["stream"] == true
    assert "reasoning.encrypted_content" in body["include"]
    assert_received {:text_delta, "work"}
    assert_received {:text_delta, "ing"}
    assert_received {:reasoning_delta, "thinking"}
    assert message["content"] == "working"
    assert message["reasoning"] == "thinking"

    assert message["tool_calls"] == [
             %{
               "id" => "call-1",
               "type" => "function",
               "function" => %{"name" => "run_elixir", "arguments" => ~s({"code":"1 + 1"})}
             }
           ]

    assert message["_responses_items"] == [
             %{
               "type" => "reasoning",
               "id" => "rs-1",
               "encrypted_content" => "ciphertext",
               "summary" => [%{"type" => "summary_text", "text" => "thinking"}]
             }
           ]

    assert usage["prompt_tokens"] == 20
    assert usage["cache_read_tokens"] == 8
  end

  test "Responses input replays opaque reasoning items before assistant output" do
    reasoning_item = %{
      "type" => "reasoning",
      "id" => "rs-1",
      "encrypted_content" => "ciphertext",
      "summary" => []
    }

    message = %{
      "role" => "assistant",
      "content" => "",
      "_responses_items" => [reasoning_item],
      "tool_calls" => [
        %{
          "id" => "call-1",
          "type" => "function",
          "function" => %{"name" => "run_elixir", "arguments" => ~s({"code":"1 + 1"})}
        }
      ]
    }

    assert Responses.input([message]) == [
             reasoning_item,
             %{
               "type" => "function_call",
               "call_id" => "call-1",
               "name" => "run_elixir",
               "arguments" => ~s({"code":"1 + 1"})
             }
           ]
  end

  test "unsupported Responses streaming falls back once and stays on JSON for the endpoint" do
    test_pid = self()
    counter = :atomics.new(1, [])
    model = "test/no-stream-#{System.unique_integer([:positive])}"

    plug = fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      body = Jason.decode!(raw)
      n = :atomics.add_get(counter, 1, 1)
      send(test_pid, {:stream_fallback_request, n, body})

      if body["stream"] do
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          400,
          Jason.encode!(%{"error" => %{"message" => "stream is not supported"}})
        )
      else
        Req.Test.json(conn, response("resp-json-#{n}", "json"))
      end
    end

    client =
      Client.new(
        api: "openai-responses",
        model: model,
        api_key: "test",
        base_url: "http://localhost",
        req_options: [plug: plug, retry: false]
      )

    assert {:ok, %{"content" => "json"}, _usage} = Client.stream_chat(client, [user("one")])
    assert_received {:stream_fallback_request, 1, %{"stream" => true}}
    assert_received {:stream_fallback_request, 2, %{"stream" => false}}

    assert {:ok, %{"content" => "json"}, _usage} = Client.stream_chat(client, [user("two")])
    assert_received {:stream_fallback_request, 3, %{"stream" => false}}
  end

  test "requires API-key account gateway downgrades continuation and retries full" do
    test_pid = self()
    checkpoint = Path.join(System.tmp_dir!(), "newbee-responses-apikey-#{System.unique_integer([:positive])}.json")
    on_exit(fn -> File.rm(checkpoint) end)
    counter = :atomics.new(1, [])

    plug = fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      body = Jason.decode!(raw)
      n = :atomics.add_get(counter, 1, 1)
      send(test_pid, {:apikey_request, n, body})

      cond do
        n == 1 ->
          # 第一轮建立 checkpoint
          Req.Test.json(conn, response("resp-1", "one"))

        body["previous_response_id"] ->
          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.send_resp(
            400,
            Jason.encode!(%{
              "error" => %{
                "message" => "previous_response_id requires an OpenAI API-key account for HTTP requests",
                "type" => "invalid_request_error"
              }
            })
          )

        true ->
          Req.Test.json(conn, response("resp-full-#{n}", "full"))
      end
    end

    client =
      Client.new(
        api: "openai-responses",
        model: "test/no-continuation-#{System.unique_integer([:positive])}",
        api_key: "test",
        base_url: "http://localhost",
        cache_key: "newbee-session",
        responses_continuation: true,
        responses_checkpoint: checkpoint,
        req_options: [plug: plug, retry: false]
      )

    # 第一轮成功并写入 checkpoint
    assert {:ok, %{"content" => "one"}, _usage} = Client.stream_chat(client, [user("hi")])
    assert_received {:apikey_request, 1, first_body}
    refute Map.has_key?(first_body, "previous_response_id")
    assert first_body["store"] == true

    # 第二轮 continuation 被网关拒绝 → 自动降级 continuation 并全量重试
    history = [user("hi"), assistant("one"), user("continue")]
    assert {:ok, %{"content" => "full"}, _usage} = Client.stream_chat(client, history)

    assert_received {:apikey_request, 2, incremental}
    assert incremental["previous_response_id"] == "resp-1"
    assert_received {:apikey_request, 3, full}
    refute Map.has_key?(full, "previous_response_id")
    refute Map.has_key?(full, "store")
    assert full["input"] == history
  end

  defp user(text), do: %{"role" => "user", "content" => text}
  defp assistant(text), do: %{"role" => "assistant", "content" => text}

  defp response(id, text) do
    %{
      "id" => id,
      "output" => [
        %{"type" => "message", "content" => [%{"type" => "output_text", "text" => text}]}
      ],
      "usage" => %{"input_tokens" => 1, "output_tokens" => 1, "total_tokens" => 2}
    }
  end
  test "capability downgrade persists to disk and survives process restart (NEWBEE_HOME)" do
    # 隔离持久化文件到临时 HOME，避免污染真实 ~/.newbee，也不污染 async 兄弟测试
    tmp_home = Path.join(System.tmp_dir!(), "newbee-home-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp_home)
    System.put_env("NEWBEE_HOME", tmp_home)

    on_exit(fn ->
      System.delete_env("NEWBEE_HOME")
      File.rm_rf(tmp_home)
    end)

    scope = {"http://localhost", "test/caps-persist-#{System.unique_integer([:positive])}"}

    # 起始于无记录
    assert Newbee.LLM.ResponsesCapabilities.load(scope) == %{}

    # 模拟 Responses.put_capability 的落盘效果
    Newbee.LLM.ResponsesCapabilities.put(scope, :continuation, false)
    Newbee.LLM.ResponsesCapabilities.put(scope, :stream, false)

    # 同进程可读回
    assert Newbee.LLM.ResponsesCapabilities.load(scope) == %{continuation: false, stream: false}

    # 模拟"重启"：清掉进程内的 load_persisted 缓存，再从磁盘读——值仍在
    :persistent_term.erase({:newbee, :responses_caps_persisted, scope})
    assert Newbee.LLM.ResponsesCapabilities.load(scope) == %{continuation: false, stream: false}

    # 不同 route 互不影响
    other = {"http://localhost", "test/other-#{System.unique_integer([:positive])}"}
    assert Newbee.LLM.ResponsesCapabilities.load(other) == %{}
  end

end
