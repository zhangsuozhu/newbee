defmodule Newbee.Truncate.WindowTest do
  use ExUnit.Case, async: true

  alias Newbee.Truncate.Window

  defp render(text, head, tail, chunk \\ nil) do
    window = Window.new(head, tail)

    window =
      case chunk do
        nil -> Window.push(window, text)
        n -> text |> chunks(n) |> Enum.reduce(window, &Window.push(&2, &1))
      end

    Window.render(window)
  end

  defp chunks(text, size), do: do_chunks(text, size, [])

  defp do_chunks("", _size, acc), do: Enum.reverse(acc)
  defp do_chunks(bin, size, acc) when byte_size(bin) <= size, do: Enum.reverse([bin | acc])

  defp do_chunks(bin, size, acc) do
    do_chunks(binary_part(bin, size, byte_size(bin) - size), size, [binary_part(bin, 0, size) | acc])
  end

  describe "未超出窗口" do
    test "tail 窗口装得下：原样，无标记" do
      text = "hello\nworld\n"
      r = render(text, 4_800, 3_200)

      refute r.truncated
      assert r.text == text
      assert r.omitted_bytes == 0
      refute r.text =~ "截断"
    end

    test "head/tail 重叠但可精确重建：不报截断，也不撑大结果" do
      # head 10 + tail 10 = 20 >= total 20 —— 旧实现会报"省略 10 bytes"并把
      # 结果撑成 head+标记+tail，这里必须一个字节都不丢地还原
      text = "0123456789ABCDEFGHIJ"
      r = render(text, 10, 10)

      refute r.truncated
      assert r.text == text
      assert r.omitted_bytes == 0
      assert r.original_bytes == 20
    end

    test "部分重叠（total 落在 tail_bytes 与 head+tail 之间）也能精确重建" do
      # 16 bytes
      text = "0123456789ABCDEF"
      r = render(text, 10, 6)
      assert r.text == text
      refute r.truncated

      r2 = render(text <> "XY", 10, 10)
      assert r2.text == text <> "XY"
      refute r2.truncated
    end
  end

  describe "真的丢字节时才报截断" do
    test "省略量 = 原文 - 实际保留，且只保留头尾" do
      text = Enum.map_join(1..100, "\n", &"line #{&1}") <> "\n"
      r = render(text, 100, 100)

      assert r.truncated
      assert r.original_bytes == byte_size(text)
      # kept = 实际留在预览里的字节；整行对齐后可能略少于 head+tail 预算，但回退有界
      assert r.kept_bytes <= 200
      assert r.kept_bytes >= 100
      assert r.omitted_bytes == byte_size(text) - r.kept_bytes

      assert String.starts_with?(r.text, "line 1\n")
      assert String.ends_with?(r.text, "\n")
      assert r.text =~ "截断: 省略 "
    end

    test "旧实现的谎报被消除：16KB/16KB 窗口下 20KB 输出不再声称省略" do
      text = String.duplicate("x", 20_000)
      r = render(text, 16_000, 16_000)

      refute r.truncated
      assert r.text == text
      assert r.omitted_bytes == 0
    end
  end

  describe "流式等价性" do
    test "任意切块方式得到同一结果" do
      text = Enum.map_join(1..500, "\n", &"log line #{&1}: something happened") <> "\n"

      whole = render(text, 4_800, 3_200)

      for size <- [1, 3, 7, 64, 1_000] do
        assert render(text, 4_800, 3_200, size) == whole, "chunk size #{size} diverged"
      end
    end

    test "大输出的流式结果与一次性结果一致" do
      text = String.duplicate("abcdefghij", 5_000)

      whole = render(text, 16_000, 16_000)

      for size <- [13, 4_096, 65_536] do
        assert render(text, 16_000, 16_000, size) == whole, "chunk size #{size} diverged"
      end
    end
  end

  describe "切割质量" do
    test "整行对齐：正文只由完整行构成" do
      text = String.duplicate("aaaaaaaaaa\n", 2_000)
      r = render(text, 4_800, 3_200)

      body = String.replace(r.text, ~r|\n… \[截断:.*?\] …\n|s, "")
      lines = body |> String.trim_trailing("\n") |> String.split("\n")
      assert Enum.all?(lines, &(&1 == "aaaaaaaaaa"))
    end

    test "UTF-8 安全：多字节字符不被切碎" do
      text = String.duplicate("错误行：编译失败\n", 800)
      r = render(text, 4_800, 3_200)

      refute String.contains?(r.text, "\uFFFD")
    end

    test "二进制输入不炸、不误判为空，且回退有界" do
      text = :crypto.strong_rand_bytes(20_000)
      r = render(text, 4_800, 3_200)

      assert r.truncated
      assert r.kept_bytes >= 6_900
    end

    test "head/tail 预算为 0 的退化情形：只留标记，不假装有内容" do
      r = render("abc", 0, 0)
      assert r.omitted_bytes == 3
      assert r.text =~ "截断: 省略 3 bytes"

      assert render("", 10, 10).text == ""
      refute render("", 10, 10).truncated
    end
  end
end
