defmodule Newbee.SessionTest do
  use ExUnit.Case, async: false
  alias Newbee.Session

  # OTP 的 erlang:unique_integer([:positive]) 跨 VM 重启序列几乎相同（实测仅
  # ±3 抖动），同一 "test_<int>" id 的 transcript 会在多次运行间累积——
  # 重复跑本文件时历史消息翻倍导致断言失败（环境污染，非契约问题）。
  # 每个测试前后清理自己的制品；只清纯数字后缀，不动其它组的
  # test_resume_*/test_repair_* 会话。

  setup do
    cleanup_test_sessions()
    on_exit(&cleanup_test_sessions/0)
    :ok
  end

  defp cleanup_test_sessions do
    root = Path.join(System.user_home!(), ".newbee/sessions")

    for f <- Path.wildcard(Path.join(root, "test_*.jsonl")),
        Regex.match?(~r{/test_\d+\.jsonl$}, f) do
      Newbee.Session.delete(Path.basename(f, ".jsonl"))
    end
  end

  test "mark_created 让空会话立即出现在列表" do
    id = "test_#{:erlang.unique_integer([:positive])}"
    assert :ok = Session.mark_created(id)

    meta = Enum.find(Session.list_with_meta(10), &(&1.id == id))
    assert meta
    assert meta.messages == 0
    assert meta.title == ""
  end

  test "transcript 追加与读取" do
    s = Session.open("test_#{:erlang.unique_integer([:positive])}")
    Session.append(s, %{"role" => "user", "content" => "hi"})
    Session.append(s, %{"role" => "assistant", "content" => "yo"})

    msgs = Session.messages(s)
    assert length(msgs) == 2
    assert Enum.at(msgs, 0)["content"] == "hi"
  end

  test "绑定快照：可序列化保留，PID/函数 tombstone" do
    s = Session.open("test_#{:erlang.unique_integer([:positive])}")

    Session.save_bindings(s,
      good: "hello",
      num: 42,
      bad_pid: self(),
      bad_fun: fn -> 1 end
    )

    restored = Session.load_bindings(s)
    assert restored[:good] == "hello"
    assert restored[:num] == 42
    refute Keyword.has_key?(restored, :bad_pid)
    refute Keyword.has_key?(restored, :bad_fun)
  end

  test "transcript 坏行（崩溃写了一半）跳过而非崩" do
    s = Session.open("test_#{:erlang.unique_integer([:positive])}")
    Session.append(s, %{"role" => "user", "content" => "hi"})
    File.write!(s.transcript, ~s({"role": "assistant", "content": "断了一半\n), [:append])
    Session.append(s, %{"role" => "user", "content" => "after"})

    msgs = Session.messages(s)
    assert Enum.map(msgs, & &1["content"]) == ["hi", "after"]
  end

  test "会话时间按本地时区显示" do
    s = Session.open("test_#{:erlang.unique_integer([:positive])}")
    Session.append(s, %{"role" => "user", "content" => "time"})

    stat = File.stat!(s.transcript)

    {{_y, _m, _d}, {hour, minute, _second}} =
      :calendar.universal_time_to_local_time(stat.mtime)

    pad = &String.pad_leading(Integer.to_string(&1), 2, "0")
    assert Session.meta(s.id).when_str =~ "#{pad.(hour)}:#{pad.(minute)}"
  end

  test "会话模型独立持久化且不覆盖标题" do
    id = "test_#{:erlang.unique_integer([:positive])}"
    Session.open(id)

    assert Session.model(id) == nil
    assert :ok = Session.rename(id, "独立会话")
    assert :ok = Session.set_model(id, "provider/session-model")
    assert Session.model(id) == "provider/session-model"
    assert Session.custom_title(id) == "独立会话"

    assert :ok = Session.rename(id, "新标题")
    assert Session.model(id) == "provider/session-model"
  end
end
