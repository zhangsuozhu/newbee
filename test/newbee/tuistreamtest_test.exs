defmodule Newbee.TUIStreamTest do
  use ExUnit.Case, async: true
  alias Newbee.TUI

  # 回归：回复文本必须从 "› 输入" 的下一行开始，不能拼在回显行尾
  test "首个 :text 事件开新行，后续增量追加到回复行" do
    state = %TUI{} |> TUI.push_line("› 你好")

    s1 = TUI.render_event(state, :text, {:text, "你"})
    # 开了新行，增量落进新行
    assert List.last(s1.lines) == "你"
    refute List.last(s1.lines) =~ "› 你好"
    assert length(s1.lines) == length(state.lines) + 1

    s2 = TUI.render_event(s1, :text, {:text, "好"})
    s3 = TUI.render_event(s2, :text, {:text, "！"})
    assert List.last(s3.lines) == "你好！"
    assert length(s3.lines) == length(state.lines) + 1
  end

  test "跨 chunk 的 Markdown 列表原位渲染，不重复显示原文" do
    state = %TUI{} |> TUI.push_line("› 清理")
    first = TUI.render_event(state, :text, {:text, "- ✅ 环境已干净"})
    second = TUI.render_event(first, :text, {:text, "\n- ✅ worktree 已删除"})

    assert length(second.lines) == 3
    assert Enum.count(second.lines, &String.contains?(&1, "环境已干净")) == 1
    assert Enum.count(second.lines, &String.contains?(&1, "worktree 已删除")) == 1

    finished = TUI.render_event(second, :turn_end, {:turn_end, :text, 0})
    assert length(finished.lines) == 3
    assert Enum.count(finished.lines, &String.contains?(&1, "环境已干净")) == 1
    assert Enum.count(finished.lines, &String.contains?(&1, "worktree 已删除")) == 1
  end

  test "非 :text 事件后 streaming 重置，下一个回复仍开新行" do
    state = %TUI{} |> TUI.push_line("› a")
    s1 = TUI.render_event(state, :text, {:text, "x"})
    assert List.last(s1.lines) == "x"

    # 工具输出打断流
    s2 = TUI.render_event(s1, :tool_result, {:tool_result, :ref, "out"})
    assert List.last(s2.lines) =~ "out"

    s3 = TUI.render_event(s2, :text, {:text, "y"})
    assert List.last(s3.lines) == "y"
    # 新回复行与上一行分离
    assert length(s3.lines) == length(s2.lines) + 1
  end

  test "push_line 重置 streaming（提交回显后新回复开新行）" do
    state = %TUI{}
    s1 = TUI.render_event(state, :text, {:text, "a"})
    s2 = TUI.push_line(s1, "● done")
    assert s2.streaming == false

    s3 = TUI.render_event(s2, :text, {:text, "b"})
    assert List.last(s3.lines) == "b"
    assert length(s3.lines) == length(s2.lines) + 1
  end

  # 上游流中断自动重试：必须给用户一行可见提示（否则"卡住 2 秒后重来"像模型抽风）
  test "llm_retry 事件渲染为一行可见提示" do
    state = %TUI{} |> TUI.push_line("› hi")

    s = TUI.render_event(state, :llm_retry, {:llm_retry, :stream_read_error})

    assert length(s.lines) == length(state.lines) + 1
    assert List.last(s.lines) =~ "上游连接中断"
    assert List.last(s.lines) =~ "stream_read_error"
    assert List.last(s.lines) =~ "正在自动重试"
  end
end
