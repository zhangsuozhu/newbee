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
end
