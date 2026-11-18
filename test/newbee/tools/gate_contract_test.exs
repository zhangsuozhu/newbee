defmodule Newbee.Tools.GateContractTest do
  @moduledoc "门禁契约：步骤集必须完整、命令必须解析到真实入口、README 必须指向唯一入口。"
  use ExUnit.Case, async: true

  # __DIR__ = <root>/test/newbee/tools → 仓库根在上三级
  @root Path.expand("../../..", __DIR__)
  @expected ~w(compile-dev compile-test format test-fast acceptance web-js)

  test "门禁步骤集完整：删掉任何一步都必须让本用例变红" do
    names = Enum.map(Mix.Tasks.Newbee.Gate.steps(), & &1.name)

    assert names == @expected,
           "门禁步骤应为 #{inspect(@expected)}，实际 #{inspect(names)}（少一步=漏一类红线）"
  end

  test "每个步骤的命令都解析到真实入口（mix 任务 / alias / node / 测试文件）" do
    for step <- Mix.Tasks.Newbee.Gate.steps() do
      assert Mix.Tasks.Newbee.Gate.entry_problem(step, @root) == :ok,
             inspect(Mix.Tasks.Newbee.Gate.entry_problem(step, @root))
    end
  end

  test "web-js 步骤覆盖 test/web 下每个 *.test.js（新增套件自动纳入）" do
    step = Enum.find(Mix.Tasks.Newbee.Gate.steps(), &(&1.name == "web-js"))
    resolved = Mix.Tasks.Newbee.Gate.resolve_command(step, @root)

    all =
      Path.wildcard(Path.join(@root, "test/web/*.test.js"))
      |> Enum.map(&Path.relative_to(&1, @root))
      |> Enum.sort()

    assert all != [], "test/web 下应至少有前端套件"
    assert Enum.sort(resolved -- ["node", "--test"]) == all
    for file <- all, do: assert(File.regular?(Path.join(@root, file)))
  end

  test "test-fast 步骤跑的是分区入口，且覆盖元测试本身也在门禁内" do
    partitions = Mix.Tasks.Newbee.TestFast.partitions(@root)
    covered = partitions |> Enum.flat_map(& &1.files) |> Enum.uniq()
    assert "test/newbee/test_partition_coverage_test.exs" in covered
    assert "test/newbee/tools/gate_contract_test.exs" in covered
  end

  test "README 把 newbee.gate 写成门禁入口，且不再宣称 test.all 是完整入口" do
    readme = File.read!(Path.join(@root, "README.md"))
    assert readme =~ "mix newbee.gate"
    refute readme =~ "快速分区回归 + acceptance 的完整入口"
  end
end
