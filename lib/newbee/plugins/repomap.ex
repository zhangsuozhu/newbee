defmodule Newbee.Plugins.RepoMap do
  @moduledoc """
  工程结构图 (DESIGN §3.6)：注入紧凑的模块签名大纲而非整文件，
  模型凭图定位，再对目标区域精确取细节。

  v2：引用图重要性排序——统计模块间静态引用（含 alias 展开），
  被引用多的模块给全签名（Tier1），其余收进单行索引（Tier2）。
  相比 v1 按文件名截断：全模块覆盖、核心模块必现、总字节更省、输出确定。
  非 Elixir 工程退化为目录树。

  ## 函数清单
  - `build(root \\ ".", opts \\ []) :: String.t()` — 构建工程结构图（紧凑字符串）。非 Elixir 工程退化为目录树。
    选项：`:tier1_max_bytes` —— Tier1 区字节预算（默认 14_000）。

  增量缓存（§3.6）：以 mix.exs + lib 全部文件的 mtime 指纹为 key，
  工程未变更时直接复用缓存，不重复 AST 解析。

  ## 可跑示例
      Newbee.Plugins.RepoMap.build(".")
      Newbee.Plugins.RepoMap.build(".", tier1_max_bytes: 8_000)

  """

  @tier1_min 8               # 无论多大预算，Top-8 必给全签名
  @tier1_max_bytes 14_000    # Tier1 区默认字节预算（预算内贪心装填）
  @sigs_per_module 15        # 每个 Tier1 模块最多展示的签名数
  @doc_bytes 80              # moduledoc 截断长度

  @cache_dir Path.join(System.user_home!(), ".newbee/cache")

  @doc """
  构建工程结构图（紧凑字符串）。非 Elixir 工程退化为目录树。

  选项：
    - :tier1_max_bytes —— Tier1 区字节预算（默认 14_000），
      小工程想强制双层展示可调小。

  增量缓存（§3.6）：以 mix.exs + lib 全部文件的 mtime 指纹为 key，
  工程未变更时直接复用缓存，不重复 AST 解析。v2 键前缀隔离旧格式。
  """
  def build(dir \\ ".", opts \\ []) do
    key = "v2-" <> fingerprint(dir)

    case read_cache(key) do
      {:ok, map} ->
        map

      :miss ->
        map =
          if File.exists?(Path.join(dir, "mix.exs")) do
            elixir_map(dir, opts)
          else
            tree_map(dir)
          end

        write_cache(key, map)
        map
    end
  end

  # ── Elixir 工程：解析 → 引用图打分 → 双层渲染 ─────────────────────────

  defp elixir_map(dir, opts) do
    parsed =
      dir
      |> source_files()
      |> parse_files(dir)

    known = module_names(parsed)
    refs = reference_counts(parsed, known)
    ranked = rank(parsed, refs)

    render_ranked(ranked, Keyword.get(opts, :tier1_max_bytes, @tier1_max_bytes))
  end

  # 参与建图的源文件：跳过厂商/产物/环境目录，test 文件保留（引用数低自然落 Tier2）
  defp source_files(dir) do
    vendor = MapSet.new(~w(_build deps .git node_modules .newbee .newbee-tmp cover))

    dir
    |> Path.join("**/*.{ex,exs}")
    |> Path.wildcard()
    |> Enum.reject(fn path ->
      path |> Path.split() |> MapSet.new() |> MapSet.disjoint?(vendor) |> Kernel.not()
    end)
  end

  # 文件级解析：相对路径 + 全部 defmodule（含嵌套）+ 引用节点 + alias 展开表
  defp parse_files(files, dir) do
    Enum.flat_map(files, fn path ->
      case parse_file(path) do
        nil -> []
        info -> [%{info | path: Path.relative_to(path, dir)}]
      end
    end)
  end

  defp parse_file(path) do
    with {:ok, src} <- File.read(path),
         {:ok, ast} <- Code.string_to_quoted(src, columns: false) do
      modules = collect_modules(ast)
      {ref_segs, alias_map} = collect_refs_and_aliases(ast)
      %{path: path, modules: modules, ref_segs: ref_segs, alias_map: alias_map}
    else
      _ -> nil
    end
  end

  # 收集文件内全部 defmodule（顶层与嵌套），每个带 doc 与签名清单
  defp collect_modules({:defmodule, _, [{:__aliases__, _, segs}, [do: body]]}) do
    {doc, defs, nested} = scan_body(body)
    own = %{name: segs, doc: doc, defs: defs}
    [own | Enum.flat_map(nested, &collect_modules/1)]
  end

  defp collect_modules(_), do: []

  # 扫描一个 defmodule 体：moduledoc 首行、定义签名、嵌套 defmodule
  defp scan_body(body) do
    body
    |> block_to_list()
    |> Enum.reduce(%{doc: nil, defs: [], nested: []}, fn
      {:@, _, [{:moduledoc, _, [doc]}]}, acc when is_binary(doc) ->
        line = doc |> String.split("\n") |> hd()
        %{acc | doc: acc.doc || line}

      {kind, _, [head | _]}, acc when kind in [:def, :defp, :defmacro, :defmacrop, :defdelegate, :defguard, :defguardp] ->
        %{acc | defs: [sig(to_string(kind), head) | acc.defs]}

      {kind, _, [fields]}, acc when kind in [:defstruct, :defexception] and is_list(fields) ->
        label = if kind == :defstruct, do: "defstruct: ", else: "defexception: "
        %{acc | defs: [label <> Enum.map_join(fields, ", ", &field_name/1) | acc.defs]}

      {:use, _, [mod | _]}, acc ->
        %{acc | defs: ["use " <> mod_str(mod) | acc.defs]}

      {:defmodule, _, [{:__aliases__, _, segs}, [do: inner]]}, acc ->
        %{acc | nested: [{:defmodule, [], [{:__aliases__, [], segs}, [do: inner]]} | acc.nested]}

      _, acc ->
        acc
    end)
    |> then(fn %{doc: doc, defs: defs, nested: nested} ->
      {doc, defs |> Enum.reverse() |> Enum.take(@sigs_per_module), Enum.reverse(nested)}
    end)
  end

  # 全文件收集 __aliases__ 引用节点 + alias 指令展开表（短名 → 完整段）
  defp collect_refs_and_aliases(ast) do
    {_ast_out, {ref_segs_rev, alias_map}} =
      Macro.prewalk(ast, {[], %{}}, fn
        {:alias, _, [spec]}, {refs, amap} ->
          {spec, {refs, Map.merge(amap, aliases_of(spec))}}

        {:__aliases__, _, segs} = node, {refs, amap} ->
          {node, {[segs | refs], amap}}

        other, acc ->
          {other, acc}
      end)

    {Enum.reverse(ref_segs_rev), alias_map}
  end

  # alias 指令三种形态：A.B.C / A.{B, C.D} / 裸原子
  defp aliases_of({:__aliases__, _, segs}) do
    case Enum.split(segs, length(segs) - 1) do
      {prefix, [last]} when is_tuple(last) and elem(last, 0) == :{} ->
        Enum.reduce(elem(last, 1), %{}, fn
          {:__aliases__, _, s}, m -> Map.put(m, hd_member(s), prefix ++ s)
          _, m -> m
        end)

      {_, [last_seg]} ->
        %{last_seg => segs}

      _ ->
        %{}
    end
  end

  defp aliases_of(mod) when is_atom(mod), do: %{mod => [mod]}
  defp aliases_of(_), do: %{}

  # 模块规范名统一用点分字符串，避免 atom/string 混用
  defp canonical(segs), do: Enum.join(segs, ".")

  defp hd_member([h | _]), do: h
  defp hd_member(other) when is_atom(other), do: other

  # 解析一个引用节点到本工程完整模块名；唯一后缀命中也算（容相对引用）
  defp resolve_ref(segs, alias_map, known) do
    expanded =
      case alias_map[hd(segs)] do
        nil -> segs
        base -> base ++ tl(segs)
      end

    full = Enum.join(expanded, ".")

    if MapSet.member?(known, full) do
      full
    else
      unique_suffix(full, known)
    end
  end

  defp unique_suffix(full_name, known) do
    wanted = String.split(full_name, ".")
    len = length(wanted)

    hits =
      Enum.filter(known, fn name ->
        parts = String.split(name, ".")
        length(parts) > len and Enum.take(parts, -len) == wanted
      end)

    case hits do
      [only] -> only
      _ -> nil
    end
  end

  # 文件级引用图：每文件的引用目标集合（扣除同文件自定义），目标计数 +1
  defp reference_counts(files, known) do
    Enum.reduce(files, %{}, fn f, acc ->
      targets =
        f.ref_segs
        |> Enum.map(&resolve_ref(&1, f.alias_map, known))
        |> Enum.reject(&is_nil/1)
        |> MapSet.new()
        |> MapSet.difference(local_names(f))

      Enum.reduce(targets, acc, fn t, a -> Map.update(a, t, 1, &(&1 + 1)) end)
    end)
  end

  defp local_names(f), do: MapSet.new(Enum.map(f.modules, &canonical(&1.name)))

  defp module_names(files) do
    files
    |> Enum.flat_map(& &1.modules)
    |> MapSet.new(&canonical(&1.name))
  end

  # 排序：引用数降序 → 路径升序 → 名字升序（完全确定）
  defp rank(files, refs) do
    files
    |> Enum.flat_map(fn f -> Enum.map(f.modules, &{f.path, &1}) end)
    |> Enum.map(fn {path, m} ->
      name = canonical(m.name)
      %{name: name, doc: m.doc, defs: m.defs, path: path, refs: Map.get(refs, name, 0)}
    end)
    |> Enum.sort_by(fn m -> {-m.refs, m.path, m.name} end)
  end

  # ── 渲染：Tier1 全签名（预算内贪心）+ Tier2 单行索引 ──────────────────

  defp render_ranked(ranked, tier1_max_bytes) do
    {tier1, tier2} = split_tiers(ranked, tier1_max_bytes)

    part1 = Enum.map_join(tier1, "\n", &render_block/1)

    part2 =
      case tier2 do
        [] ->
          ""

        mods ->
          lines = Enum.map_join(mods, "\n", &render_index_line/1)
          "\n其他模块:\n" <> lines
      end

    String.trim_trailing(part1 <> part2)
  end

  defp split_tiers(ranked, tier1_max_bytes) do
    {t1, t2, _bytes} =
      Enum.reduce(ranked, {[], [], 0}, fn m, {t1, t2, bytes} ->
        block_size = byte_size(render_block(m))

        cond do
          length(t1) < @tier1_min ->
            {[m | t1], t2, bytes + block_size}

          bytes + block_size <= tier1_max_bytes ->
            {[m | t1], t2, bytes + block_size}

          true ->
            {t1, [m | t2], bytes}
        end
      end)

    {Enum.reverse(t1), Enum.reverse(t2)}
  end

  defp render_block(m) do
    header = "▸ " <> m.name <> doc_suffix(m.doc)

    body =
      m.defs
      |> Enum.map_join("\n", &("    " <> &1))
      |> case do
        "" -> ""
        body -> "\n" <> body
      end

    header <> body <> "\n  @ " <> m.path
  end

  defp doc_suffix(nil), do: ""
  defp doc_suffix(doc), do: " — " <> String.slice(doc, 0, @doc_bytes)

  defp render_index_line(m) do
    "· #{m.name} (#{length(m.defs)} sigs) @ #{m.path}"
  end

  # ── 缓存 ──────────────────────────────────────────────────────────────

  # 工程指纹：实际参与解析的文件集合的 mtime 汇总（未变更即缓存命中）
  defp fingerprint(dir) do
    files =
      if File.exists?(Path.join(dir, "mix.exs")) do
        source_files(dir) ++ [Path.join(dir, "mix.exs")]
      else
        dir
        |> Path.join("**/*")
        |> Path.wildcard()
        |> Enum.reject(&String.contains?(&1, ~w(_build deps .git node_modules)))
      end

    sig =
      files
      |> Enum.map(fn f ->
        mtime =
          case File.stat(f, time: :posix) do
            {:ok, s} -> s.mtime
            _ -> 0
          end

        "#{f}:#{mtime}"
      end)
      |> Enum.sort()
      |> Enum.join("|")

    :crypto.hash(:md5, sig <> dir) |> Base.encode16(case: :lower)
  end

  defp read_cache(key) do
    file = Path.join(@cache_dir, "repomap-" <> cache_id() <> ".json")

    case File.read(file) do
      {:ok, body} ->
        case Jason.decode(body) do
          {:ok, %{"key" => ^key, "map" => map}} -> {:ok, map}
          _ -> :miss
        end

      _ ->
        :miss
    end
  end

  defp write_cache(key, map) do
    File.mkdir_p!(@cache_dir)
    file = Path.join(@cache_dir, "repomap-" <> cache_id() <> ".json")
    File.write!(file, Jason.encode_to_iodata!(%{"key" => key, "map" => map}))
    :ok
  rescue
    _ -> :ok
  end

  defp cache_id, do: File.cwd!() |> then(&:crypto.hash(:md5, &1)) |> Base.encode16(case: :lower)

  defp tree_map(dir) do
    dir
    |> Path.join("**/*")
    |> Path.wildcard()
    |> Enum.reject(&String.contains?(&1, ~w(_build deps .git node_modules)))
    |> Enum.take(200)
    |> Enum.sort()
    |> Enum.join("\n")
  end

  # ── AST 小工具 ────────────────────────────────────────────────────────

  defp block_to_list({:__block__, _, xs}), do: xs
  defp block_to_list(x), do: [x]

  defp sig(kind, {:when, _, [head | _]}), do: sig(kind, head)

  defp sig(kind, {name, _, args}) when is_atom(name) do
    arity = if is_list(args), do: length(args), else: 0
    "#{kind} #{name}/#{arity}"
  end

  defp sig(kind, _), do: kind

  defp field_name({k, _}), do: to_string(k)
  defp field_name(k), do: to_string(k)

  defp mod_str({:__aliases__, _, segs}), do: Enum.join(segs, ".")
  defp mod_str(mod) when is_atom(mod), do: inspect(mod)
  defp mod_str(other), do: Macro.to_string(other)
end
