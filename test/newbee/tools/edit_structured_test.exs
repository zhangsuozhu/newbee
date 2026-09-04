defmodule Newbee.Tools.EditStructuredTest do
  use ExUnit.Case, async: false

  alias Newbee.Tools.Edit
  alias Newbee.Tools.Edit.SnapshotStore

  setup do
    SnapshotStore.clear()

    path =
      Path.join(
        System.tmp_dir!(),
        "edit_structured_#{System.system_time(:native)}_#{:erlang.unique_integer([:positive])}.txt"
      )

    on_exit(fn -> File.rm(path) end)
    %{path: path}
  end

  defp w!(path, content), do: File.write!(path, content)

  test "单文件结构化 replace + insert_before + delete", %{path: path} do
    w!(path, "l1\nl2\nl3\nl4\nl5\n")
    s = Edit.show(path)

    result =
      Edit.patch(%{
        path: path,
        tag: s.tag,
        edits: [
          %{op: :replace, range: [2, 3], content: "L2-new\nL3-new"},
          %{op: :insert_before, line: 5, content: "L4.5"},
          %{op: :delete, range: {5, 5}}
        ]
      })

    assert result.status == :applied
    assert File.read!(path) == "l1\nL2-new\nL3-new\nl4\n"
  end

  test "单操作简写：op/from/to/text", %{path: path} do
    w!(path, "a\nb\nc\n")
    s = Edit.show(path)

    result = Edit.patch(%{path: path, tag: s.tag, op: :replace, from: 2, to: 2, text: "B"})

    assert result.status == :applied
    assert File.read!(path) == "a\nB\nc\n"
  end

  test "删除简写 delete: [a, b]", %{path: path} do
    w!(path, "a\nb\nc\n")
    s = Edit.show(path)

    result = Edit.patch(%{path: path, tag: s.tag, delete: [2, 2]})

    assert result.status == :applied
    assert File.read!(path) == "a\nc\n"
  end

  test "before/after 简写", %{path: path} do
    w!(path, "a\nc\n")
    s = Edit.show(path)

    assert Edit.patch(%{path: path, tag: s.tag, before: 2, content: "B"}).status == :applied
    assert File.read!(path) == "a\nB\nc\n"

    w!(path, "a\nc\n")
    s2 = Edit.show(path)
    assert Edit.patch(%{file: path, snapshot: s2.tag, after: 1, text: "B"}).status == :applied
    assert File.read!(path) == "a\nB\nc\n"
  end

  test "键名宽容：file/snapshot/ops/changes", %{path: path} do
    w!(path, "a\nb\n")
    s = Edit.show(path)

    assert Edit.patch(%{file: path, snapshot: s.tag, ops: [%{op: "put", from: 1, to: 1, text: "A"}]}).status == :applied
    assert File.read!(path) == "A\nb\n"

    w!(path, "a\nb\n")
    s2 = Edit.show(path)
    assert Edit.patch(%{file: path, snapshot: s2.tag, changes: [%{op: "cut", from: 2, to: 2}]}).status == :applied
    assert File.read!(path) == "a\n"
  end

  test "多文件列表与 files 包", %{path: path} do
    p2 = path <> ".2"
    on_exit(fn -> File.rm(p2) end)
    w!(path, "a\n")
    w!(p2, "x\n")
    s1 = Edit.show(path)
    s2 = Edit.show(p2)

    result =
      Edit.patch([
        %{path: path, tag: s1.tag, edits: [%{op: :replace, from: 1, to: 1, content: "A"}]},
        %{path: p2, tag: s2.tag, edits: [%{op: :replace, from: 1, to: 1, content: "X"}]}
      ])

    assert result.status == :applied
    assert File.read!(path) == "A\n"
    assert File.read!(p2) == "X\n"
  end

  test "同一路径同 tag 自动合并 edits，不报重复路径", %{path: path} do
    w!(path, "a\nb\nc\n")
    s = Edit.show(path)

    result =
      Edit.patch([
        %{path: path, tag: s.tag, edits: [%{op: :replace, from: 1, to: 1, content: "A"}]},
        %{path: path, tag: s.tag, edits: [%{op: :replace, from: 2, to: 2, content: "B"}]}
      ])

    assert result.status == :applied
    assert File.read!(path) == "A\nB\nc\n"
  end

  test "不同 tag 同一路径返回冲突", %{path: path} do
    w!(path, "a\n")
    s1 = Edit.show(path)
    File.write!(path, "modified\n")
    s2 = Edit.show(path)

    assert_raise Edit.RejectError, fn ->
      Edit.patch([
        %{path: path, tag: s1.tag, edits: [%{op: :replace, from: 1, to: 1, content: "A"}]},
        %{path: path, tag: s2.tag, edits: [%{op: :replace, from: 1, to: 1, content: "B"}]}
      ])
    end
  end

  test "base64 入口并入 patch(:base64)", %{path: path} do
    w!(path, "a\nb\n")
    s = Edit.show(path)
    patch_text = "[#{path}##{s.tag}]\nPUT 1..1:\n+A\n"
    result = Edit.patch(%{base64: Base.encode64(patch_text)})
    assert result.status == :applied
    assert File.read!(path) == "A\nb\n"
  end

  test "缺少 tag 返回 ParseError 而不是静默", %{path: path} do
    w!(path, "a\n")

    assert_raise Edit.ParseError, fn ->
      Edit.patch(%{path: path, edits: [%{op: :replace, from: 1, to: 1, content: "A"}]})
    end
  end

  test "正文含引号反斜杠与 #{} 直接提交", %{path: path} do
    w!(path, "a\nb\n")
    s = Edit.show(path)
    tricky = "  def hi, do: \"quote\" \\\\ escaped"
    result = Edit.patch(%{path: path, tag: s.tag, op: :replace, from: 2, to: 2, text: tricky})
    assert result.status == :applied
    assert File.read!(path) == "a\n" <> tricky <> "\n"
  end

  test "show 返回值直传 snapshot（推荐用法）", %{path: path} do
    w!(path, "a\nb\nc\n")
    shown = Edit.show(path)

    result = Edit.patch(%{snapshot: shown, edits: [%{op: :replace, range: 2..2, content: "B"}]})

    assert result.status == :applied
    assert File.read!(path) == "a\nB\nc\n"
  end

  test "show 扩展返回值 ok:true 直传", %{path: path} do
    w!(path, "x\ny\n")
    shown = Map.put(Edit.show(path), :ok, true)

    result = Edit.patch(%{snapshot: shown, edits: [%{op: :delete, range: {2, 2}}]})

    assert result.status == :applied
    assert File.read!(path) == "x\n"
  end

  test "冲突参数 content 和 text 不一致返回 ambiguous", %{path: path} do
    w!(path, "a\nb\n")
    s = Edit.show(path)

    assert_raise Edit.ParseError, ~r/ambiguous/, fn ->
      Edit.patch(%{path: path, tag: s.tag, op: :replace, from: 1, to: 1, content: "A", text: "B"})
    end
  end

  test "无效 range 不再静默退化为全文", %{path: path} do
    w!(path, "a\nb\n")

    assert_raise Edit.ParseError, ~r/unrecognized range/, fn ->
      Edit.show(path, %{nonsense: true})
    end

    assert_raise Edit.ParseError, ~r/unrecognized range/, fn ->
      Edit.show(path, "banana")
    end
  end

  test "并发变更：show 后磁盘被改则拒绝写入", %{path: path} do
    w!(path, "l1\nl2\nl3\n")
    s = Edit.show(path)
    # 模拟外部修改
    w!(path, "CONCURRENT-CHANGE\n")

    assert_raise Edit.RejectError, fn ->
      Edit.patch(%{path: path, tag: s.tag, ops: [%{op: :replace, from: 1, to: 1, text: "X"}]})
    end

    # 文件保持并发修改的内容，未被破坏
    assert File.read!(path) == "CONCURRENT-CHANGE\n"
  end

  test "权限保留：写入后文件 mode 不变", %{path: path} do
    w!(path, "a\nb\n")
    s = Edit.show(path)
    before = File.stat!(path).mode

    Edit.patch(%{path: path, tag: s.tag, ops: [%{op: :replace, from: 1, to: 1, text: "A"}]})

    assert File.stat!(path).mode == before
  end

  test "失败原子性：第二个文件校验失败时第一个文件未被写入", %{path: path} do
    w!(path, "l1\nl2\n")
    path2 = path <> "_2.txt"
    w!(path2, "x\ny\n")
    s1 = Edit.show(path)
    s2 = Edit.show(path2)
    orig1 = File.read!(path)

    # 使 path2 校验失败：删除文件并创建同名非空目录（不可读）
    File.rm(path2)
    File.mkdir(path2)

    # plan 阶段即失败（File.Error 或 RejectError），此时 write 尚未执行
    assert_raise File.Error, fn ->
      Edit.patch([
        %{path: path, tag: s1.tag, ops: [%{op: :replace, from: 1, to: 1, text: "A"}]},
        %{path: path2, tag: s2.tag, ops: [%{op: :replace, from: 1, to: 1, text: "Y"}]}
      ])
    end

    # 第一个文件未被写入，保持原内容
    assert File.read!(path) == orig1
    on_exit(fn -> File.rm_rf(path2) end)
  end

  test "快照内容哈希：不同内容不同 tag，相同内容 tag 一致" do
    p1 = Path.join(System.tmp_dir!(), "nb_hash_#{System.unique_integer([:positive])}_1.txt")
    p2 = Path.join(System.tmp_dir!(), "nb_hash_#{System.unique_integer([:positive])}_2.txt")

    on_exit(fn ->
      File.rm(p1)
      File.rm(p2)
    end)

    w!(p1, "same\n")
    w!(p2, "same\n")
    s1 = Edit.show(p1)
    s2 = Edit.show(p2)

    w!(p2, "different\n")
    s3 = Edit.show(p2)

    assert s1.tag == s2.tag
    assert s1.tag != s3.tag
    assert s1.tag =~ ~r/^[0-9a-f]{12}$/
  end

  test "不同项目目录独立快照（项目隔离写入）" do
    proj_a = Path.join(System.tmp_dir!(), "nb_proja_#{System.unique_integer([:positive])}")
    proj_b = Path.join(System.tmp_dir!(), "nb_projb_#{System.unique_integer([:positive])}")
    File.mkdir_p!(proj_a)
    File.mkdir_p!(proj_b)

    on_exit(fn ->
      File.rm_rf!(proj_a)
      File.rm_rf!(proj_b)
    end)

    pa = Path.join(proj_a, "f.txt")
    pb = Path.join(proj_b, "f.txt")
    w!(pa, "aaa\n")
    w!(pb, "bbb\n")

    {:ok, orig} = File.cwd()

    try do
      File.cd!(proj_a)
      sa = Edit.show(pa)
      File.cd!(proj_b)
      sb = Edit.show(pb)
      assert sa.tag != sb.tag
      assert String.length(sa.tag) == 12
    after
      File.cd!(orig)
    end
  end
end
