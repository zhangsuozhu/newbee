# 验证码 PNG 化（设计级待办①的落地）：
#   旧实现下发 <svg> 且用 <text> 逐字写答案 → 脚本一行正则就能读出
#   （浏览器轮次 R49 实测 T7Bv/CZBa/Bxft 被服务端接受为正确验证码）；
#   现在服务端只下发 data:image/png;base64 的像素：
#     · PNG 结构必须合法（签名 / IHDR 尺寸与颜色类型 / 每块 CRC / IDAT 能解出完整位图）
#     · 返回里绝不能再有矢量或文本字段可被脚本直接解析
defmodule Newbee.Web.CaptchaPngTest do
  use ExUnit.Case, async: true

  alias Newbee.Web.Auth

  @png_magic <<137, 80, 78, 71, 13, 10, 26, 10>>

  defp decode(uri) do
    assert String.starts_with?(uri, "data:image/png;base64,")
    Base.decode64!(String.replace_prefix(uri, "data:image/png;base64,", ""))
  end

  defp chunks(<<len::32, type::binary-size(4), data::binary-size(len), crc::32, rest::binary>>, acc) do
    assert :erlang.crc32(type <> data) == crc, "PNG chunk CRC 不匹配: #{type}"
    chunks(rest, [{type, data} | acc])
  end

  defp chunks(<<>>, acc), do: Enum.reverse(acc)

  test "验证码是结构合法的 PNG，IDAT 能解出完整位图" do
    cap = Auth.gen_captcha()
    png = decode(cap.image)

    assert binary_part(png, 0, 8) == @png_magic

    <<_sig::binary-size(8), ihdr_len::32, "IHDR", ihdr::binary-size(ihdr_len), _crc::32, _::binary>> = png
    <<w::32, h::32, depth, color, comp, filt, interlace>> = ihdr

    assert w > 0 and h > 0
    assert {depth, color, comp, filt, interlace} == {8, 3, 0, 0, 0}

    chs = chunks(binary_part(png, 8, byte_size(png) - 8), [])
    assert List.keyfind(chs, "PLTE", 0)
    assert List.keyfind(chs, "IEND", 0)

    {"IDAT", idat} = List.keyfind(chs, "IDAT", 0)
    raw = :zlib.uncompress(idat)
    # 每行 = 1 字节 filter(0) + w 字节索引
    assert byte_size(raw) == h * (w + 1)
  end

  test "返回里没有可被脚本解析的矢量/文本字段" do
    cap = Auth.gen_captcha()

    refute Map.has_key?(cap, :svg), "不能再返回 svg 字段"
    refute cap.image =~ "<svg"
    refute cap.image =~ "<text"
    assert Map.keys(cap) |> Enum.sort() == [:id, :image, :text]
  end
end
