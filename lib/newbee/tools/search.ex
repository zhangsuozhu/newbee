defmodule Newbee.Tools.Search do
  @moduledoc """
  Source/text search: regex-grep contents or find by filename.
  Skips `_build/deps/.git/node_modules/cover`. Returns compact hit lists.

  ## Functions
  - `grep(pattern, dir \\\\ ".", opts \\\\ [])` — recursive content search, `pattern` is a regex.
    Returns `[{path, line_no, line}]` (default cap 100, tunable via `opts[:max]`). Bad regex returns `{:error, %{reason: :invalid_regex, hint: ...}}`. Single files go through `File.read`; files over 5MB or holding `<<0>>` bytes are skipped.
  - `find(name, dir \\\\ ".")` — find by filename fragment; returns `[path]`.

  `list_files/1` prefers `git ls-files -co --exclude-standard` (fast whitelist), falling back to `Path.wildcard`.

  ## Runnable example
      hits = Newbee.Tools.Search.grep("def show", "lib")
      hits = Newbee.Tools.Search.grep("TODO", ".", max: 20)
      paths = Newbee.Tools.Search.find("fs.ex")
      paths = Newbee.Tools.Search.find("edit", "lib/newbee/tools")
  """

  @skip ~r{/(_build|deps|\.git|node_modules|cover)/}

  @doc """
  Recursive content search.

  Returns `[{path, line_no, line}]`, `[]` when nothing matches, and
  `{:error, %{reason: ..., hint: ...}}` when the call cannot be honoured:
  a bad regex, a directory that does not exist, or options passed as the
  directory (e.g. `grep(pattern, path: "lib")` — that is a keyword list, not a path).
  """
  def grep(pattern, dir \\ ".", opts \\ [])

  def grep(pattern, opts, []) when is_binary(pattern) and is_list(opts) do
    {:error,
     %{
       reason: :bad_arguments,
       hint: "second argument is the directory (a string); options come third: Search.grep(pattern, \"lib\", opt: 1)"
     }}
  end

  def grep(pattern, dir, opts) when is_binary(pattern) and is_list(opts) do
    max = Keyword.get(opts, :max, 100)

    with {:ok, re} <- compile_regex(pattern),
         {:ok, files} <- list_files(dir) do
      files
      |> Enum.reduce_while([], fn f, acc ->
        if length(acc) >= max do
          {:halt, acc}
        else
          hits = grep_file(f, re, max - length(acc))
          {:cont, acc ++ hits}
        end
      end)
      |> Enum.take(max)
    end
  end

  defp compile_regex(pattern) do
    case Regex.compile(pattern) do
      {:ok, re} -> {:ok, re}
      {:error, reason} -> {:error, %{reason: :invalid_regex, hint: "regex compile failed: " <> inspect(reason)}}
    end
  end

  # 一次 File.read 替代 File.stat + File.stream（慢速双调用）——
  # 大文件/二进制文件直接跳过；返回 [{path, line_no, line}]
  defp grep_file(f, re, max) do
    case File.read(f) do
      {:ok, body} when byte_size(body) <= 5_000_000 and is_binary(body) ->
        if String.contains?(body, <<0>>) do
          []
        else
          body
          |> String.split("\n")
          |> Enum.with_index(1)
          |> Enum.reduce_while([], fn {line, n}, acc ->
            if length(acc) >= max do
              {:halt, acc}
            else
              if Regex.match?(re, line),
                do: {:cont, [{f, n, String.slice(line, 0, 200)} | acc]},
                else: {:cont, acc}
            end
          end)
          |> Enum.reverse()
        end

      _ ->
        []
    end
  rescue
    _ -> []
  catch
    _, _ -> []
  end

  @doc """
  Find by filename fragment.

  Returns a path list (empty when nothing matches) or
  `{:error, %{reason: :no_such_dir, hint: ...}}` for a missing directory.
  """
  def find(name, dir \\ ".") when is_binary(name) do
    with {:ok, files} <- list_files(dir) do
      Enum.filter(files, &String.contains?(Path.basename(&1), name))
    end
  end

  # A missing directory must be reported: an empty hit list from a typo is
  # indistinguishable from "no matches" and silently answers the wrong question.
  defp list_files(dir) do
    dir = Path.expand(dir)

    if File.dir?(dir) do
      git_files(dir)
    else
      {:error, %{reason: :no_such_dir, hint: "not a directory: " <> dir}}
    end
  end

  defp git_files(dir) do
    # 优先用 git ls-files（秒级，白名单），失败回退到 wildcard + 过滤
    case System.cmd("git", ["ls-files", "-co", "--exclude-standard", dir], stderr_to_stdout: true) do
      {out, 0} ->
        {:ok,
         out
         |> String.split("\n", trim: true)
         |> Enum.reject(&Regex.match?(@skip, "/" <> &1 <> "/"))}

      _ ->
        # 有界漫步：git 不可用时的回退原来是裸 "**"（根目录下内存爆炸，2026-09-08 事故）。
        {:ok,
         Newbee.FsWalk.files(dir, prune_dir: &skip_search_segment?/1)
         |> Enum.filter(&File.regular?/1)
         |> Enum.reject(&Regex.match?(@skip, &1))}
    end
  end

  defp skip_search_segment?(seg), do: seg in ~w(_build deps .git node_modules cover)
end
