defmodule Newbee.Tools.Edit do
  @moduledoc """
  哈希锚点编辑 (DESIGN §3.2 文本轨) ⭐：
  `show/2` 给每行生成 `N#hash` 锚点（MD5 前 4 字节，8 位 hex），
  `patch/1` 按**锚点对**（目标行 + 相邻上下文行）定位补丁。

  - **行号只是提示**：数错行按 hash 自动重定位（警告），数错且对不上整体拒绝；
  - **上下文必填**（单行/空文件除外），空行/重复行靠锚点对消歧（show 标记 `[dup:...]`）；
  - **快照 tag 过期只警告**（锚点对才是新鲜度检查），照常应用；
  - **原子**：多节补丁全部验证通过才统一落盘。
  - **哈希统一**：所有行哈希基于 `clean_line` 后（去 `\\r` 与尾空格），标记 `⟪cr⟫`/`⟪trail⟫` 仅展示用。

  补丁语法（节头 + 操作，锚点必须来自最近一次 show）：

      [lib/foo.ex#9F2C3A1B]
      PUT 3.#a1b2|2.#c3d4:      # 用 + 行替换第 3 行（上下文第 2 行）
      +newline
      PUT <2.#a1b2|1.#c3d4:     # 在第 2 行前插入
      +head
      CUT 8.#e5f6|7.#g7h8       # 删除第 8 行
      PUT 2.#a1b2=4.#c3d4:      # 范围替换 2..4 行

  内容行以 `+` 开头（`++` 转义字面 `+` 开头的行）。

  """

  @line_re ~r/^(PUT|CUT)\s+(.+?)(:)?$/
  @anchor_re ~r/^(\d+)\.#([0-9a-f]{8})$/

  defmodule ParseError do
    defexception [:message]
  end

  defmodule AnchorError do
    defexception [:message]
  end

  # ── 读 ──

  @doc """
  带锚点显示文件。返回 %{tag, path, text, lines}。
  tag 是全文件快照哈希（8 位 hex）。标记：
    `[dup:n,m]`  hash 与其它行重复（空行等）
    `⟪trail⟫`   行尾空白
    `⟪cr⟫`      CRLF 行（\r 已剥离）
  尾换行不产生幻影空行。
  """
  def show(path, range \\ :all) do
    content = File.read!(path)
    {lines, _has_trailing} = split_lines(content)

    lines =
      case range do
        :all -> lines
        {a, b} -> Enum.slice(lines, (a - 1)..(b - 1)//1)
      end

    start =
      case range do
        :all -> 1
        {a, _} -> a
      end

    # 行 hash -> 行号组（dup 标记用；与 show_line 的 clean 一致）
    by_hash =
      lines
      |> Enum.with_index(start)
      |> Enum.group_by(fn {line, _n} -> line |> clean_line() |> elem(0) |> line_hash() end, fn {_line, n} -> n end)

    text =
      lines
      |> Enum.with_index(start)
      |> Enum.map(fn {line, n} -> show_line(line, n, by_hash) end)
      |> Enum.join("\n")

    %{tag: file_tag(content), path: path, text: text, lines: length(lines)}
  end

  defp show_line(line, n, by_hash) do
    {clean, marks} = clean_line(line)
    h = line_hash(clean)

    dup =
      case Map.get(by_hash, h) do
        [one] when one == n -> ""
        group -> "[dup:" <> Enum.join(group, ",") <> "]"
      end

    "#{n}##{h}#{dup}| #{clean}#{marks}"
  end

  # ── 改 ──

  @doc """
  应用锚点补丁。成功返回 %{applied, paths, warnings}。
  快照 tag 过期只警告不拒绝（锚点对才是新鲜度检查）；
  锚点不匹配抛 AnchorError；格式错误抛 ParseError。
  多节补丁全部验证通过才统一落盘（原子）。
  """
  def patch(patch_text) do
    sections = parse_sections(patch_text)

    {warnings, writes} =
      Enum.reduce(sections, {[], []}, fn section, {warns, acc} ->
        {new_content, sec_warns} = prepare_section(section)
        {warns ++ sec_warns, acc ++ [{section.path, new_content}]}
      end)

    Enum.each(writes, fn {path, content} ->
      old = if File.exists?(path), do: File.read!(path), else: ""
      File.write!(path, content)
      # 内联 diff 事件（§5.1）：节点上经 Host 代理回主 VM 总线
      if old != content do
        Newbee.Host.emit(
          :file_diff,
          {:file_diff, path, Enum.join(Newbee.Diff.lines(old, content), "\n"), Newbee.Diff.stats(old, content)}
        )
      end
    end)

    %{applied: length(sections), paths: Enum.map(sections, & &1.path), warnings: warnings}
  end

  # ── 解析 ──

  defp parse_sections(text) do
    {sections, cur} =
      text
      |> String.split("\n")
      |> Enum.reduce({[], nil}, &parse_line(&1, &2))

    sections = if cur, do: sections ++ [cur], else: sections

    # 同文件两个节头 → 拒绝
    paths = Enum.map(sections, & &1.path)

    if length(paths) != length(Enum.uniq(paths)) do
      raise ParseError, message: "同一补丁内同文件只能出现一个节头"
    end

    sections
  end

  defp parse_line(line, {sections, nil}) do
    case String.trim(line) do
      "" ->
        {sections, nil}

      "[" <> _ = header ->
        {sections, parse_header(header)}

      _ ->
        raise ParseError, message: "补丁必须以节头 [path#tag] 开头，或内容行以 + 开头"
    end
  end

  defp parse_line(line, {sections, cur}) do
    cond do
      String.starts_with?(line, "+") ->
        # 只剥一层：+x → x；++x → +x（字面 + 开头的行）
        content = String.replace_prefix(line, "+", "")
        {sections, put_in_ops(cur, content)}

      String.trim(line) == "" ->
        {sections, cur}

      match = Regex.run(@line_re, line) ->
        [_, op, arg | _] = match
        {sections, put_op(cur, parse_op(op, arg))}

      # 新节头
      String.starts_with?(String.trim(line), "[") ->
        {sections ++ [cur], parse_header(String.trim(line))}

      true ->
        raise ParseError,
          message:
            "内容行必须以 + 开头（第 #{length(cur.ops) + 1} 个操作附近）；" <>
              "若这是新节头请检查 [path#tag] 格式"
    end
  end

  defp parse_header(header) do
    case Regex.run(~r/^\[(.+)#([0-9a-f]{8})\]\s*$/, header) do
      [_, path, tag] -> %{path: String.trim(path), tag: String.trim(tag), ops: []}
      _ -> raise ParseError, message: "节头格式错误: #{header}（应为 [path#8位hash]）"
    end
  end

  # op 行进入 cur（ops 列表）
  defp put_op(cur, op) do
    %{cur | ops: cur.ops ++ [op]}
  end

  defp put_in_ops(%{ops: ops} = cur, new) do
    %{
      cur
      | ops:
          List.update_at(ops, -1, fn
            {:replace, a, b, lines, {h, ctx, hb, ctx_b}} -> {:replace, a, b, lines ++ [new], {h, ctx, hb, ctx_b}}
            {:insert_before, n, lines, h, ctx} -> {:insert_before, n, lines ++ [new], h, ctx}
            {:insert_after, n, lines, h, ctx} -> {:insert_after, n, lines ++ [new], h, ctx}
            {:delete, a, b, {h, ctx, hb, ctx_b}} -> {:delete, a, b, {h, ctx, hb, ctx_b}}
            op -> op
          end)
    }
  end

  # 锚点对: N.#h|M.#ch （a 目标, b 上下文；必须相邻）
  defp parse_anchor_pair(s) do
    case String.split(s, "|", parts: 2) do
      [a] ->
        case Regex.run(@anchor_re, a) do
          [_, n, h] -> {String.to_integer(n), h, nil}
          _ -> raise ParseError, message: "锚点格式错误: " <> a <> "（应为 行号.#8位hash，如 3.#a1b2c3d4，注意点号后必须跟井号）"
        end

      [a, b] ->
        {na, ha} = parse_single_anchor(a)
        {nb, hb} = parse_single_anchor(b)

        if abs(na - nb) != 1 do
          raise ParseError, message: "上下文锚点必须与目标行相邻（当前 |#{na}-#{nb}|=#{abs(na - nb)}）"
        end

        {na, ha, {nb, hb}}
    end
  end

  defp parse_single_anchor(s) do
    case Regex.run(@anchor_re, s) do
      [_, n, h] -> {String.to_integer(n), h}
      _ -> raise ParseError, message: "锚点格式错误: #{s}（应为 N.#8位hash）"
    end
  end

  defp parse_op("PUT", arg) do
    {op, _rest} =
      case arg do
        "<" <> rest ->
          {n, h, ctx} = parse_anchor_pair(rest)
          {{:insert_before, n, [], h, ctx}, :ok}

        ">" <> rest ->
          {n, h, ctx} = parse_anchor_pair(rest)
          {{:insert_after, n, [], h, ctx}, :ok}

        _ ->
          case String.split(arg, "=", parts: 2) do
            [a, b] ->
              {na, ha, ctx_a} = parse_anchor_pair(a)
              {nb, hb, ctx_b} = parse_anchor_pair(b)
              {{:replace, na, nb, [], {ha, ctx_a, hb, ctx_b}}, :ok}

            [a] ->
              {n, h, ctx} = parse_anchor_pair(a)
              {{:replace, n, n, [], {h, ctx, nil, nil}}, :ok}
          end
      end

    op
  end

  defp parse_op("CUT", arg) do
    case String.split(arg, "=", parts: 2) do
      [a, b] ->
        {na, ha, ctx_a} = parse_anchor_pair(a)
        {nb, hb, ctx_b} = parse_anchor_pair(b)
        {:delete, na, nb, {ha, ctx_a, hb, ctx_b}}

      [a] ->
        {n, h, ctx} = parse_anchor_pair(a)
        {:delete, n, n, {h, ctx, nil, nil}}
    end
  end

  # ── 应用 ──

  defp prepare_section(%{path: path, tag: tag, ops: ops}) do
    content = File.read!(path)
    current_tag = file_tag(content)

    warnings =
      if current_tag != tag do
        ["快照过期: #{path} (期望 #{tag}, 实际 #{current_tag})——锚点对仍生效，已照常应用"]
      else
        []
      end

    {lines, has_trailing} = split_lines(content)

    # 上下文缺失检查（>1 行文件必填上下文）
    Enum.each(ops, fn op ->
      ctx = op_ctx(op)

      if ctx == nil and length(lines) > 1 do
        raise ParseError, message: "缺少上下文锚点（PUT N.#hash|M.#ch）——上下文对用于消歧"
      end
    end)

    # 1) 解析目标行号（重定位，hash 为准）并写回 op
    {ops2, warns2} =
      Enum.map_reduce(ops, [], fn op, ws ->
        {op2, w} = resolve_op(lines, op)
        {op2, ws ++ w}
      end)

    # 2) 重叠检测（解析后的区间）
    check_overlap!(ops2)

    # 3) 全部验证（基于原文件，通过才允许应用——原子性）
    Enum.each(ops2, fn op -> verify_op!(lines, op) end)

    # 4) 应用：从大到小；同位置插入合并保持补丁顺序
    ops2 = merge_inserts(ops2)

    new_lines =
      ops2
      |> Enum.sort_by(&op_line/1, :desc)
      |> Enum.reduce(lines, fn op, acc -> apply_op(acc, op) end)

    trailing = if has_trailing, do: "\n", else: ""
    {Enum.join(new_lines, "\n") <> trailing, warnings ++ warns2}
  end

  # 重定位并写回 op（目标行号与范围行号都按 hash 解析；
  # 目标重定位时上下文跟随 hash 定位，否则上下文必须在原始行号处精确匹配）
  defp resolve_op(lines, op) do
    case op do
      {:replace, a, b, new, {h, ctx, hb, ctx_b}} ->
        {na, w1} = resolve_target(lines, a, h, ctx)
        ctx2 = follow_ctx(lines, ctx, w1)
        {nb, w2} = resolve_range_end(lines, b, hb, ctx_b, na)
        ctx_b2 = follow_ctx(lines, ctx_b, w2)
        {{:replace, na, nb, new, {h, ctx2, hb, ctx_b2}}, w1 ++ w2}

      {:delete, a, b, {h, ctx, hb, ctx_b}} ->
        {na, w1} = resolve_target(lines, a, h, ctx)
        ctx2 = follow_ctx(lines, ctx, w1)
        {nb, w2} = resolve_range_end(lines, b, hb, ctx_b, na)
        ctx_b2 = follow_ctx(lines, ctx_b, w2)
        {{:delete, na, nb, {h, ctx2, hb, ctx_b2}}, w1 ++ w2}

      {:insert_before, n, new, h, ctx} ->
        {m, w} = resolve_target(lines, n, h, ctx)
        ctx2 = follow_ctx(lines, ctx, w)
        {{:insert_before, m, new, h, ctx2}, w}

      {:insert_after, n, new, h, ctx} ->
        {m, w} = resolve_target(lines, n, h, ctx)
        ctx2 = follow_ctx(lines, ctx, w)
        {{:insert_after, m, new, h, ctx2}, w}
    end
  end

  # 范围结束行号：单行 op（hb=nil）跟随解析后的起点；范围 op 独立按 hash 解析
  defp resolve_range_end(_lines, _b, nil, _ctx_b, na), do: {na, []}
  defp resolve_range_end(lines, b, hb, ctx_b, _na), do: resolve_target(lines, b, hb, ctx_b)

  # 目标重定位（w != []）时：上下文按 hash 定位到实际行
  defp follow_ctx(_lines, ctx, []), do: ctx

  defp follow_ctx(lines, {_cn, ch}, _w) do
    case find_by_hash(lines, ch) do
      [cm] -> {cm, ch}
      [] -> raise AnchorError, message: "锚点不匹配: 上下文 hash ##{ch} 未命中任何行"
      _many -> raise AnchorError, message: "锚点不匹配: 上下文 hash ##{ch} 命中多行，无法消歧"
    end
  end

  defp follow_ctx(_lines, nil, _w), do: nil

  # 同位置同类型插入合并（补丁顺序保持：first + second 落在 first 之后）
  defp merge_inserts(ops) do
    Enum.reduce(ops, [], fn op, out ->
      case {List.last(out), op} do
        {{:insert_before, n1, lines1, h1, ctx1}, {:insert_before, n2, lines2, h2, ctx2}}
        when n1 == n2 and h1 == h2 and ctx1 == ctx2 ->
          List.replace_at(out, -1, {:insert_before, n1, lines1 ++ lines2, h1, ctx1})

        {{:insert_after, n1, lines1, h1, ctx1}, {:insert_after, n2, lines2, h2, ctx2}}
        when n1 == n2 and h1 == h2 and ctx1 == ctx2 ->
          List.replace_at(out, -1, {:insert_after, n1, lines1 ++ lines2, h1, ctx1})

        _ ->
          out ++ [op]
      end
    end)
  end

  # 上下文锚点（可能缺省）
  defp op_ctx({:replace, _, _, _, {_h, ctx, _, _}}), do: ctx
  defp op_ctx({:delete, _, _, {_h, ctx, _, _}}), do: ctx
  defp op_ctx({:insert_before, _, _, _, ctx}), do: ctx
  defp op_ctx({:insert_after, _, _, _, ctx}), do: ctx

  # 目标定位：行号处 hash 匹配直接用；否则按 hash 全文找唯一匹配（重定位 + 警告）
  defp resolve_target(_lines, n, nil, _ctx), do: {n, []}

  defp resolve_target(lines, n, h, ctx) do
    if n < 1 or n > length(lines) do
      raise AnchorError,
        message: "锚点不匹配: 行号 #{n} 超出文件范围（共 #{length(lines)} 行）——请重新 show"
    end

    actual = lines |> Enum.at(n - 1, "") |> clean_hash()

    if actual == h do
      {n, []}
    else
      # 按 hash 找
      case find_by_hash(lines, h) do
        [m] ->
          case ctx do
            nil ->
              {m, ["目标行重定位: 第 #{n} 行 → 第 #{m} 行（hash 为准）"]}

            {_cn, ch} ->
              # 上下文也按 hash 定位，且必须与重定位后的目标相邻
              case find_by_hash(lines, ch) do
                [cm] when abs(m - cm) == 1 ->
                  {m, ["目标行重定位: 第 #{n} 行 → 第 #{m} 行（hash 为准）"]}

                [cm] ->
                  raise AnchorError,
                    message: "锚点不匹配: 重定位后与上下文不相邻（目标 #{m}，上下文 hash 在第 #{cm} 行）"

                [] ->
                  raise AnchorError, message: "锚点不匹配: 上下文 hash ##{ch} 未命中任何行"

                _many ->
                  raise AnchorError, message: "锚点不匹配: 上下文 hash ##{ch} 命中多行，无法消歧"
              end
          end

        [] ->
          raise AnchorError, message: "锚点不匹配: 第 #{n} 行期望 ##{h} 实际 ##{actual}——模型可能数错了行，请重新 show"

        many ->
          raise AnchorError, message: "锚点不匹配: hash ##{h} 命中多行 #{inspect(many)}，无法消歧——请用上下文锚点对"
      end
    end
  end

  defp find_by_hash(lines, h) do
    lines
    |> Enum.with_index(1)
    |> Enum.filter(fn {line, _} -> clean_hash(line) == h end)
    |> Enum.map(&elem(&1, 1))
  end

  # 重叠检测：两个 op 的解析区间相交 → AnchorError（插入 op 不参与——同位置多次插入合法）
  defp check_overlap!(ops) do
    ranges =
      ops
      |> Enum.map(fn op -> {op, {op_line(op), op_end(op)}} end)
      |> Enum.reject(fn {op, _} ->
        match?({:insert_before, _, _, _, _}, op) or match?({:insert_after, _, _, _, _}, op)
      end)
      |> Enum.map(fn {op, {a, b}} -> {op, {min(a, b), max(a, b)}} end)

    Enum.reduce(ranges, [], fn {op, r}, acc ->
      overlap =
        Enum.find(acc, fn {_op2, {a, b}} ->
          not (r |> elem(1) < a or r |> elem(0) > b)
        end)

      if overlap do
        raise AnchorError, message: "重叠区间: #{inspect(r)} 与 #{inspect(elem(overlap, 1))} 相交"
      end

      acc ++ [{op, r}]
    end)

    :ok
  end

  defp op_end({:replace, _a, b, _, _}), do: b
  defp op_end({:delete, _a, b, _}), do: b
  defp op_end({:insert_before, n, _, _, _}), do: n
  defp op_end({:insert_after, n, _, _, _}), do: n

  defp op_line({:replace, a, _, _, _}), do: a
  defp op_line({:delete, a, _, _}), do: a
  defp op_line({:insert_before, n, _, _, _}), do: n
  defp op_line({:insert_after, n, _, _, _}), do: n

  # 全部验证（基于原文件行号——原子性前提）
  defp verify_op!(lines, {:replace, a, b, _, {h, ctx, hb, ctx_b}}) do
    verify_anchor!(lines, a, h)
    verify_ctx!(lines, ctx)
    verify_anchor!(lines, b, hb)
    verify_ctx!(lines, ctx_b)
    :ok
  end

  defp verify_op!(lines, {:delete, a, b, {h, ctx, hb, ctx_b}}) do
    verify_anchor!(lines, a, h)
    verify_ctx!(lines, ctx)
    verify_anchor!(lines, b, hb)
    verify_ctx!(lines, ctx_b)
    :ok
  end

  defp verify_op!(lines, {:insert_before, n, _, h, ctx}) do
    verify_anchor!(lines, n, h)
    verify_ctx!(lines, ctx)
    :ok
  end

  defp verify_op!(lines, {:insert_after, n, _, h, ctx}) do
    verify_anchor!(lines, n, h)
    verify_ctx!(lines, ctx)
    :ok
  end

  # 纯变换（行号已解析且已验证）
  defp apply_op(lines, {:replace, a, b, new, _}), do: Enum.take(lines, a - 1) ++ new ++ Enum.drop(lines, b)
  defp apply_op(lines, {:delete, a, b, _}), do: Enum.take(lines, a - 1) ++ Enum.drop(lines, b)
  defp apply_op(lines, {:insert_before, n, new, _, _}), do: Enum.take(lines, n - 1) ++ new ++ Enum.drop(lines, n - 1)
  defp apply_op(lines, {:insert_after, n, new, _, _}), do: Enum.take(lines, n) ++ new ++ Enum.drop(lines, n)

  # 上下文 hash 校验（行号处必须精确匹配，不重定位；与 show 的 clean 语义一致）
  defp verify_ctx!(_lines, nil), do: :ok

  defp verify_ctx!(lines, {cn, ch}) do
    actual = lines |> Enum.at(cn - 1, "") |> clean_hash()

    if actual != ch do
      raise AnchorError,
        message: "锚点不匹配: 上下文第 #{cn} 行期望 ##{ch} 实际 ##{actual}——请重新 show"
    end
  end

  defp verify_anchor!(_lines, _n, nil), do: :ok

  defp verify_anchor!(lines, n, expected) do
    actual = lines |> Enum.at(n - 1, "") |> clean_hash()

    if actual != expected do
      raise AnchorError,
        message: "锚点不匹配: 第 #{n} 行期望 ##{expected} 实际 ##{actual}——模型可能数错了行，请重新 show"
    end
  end

  defp clean_hash(line), do: line |> clean_line() |> elem(0) |> line_hash()

  # ── 行/哈希 ──

  # 行清洗：CRLF 行去 \r 标 ⟪cr⟫；行尾空白标 ⟪trail⟫ 并去除
  defp clean_line(line) do
    {clean, marks} =
      if String.ends_with?(line, "\r") do
        {String.trim_trailing(line, "\r"), " ⟪cr⟫"}
      else
        {line, ""}
      end

    if Regex.match?(~r/\s$/, clean) do
      {String.trim_trailing(clean), marks <> " ⟪trail⟫"}
    else
      {clean, marks}
    end
  end

  # 保留尾换行状态；不产生幻影空行
  defp split_lines(content) do
    has_trailing = String.ends_with?(content, "\n")
    lines = String.split(content, "\n", trim: false)
    lines = if has_trailing and lines != [], do: Enum.drop(lines, -1), else: lines
    {lines, has_trailing}
  end

  defp file_tag(content), do: hash8(content)
  defp line_hash(line), do: hash8(line)

  # MD5 前 4 字节 = 8 位 hex（DESIGN §3.2）
  defp hash8(s) do
    :crypto.hash(:md5, s) |> binary_part(0, 4) |> Base.encode16(case: :lower)
  end
end
