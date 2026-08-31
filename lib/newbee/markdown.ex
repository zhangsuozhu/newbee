defmodule Newbee.Markdown do
  @moduledoc """
  轻量 Markdown → ANSI 渲染器（无依赖，纯函数）。
  用于 CLI/TUI 把模型输出的 markdown 渲染成带样式的终端文本。

  支持：
    - ATX 标题 # ~ ######
    - 围栏代码块 ```lang ... ```
    - 引用 >
    - 无序列表 - * +（含嵌套）
    - 有序列表 1. 2.
    - 水平线 ---
    - 表格 | a | b |（简单对齐）
    - 行内：**bold** *italic* `code` [text](url) ~~del~~
  """

  # ── 正则 ──

  # 围栏代码块开/闭行
  @fence_start ~r/^\s*(`{3})([^\s`]*)\s*$/
  @fence_end ~r/^\s*`{3}\s*$/
  # ATX 标题
  @heading ~r/^(\#{1,6})\s+(.*)$/
  # 引用
  @blockquote ~r/^>\s?(.*)$/
  # 任务列表 - [ ] / - [x]
  @task ~r/^(\s*)[-*+]\s+\[([ xX])\]\s+(.*)$/
  # 无序列表（含嵌套缩进）
  @ul ~r/^(\s*)[-*+]\s+(.*)$/
  # 有序列表
  @ol ~r/^(\s*)(\d+)[.)]\s+(.*)$/
  # 水平线
  @hr ~r/^\s*-{3,}\s*$/
  # 表格分隔行（|---| 或 |:---:|）
  @sep ~r/^\s*\|?[\s:\-|]+\|?\s*$/
  # 行内标记：**bold** 先于 *italic*；* 模式不允许内部再含 *，避免吞掉 **
  @inline_re ~r/(\*\*[^*]+\*\*|\*[^*\s][^*]*\*|`[^`\n]+`|\[[^\]\n]*\]\([^)\n]*\)|~~[^~\n]+~~)/u
  # markdown 特征：** 或 ` 或 ]( 或行首 #/>/-/数字列表/---/```
  @feature ~r/\*\*|`{1,3}|\[[^\]]*\]\(|^\s{0,3}(\#{1,6}\s|>|[-*+]\s|\d+[.)]\s|-{3,}\s*$)/m

  # ── API ──

  @doc "渲染整段 markdown 文本为带 ANSI 样式的多行文本（行间 \n）。"
  def render(text) when is_binary(text) do
    text
    |> String.split(["\r\n", "\n"])
    |> render_blocks(:normal, [])
    |> Enum.join("\n")
  end

  @doc "检测文本是否含 markdown 特征（用于决定是否渲染）。"
  def md?(text) when is_binary(text) do
    Regex.match?(@feature, text)
  end

  # ── 块级状态机：逐行处理，fence 内外两态 ──

  defp render_blocks([], _mode, acc), do: Enum.reverse(acc)

  # fence 内：elixir/exs 语法高亮，其余灰色，直到闭合 ```
  defp render_blocks([line | rest], {:fence, lang}, acc) do
    if Regex.match?(@fence_end, line) do
      render_blocks(rest, :normal, ["\e[2m```\e[0m" | acc])
    else
      colored =
        if lang in ["elixir", "exs", "ex", "iex"] do
          Newbee.TUI.Highlight.elixir(line)
        else
          "\e[38;5;187m" <> line <> "\e[0m"
        end

      render_blocks(rest, {:fence, lang}, [colored | acc])
    end
  end

  defp render_blocks([line | rest] = lines, :normal, acc) do
    case take_table(lines) do
      {table_lines, rest} ->
        render_blocks(rest, :normal, Enum.reverse(render_table(table_lines)) ++ acc)

      nil ->
        cond do
          Regex.match?(@fence_start, line) ->
            [_, _ticks, lang] = Regex.run(@fence_start, line)
            label = if lang == "", do: "```", else: "```" <> lang
            render_blocks(rest, {:fence, lang}, ["\e[36m" <> label <> "\e[0m" | acc])

          Regex.match?(@heading, line) ->
            [_, hashes, body] = Regex.run(@heading, line)
            render_blocks(rest, :normal, [heading(String.length(hashes), body) | acc])

          Regex.match?(@task, line) ->
            [_, indent, check, body] = Regex.run(@task, line)
            render_blocks(rest, :normal, [task_line(indent, check, body) | acc])

          Regex.match?(@ul, line) ->
            [_, indent, body] = Regex.run(@ul, line)
            render_blocks(rest, :normal, [list_line(indent, "•", body) | acc])

          Regex.match?(@ol, line) ->
            [_, indent, num, body] = Regex.run(@ol, line)
            render_blocks(rest, :normal, [list_line(indent, num, body) | acc])

          Regex.match?(@blockquote, line) ->
            [_, body] = Regex.run(@blockquote, line)
            render_blocks(rest, :normal, [quote_line(body) | acc])

          Regex.match?(@hr, line) ->
            render_blocks(rest, :normal, ["\e[2m" <> String.duplicate("─", 40) <> "\e[0m" | acc])

          true ->
            render_blocks(rest, :normal, [inline(line) | acc])
        end
    end
  end

  # ── 块级渲染 ──

  defp heading(level, body) do
    style =
      case level do
        1 -> "\e[1;36m"
        2 -> "\e[1;34m"
        3 -> "\e[1;33m"
        _ -> "\e[36m"
      end

    style <> inline(String.trim(body)) <> "\e[0m"
  end

  defp list_line(indent, marker, body) do
    indent <> "\e[33m" <> marker <> "\e[0m " <> inline(body)
  end

  defp task_line(indent, check, body) do
    mark = if check == " ", do: "\e[2m☐\e[0m", else: "\e[32m☑\e[0m"
    indent <> mark <> " " <> inline(body)
  end

  defp quote_line(body) do
    "\e[2m│\e[0m " <> inline(String.trim_leading(body, ">") |> String.trim_leading())
  end

  # ── 表格（简单对齐：计算列宽、左对齐填充、表头 bold）──

  defp take_table([hdr, sep | rest]) do
    if rowish?(hdr) and sep?(sep) do
      {data, rest} = Enum.split_while(rest, &rowish?/1)
      {[hdr, sep | data], rest}
    end
  end

  defp take_table(_), do: nil

  defp rowish?(line), do: String.contains?(line, "|")

  defp sep?(line), do: String.contains?(line, "-") and Regex.match?(@sep, line)

  defp render_table([hdr, sep | data]) do
    rows = [parse_row(hdr) | Enum.map(data, &parse_row/1)]
    aligns = parse_align(sep)
    ncols = Enum.max(Enum.map(rows, &length/1), fn -> 1 end)

    widths =
      for col <- 0..(ncols - 1) do
        rows
        |> Enum.map(fn r -> if col < length(r), do: String.length(Enum.at(r, col)), else: 0 end)
        |> Enum.max(fn -> 0 end)
      end

    header = table_row(Enum.at(rows, 0), widths, aligns, true)

    ruler =
      "\e[2m " <>
        Enum.join(Enum.map(widths, fn w -> String.duplicate("─", w + 2) end), "┼") <> " \e[0m"

    data_rows = Enum.map(Enum.drop(rows, 1), &table_row(&1, widths, aligns, false))
    [header, ruler | data_rows]
  end

  defp parse_row(line) do
    line
    |> String.split("|")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp parse_align(sep) do
    sep
    |> String.split("|")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(fn col ->
      cond do
        String.starts_with?(col, ":") and String.ends_with?(col, ":") -> :center
        String.ends_with?(col, ":") -> :right
        true -> :left
      end
    end)
  end

  defp table_row(cells, widths, aligns, header?) do
    n = length(widths)
    padded = cells ++ List.duplicate("", max(n - length(cells), 0))

    body =
      padded
      |> Enum.with_index()
      |> Enum.map(fn {c, i} -> pad_cell(c, Enum.at(widths, i), Enum.at(aligns, i, :left)) end)
      |> Enum.join("\e[2m│\e[0m")

    if header? do
      "\e[1m " <> body <> " \e[0m"
    else
      " " <> inline(body) <> " "
    end
  end

  defp pad_cell(cell, width, align) do
    diff = max(width - String.length(cell), 0)

    case align do
      :right -> String.duplicate(" ", diff) <> cell
      :center -> String.duplicate(" ", div(diff, 2)) <> cell <> String.duplicate(" ", diff - div(diff, 2))
      _ -> cell <> String.duplicate(" ", diff)
    end
  end

  # ── 行内渲染：正则分割保留 captures，分段套 ANSI，**/*/~~ 内部递归 inline ──

  defp inline(s) do
    Regex.split(@inline_re, s, include_captures: true, trim: false)
    |> Enum.map(&render_piece/1)
    |> Enum.join()
  end

  # 每个片段先按正则形状校验（取 delim 包裹的内容），避免把普通文本误判为样式
  defp render_piece(piece) do
    cond do
      bold = take_wrapped(piece, "**", "*", false) ->
        "\e[1m" <> inline(bold) <> "\e[0m"

      italic = take_wrapped(piece, "*", "*", true) ->
        "\e[3m" <> inline(italic) <> "\e[0m"

      code = take_wrapped(piece, "`", "`", false) ->
        "\e[48;5;236m\e[38;5;180m" <> code <> "\e[0m"

      del = take_wrapped(piece, "~~", "~", false) ->
        "\e[9m" <> inline(del) <> "\e[0m"

      link = take_link(piece) ->
        {label, _url} = link
        "\e[4;34m" <> inline(label) <> "\e[0m"

      true ->
        piece
    end
  end

  # 取 delim 包裹的内层；forbidden 为内层禁止字符，no_leading_space? 对应 * 模式 \*[^*\s]
  defp take_wrapped(piece, delim, forbidden, no_leading_space?) do
    d = byte_size(delim)

    if String.starts_with?(piece, delim) and String.ends_with?(piece, delim) and
         byte_size(piece) > 2 * d do
      inner = binary_part(piece, d, byte_size(piece) - 2 * d)

      if not String.contains?(inner, forbidden) and
           (not no_leading_space? or not String.starts_with?(inner, [" ", "\t"])) do
        inner
      end
    end
  end

  # 链接只显示 label：\e[4;34m 蓝色下划线（正则已保证 label 无 ]、url 无 )）
  defp take_link(piece) do
    case :binary.match(piece, "](") do
      {idx, 2} ->
        label = binary_part(piece, 1, idx - 1)
        rest = binary_part(piece, idx + 2, byte_size(piece) - idx - 2)

        if String.ends_with?(rest, ")") and not String.contains?(label, "]") do
          {label, binary_part(rest, 0, byte_size(rest) - 1)}
        end

      :nomatch ->
        nil
    end
  end
end
