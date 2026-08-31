defmodule Newbee.CommandsTest do
  use ExUnit.Case, async: true
  alias Newbee.Commands

  setup do
    say = fn _ -> :ok end
    %{ctx: %{say: say, kernel: nil}}
  end

  test "空输入 :ok" do
    assert :ok = Commands.handle("   ", %{say: fn _ -> :ok end})
  end

  test "普通文本返回 {:submit, text}" do
    assert {:submit, "hello"} = Commands.handle("hello", %{say: fn _ -> :ok end})
  end

  test "/quit 返回 :quit" do
    assert :quit = Commands.handle("/quit", %{say: fn _ -> :ok end})
  end

  test "/new 返回 :new（由调用方重建 kernel）" do
    assert :new = Commands.handle("/new", %{say: fn _ -> :ok end})
    assert :new = Commands.handle("/new  ", %{say: fn _ -> :ok end})
    assert "/new" in Commands.commands()
  end

  defp unique_session_id do
    # crypto 随机定长：跨 VM 不重复，且不互为前缀（前缀匹配测试需要唯一性）
    "test_resume_" <> (:crypto.strong_rand_bytes(6) |> Base.encode16(case: :lower))
  end

  @tag timeout: 120_000
  test "/resume 无参数返回 {:resume_picker, metas} 且含最新会话" do
    id = unique_session_id()
    s = Newbee.Session.open(id)
    Newbee.Session.append(s, %{"role" => "user", "content" => "帮我做个功能"})

    assert {:resume_picker, metas} = Commands.handle("/resume", %{say: fn _ -> :ok end})
    assert Enum.any?(metas, &(&1.id == s.id))
    Newbee.Session.delete(id)
  end

  test "/resume 精确 id 与前缀都返回 {:resume, id}" do
    id = unique_session_id()
    s = Newbee.Session.open(id)
    Newbee.Session.append(s, %{"role" => "user", "content" => "hi"})
    pref = String.slice(s.id, 0, String.length(s.id) - 1)

    assert {:resume, resumed} = Commands.handle("/resume #{s.id}", %{say: fn _ -> :ok end})
    assert resumed == s.id
    assert {:resume, resumed2} = Commands.handle("/resume #{pref}", %{say: fn _ -> :ok end})
    assert resumed2 == s.id
    Newbee.Session.delete(id)
  end

  test "@文件 展开为内容块（不存在则原样保留）" do
    tmp =
      Path.join(
        System.tmp_dir!(),
        "newbee_at_#{System.system_time(:native)}_#{:erlang.unique_integer([:positive])}.txt"
      )

    File.write!(tmp, "file-body")

    assert {:submit, text} = Commands.handle("@#{tmp}", %{say: fn _ -> :ok end})
    assert text =~ "file-body"

    assert {:submit, text2} = Commands.handle("@no/such/file.txt", %{say: fn _ -> :ok end})
    assert text2 == "@no/such/file.txt"
    File.rm(tmp)
  end

  test "/image 返回图片提交参数" do
    assert {:image, "error.png", "分析堆栈"} = Commands.handle("/image error.png 分析堆栈", %{say: fn _ -> :ok end})
    assert {:image, "error.png", ""} = Commands.handle("/image error.png", %{say: fn _ -> :ok end})
  end

  test "/bindings 输出绑定清单" do
    said = self()
    say = fn line -> send(said, {:said, line}) end
    assert :handled = Commands.handle("/bindings", %{say: say, kernel: nil})
    assert_received {:said, _msg}
  end

  test "/rules 输出规则而非未知命令" do
    said = self()
    say = fn line -> send(said, {:said, line}) end
    assert :handled = Commands.handle("/rules", %{say: say})
    assert_received {:said, msg}
    refute msg =~ "未知命令"
  end

  test "未知命令提示" do
    said = self()
    say = fn line -> send(said, {:said, line}) end
    assert :handled = Commands.handle("/nonsense-cmd", %{say: say})
    assert_received {:said, msg}
    assert msg =~ "未知命令"
  end

  test "/goal 无 kernel 上下文给出提示" do
    said = self()
    say = fn line -> send(said, {:said, line}) end
    assert :handled = Commands.handle("/goal", %{say: say, kernel: nil})
    assert_received {:said, msg}
    assert msg =~ "无 kernel"
  end

  test "/session 无 kernel 上下文给出提示" do
    said = self()
    say = fn line -> send(said, {:said, line}) end
    assert :handled = Commands.handle("/session", %{say: say, kernel: nil})
    assert_received {:said, msg}
    assert msg =~ "无会话"
  end

  test "/diff 不再是未知命令" do
    said = self()
    say = fn line -> send(said, {:said, line}) end
    assert :handled = Commands.handle("/diff", %{say: say, kernel: nil})
    assert_received {:said, msg}
    refute msg =~ "未知命令"
  end
end
