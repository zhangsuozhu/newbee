defmodule Newbee.LLM.ChatWireProjectionTest do
  # chat/completions 请求投影回归：transcript 里的 UI/统计私有字段不得出网。
  #
  # 线上事故两例，形态一致：
  # ① 2026-10-14 opencode/zen `cat-jam-free`：assistant 消息自带的 `reasoning`
  #    被原样发进请求体 → 400 `Unrecognized request argument supplied: messages[5].reasoning.`；
  # ② 2026-10-20 opencode/zen `beam-free`：Session 给每条消息补的 `created_at`
  #    被原样发进请求体 → 400 `messages[3].created_at`（同一 key 下 minimax/deepseek
  #    静默忽略，只有严格上游会拒）。
  # 坏消息留在历史里 → 之后每一轮都 400，会话永久卡死。
  use ExUnit.Case, async: true

  alias Newbee.LLM.Client

  @t0 "2026-10-20T15:52:10+08:00"

  # 一条"真实形态"的 transcript：每条消息都带 Session 补写的 `created_at`（2026-10-20
  # 事故字段），assistant 带 `reasoning` / `done` / `next_steps`，中断封印的 tool 结果
  # 带 `recovery`，provider 扩展 `cache_control` 则必须保留。
  @transcript [
    %{"role" => "system", "content" => "sys", "created_at" => @t0, "_usage" => %{"prompt_tokens" => 1}},
    %{"role" => "user", "content" => "hi", "created_at" => @t0},
    %{
      "role" => "assistant",
      "content" => "先看代码",
      "created_at" => @t0,
      "reasoning" => "读文件",
      "cache_control" => %{"type" => "ephemeral"},
      "tool_calls" => [
        %{
          "id" => "call_1",
          "type" => "function",
          "function" => %{"name" => "run_elixir", "arguments" => ~s({"code":"1 + 1"})}
        }
      ]
    },
    %{
      "role" => "tool",
      "tool_call_id" => "call_1",
      "content" => "2",
      "created_at" => @t0,
      "_stop_reason" => "tool_calls",
      "recovery" => true
    },
    %{
      "role" => "assistant",
      "content" => "讲完了",
      "created_at" => @t0,
      "done" => true,
      "next_steps" => [%{"label" => "再来"}]
    }
  ]

  # 会话私有字段清单：Session.append/messages 与 Agent.Loop 写进 transcript 的非协议键。
  # 新增这类字段时，必须同时加进 Client 的 @chat_private_msg_keys，否则严格上游 400
  # （本清单就是那条约束的可执行版本）。
  @private_keys [
    "created_at",
    "reasoning",
    "done",
    "next_steps",
    "recovery",
    "_usage",
    "_stop_reason",
    "_responses_items"
  ]

  defp client(opts \\ []) do
    Client.new(Keyword.merge([model: "test/m", api_key: "t", base_url: "http://localhost"], opts))
  end

  test "默认投影：摘掉 newbee 私有字段，协议字段与 provider 扩展字段保留" do
    projected = Client.project_chat_messages(@transcript, client())

    for key <- @private_keys do
      refute Enum.any?(projected, &Map.has_key?(&1, key)), "#{key} 不应出网"
    end

    assert Enum.at(projected, 0) == %{"role" => "system", "content" => "sys"}
    assert Enum.at(projected, 1) == %{"role" => "user", "content" => "hi"}
    assert Enum.at(projected, 3) == %{"role" => "tool", "tool_call_id" => "call_1", "content" => "2"}

    assistant = Enum.at(projected, 2)
    assert assistant["content"] == "先看代码"
    assert [%{"id" => "call_1", "function" => %{"name" => "run_elixir"}}] = assistant["tool_calls"]
    # provider 消息级扩展默认不动（避免误删个别网关能用的键）
    assert assistant["cache_control"] == %{"type" => "ephemeral"}
    assert Enum.at(projected, 4) == %{"role" => "assistant", "content" => "讲完了"}

    # 投影只作用于请求体：transcript 原件（UI 回放与统计用）逐字保留
    assert Enum.at(@transcript, 3)["created_at"] == @t0
    refute Map.has_key?(Enum.at(projected, 3), "created_at")
  end

  test "strict 投影：只留协议字段" do
    projected = Client.project_chat_messages(@transcript, client(), strict: true)

    assert Enum.at(projected, 2) == %{
             "role" => "assistant",
             "content" => "先看代码",
             "tool_calls" => [
               %{
                 "id" => "call_1",
                 "type" => "function",
                 "function" => %{"name" => "run_elixir", "arguments" => ~s({"code":"1 + 1"})}
               }
             ]
           }

    assert Enum.at(projected, 3) == %{"role" => "tool", "content" => "2", "tool_call_id" => "call_1"}
    refute Enum.any?(projected, &Map.has_key?(&1, "cache_control"))
  end

  test "原子键消息在 strict 投影下同样只留协议字段" do
    messages = [%{role: "user", content: "hi", reasoning: "x"}]

    assert Client.project_chat_messages(messages, client(), strict: true) == [
             %{"role" => "user", "content" => "hi"}
           ]
  end

  test "capabilities.reasoningEcho: true 保留 reasoning，其余私有字段仍摘掉；strict 无视该能力" do
    echo = client(capabilities: %{reasoning_echo: true})

    projected = Client.project_chat_messages(@transcript, echo)
    assert Enum.at(projected, 2)["reasoning"] == "读文件"
    refute Enum.any?(projected, &Map.has_key?(&1, "done"))

    strict = Client.project_chat_messages(@transcript, echo, strict: true)
    refute Enum.any?(strict, &Map.has_key?(&1, "reasoning"))
  end

  test "complete：带 reasoning/done 的历史进请求体前被投影掉" do
    test_pid = self()

    plug = fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:req_body, Jason.decode!(body)})

      Req.Test.json(conn, %{"choices" => [%{"message" => %{"role" => "assistant", "content" => "ok"}}]})
    end

    assert {:ok, "ok", _} =
             Client.complete(client(req_options: [plug: plug, retry: false]), @transcript)

    assert_receive {:req_body, body}, 1_000

    for key <- @private_keys do
      refute Enum.any?(body["messages"], &Map.has_key?(&1, key)), "#{key} 不应出网"
    end
  end

  test "stream_chat：历史里的 reasoning/done 不出网" do
    test_pid = self()

    plug = fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:req_body, Jason.decode!(body)})
      conn = Plug.Conn.send_chunked(Plug.Conn.put_resp_content_type(conn, "text/event-stream"), 200)
      {:ok, conn} = Plug.Conn.chunk(conn, sse_data())
      conn
    end

    assert {:ok, message, _usage} =
             Client.stream_chat(
               client(req_options: [plug: plug, retry: false]),
               @transcript,
               fn _ -> :ok end
             )

    assert message["content"] == "ok"
    assert_receive {:req_body, body}, 1_000

    for key <- ["created_at", "reasoning", "done", "recovery"] do
      refute Enum.any?(body["messages"], &Map.has_key?(&1, key)), "#{key} 不应出网"
    end
  end

  test "opencode/zen beam-free 事故：created_at 首次请求就不出网（无 400 重试）" do
    test_pid = self()

    # 复刻真上游行为：任一消息带 created_at 就按索引回 400
    # （2026-10-20 实测：beam-free / cat-jam-free 严格校验，minimax / deepseek 静默忽略）。
    plug = fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      body = Jason.decode!(body)
      send(test_pid, {:req_body, body})

      case Enum.find_index(body["messages"], &Map.has_key?(&1, "created_at")) do
        nil ->
          conn = Plug.Conn.send_chunked(Plug.Conn.put_resp_content_type(conn, "text/event-stream"), 200)
          {:ok, conn} = Plug.Conn.chunk(conn, sse_data())
          conn

        idx ->
          conn
          |> Plug.Conn.put_status(400)
          |> Req.Test.json(%{
            "error" => %{
              "param" => "messages[#{idx}].created_at",
              "type" => "invalid_request_error",
              "message" =>
                "Upstream request failed: [unsupported_parameter] Unrecognized request argument supplied: messages[#{idx}].created_at."
            }
          })
      end
    end

    opts = [req_options: [plug: plug, retry: false]]

    assert {:ok, message, _usage} =
             Client.stream_chat(client(opts), @transcript, fn _ -> :ok end)

    assert message["content"] == "ok"
    assert_receive {:req_body, body}, 1_000
    refute Enum.any?(body["messages"], &Map.has_key?(&1, "created_at"))

    # 投影已覆盖 → 不该有第二次请求（不会先去撞一次 400 再靠 strict 兜底）
    refute_receive {:req_body, _}, 200
  end

  test "上游点名 messages[i].reasoning：strict 投影重试一次并成功" do
    test_pid = self()

    plug = fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      body = Jason.decode!(body)
      send(test_pid, {:req_body, body})

      if Enum.any?(body["messages"], &Map.has_key?(&1, "reasoning")) do
        conn
        |> Plug.Conn.put_status(400)
        |> Req.Test.json(%{
          "error" => %{
            "param" => "messages[2].reasoning",
            "message" =>
              "Upstream request failed: [unsupported_parameter] Unrecognized request argument supplied: messages[2].reasoning."
          }
        })
      else
        conn = Plug.Conn.send_chunked(Plug.Conn.put_resp_content_type(conn, "text/event-stream"), 200)
        {:ok, conn} = Plug.Conn.chunk(conn, sse_data())
        conn
      end
    end

    # reasoningEcho 打开 → 首次请求确实带 reasoning（模拟配置失配/未来新字段），
    # 兜底重试必须把它摘掉。
    opts = [capabilities: %{reasoning_echo: true}, req_options: [plug: plug, retry: false]]

    assert {:ok, message, _usage} = Client.stream_chat(client(opts), @transcript, fn _ -> :ok end)
    assert message["content"] == "ok"

    assert_receive {:req_body, first}, 1_000
    assert Enum.any?(first["messages"], &Map.has_key?(&1, "reasoning"))

    assert_receive {:req_body, second}, 1_000
    refute Enum.any?(second["messages"], &Map.has_key?(&1, "reasoning"))
    refute Map.has_key?(second, "reasoning_effort")
  end

  defp sse_data do
    [%{"choices" => [%{"delta" => %{"content" => "ok"}}]}]
    |> Enum.map_join("\n\n", fn event -> "data: " <> Jason.encode!(event) end)
    |> Kernel.<>("\n\ndata: [DONE]\n\n")
  end
end
