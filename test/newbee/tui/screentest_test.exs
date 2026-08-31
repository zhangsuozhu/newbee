defmodule Newbee.TUI.ScreenTest do
  use ExUnit.Case, async: true
  alias Newbee.TUI.Screen

  test "短行不折" do
    assert ["abc"] = Screen.wrap(["abc"], 20)
  end

  test "超宽 ASCII 行真实折行" do
    rows = Screen.wrap([String.duplicate("a", 30)], 11)
    assert length(rows) >= 3
    # 拼回去内容无损
    assert rows |> Enum.join() |> String.contains?("aaaaaaaaaaa")
  end

  test "中文按可见宽度折（双宽不折进半格）" do
    # 10 列宽：每行最多 4 个中文（8 列）+ 1 空隙
    rows = Screen.wrap(["中文中文中文中文中文"], 10)
    assert length(rows) == 3
    assert Enum.all?(rows, fn r -> Newbee.TUI.Line.width(plain(r)) <= 10 end)
  end

  test "ANSI 颜色段不占宽度" do
    colored = "\e[31m红\e[0m" <> String.duplicate("x", 8)
    assert [_one] = Screen.wrap([colored], 12)
  end

  test "状态栏 ANSI 不占宽，右栏 tok/bind/policy 不被截断" do
    # 回归：状态栏按可见宽度截断时曾把 \e[2m 里的 [ 2 m 各计 1 列，
    # 导致右栏 tok/bind/policy 被多算的 20+ 列顶出屏幕。
    tmp =
      Path.join(
        System.tmp_dir!(),
        "newbee_screen_status_#{System.system_time(:native)}_#{:erlang.unique_integer([:positive])}.bin"
      )

    port =
      Port.open({:spawn_executable, "/bin/bash"}, [:binary, :exit_status, args: ["-c", "cat > #{tmp}"]])

    left = "\e[2mdeepseek-v4-flash · newbee\e[0m"
    right = "\e[2m\e[33m ⏱ 1.5s\e[0m\e[2m tok:12.3M bind:0 hint\e[0m"
    status_text = left <> String.duplicate(" ", 20) <> right
    status = {status_text, {10, 1}}

    Screen.paint_full(port, ["body"], "› ", status, 80, 10)
    out = await_file(tmp, "hint")

    assert out =~ "tok:12.3M bind:0 hint"
    File.rm!(tmp)
  end

  test "折行保留 ANSI 样式" do
    rows = Screen.wrap(["\e[32m" <> String.duplicate("a", 20) <> "\e[0m"], 8)
    assert Enum.all?(rows, &String.starts_with?(&1, "\e["))
  end

  test "多行输入逐行折" do
    rows = Screen.wrap(["aaaa", "bbbb"], 10)
    assert rows == ["aaaa", "bbbb"]
  end

  test "wrap_tail 保持显示顺序（旧上新下），只折尾部" do
    lines = Enum.map(1..10, &"line#{&1}")
    {rows, complete?} = Screen.wrap_tail(lines, 80, 3)
    assert rows == ["line8", "line9", "line10"]
    refute complete?
  end

  test "wrap_tail 行数不足时 complete?=true（已到顶）" do
    assert {["a", "b"], true} = Screen.wrap_tail(["a", "b"], 80, 5)
  end

  test "wrap_tail 尾部宽行先折行，凑够即停" do
    wide = String.duplicate("x", 30)
    {rows, complete?} = Screen.wrap_tail(["top", wide], 11, 2)
    assert length(rows) == 3
    assert Enum.all?(rows, &String.contains?(&1, "x"))
    refute complete?
  end

  test "paint_full 锚定末尾：超屏后首行不可见、末行必上屏" do
    # 回归：旧实现取【前】N 行，transcript 超一屏后新输出永远不上屏
    tmp =
      Path.join(
        System.tmp_dir!(),
        "newbee_screen_#{System.system_time(:native)}_#{:erlang.unique_integer([:positive])}.bin"
      )

    port =
      Port.open({:spawn_executable, "/bin/bash"}, [:binary, :exit_status, args: ["-c", "cat > #{tmp}"]])

    lines = Enum.map(1..50, &"line#{&1}")
    status = {"status", {10, 1}}

    Screen.paint_full(port, lines, "› ", status, 80, 10)
    out = await_file(tmp, "line50")

    assert out =~ "line44"
    refute out =~ "line43"
    File.rm(tmp)
  end

  test "paint_delta 只重写变化行且内容正确" do
    tmp =
      Path.join(
        System.tmp_dir!(),
        "newbee_screen_#{System.system_time(:native)}_#{:erlang.unique_integer([:positive])}.bin"
      )

    port =
      Port.open({:spawn_executable, "/bin/bash"}, [:binary, :exit_status, args: ["-c", "cat > #{tmp}"]])

    status = {"status", {10, 1}}

    screen = Screen.paint_full(port, ["a", "b"], "› ", status, 80, 10)
    Screen.paint_delta(screen, ["a", "b", "c"], "› ", status, 80, 10)
    out = await_file(tmp, "\e[3;1Hc\e[K")

    # 增绘帧包含新行 c 的行写入
    assert out =~ "\e[3;1Hc\e[K"
    File.rm!(tmp)
  end

  # 端口落盘是异步的：轮询直到文件出现预期内容
  defp await_file(path, marker, deadline \\ 5_000) do
    case File.read(path) do
      {:ok, content} ->
        if String.contains?(content, marker) do
          content
        else
          if deadline <= 0, do: flunk("file never got #{inspect(marker)}: #{inspect(content)}")
          Process.sleep(50)
          await_file(path, marker, deadline - 50)
        end

      _ ->
        Process.sleep(50)
        await_file(path, marker, deadline - 50)
    end
  end

  defp plain(s), do: String.replace(s, ~r/\e\[[0-9;]*[A-Za-z~]/, "")
end
