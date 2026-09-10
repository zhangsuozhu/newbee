defmodule Newbee.JsonlTail do
  @moduledoc """
  JSONL 尾部读取（DESIGN §4.6 事件流的读侧快路径）。

  大事件流（本项目实测 172 MB / 15.6 万行）「读最后 n 条」不该等于全量解码：
  本模块只读文件末尾的字节窗口，窗口 128 KiB 起步、按 4 倍放大，直到取满
  n 行或覆盖整个文件。

  - 窗口起点不在行首时丢弃残缺首段（用起点前一个字节判定）；
  - 末尾无换行的残行默认丢弃，`keep_partial: true` 时保留（由调用方决定能否解码）；
  - 返回 `{:ok, lines, coverage}`，`coverage` 为 `:partial`（窗口只覆盖尾部）或
    `:whole`（窗口已覆盖整个文件，调用方可退回全量语义）。
  """

  @initial_window 131_072
  @growth 4

  @doc """
  读取文件末尾至多 `n` 行（按文件顺序，旧 → 新）。

  opts：
  - `keep_partial: true` — 保留末尾没有换行符的残行。
  """
  def read_lines(path, n, opts \\ [])

  # n 非法时报错，而不是静默返回空列表（避免调用方把 bug 当成空文件）
  def read_lines(_path, n, _opts) when not is_integer(n) or n <= 0, do: {:error, :invalid_request}

  def read_lines(path, n, opts) do
    keep_partial = Keyword.get(opts, :keep_partial, false)

    case File.stat(path) do
      {:ok, %{size: 0}} ->
        {:ok, [], :whole}

      {:ok, %{size: size}} ->
        window(path, n, size, min(@initial_window, size), keep_partial)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp window(path, n, size, window, keep_partial) do
    if window >= size do
      case File.read(path) do
        {:ok, body} -> {:ok, take_last(split(body, true, keep_partial), n), :whole}
        {:error, reason} -> {:error, reason}
      end
    else
      start = size - window

      with {:ok, body} <- pread(path, start, window),
           {:ok, boundary?} <- boundary?(path, start) do
        lines = split(body, boundary?, keep_partial)

        if length(lines) >= n do
          {:ok, take_last(lines, n), :partial}
        else
          window(path, n, size, window * @growth, keep_partial)
        end
      end
    end
  end

  defp take_last(lines, n), do: Enum.take(lines, -n)

  # 把窗口字节切成行：boundary? 表示窗口首字节就在行首。
  defp split(body, boundary?, keep_partial) do
    parts = :binary.split(body, "\n", [:global])
    parts = if boundary?, do: parts, else: tl(parts)

    parts =
      case List.last(parts) do
        "" -> Enum.drop(parts, -1)
        _fragment -> if keep_partial, do: parts, else: Enum.drop(parts, -1)
      end

    Enum.reject(parts, &(&1 == ""))
  end

  defp boundary?(_path, 0), do: {:ok, true}

  defp boundary?(path, start) do
    case pread(path, start - 1, 1) do
      {:ok, "\n"} -> {:ok, true}
      {:ok, _} -> {:ok, false}
      {:error, reason} -> {:error, reason}
    end
  end

  defp pread(path, offset, bytes) do
    case :file.open(path, [:read, :raw, :binary]) do
      {:ok, fd} ->
        try do
          case :file.pread(fd, offset, bytes) do
            {:ok, bin} -> {:ok, bin}
            :eof -> {:ok, <<>>}
            {:error, reason} -> {:error, reason}
          end
        after
          :file.close(fd)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end
end
