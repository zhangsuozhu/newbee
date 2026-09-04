defmodule Newbee.Tools.Fs do
  # -- 宽容参数：路径/内容多形态归一 --
  defp normalize_path(path) when is_binary(path), do: path
  defp normalize_path(path) when is_atom(path), do: to_string(path)
  defp normalize_path(%{path: p}) when is_binary(p) or is_atom(p), do: normalize_path(p)
  defp normalize_path(%{"path" => p}) when is_binary(p) or is_atom(p), do: normalize_path(p)
  defp normalize_path(%{dir: p}) when is_binary(p) or is_atom(p), do: normalize_path(p)
  defp normalize_path(%{"dir" => p}) when is_binary(p) or is_atom(p), do: normalize_path(p)
  defp normalize_path(%{file: p}) when is_binary(p) or is_atom(p), do: normalize_path(p)
  defp normalize_path(%{"file" => p}) when is_binary(p) or is_atom(p), do: normalize_path(p)
  defp normalize_path([p]) when is_binary(p) or is_atom(p), do: normalize_path(p)
  defp normalize_path(other) when is_list(other) and length(other) == 1, do: normalize_path(hd(other))
  defp normalize_path(other), do: to_string(other)

  defp normalize_content(c) when is_binary(c), do: c
  defp normalize_content(%{content: c}) when is_binary(c), do: c
  defp normalize_content(%{"content" => c}) when is_binary(c), do: c
  defp normalize_content(c) when is_list(c), do: IO.iodata_to_binary(c)
  defp normalize_content(c) when is_number(c), do: to_string(c)
  defp normalize_content(nil), do: ""
  defp normalize_content(c), do: to_string(c)

  @moduledoc """
  Filesystem writes/deletes/listing; prefer `Newbee.read/1` for reads.

  Tolerant path args: `binary` | `atom` | `%{path: p}` | `%{"path" => p}` | `[p]` all normalize to a path value;
  `write` content also takes `binary` | `%{content: c}`.

  - Writes land in Staging first (Newbee.Staging), flushed to disk on /approve — the rollback promise of the lenient sandbox;
  - Reads return content directly; paths stay inside the project tree (workspace isolation).

  ## Functions
  - `read(path)` — read a file; `{:ok, content} | {:error, reason}`.
  - `read!(path)` — read a file; raises `File.Error` when missing.
  - `write(path, content)` — staged write; returns entry `id` (integer) or `:direct`; needs `/approve` to hit disk.
  - `write!(path, content)` — write through to disk (dangerous, skips staging); `:ok` on success, emits an inline diff event.
  - `append!(path, content)` — append to a file, straight to disk; `:ok`.
  - `rm(path)` — delete a file; `:ok | {:error, reason}`.
  - `rm_rf(path)` — recursive delete (hazardous, audited); `{:ok, [deleted]} | {:error, reason}`.
  - `exists?(path)` — whether the file exists.
  - `guard_path(path)` — workspace isolation check; `:ok` when legal, else `{:error, %{reason: :out_of_bounds, hint: _}}`.
  - `guard_path!(path)` — bang variant; raises `ArgumentError` on illegal paths.
  - `ls(dir)` — list one directory level; `[entry]` (dirs end with `/`) or `{:error, reason}`.
  - `tree(root)` — walk the project tree (skips `_build/deps/.git/node_modules/cover`); relative-path `[String.t()]`.
  - `size(path)` — file size in bytes, `non_neg_integer()`; `0` when missing.
  - `write_base64(path, base64)` — base64 write, no Elixir escaping involved.
  - `write_content(path, content)` — smart write: `base64:`-prefixed content is decoded first.

  ## Runnable example
      {:ok, c} = Newbee.Tools.Fs.read("README.md")
        {:ok, c} = Newbee.Tools.Fs.read(%{path: "README.md"})
        {:ok, c} = Newbee.Tools.Fs.read(:"README.md")
        {:ok, c} = Newbee.Tools.Fs.read(["README.md"])
      c = Newbee.Tools.Fs.read!("mix.exs")
      id_or_direct = Newbee.Tools.Fs.write("tmp/hello.txt", "hello")
      :ok = Newbee.Tools.Fs.write!("tmp/a.txt", "direct")
      :ok = Newbee.Tools.Fs.append!("tmp/log.txt", "line\n")
      true = Newbee.Tools.Fs.exists?("mix.exs")
      :ok = Newbee.Tools.Fs.guard_path("tmp/safe.txt")
      :ok = Newbee.Tools.Fs.guard_path!("tmp/safe.txt")
      Newbee.Tools.Fs.ls("lib/newbee/tools")
      Newbee.Tools.Fs.tree(".") |> Enum.take(3)
      Newbee.Tools.Fs.size("mix.exs")
      :ok = Newbee.Tools.Fs.rm("tmp/hello.txt")
      {:ok, _deleted} = Newbee.Tools.Fs.rm_rf("tmp/generated")
    :ok = Newbee.Tools.Fs.write_base64("tmp/out.txt", Base.encode64("hello"))
    :ok = Newbee.Tools.Fs.write_content("tmp/out2.txt", "base64:" <> Base.encode64(content))
  """

  @doc "Read a file. Returns {:ok, content} | {:error, reason}."
  def read(path) do
    path = normalize_path(path)
    File.read(path)
  end

  @doc "Read a file (raises when missing)."
  def read!(path) do
    path = normalize_path(path)
    File.read!(path)
  end

  @doc "Staged file write; returns the staging entry id.

  No Staging process runs on evaluator nodes — proxies back to the host VM via Newbee.Host;
  falls back to a direct write when the host has no staging area (app not started)."
  def write(path, content) do
    path = normalize_path(path)
    content = normalize_content(content)

    with :ok <- guard_path(path) do
      case Newbee.Host.call(Newbee.Staging, :stage, [path, content, :fs_write]) do
        id when is_integer(id) ->
          id

        _ ->
          # 主 VM 暂存区不可用（badrpc / 未启动）：直接落盘
          File.mkdir_p!(Path.dirname(path))
          File.write!(path, content)
          :direct
      end
    end
  end

  @doc "Write a file straight to disk, no staging. Dangerous, use sparingly. Emits an inline diff event after writing."
  def write!(path, content) do
    path = normalize_path(path)
    content = normalize_content(content)
    guard_path!(path)
    old = if File.exists?(path), do: File.read!(path), else: ""
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, content)
    emit_diff(path, old, content)
    :ok
  end

  @doc "Append to a file (straight to disk — appends do not stage)."
  def append!(path, content) do
    path = normalize_path(path)
    content = normalize_content(content)
    guard_path!(path)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, content, [:append])
    :ok
  end

  @doc "Delete a file. Returns :ok | {:error, reason}."
  def rm(path) do
    path = normalize_path(path)
    with :ok <- guard_path(path), do: File.rm(path)
  end

  @doc "Recursive delete (high risk, audited)."
  def rm_rf(path) do
    path = normalize_path(path)

    with :ok <- guard_path(path) do
      Newbee.Host.emit(:audit, {:audit, :dangerous_code, ["File.rm_rf!", path]})
      File.rm_rf(path)
    end
  end

  # 内联 diff 事件（§5.1）：节点上经 Host 代理回主 VM 总线
  defp emit_diff(path, old, new) do
    if old != new do
      Newbee.Host.emit(
        :file_diff,
        {:file_diff, path, Enum.join(Newbee.Diff.lines(old, new), "\n"), Newbee.Diff.stats(old, new)}
      )
    end

    :ok
  end

  @doc """
  Workspace isolation: write ops stay inside the project tree or ~/.newbee;
  non-bang calls return a structured error, bang calls still raise `ArgumentError`.

  Soft boundary: raw File.write! inside run_elixir bypasses it — it constrains the recommended API;
  hard isolation is audit/snapshot. Write long output under `.newbee-tmp/` or `~/.newbee/`.
  """
  def guard_path(path) do
    path = normalize_path(path)
    expanded = Path.expand(path)
    root = Path.expand(File.cwd!())
    newbee = Path.join(System.user_home!(), ".newbee") |> Path.expand()

    ok? =
      Enum.any?([root, newbee], fn base ->
        expanded == base or String.starts_with?(expanded, base <> "/")
      end)

    if ok? do
      :ok
    else
      {:error,
       %{
         reason: :out_of_bounds,
         hint: "Out-of-tree write refused: #{path} (write long output under .newbee-tmp/ or ~/.newbee/)"
       }}
    end
  end

  @doc "Bang variant of workspace isolation; raises ArgumentError on illegal paths."
  def guard_path!(path) do
    path = normalize_path(path)

    case guard_path(path) do
      :ok -> :ok
      {:error, %{hint: hint}} -> raise ArgumentError, hint
    end
  end

  @doc "Whether a file exists."
  def exists?(path) do
    path = normalize_path(path)
    File.exists?(path)
  end

  @doc "List one directory level."
  def ls(dir) do
    dir = normalize_path(dir)

    case File.ls(dir) do
      {:ok, entries} ->
        Enum.map(entries, fn e ->
          p = Path.join(dir, e)
          if File.dir?(p), do: e <> "/", else: e
        end)

      {:error, _} = err ->
        err
    end
  end

  @doc "Walk the project tree (skips _build/deps/.git). Returns relative paths."
  def tree(root \\ ".") do
    root = normalize_path(root)

    root
    |> Path.join("**/*")
    |> Path.wildcard()
    |> Enum.reject(fn p ->
      p =~ ~r{/(_build|deps|\.git|node_modules|cover)/}
    end)
    |> Enum.map(&Path.relative_to(&1, root))
  end

  @doc "File size in bytes."
  def size(path) do
    path = normalize_path(path)

    case File.stat(path) do
      {:ok, stat} -> stat.size
      _ -> 0
    end
  end

  @doc false
  def write(%{path: p, content: c}), do: write(p, c)
  @doc false
  def write(%{"path" => p, "content" => c}), do: write(p, c)
  @doc false
  def write(%{path: p, text: c}), do: write(p, c)
  @doc false
  def write(%{"path" => p, "text" => c}), do: write(p, c)
  @doc false
  def write(%{file: p, content: c}), do: write(p, c)
  @doc false
  def write(%{"file" => p, "content" => c}), do: write(p, c)

  @doc false
  def write!(%{path: p, content: c}), do: write!(p, c)
  @doc false
  def write!(%{"path" => p, "content" => c}), do: write!(p, c)
  @doc false
  def write!(%{path: p, text: c}), do: write!(p, c)
  @doc false
  def write!(%{"path" => p, "text" => c}), do: write!(p, c)

  @doc false
  def append!(%{path: p, content: c}), do: append!(p, c)
  @doc false
  def append!(%{"path" => p, "content" => c}), do: append!(p, c)

  @doc "Base64 write, fully dodging Elixir escaping. `content_base64` holds base64 content; pass `Base.encode64(content)` directly."
  def write_base64(path, base64) when is_binary(path) and is_binary(base64) do
    path = normalize_path(path)

    case Base.decode64(String.trim(base64)) do
      {:ok, content} -> write!(path, content)
      :error -> {:error, :invalid_base64}
    end
  end

  @doc false
  def write_base64(%{path: p, content_base64: b}) when is_binary(p) and is_binary(b), do: write_base64(p, b)
  @doc false
  def write_base64(%{"path" => p, "content_base64" => b}) when is_binary(p) and is_binary(b), do: write_base64(p, b)
  @doc false
  def write_base64(%{path: p, base64: b}) when is_binary(p) and is_binary(b), do: write_base64(p, b)
  @doc false
  def write_base64(%{"path" => p, "base64" => b}) when is_binary(p) and is_binary(b), do: write_base64(p, b)
  @doc false
  def write_base64(%{file: p, content_base64: b}) when is_binary(p) and is_binary(b), do: write_base64(p, b)

  @doc "Smart write: content starting with a `base64:` prefix is base64-decoded, otherwise written as-is. Takes all shapes."
  def write_content(path, content) when is_binary(path) and is_binary(content) do
    path = normalize_path(path)

    cond do
      String.starts_with?(content, "base64:") ->
        base64 = String.trim_leading(content, "base64:")

        case Base.decode64(String.trim(base64)) do
          {:ok, decoded} -> write!(path, decoded)
          :error -> {:error, :invalid_base64}
        end

      true ->
        write!(path, content)
    end
  end

  @doc false
  def write_content(%{path: p, content: c}) when is_binary(p) and is_binary(c), do: write_content(p, c)
  @doc false
  def write_content(%{"path" => p, "content" => c}) when is_binary(p) and is_binary(c), do: write_content(p, c)
end
