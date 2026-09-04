defmodule Newbee.Tools.Edit do
  @moduledoc """
  Text patches (docs/edit-design.md): snapshot tag + line range + final content.

      [path#tag]
      PUT N..M:      replace snapshot lines N..M (inclusive) with + body
      PUT <N:        insert before line N
      PUT >N:        insert after line N
      CUT N..M       delete lines N..M

  Line numbers always point at the original snapshot; stale/out-of-bounds/unseen/overlap/no-op edits are all rejected;
  multi-section patches land on disk only after every section pre-checks (logically atomic).

  When generating Elixir source with interpolation, sigils, or heredocs, wrap the target text with `source_literal/1` first.

  ## Functions
  - `show(path, range \\\\ :all) :: %{tag: String.t(), text: String.t(), lines: non_neg_integer()}` — read the whole file or a `{first, last}` range and record a snapshot; defaults make both `show/1` and `show/2` callable.
  - `patch(patch_text) :: %{status: :applied, files: [map()], warnings: list()}` — apply a `[path#tag]` line patch; parse failures raise `ParseError`, pre-check rejections raise `RejectError` with a `category`.
  - `source_literal(text) :: String.t()` — wrap any text as a safe Elixir literal, dodging second-order interpolation and heredoc/sigil delimiter clashes.

  ## Runnable example
      snapshot = Newbee.Tools.Edit.show("README.md", {1, 20})
      snapshot = Newbee.Tools.Edit.show("README.md", [1, 20])
        snapshot = Newbee.Tools.Edit.show("README.md", 1..20)
        snapshot = Newbee.Tools.Edit.show("README.md", %{first: 1, last: 20})
        snapshot = Newbee.Tools.Edit.show(%{path: "README.md", range: {1, 20}})
      # section headers use snapshot.tag; PUT/CUT line numbers come from snapshot.text
      result = Newbee.Tools.Edit.patch(patch_text)
        result = Newbee.Tools.Edit.patch(%{patch: patch_text})
      literal = Newbee.Tools.Edit.source_literal(source_code)
    # structured entry: edit lists / single-op shorthand / tolerant keys
    result = Newbee.Tools.Edit.patch(%{
      path: "lib/demo.ex",
      tag: snapshot.tag,
      edits: [
        %{op: :replace, range: 10..12, content: "  def hello(name), do: {:ok, name}"},
        %{op: :insert_before, line: 5, content: "  @moduledoc false"},
        %{op: :delete, range: [30, 31]}
      ]
    })
    # single-op shorthand (op/from/to/text; path/file; tag/snapshot/ops/changes all map)
    result = Newbee.Tools.Edit.patch(%{file: "lib/demo.ex", snapshot: snapshot.tag, op: "replace", from: 2, to: 2, text: "B"})
    # lenient Base64 entry
    base64 = Base.encode64(patch_text)
    result = Newbee.Tools.Edit.patch(%{base64: base64})
  """

  alias Newbee.Tools.Edit.SnapshotStore

  @source_delimiters [{"/", "/"}, {"|", "|"}, {"'", "'"}, {"\"", "\""}, {"(", ")"}, {"[", "]"}, {"{", "}"}, {"<", ">"}]

  @doc "Wrap any text as a safe Elixir literal for splicing straight into run_elixir."
  def source_literal(text) when is_binary(text) do
    case Enum.find(@source_delimiters, fn {open, close} ->
           not String.contains?(text, open) and not String.contains?(text, close)
         end) do
      {open, close} -> "~S" <> open <> text <> close
      nil -> inspect(text)
    end
  end

  defmodule ParseError do
    defexception [:message, :code, :hint, :retry]
  end

  defmodule RejectError do
    defexception [:message, :category]
  end

  @op_re ~r/^(PUT|CUT)\s+(.+?)\s*(:)?$/
  @range_re ~r/^(\d+)(?:\.\.(\d+))?$/
  # ── 结构化输入归一 ──

  @doc """
  Structured patch entry. Besides the text DSL, also takes:
    %{path: p, tag: t, edits: [...]}       one file, edit list
    %{file: p, snapshot: t, ops: [...]}    tolerant keys
    %{path: p, tag: t, op: :replace, from: a, to: b, text: body}   single-op shorthand
    %{path: p, tag: t, delete: [a, b]}     delete shorthand
    %{path: p, tag: t, before: n, text: body}  insert-before shorthand
    %{path: p, tag: t, after: n, text: body}   insert-after shorthand
    [%{path: p1, ...}, %{path: p2, ...}]   multi-file
    %{files: [...]}                        multi-file pack
  Edits on the same path with the same tag auto-merge; same path with different tags is a conflict.
  """

  def patch(%{base64: b}) when is_binary(b), do: patch_base64_decoded(b)
  def patch(%{"base64" => b}) when is_binary(b), do: patch_base64_decoded(b)

  def patch(%{files: files}) when is_list(files), do: patch_files(files)
  def patch(%{"files" => files}) when is_list(files), do: patch_files(files)

  def patch(%{snapshot: %{path: p, tag: t}} = opts) when is_binary(p) and is_binary(t) do
    opts = Map.put(opts, :path, p) |> Map.put(:tag, t)
    file = normalize_file_map(opts)
    patch_files([file])
  end

  def patch(%{"snapshot" => %{"path" => p, "tag" => t}} = opts)
      when is_binary(p) and is_binary(t) do
    opts = Map.put(opts, :path, p) |> Map.put(:tag, t)
    file = normalize_file_map(opts)
    patch_files([file])
  end

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

  defp patch_base64_decoded(base64) do
    case Base.decode64(String.trim(base64)) do
      {:ok, text} -> patch(text)
      :error -> raise ParseError, message: "invalid base64 patch"
    end
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
    tag = fetch_tag(map)

    cond do
      is_nil(path) ->
        raise ParseError, message: "structured patch is missing path/file"

      is_nil(tag) ->
        raise ParseError, message: "structured patch is missing tag/snapshot"

      fetch_key(map, [:edits, :ops, :changes]) || fetch_key(map, ["edits", "ops", "changes"]) ->
        edits = fetch_key(map, [:edits, :ops, :changes]) || fetch_key(map, ["edits", "ops", "changes"])
        %{path: path, tag: tag, edits: List.wrap(edits)}

      true ->
        %{path: path, tag: tag, edits: [normalize_single_edit(map)]}
    end
  end

  defp normalize_single_edit(opts) do
    check_ambiguous!(opts, [
      [:content, :text, :new_text],
      ["content", "text", "new_text"],
      [:range, :lines],
      ["range", "lines"],
      [:from, :first, :a, :start],
      ["from", "first", "a", "start"],
      [:to, :last, :b, :end],
      ["to", "last", "b", "end"]
    ])

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
        raise ParseError, message: "unrecognized structured edit (needs op/delete/before/after)"
    end
  end

  defp normalize_op_name(op) when op in [:replace, :put, "replace", "put"], do: :replace
  defp normalize_op_name(op) when op in [:delete, :cut, :remove, "delete", "cut", "remove"], do: :delete
  defp normalize_op_name(op) when op in [:insert_before, :before, "insert_before", "before"], do: :insert_before
  defp normalize_op_name(op) when op in [:insert_after, :after, "insert_after", "after"], do: :insert_after
  defp normalize_op_name(other), do: raise(ParseError, message: "unknown op: #{inspect(other)}")

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

  # tag 支持 show/2 的完整返回值（%{ok: true, snapshot: t, ...} 或 %{tag: t, text: ...}）
  defp fetch_tag(map) do
    raw = fetch_key(map, [:tag, :snapshot, :id]) || fetch_key(map, ["tag", "snapshot", "id"])
    extract_tag(raw)
  end

  defp extract_tag(%{tag: t}) when is_binary(t), do: t
  defp extract_tag(%{"tag" => t}) when is_binary(t), do: t
  defp extract_tag(%{snapshot: t}) when is_binary(t), do: t
  defp extract_tag(%{"snapshot" => t}) when is_binary(t), do: t
  defp extract_tag(t) when is_binary(t), do: t
  defp extract_tag(_), do: nil

  # 冲突参数检测：多键同时传且值不一致 → :ambiguous_parameter
  defp check_ambiguous!(map, groups) do
    Enum.each(groups, fn keys ->
      vals =
        Enum.map(keys, fn k ->
          case Map.fetch(map, k) do
            {:ok, v} -> {k, v}
            :error -> nil
          end
        end)
        |> Enum.reject(&is_nil/1)

      uniq = vals |> Enum.map(fn {_k, v} -> v end) |> Enum.uniq()

      if length(vals) > 1 and length(uniq) > 1 do
        names = vals |> Enum.map(fn {k, _v} -> inspect(k) end) |> Enum.join(" and ")

        raise ParseError,
          message: "#{names} disagree, ambiguous — keep only one",
          code: :ambiguous_parameter
      end
    end)

    map
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
    op = normalize_op_name(return_op)
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
        raise ParseError, message: "op #{op} has a bad range: #{inspect(raw_range)}; inserts must be single-line"
    end
  end

  defp content_lines(nil), do: nil
  defp content_lines(""), do: nil
  defp content_lines(body), do: String.split(body, "\n")

  defp require_body!(op, nil), do: raise(ParseError, message: "op #{inspect(op)} is missing its text/content body")
  defp require_body!(_op, _body), do: :ok

  @doc "Read a file and record a snapshot; returns %{tag, text, lines, path} (path feeds patch %{snapshot: shown} directly). Tolerant range: :all | {a,b} | [a,b] | a..b | %{from: a, to: b} | \"a..b\" | a; unknown ranges raise ParseError(code: :invalid_range)."
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
        raise ParseError,
          message: "unrecognized range text: #{inspect(t)} (takes a..b | a-b | a,b | a | all)",
          code: :invalid_range
    end
  end

  defp normalize_show_range(other) when is_list(other) do
    f = Keyword.get(other, :first) || Keyword.get(other, :start) || Keyword.get(other, :a)
    l = Keyword.get(other, :last) || Keyword.get(other, :end) || Keyword.get(other, :b)

    if is_integer(f) and is_integer(l) do
      {f, l}
    else
      raise ParseError,
        message: "unrecognized range list: #{inspect(other)} (needs [a, b], [a], or first/last keywords)",
        code: :invalid_range
    end
  end

  defp normalize_show_range(other) do
    raise ParseError,
      message: "unrecognized range: #{inspect(other)} (takes :all | {a,b} | [a,b] | a..b | %{from: a, to: b} | \"a..b\" | integer)",
      code: :invalid_range
  end

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
    %{tag: tag, text: text, lines: length(sel), path: path}
  end

  # ── 解析 ──

  defp parse(text) do
    {sections, cur} = Enum.reduce(String.split(text, "\n"), {[], nil}, &parse_line/2)
    sections = if cur, do: sections ++ [cur], else: sections
    if sections == [], do: raise(ParseError, message: "empty patch")
    sections
  end

  defp parse_line(line, {sections, nil}) do
    case String.trim(line) do
      "" -> {sections, nil}
      "[" <> _ = h -> {sections, parse_header(h)}
      _ -> raise ParseError, message: "patch must start with a [path#tag] section"
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
        raise ParseError, message: "unrecognized line (body must start with +): #{String.trim(line)}"
    end
  end

  defp parse_header(h) do
    case Regex.run(~r/^\[(.+)#([0-9a-f]{12})\]\s*$/, h) do
      [_, path, tag] -> %{path: String.trim(path), tag: tag, ops: []}
      _ -> raise ParseError, message: "bad section header: #{String.trim(h)} (want [path#12-char-tag])"
    end
  end

  defp add_body(%{ops: ops} = cur, content) do
    case Enum.reverse(ops) do
      [{op, m} | rest] when op in [:put, :insert_before, :insert_after] ->
        %{cur | ops: Enum.reverse([{op, Map.update(m, :body, [content], &(&1 ++ [content]))} | rest])}

      _ ->
        raise ParseError, message: "body lines must directly follow a PUT/insert header ending in :"
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
      nil -> raise ParseError, message: "bad range: #{s} (want N or N..M)"
    end
  end

  # ── 预检与候选 ──

  defp plan_section(%{path: path, tag: tag, ops: ops}) do
    snap =
      SnapshotStore.fetch(path, tag) ||
        raise RejectError, message: "unknown snapshot tag #{tag} (show first)", category: :unknown_snapshot

    current = File.read!(path)

    if current != snap.text do
      raise RejectError,
        message: "file changed under you (stale): #{path} no longer matches snapshot #{tag}; nothing written. Re-show and resubmit on the new tag",
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
        raise RejectError, message: "line out of bounds: #{lo}..#{hi} (snapshot has #{total} lines)", category: :out_of_bounds
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
            message: "lines not yet read: #{Enum.take(unseen, 5) |> Enum.join(",")} (show that range first)",
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
        raise RejectError, message: "overlapping ranges: #{pa}..#{pb} vs #{a}..#{b}", category: :overlap
      end

      {a, b}
    end)

    :ok
  end

  defp check_duplicate_paths!(sections) do
    paths = Enum.map(sections, & &1.path)

    if length(paths) != length(Enum.uniq(paths)) do
      raise RejectError,
        message: "one patch may not touch the same path twice; merge into one section",
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
          backup: plan.path <> ".newbee-edit-backup-" <> nonce,
          moved?: false
        }
      end)

    try do
      Enum.each(entries, fn %{plan: plan, temp: temp} ->
        File.write!(temp, plan.new_content)

        case File.stat(plan.path) do
          {:ok, %{mode: mode}} -> File.chmod!(temp, mode)
          _ -> :ok
        end
      end)

      case Enum.reduce_while(entries, [], fn
             %{plan: plan, temp: temp, backup: backup} = entry, moved ->
               if File.read!(plan.path) != plan.old_content do
                 rollback_entries([entry | moved])
                 {:halt, {:error, plan.path, :concurrent_change}}
               else
                 with :ok <- File.rename(plan.path, backup),
                      :ok <- File.rename(temp, plan.path) do
                   {:cont, [%{entry | moved?: true} | moved]}
                 else
                   {:error, reason} ->
                     rollback_entries([entry | moved])
                     {:halt, {:error, plan.path, reason}}
                 end
               end
           end) do
        {:error, failed_path, :concurrent_change} ->
          raise RejectError,
            message: "file concurrently modified before write: #{failed_path}; nothing written. Re-show and retry",
            category: :concurrent_change

        {:error, failed_path, reason} ->
          raise RejectError,
            message: "cannot atomically replace #{failed_path}: #{inspect(reason)}",
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
    Enum.each(Enum.reverse(entries), fn entry ->
      %{plan: plan, temp: temp, backup: backup} = entry

      if entry.moved? do
        # 已成功替换：删除新内容，恢复备份
        File.rm(plan.path)
        if File.exists?(backup), do: File.rename(backup, plan.path)
      else
        # 未移动：原文件仍在原位，只清理备份（可能备份存在但第二步失败）
        if File.exists?(backup), do: File.rename(backup, plan.path)
      end

      File.rm(temp)
    end)
  end

  defp check_no_op!(plan) do
    if plan.new_content == File.read!(plan.path) do
      raise RejectError, message: "no-op: patched result matches current content", category: :no_op
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
