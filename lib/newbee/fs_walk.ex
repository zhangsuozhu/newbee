defmodule Newbee.FsWalk do
  @moduledoc """
  有护栏的递归文件漫步（内部共享模块，非模型可见工具）。

  背景：`Path.wildcard(dir <> "/**/...")` 会先把全量结果装进内存再返回。
  当根是 `/`（含 /proc、/sys 等伪文件系统）时，遍历在求值进程 32MB 堆
  上限（`Newbee.DEE.EvalWorker` 的 `:max_heap_size`）下直接被杀，任务随之
  中断（2026-09-08 线上事故：`RepoMap.build(".")` 在工作目录为 `/` 的机器
  上两次触发 `maximum heap size reached`）。

  护栏（调用方原有的事后过滤保留，本模块只保证"枚举有界"）：
  - 遍历中剪枝：`:prune_dir` 按目录名单跳过子树（如 `_build`、`deps`、`.git`）；
  - 伪文件系统：永不进入 `/proc`、`/sys`、`/dev`、`/run`；
  - 符号链接：目录链接列出但不进入（防环）；
  - 深度上限（默认 30）与条数上限（默认 50_000），超限截断；
  - 不可读或中途消失的目录直接跳过。
  """

  @pseudo_roots ["/proc", "/sys", "/dev", "/run"]
  @default_max_entries 50_000
  @default_max_depth 30

  @doc """
  有界递归枚举 `dir` 下的条目，返回路径列表。

  返回路径的形式与传入的 `dir` 保持一致（相对传入就是相对的），便于调用方
  继续做 `Path.relative_to/2` 或直接 `File.read/1`。

  选项：
  - `:max_entries` — 最多返回条数（默认 50_000），超限截断；
  - `:max_depth` — 相对根的最大下探深度（默认 30）；
  - `:exts` — 只要这些后缀的文件，如 `[".ex", ".exs"]`（默认不过滤）；
  - `:include_dirs` — 是否收录目录条目（默认 false，只要文件）；
  - `:prune_dir` — 目录剪枝谓词 `(segment -> boolean)`，命中则不进入该子树
    （根目录本身不受影响，只作用于子孙）。

  ## Runnable example
      files = Newbee.FsWalk.files("lib", exts: [".ex"])
      all = Newbee.FsWalk.files(".", include_dirs: true, max_entries: 500)
  """
  @spec files(Path.t(), keyword()) :: [String.t()]
  def files(dir, opts \\ []) do
    ctx = %{
      prefix: to_string(dir),
      prefix_exp: Path.expand(dir),
      max: Keyword.get(opts, :max_entries, @default_max_entries),
      max_depth: Keyword.get(opts, :max_depth, @default_max_depth),
      exts: Keyword.get(opts, :exts, nil),
      include_dirs: Keyword.get(opts, :include_dirs, false),
      prune_dir: Keyword.get(opts, :prune_dir, fn _seg -> false end)
    }

    if pseudo?(ctx.prefix_exp) do
      []
    else
      case File.lstat(ctx.prefix_exp) do
        {:ok, %{type: :directory}} ->
          {_count, acc} = walk([{ctx.prefix_exp, 0}], ctx, {0, []})
          Enum.reverse(acc)

        _ ->
          []
      end
    end
  end

  defp walk([], _ctx, state), do: state
  defp walk(_stack, %{max: max}, {count, _acc} = state) when count >= max, do: state

  defp walk([{path, depth} | rest], ctx, {count, acc}) do
    case File.ls(path) do
      {:ok, entries} ->
        {stack2, count2, acc2} =
          Enum.reduce_while(entries, {rest, count, acc}, fn entry, {st, c, a} ->
            step(Path.join(path, entry), entry, depth, st, c, a, ctx)
          end)

        walk(stack2, ctx, {count2, acc2})

      {:error, _} ->
        walk(rest, ctx, {count, acc})
    end
  end

  defp step(full, seg, depth, st, c, a, ctx) do
    cond do
      c >= ctx.max ->
        {:halt, {st, c, a}}

      pseudo?(full) ->
        {:cont, {st, c, a}}

      true ->
        case File.lstat(full) do
          {:ok, %{type: :symlink}} ->
            push(full, dir_link?(full), seg, depth, st, c, a, ctx, false)

          {:ok, %{type: :directory}} ->
            push(full, true, seg, depth, st, c, a, ctx, true)

          {:ok, _} ->
            push(full, false, seg, depth, st, c, a, ctx, false)

          {:error, _} ->
            {:cont, {st, c, a}}
        end
    end
  end

  defp push(full, is_dir, seg, depth, st, c, a, ctx, descend) do
    display = Path.join(ctx.prefix, Path.relative_to(full, ctx.prefix_exp))

    {a2, c2} =
      cond do
        is_dir and ctx.include_dirs ->
          {[display | a], c + 1}

        not is_dir and (is_nil(ctx.exts) or Path.extname(seg) in ctx.exts) ->
          {[display | a], c + 1}

        true ->
          {a, c}
      end

    st2 =
      if descend and depth < ctx.max_depth and not ctx.prune_dir.(seg) do
        [{full, depth + 1} | st]
      else
        st
      end

    {:cont, {st2, c2, a2}}
  end

  defp dir_link?(path) do
    case File.stat(path) do
      {:ok, %{type: :directory}} -> true
      _ -> false
    end
  end

  defp pseudo?(path) do
    Enum.any?(@pseudo_roots, fn p -> path == p or String.starts_with?(path, p <> "/") end)
  end
end
