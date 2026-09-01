defmodule Newbee.Tools.Edit do
  @moduledoc """
  唯一公开文本补丁工具（docs/edit-design.md §4.2/§5）：快照标签 + 原始行范围 + 最终内容。

      [path#tag]
      PUT N..M:      用 + 正文替换原快照 N..M 行（含端点）
      PUT <N:        在第 N 行前插入
      PUT >N:        在第 N 行后插入
      CUT N..M       删除 N..M 行

  行号全部指向原快照；stale/越界/未读/重叠/no-op 一律拒绝；
  多节全部预检通过才落盘（逻辑原子）。

  生成含插值、sigil 或 heredoc 的 Elixir 源码时，先用 `source_literal/1` 包装目标文本。

  ## 函数清单
  - `show(path, range \\\\ :all) :: %{tag: String.t(), text: String.t(), lines: non_neg_integer()}` — 读取全文或 `{first, last}` 范围并记录快照；默认参数使 `show/1` 与 `show/2` 都可调用。
  - `patch(patch_text) :: %{status: :applied, files: [map()], warnings: list()}` — 应用 `[path#tag]` 行号补丁；解析失败抛 `ParseError`，预检拒绝抛带 `category` 的 `RejectError`。
  - `source_literal(text) :: String.t()` — 把任意文本包装成安全 Elixir 字符串表达式，避免二阶插值和 heredoc/sigil 分隔符冲突。

  ## 可跑示例
      snapshot = Newbee.Tools.Edit.show("README.md", {1, 20})
      snapshot = Newbee.Tools.Edit.show("README.md", [1, 20])
        snapshot = Newbee.Tools.Edit.show("README.md", 1..20)
        snapshot = Newbee.Tools.Edit.show("README.md", %{first: 1, last: 20})
        snapshot = Newbee.Tools.Edit.show(%{path: "README.md", range: {1, 20}})
      # patch_text 的节头使用 snapshot.tag；PUT/CUT 行号来自 snapshot.text
      result = Newbee.Tools.Edit.patch(patch_text)
        result = Newbee.Tools.Edit.patch(%{patch: patch_text})
      literal = Newbee.Tools.Edit.source_literal(source_code)
    # 结构化入口：edits 列表 / 单操作简写 / 键名宽容
    result = Newbee.Tools.Edit.patch(%{
      path: "lib/demo.ex",
      tag: snapshot.tag,
      edits: [
        %{op: :replace, range: 10..12, content: "  def hello(name), do: {:ok, name}"},
        %{op: :insert_before, line: 5, content: "  @moduledoc false"},
        %{op: :delete, range: [30, 31]}
      ]
    })
    # 单操作简写（op/from/to/text；path/file；tag/snapshot/ops/changes 均兼容）
    result = Newbee.Tools.Edit.patch(%{file: "lib/demo.ex", snapshot: snapshot.tag, op: "replace", from: 2, to: 2, text: "B"})
    # Base64 宽松入口
    base64 = Base.encode64(patch_text)
    result = Newbee.Tools.Edit.patch(%{base64: base64})
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
  # ── 结构化输入归一 ──

  @doc """
  结构化补丁入口。除文本 DSL 外，还接受：
    %{path: p, tag: t, edits: [...]}       单文件、edits 列表
    %{file: p, snapshot: t, ops: [...]}    键名宽容
    %{path: p, tag: t, op: :replace, from: a, to: b, text: body}   单操作简写
    %{path: p, tag: t, delete: [a, b]}     删除简写
    %{path: p, tag: t, before: n, text: body}  前插简写
    %{path: p, tag: t, after: n, text: body}   后插简写
    [%{path: p1, ...}, %{path: p2, ...}]   多文件
    %{files: [...]}                        多文件包
  同一路径且 tag 相同时自动合并 edits；同一路径 tag 不同返回冲突。
  """

  def patch(%{base64: b}) when is_binary(b), do: patch_base64_decoded(b)
  def patch(%{"base64" => b}) when is_binary(b), do: patch_base64_decoded(b)

  defp patch_base64_decoded(base64) do
    case Base.decode64(String.trim(base64)) do
      {:ok, text} -> patch(text)
      :error -> raise ParseError, message: "invalid base64 patch"
    end
  end

  def patch(%{files: files}) when is_list(files), do: patch_files(files)
  def patch(%{"files" => files}) when is_list(files), do: patch_files(files)

  def patch(%{file: p} = opts) when is_binary(p) and is_map(opts) do
    file = normalize_file_map(opts)
    patch_files([file])
  end

  def patch(%{"file" => p} = opts) when is_binary(p) and is_map(opts) do
    file = normalize_file_map(opts)
    patch_files([file])
  end

  def patch(%{path: p} = opts) when is_binary(p) and is_map(opts) do
    file = normalize_file_map(opts)
    patch_files([file])
  end

  def patch(%{"path" => p} = opts) when is_binary(p) and is_map(opts) do
    file = normalize_file_map(opts)
    patch_files([file])
  end

  def patch(list) when is_list(list) do
    patch_files(list)
  end

  defp patch_files(files) do
    files = Enum.map(files, &normalize_file_map/1)
    merged = merge_files(files)
    sections = Enum.map(merged, &file_to_section/1)
    check_duplicate_paths!(sections)
    plans = Enum.map(sections, &plan_section/1)
    Enum.each(plans, &check_no_op!/1)
    :ok = write_plans_atomic(plans)
    plans = Enum.map(plans, fn plan -> %{plan | new_tag: SnapshotStore.promote(plan.path, plan.new_content)} end)

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

  defp normalize_file_map(map) when is_map(map) do
    path = fetch_key(map, [:path, :file]) || fetch_key(map, ["path", "file"])
    tag = fetch_key(map, [:tag, :snapshot, :id]) || fetch_key(map, ["tag", "snapshot", "id"])

    cond do
      is_nil(path) ->
        raise ParseError, message: "结构化补丁缺少 path/file"

      is_nil(tag) ->
        raise ParseError, message: "结构化补丁缺少 tag/snapshot"

      fetch_key(map, [:edits, :ops, :changes]) || fetch_key(map, ["edits", "ops", "changes"]) ->
        edits = fetch_key(map, [:edits, :ops, :changes]) || fetch_key(map, ["edits", "ops", "changes"])
        %{path: path, tag: tag, edits: List.wrap(edits)}

      true ->
        %{path: path, tag: tag, edits: [normalize_single_edit(map)]}
    end
  end

  defp normalize_single_edit(opts) do
    cond do
      op = fetch_key(opts, [:op, :operation]) || fetch_key(opts, ["op", "operation"]) ->
        %{
          op: normalize_op_name(op),
          range: normalize_edit_range(opts),
          content: fetch_key(opts, [:text, :content, :new_text]) || fetch_key(opts, ["text", "content", "new_text"]),
          _extra: opts
        }

      ed = fetch_key(opts, [:delete, :remove]) || fetch_key(opts, ["delete", "remove"]) ->
        %{op: :delete, range: normalize_edit_range(opts, ed), content: nil}

      n = fetch_key(opts, [:before, :insert_before]) || fetch_key(opts, ["before", "insert_before"]) ->
        %{
          op: :insert_before,
          range: {n, n},
          content: fetch_key(opts, [:text, :content, :new_text]) || fetch_key(opts, ["text", "content", "new_text"])
        }

      n = fetch_key(opts, [:after, :insert_after]) || fetch_key(opts, ["after", "insert_after"]) ->
        %{
          op: :insert_after,
          range: {n, n},
          content: fetch_key(opts, [:text, :content, :new_text]) || fetch_key(opts, ["text", "content", "new_text"])
        }

      true ->
        raise ParseError, message: "无法识别的结构化编辑（需要 op/delete/before/after）"
    end
  end

  defp normalize_op_name(op) when op in [:replace, :put, "replace", "put"], do: :replace
  defp normalize_op_name(op) when op in [:delete, :cut, :remove, "delete", "cut", "remove"], do: :delete
  defp normalize_op_name(op) when op in [:insert_before, :before, "insert_before", "before"], do: :insert_before
  defp normalize_op_name(op) when op in [:insert_after, :after, "insert_after", "after"], do: :insert_after
  defp normalize_op_name(other), do: raise(ParseError, message: "未知操作: #{inspect(other)}")

  defp normalize_edit_range(opts, fallback \\ nil) do
    range =
      fetch_key(opts, [:range, :lines]) || fetch_key(opts, ["range", "lines"]) ||
        single_range_from_keys(opts) || fallback

    normalize_show_range(range)
  end

  defp single_range_from_keys(opts) do
    from = fetch_key(opts, [:from, :first, :a, :start]) || fetch_key(opts, ["from", "first", "a", "start"])
    to = fetch_key(opts, [:to, :last, :b, :end]) || fetch_key(opts, ["to", "last", "b", "end"])

    cond do
      is_integer(from) and is_integer(to) -> {from, to}
      is_integer(from) -> {from, from}
      is_integer(fetch_key(opts, [:line, :at])) -> {fetch_key(opts, [:line, :at]), fetch_key(opts, [:line, :at])}
      true -> nil
    end
  end

  defp fetch_key(map, keys) do
    Enum.find_value(keys, fn k ->
      case Map.fetch(map, k) do
        {:ok, v} -> v
        :error -> nil
      end
    end)
  end

  defp merge_files(files) do
    files
    |> Enum.group_by(&{&1.path, &1.tag})
    |> Enum.map(fn {{path, tag}, group} ->
      %{path: path, tag: tag, edits: Enum.flat_map(group, & &1.edits)}
    end)
  end

  defp file_to_section(%{path: path, tag: tag, edits: edits}) do
    ops = Enum.map(edits, fn edit -> edit |> normalize_single_edit() |> edit_to_op() end)
    %{path: path, tag: tag, ops: ops}
  end

  defp edit_to_op(%{op: return_op, range: raw_range, content: body}) do
    range = normalize_show_range(raw_range)
    op = norm_op(return_op)
    lines = content_lines(body)

    case {op, range} do
      {:replace, {a, b}} ->
        require_body!(op, body)
        {:put, %{a: a, b: b, body: lines}}

      {:delete, {a, b}} ->
        {:cut, %{a: a, b: b}}

      {:insert_before, {n, n}} ->
        require_body!(op, body)
        {:insert_before, %{at: n, body: lines}}

      {:insert_after, {n, n}} ->
        require_body!(op, body)
        {:insert_after, %{at: n, body: lines}}

      {op, _} ->
        raise ParseError, message: "操作 #{op} 的 range 不合法: #{inspect(raw_range)}，插入必须单行"
    end
  end

  defp content_lines(nil), do: nil
  defp content_lines(""), do: nil
  defp content_lines(body), do: String.split(body, "\n")

  defp require_body!(op, nil), do: raise(ParseError, message: "操作 #{inspect(op)} 缺少正文 text/content")
  defp require_body!(_op, _body), do: :ok

  defp norm_op(op) when op in [:replace, :put, "replace", "put"], do: :replace
  defp norm_op(op) when op in [:delete, :cut, :remove, "delete", "cut", "remove"], do: :delete
  defp norm_op(op) when op in [:insert_before, :before, "insert_before", "before"], do: :insert_before
  defp norm_op(op) when op in [:insert_after, :after, "insert_after", "after"], do: :insert_after
  defp norm_op(other), do: raise(ParseError, message: "未知操作: #{inspect(other)}")

  @doc "应用行号补丁，成功返回 %{status: :applied, files: [...]}。patch_text 宽容：binary | %{patch: text} | %{text: text} | %{patch_text: text}"

  def patch(patch_text) when is_binary(patch_text) do
    sections = parse(patch_text)
    check_duplicate_paths!(sections)
    plans = Enum.map(sections, &plan_section/1)
    Enum.each(plans, &check_no_op!/1)
    :ok = write_plans_atomic(plans)
    plans = Enum.map(plans, fn plan -> %{plan | new_tag: SnapshotStore.promote(plan.path, plan.new_content)} end)

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

  @doc "读取文件并记录快照，返回 %{tag, text, lines}。range 宽容：:all | {a,b} | [a,b] | a..b | %{first: a, last: b} | \"a..b\" | a"
  def show(path, range \\ :all)

  def show(%{path: p} = opts, _range) when is_binary(p) do
    r = Map.get(opts, :range) || Map.get(opts, "range") || Map.get(opts, :__range__) || :all
    show(p, r)
  end

  def show(%{"path" => p} = opts, _range) when is_binary(p) do
    r = Map.get(opts, "range") || Map.get(opts, :range) || :all
    show(p, r)
  end

  def show(path, range) when is_binary(path) do
    show_range(path, normalize_show_range(range))
  end

  def show(path, range) when is_atom(path) do
    show(to_string(path), range)
  end

  defp normalize_show_range(:all), do: :all
  defp normalize_show_range(nil), do: :all
  defp normalize_show_range(""), do: :all
  defp normalize_show_range(:full), do: :all
  defp normalize_show_range({a, b}) when is_integer(a) and is_integer(b), do: {a, b}
  defp normalize_show_range([a, b]) when is_integer(a) and is_integer(b), do: {a, b}
  defp normalize_show_range([a]) when is_integer(a), do: {a, a}
  defp normalize_show_range(%Range{first: f, last: l}), do: {min(f, l), max(f, l)}
  defp normalize_show_range(%{first: f, last: l}) when is_integer(f) and is_integer(l), do: {f, l}
  defp normalize_show_range(%{"first" => f, "last" => l}) when is_integer(f) and is_integer(l), do: {f, l}
  defp normalize_show_range(%{start: s, end: e}) when is_integer(s) and is_integer(e), do: {s, e}
  defp normalize_show_range(%{"start" => s, "end" => e}) when is_integer(s) and is_integer(e), do: {s, e}
  defp normalize_show_range(%{a: a, b: b}) when is_integer(a) and is_integer(b), do: {a, b}
  defp normalize_show_range(%{"a" => a, "b" => b}) when is_integer(a) and is_integer(b), do: {a, b}
  defp normalize_show_range(a) when is_integer(a), do: {a, a}

  defp normalize_show_range(s) when is_binary(s) do
    t = String.trim(s)

    cond do
      t == "" or t == "all" ->
        :all

      Regex.match?(~r/^\d+\.\.\d+$/, t) ->
        t |> String.split("..") |> then(fn [a, b] -> {String.to_integer(a), String.to_integer(b)} end)

      Regex.match?(~r/^\d+-\d+$/, t) ->
        t |> String.split("-") |> then(fn [a, b] -> {String.to_integer(a), String.to_integer(b)} end)

      Regex.match?(~r/^\d+,\d+$/, t) ->
        t
        |> String.split(",")
        |> then(fn [a, b] -> {String.to_integer(String.trim(a)), String.to_integer(String.trim(b))} end)

      Regex.match?(~r/^\d+$/, t) ->
        {String.to_integer(t), String.to_integer(t)}

      true ->
        :all
    end
  end

  defp normalize_show_range(other) when is_list(other) do
    f = Keyword.get(other, :first) || Keyword.get(other, :start) || Keyword.get(other, :a)
    l = Keyword.get(other, :last) || Keyword.get(other, :end) || Keyword.get(other, :b)
    if is_integer(f) and is_integer(l), do: {f, l}, else: :all
  end

  defp normalize_show_range(_), do: :all

  defp show_range(path, range) do
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
      new_tag: nil,
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

  defp check_duplicate_paths!(sections) do
    paths = Enum.map(sections, & &1.path)

    if length(paths) != length(Enum.uniq(paths)) do
      raise RejectError,
        message: "补丁不能重复修改同一路径；请合并为一个节",
        category: :duplicate_path
    end
  end

  defp write_plans_atomic(plans) do
    entries =
      Enum.map(plans, fn plan ->
        nonce = Integer.to_string(System.unique_integer([:positive]))

        %{
          plan: plan,
          temp: plan.path <> ".newbee-edit-tmp-" <> nonce,
          backup: plan.path <> ".newbee-edit-backup-" <> nonce
        }
      end)

    try do
      Enum.each(entries, fn %{plan: plan, temp: temp} ->
        File.write!(temp, plan.new_content)
      end)

      case Enum.reduce_while(entries, [], fn %{plan: plan, temp: temp, backup: backup} = entry, moved ->
             with :ok <- File.rename(plan.path, backup),
                  :ok <- File.rename(temp, plan.path) do
               {:cont, [entry | moved]}
             else
               {:error, reason} ->
                 rollback_entries([entry | moved])
                 {:halt, {:error, plan.path, reason}}
             end
           end) do
        {:error, failed_path, reason} ->
          raise RejectError,
            message: "无法原子替换 #{failed_path}: #{inspect(reason)}",
            category: :edit_write_failed

        _moved ->
          :ok
      end

      Enum.each(entries, fn %{plan: plan} ->
        Newbee.Host.emit(
          :file_diff,
          {:file_diff, plan.path, Enum.join(Newbee.Diff.lines(plan.old_content, plan.new_content), "\n"),
           Newbee.Diff.stats(plan.old_content, plan.new_content)}
        )
      end)
    rescue
      error ->
        rollback_entries(entries)
        reraise error, __STACKTRACE__
    after
      Enum.each(entries, fn %{temp: temp, backup: backup} ->
        File.rm(temp)
        File.rm(backup)
      end)
    end
  end

  defp rollback_entries(entries) do
    Enum.each(Enum.reverse(entries), fn %{plan: plan, temp: temp, backup: backup} ->
      File.rm(plan.path)

      if File.exists?(backup), do: File.rename(backup, plan.path)
      File.rm(temp)
    end)
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
            Map.get(ins_before, n, []) ++
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
