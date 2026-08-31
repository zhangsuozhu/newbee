defmodule Newbee.TUI.HistoryTest do
  use ExUnit.Case, async: false
  alias Newbee.TUI.History

  setup do
    tmp =
      Path.join(
        System.tmp_dir!(),
        "newbee_hist_test_#{System.system_time(:native)}_#{:erlang.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp)
    path = Path.join(tmp, "history")
    Application.put_env(:newbee, :history_path, path)

    on_exit(fn ->
      Application.delete_env(:newbee, :history_path)
      File.rm_rf!(tmp)
    end)

    %{path: path}
  end

  test "load: 文件不存在返回 []", %{path: path} do
    refute File.exists?(path)
    assert History.load() == []
  end

  test "append 后 load 能读回（跨“进程”持久，即模拟退出重进）", %{path: _path} do
    History.append("帮我重构 foo")
    History.append("解释一下 diff")
    assert History.load() == ["帮我重构 foo", "解释一下 diff"]
  end

  test "append 去重：与最后一条相同则跳过", %{path: _path} do
    History.append("a")
    History.append("a")
    assert History.load() == ["a"]
    History.append("b")
    History.append("a")
    assert History.load() == ["a", "b", "a"]
  end

  test "append 空行不写", %{path: _path} do
    History.append("   ")
    assert History.load() == []
  end

  test "顺序：最早的在前（与 Line.hist 一致，↑ 从最新翻起）", %{path: _path} do
    History.append("one")
    History.append("two")
    History.append("three")
    assert History.load() == ["one", "two", "three"]
  end
end
