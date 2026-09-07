defmodule Newbee.Web.CollaborationSocketStub do
  use GenServer

  def start_link(sid, tester),
    do: GenServer.start_link(__MODULE__, {sid, tester}, name: {:via, Registry, {Newbee.Web.SessionRegistry, sid}})

  @impl true
  def init({sid, tester}), do: {:ok, %{sid: sid, tester: tester}}
  @impl true
  def handle_cast(message, state) do
    send(state.tester, {:socket_stub_got, state.sid, message})
    {:noreply, state}
  end
end

defmodule Newbee.Web.CollaborationSocketTest do
  use ExUnit.Case, async: false

  test "只向所属 session 下发群事件帧" do
    event = %{
      "event_id" => 7,
      "topic" => "collab_message_created",
      "group_id" => "grp-test",
      "session_ids" => ["session-a", "session-b"],
      "payload" => %{
        "message" => %{
          "message_id" => "msg-test",
          "sender_session_id" => "session-a",
          "body" => "群消息"
        }
      }
    }

    assert {:push, [{:text, frame}], %{sid: "session-b"}} =
             Newbee.Web.Socket.handle_info(
               {:newbee_event, :collab_event, event},
               %{sid: "session-b"}
             )

    decoded = frame |> IO.iodata_to_binary() |> Jason.decode!()
    assert decoded["type"] == "group_event"
    assert decoded["groupId"] == "grp-test"
    assert decoded["eventId"] == 7
    assert decoded["payload"]["message"]["body"] == "群消息"

    assert {:ok, %{sid: "outsider"}} =
             Newbee.Web.Socket.handle_info(
               {:newbee_event, :collab_event, event},
               %{sid: "outsider"}
             )
  end

  test "跨会话权限回复只允许直接父会话或总控" do
    if pid = Process.whereis(Newbee.Collaboration.Coordinator), do: GenServer.stop(pid)
    root = Path.join(System.tmp_dir!(), "newbee-socket-perm-#{System.unique_integer([:positive])}")

    {:ok, coordinator} =
      Newbee.Collaboration.Coordinator.start_link(path: Path.join(root, "events.jsonl"), durability: :event)

    assert {:ok, group} = Newbee.Collaboration.Coordinator.create_group(%{"session_id" => "parent", "title" => "审批"})

    assert {:ok, _} =
             Newbee.Collaboration.Coordinator.add_member(group["group_id"], %{
               "session_id" => "child",
               "parent_session_id" => "parent"
             })

    assert {:ok, _} =
             Newbee.Collaboration.Coordinator.add_member(group["group_id"], %{
               "session_id" => "sibling",
               "parent_session_id" => "parent"
             })

    {:ok, child} = Newbee.Web.CollaborationSocketStub.start_link("child", self())

    denied = Jason.encode!(%{"type" => "permission", "ok" => true, "sessionId" => "child"})
    assert {:ok, %{sid: "sibling"}} = Newbee.Web.Socket.handle_in({denied, [opcode: :text]}, %{sid: "sibling"})
    refute_receive {:socket_stub_got, "child", {:permission_reply, true}}, 100

    allowed = Jason.encode!(%{"type" => "permission", "ok" => false, "sessionId" => "child"})
    assert {:ok, %{sid: "parent"}} = Newbee.Web.Socket.handle_in({allowed, [opcode: :text]}, %{sid: "parent"})
    assert_receive {:socket_stub_got, "child", {:permission_reply, false}}, 1_000

    GenServer.stop(child)
    GenServer.stop(coordinator)
    File.rm_rf!(root)
  end

  test "终端使用系统 script PTY，不依赖 Python proxy" do
    assert is_binary(System.find_executable("script"))
    refute File.exists?(Path.expand("priv/web/pty_proxy.py"))

    sid = "native-pty-#{System.unique_integer([:positive])}"
    root = Path.join(System.tmp_dir!(), "newbee-native-pty-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)

    on_exit(fn ->
      Newbee.Web.Terminal.close(sid)
      File.rm_rf!(root)
    end)

    assert {:ok, pid} = Newbee.Web.Terminal.ensure(sid, root)
    state = :sys.get_state(pid)
    assert state.pty?
    assert state.pty_driver == :script
  end

  test "终端在会话工作目录执行命令并回传输出" do
    sid = "terminal-socket-#{System.unique_integer([:positive])}"
    root = Path.join(System.tmp_dir!(), "newbee-terminal-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    :ok = Newbee.Session.set_cwd(sid, root)

    on_exit(fn ->
      File.rm_rf!(root)
      Newbee.Session.delete(sid)
    end)

    :ok = Newbee.Bus.subscribe()

    state = %{sid: sid, terminal: nil}
    open = Jason.encode!(%{"type" => "terminal_open"})
    assert {:push, [{:text, ready}], state} = Newbee.Web.Socket.handle_in({open, [opcode: :text]}, state)
    ready = ready |> IO.iodata_to_binary() |> Jason.decode!()
    assert ready["type"] == "terminal"
    assert ready["event"] == "ready"
    assert ready["pty"] == true
    assert ready["resize"] == true
    assert ready["cwd"] == Path.expand(root)

    resize = Jason.encode!(%{"type" => "terminal_resize", "cols" => 120, "rows" => 40})
    assert {:ok, ^state} = Newbee.Web.Socket.handle_in({resize, [opcode: :text]}, state)

    size_input = Jason.encode!(%{"type" => "terminal_input", "data" => "stty size\n"})
    assert {:ok, ^state} = Newbee.Web.Socket.handle_in({size_input, [opcode: :text]}, state)
    size_output = terminal_output_until(sid, state, "40 120")
    assert size_output["data"] =~ "40 120"

    long_input = Jason.encode!(%{"type" => "terminal_input", "data" => "sleep 20\n"})
    assert {:ok, ^state} = Newbee.Web.Socket.handle_in({long_input, [opcode: :text]}, state)
    Process.sleep(200)

    interrupt = Jason.encode!(%{"type" => "terminal_interrupt"})
    assert {:ok, ^state} = Newbee.Web.Socket.handle_in({interrupt, [opcode: :text]}, state)
    Process.sleep(250)

    input = Jason.encode!(%{"type" => "terminal_input", "data" => "printf terminal-ok\n"})
    assert {:ok, ^state} = Newbee.Web.Socket.handle_in({input, [opcode: :text]}, state)

    output = terminal_output_until(sid, state, "terminal-ok")
    assert output["event"] == "output"
    assert output["data"] =~ "terminal-ok"

    close = Jason.encode!(%{"type" => "terminal_close"})
    assert {:ok, %{terminal: nil}} = Newbee.Web.Socket.handle_in({close, [opcode: :text]}, state)
    assert [] = Registry.lookup(Newbee.Web.TerminalRegistry, sid)
  end

  test "手动终端命令和输出写入共享 session transcript" do
    sid = "terminal-context-" <> Integer.to_string(System.unique_integer([:positive]))

    root =
      Path.join(System.tmp_dir!(), "newbee-terminal-context-" <> Integer.to_string(System.unique_integer([:positive])))

    File.mkdir_p!(root)

    :ok = Newbee.Session.set_cwd(sid, root)

    on_exit(fn ->
      Newbee.Web.Terminal.close(sid)
      Newbee.Session.delete(sid)
      File.rm_rf!(root)
    end)

    assert {:ok, _pid} = Newbee.Web.Terminal.ensure(sid, root)

    assert :ok = Newbee.Web.Terminal.input(sid, "echo $((300000+14159))" <> <<10>>)

    assert wait_for_transcript(sid, "314159")
  end

  defp wait_for_transcript(sid, needle), do: wait_for_transcript(sid, needle, 50)

  defp wait_for_transcript(sid, needle, attempts) when attempts > 0 do
    found? =
      sid
      |> Newbee.Session.open()
      |> Newbee.Session.messages()
      |> Enum.any?(fn message ->
        content = Map.get(message, <<99, 111, 110, 116, 101, 110, 116>>)
        is_binary(content) and String.contains?(content, needle)
      end)

    if found? do
      true
    else
      Process.sleep(100)
      wait_for_transcript(sid, needle, attempts - 1)
    end
  end

  defp wait_for_transcript(_sid, _needle, _attempts), do: false

  defp terminal_output_until(sid, state, marker) do
    assert_receive {:newbee_event, :terminal_event, {:terminal_event, ^sid, :output, payload}}, 5_000
    event = {:newbee_event, :terminal_event, {:terminal_event, sid, :output, payload}}
    assert {:push, [{:text, frame}], ^state} = Newbee.Web.Socket.handle_info(event, state)
    output = frame |> IO.iodata_to_binary() |> Jason.decode!()

    if output["event"] == "output" and String.contains?(output["data"] || "", marker) do
      output
    else
      terminal_output_until(sid, state, marker)
    end
  end
end
