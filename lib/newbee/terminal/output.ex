defmodule Newbee.Terminal.Output do
  @moduledoc """
  PTY 原始字节流 → 模型可读的纯文本。

  终端里混着四类对模型毫无意义的字节：命令回显、`newbee-done` 哨兵与 shell 提示符、
  ANSI 转义（CSI/OSC/键区模式切换）、以及回车覆盖与退格造成的重绘残渣。这个模块只
  负责最后一类——把**一段**字节流清洗成**一份**文本；回显、哨兵与提示符由执行侧的
  标记切片解决（见 `Newbee.Web.Terminal`）。

  流式设计：PTY 数据分块到达，转义序列与一行文本都可能被切在块边界上，所以

    * 未完成的转义序列留在 `pending` 里等下一块（绝不吐出半截 `ESC[3`）；
    * 一行文本留到换行才吐出（否则 `\\r` 覆盖与退格无法正确重绘）；
    * 行尾孤立的 `\\r` 也必须等下一个字节——CRLF 与 CR 覆盖只差这一个字节。

  行缓冲有上限（`@max_line_bytes`）：超长单行（压缩产物、二进制转储）不再等换行，
  直接分段吐出，内存不随输出量增长。
  """

  import Bitwise

  @max_line_bytes 65_536

  defstruct mode: :text, line: "", pending: ""

  @typedoc "`mode` 记录转义序列解析到了哪一步。"
  @type mode :: :text | :esc | :esc_intermediate | :csi | :osc

  @type t :: %__MODULE__{mode: mode(), line: binary(), pending: binary()}

  @doc "新建清洗器。"
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc "推入一块原始字节，返回 `{清洗器, 可直接落盘的文本}`。"
  @spec push(t(), binary()) :: {t(), binary()}
  def push(%__MODULE__{} = st, data) when is_binary(data),
    do: run(%{st | pending: st.pending <> data}, [])

  @doc """
  收尾：吐出仍在行缓冲里的残余文本。

  未完成的转义序列一律丢弃——那是被截断的控制序列，不是内容。
  """
  @spec finish(t()) :: {t(), binary()}
  def finish(%__MODULE__{} = st) do
    out = if st.line == "", do: "", else: st.line
    {%{st | mode: :text, line: "", pending: ""}, out}
  end

  # ── 主循环 ──────────────────────────────────────────────────────────

  defp run(%{pending: ""} = st, acc), do: {st, acc |> Enum.reverse() |> IO.iodata_to_binary()}

  defp run(st, acc) do
    case step(st, st.pending) do
      {:cont, st, rest, ""} -> run(%{st | pending: rest}, acc)
      {:cont, st, rest, out} -> run(%{st | pending: rest}, [out | acc])
      :hold -> {st, IO.iodata_to_binary(acc)}
    end
  end

  # ── 文本态 ──────────────────────────────────────────────────────────

  defp step(%{mode: :text}, <<>>), do: :hold

  defp step(%{mode: :text} = st, <<27, rest::binary>>), do: {:cont, %{st | mode: :esc}, rest, ""}

  # 行尾孤立 CR：留待下一块，CRLF 与 CR 覆盖只差一个字节
  defp step(%{mode: :text}, <<13>>), do: :hold

  defp step(%{mode: :text} = st, <<13, 10, rest::binary>>) do
    {st, out} = newline(st)
    {:cont, st, rest, out}
  end

  # 裸 CR = 回到行首重绘：已缓冲内容作废（进度条、旋转指示器）
  defp step(%{mode: :text} = st, <<13, rest::binary>>), do: {:cont, %{st | line: ""}, rest, ""}

  defp step(%{mode: :text} = st, <<10, rest::binary>>) do
    {st, out} = newline(st)
    {:cont, st, rest, out}
  end

  defp step(%{mode: :text} = st, <<8, rest::binary>>),
    do: {:cont, %{st | line: drop_last_char(st.line)}, rest, ""}

  # 其余 C0 控制字符与 DEL 不可见（TAB 保留）
  defp step(%{mode: :text} = st, <<byte, rest::binary>>) when byte < 32 and byte != 9,
    do: {:cont, st, rest, ""}

  defp step(%{mode: :text} = st, <<127, rest::binary>>), do: {:cont, st, rest, ""}

  defp step(%{mode: :text} = st, <<byte, rest::binary>>) do
    case append(st, byte) do
      {:ok, st} -> {:cont, st, rest, ""}
      {:flush, st, out} -> {:cont, st, rest, out}
    end
  end

  # ── 转义态：ESC 之后一个字节决定序列类型 ───────────────────────────

  defp step(%{mode: :esc}, <<>>), do: :hold
  defp step(%{mode: :esc} = st, <<?[, rest::binary>>), do: {:cont, %{st | mode: :csi}, rest, ""}
  defp step(%{mode: :esc} = st, <<?], rest::binary>>), do: {:cont, %{st | mode: :osc}, rest, ""}

  # 字符集选择等中间字节：后面还有恰好一个终止字节
  defp step(%{mode: :esc} = st, <<byte, rest::binary>>) when byte in 0x20..0x2F,
    do: {:cont, %{st | mode: :esc_intermediate}, rest, ""}

  # 两字节序列（ESC = / ESC > / ESC 7 / ESC M …）
  defp step(%{mode: :esc} = st, <<_byte, rest::binary>>), do: {:cont, %{st | mode: :text}, rest, ""}

  defp step(%{mode: :esc_intermediate}, <<>>), do: :hold

  defp step(%{mode: :esc_intermediate} = st, <<_byte, rest::binary>>),
    do: {:cont, %{st | mode: :text}, rest, ""}

  # ── CSI：参数 0x20..0x3F，终止 0x40..0x7E ───────────────────────────

  defp step(%{mode: :csi}, <<>>), do: :hold

  defp step(%{mode: :csi} = st, <<byte, rest::binary>>) when byte in 0x40..0x7E,
    do: {:cont, %{st | mode: :text}, rest, ""}

  defp step(%{mode: :csi} = st, <<_byte, rest::binary>>), do: {:cont, st, rest, ""}

  # ── OSC：BEL / ST(ESC \) / 8 位 ST(0x9C) 结束 ──────────────────────

  defp step(%{mode: :osc}, <<>>), do: :hold
  defp step(%{mode: :osc} = st, <<7, rest::binary>>), do: {:cont, %{st | mode: :text}, rest, ""}
  defp step(%{mode: :osc} = st, <<0x9C, rest::binary>>), do: {:cont, %{st | mode: :text}, rest, ""}
  defp step(%{mode: :osc}, <<27>>), do: :hold

  defp step(%{mode: :osc} = st, <<27, ?\\, rest::binary>>),
    do: {:cont, %{st | mode: :text}, rest, ""}

  defp step(%{mode: :osc} = st, <<_byte, rest::binary>>), do: {:cont, st, rest, ""}

  # ── 行缓冲 ──────────────────────────────────────────────────────────

  defp newline(st) do
    out = st.line <> "\n"
    {%{st | line: ""}, out}
  end

  defp append(st, byte) do
    line = st.line <> <<byte>>

    if byte_size(line) >= @max_line_bytes do
      {:flush, %{st | line: ""}, line}
    else
      {:ok, %{st | line: line}}
    end
  end

  # 退格删除最后一个字符（不是最后一个字节）——否则 UTF-8 会被切成非法序列。
  defp drop_last_char(""), do: ""

  defp drop_last_char(line) do
    size = byte_size(line)
    keep = backtrack_continuation(line, size - 1)
    binary_part(line, 0, keep)
  end

  defp backtrack_continuation(_line, 0), do: 0

  defp backtrack_continuation(line, index) do
    if (binary_part(line, index, 1) |> :binary.first() &&& 0xC0) == 0x80 do
      backtrack_continuation(line, index - 1)
    else
      index
    end
  end
end
