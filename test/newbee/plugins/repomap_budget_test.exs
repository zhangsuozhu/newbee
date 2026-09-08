# Regression: RepoMap budget guard + _build* exclusion.
defmodule Newbee.Plugins.RepoMapBudgetTest do
  use ExUnit.Case, async: false

  test "slim build succeeds on project" do
    map = Newbee.Plugins.RepoMap.build(".", format: :slim)
    assert is_binary(map)
    assert map =~ "Newbee.DEE.Evaluator"
  end

  test "ignores _build variants" do
    dir = Path.join(System.tmp_dir!(), "repomap-budget-" <> Integer.to_string(System.unique_integer([:positive])))
    File.mkdir_p!(Path.join(dir, "lib"))
    File.mkdir_p!(Path.join(dir, "_build-codex-calls/lib"))
    File.write!(Path.join(dir, "mix.exs"), "defmodule Foo.MixProject do\n use Mix.Project\nend\n")
    File.write!(Path.join(dir, "lib/a.ex"), "defmodule Foo.Kept do\nend\n")
    File.write!(Path.join(dir, "_build-codex-calls/lib/ignored.ex"), "defmodule Foo.BuildIgnoredXYZ do\nend\n")
    on_exit(fn -> File.rm_rf(dir) end)
    map = Newbee.Plugins.RepoMap.build(dir, format: :slim)
    assert map =~ "Foo.Kept"
    refute map =~ "BuildIgnoredXYZ"
  end
  test "non-elixir dir degrades to bounded tree" do
    dir = Path.join(System.tmp_dir!(), "repomap-tree-" <> Integer.to_string(System.unique_integer([:positive])))
    File.mkdir_p!(Path.join(dir, "docs"))
    File.mkdir_p!(Path.join(dir, "_build"))
    File.write!(Path.join(dir, "docs/guide.txt"), "hello")
    File.write!(Path.join(dir, "_build/drop.txt"), "x")
    on_exit(fn -> File.rm_rf(dir) end)
    map = Newbee.Plugins.RepoMap.build(dir)
    assert map =~ "guide.txt"
    refute map =~ "drop.txt"
  end
end
