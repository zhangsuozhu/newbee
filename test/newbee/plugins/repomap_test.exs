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

  # 回归：`__MODULE__.X`（本仓库 test/collaboration/chat_test.exs 就有）与
  # `&__MODULE__.f/1` 会在引用段里带 AST 元组，旧实现直接 Enum.join 抛
  # String.Chars not implemented for Tuple，整个 RepoMap.build/1 崩掉。
  test "__MODULE__.X 形态的引用不崩溃" do
    dir =
      Path.join(
        System.tmp_dir!(),
        "newbee_repomap_module_ref_" <> Integer.to_string(System.unique_integer([:positive]))
      )

    File.mkdir_p!(Path.join(dir, "lib/demo"))
    File.mkdir_p!(Path.join(dir, "lib/demo"))
    # 只有存在 mix.exs 才按 Elixir 工程扫源码目录，否则退化成文件树
    File.write!(Path.join(dir, "mix.exs"), "defmodule Demo.MixProject do\nend\n")

    File.write!(Path.join(dir, "lib/demo/app.ex"), """
    defmodule Demo.App do
      def start(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__.Runner)
      def reload, do: &__MODULE__.load/1

      defmodule Runner do
        def run, do: :ok
      end
    end
    """)

    on_exit(fn -> File.rm_rf(dir) end)

    map = Newbee.Plugins.RepoMap.build(dir)
    assert map =~ "Demo.App"
    assert map =~ "Runner"
  end
end
