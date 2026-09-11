defmodule Newbee.Truncate do
  @moduledoc """
  统一的「头尾预览 + 无损溢出」截断点。

  历史上 newbee 有四个互不知情的截断点（终端 64KB、Ring0 32KB、cell IO 1MB、
  结果回填 8KB），每一处都物理销毁被截掉的字节，且标记里的省略量与实际不符——
  长构建日志里唯一那条 `ERROR` 行会静默消失，模型只剩一个 `exit=2`。

  本模块把"怎么切、怎么报告、怎么取回"收敛到一处：

  - **UTF-8 安全**：按字节切会把多字节字符切成替换字符；这里在字符边界收尾；
  - **整行优先**：收尾/起始尽量落在换行符边界，且回退量有上界；
  - **无损**：被切掉的原文先按内容寻址落盘（`Newbee.Spill`），标记给出
    `Newbee.read("spill://<id>")` 这个**可执行**的回读句柄；
  - **量诚实**：报告本层省略量；若输入里已带有更外层的句柄（更完整的原文），
    以其真实字节数为"原文"，优先展示那个句柄——模型一次跳转就能拿到全文；
  - **fail-open**：落盘失败不改行为，只把标记降级为"原文已丢弃"。

  标记是唯一格式，各层共用：

  ```text
  … [截断: 省略 24062 bytes · 原文 124938 bytes · 完整原文: Newbee.read("spill://ab12…")] …
  ```

  在线生产者（无法把整份输出留在内存里）用 `Newbee.Truncate.Window` 做同一件事：
  在线累加有界头尾，收尾时由本模块渲染同一个标记。
  """

  alias Newbee.Truncate.Window

  @default_max_bytes 8_000
  @default_head_ratio 0.6
  @handle_hint ~s|Newbee.read("spill://|

  @doc """
  一站式：必要时切割 + 落盘 + 渲染标记。返回

      %{
        text: String.t(),          # 可直接回填给模型
        truncated: boolean(),
        original_bytes: non_neg_integer(),
        kept_bytes: non_neg_integer(),
        omitted_bytes: non_neg_integer(),
        handle: map() | nil,       # 本层落盘的 Newbee.Spill info
        deeper: map() | nil        # 输入中更外层的、更完整的句柄（含 bytes/id）
      }

  `opts`: `:max_bytes`、`:head_ratio`、`:source`（进 spill 账本）、`:spill`（false 关闭落盘）。
  """
  def head_tail(text, opts \\ []) when is_binary(text) do
    max = opts |> Keyword.get(:max_bytes, @default_max_bytes) |> positive(@default_max_bytes)
    ratio = opts |> Keyword.get(:head_ratio, @default_head_ratio) |> normalize_ratio()
    size = byte_size(text)

    if size <= max do
      %{
        text: text,
        truncated: false,
        original_bytes: size,
        kept_bytes: size,
        omitted_bytes: 0,
        handle: nil,
        deeper: nil
      }
    else
      handle = spill(text, opts)
      deeper = deepest_handle(text)
      {head_bytes, tail_bytes} = budgets(max, ratio)

      rendered =
        head_bytes
        |> Window.new(tail_bytes)
        |> Window.push(text)
        |> Window.render(handle: handle, deeper: deeper)

      Map.merge(rendered, %{handle: handle, deeper: deeper})
    end
  end

  @doc "按总预算与头占比算出 `{head_bytes, tail_bytes}`。"
  def budgets(max_bytes, head_ratio \\ @default_head_ratio) do
    max = positive(max_bytes, @default_max_bytes)
    head = max(trunc(max * normalize_ratio(head_ratio)), 1)
    {head, max(max - head, 0)}
  end

  @doc """
  渲染截断标记（含换行围栏）。`meta` 形如 `%{omitted:, original:, handle:, deeper:}`：

  - `:omitted`   本层省略字节数；
  - `:original`  本层输入字节数；
  - `:handle`    本层 spill info（`%{id:, bytes:, stored:, partial:}`）或 nil；
  - `:deeper`    输入里更外层的句柄（`%{id:, bytes:}`）或 nil，优先展示。
  """
  def marker(meta) do
    parts =
      [
        "截断: 省略 #{int(Map.get(meta, :omitted, 0))} bytes",
        origin_text(meta),
        handle_text(meta)
      ]
      |> Enum.reject(&is_nil/1)

    "\n… [" <> Enum.join(parts, " · ") <> "] …\n"
  end

  @doc "把预览与标记拼成最终回填文本。"
  def compose(head, tail, meta) when is_binary(head) and is_binary(tail) do
    head <> marker(meta) <> tail
  end

  @doc """
  输入里已有的 spill 句柄，取字节数最大的一个（= 能看到的最完整原文）。
  句柄不可读时返回 nil（fail-open）。
  """
  def deepest_handle(text) when is_binary(text) do
    text
    |> Newbee.Spill.handles_in()
    |> Enum.map(&Newbee.Spill.stat/1)
    |> Enum.flat_map(fn
      {:ok, info} -> [info]
      {:error, _reason} -> []
    end)
    |> Enum.max_by(& &1.bytes, fn -> nil end)
  rescue
    _ -> nil
  catch
    _kind, _reason -> nil
  end

  def deepest_handle(_), do: nil

  # ── 标记片段 ──

  defp origin_text(meta) do
    original = Map.get(meta, :original)
    deeper = Map.get(meta, :deeper)

    cond do
      is_map(deeper) and is_integer(deeper[:bytes]) -> "原文 #{int(deeper.bytes)} bytes"
      is_integer(original) -> "原文 #{int(original)} bytes" <> partial_suffix(meta)
      true -> nil
    end
  end

  defp partial_suffix(meta) do
    handle = Map.get(meta, :handle)

    if is_map(handle) and Map.get(handle, :partial) do
      "（超上限，仅存前 #{int(Map.get(handle, :stored, 0))} bytes）"
    else
      ""
    end
  end

  defp handle_text(meta) do
    handle = Map.get(meta, :handle)
    deeper = Map.get(meta, :deeper)

    cond do
      is_map(deeper) -> "完整原文: " <> hint(deeper[:id])
      is_map(handle) -> "完整原文: " <> hint(handle[:id])
      true -> "原文已丢弃，无法回读"
    end
  end

  defp hint(id) when is_binary(id), do: @handle_hint <> id <> ~s|")|
  defp hint(_), do: "原文已丢弃，无法回读"

  defp int(value) when is_integer(value), do: Integer.to_string(value)
  defp int(_), do: "0"

  # ── 落盘 ──

  defp spill(text, opts) do
    if Keyword.get(opts, :spill, true) do
      case Newbee.Spill.store(text, source: Keyword.get(opts, :source, "truncate")) do
        {:ok, info} -> info
        {:error, _reason} -> nil
      end
    end
  rescue
    _ -> nil
  catch
    _kind, _reason -> nil
  end

  defp positive(value, _fallback) when is_integer(value) and value > 0, do: value
  defp positive(_value, fallback), do: fallback

  defp normalize_ratio(value) when is_float(value) and value > 0 and value < 1, do: value
  defp normalize_ratio(value) when is_integer(value) and value > 0 and value < 1, do: value / 1
  defp normalize_ratio(_value), do: @default_head_ratio
end
