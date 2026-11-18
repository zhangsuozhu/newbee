defmodule Newbee.GatePreflightTest do
  @moduledoc """
  环境体检的契约：磁盘不足必须阻断，其余只告警；报告必须说清"怎么办"。

  背景：R1 根分区红 3 条全是 `ExUnit.TimeoutError`（FsWalkTest / TestPartitionCoverageTest），
  单跑 8 个全过、`/tmp` 换成大磁盘后 root 分区 348 passed exit=0 —— 唯一真因是 `/tmp`
  100% 满 + 40 个 async 用例抢文件服务队列。体检就是为了让这种假红在开跑前显形。
  """
  use ExUnit.Case, async: true

  test "TMPDIR 空间不足是 :fail（阻断），不是 :warn" do
    dir = tmp_dir()
    # 把阈值做到不可能满足：任何真实磁盘都"不够"。
    checks = Newbee.GatePreflight.checks(tmpdir: dir, min_free_mb: 1_000_000_000)

    assert Enum.any?(checks, fn %{level: level, message: message} ->
             level == :fail and message =~ "MB"
           end)

    assert Newbee.GatePreflight.failures(tmpdir: dir, min_free_mb: 1_000_000_000) != []
  end

  test "空间充足时不产生 :fail（默认阈值下真实盘应通过）" do
    dir = tmp_dir()
    failures = Newbee.GatePreflight.failures(tmpdir: dir, min_free_mb: 0)

    assert failures == [], inspect(failures)
  end

  test "报告每行都带级别前缀，且 :fail 项说明怎么修" do
    report = Newbee.GatePreflight.report(tmpdir: tmp_dir(), min_free_mb: 1_000_000_000)

    assert Enum.all?(report, &String.starts_with?(&1, "[gate] preflight"))
    assert Enum.any?(report, &String.contains?(&1, "TMPDIR"))

    failed = Enum.find(report, &String.contains?(&1, "preflight fail"))
    assert failed =~ "MB"
    assert String.length(failed) > 40
  end

  test "体检只读：不创建、不删除 tmp 目录里的任何东西" do
    dir = tmp_dir()
    File.write!(Path.join(dir, "sentinel.txt"), "keep")
    before = File.ls!(dir) |> Enum.sort()

    _ = Newbee.GatePreflight.checks(tmpdir: dir, min_free_mb: 0)

    assert File.ls!(dir) |> Enum.sort() == before
    assert File.read!(Path.join(dir, "sentinel.txt")) == "keep"
  end

  defp tmp_dir do
    dir = Path.join(System.tmp_dir!(), "gate-preflight-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    dir
  end
end
