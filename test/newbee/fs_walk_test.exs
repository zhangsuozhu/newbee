defmodule Newbee.FsWalkTest do
  use ExUnit.Case, async: true

  setup do
    dir = Path.join(System.tmp_dir!(), "fswalk-" <> Integer.to_string(System.unique_integer([:positive])))
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    {:ok, dir: dir}
  end

  test "lists files with ext filter and prunes skip dirs", %{dir: dir} do
    File.mkdir_p!(Path.join(dir, "lib/sub"))
    File.mkdir_p!(Path.join(dir, "_build/lib"))
    File.write!(Path.join(dir, "lib/keep.ex"), "x")
    File.write!(Path.join(dir, "lib/sub/deep.exs"), "x")
    File.write!(Path.join(dir, "lib/notes.txt"), "x")
    File.write!(Path.join(dir, "_build/skip.ex"), "x")

    got = Newbee.FsWalk.files(dir, exts: [".ex", ".exs"], prune_dir: &(&1 in ~w(_build deps .git)))
    assert Enum.any?(got, &String.ends_with?(&1, "lib/keep.ex"))
    assert Enum.any?(got, &String.ends_with?(&1, "lib/sub/deep.exs"))
    refute Enum.any?(got, &String.ends_with?(&1, "skip.ex"))
    refute Enum.any?(got, &String.ends_with?(&1, "notes.txt"))
  end

  test "does not follow dir symlinks into cycles", %{dir: dir} do
    File.mkdir_p!(Path.join(dir, "a"))
    File.write!(Path.join(dir, "a/f.txt"), "x")
    File.ln_s!(dir, Path.join(dir, "a/loop"))
    got = Newbee.FsWalk.files(dir)
    assert Enum.any?(got, &String.ends_with?(&1, "a/f.txt"))
  end

  test "respects max_depth and max_entries", %{dir: dir} do
    Enum.reduce(1..10, dir, fn i, acc ->
      nxt = Path.join(acc, "d" <> Integer.to_string(i))
      File.mkdir_p!(nxt)
      File.write!(Path.join(nxt, "f.txt"), "x")
      nxt
    end)

    assert length(Newbee.FsWalk.files(dir, max_depth: 3)) == 3
    assert length(Newbee.FsWalk.files(dir, max_entries: 4)) == 4
  end

  test "never enters pseudo filesystems" do
    assert Newbee.FsWalk.files("/proc") == []
    assert Newbee.FsWalk.files("/sys") == []
  end

  test "missing dir returns empty list" do
    assert Newbee.FsWalk.files("/no/such/dir-newbee-test") == []
  end

  test "include_dirs lists directories", %{dir: dir} do
    File.mkdir_p!(Path.join(dir, "sub"))
    File.write!(Path.join(dir, "sub/f.txt"), "x")
    got = Newbee.FsWalk.files(dir, include_dirs: true)
    assert Enum.any?(got, &String.ends_with?(&1, "sub"))
    assert Enum.any?(got, &String.ends_with?(&1, "sub/f.txt"))
  end
end
