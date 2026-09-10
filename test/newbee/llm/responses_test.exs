defmodule Newbee.LLM.ResponsesTest do
  # These tests change NEWBEE_HOME; the process-wide environment must not race other modules.
  use ExUnit.Case, async: false

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

      send(
        test_pid,
        {:request, conn.request_path, Jason.decode!(body), Plug.Conn.get_req_header(conn, "x-opencode-session")}
      )

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
          "input_tokens_details" => %{"cached_tokens" => 8, "cache_write_tokens" => 3}
        }
      })
    end

    client =
      Client.new(
        provider: "opencode",
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

    assert_received {:request, "/responses", body, ["responses-session"]}

    assert_received {:text, "working"}
    assert body["input"] == [%{"role" => "user", "content" => "hi"}]
    assert body["reasoning"] == %{"effort" => "max"}
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
    assert usage["cache_write_tokens"] == 3
  end

  describe "complete/3 on a responses route" do
    test "posts /responses (not chat/completions) and returns Client.complete's contract" do
      test_pid = self()

      plug = fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:request, conn.request_path, Jason.decode!(body)})

        Req.Test.json(conn, %{
          "output" => [
            %{
              "type" => "message",
              "content" => [%{"type" => "output_text", "text" => "摘要正文"}]
            }
          ],
          "usage" => %{
            "input_tokens" => 30,
            "output_tokens" => 7,
            "total_tokens" => 37,
            "input_tokens_details" => %{"cached_tokens" => 24}
          }
        })
      end

      client =
        Client.new(
          api: "openai-responses",
          model: "muse-spark-1.2-contributor",
          api_key: "test",
          base_url: "http://localhost",
          cache_key: "newbee-responses-session",
          req_options: [plug: plug, retry: false]
        )

      assert {:ok, "摘要正文", %{usage: usage, logprobs: nil}} =
               Client.complete(client, [%{"role" => "user", "content" => "压缩这段历史"}],
                 tools: Newbee.Codec.tools(),
                 tool_choice: "none",
                 temperature: nil,
                 extra: %{max_tokens: 2000}
               )

      assert_received {:request, "/responses", body}
      assert body["stream"] == false
      assert body["input"] == [%{"role" => "user", "content" => "压缩这段历史"}]
      assert body["prompt_cache_key"] == "newbee-responses-session"

      # max_tokens 必须翻译成 Responses 的 max_output_tokens，否则网关当未知字段拒绝
      assert body["max_output_tokens"] == 2000
      refute Map.has_key?(body, "max_tokens")

      # 调用方显式传 temperature: nil 时不写字段（压缩回放要求与路由请求同形）
      refute Map.has_key?(body, "temperature")

      assert [%{"type" => "function", "name" => "run_elixir"} | _] = body["tools"]

      assert usage["prompt_tokens"] == 30
      assert usage["cache_read_tokens"] == 24
    end

    test "omits tools when none are given" do
      test_pid = self()

      plug = fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:request, Jason.decode!(body)})
        Req.Test.json(conn, %{"output" => [], "usage" => %{}})
      end

      client =
        Client.new(
          api: "openai-responses",
          model: "m",
          api_key: "test",
          base_url: "http://localhost",
          req_options: [plug: plug, retry: false]
        )

      assert {:ok, "", %{usage: _}} = Client.complete(client, [%{"role" => "user", "content" => "hi"}])
      assert_received {:request, body}
      refute Map.has_key?(body, "tools")
    end

    test "non-2xx returns an error value instead of crashing" do
      plug = fn conn ->
        conn
        |> Plug.Conn.put_status(500)
        |> Req.Test.json(%{"error" => %{"message" => "Internal server error"}})
      end

      client =
        Client.new(
          api: "openai-responses",
          model: "m",
          api_key: "test",
          base_url: "http://localhost",
          req_options: [plug: plug, retry: false]
        )

      assert {:error, {:http_error, 500, _body}} =
               Client.complete(client, [%{"role" => "user", "content" => "hi"}])
    end
  end

  test "explicit prompt cache options are sent only when configured" do
    test_pid = self()

    plug = fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:cache_request, Jason.decode!(body)})
      Req.Test.json(conn, %{"output" => [], "usage" => %{}})
    end

    client =
      Client.new(
        api: "openai-responses",
        model: "gpt-5.6-sol",
        api_key: "test",
        base_url: "http://localhost",
        prompt_cache_options: %{"mode" => "explicit", "ttl" => "30m"},
        req_options: [plug: plug, retry: false]
      )

    assert {:ok, _message, _usage} = Client.stream_chat(client, [user("hi")])
    assert_received {:cache_request, body}
    assert body["prompt_cache_options"] == %{"mode" => "explicit", "ttl" => "30m"}
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

  test "input converts chat-style image content for Responses API" do
    messages = [
      %{
        "role" => "user",
        "content" => [
          %{"type" => "text", "text" => "analyze this screenshot"},
          %{
            "type" => "image_url",
            "image_url" => %{"url" => "data:image/png;base64,AA==", "detail" => "high"}
          }
        ]
      }
    ]

    assert Responses.input(messages) == [
             %{
               "role" => "user",
               "content" => [
                 %{"type" => "input_text", "text" => "analyze this screenshot"},
                 %{
                   "type" => "input_image",
                   "image_url" => "data:image/png;base64,AA==",
                   "detail" => "high"
                 }
               ]
             }
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

  test "default test capability cache stays inside this VM's isolated global storage" do
    previous = System.get_env("NEWBEE_HOME")
    System.delete_env("NEWBEE_HOME")

    on_exit(fn ->
      if previous, do: System.put_env("NEWBEE_HOME", previous), else: System.delete_env("NEWBEE_HOME")
    end)

    assert Newbee.LLM.ResponsesCapabilities.path() ==
             Path.join(Newbee.GlobalStore.root(), "llm-responses-capabilities.json")
  end

  test "capability downgrade persists to disk and survives process restart (NEWBEE_HOME)" do
    # 隔离持久化文件到临时 HOME，避免污染真实 ~/.newbee，也不污染 async 兄弟测试
    tmp_home = Path.join(Newbee.GlobalStore.root(), "newbee-home-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp_home)
    previous_home = System.get_env("NEWBEE_HOME")
    System.put_env("NEWBEE_HOME", tmp_home)

    on_exit(fn ->
      if previous_home, do: System.put_env("NEWBEE_HOME", previous_home), else: System.delete_env("NEWBEE_HOME")
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

  test "stream_chat tools: [] sends a provider request without callable tools" do
    test_pid = self()

    plug = fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:btw_request, Jason.decode!(raw)})

      Req.Test.json(conn, %{
        "output" => [%{"type" => "message", "content" => [%{"type" => "output_text", "text" => "side answer"}]}],
        "usage" => %{"input_tokens" => 3, "output_tokens" => 2, "total_tokens" => 5}
      })
    end

    client =
      Client.new(
        api: "openai-responses",
        model: "test/btw-no-tools",
        api_key: "test",
        base_url: "http://localhost",
        req_options: [plug: plug, retry: false]
      )

    assert {:ok, %{"content" => "side answer"} = message, _} =
             Client.stream_chat(
               client,
               [%{"role" => "user", "content" => "question"}],
               fn _ -> :ok end,
               fn _ -> :ok end,
               tools: []
             )

    assert Map.get(message, "tool_calls", []) == []

    assert_received {:btw_request, body}
    assert body["tools"] == []
  end

  test "tool output alone in delta forces full request" do
    test_pid = self()

    checkpoint =
      Path.join(
        System.tmp_dir!(),
        "newbee-responses-tool-delta-" <> to_string(System.unique_integer([:positive])) <> ".json"
      )

    on_exit(fn -> File.rm(checkpoint) end)

    plug = fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      body = Jason.decode!(raw)
      send(test_pid, {:tool_delta_request, body})

      if length(body["input"] || []) == 1 do
        Req.Test.json(conn, %{
          "id" => "resp-1",
          "output" => [
            %{"type" => "function_call", "call_id" => "call-0910", "name" => "run_elixir", "arguments" => "{}"}
          ],
          "usage" => %{"input_tokens" => 1, "output_tokens" => 1, "total_tokens" => 2}
        })
      else
        Req.Test.json(conn, response("resp-2", "two"))
      end
    end

    client_opts = [
      api: "openai-responses",
      model: "test/tool-delta-" <> to_string(System.unique_integer([:positive])),
      api_key: "test",
      base_url: "http://localhost",
      responses_continuation: true,
      responses_checkpoint: checkpoint,
      req_options: [plug: plug, retry: false]
    ]

    client = Client.new(client_opts)
    assert {:ok, first, _} = Client.stream_chat(client, [user("hi")])
    assert first["tool_calls"] != []

    history = [user("hi"), first, %{"role" => "tool", "tool_call_id" => "call-0910", "content" => "2"}]
    assert {:ok, %{"content" => "two"}, _} = Client.stream_chat(Client.new(client_opts), history)

    assert_received {:tool_delta_request, _first_body}
    assert_received {:tool_delta_request, second_body}
    refute Map.has_key?(second_body, "previous_response_id")
    types = Enum.map(second_body["input"], &(&1["type"] || &1["role"]))
    assert "function_call" in types
    assert "function_call_output" in types
  end

  test "orphaned tool output error retries once with full" do
    test_pid = self()

    checkpoint =
      Path.join(
        System.tmp_dir!(),
        "newbee-responses-tool-retry-" <> to_string(System.unique_integer([:positive])) <> ".json"
      )

    on_exit(fn -> File.rm(checkpoint) end)

    plug = fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      body = Jason.decode!(raw)
      send(test_pid, {:tool_retry_request, body})

      cond do
        body["previous_response_id"] ->
          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.send_resp(
            400,
            Jason.encode!(%{
              "error" => %{
                "message" => "No tool call found for tool output with call_id call-0910.",
                "type" => "invalid_request_error"
              }
            })
          )

        map_size(body) > 0 and body["input"] == [%{"role" => "user", "content" => "hi"}] ->
          Req.Test.json(conn, response("resp-1", "one"))

        true ->
          Req.Test.json(conn, response("resp-3", "three"))
      end
    end

    client_opts = [
      api: "openai-responses",
      model: "test/tool-retry-" <> to_string(System.unique_integer([:positive])),
      api_key: "test",
      base_url: "http://localhost",
      responses_continuation: true,
      responses_checkpoint: checkpoint,
      req_options: [plug: plug, retry: false]
    ]

    assert {:ok, %{"content" => "one"}, _} = Client.stream_chat(Client.new(client_opts), [user("hi")])
    history = [user("hi"), assistant("one"), user("continue")]
    assert {:ok, %{"content" => "three"}, _} = Client.stream_chat(Client.new(client_opts), history)

    assert_received {:tool_retry_request, _first}
    assert_received {:tool_retry_request, incremental}
    assert incremental["previous_response_id"] == "resp-1"
    assert_received {:tool_retry_request, full}
    refute Map.has_key?(full, "previous_response_id")
    assert full["input"] == history
  end

  describe "capability downgrade guards" do
    test "a 400 whose text merely contains \"passed\" never downgrades streaming" do
      test_pid = self()
      model = unique_model("passed-back")

      plug = fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:guard_request, Jason.decode!(raw)})

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          400,
          Jason.encode!(%{
            "error" => %{
              "code" => "invalid_request_error",
              "message" => "The `reasoning_text` in the thinking mode must be passed back to the API.",
              "type" => "invalid_request_error"
            }
          })
        )
      end

      client =
        Client.new(
          api: "openai-responses",
          model: model,
          api_key: "test",
          base_url: "http://localhost",
          req_options: [plug: plug, retry: false]
        )

      assert {:error, {:http_error, 400, _body}} = Client.stream_chat(client, [user("hi")])

      # "passed" 里虽然含 sse，但它不是"不支持流式"的证据：一次请求就够，不许降级重试
      assert_received {:guard_request, %{"stream" => true}}
      refute_received {:guard_request, _}
      refute Map.has_key?(memory_caps(model), :stream)
      assert Newbee.LLM.ResponsesCapabilities.load({"http://localhost", model}) == %{}
    end

    test "a downgrade that does not clear the error is reverted and not persisted" do
      test_pid = self()
      model = unique_model("downgrade-ineffective")

      plug = fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:stream_retry_request, Jason.decode!(raw)})

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          400,
          Jason.encode!(%{"error" => %{"message" => "stream is not supported"}})
        )
      end

      client =
        Client.new(
          api: "openai-responses",
          model: model,
          api_key: "test",
          base_url: "http://localhost",
          req_options: [plug: plug, retry: false]
        )

      assert {:error, {:http_error, 400, _body}} = Client.stream_chat(client, [user("hi")])

      # 降级后重试还是同一个 400，说明"关掉流式"并没有解决问题 → 回退内存标记、不落盘
      assert_received {:stream_retry_request, %{"stream" => true}}
      assert_received {:stream_retry_request, %{"stream" => false}}
      refute_received {:stream_retry_request, _}
      refute Map.has_key?(memory_caps(model), :stream)
      assert Newbee.LLM.ResponsesCapabilities.load({"http://localhost", model}) == %{}
    end

    test "a confirmed downgrade is persisted for the next process" do
      tmp_home = Path.join(System.tmp_dir!(), "newbee-home-#{System.unique_integer([:positive])}")
      File.mkdir_p!(tmp_home)
      System.put_env("NEWBEE_HOME", tmp_home)

      on_exit(fn ->
        System.delete_env("NEWBEE_HOME")
        File.rm_rf(tmp_home)
      end)

      test_pid = self()
      model = unique_model("downgrade-confirmed")
      scope = {"http://localhost", model}

      plug = fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        body = Jason.decode!(raw)
        send(test_pid, {:confirmed_request, body})

        if body["stream"] do
          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.send_resp(
            400,
            Jason.encode!(%{"error" => %{"message" => "unsupported parameter: stream"}})
          )
        else
          Req.Test.json(conn, response("resp-confirmed", "json"))
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

      assert {:ok, %{"content" => "json"}, _usage} = Client.stream_chat(client, [user("hi")])

      assert_received {:confirmed_request, %{"stream" => true}}
      assert_received {:confirmed_request, %{"stream" => false}}
      assert Map.get(memory_caps(model), :stream) == false

      # 落盘这份"重试已验证"的结论：另一进程（清掉内存缓存后）也能读到
      :persistent_term.erase({:newbee, :responses_caps_persisted, scope})
      assert Newbee.LLM.ResponsesCapabilities.load(scope) == %{stream: false}
    end
  end

  describe "reasoning extraction" do
    test "keeps reasoning carried in content reasoning_text parts (non-stream path)" do
      test_pid = self()

      plug = fn conn ->
        Req.Test.json(conn, %{
          "id" => "resp-reasoning-content",
          "output" => [
            %{
              "type" => "reasoning",
              "id" => "rs-content",
              "summary" => [],
              "content" => [%{"type" => "reasoning_text", "text" => "先想一步"}]
            },
            %{"type" => "message", "content" => [%{"type" => "output_text", "text" => "答案"}]}
          ],
          "usage" => %{"input_tokens" => 3, "output_tokens" => 4, "total_tokens" => 7}
        })
      end

      client =
        Client.new(
          api: "openai-responses",
          model: unique_model("reasoning-content"),
          api_key: "test",
          base_url: "http://localhost",
          responses_stream: false,
          req_options: [plug: plug, retry: false]
        )

      assert {:ok, %{"content" => "答案"} = message, _usage} =
               Client.stream_chat(
                 client,
                 [user("hi")],
                 fn text -> send(test_pid, {:text_delta, text}) end,
                 fn reasoning -> send(test_pid, {:reasoning_delta, reasoning}) end
               )

      assert message["reasoning"] == "先想一步"
      assert_received {:text_delta, "答案"}
      assert_received {:reasoning_delta, "先想一步"}
    end

    test "keeps reasoning from the final streamed output when no reasoning delta arrives" do
      test_pid = self()

      plug = fn conn ->
        events = [
          %{"type" => "response.created", "response" => %{"id" => "resp-final-reasoning"}},
          %{
            "type" => "response.output_item.done",
            "output_index" => 0,
            "item" => %{
              "type" => "reasoning",
              "id" => "rs-final",
              "summary" => [],
              "content" => [%{"type" => "reasoning_text", "text" => "网关只给终稿"}]
            }
          },
          %{
            "type" => "response.output_item.done",
            "output_index" => 1,
            "item" => %{
              "type" => "message",
              "content" => [%{"type" => "output_text", "text" => "答案"}]
            }
          },
          %{
            "type" => "response.completed",
            "response" => %{
              "id" => "resp-final-reasoning",
              "usage" => %{"input_tokens" => 1, "output_tokens" => 1, "total_tokens" => 2}
            }
          }
        ]

        payload = Enum.map_join(events, fn event -> "data: " <> Jason.encode!(event) <> "\n\n" end)

        conn =
          conn
          |> Plug.Conn.put_resp_header("content-type", "text/event-stream")
          |> Plug.Conn.send_chunked(200)

        {:ok, conn} = Plug.Conn.chunk(conn, payload)
        conn
      end

      client =
        Client.new(
          api: "openai-responses",
          model: unique_model("reasoning-final"),
          api_key: "test",
          base_url: "http://localhost",
          req_options: [plug: plug, retry: false]
        )

      assert {:ok, message, _usage} =
               Client.stream_chat(
                 client,
                 [user("hi")],
                 fn text -> send(test_pid, {:text_delta, text}) end,
                 fn reasoning -> send(test_pid, {:reasoning_delta, reasoning}) end
               )

      assert message["reasoning"] == "网关只给终稿"
      assert_received {:reasoning_delta, "网关只给终稿"}
    end
  end

  defp unique_model(prefix), do: "test/#{prefix}-#{System.unique_integer([:positive])}"

  defp memory_caps(model) do
    :persistent_term.get({Newbee.LLM.Responses, :capabilities}, %{})
    |> Map.get({"http://localhost", model}, %{})
  end
end
