defmodule Newbee.Tools.Edit do
  @moduledoc """
  唯一公开文本补丁工具（docs/edit-v2-design.md §4.2/§5）：快照标签 + 原始行范围 + 最终内容。

      [path#tag]
      PUT N..M:      用 + 正文替换原快照 N..M 行（含端点）
      PUT <N:        在第 N 行前插入
      PUT >N:        在第 N 行后插入
      CUT N..M       删除 N..M 行

  行号全部指向原快照；stale/越界/未读/重叠/no-op 一律拒绝；
  多节全部预检通过才落盘（逻辑原子）。
  """

  alias Newbee.Tools.Edit.SnapshotStore

  @source_delimiters [{"/", "/"}, {"|", "|"}, {"'", "'"}, {"\"", "\""}, {"(", ")"}, {"[", "]"}, {"{", "}"}, {"<", ">"}]

  @doc "把任意文本包装成可直接拼入 run_elixir 的安全 Elixir 字符串表达式。"
  def source_literal(text) when is_binary(text) do
    case Enum.find(@source_delimiters, fn {open, close} ->
           not String.contains?(text, open) and not String.contains?(text, close)
         end) do
      {open, close} -> "~S" <> open <> text <> close
      nil -> inspect(text)
    end
  end

  defmodule ParseError do
    defexception [:message]
  end

  defmodule RejectError do
    defexception [:message, :category]
  end

  @op_re ~r/^(PUT|CUT)\s+(.+?)\s*(:)?$/
  @range_re ~r/^(\d+)(?:\.\.(\d+))?$/

  @doc "应用行号补丁，成功返回 %{status: :applied, files: [...]}。"
  def patch(patch_text) do
    sections = parse(patch_text)
    plans = Enum.map(sections, &plan_section/1)
    Enum.each(plans, &check_no_op!/1)
    Enum.each(plans, &write_section/1)

    %{
      status: :applied,
      files:
        Enum.map(plans, fn p ->
          %{
            path: p.path,
            old_tag: p.tag,
            new_tag: p.new_tag,
            changed_lines: p.changed_lines,
            diff: p.diff,
            context: p.context
          }
        end),
      warnings: []
    }
  end

  @doc "读取文件并记录快照，返回 %{tag, text, lines}。"
  def show(path, range \\ :all) do
    content = File.read!(path)
    full_lines = split_lines(content) |> elem(0)

    {sel, start} =
      case range do
        :all -> {full_lines, 1}
        {a, b} -> {Enum.slice(full_lines, (a - 1)..(b - 1)//1), a}
      end

    tag = SnapshotStore.record(path, content, seen_range(start, length(sel)))
    text = sel |> Enum.with_index(start) |> Enum.map(fn {l, n} -> "#{n}| #{l}" end) |> Enum.join("\n")
    %{tag: tag, text: text, lines: length(sel)}
  end

  # ── 解析 ──

  defp parse(text) do
    {sections, cur} = Enum.reduce(String.split(text, "\n"), {[], nil}, &parse_line/2)
    sections = if cur, do: sections ++ [cur], else: sections
    if sections == [], do: raise(ParseError, message: "空补丁")
    sections
  end

  defp parse_line(line, {sections, nil}) do
    case String.trim(line) do
      "" -> {sections, nil}
      "[" <> _ = h -> {sections, parse_header(h)}
      _ -> raise ParseError, message: "补丁必须以 [path#tag] 节头开始"
    end
  end

  defp parse_line(line, {sections, cur}) do
    cond do
      String.starts_with?(line, "+") ->
        {sections, add_body(cur, String.replace_prefix(line, "+", ""))}

      String.trim(line) == "" ->
        {sections, cur}

      match = Regex.run(@op_re, String.trim(line)) ->
        [_, op, arg | _] = match
        {sections, add_op(cur, parse_op(op, arg))}

      String.starts_with?(String.trim(line), "[") ->
        {sections ++ [cur], parse_header(String.trim(line))}

      true ->
        raise ParseError, message: "无法识别的行（正文必须以 + 开头）: #{String.trim(line)}"
    end
  end

  defp parse_header(h) do
    case Regex.run(~r/^\[(.+)#([0-9a-f]{12})\]\s*$/, h) do
      [_, path, tag] -> %{path: String.trim(path), tag: tag, ops: []}
      _ -> raise ParseError, message: "节头格式错误: #{String.trim(h)}（应为 [path#12位tag]）"
    end
  end

  defp add_body(%{ops: ops} = cur, content) do
    case Enum.reverse(ops) do
      [{op, m} | rest] when op in [:put, :insert_before, :insert_after] ->
        %{cur | ops: Enum.reverse([{op, Map.update(m, :body, [content], &(&1 ++ [content]))} | rest])}

      _ ->
        raise ParseError, message: "正文行必须紧跟带 : 的 PUT/插入头"
    end
  end

  defp add_op(%{ops: ops} = cur, op), do: %{cur | ops: ops ++ [op]}

  defp parse_op("PUT", arg) do
    case Regex.run(~r/^([<>])(\d+)$/, arg) do
      [_, dir, n] ->
        op = if dir == "<", do: :insert_before, else: :insert_after
        {op, %{at: String.to_integer(n), body: []}}

      nil ->
        case parse_range(arg) do
          {a, b} -> {:put, %{a: a, b: b, body: []}}
        end
    end
  end

  defp parse_op("CUT", arg) do
    {a, b} = parse_range(arg)
    {:cut, %{a: a, b: b}}
  end

  defp parse_range(s) do
    case Regex.run(@range_re, s) do
      [_, a] -> {String.to_integer(a), String.to_integer(a)}
      [_, a, b] -> {String.to_integer(a), String.to_integer(b)}
      nil -> raise ParseError, message: "范围格式错误: #{s}（应为 N 或 N..M）"
    end
  end

  # ── 预检与候选 ──

  defp plan_section(%{path: path, tag: tag, ops: ops}) do
    snap =
      SnapshotStore.fetch(path, tag) ||
        raise RejectError, message: "未知快照标签 #{tag}（请先 show）", category: :unknown_snapshot

    current = File.read!(path)

    if current != snap.text do
      raise RejectError,
        message: "文件已变化（stale）：#{path} 与快照 #{tag} 不一致，未写入。请重新 show 后基于新标签提交",
        category: :stale_conflict
    end

    lines = split_lines(snap.text) |> elem(0)
    total = length(lines)
    check_bounds!(ops, total)
    check_seen!(ops, snap)
    check_overlap!(ops)

    new_lines = build_lines(ops, lines)
    new_content = join_lines(new_lines, snap.has_trailing)

    extent = changed_extent(ops)

    %{
      path: path,
      tag: tag,
      old_lines: lines,
      old_content: snap.text,
      new_content: new_content,
      new_tag: SnapshotStore.promote(path, new_content),
      changed_lines: extent,
      diff: Newbee.Diff.lines(snap.text, new_content) |> Enum.join("\n"),
      context: context_after(new_lines, extent)
    }
  end

  defp check_bounds!(ops, total) do
    Enum.each(ops, fn {op, m} ->
      {lo, hi} =
        case op do
          :insert_before -> {m.at, m.at}
          :insert_after -> {m.at, m.at}
          _ -> {m.a, m.b}
        end

      if lo < 1 or lo > hi or hi > total do
        raise RejectError, message: "行号越界: #{lo}..#{hi}（快照共 #{total} 行）", category: :out_of_bounds
      end
    end)
  end

  defp check_seen!(ops, snap) do
    seen = snap.seen

    if MapSet.size(seen) > 0 do
      Enum.each(ops, fn {op, m} ->
        range =
          case op do
            :insert_before -> [m.at]
            :insert_after -> [m.at]
            _ -> Enum.to_list(m.a..m.b//1)
          end

        unseen = Enum.filter(range, &(not MapSet.member?(seen, &1)))

        if unseen != [] do
          raise RejectError,
            message: "行未读取: #{Enum.take(unseen, 5) |> Enum.join(",")}（请先 show 对应范围）",
            category: :unseen_range
        end
      end)
    end
  end

  defp check_overlap!(ops) do
    ops
    |> Enum.filter(fn {op, _} -> op in [:put, :cut] end)
    |> Enum.map(fn {_, m} -> {m.a, m.b} end)
    |> Enum.sort()
    |> Enum.reduce({nil, nil}, fn {a, b}, {pa, pb} ->
      if pa != nil and a <= pb do
        raise RejectError, message: "范围重叠: #{pa}..#{pb} 与 #{a}..#{b}", category: :overlap
      end

      {a, b}
    end)

    :ok
  end

  defp check_no_op!(plan) do
    if plan.new_content == File.read!(plan.path) do
      raise RejectError, message: "no-op：补丁结果与当前内容一致", category: :no_op
    end
  end

  # 原快照坐标单遍展开：删除/替换吞区间，插入挂边界行；尾部插入挂 total+1
  defp build_lines(ops, lines) do
    # 删除/替换区间展开成逐行集合；插入挂边界行；尾部插入挂 total+1
    del_set =
      ops
      |> Enum.filter(fn {op, _} -> op in [:put, :cut] end)
      |> Enum.flat_map(fn {_, m} -> Enum.to_list(m.a..m.b//1) end)
      |> MapSet.new()

    replaces =
      Map.new(ops |> Enum.filter(&(&1 |> elem(0) == :put)) |> Enum.map(fn {_, m} -> {m.a, m.body} end))

    ins_before =
      Map.new(ops |> Enum.filter(&(&1 |> elem(0) == :insert_before)) |> Enum.map(fn {_, m} -> {m.at, m.body} end))

    ins_after =
      Map.new(ops |> Enum.filter(&(&1 |> elem(0) == :insert_after)) |> Enum.map(fn {_, m} -> {m.at, m.body} end))

    total = length(lines)

    body =
      Enum.flat_map(1..total//1, fn n ->
        cond do
          MapSet.member?(del_set, n) ->
            if Map.has_key?(replaces, n), do: Map.fetch!(replaces, n), else: []

          true ->
            Enum.reverse(Map.get(ins_before, n, [])) ++
              [Enum.at(lines, n - 1)] ++
              Map.get(ins_after, n, [])
        end
      end)

    body ++ Map.get(ins_after, total + 1, [])
  end

  defp changed_extent(ops) do
    pos = Enum.flat_map(ops, fn {op, m} -> if op in [:insert_before, :insert_after], do: [m.at], else: [m.a, m.b] end)
    {Enum.min(pos), Enum.max(pos)}
  end

  defp context_after(new_lines, {lo, hi}) do
    new_lines
    |> Enum.with_index(1)
    |> Enum.filter(fn {_, n} -> n >= max(1, lo - 2) and n <= min(length(new_lines), hi + 2) end)
    |> Enum.map(fn {l, n} -> "#{n}| #{l}" end)
    |> Enum.join("\n")
  end

  defp write_section(plan) do
    File.write!(plan.path, plan.new_content)

    Newbee.Host.emit(
      :file_diff,
      {:file_diff, plan.path, Enum.join(Newbee.Diff.lines(plan.old_content, plan.new_content), "\n"),
       Newbee.Diff.stats(plan.old_content, plan.new_content)}
    )
  end

  defp split_lines(content) do
    has_trailing = String.ends_with?(content, "\n")
    lines = String.split(content, "\n", trim: false)
    lines = if has_trailing and lines != [], do: Enum.drop(lines, -1), else: lines
    {lines, has_trailing}
  end

  defp join_lines(lines, has_trailing) do
    base = Enum.join(lines, "\n")
    if has_trailing and lines != [], do: base <> "\n", else: base
  end

  defp seen_range(start, count), do: start..(start + count - 1)//1
end
