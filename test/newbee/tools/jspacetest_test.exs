defmodule Newbee.Tools.JSpaceTest do
  use ExUnit.Case, async: true
  alias Newbee.Tools.JSpace

  setup do
    dir =
      Path.join(
        System.tmp_dir!(),
        "newbee_jspace_#{System.system_time(:native)}_#{:erlang.unique_integer([:positive])}"
      )

    System.put_env("NEWBEE_JSPACE_DIR", dir)
    sid = "test-#{System.system_time(:native)}_#{:erlang.unique_integer([:positive])}"

    on_exit(fn ->
      System.delete_env("NEWBEE_JSPACE_DIR")
      File.rm_rf(dir)
    end)

    {:ok, sid: sid}
  end

  test "note 开账写入 goal/core/next", %{sid: sid} do
    text = JSpace.note([goal: "实现 mapreduce 并写测试", next: "看 RepoMap"], sid)
    assert text =~ "Goal:      实现 mapreduce 并写测试"
    assert text =~ "Next:      看 RepoMap"
    assert JSpace.exists?(sid)
  end

  test "verified 编号追加且清占位", %{sid: sid} do
    JSpace.note([verified: "编译通过"], sid)
    JSpace.note([verified: "测试全绿"], sid)
    text = JSpace.read(sid)
    assert text =~ "Verified:\n"
    refute text =~ "Verified:  (none)"
    assert text =~ "✓01 编译通过"
    assert text =~ "✓02 测试全绿"
  end

  test "verified 条目留在 Verified 段内，不散落到文件末尾", %{sid: sid} do
    JSpace.note([goal: "g", next: "n"], sid)
    JSpace.note([verified: "第一条"], sid)
    JSpace.note([checkpoint: "CP 之后"], sid)
    JSpace.note([verified: "第二条"], sid)

    lines = JSpace.read(sid) |> String.split("\n")
    verified_at = Enum.find_index(lines, &String.starts_with?(&1, "Verified:"))
    open_at = Enum.find_index(lines, &String.starts_with?(&1, "Open:"))
    first_at = Enum.find_index(lines, &String.starts_with?(&1, "✓01"))
    second_at = Enum.find_index(lines, &String.starts_with?(&1, "✓02"))

    assert verified_at, "missing Verified header"
    assert open_at, "missing Open header"

    # Both entries sit between the header and the next section, not after [CP ...].
    assert first_at == verified_at + 1
    assert second_at == first_at + 1
    assert second_at < open_at
  end

  test "占位符在首条 verified 时被清掉", %{sid: sid} do
    JSpace.note([goal: "g"], sid)
    assert JSpace.read(sid) =~ "Verified:  (none)"

    JSpace.note([verified: "第一条"], sid)
    text = JSpace.read(sid)
    refute text =~ "Verified:  (none)"
    assert text =~ "Verified:\n✓01 第一条"
  end

  test "open 条目留在 Open 段内，占位符被清掉", %{sid: sid} do
    JSpace.note([goal: "g"], sid)
    assert JSpace.read(sid) =~ "Open:      (none)"

    JSpace.note([open: "问题一"], sid)
    JSpace.note([open: "问题二"], sid)

    text = JSpace.read(sid)
    refute text =~ "Open:      (none)"

    lines = String.split(text, "\n")
    open_at = Enum.find_index(lines, &String.starts_with?(&1, "Open:"))
    next_at = Enum.find_index(lines, &String.starts_with?(&1, "Next:"))
    first_at = Enum.find_index(lines, &String.starts_with?(&1, "? 问题一"))
    second_at = Enum.find_index(lines, &String.starts_with?(&1, "? 问题二"))

    assert open_at, "missing Open header"
    assert next_at, "missing Next header"
    assert Enum.at(lines, open_at) == "Open:"
    assert first_at == open_at + 1
    assert second_at == first_at + 1
    assert second_at < next_at
  end

  test "checkpoint 编号追加", %{sid: sid} do
    JSpace.note([checkpoint: "core 定稿"], sid)
    assert JSpace.read(sid) =~ "[CP 01] core 定稿"
  end

  test "open 追加悬项", %{sid: sid} do
    JSpace.note([open: "并发语义待定"], sid)
    assert JSpace.read(sid) =~ "? 并发语义待定"
  end

  test "seam 无 ledger 时提示开账", %{sid: sid} do
    assert JSpace.seam(sid) =~ "no ledger"
  end

  test "seam 返回 ledger", %{sid: sid} do
    JSpace.note([goal: "g", next: "n"], sid)
    assert JSpace.seam(sid) =~ "Goal:"
  end

  test "ship 登记交付检查", %{sid: sid} do
    text = JSpace.ship("lib/foo.ex", ["编译", "测试"], sid)
    assert text =~ "Delivery checks recorded: lib/foo.ex"
    assert JSpace.read(sid) =~ "- [ ] SHIP lib/foo.ex"
    assert JSpace.read(sid) =~ "- [ ] 编译"
  end

  test "resume 含前提 + invariants + ledger", %{sid: sid} do
    JSpace.note([goal: "g"], sid)
    text = JSpace.resume(sid)
    assert text =~ "J-Space recovery protocol"
    assert text =~ "Invariants"
    assert text =~ "Goal:"
  end

  test "clear 删除 ledger", %{sid: sid} do
    JSpace.note([goal: "g"], sid)
    assert JSpace.exists?(sid)
    JSpace.clear(sid)
    refute JSpace.exists?(sid)
  end
end
