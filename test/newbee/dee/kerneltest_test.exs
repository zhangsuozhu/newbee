defmodule Newbee.Agent.LoopTest do
  use ExUnit.Case, async: false
  alias Newbee.Agent.Loop
  alias Newbee.DEE.Evaluator

  defp tool_msg(code, id \\ "call_1") do
    %{
      "role" => "assistant",
      "content" => "",
      "tool_calls" => [
        %{
          "id" => id,
          "type" => "function",
          "function" => %{"name" => "run_elixir", "arguments" => Jason.encode!(%{code: code})}
        }
      ]
    }
  end

  defp done_msg(summary) do
    %{
      "role" => "assistant",
      "content" => "final text",
      "tool_calls" => [
        %{
          "id" => "call_done",
          "type" => "function",
          "function" => %{"name" => "done", "arguments" => Jason.encode!(%{summary: summary})}
        }
      ]
    }
  end

  @tag timeout: 120_000
  test "完整循环：run_elixir → 回填 → done，绑定留在求值器" do
    {:ok, ev} = Evaluator.start(mode: :local)

    script = [
      fn _messages, _on_text -> {:ok, tool_msg("x = 40 + 2"), %{"total_tokens" => 10}} end,
      fn messages, _on_text ->
        # 断言工具结果被回填进 messages
        assert Enum.any?(messages, fn m ->
                 m["role"] == "tool" and m["content"] =~ "42"
               end)

        {:ok, done_msg("算完了"), %{"total_tokens" => 5}}
      end
    ]

    {:ok, kernel} =
      Loop.start_link(
        client: %{},
        evaluator: ev,
        session: false,
        client_fun: scripted(script)
      )

    assert {:done, "算完了"} = Loop.submit(kernel, "算个 42")
    # 绑定持久
    assert Enum.any?(Evaluator.bindings_summary(ev), &(&1.name == :x))
    # token 记账
    assert Loop.usage(kernel)["total_tokens"] == 15
  end

  test "模型只输出文本时 turn 结束" do
    {:ok, ev} = Evaluator.start(mode: :local)

    script = [
      fn _messages, on_text ->
        on_text.("直接回答")
        {:ok, %{"role" => "assistant", "content" => "直接回答", "tool_calls" => []}, %{}}
      end
    ]

    {:ok, kernel} = Loop.start_link(client: %{}, evaluator: ev, session: false, client_fun: scripted(script))
    assert {:text, "直接回答"} = Loop.submit(kernel, "hi")
  end

  test "done 工具调用也回填 tool 响应（历史不留悬空 tool_calls）" do
    {:ok, ev} = Evaluator.start(mode: :local)
    script = [fn _m, _t -> {:ok, done_msg("完"), %{}} end]

    {:ok, kernel} =
      Loop.start_link(client: %{}, evaluator: ev, session: false, client_fun: scripted(script))

    assert {:done, "完"} = Loop.submit(kernel, "x")

    last = :sys.get_state(kernel).messages |> List.last()
    assert last["role"] == "tool"
    assert last["tool_call_id"] == "call_done"
  end

  test "恢复含悬空 tool_calls 的 transcript：载入时补占位（DeepSeek 400 根因）" do
    {:ok, ev} = Evaluator.start(mode: :local)
    sid = "test_repair_#{:erlang.unique_integer([:positive])}"
    s = Newbee.Session.open(sid)
    Newbee.Session.append(s, %{"role" => "user", "content" => "hi"})
    # 崩溃现场：assistant 带了 tool_calls，tool 响应永远没写进去
    Newbee.Session.append(s, tool_msg("1 + 1", "call_orphan"))

    script = [
      fn messages, _t ->
        assert Enum.any?(messages, fn m ->
                 m["role"] == "tool" and m["tool_call_id"] == "call_orphan" and
                   m["content"] =~ "丢失"
               end)

        {:ok, %{"role" => "assistant", "content" => "ok", "tool_calls" => []}, %{}}
      end
    ]

    {:ok, kernel} =
      Loop.start_link(
        client: %{},
        evaluator: ev,
        session_id: sid,
        client_fun: scripted(script)
      )

    assert {:text, "ok"} = Loop.submit(kernel, "继续")
    File.rm(s.transcript)
  end

  test "模型返回空正文且无工具调用：不给历史落空 assistant（上游 400 根因）" do
    {:ok, ev} = Evaluator.start(mode: :local)

    script = [
      fn _messages, _on_text -> {:ok, %{"role" => "assistant", "content" => " \n "}, %{}} end
    ]

    {:ok, kernel} = Loop.start_link(client: %{}, evaluator: ev, session: false, client_fun: scripted(script))
    assert {:text, " \n "} = Loop.submit(kernel, "hi")

    msgs = :sys.get_state(kernel).messages

    refute Enum.any?(msgs, fn m ->
             m["role"] == "assistant" and String.trim(m["content"] || "") == "" and
               (m["tool_calls"] || []) == []
           end)
  end

  test "热加载后的活动 Loop：提交前清理旧空 assistant" do
    {:ok, ev} = Evaluator.start(mode: :local)

    script = [
      fn messages, _on_text ->
        refute Enum.any?(messages, fn m ->
                 m["role"] == "assistant" and String.trim(m["content"] || "") == "" and
                   (m["tool_calls"] || []) == []
               end)

        {:ok, %{"role" => "assistant", "content" => "fine", "tool_calls" => []}, %{}}
      end
    ]

    {:ok, kernel} =
      Loop.start_link(
        client: %{},
        evaluator: ev,
        session: false,
        client_fun: scripted(script)
      )

    :sys.replace_state(kernel, fn state ->
      %{state | messages: state.messages ++ [%{"role" => "assistant", "content" => ""}]}
    end)

    assert {:text, "fine"} = Loop.submit(kernel, "继续")
  end

  test "恢复含空 assistant 的 transcript：载入时丢弃（上游 400 根因）" do
    {:ok, ev} = Evaluator.start(mode: :local)
    sid = "test_repair_empty_#{:erlang.unique_integer([:positive])}"
    s = Newbee.Session.open(sid)
    Newbee.Session.append(s, %{"role" => "user", "content" => "hi"})
    # 污染现场：模型某轮返回了空正文且无工具调用的 assistant
    Newbee.Session.append(s, %{"role" => "assistant", "content" => "   "})
    Newbee.Session.append(s, %{"role" => "assistant", "content" => "ok", "tool_calls" => []})

    script = [
      fn messages, _t ->
        refute Enum.any?(messages, fn m ->
                 m["role"] == "assistant" and String.trim(m["content"] || "") == "" and
                   (m["tool_calls"] || []) == []
               end)

        {:ok, %{"role" => "assistant", "content" => "fine", "tool_calls" => []}, %{}}
      end
    ]

    {:ok, kernel} =
      Loop.start_link(
        client: %{},
        evaluator: ev,
        session_id: sid,
        client_fun: scripted(script)
      )

    assert {:text, "fine"} = Loop.submit(kernel, "继续")
    File.rm(s.transcript)
  end

  test "恢复会话逐字复用首次 system prompt" do
    {:ok, ev} = Evaluator.start(mode: :local)
    sid = "test_prefix_resume_#{System.unique_integer([:positive, :monotonic])}_#{System.system_time(:microsecond)}"

    {:ok, first} =
      Loop.start_link(
        client: %{},
        evaluator: ev,
        session_id: sid,
        client_fun: fn messages, _on_text ->
          assert List.first(messages)["role"] == "system"
          {:ok, %{"role" => "assistant", "content" => "one", "tool_calls" => []}, %{}}
        end
      )

    assert {:text, "one"} = Loop.submit(first, "first")
    first_prompt = :sys.get_state(first).messages |> List.first() |> Map.fetch!("content")
    GenServer.stop(first)

    {:ok, resumed} =
      Loop.start_link(
        client: %{},
        evaluator: ev,
        session_id: sid,
        client_fun: fn messages, _on_text ->
          assert List.first(messages)["content"] == first_prompt
          {:ok, %{"role" => "assistant", "content" => "two", "tool_calls" => []}, %{}}
        end
      )

    assert {:text, "two"} = Loop.submit(resumed, "second")
  end

  test "Esc 中断：client 返回 {:interrupted, content} 时 turn 立即终止" do
    {:ok, ev} = Evaluator.start(mode: :local)

    script = [
      fn _messages, on_text ->
        on_text.("部分生成")
        {:interrupted, "部分生成"}
      end
    ]

    {:ok, kernel} = Loop.start_link(client: %{}, evaluator: ev, session: false, client_fun: scripted(script))
    assert {:interrupted, "部分生成"} = Loop.submit(kernel, "hi")

    # 部分生成的 assistant 消息不入历史（避免悬空 tool_calls）
    msgs = :sys.get_state(kernel).messages
    refute Enum.any?(msgs, &(&1["role"] == "assistant" and &1["content"] == "部分生成"))
  end

  test "中断标志：新一轮提交自动清除（上一轮残留不影响下一轮）" do
    Newbee.LLM.Client.interrupt()
    assert Newbee.LLM.Client.interrupted?()

    {:ok, ev} = Evaluator.start(mode: :local)
    script = [fn _messages, _on_text -> {:ok, %{"role" => "assistant", "content" => "ok", "tool_calls" => []}, %{}} end]
    {:ok, kernel} = Loop.start_link(client: %{}, evaluator: ev, session: false, client_fun: scripted(script))
    assert {:text, "ok"} = Loop.submit(kernel, "hi")
    refute Newbee.LLM.Client.interrupted?()
  end

  test "观察者异常不杀死回合 Loop" do
    {:ok, ev} = Evaluator.start(mode: :local)

    script = [fn _messages, _on_text -> {:ok, %{"role" => "assistant", "content" => "ok", "tool_calls" => []}, %{}} end]

    {:ok, kernel} =
      Loop.start_link(
        client: %{},
        evaluator: ev,
        session: false,
        render: fn _event -> raise "render failed" end,
        client_fun: scripted(script)
      )

    assert {:text, "ok"} = Loop.submit(kernel, "hi")
    assert Process.alive?(kernel)
  end

  test "中断标志在 execute_calls 阶段生效：不发起下一个工具调用" do
    {:ok, ev} = Evaluator.start(mode: :local)

    script = [
      fn _messages, _on_text ->
        {:ok, tool_msg("1 + 1", "call_1"), %{}}
      end
    ]

    {:ok, kernel} = Loop.start_link(client: %{}, evaluator: ev, session: false, client_fun: scripted(script))

    # 会话级中断：通过 Loop.interrupt(kernel) 置本会话 client 的 scope flag。
    # submit 同步执行 turn，interrupt 需在 turn 进行中由外部触发——这里先置 flag
    # 再 submit，验证 execute_calls 第一个工具前即 halt（scope 在 init 时已注入 client）。
    Newbee.Agent.Loop.interrupt(kernel)
    assert {:interrupted, nil} = Loop.submit(kernel, "hi")
    # 中断只作用本会话 scope：另一会话的 client（不同 scope）不受影响
    other = %{interrupt_scope: Newbee.LLM.Client.new_interrupt_scope()}
    refute Newbee.LLM.Client.interrupted?(other)
  end

  defp scripted(script) do
    {:ok, agent} = Agent.start_link(fn -> script end)

    fn messages, on_text ->
      fun =
        Agent.get_and_update(agent, fn
          [f | rest] -> {f, rest}
          [] -> {nil, []}
        end)

      if fun, do: fun.(messages, on_text), else: {:error, :script_exhausted}
    end
  end

  @tag timeout: 60_000
  test "恢复含 usage/media 审计行的 transcript：请求历史过滤掉（Incorrect role information 根因）" do
    {:ok, ev} = Evaluator.start(mode: :local)

    sid = Integer.to_string(:erlang.unique_integer([:positive])) <> "_audit_rows"
    s = Newbee.Session.open(sid)
    Newbee.Session.append(s, %{"role" => "user", "content" => "hi"})
    Newbee.Session.append(s, %{"role" => "usage", "usage" => %{"total_tokens" => 10}})
    Newbee.Session.append(s, %{"role" => "assistant", "content" => "看图", "tool_calls" => []})
    Newbee.Session.append(s, %{"role" => "media", "content" => %{"url" => "/tmp/x.png"}})
    Newbee.Session.append(s, %{"role" => "usage", "usage" => %{"total_tokens" => 20}})

    script = [
      fn messages, _t ->
        roles = messages |> Enum.map(& &1["role"]) |> Enum.uniq()
        refute "usage" in roles, "usage 审计行泄漏进请求历史"
        refute "media" in roles, "media 审计行泄漏进请求历史"
        assert Enum.any?(messages, &(&1["role"] == "assistant" and &1["content"] == "看图"))
        {:ok, %{"role" => "assistant", "content" => "ok", "tool_calls" => []}, %{}}
      end
    ]

    {:ok, kernel} =
      Loop.start_link(client: %{}, evaluator: ev, session_id: sid, client_fun: scripted(script))

    assert {:text, "ok"} = Loop.submit(kernel, "继续")
    File.rm(s.transcript)
  end
end

:ok
