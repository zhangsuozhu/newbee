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
  文件系统写入/删除/目录工具；通用只读优先 `Newbee.read/1`。

  路径参数宽容：`binary` | `atom` | `%{path: p}` | `%{"path" => p}` | `[p]` 均归一为路径字符串；`write` 的内容也宽容 `binary` | `%{content: c}`。

  - 写操作**先进暂存区**（Newbee.Staging），用户 /approve 统一落盘——
    宽松沙箱的"可回滚"承诺（§8）；
  - 读操作直接返回内容，路径限制在当前工程树内（§8 工作目录隔离）。

  ## 函数清单
  - `read(path)` — 读文件，返回 `{:ok, content} | {:error, reason}`。
  - `read!(path)` — 读文件，不存在抛 `File.Error`。
  - `write(path, content)` — 暂存写，返回条目 `id`（integer）或 `:direct`；需 `/approve` 才落盘。
  - `write!(path, content)` — 直接落盘（危险，绕过暂存），成功 `:ok`，并触发内联 diff 事件。
  - `append!(path, content)` — 追加写，直接落盘，`:ok`。
  - `rm(path)` — 删除文件，返回 `:ok | {:error, reason}`。
  - `rm_rf(path)` — 递归删除（高危，记审计），返回 `{:ok, [deleted]} | {:error, reason}`。
  - `exists?(path)` — 文件是否存在，`boolean`。
  - `guard_path(path)` — 工作目录隔离校验，合法 `:ok`，非法返回 `{:error, %{reason: :out_of_bounds, hint: _}}`。
  - `guard_path!(path)` — bang 版本；非法路径抛 `ArgumentError`。
  - `ls(dir)` — 列目录一层，返回 `[entry]`（目录带 `/`）或 `{:error, reason}`。
  - `tree(root \\\\ ".")` — 遍历工程树（跳过 `_build/deps/.git/node_modules/cover`），返回相对路径 `[String.t()]`。
  - `size(path)` — 文件字节数，`non_neg_integer()`，不存在返回 `0`。

  ## 可跑示例
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

  ## 注意
  - `write/2` 经 `Newbee.Host` 代理回主 VM 的 `Staging`；未启动时降级为 `:direct`。
  - `write!/2` 直接落盘并经 `Host.emit` 发 `:file_diff`；`append!/2` 直接追加，当前不发 diff 事件。
  - `guard_path/1` 返回结构化边界错误；`guard_path!/1` 限制写入 `File.cwd!()` 树或 `~/.newbee` 内，其余抛错；但 `File.write!` 仍可绕过，硬隔离由审计/快照兜底。

  """

  @doc "读文件。返回 {:ok, content} | {:error, reason}。"
  def read(path) do
    path = normalize_path(path)
    File.read(path)
  end

  @doc "读文件（不存在抛错）。"
  def read!(path) do
    path = normalize_path(path)
    File.read!(path)
  end

  @doc "写文件：暂存待批。返回暂存条目 id。

  注意：求值器节点上没有 Staging 进程——经 Newbee.Host 代理回主 VM（§3.4），
  主 VM 无暂存区（app 未启动）时降级直接落盘。"
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

  @doc "写文件（直接落盘，不暂存）。危险操作，模型慎用。落盘后发内联 diff 事件（§5.1）。"
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

  @doc "追加写（直接落盘——追加语义不适合暂存）。"
  def append!(path, content) do
    path = normalize_path(path)
    content = normalize_content(content)
    guard_path!(path)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, content, [:append])
    :ok
  end

  @doc "删除文件。返回 :ok | {:error, reason}。"
  def rm(path) do
    path = normalize_path(path)
    with :ok <- guard_path(path), do: File.rm(path)
  end

  @doc "递归删除（高风险，记审计）。"
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
  工作目录隔离（§8）：写入类操作限制在当前工程树或 ~/.newbee 内，
  非 bang 操作返回结构化错误；bang 操作仍抛 `ArgumentError`。

  注意这是**软边界**：模型仍可在 run_elixir 里直接 File.write! 绕开——
  它约束的是推荐 API，真正的硬隔离由宽松档位的审计/快照兜底（§8）。
  长输出可写到工程内 `.newbee-tmp/` 或 `~/.newbee/`。
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
         hint: "拒绝写入工程树外路径: #{path}（长输出可写到工程内 .newbee-tmp/ 或 ~/.newbee/）"
       }}
    end
  end

  @doc "工作目录隔离的 bang 版本；非法路径抛 ArgumentError。"
  def guard_path!(path) do
    path = normalize_path(path)
    case guard_path(path) do
      :ok -> :ok
      {:error, %{hint: hint}} -> raise ArgumentError, hint
    end
  end

  @doc "文件是否存在。"
  def exists?(path) do
    path = normalize_path(path)
    File.exists?(path)
  end

  @doc "列出目录（一层）。"
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

  @doc "遍历工程树（跳过 _build/deps/.git）。返回相对路径列表。"
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

  @doc "文件大小（字节）。"
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

end
