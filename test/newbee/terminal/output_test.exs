defmodule Newbee.Terminal.OutputTest do
  # 纯函数，不碰 PTY。
  use ExUnit.Case, async: true

  alias Newbee.Terminal.Output

  # 按块喂入，模拟 PTY 分片到达（转义序列与 CRLF 都可能被切开）。
  defp clean(chunks) do
    {st, out} =
      Enum.reduce(List.wrap(chunks), {Output.new(), ""}, fn chunk, {st, acc} ->
        {st, text} = Output.push(st, chunk)
        {st, acc <> text}
      end)

    {_st, tail} = Output.finish(st)
    out <> tail
  end

  test "普通文本按行输出，行尾归一成 LF" do
    assert clean("hello\r\nworld\r\n") == "hello\nworld\n"
    assert clean(["a\r\n", "b\r\n"]) == "a\nb\n"
  end

  test "剥离 CSI 颜色与键区模式序列" do
    assert clean("\e[31mRED\e[0m\r\n") == "RED\n"
    assert clean("\e[?1h\e=\e[33mx\e[m\r\n\r\e[K\e[?1l\e>") == "x\n"
  end

  test "剥离 OSC（BEL 与 ST 两种结尾）" do
    assert clean("\e]0;title\aabc\r\n") == "abc\n"
    assert clean("\e]0;title\e\\abc\r\n") == "abc\n"
  end

  test "转义序列被切在块边界时不会吐出半截" do
    assert clean(["\e[3", "1mX\e", "[0m\r", "\n"]) == "X\n"
    assert clean(["abc\r", "\ndef"]) == "abc\ndef"
  end

  test "CR 覆盖与进度条只保留最终内容" do
    assert clean("aaa\rbbb\rccc\r\n") == "ccc\n"
    assert clean("10%\r20%\r30%\rdone\r\n") == "done\n"
  end

  test "退格删除整个字符，不会切碎 UTF-8" do
    assert clean("abc\b\bX\r\n") == "aX\n"
    assert clean("中文\b\bX\r\n") == "X\n"
  end

  test "不可见控制字符与 DEL 被丢弃，TAB 保留" do
    assert clean("a\x01b\x07c\x7f\r\n") == "abc\n"
    assert clean("a\tb\r\n") == "a\tb\n"
  end

  test "未完成的转义序列在收尾时丢弃，不当作内容" do
    assert clean("abc\e]0;nope") == "abc"
  end

  test "行尾孤立 CR 不产生多余空行" do
    assert clean("abc\r") == "abc"
  end

  test "空输入与纯 CRLF 的边界" do
    assert clean("") == ""
    assert clean("\r\n") == "\n"
  end

  test "超长单行不会被行缓冲无限累积" do
    line = String.duplicate("x", 70_000)
    out = clean(line <> "\r\n")
    assert out == line <> "\n"
  end
end
