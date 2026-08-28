<<<data origin="file:test/newbee/tools/edittest_test.exs" hash="63fb6ebe30227c85" trust="untrusted" bytes="9502">>
defmodule Newbee.Tools.EditTest do
  use ExUnit.Case, async: true
  alias Newbee.Tools.Edit

  @content "line one\nline two\nline three\n"

  defp tmpfile(content \\ @content) do
    path = Path.join(System.tmp_dir!(), "edit_test_#{System.system_time(:native)}_#{:erlang.unique_integer([:positive])}.txt")
    File.write!(path, content)
    on_exit(fn -> File.rm(path) end)
    path
  end

  # 从 show 文本取第 n 行的 8 位 hash
  defp anch(text, n) do
    Regex.run(~r/^#{n}#([0-9a-f]{8})/m, text) |> List.last()
  end

  # 锚点对：第 n 行 + 相邻行 m
  defp pair(text, n, m), do: "#{n}.##{anch(text, n)}|#{m}.##{anch(text, m)}"

  test "show 带锚点与快照 tag（8 位 hash，无幻影空行）", %{} do
    path = tmpfile()
    %{tag: tag, text: text, lines: lines} = Edit.show(path)
    assert is_binary(tag) and byte_size(tag) == 8
    assert lines == 3
    # 以 \n 结尾的 3 行文件不再显示第 4 条幻影空行
    assert String.split(text, "\n") |> length() == 3
    assert text =~ "1#"
    assert text =~ "line one"
    assert text =~ ~r/^1#[0-9a-f]{8}\|/
  end

  test "PUT 替换行（锚点对）", %{} do
    path = tmpfile()
    %{tag: tag, text: text} = Edit.show(path)

    Edit.patch("""
    [#{path}##{tag}]
    PUT #{pair(text, 2, 1)}:
    +LINE TWO
    """)

    assert File.read!(path) == "line one\nLINE TWO\nline three\n"
  end

  test "插入与删除（同补丁多 op）", %{} do
    path = tmpfile()
    %{tag: tag, text: text} = Edit.show(path)

    Edit.patch("""
    [#{path}##{tag}]
    PUT <#{pair(text, 2, 1)}:
    +inserted
    CUT #{pair(text, 1, 2)}
    """)

    assert File.read!(path) == "inserted\nline two\nline three\n"
  end

  test "数错行自动重定位（hash 对为准，行号只是提示）", %{} do
    path = tmpfile()
    %{tag: tag, text: text} = Edit.show(path)

    # 模型想改第 3 行，但行号数错写成 2/1；hash 对仍是第 3+2 行 → 重定位到第 3 行
    wrong = "#{2}.##{anch(text, 3)}|#{1}.##{anch(text, 2)}"

    %{warnings: warns} =
      Edit.patch("""
      [#{path}##{tag}]
      PUT #{wrong}:
      +X
      """)

    assert File.read!(path) == "line one\nline two\nX\n"
    assert Enum.any?(warns, &(&1 =~ "重定位"))
  end

  test "空行锚点：上下文消歧成功", %{} do
    path = tmpfile("head\n\n\nfoot\n")
    %{tag: tag, text: text} = Edit.show(path)
    # 第 2、3 行都是空行（hash 相同）；上下文取第 1 行（内容唯一）
    Edit.patch("""
    [#{path}##{tag}]
    PUT >#{pair(text, 2, 1)}:
    +INS
    """)

    assert File.read!(path) == "head\n\nINS\n\nfoot\n"
  end

  test "空行数错且上下文行不相邻 → 拒绝", %{} do
    path = tmpfile("head\n\n\nfoot\n")
    %{tag: tag, text: text} = Edit.show(path)

    # 想插到第 2 个空行后，数错成第 3 行，但上下文仍抄第 1 行：|3-1|=2 不相邻
    bad = "#{3}.##{anch(text, 3)}|#{1}.##{anch(text, 1)}"

    assert_raise Edit.ParseError, ~r/相邻/, fn ->
      Edit.patch("""
      [#{path}##{tag}]
      PUT >#{bad}:
      +INS
      """)
    end

    assert File.read!(path) == "head\n\n\nfoot\n"
  end

  test "缺少上下文锚点 → ParseError", %{} do
    path = tmpfile()
    %{tag: tag, text: text} = Edit.show(path)

    assert_raise Edit.ParseError, ~r/上下文/, fn ->
      Edit.patch("""
      [#{path}##{tag}]
      PUT 2.##{anch(text, 2)}:
      +X
      """)
    end

    assert File.read!(path) == @content
  end

  test "内容行忘写 + → ParseError（不再静默丢行）", %{} do
    path = tmpfile()
    %{tag: tag, text: text} = Edit.show(path)

    assert_raise Edit.ParseError, ~r/必须以 \+ 开头/, fn ->
      Edit.patch("""
      [#{path}##{tag}]
      PUT <#{pair(text, 2, 1)}:
      +keepme
      lost line (忘了加 +)
      """)
    end

    assert File.read!(path) == @content
  end

  test "++ 转义：插入字面 + 开头的行", %{} do
    path = tmpfile()
    %{tag: tag, text: text} = Edit.show(path)

    Edit.patch("""
    [#{path}##{tag}]
    PUT <#{pair(text, 1, 2)}:
    ++literal plus
    """)

    assert File.read!(path) == "+literal plus\nline one\nline two\nline three\n"
  end

  test "同一行两次插入：顺序保持（不反转）", %{} do
    path = tmpfile()
    %{tag: tag, text: text} = Edit.show(path)

    Edit.patch("""
    [#{path}##{tag}]
    PUT <#{pair(text, 2, 1)}:
    +first
    PUT <#{pair(text, 2, 1)}:
    +second
    """)

    assert File.read!(path) == "line one\nfirst\nsecond\nline two\nline three\n"
  end

  test "多节补丁原子性：任一锚点失败全部不落盘", %{} do
    p1 = tmpfile("A1\nA2\n")
    p2 = tmpfile("B1\nB2\n")
    %{tag: t1, text: t1t} = Edit.show(p1)
    %{tag: t2, text: t2t} = Edit.show(p2)

    assert_raise Edit.AnchorError, fn ->
      Edit.patch("""
      [#{p1}##{t1}]
      PUT #{pair(t1t, 1, 2)}:
      +AA
      [#{p2}##{t2}]
      PUT 9.##{anch(t2t, 1)}|8.##{anch(t2t, 2)}:
      +BB
      """)
    end

    assert File.read!(p1) == "A1\nA2\n"
    assert File.read!(p2) == "B1\nB2\n"
  end

  test "快照 tag 过期：锚点全中照常应用 + 警告", %{} do
    path = tmpfile()
    %{tag: _tag, text: text} = Edit.show(path)

    %{warnings: warns} =
      Edit.patch("""
      [#{path}#00000000]
      PUT #{pair(text, 2, 1)}:
      +X
      """)

    assert File.read!(path) == "line one\nX\nline three\n"
    assert Enum.any?(warns, &(&1 =~ "快照过期"))
  end

  test "锚点不匹配拒绝且文件不动", %{} do
    path = tmpfile()
    %{tag: tag, text: text} = Edit.show(path)

    # 把第 1 行的 hash 贴到第 2 行（上下文也是第 1 行 hash）→ 锚点对整体对不上
    bad = "#{2}.##{anch(text, 1)}|#{1}.##{anch(text, 1)}"

    assert_raise Edit.AnchorError, ~r/锚点不匹配/, fn ->
      Edit.patch("""
      [#{path}##{tag}]
      PUT #{bad}:
      +x
      """)
    end

    assert File.read!(path) == @content
  end

  test "上下文行 hash 错 → 拒绝", %{} do
    path = tmpfile()
    %{tag: tag, text: text} = Edit.show(path)
    # 目标行 hash 对，但上下文行 hash 抄错（第 3 行的 hash 当第 1 行用）
    bad = "#{2}.##{anch(text, 2)}|#{1}.##{anch(text, 3)}"

    assert_raise Edit.AnchorError, ~r/锚点不匹配/, fn ->
      Edit.patch("""
      [#{path}##{tag}]
      PUT #{bad}:
      +x
      """)
    end

    assert File.read!(path) == @content
  end

  test "尾部换行约定保留：无尾换行文件替换后仍无尾换行", %{} do
    path = tmpfile("a\nb")
    %{tag: tag, text: text} = Edit.show(path)

    Edit.patch("""
    [#{path}##{tag}]
    PUT #{pair(text, 2, 1)}:
    +X
    """)

    assert File.read!(path) == "a\nX"
  end

  test "show 标记：dup / trail / cr", %{} do
    p1 = tmpfile("x\n\n\ny\n")
    %{text: t1} = Edit.show(p1)
    assert t1 =~ ~r/^2#[0-9a-f]{8}\[dup:2,3\]/m

    p2 = tmpfile("x = 1   \nz\n")
    %{text: t2} = Edit.show(p2)
    assert t2 =~ "⟪trail⟫"

    p3 = tmpfile("one\r\ntwo\r\n")
    %{text: t3} = Edit.show(p3)
    assert t3 =~ "⟪cr⟫"
  end

  test "空文件补丁", %{} do
    path = tmpfile("")
    %{tag: tag, text: text} = Edit.show(path)
    assert text =~ ~r/^1#[0-9a-f]{8}\|/

    Edit.patch("""
    [#{path}##{tag}]
    PUT 1.##{anch(text, 1)}:
    +hello
    """)

    assert File.read!(path) == "hello"
  end

  test "单行文件补丁（上下文可选）", %{} do
    path = tmpfile("solo")
    %{tag: tag, text: text} = Edit.show(path)

    Edit.patch("""
    [#{path}##{tag}]
    PUT 1.##{anch(text, 1)}:
    +new
    """)

    assert File.read!(path) == "new"
  end

  test "范围替换 2..3", %{} do
    path = tmpfile()
    %{tag: tag, text: text} = Edit.show(path)

    Edit.patch("""
    [#{path}##{tag}]
    PUT #{pair(text, 2, 1)}=#{pair(text, 3, 2)}:
    +X
    +Y
    """)

    assert File.read!(path) == "line one\nX\nY\n"
  end

  test "重叠区间拒绝", %{} do
    path = tmpfile("a\nb\nc\nd\n")
    %{tag: tag, text: text} = Edit.show(path)

    assert_raise Edit.AnchorError, ~r/重叠/, fn ->
      Edit.patch("""
      [#{path}##{tag}]
      CUT #{pair(text, 1, 2)}=#{pair(text, 3, 4)}
      CUT #{pair(text, 3, 2)}=#{pair(text, 4, 3)}
      """)
    end

    assert File.read!(path) == "a\nb\nc\nd\n"
  end

  test "同一补丁内同文件两个节头 → 拒绝", %{} do
    path = tmpfile()
    %{tag: tag, text: text} = Edit.show(path)

    assert_raise Edit.ParseError, ~r/只能出现一个节头/, fn ->
      Edit.patch("""
      [#{path}##{tag}]
      PUT #{pair(text, 2, 1)}:
      +X
      [#{path}##{tag}]
      PUT #{pair(text, 3, 2)}:
      +Y
      """)
    end

    assert File.read!(path) == @content
  end

  test "补丁内容带 [ 开头的行（未加 +）→ 友好 ParseError 而非崩溃", %{} do
    path = tmpfile()
    %{tag: tag, text: text} = Edit.show(path)

    assert_raise Edit.ParseError, ~r/节头|\+ 开头/, fn ->
      Edit.patch("""
      [#{path}##{tag}]
      PUT <#{pair(text, 2, 1)}:
      +keep
      [foo: 1]
      """)
    end

    assert File.read!(path) == @content
  end

  test "PUT 行后跟内容行（忘加 + 且以 PUT 开头）→ 友好 ParseError", %{} do
    path = tmpfile()
    %{tag: tag, text: text} = Edit.show(path)

    assert_raise Edit.ParseError, ~r/操作格式错误|锚点格式错误|\+ 开头/, fn ->
      Edit.patch("""
      [#{path}##{tag}]
      PUT <#{pair(text, 2, 1)}:
      +keep
      PUT not-a-number
      """)
    end

    assert File.read!(path) == @content
  end
end

<<<end 63fb6ebe30227c85>>>
