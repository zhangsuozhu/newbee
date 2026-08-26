defmodule Newbee.Tools.EditV2Test do
  use ExUnit.Case, async: false

  alias Newbee.Tools.Edit.SnapshotStore
  alias Newbee.Tools.Edit.V2

  setup do
    SnapshotStore.clear()
    path = Path.join(System.tmp_dir!(), "edit_v2_#{System.system_time(:native)}_#{:erlang.unique_integer([:positive])}.txt")

    on_exit(fn -> File.rm(path) end)

    %{path: path}
  end

  defp write!(path, content) do
    File.write!(path, content)
    path
  end

  defp show(path, range \\ :all), do: V2.show(path, range)

  defp patch(path_tag, body), do: V2.apply_patch("[#{path_tag}]\n" <> body)

  test "show 返回标签与行号文本", %{path: path} do
    write!(path, "a\nb\n")
    r = show(path)
    assert String.length(r.tag) == 12
    assert r.text == "1| a\n2| b"
    assert r.lines == 2
  end

  test "PUT 范围替换 + CUT + 头部插入", %{path: path} do
    write!(path, "l1\nl2\nl3\nl4\nl5\n")
    r = show(path)

    patch(path <> "#" <> r.tag, "PUT 2..3:\n+L2-new\n+L3-new\nCUT 5\nPUT <1:\n+HEAD\n")

    assert File.read!(path) == "HEAD\nl1\nL2-new\nL3-new\nl4\n"
  end

  test "尾部插入 PUT >N", %{path: path} do
    write!(path, "a\nb\n")
    r = show(path)
    patch(path <> "#" <> r.tag, "PUT >2:\n+c\n")
    assert File.read!(path) == "a\nb\nc\n"
  end

  test "无尾换行文件保留约定", %{path: path} do
    write!(path, "a\nb")
    r = show(path)
    patch(path <> "#" <> r.tag, "PUT >2:\n+c\n")
    assert File.read!(path) == "a\nb\nc"
  end

  test "重复行：按行号精确替换不歧义", %{path: path} do
    write!(path, "dup\ndup\nkeep\n")
    r = show(path)
    patch(path <> "#" <> r.tag, "PUT 2..2:\n+dup-new\n")
    assert File.read!(path) == "dup\ndup-new\nkeep\n"
  end

  test "stale 拒绝且不落盘", %{path: path} do
    write!(path, "x\ny\nz\n")
    r = show(path)
    write!(path, "x\nY\nz\n")

    assert_raise V2.RejectError, fn ->
      patch(path <> "#" <> r.tag, "CUT 2\n")
    end

    assert File.read!(path) == "x\nY\nz\n"
  end

  test "未读范围拒绝", %{path: path} do
    write!(path, "x\ny\nz\n")
    r = show(path, {1, 1})

    assert_raise V2.RejectError, fn ->
      patch(path <> "#" <> r.tag, "CUT 2..3\n")
    end
  end

  test "范围重叠拒绝", %{path: path} do
    write!(path, "x\ny\nz\n")
    r = show(path)

    assert_raise V2.RejectError, fn ->
      patch(path <> "#" <> r.tag, "CUT 1..2\nCUT 2..3\n")
    end
  end

  test "no-op 拒绝", %{path: path} do
    write!(path, "same\n")
    r = show(path)

    assert_raise V2.RejectError, fn ->
      patch(path <> "#" <> r.tag, "PUT 1..1:\n+same\n")
    end
  end

  test "未知标签拒绝", %{path: path} do
    write!(path, "a\n")

    assert_raise V2.RejectError, fn ->
      patch(path <> "#000000000000", "PUT 1..1:\n+b\n")
    end
  end

  test "越界拒绝", %{path: path} do
    write!(path, "a\n")
    r = show(path)

    assert_raise V2.RejectError, fn ->
      patch(path <> "#" <> r.tag, "CUT 1..5\n")
    end
  end

  test "多节原子性：任一节失败全部不落盘", %{path: path} do
    p2 = path <> ".2"
    on_exit(fn -> File.rm(p2) end)
    write!(path, "A1\nA2\n")
    write!(p2, "B1\nB2\n")
    s1 = show(path)
    s2 = show(p2)
    write!(p2, "B1\nCHANGED\n")

    assert_raise V2.RejectError, fn ->
      V2.apply_patch("""
      [#{path}##{s1.tag}]
      PUT 1..1:
      +AA
      [#{p2}##{s2.tag}]
      PUT 1..1:
      +BB
      """)
    end

    assert File.read!(path) == "A1\nA2\n"
    assert File.read!(p2) == "B1\nCHANGED\n"
  end

  test "成功后新标签可继续编辑（快照链）", %{path: path} do
    write!(path, "a\nb\n")
    r1 = show(path)
    %{files: [f]} = patch(path <> "#" <> r1.tag, "PUT 1..1:\n+A\n")
    assert File.read!(path) == "A\nb\n"
    r2_tag = f.new_tag
    patch(path <> "#" <> r2_tag, "PUT 2..2:\n+B\n")
    assert File.read!(path) == "A\nB\n"
  end

  test "读融合：同内容多次部分读取合并已读范围", %{path: path} do
    write!(path, "1\n2\n3\n4\n")
    show(path, {1, 2})
    show(path, {3, 4})
    r = show(path, {2, 3})

    # 1..4 全部读过 → 编辑 4 行应通过
    patch(path <> "#" <> r.tag, "CUT 1..4\n")
    assert File.read!(path) == ""
  end
end
