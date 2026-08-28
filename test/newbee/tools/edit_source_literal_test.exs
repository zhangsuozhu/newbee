defmodule Newbee.Tools.EditSourceLiteralTest do
  use ExUnit.Case, async: true
  alias Newbee.Tools.Edit

  test "wrap 保留插值与 heredoc 文本，不在当前表达式提前求值" do
    source = "value = \#{name}\ntext = \"\"\"nested\"\"\""
    expression = Edit.source_literal(source)
    assert {value, []} = Code.eval_string(expression)
    assert value == source
  end

  test "候选分隔符全部冲突时回退到安全转义字符串" do
    source = "/|\'\"()[]{}<> \#{value}"
    expression = Edit.source_literal(source)
    refute String.starts_with?(expression, "~S")
    assert {value, []} = Code.eval_string(expression)
    assert value == source
  end

  test "用法可通过既有 Edit 工具文档发现" do
    assert {:ok, doc} = Newbee.read("tool://Newbee.Tools.Edit")
    assert doc =~ "source_literal/1"
  end
end
