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
      Newbee.Tools.Search.grep("def show", "lib")
      Newbee.Tools.Search.grep("TODO", ".", max: 20)
      Newbee.Tools.Search.find("fs.ex")
      Newbee.Tools.Search.find("edit", "lib/newbee/tools")
  """

  @skip ~r{/(_build|deps|\.git|node_modules|cover)/}

  @doc "Recursive content search. Returns hits on success; {:error, %{reason: :invalid_regex, hint: _}} on a bad regex."
  def grep(pattern, dir \\ ".", opts \\ []) when is_binary(pattern) do
    max = Keyword.get(opts, :max, 100)

    case Regex.compile(pattern) do
      {:ok, re} ->
        files = list_files(dir)

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

      {:error, reason} ->
        {:error, %{reason: :invalid_regex, hint: "regex compile failed: " <> inspect(reason)}}
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

  @doc "Find by filename fragment. Returns a path list."
  def find(name, dir \\ ".") do
    list_files(dir) |> Enum.filter(&String.contains?(Path.basename(&1), name))
  end

  defp list_files(dir) do
    dir = Path.expand(dir)

    # 优先用 git ls-files（秒级，白名单），失败回退到 wildcard + 过滤
    case System.cmd("git", ["ls-files", "-co", "--exclude-standard", dir], stderr_to_stdout: true) do
      {out, 0} ->
        out
        |> String.split("\n", trim: true)
        |> Enum.reject(&Regex.match?(@skip, "/" <> &1 <> "/"))

      _ ->
        dir
        |> Path.join("**/*")
        |> Path.wildcard()
        |> Enum.reject(&(File.dir?(&1) or Regex.match?(@skip, &1)))
    end
  end
end
