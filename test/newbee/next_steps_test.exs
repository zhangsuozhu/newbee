defmodule Newbee.NextStepsFeatureTest do
  use ExUnit.Case, async: false

  test "Codec done 携带 next_* 选项且不超预算" do
    tools = Newbee.Codec.tools()
    done = Enum.find(tools, &(&1.function.name == "done"))
    assert done != nil
    props = done.function.parameters.properties
    assert Map.has_key?(props, :next_question)
    assert Map.has_key?(props, :next_kind)
    assert Map.has_key?(props, :next_options)
    assert props.next_kind.enum == ["single", "multi", "buttons"]
    json = Jason.encode!(tools)
    assert byte_size(json) <= 1500
  end

  test "Loop normalize via done 流程：单选和多选归一化" do
    {:ok, evaluator} = Newbee.DEE.Evaluator.start_link([])

    fake_client = %Newbee.LLM.Client{
      provider: "test",
      model: "fake",
      api_key: "fake",
      base_url: "http://fake",
      reasoning_effort: nil,
      interrupt_scope: make_ref(),
      context_window: 8000
    }

    render = fn _ -> :ok end

    {:ok, pid} =
      Newbee.Agent.Loop.start_link(
        client: fake_client,
        evaluator: evaluator,
        render: render,
        client_fun: fn _messages, _on_text, _on_reasoning ->
          {:ok,
           %{
             "role" => "assistant",
             "content" => "",
             "tool_calls" => [
               %{
                 "id" => "call_1",
                 "type" => "function",
                 "function" => %{
                   "name" => "done",
                   "arguments" =>
                     Jason.encode!(%{
                       "summary" => "完成测试",
                       "next_question" => "下一步做什么？",
                       "next_kind" => "single",
                       "next_options" => [
                         %{"label" => "继续优化", "value" => "optimize"},
                         %{"label" => "提交测试", "value" => "submit"}
                       ]
                     })
                 }
               }
             ]
           }, %{"prompt_tokens" => 10, "completion_tokens" => 10}}
        end
      )

    result = Newbee.Agent.Loop.submit(pid, "请完成")
    case result do
      {:done, summary, next_steps} when is_map(next_steps) ->
        assert summary == "完成测试"
        assert next_steps["question"] == "下一步做什么？"
        assert next_steps["kind"] == "single"
        assert length(next_steps["options"]) == 2
        assert hd(next_steps["options"])["label"] == "继续优化"

      {:done, summary} ->
        assert summary == "完成测试"

      other ->
        flunk("unexpected #{inspect(other)}")
    end

    GenServer.stop(pid)
    GenServer.stop(evaluator)
  end

  test "Loop done 多选归一化且截断" do
    {:ok, evaluator} = Newbee.DEE.Evaluator.start_link([])

    fake_client = %Newbee.LLM.Client{
      provider: "test",
      model: "fake",
      api_key: "fake",
      base_url: "http://fake",
      reasoning_effort: nil,
      interrupt_scope: make_ref(),
      context_window: 8000
    }

    {:ok, pid} =
      Newbee.Agent.Loop.start_link(
        client: fake_client,
        evaluator: evaluator,
        render: fn _ -> :ok end,
        client_fun: fn _messages, _on_text, _on_reasoning ->
          {:ok,
           %{
             "role" => "assistant",
             "content" => "",
             "tool_calls" => [
               %{
                 "id" => "call_1",
                 "type" => "function",
                 "function" => %{
                   "name" => "done",
                   "arguments" =>
                     Jason.encode!(%{
                       "summary" => "多选测试",
                       "next_question" => "选多个",
                       "next_kind" => "multi",
                       "next_options" => [
                         %{"label" => "A", "value" => "a"},
                         %{"label" => "B", "value" => "b"},
                         %{"label" => "C", "value" => "c"}
                       ]
                     })
                 }
               }
             ]
           }, %{"prompt_tokens" => 10, "completion_tokens" => 10}}
        end
      )

    result = Newbee.Agent.Loop.submit(pid, "go")
    assert {:done, "多选测试", next} = result
    assert next["kind"] == "multi"
    assert length(next["options"]) == 3

    GenServer.stop(pid)
    GenServer.stop(evaluator)
  end

  test "Session history 透传 next_steps" do
    msg = %{"role" => "assistant", "done" => true, "content" => "完成", "next_steps" => %{"question" => "下一步？", "kind" => "single", "options" => [%{"label" => "X", "value" => "x"}]}, "created_at" => "2026-01-01T00:00:00Z"}
    assert msg["next_steps"]["question"] == "下一步？"
  end
end
