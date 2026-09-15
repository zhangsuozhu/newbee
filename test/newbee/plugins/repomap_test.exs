defmodule Newbee.Plugins.RepoMapTest do
  use ExUnit.Case, async: false

  test "提取模块签名与 moduledoc" do
    map = Newbee.Plugins.RepoMap.build(".")
    assert map =~ "Newbee.DEE.Evaluator"
    assert map =~ "def eval"
    assert map =~ "@ lib/newbee/dee/evaluator.ex"
  end

  test "非 Elixir 目录退化为文件树" do
    dir =
      Path.join(
        System.tmp_dir!(),
        "newbee_repomap_non_elixir_" <> Integer.to_string(System.unique_integer([:positive]))
      )

    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "README.txt"), "plain project")
    on_exit(fn -> File.rm_rf(dir) end)

    map = Newbee.Plugins.RepoMap.build(dir)
    assert map =~ "README.txt"
  end

  test "引用段含动态节点 (__MODULE__.Sub) 时构建不崩溃" do
    # 回归: 2026-02 chat_test.exs 的 __MODULE__.Runner 让 build(".") 抛
    # Protocol.UndefinedError (String.Chars for Tuple)。resolve_ref 必须跳过
    # 无法静态解析的动态段。
    dir =
      Path.join(
        System.tmp_dir!(),
        "newbee_repomap_dyn_" <> Integer.to_string(System.unique_integer([:positive]))
      )

    File.mkdir_p!(Path.join(dir, "lib"))
    File.write!(Path.join(dir, "mix.exs"), "defmodule Dyn.MixProject do\nend")

    File.write!(Path.join(dir, "lib/dyn.ex"), """
    defmodule Dyn do
      def runner, do: __MODULE__.Runner
      defmodule Runner do
        def go, do: :ok
      end
    end
    """)

    on_exit(fn -> File.rm_rf(dir) end)

    map = Newbee.Plugins.RepoMap.build(dir)
    assert map =~ "Dyn"
  end
end
