defmodule Newbee.TUI.Screen do
  @moduledoc """
  屏幕渲染（纯逻辑 + 单个 paint 落点）：

  - 折行：按可见宽度（CJK 双宽感知，Line.width），超宽行真正折行
  - 双缓冲：与上次帧 diff，只重写变化的行；首帧/resize 全清重画
  - 无闪烁：不清屏（旧实现每帧 \e[2J 是闪烁根源），行内重写后 \e[K 去尾
  - 输出区滚动：page>0 时上翻历史（PgUp/PgDn），底部固定输入行
  """

  alias Newbee.TUI.Line

  @doc "把渲染行列表 -> 屏幕行列表（真实折行）。"
  @spec wrap(term(), pos_integer()) :: list(String.t())
  def wrap(lines, cols) when is_list(lines) do
    Enum.flat_map(lines, &wrap_line(&1, cols))
  end

  @doc """
  只折行尾部：从最后一行往前折，凑够 need 个屏幕行即停。
  返回 {rows（显示顺序）, complete?（已扫到首行/到顶）}。
  paint 每帧只显示末尾几十行，全量折行在巨型工具输出下是 O(历史×宽度)。
  """
  def wrap_tail(lines, cols, need) do
    {chunks, _row_count, top?} = do_wrap_tail(Enum.reverse(lines), cols, need, [], 0)

    # 注意：倒序遍历 + 头部 cons 后 acc 已是显示顺序，不可再 reverse。
    {Enum.concat(chunks), top?}
  end

  # 从最后一行往前折，凑够 need 个屏幕行即停。
  # top? = 已扫到首行（列表耗尽或恰好停在首行）——即 complete?（已到顶）。
  defp do_wrap_tail([], _cols, _need, acc, rows), do: {acc, rows, true}

  defp do_wrap_tail([line | rest], cols, need, acc, rows) do
    w = wrap_line(line, cols)
    rows = rows + length(w)

    if rows >= need do
      {[w | acc], rows, rest == []}
    else
      do_wrap_tail(rest, cols, need, [w | acc], rows)
    end
  end

  # 单行折行：ANSI 转义不占宽。把行拆成 {段, 样式} 流再按宽度拼。
  defp wrap_line(line, cols) do
    chunks = ansi_chunks(line)
    max = max(cols, 1)
    rows = layout(chunks, max) |> Enum.reverse() |> Enum.map(&Enum.reverse/1)
    rows |> Enum.map(fn row -> row |> Enum.reverse() |> build_row() end)
  end

  # [{text, style} | :nl] 段流；style 是当前 SGR 码列表。
  # \n 是硬换行：流式回复常含多行，若当普通字符会与终端自动换行错位（行乱根因）。
  defp ansi_chunks(line), do: do_ansi(String.to_charlist(line), "", [], [])

  defp do_ansi([], text, style, acc) do
    acc = if text == "", do: acc, else: [{text, style} | acc]
    Enum.reverse(acc)
  end

  defp do_ansi([10 | rest], text, style, acc) do
    acc = if text == "", do: acc, else: [{text, style} | acc]
    do_ansi(rest, "", style, [:nl | acc])
  end

  # 孤立的 \r 丢弃（\r\n 里 \n 已断行）
  defp do_ansi([13 | rest], text, style, acc), do: do_ansi(rest, text, style, acc)

  defp do_ansi([27, ?[ | rest], text, style, acc) do
    {codes, rest} = take_sgr(rest, "")
    acc = if text == "", do: acc, else: [{text, style} | acc]

    style2 =
      case codes do
        "0" -> []
        "" -> style
        _ -> merge_sgr(style, codes)
      end

    do_ansi(rest, "", style2, acc)
  end

  defp do_ansi([cp | rest], text, style, acc) do
    do_ansi(rest, text <> <<cp::utf8>>, style, acc)
  end

  # 吃掉 SGR 参数直到 m
  defp take_sgr([?m | rest], acc), do: {acc, rest}
  defp take_sgr([cp | rest], acc), do: take_sgr(rest, acc <> <<cp>>)
  defp take_sgr([], acc), do: {acc, []}

  # SGR 合并：新码替换同类属性（粗略：直接追加，0 清空）
  defp merge_sgr(style, codes) do
    style ++ String.split(codes, ";")
  end

  # 按宽度铺行；宽度随行携带（O(n)）。
  # 旧实现每个字符都重算 row_width（O(行长×列数)），巨型工具输出行卡死 paint。
  defp layout(chunks, max), do: layout(chunks, max, [], 0, [])

  defp layout([], _max, row, _w, rows) do
    if row == [], do: rows, else: [row | rows]
  end

  # 硬换行：封当前行；空行（连续 \n）也占一行
  defp layout([:nl | rest], max, row, _w, rows) do
    layout(rest, max, [], 0, [row | rows])
  end

  defp layout([{text, style} | rest], max, row, w, rows) do
    {row, w, rows} =
      text
      |> String.to_charlist()
      |> Enum.reduce({row, w, rows}, fn cp, {row, w, rows} ->
        cw = Line.char_width(cp)

        # 双宽字符不得贴到右缘（留 1 空隙，避免折进半格）：窄字符超界才折，
        # 宽字符到边界即折。单字符行（row == []）永不折，保证超宽字符有处放。
        overflow? =
          if cw > 1 do
            w + cw >= max
          else
            w + cw > max
          end

        if overflow? and row != [] do
          # 换行：当前行封板，cp 开新行
          {[{cp, style}], cw, [row | rows]}
        else
          {[{cp, style} | row], w + cw, rows}
        end
      end)

    layout(rest, max, row, w, rows)
  end

  # 按原顺序聚相邻同段；无样式段不加 SGR
  defp build_row(pairs) do
    pairs
    |> Enum.reverse()
    |> merge_runs([], nil)
    |> Enum.map_join(fn
      {cps, []} -> cps
      {cps, style} -> "\e[" <> Enum.join(style, ";") <> "m" <> cps <> "\e[0m"
    end)
  end

  defp merge_runs([], acc, _style), do: Enum.reverse(acc)

  # 首段：起新 run
  defp merge_runs([{cp, style} | rest], [], _old), do: merge_runs(rest, [{<<cp::utf8>>, style}], style)

  # 与 acc 头同样式：并入当前 run（聚相邻同段，避免每字符一个 SGR）
  defp merge_runs([{cp, style} | rest], [{cur, s} | acc_tail], _old) when style == s do
    merge_runs(rest, [{cur <> <<cp::utf8>>, s} | acc_tail], style)
  end

  # 换段：起新 run
  defp merge_runs([{cp, style} | rest], acc, _old) do
    merge_runs(rest, [{<<cp::utf8>>, style} | acc], style)
  end

  # ── 双缓冲 paint ──

  defstruct prev: nil, cols: 0, rows: 0, port: nil, input_rows: 1

  @doc """
  打开直通 stdout 的输出端口（TUI 启动时调用一次）。

  必须绕过 group leader：输入 reader 的 `IO.getn` 挂起期间，OTP `user` IO 服务器
  会把所有后续 put_chars 排队到下一次按键才处理——即"不输入就不输出"的根因。
  fd 端口直写 tty，与输入等待完全解耦。
  """
  def open_port, do: Port.open({:fd, 1, 1}, [:binary, :out])

  @doc """
  全量重画（首帧 / resize / 翻页跳变）。port 来自 open_port/0。

  布局（自底向上）：第 rows 行 = 输入行，rows-1 = 分隔线，rows-2 = 状态栏，
  1..rows-3 = 正文输出区。status 为 {status_text, {line_no, cursor_col}}。
  """
  def paint_full(port, lines, input_view, status, cols, rows, page \\ 0) do
    {status_text, {line_no, cursor_col}} = status
    in_lines = String.split(input_view, "\n")
    n = max(length(in_lines), 1)
    body = body_rows(lines, cols, max(rows - 2 - n, 1), page)
    out = ["\e[H\e[2J"]

    out =
      out ++
        Enum.map(Enum.with_index(body, 1), fn {l, i} ->
          "\e[#{i};1H" <> l <> "\e[K"
        end)

    out = out ++ ["\e[#{rows - n - 1};1H\e[K" <> slice_by_width(status_text, cols) <> "\e[K"]
    out = out ++ ["\e[#{rows - n};1H" <> String.duplicate("─", cols) <> "\e[K"]

    out =
      out ++
        (Enum.with_index(in_lines, 1)
         |> Enum.map(fn {l, i} -> "\e[#{rows - n + i};1H\e[K" <> String.slice(l, 0, max(cols, 0)) end))

    # 光标定位到输入行后重新显示（启动时 \e[?25l 隐藏，每帧补 \e[?25h）
    out = out ++ ["\e[#{line_no};#{cursor_col}H\e[?25h"]
    Port.command(port, out)
    %__MODULE__{prev: body, cols: cols, rows: rows, port: port, input_rows: n}
  end

  @doc """
  增量重画：只重写与上一帧不同的行。
  """
  def paint_delta(screen, lines, input_view, status, cols, rows, page \\ 0) do
    {status_text, {line_no, cursor_col}} = status
    in_lines = String.split(input_view, "\n")
    n = max(length(in_lines), 1)
    body = body_rows(lines, cols, max(rows - 2 - n, 1), page)
    # 屏幕上第 i 行（1 起）
    out =
      diff_rows(screen.prev, body)
      |> Enum.map(fn {i, l} -> "\e[#{i + 1};1H" <> l <> "\e[K" end)

    out = out ++ ["\e[#{rows - n - 1};1H\e[K" <> slice_by_width(status_text, cols) <> "\e[K"]
    out = out ++ ["\e[#{rows - n};1H" <> String.duplicate("─", cols) <> "\e[K"]

    out =
      out ++
        (Enum.with_index(in_lines, 1)
         |> Enum.map(fn {l, i} -> "\e[#{rows - n + i};1H\e[K" <> String.slice(l, 0, max(cols, 0)) end))

    # 光标定位到输入行后重新显示（启动时 \e[?25l 隐藏，每帧补 \e[?25h）
    out = out ++ ["\e[#{line_no};#{cursor_col}H\e[?25h"]
    Port.command(screen.port, out)
    %__MODULE__{prev: body, cols: cols, rows: rows, port: screen.port, input_rows: n}
  end

  # 输出区取末尾 need 行（聊天 TUI 永远锚定最新内容）；page>0 时向上翻 need×page 行。
  # 旧实现取【前】N 行：transcript 超过一屏后新内容永远不上屏（"输出一半不显示"根因）。
  defp body_rows(lines, cols, need, page) do
    {tail, _top?} = wrap_tail(lines, cols, need * (page + 1))
    Enum.take(tail, need)
  end

  # 返回 [{行号(0起), 新行}]
  # 返回 [{行号(0起), 新行}] — O(n) zip 版，旧版 Enum.at 每轮 O(n) 导致大屏卡顿
  defp diff_rows(prev, next) do
    prev = prev || []
    next = next || []
    max_len = max(length(prev), length(next))
    prev = prev ++ List.duplicate(nil, max_len - length(prev))
    next = next ++ List.duplicate(nil, max_len - length(next))

    prev
    |> Enum.zip(next)
    |> Enum.with_index()
    |> Enum.reduce([], fn {{p, c}, i}, acc ->
      if p != c, do: [{i, c || ""} | acc], else: acc
    end)
    |> Enum.reverse()
  end

  # 状态栏按可见宽度截断：ANSI 转义不占宽，且不在转义/双宽字符中间切断。
  # 旧实现直接走 Line.slice_by_width，把 \e[2m 里的 [ 2 m 各计 1 列，
  # 状态栏右栏（tok/bind/policy）被多算的 20+ 列顶出屏幕。
  defp slice_by_width(text, cols) do
    max = max(cols, 0)

    text
    |> ansi_chunks()
    |> Enum.reject(&(&1 == :nl))
    |> take_chunks(max, [])
    |> Enum.reverse()
    |> Enum.map_join(fn {cps, style} ->
      if style == [] do
        cps
      else
        "\e[" <> Enum.join(style, ";") <> "m" <> cps <> "\e[0m"
      end
    end)
  end

  defp take_chunks(_chunks, w, acc) when w <= 0, do: acc
  defp take_chunks([], _w, acc), do: acc

  defp take_chunks([{text, style} | rest], w, acc) do
    {kept, rem} = take_cps(String.to_charlist(text), w, [])
    acc = if kept == [], do: acc, else: [{List.to_string(kept), style} | acc]
    take_chunks(rest, rem, acc)
  end

  defp take_cps(_chars, w, acc) when w <= 0, do: {Enum.reverse(acc), 0}
  defp take_cps([], w, acc), do: {Enum.reverse(acc), w}

  defp take_cps([cp | rest], w, acc) do
    cw = Line.char_width(cp)

    if w >= cw do
      take_cps(rest, w - cw, [cp | acc])
    else
      {Enum.reverse(acc), w}
    end
  end
end
