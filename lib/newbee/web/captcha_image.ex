defmodule Newbee.Web.CaptchaImage do
  @moduledoc """
  服务端把验证码栅格化成 PNG（零依赖：`:zlib` 压缩 IDAT、`:erlang.crc32` 计算块校验）。

  产物里只有像素：payload 不再包含 `<svg>` / `<text>`，脚本只能做像素级/模板识别，
  不能再靠一行正则读出答案（此前 R49 实测 T7Bv/CZBa/Bxft 被服务端接受为正确验证码）。
  字形来自 `Newbee.Web.CaptchaGlyphs`（DejaVu Sans Bold 离线栅格化的位图游程）。
  """
  alias Newbee.Web.CaptchaGlyphs

  @w 132
  @h 44

  # 调色板（PLTE 顺序即索引）：0 背景 1 字形 2 噪声线 3 噪声点
  @palette [{240, 243, 248}, {30, 36, 48}, {150, 160, 180}, {120, 132, 155}]

  @doc "把验证码文本渲染成 PNG 字节串"
  def render(text) when is_binary(text) do
    glyphs =
      text
      |> String.graphemes()
      |> Enum.map(&CaptchaGlyphs.glyph/1)
      |> Enum.flat_map(fn
        {:ok, g} -> [g]
        :error -> []
      end)

    glyphs
    |> glyph_canvas()
    |> add_noise()
    |> encode()
  end

  def width, do: @w
  def height, do: @h

  # ── 画布：行主序的一维调色板索引数组 ──

  defp blank, do: :array.new(@w * @h, default: 0)

  defp put(cv, x, y, color)
       when is_integer(x) and is_integer(y) and x >= 0 and x < @w and y >= 0 and y < @h do
    :array.set(y * @w + x, color, cv)
  end

  defp put(cv, _x, _y, _color), do: cv

  # 每个字形画一个按比例缩放的实心矩形（最近邻），再叠一层斜切做干扰
  defp glyph_canvas(glyphs) do
    gap = 5
    n = max(length(glyphs), 1)
    available_w = @w - 12 - gap * (n - 1)
    max_w = Enum.reduce(glyphs, 1, fn g, acc -> max(acc, g.w) end) * length(glyphs)
    max_h = Enum.reduce(glyphs, 1, fn g, acc -> max(acc, g.h) end)

    scale =
      min(
        max(available_w / max(max_w, 1), 0.6),
        max((@h - 8) / max(max_h, 1), 0.6)
      )

    x0 = 6

    {_, cv} =
      Enum.reduce(glyphs, {x0, blank()}, fn g, {cx, cv} ->
        shear = :rand.uniform(5) - 2
        y_off = max(div(@h - round(g.h * scale), 2), 2) + (:rand.uniform(5) - 3)
        w = round(g.w * scale)

        cv =
          Enum.reduce(g.runs, cv, fn {rx0, rx1, ry}, cv ->
            y_top = y_off + round(ry * scale)
            y_bot = max(y_off + round((ry + 1) * scale) - 1, y_top)
            skew = div(shear * ry, max(g.h, 1))
            x_left = cx + round(rx0 * scale) + skew
            x_right = max(cx + round((rx1 + 1) * scale) - 1 + skew, x_left)

            for yy <- y_top..y_bot, xx <- x_left..x_right, reduce: cv do
              cv -> put(cv, xx, yy, 1)
            end
          end)

        {cx + w + gap, cv}
      end)

    cv
  end

  # 噪声：几条随机折线 + 一堆小点（画在字形之上）
  defp add_noise(cv) do
    cv =
      Enum.reduce(1..4, cv, fn _, cv ->
        ax = :rand.uniform(@w) - 1
        ay = :rand.uniform(@h) - 1
        bx = :rand.uniform(@w) - 1
        by = :rand.uniform(@h) - 1
        steps = max(abs(bx - ax), abs(by - ay)) + 1

        Enum.reduce(0..steps, cv, fn i, cv ->
          t = i / steps
          put(cv, round(ax + (bx - ax) * t), round(ay + (by - ay) * t), 2)
        end)
      end)

    Enum.reduce(1..25, cv, fn _, cv ->
      dx = :rand.uniform(@w) - 1
      dy = :rand.uniform(@h) - 1

      for oy <- -1..1, ox <- -1..1, reduce: cv do
        cv -> put(cv, dx + ox, dy + oy, 3)
      end
    end)
  end

  # ── PNG 编码：8bit 索引色（color type 3），IDAT 用 zlib 流 ──

  defp encode(cv) do
    rows =
      for y <- 0..(@h - 1) do
        row = for x <- 0..(@w - 1), do: <<:array.get(y * @w + x, cv)>>
        <<0>> <> IO.iodata_to_binary(row)
      end

    ihdr = <<@w::32, @h::32, 8, 3, 0, 0, 0>>
    plte = Enum.map_join(@palette, fn {r, g, b} -> <<r, g, b>> end)
    idat = :zlib.compress(IO.iodata_to_binary(rows))

    <<0x89, "PNG", "\r\n\x1a\n">> <>
      chunk("IHDR", ihdr) <>
      chunk("PLTE", plte) <>
      chunk("IDAT", idat) <>
      chunk("IEND", <<>>)
  end

  defp chunk(type, data) do
    t = if byte_size(type) == 4, do: type, else: raise(ArgumentError, "chunk type 必须4 字节")
    <<byte_size(data)::32, t::binary, data::binary, :erlang.crc32(t <> data)::32>>
  end
end
