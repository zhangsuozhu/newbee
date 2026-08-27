defmodule Newbee.Agent.LoopAskPersistTest do
  use ExUnit.Case, async: false
  import Newbee.TestScripted
  alias Newbee.Agent.Loop
  alias Newbee.DEE.Evaluator

  defp ask_msg(question, extra) do
    args = Map.merge(%{question: question}, extra)
    %{
      "role" => "assistant",
      "content" => "",
      "tool_calls" => [
        %{
          "id" => "c_ask",
          "type" => "function",
          "function" => %{"name" => "ask", "arguments" => Jason.encode!(args)}
        }
      ]
    }
  end

  test "ask 落盘 role=ask 且携带 options/kind，刷新可回放" do
    sid = "ask-persist-test-" <> Integer.to_string(System.unique_integer([:positive]))

    {:ok, ev} = Evaluator.start(mode: :local)
    {:ok, kernel} =
      Loop.start_link(
        client: %{},
        evaluator: ev,
        session_id: sid,
        client_fun:
          scripted([
            fn _m, _o ->
              {:ok, ask_msg("选哪个方案？", %{options: [%{label: "A", value: "a"}, %{label: "B", value: "b"}], kind: "buttons"}), %{}}
            end
          ])
      )

    assert {:ask, q, opts, kind} = Loop.submit(kernel, "hi")
    assert q == "选哪个方案？"
    assert kind == "buttons"
    assert [%{"label" => "A", "value" => "a"}, %{"label" => "B", "value" => "b"}] = opts

    s = Newbee.Session.open(sid)
    msgs = Newbee.Session.messages(s)
    ask_msg_ = Enum.find(msgs, &(&1["role"] == "ask"))
    assert ask_msg_ != nil
    assert ask_msg_["content"]["question"] == "选哪个方案？"
    assert ask_msg_["content"]["kind"] == "buttons"
    assert length(ask_msg_["content"]["options"]) == 2

    GenServer.stop(kernel)
    GenServer.stop(ev)
  end

  test "ask 无 options 时默认 text 形态且落盘 options 为空" do
    sid = "ask-persist-test-" <> Integer.to_string(System.unique_integer([:positive]))
    {:ok, ev} = Evaluator.start(mode: :local)
    {:ok, kernel} =
      Loop.start_link(
        client: %{},
        evaluator: ev,
        session_id: sid,
        client_fun:
          scripted([
            fn _m, _o -> {:ok, ask_msg("确认一下", %{}), %{}} end
          ])
      )

    assert {:ask, "确认一下", nil, "text"} = Loop.submit(kernel, "hi")
    s = Newbee.Session.open(sid)
    msgs = Newbee.Session.messages(s)
    ask_msg_ = Enum.find(msgs, &(&1["role"] == "ask"))
    assert ask_msg_["content"]["options"] == []
    assert ask_msg_["content"]["kind"] == "text"

    GenServer.stop(kernel)
    GenServer.stop(ev)
  end
end
