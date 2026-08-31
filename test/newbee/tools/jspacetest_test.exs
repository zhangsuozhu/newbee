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
    refute text =~ "Verified:  (无)"
    assert text =~ "✓01 编译通过"
    assert text =~ "✓02 测试全绿"
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
    assert JSpace.seam(sid) =~ "无 ledger"
  end

  test "seam 返回 ledger", %{sid: sid} do
    JSpace.note([goal: "g", next: "n"], sid)
    assert JSpace.seam(sid) =~ "Goal:"
  end

  test "ship 登记交付检查", %{sid: sid} do
    text = JSpace.ship("lib/foo.ex", ["编译", "测试"], sid)
    assert text =~ "已登记交付检查: lib/foo.ex"
    assert JSpace.read(sid) =~ "- [ ] SHIP lib/foo.ex"
    assert JSpace.read(sid) =~ "- [ ] 编译"
  end

  test "resume 含前提 + invariants + ledger", %{sid: sid} do
    JSpace.note([goal: "g"], sid)
    text = JSpace.resume(sid)
    assert text =~ "J-Space 恢复协议"
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
