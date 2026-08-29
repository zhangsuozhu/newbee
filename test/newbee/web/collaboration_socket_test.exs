defmodule Newbee.Web.CollaborationSocketTest do
  use ExUnit.Case, async: true

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
end
