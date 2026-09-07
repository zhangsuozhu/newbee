defmodule Newbee.Collaboration.PreemptStub do
  use GenServer

  def start_link(sid, tester) do
    GenServer.start_link(__MODULE__, tester, name: {:via, Registry, {Newbee.Web.SessionRegistry, sid}})
  end

  @impl true
  def init(tester), do: {:ok, tester}

  @impl true
  def handle_cast(msg, tester) do
    send(tester, {:preempt_stub, msg})
    {:noreply, tester}
  end
end

defmodule Newbee.Collaboration.PreemptChannelTest do
  use ExUnit.Case, async: false

  alias Newbee.Collaboration.{Coordinator, PreemptStub}

  setup do
    if pid = Process.whereis(Coordinator), do: GenServer.stop(pid)

    root =
      Path.join(System.tmp_dir!(), "newbee-collab-preempt-" <> Integer.to_string(System.unique_integer([:positive])))

    {:ok, coord} = Coordinator.start_link(path: Path.join(root, "events.jsonl"), durability: :event)
    {:ok, stub} = PreemptStub.start_link("preempt-worker", self())

    on_exit(fn ->
      if Process.alive?(coord), do: GenServer.stop(coord)
      if Process.alive?(stub), do: Process.exit(stub, :kill)
      File.rm_rf!(root)
    end)

    %{}
  end

  defp open_group(title) do
    {:ok, group} =
      Coordinator.create_group(%{
        "session_id" => "parent",
        "title" => title,
        "project_root" => File.cwd!(),
        "command_id" => "preempt-open-#{System.unique_integer([:positive])}"
      })

    gid = group["group_id"]
    {:ok, _} = Coordinator.add_member(gid, %{"session_id" => "preempt-worker"})
    gid
  end

  defp preempt_attrs(overrides \\ %{}) do
    Map.merge(
      %{
        "from_session_id" => "parent",
        "to_session_id" => "preempt-worker",
        "reason" => "dependency failed",
        "request_id" => "req-#{System.unique_integer([:positive])}",
        "command_id" => "preempt-cmd-#{System.unique_integer([:positive])}"
      },
      overrides
    )
  end

  test "member routes preempt to target session and timeline keeps the event" do
    gid = open_group("route preempt")

    assert {:ok, request} =
             Coordinator.request_preempt(
               gid,
               preempt_attrs(%{"task_id" => "t-1", "attempt" => 2, "board_revision" => 3})
             )

    assert request["accepted"] == true
    assert request["reason"] == "dependency failed"
    assert request["task_id"] == "t-1"
    assert request["attempt"] == 2
    assert request["group_id"] == gid

    assert_receive {:preempt_stub, {:request_preempt, delivered}}, 1_000
    assert delivered["request_id"] == request["request_id"]

    assert {:ok, activity} = Coordinator.activity(gid, limit: 50)
    assert Enum.any?(activity, &(&1["topic"] == "collab_preempt_requested"))
  end

  test "non-member sender and unknown recipient are refused" do
    gid = open_group("refuse preempt")

    assert {:error, "not_member", _} =
             Coordinator.request_preempt(gid, preempt_attrs(%{"from_session_id" => "outsider"}))

    assert {:error, "bad_recipient", _} =
             Coordinator.request_preempt(gid, preempt_attrs(%{"to_session_id" => "ghost"}))

    refute_received {:preempt_stub, _}
  end

  test "malformed requests are rejected without side effects" do
    gid = open_group("validate preempt")
    good = preempt_attrs()

    assert {:error, "bad_request", _} = Coordinator.request_preempt(gid, Map.delete(good, "reason"))
    assert {:error, "bad_request", _} = Coordinator.request_preempt(gid, Map.delete(good, "request_id"))
    assert {:error, "bad_request", _} = Coordinator.request_preempt(gid, Map.delete(good, "from_session_id"))
    assert {:error, "bad_request", _} = Coordinator.request_preempt(gid, Map.delete(good, "to_session_id"))
    assert {:error, "bad_request", _} = Coordinator.request_preempt(gid, "not-a-map")

    assert {:error, "request_too_large", _} =
             Coordinator.request_preempt(gid, preempt_attrs(%{"reason" => String.duplicate("x", 2_049)}))

    assert {:error, "bad_request", _} =
             Coordinator.request_preempt(gid, preempt_attrs(%{"task_id" => "t-1"}))

    refute_received {:preempt_stub, _}
  end

  test "duplicate command_id is idempotent" do
    gid = open_group("dedupe preempt")
    attrs = preempt_attrs(%{"request_id" => "req-dup", "command_id" => "preempt-cmd-dup"})

    assert {:ok, _} = Coordinator.request_preempt(gid, attrs)
    assert {:error, "duplicate_command", _} = Coordinator.request_preempt(gid, attrs)

    assert_receive {:preempt_stub, {:request_preempt, _}}, 1_000
    refute_received {:preempt_stub, _}
  end

  test "offline target keeps timeline event with accepted false" do
    gid = open_group("offline preempt")
    {:ok, _} = Coordinator.add_member(gid, %{"session_id" => "offline-worker"})

    assert {:ok, request} =
             Coordinator.request_preempt(
               gid,
               preempt_attrs(%{"to_session_id" => "offline-worker", "reason" => "stop when back"})
             )

    assert request["accepted"] == false

    assert {:ok, activity} = Coordinator.activity(gid, limit: 50)
    assert Enum.any?(activity, &(&1["topic"] == "collab_preempt_requested"))
  end

  test "preempt does not touch board revision or messages" do
    gid = open_group("clean preempt")
    {:ok, board_before} = Coordinator.board(gid, "parent")
    {:ok, messages_before} = Coordinator.messages(gid, [])

    assert {:ok, _} = Coordinator.request_preempt(gid, preempt_attrs())

    {:ok, board_after} = Coordinator.board(gid, "parent")
    {:ok, messages_after} = Coordinator.messages(gid, [])
    assert board_after["revision"] == board_before["revision"]
    assert length(messages_after) == length(messages_before)
  end
end
