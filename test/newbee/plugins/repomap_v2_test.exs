defmodule Newbee.Plugins.RepoMapV2Test do
  use ExUnit.Case, async: false

  @moduledoc "RepoMap v2：引用图排序 + 双层展示的行为测试。"

  defp write(path, content) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, content)
    path
  end

  setup do
    dir =
      Path.join(
        System.tmp_dir!(),
        "repomap_v2_test_#{System.system_time(:native)}_#{:erlang.unique_integer([:positive])}"
      )

    File.mkdir_p!(Path.join(dir, "lib"))

    # build 需要 mix.exs 才进入 Elixir 建图分支
    File.write!(
      Path.join(dir, "mix.exs"),
      "defmodule T.MixProject do\n  use Mix.Project\n  def project, do: [app: :t]\nend\n"
    )

    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, dir: dir}
  end

  test "核心模块(被引用最多)排最前且带全签名", %{dir: dir} do
    write(Path.join(dir, "lib/core.ex"), """
    defmodule Core do
      @moduledoc "核心"
      def run(a), do: a
      def stop, do: :ok
    end
    """)

    write(Path.join(dir, "lib/app.ex"), """
    defmodule App do
      alias Core
      def go, do: Core.run(1)
    end
    """)

    map = Newbee.Plugins.RepoMap.build(dir)
    core_pos = :binary.match(map, "Core") |> elem(0)
    app_pos = :binary.match(map, "App") |> elem(0)
    assert core_pos < app_pos, "Core 被引用多应排在前面"
    assert map =~ "def run/1"
    assert map =~ "def stop/0"
    refute String.contains?(map, "其他模块:")
  end

  test "全模块覆盖：无文件名截断", %{dir: dir} do
    for i <- 1..30 do
      mod = "M#{i}"
      write(Path.join(dir, "lib/m#{i}.ex"), "defmodule #{mod} do\n  def f, do: #{i}\nend\n")
    end

    map = Newbee.Plugins.RepoMap.build(dir)

    for i <- 1..30 do
      assert map =~ "M#{i}"
    end
  end

  test "预算触发双层：Tier2 单行索引", %{dir: dir} do
    # 一个大模块吃掉 Tier1 预算，其余进 Tier2
    big_defs = Enum.map_join(1..60, "\n", &"  def big_fn#{&1}(a), do: a")

    write(Path.join(dir, "lib/big.ex"), """
    defmodule Big do
      #{big_defs}
    end
    """)

    for i <- 1..40 do
      write(
        Path.join(dir, "lib/small#{i}.ex"),
        "defmodule Small#{i} do\n  def f#{i}, do: #{i}\nend\n"
      )
    end

    map = Newbee.Plugins.RepoMap.build(dir, tier1_max_bytes: 500)
    assert map =~ "其他模块:"
    assert map =~ "sig"
    # Tier2 行不含签名细节
    refute map =~ "def f3/"
  end

  test "alias 指令展开后引用可解析", %{dir: dir} do
    write(Path.join(dir, "lib/svc.ex"), "defmodule A.B.Service do\n  def ping, do: :pong\nend\n")

    write(Path.join(dir, "lib/user.ex"), """
    defmodule User do
      alias A.B.Service
      def call, do: Service.ping()
    end
    """)

    map = Newbee.Plugins.RepoMap.build(dir)
    svc_pos = :binary.match(map, "A.B.Service") |> elem(0)
    user_pos = :binary.match(map, "User") |> elem(0)
    assert svc_pos < user_pos
  end

  test "嵌套 defmodule 全部收集", %{dir: dir} do
    write(Path.join(dir, "lib/nested.ex"), """
    defmodule Outer do
      def o, do: 1

      defmodule Inner do
        def i, do: 2
      end
    end
    """)

    map = Newbee.Plugins.RepoMap.build(dir)
    assert map =~ "Outer"
    assert map =~ "Inner"
  end

  test "输出确定性：同输入两次构建逐字节相同", %{dir: dir} do
    write(Path.join(dir, "lib/a.ex"), "defmodule AA do\n  def x, do: 1\nend\n")
    m1 = Newbee.Plugins.RepoMap.build(dir)
    m2 = Newbee.Plugins.RepoMap.build(dir)
    assert m1 == m2
  end

  test "厂商与产物目录不参与建图", %{dir: dir} do
    write(Path.join(dir, "lib/real.ex"), "defmodule Real do\n  def r, do: 1\nend\n")
    write(Path.join(dir, "deps/junk/lib/junk.ex"), "defmodule JunkDep do\n  def j, do: 1\nend\n")
    write(Path.join(dir, "_build/dev/lib/x/y.ex"), "defmodule JunkBuild do\ndef b, do: 1\nend\n")

    map = Newbee.Plugins.RepoMap.build(dir)
    refute map =~ "JunkDep"
    refute map =~ "JunkBuild"
    assert map =~ "Real"
  end

  test "非 Elixir 目录退化为文件树", %{dir: dir} do
    File.rm!(Path.join(dir, "mix.exs"))
    write(Path.join(dir, "README.md"), "# hi")
    map = Newbee.Plugins.RepoMap.build(dir)
    assert is_binary(map)
    assert map =~ "README.md"
  end

  test "语法坏文件跳过不崩溃", %{dir: dir} do
    write(Path.join(dir, "lib/bad.ex"), "defmodule Bad do def (end")
    write(Path.join(dir, "lib/good.ex"), "defmodule Good do\n  def g, do: 1\nend\n")
    map = Newbee.Plugins.RepoMap.build(dir)
    assert map =~ "Good"
  end
end

defmodule Newbee.Plugins.RepoMapV2Test do
  use ExUnit.Case, async: false

  @moduledoc "RepoMap v2：引用图排序 + 双层展示的行为测试。"

  defp write(path, content) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, content)
    path
  end

  setup do
    dir =
      Path.join(
        System.tmp_dir!(),
        "repomap_v2_test_#{System.system_time(:native)}_#{:erlang.unique_integer([:positive])}"
      )

    File.mkdir_p!(Path.join(dir, "lib"))

    # build 需要 mix.exs 才进入 Elixir 建图分支
    File.write!(
      Path.join(dir, "mix.exs"),
      "defmodule T.MixProject do\n  use Mix.Project\n  def project, do: [app: :t]\nend\n"
    )

    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, dir: dir}
  end

  test "核心模块(被引用最多)排最前且带全签名", %{dir: dir} do
    write(Path.join(dir, "lib/core.ex"), """
    defmodule Core do
      @moduledoc "核心"
      def run(a), do: a
      def stop, do: :ok
    end
    """)

    write(Path.join(dir, "lib/app.ex"), """
    defmodule App do
      alias Core
      def go, do: Core.run(1)
    end
    """)

    map = Newbee.Plugins.RepoMap.build(dir)
    core_pos = :binary.match(map, "Core") |> elem(0)
    app_pos = :binary.match(map, "App") |> elem(0)
    assert core_pos < app_pos, "Core 被引用多应排在前面"
    assert map =~ "def run/1"
    assert map =~ "def stop/0"
    refute String.contains?(map, "其他模块:")
  end

  test "全模块覆盖：无文件名截断", %{dir: dir} do
    for i <- 1..30 do
      mod = "M#{i}"
      write(Path.join(dir, "lib/m#{i}.ex"), "defmodule #{mod} do\n  def f, do: #{i}\nend\n")
    end

    map = Newbee.Plugins.RepoMap.build(dir)

    for i <- 1..30 do
      assert map =~ "M#{i}"
    end
  end

  test "预算触发双层：Tier2 单行索引", %{dir: dir} do
    # 一个大模块吃掉 Tier1 预算，其余进 Tier2
    big_defs = Enum.map_join(1..60, "\n", &"  def big_fn#{&1}(a), do: a")

    write(Path.join(dir, "lib/big.ex"), """
    defmodule Big do
      #{big_defs}
    end
    """)

    for i <- 1..40 do
      write(
        Path.join(dir, "lib/small#{i}.ex"),
        "defmodule Small#{i} do\n  def f#{i}, do: #{i}\nend\n"
      )
    end

    map = Newbee.Plugins.RepoMap.build(dir, tier1_max_bytes: 500)
    assert map =~ "其他模块:"
    assert map =~ "sig"
    # Tier2 行不含签名细节
    refute map =~ "def f3/"
  end

  test "alias 指令展开后引用可解析", %{dir: dir} do
    write(Path.join(dir, "lib/svc.ex"), "defmodule A.B.Service do\n  def ping, do: :pong\nend\n")

    write(Path.join(dir, "lib/user.ex"), """
    defmodule User do
      alias A.B.Service
      def call, do: Service.ping()
    end
    """)

    map = Newbee.Plugins.RepoMap.build(dir)
    svc_pos = :binary.match(map, "A.B.Service") |> elem(0)
    user_pos = :binary.match(map, "User") |> elem(0)
    assert svc_pos < user_pos
  end

  test "嵌套 defmodule 全部收集", %{dir: dir} do
    write(Path.join(dir, "lib/nested.ex"), """
    defmodule Outer do
      def o, do: 1

      defmodule Inner do
        def i, do: 2
      end
    end
    """)

    map = Newbee.Plugins.RepoMap.build(dir)
    assert map =~ "Outer"
    assert map =~ "Inner"
  end

  test "输出确定性：同输入两次构建逐字节相同", %{dir: dir} do
    write(Path.join(dir, "lib/a.ex"), "defmodule AA do\n  def x, do: 1\nend\n")
    m1 = Newbee.Plugins.RepoMap.build(dir)
    m2 = Newbee.Plugins.RepoMap.build(dir)
    assert m1 == m2
  end

  test "厂商与产物目录不参与建图", %{dir: dir} do
    write(Path.join(dir, "lib/real.ex"), "defmodule Real do\n  def r, do: 1\nend\n")
    write(Path.join(dir, "deps/junk/lib/junk.ex"), "defmodule JunkDep do\n  def j, do: 1\nend\n")
    write(Path.join(dir, "_build/dev/lib/x/y.ex"), "defmodule JunkBuild do\ndef b, do: 1\nend\n")

    map = Newbee.Plugins.RepoMap.build(dir)
    refute map =~ "JunkDep"
    refute map =~ "JunkBuild"
    assert map =~ "Real"
  end

  test "非 Elixir 目录退化为文件树", %{dir: dir} do
    File.rm!(Path.join(dir, "mix.exs"))
    write(Path.join(dir, "README.md"), "# hi")
    map = Newbee.Plugins.RepoMap.build(dir)
    assert is_binary(map)
    assert map =~ "README.md"
  end

  test "语法坏文件跳过不崩溃", %{dir: dir} do
    write(Path.join(dir, "lib/bad.ex"), "defmodule Bad do def (end")
    write(Path.join(dir, "lib/good.ex"), "defmodule Good do\n  def g, do: 1\nend\n")
    map = Newbee.Plugins.RepoMap.build(dir)
    assert map =~ "Good"
  end
end
