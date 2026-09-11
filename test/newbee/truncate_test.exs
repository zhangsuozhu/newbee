defmodule Newbee.TruncateTest do
  use ExUnit.Case, async: true

  alias Newbee.{Spill, Truncate}

  defp uniq(prefix), do: prefix <> "-" <> Integer.to_string(System.unique_integer([:positive]))

  defp noisy_log(size, err_line) do
    before = Enum.map_join(1..500, "\n", &"Compiling mod_#{&1}.ex ... ok")
    after_ = Enum.map_join(1..size, "\n", &"Compiling mod_#{&1}.ex ... ok")
    before <> "\n" <> err_line <> "\n" <> after_ <> "\n"
  end

  # Spill.read/2 一次只给一页（表头预留算在预算内），这里串起来读回全文。
  defp read_all(id), do: do_read_all(id, 0, [])

  defp do_read_all(id, offset, acc) do
    {:ok, page} = Spill.read(id, offset: offset, max_bytes: 4_096)
    acc = [page.text | acc]

    if page.eof do
      IO.iodata_to_binary(Enum.reverse(acc))
    else
      do_read_all(id, page.next_offset, acc)
    end
  end

  describe "head_tail/2 基本行为" do
    test "未超预算：原样返回，不落盘、不加标记" do
      text = uniq("short") <> "\n"

      result = Truncate.head_tail(text, max_bytes: 8_000)

      refute result.truncated
      assert result.text == text
      assert result.handle == nil
      assert result.omitted_bytes == 0
      assert result.original_bytes == byte_size(text)
      refute result.text =~ "截断"
    end

    test "超预算：头尾保留 + 标记 + 句柄；句柄读回完整原文" do
      text = String.duplicate("line\n", 10_000)

      result = Truncate.head_tail(text, max_bytes: 8_000, source: "test")

      assert result.truncated
      assert byte_size(result.text) < byte_size(text)
      assert result.text =~ "截断"

      # 头尾都还在
      assert String.starts_with?(result.text, "line\n")
      assert String.ends_with?(result.text, "line\n")

      assert is_map(result.handle)
      assert read_all(result.handle.id) == text
    end

    test "省略量与原文量自洽" do
      text = String.duplicate("abcdefghij\n", 3_000)
      result = Truncate.head_tail(text, max_bytes: 8_000)

      assert result.original_bytes == byte_size(text)
      assert result.kept_bytes == byte_size(result.text) - marker_size(result)
      assert result.omitted_bytes == result.original_bytes - result.kept_bytes
    end
  end

  describe "切割质量" do
    test "UTF-8 安全：多字节字符不被切碎" do
      text = String.duplicate("错误行：编译失败\n", 800)

      result = Truncate.head_tail(text, max_bytes: 8_000)

      refute String.contains?(result.text, "\uFFFD")
      assert String.valid?(result.text)
    end

    test "整行对齐：预览正文不出现残行" do
      text = String.duplicate("aaaaaaaaaa\n", 2_000)

      result = Truncate.head_tail(text, max_bytes: 8_000)
      body = String.replace(result.text, ~r|\n… \[截断:.*?\] …\n|s, "")

      # 正文只应由完整行构成
      assert body |> String.trim_trailing("\n") |> String.split("\n") |> Enum.all?(&(&1 == "aaaaaaaaaa"))
    end

    test "二进制/非法 UTF-8 输入不炸、不误判为空，且对齐回退有界" do
      text = :crypto.strong_rand_bytes(20_000)

      result = Truncate.head_tail(text, max_bytes: 8_000)

      assert result.truncated
      # 整行对齐的回退被 @snap_window 钉成常数：8000 预算至少保住 6900 字节
      assert result.kept_bytes >= 6_900
      # 非法 UTF-8 源保持原样（交下游 sanitize），不清空
      assert byte_size(result.text) >= result.kept_bytes
    end
  end

  describe "更外层句柄" do
    test "输入里已带更完整的句柄时，标记优先展示它并报其真实字节数" do
      full = noisy_log(2_000, "ERROR: undefined function foo/1")
      assert {:ok, outer} = Spill.store(full, source: "test-outer")

      # 模拟外层（终端/Ring0）已经给出的预览 + 句柄
      inner_text =
        String.slice(full, 0, 20_000) <>
          ~s|\n… [截断: 省略 12345 bytes · 原文 #{byte_size(full)} bytes · 完整原文: Newbee.read("spill://#{outer.id}")] …\n| <>
          String.slice(full, -20_000, 20_000)

      result = Truncate.head_tail(inner_text, max_bytes: 8_000)

      assert result.deeper.id == outer.id
      assert result.deeper.bytes == byte_size(full)
      assert result.text =~ outer.id
      assert result.text =~ "原文 #{byte_size(full)} bytes"
      # 不再嵌套展示本层句柄
      refute result.text =~ result.handle.id
    end

    test "句柄不可读时回退到本层句柄" do
      ghost = String.duplicate("c", 64)
      text = String.duplicate("line\n", 5_000) <> ~s|ref spill://#{ghost}|

      result = Truncate.head_tail(text, max_bytes: 8_000)

      assert result.deeper == nil
      assert result.text =~ result.handle.id
    end
  end

  describe "降级" do
    test "spill: false 时标记明说原文已丢弃（不留假希望）" do
      text = String.duplicate("line\n", 5_000)

      result = Truncate.head_tail(text, max_bytes: 8_000, spill: false)

      assert result.handle == nil
      assert result.text =~ "原文已丢弃，无法回读"
      refute result.text =~ "spill://"
      assert result.text =~ "省略"
    end

    test "标记格式稳定" do
      text = String.duplicate("line\n", 5_000)
      result = Truncate.head_tail(text, max_bytes: 8_000)

      assert result.text =~
               ~r|\n… \[截断: 省略 \d+ bytes · 原文 \d+ bytes · 完整原文: Newbee\.read\("spill://[a-f0-9]{64}"\)\] …\n|
    end
  end

  describe "验收：长日志中段的错误行" do
    test "预览看不到，但句柄能原样读回含错误行的全文" do
      err = "ERROR: undefined function foo/1 (lib/core.ex:142)"
      text = noisy_log(900, err)
      assert byte_size(text) > 30_000

      result = Truncate.head_tail(text, max_bytes: 8_000)

      # 头尾预览里确实看不到（这就是要修的病）
      refute result.text =~ "undefined function foo/1"

      # 但现在有可执行的句柄，读回的字节与原文逐字节相等
      assert read_all(result.handle.id) =~ err
      assert read_all(result.handle.id) == text
    end

    test "分页读完仍能拼回含错误行的全文" do
      err = "ERROR: undefined function foo/1"
      text = noisy_log(600, err)

      result = Truncate.head_tail(text, max_bytes: 4_000)
      id = result.handle.id

      {parts, _last} =
        Enum.reduce_while(1..200, {[], 0}, fn _i, {acc, offset} ->
          {:ok, page} = Spill.read(id, offset: offset, max_bytes: 4_096)
          acc = [page.text | acc]
          if page.eof, do: {:halt, {acc, page}}, else: {:cont, {acc, page.next_offset}}
        end)

      assert IO.iodata_to_binary(Enum.reverse(parts)) == text
      assert IO.iodata_to_binary(Enum.reverse(parts)) =~ err
    end
  end

  # 标记自身占用的字节数（用于反推 kept_bytes）
  defp marker_size(result) do
    [marker] = Regex.run(~r|\n… \[截断:.*?\] …\n|s, result.text)
    byte_size(marker)
  end
end
