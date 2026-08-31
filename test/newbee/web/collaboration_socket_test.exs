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
end
