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
end
