defmodule Newbee.Web.SessionQueueTest do
  use ExUnit.Case, async: false

  alias Newbee.Web.Session

  defp base_state(sid, opts) do
    %Session{
      sid: sid,
      kernel: nil,
      client: nil,
      busy: Keyword.get(opts, :busy, true),
      booting: Keyword.get(opts, :booting, false),
      queue: :queue.new(),
      queue_seq: 0,
      queue_events: [],
      current: nil
    }
  end

  test "busy prompt enqueues with client queueId and state exposes queue" do
    sid = "qtest_44994"
    st = base_state(sid, busy: true)
    {:noreply, st2} = Session.handle_cast({:prompt, "hello queue", "myid123"}, st)
    assert :queue.len(st2.queue) == 1
    [item] = :queue.to_list(st2.queue)
    assert item.id == "myid123"
    assert item.kind == "text"
    assert item.text == "hello queue"
    assert {:reply, state, _} = Session.handle_call(:state, self(), st2)
    assert state.queued == 1
    assert [%{id: "myid123", kind: "text"}] = state.queue
    assert state.queue_seq >= 1
    assert is_list(state.queue_events)
  end

  test "same queueId does not duplicate" do
    sid = "qdup_45058"
    st = base_state(sid, busy: true)
    {:noreply, st2} = Session.handle_cast({:prompt, "first", "dupid"}, st)
    {:noreply, st3} = Session.handle_cast({:prompt, "first retry", "dupid"}, st2)
    assert :queue.len(st3.queue) == 1
  end

  test "queue_list / cancel_queued / clear_queue" do
    sid = "qops_45122"
    st = base_state(sid, busy: true)
    {:noreply, st2} = Session.handle_cast({:prompt, "one", "id_one"}, st)
    {:noreply, st3} = Session.handle_cast({:prompt, "two", "id_two"}, st2)
    assert {:reply, %{queued: 2}, _} = Session.handle_call(:queue_list, self(), st3)
    assert {:reply, {:ok, %{cancelled: "id_one", queued: 1}}, st4} =
             Session.handle_call({:cancel_queued, "id_one"}, self(), st3)
    assert :queue.len(st4.queue) == 1
    assert {:reply, {:error, :not_found}, _} = Session.handle_call({:cancel_queued, "nope"}, self(), st4)
    assert {:reply, {:ok, %{cleared: 1}}, st5} = Session.handle_call(:clear_queue, self(), st4)
    assert :queue.len(st5.queue) == 0
  end

  test "collab_message dedups by message_id" do
    sid = "qcollab_45186"
    st = base_state(sid, busy: true)
    msg = %{"message_id" => "m1", "body" => "hi", "group_id" => "g", "sender_session_id" => "s"}
    {:noreply, st2} = Session.handle_cast({:collaboration_message, msg}, st)
    {:noreply, st3} = Session.handle_cast({:collaboration_message, msg}, st2)
    assert :queue.len(st3.queue) == 1
  end

  test "interrupt clears queue and broadcasts queue_updated" do
    sid = "qint_45250"
    Newbee.Bus.subscribe()
    on_exit(fn -> Newbee.Bus.unsubscribe() end)
    st = base_state(sid, busy: true)
    {:noreply, st2} = Session.handle_cast({:prompt, "a", "ida"}, st)
    {:noreply, st3} = Session.handle_cast({:prompt, "b", "idb"}, st2)
    # drain enqueued broadcasts
    for _ <- 1..2 do
      receive do
        {:newbee_event, :web_event, {:web_event, _, :queue_updated, _}} -> :ok
      after
        500 -> :ok
      end
    end
    # also drain legacy queued notices
    for _ <- 1..2 do
      receive do
        {:newbee_event, :web_event, {:web_event, _, :queued, _}} -> :ok
      after
        0 -> :ok
      end
    end
    {:noreply, st4} = Session.handle_cast(:interrupt, st3)
    assert :queue.len(st4.queue) == 0
    assert st4.current == nil
    assert_receive {:newbee_event, :web_event, {:web_event, _, :queue_updated, %{event: %{type: "cleared"}}}}, 500
  end

  test "booting prompt enqueues and prompt_images enqueues" do
    sid = "qboot_45314"
    st = base_state(sid, busy: false, booting: true)
    {:noreply, st2} = Session.handle_cast({:prompt, "boot text", "bootid"}, st)
    assert :queue.len(st2.queue) == 1
    {:noreply, st3} = Session.handle_cast({:prompt_images, ["data:image/png;base64,xx"], "with pic", "imgid"}, st2)
    assert :queue.len(st3.queue) == 2
    assert {:reply, %{queue: q}, _} = Session.handle_call(:queue_list, self(), st3)
    assert Enum.map(q, & &1.id) == ["bootid", "imgid"]
  end
end
