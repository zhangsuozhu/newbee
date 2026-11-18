defmodule Newbee.Plugins.PromptSectionTest do
  @moduledoc """
  能力索引（每轮对话都带的常驻提示）的预算与截断不变量。

  R1 基线：1941 B / 契约上限 1800 B（红）；修后 1745 B。剩余余量只有约 55 B，
  所以再加一个内置工具之前必须先压缩摘要 —— 这条约束由本文件的回归线守住。
  """
  use ExUnit.Case, async: true

  @budget 1_800
  # 回归线：允许 10 B 的文案微调，再多就是"又往提示里塞东西"。
  @regression_line 1_790

  test "总量在契约上限与回归线之内" do
    section = Newbee.Plugins.prompt_section()

    assert byte_size(section) <= @budget,
           "能力索引 #{byte_size(section)} B 超出契约上限 #{@budget} B"

    assert byte_size(section) <= @regression_line,
           "能力索引回涨到 #{byte_size(section)} B（回归线 #{@regression_line} B）；新增工具请先压缩其他摘要"
  end

  test "每条摘要都按字节预算截断，且不在半个词/半个字符处断" do
    for %{plugin_id: id, name: name, summary: summary} <- Newbee.Plugins.list() do
      assert is_binary(summary) and summary != "", "#{id} 没有摘要"
      assert String.valid?(summary), "#{id} 摘要不是合法 UTF-8"
      assert summary == String.trim(summary), "#{id} 摘要带首尾空白"
      refute String.ends_with?(summary, " "), "#{id} 摘要在空格处收尾（说明按字节硬切）"

      first_line = first_doc_line(name)
      assert String.starts_with?(first_line, summary), "#{id} 摘要不是 moduledoc 首行的前缀"

      # 词边界：截断点后必须紧跟行尾或空白；不允许 "…; start " 这种半个词。
      rest = String.slice(first_line, byte_size(summary)..-1//1)
      assert rest == "" or String.starts_with?(rest, " "), "#{id} 摘要在词中间截断：#{inspect(rest)}"
    end
  end

  test "中文摘要按字符边界截断：不产生半个多字节字符" do
    for %{plugin_id: id, summary: summary} <- Newbee.Plugins.list() do
      assert byte_size(summary) == byte_size(String.trim(summary))
      assert String.length(summary) > 0
      # 任何被截断的摘要都必须仍是合法 UTF-8 且不含替换字符
      refute summary =~ "�", "#{id} 摘要含替换字符（多字节字符被切半）"
    end
  end

  defp first_doc_line(name) do
    module = name |> String.trim_leading("Elixir.") |> then(&Module.concat([&1]))
    {:docs_v1, _, _, _, %{"en" => doc}, _, _} = Code.fetch_docs(module)
    doc |> String.split("\n") |> hd() |> String.trim()
  end
end
