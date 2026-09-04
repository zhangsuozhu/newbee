defmodule Newbee.CodecTest do
  use ExUnit.Case, async: true
  alias Newbee.Codec

  test "工具面封顶 3 个（光头原则）" do
    names = Enum.map(Codec.tools(), & &1.function.name)
    assert Enum.sort(names) == ["ask", "done", "run_elixir"]
  end

  test "从 OpenAI 形状的消息提取 tool_calls" do
    msg = %{
      "tool_calls" => [
        %{
          "id" => "call_1",
          "type" => "function",
          "function" => %{"name" => "run_elixir", "arguments" => ~s({"code":"1+1","title":"t"})}
        }
      ]
    }

    [call] = Codec.extract_tool_calls(msg)
    assert call.id == "call_1"
    assert call.name == "run_elixir"
    assert call.args["code"] == "1+1"
  end

  test "无 tool_calls 返回空列表" do
    assert Codec.extract_tool_calls(%{"content" => "hi"}) == []
  end

  test "run_elixir 提示包含安全源码字面量用法" do
    tool = Enum.find(Codec.tools(), &(&1.function.name == "run_elixir"))
    assert tool.function.description =~ "Edit.source_literal/1"
    assert tool.function.description =~ "heredoc"
  end
  test "无名碎片丢掉，避免 unknown tool 回写 nil id" do
    msg = %{"tool_calls" => [%{"id" => nil, "type" => "function", "function" => %{"name" => "", "arguments" => ""}}]}
    assert Codec.extract_tool_calls(msg) == []
  end

  test "缺 function 与参数形态容错" do
    assert Codec.extract_tool_calls(%{"tool_calls" => [%{"id" => "c1", "function" => nil}]}) == []
    msg = %{"tool_calls" => [%{"id" => "c2", "type" => "function", "function" => %{"name" => "done", "arguments" => nil}}]}
    [call] = Codec.extract_tool_calls(msg)
    assert call.id == "c2"
    assert call.name == "done"
    assert call.args == %{}
  end

end
