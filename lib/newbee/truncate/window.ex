defmodule Newbee.Truncate.Window do
  @moduledoc """
  有界头尾累加器：内存与输出量无关，且**只在真的丢字节时才报截断**。

  流式生产者（终端 PTY、Ring0 shell）不能把整份输出留在内存里，于是在线累加
  「前 `head_bytes` 字节 + 最后 `tail_bytes` 字节」。这个结构有两个容易做错的点，
  都在这里钉死：

  1. **重叠区不是丢失**。`total <= head_bytes + tail_bytes` 时 `head` 与 `tail` 必然
     重叠，整份内容可**精确重建**——旧实现把从 tail 窗口挤出去的字节一律计成"省略"，
     于是 20KB 的命令输出会被报成"省略 4KB"（其实一个字节都没丢），并且结果还被撑成
     32KB。这里改为：可重建就不加标记、不报省略、直接还原原文。
  2. **整行对齐与 UTF-8 回退都不能吃掉预算**。两者都只在各自窗口内有界回退
     （`@snap_window` / 3 字节），所以「可读」「不切碎多字节字符」的代价是常数，
     不会因为一条超长行（或二进制数据）丢一半内容。

  `tail_prefix` 记住被挤出 tail 窗口的那个字节，用来判断 tail 是否本来就落在行首，
  避免做无谓丢弃。
  """

  alias Newbee.Truncate

  @snap_window 512

  defstruct head: "",
            tail: "",
            # 紧挨着 tail 起点之前的那个字节（nil = tail 就是流的开头）
            tail_prefix: nil,
            total: 0,
            head_bytes: 0,
            tail_bytes: 0

  @doc "新建累加器。`head_bytes`/`tail_bytes` 各自是保留预算（字节）。"
  def new(head_bytes, tail_bytes)
      when is_integer(head_bytes) and head_bytes >= 0 and is_integer(tail_bytes) and tail_bytes >= 0 do
    %__MODULE__{head_bytes: head_bytes, tail_bytes: tail_bytes}
  end

  @doc "推入一块数据（纯函数，返回新结构）。"
  def push(%__MODULE__{} = window, ""), do: window

  def push(%__MODULE__{} = window, data) when is_binary(data) do
    head = take_head(window.head, data, window.head_bytes)
    {tail, evicted} = take_tail(window.tail, data, window.tail_bytes)

    %{
      window
      | head: head,
        tail: tail,
        tail_prefix: if(evicted, do: evicted, else: window.tail_prefix),
        total: window.total + byte_size(data)
    }
  end

  @doc """
  收尾渲染。返回

      %{text:, truncated:, original_bytes:, kept_bytes:, omitted_bytes:}

  `opts[:handle]` / `opts[:deeper]` 供渲染标记时引用 spill 句柄。
  """
  def render(%__MODULE__{} = window, opts \\ []) do
    cond do
      # tail 窗口就装下了全部内容
      window.total <= window.tail_bytes ->
        intact(window.tail, window.total)

      # head 与 tail 重叠但足以精确重建：没有丢失，就不要假标记
      window.total <= window.head_bytes + window.tail_bytes ->
        text = binary_part(window.head, 0, window.total - window.tail_bytes) <> window.tail
        intact(text, window.total)

      true ->
        head = window.head |> utf8_prefix() |> snap_head()
        tail = window.tail |> utf8_suffix() |> snap_tail(window.tail_prefix)
        kept = byte_size(head) + byte_size(tail)
        omitted = max(window.total - kept, 0)

        meta = %{
          omitted: omitted,
          original: window.total,
          handle: Keyword.get(opts, :handle),
          deeper: Keyword.get(opts, :deeper)
        }

        %{
          text: Truncate.compose(head, tail, meta),
          truncated: true,
          original_bytes: window.total,
          kept_bytes: kept,
          omitted_bytes: omitted
        }
    end
  end

  defp intact(text, total) do
    %{text: text, truncated: false, original_bytes: total, kept_bytes: total, omitted_bytes: 0}
  end

  defp take_head(head, _data, limit) when byte_size(head) >= limit, do: head

  defp take_head(head, data, limit) do
    need = limit - byte_size(head)
    head <> binary_part(data, 0, min(need, byte_size(data)))
  end

  # 滑动窗口保留最后 limit 字节；同时回一个字，供 tail 行首判断。
  defp take_tail(tail, data, limit) do
    combined = tail <> data
    size = byte_size(combined)

    cond do
      size == 0 -> {"", false}
      limit == 0 -> {"", binary_part(combined, size - 1, 1)}
      size <= limit -> {combined, false}
      true -> sliced_tail(combined, size, limit)
    end
  end

  defp sliced_tail(combined, size, limit) do
    start = size - limit
    {binary_part(combined, start, limit), binary_part(combined, start - 1, 1)}
  end

  # 收尾对齐到换行符之后——只在回退不超过 @snap_window 字节时做。
  defp snap_head(""), do: ""

  defp snap_head(head) do
    size = byte_size(head)

    if binary_part(head, size - 1, 1) == "\n" do
      head
    else
      case head |> :binary.matches("\n") |> List.last() do
        {pos, 1} when size - (pos + 1) <= @snap_window -> binary_part(head, 0, pos + 1)
        _ -> head
      end
    end
  end

  # 开头对齐到整行；tail 本来就落在行首时不做事（不做无谓丢弃）。
  defp snap_tail(tail, prefix) do
    size = byte_size(tail)

    cond do
      size == 0 -> ""
      prefix == nil or prefix == "\n" -> tail
      true -> match_tail(tail, size)
    end
  end

  defp match_tail(tail, size) do
    case :binary.match(tail, "\n") do
      {pos, 1} when pos + 1 <= @snap_window -> binary_part(tail, pos + 1, size - pos - 1)
      _ -> tail
    end
  end

  # 回退最多 3 字节以避开被切碎的多字节字符；源本身非法 UTF-8 时保持原样
  # （不把"二进制输出"误判成"空"）。
  defp utf8_prefix(""), do: ""

  defp utf8_prefix(data) do
    size = byte_size(data)
    limit = min(3, size)

    case Enum.find(0..limit, fn back -> String.valid?(prefix_of(data, size - back)) end) do
      nil -> data
      back -> prefix_of(data, size - back)
    end
  end

  defp utf8_suffix(""), do: ""

  defp utf8_suffix(data) do
    size = byte_size(data)
    limit = min(3, size)

    case Enum.find(0..limit, fn skip -> String.valid?(suffix_of(data, skip)) end) do
      nil -> data
      skip -> suffix_of(data, skip)
    end
  end

  defp prefix_of(_data, len) when len <= 0, do: ""
  defp prefix_of(data, len), do: binary_part(data, 0, len)

  defp suffix_of(data, skip) do
    size = byte_size(data)
    if skip >= size, do: "", else: binary_part(data, skip, size - skip)
  end
end
