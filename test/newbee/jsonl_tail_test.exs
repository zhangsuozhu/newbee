defmodule Newbee.JsonlTailTest do
  use ExUnit.Case, async: true

  alias Newbee.JsonlTail

  defp write(content) do
    path = Path.join(System.tmp_dir!(), "jsonl-tail-#{System.unique_integer([:positive])}.jsonl")
    File.write!(path, content)
    on_exit(fn -> File.rm(path) end)
    path
  end

  test "小文件：窗口覆盖全文件，仍只返回尾部 n 行" do
    path = write("a\nb\nc\nd\n")
    assert {:ok, ["c", "d"], :whole} = JsonlTail.read_lines(path, 2)
    assert {:ok, ["b", "c", "d"], :whole} = JsonlTail.read_lines(path, 3)
  end

  test "大文件：窗口只读尾部，行边界不整时丢弃残缺首段" do
    lines = for i <- 1..4000, do: "line-#{i}-" <> String.duplicate("x", 120)
    path = write(Enum.join(lines, "\n") <> "\n")

    assert {:ok, got, :partial} = JsonlTail.read_lines(path, 5)
    assert got == Enum.take(lines, -5)

    assert {:ok, got2, :partial} = JsonlTail.read_lines(path, 300)
    assert got2 == Enum.take(lines, -300)
  end

  test "末尾无换行的残行：默认丢弃，keep_partial 保留" do
    path = write("a\nb\npartial-no-newline")
    assert {:ok, ["a", "b"], :whole} = JsonlTail.read_lines(path, 3)
    assert {:ok, ["b", "partial-no-newline"], :whole} = JsonlTail.read_lines(path, 2, keep_partial: true)
  end

  test "空文件与缺失文件" do
    empty = write("")
    assert {:ok, [], :whole} = JsonlTail.read_lines(empty, 5)

    assert {:error, :enoent} =
             JsonlTail.read_lines("/tmp/definitely-missing-#{System.unique_integer([:positive])}.jsonl", 5)

    assert {:error, :invalid_request} = JsonlTail.read_lines(empty, 0)
  end
end
