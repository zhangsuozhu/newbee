defmodule Newbee.TestPartitionCoverageTest do
  @moduledoc """
  门禁覆盖元测试：分区表必须覆盖 test/ 下每一个测试文件（acceptance 除外）。

  这条用例是 G7（覆盖完整性）的守护：R1 基线时 `test.fast` 只跑 218/250 个文件，
  整个 colony 子系统（281 个用例）从来不在门禁里，却没人发现。

  `timeout` 是必要的：root 分区与 40 个 async 用例共用一个 VM，文件服务在磁盘压力下
  可能排队数十秒（R1 D7 同一根因），这里只做"枚举 + 比较"，给足预算就不会误报。
  """
  use ExUnit.Case, async: true

  @moduletag timeout: 300_000

  # __DIR__ = <root>/test/newbee → 仓库根在上两级
  @root Path.expand("../..", __DIR__)
  @acceptance "test/newbee/acceptance_test.exs"

  setup_all do
    # 一次枚举供全部用例复用：目录遍历在这台机器上是稀缺资源。
    all =
      Path.wildcard(Path.join(@root, "test/**/*_test.exs"))
      |> Enum.filter(&File.regular?/1)
      |> Enum.map(&Path.relative_to(&1, @root))
      |> Enum.sort()

    partitions = Mix.Tasks.Newbee.TestFast.partitions(@root)
    {:ok, all: all, partitions: partitions}
  end

  test "分区表覆盖 test/ 下每个测试文件（acceptance 单独跑）", %{all: all, partitions: partitions} do
    covered = partitions |> Enum.flat_map(& &1.files) |> Enum.uniq() |> Enum.sort()
    missing = (all -- covered) -- [@acceptance]
    extra = covered -- all

    assert all != [], "test/ 下一个测试文件都没枚举到（@root 路径写错了）"
    assert missing == [], "门禁漏跑这些文件: " <> Enum.join(missing, ", ")
    assert extra == [], "分区列出不存在的文件: " <> Enum.join(extra, ", ")
    assert @acceptance not in covered, "acceptance 必须留在 test.fast 之外"
  end

  test "没有文件落在两个分区（不会重复跑）", %{partitions: partitions} do
    files = Enum.flat_map(partitions, & &1.files)
    duplicates = files -- Enum.uniq(files)
    assert duplicates == [], "重复文件: " <> inspect(Enum.uniq(duplicates))
  end

  test "分区名唯一且非空", %{partitions: partitions} do
    names = Enum.map(partitions, & &1.name)
    assert length(names) == length(Enum.uniq(names))
    assert Enum.all?(partitions, &(&1.files != [])), "存在空分区"
  end
end
