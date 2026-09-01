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
end
