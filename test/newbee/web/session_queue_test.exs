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

  test "interrupt preserves queued collaboration deliveries and requeues the current one" do
    st = base_state("qint_collab_45251", busy: true)

    message = %{
      "delivery_id" => "delivery-preserved",
      "message_id" => "m-preserved",
      "group_id" => "g",
      "body" => "keep"
    }

    {:noreply, st2} = Session.handle_cast({:collaboration_message, message}, st)
    {:noreply, st3} = Session.handle_cast({:prompt, "discard me", "discarded-id"}, st2)

    {:noreply, preserved} = Session.handle_cast(:interrupt, st3)
    assert [%{delivery_id: "delivery-preserved"}] = :queue.to_list(preserved.queue)

    current_item = %{
      id: "delivery-current",
      kind: "collab_message",
      preview: "keep",
      delivery_kind: "message",
      delivery_id: "delivery-current",
      payload: message
    }

    current = %{delivery_item: current_item, delivery_id: "delivery-current", delivery_kind: "message"}
    st4 = %{base_state("qint_current_45252", busy: true) | current: current}

    {:noreply, recovered} = Session.handle_cast(:interrupt, st4)
    assert recovered.current == nil
    assert [%{delivery_id: "delivery-current"}] = :queue.to_list(recovered.queue)
    refute Enum.any?(:queue.to_list(recovered.queue), &Map.has_key?(&1, :retry_after_restart))
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

  test "turn DOWN clears busy and late results do not finish another turn" do
    ref = make_ref()
    id = make_ref()

    state = %{
      base_state("turn-down-safety", busy: true)
      | turn_task: self(),
        turn_ref: ref,
        turn_id: id,
        current: %{id: "turn"}
    }

    assert {:noreply, finished} = Session.handle_info({:DOWN, ref, :process, self(), :killed}, state)
    refute finished.busy
    assert finished.current == nil
    assert finished.turn_ref == nil
    assert finished.turns == 1
    assert {:noreply, ^finished} = Session.handle_info({:turn_finished, id, {:text, "late"}}, finished)
    next = %{state | turn_id: make_ref(), turn_ref: make_ref()}
    assert {:noreply, ^next} = Session.handle_info({:turn_finished, id, {:text, "late"}}, next)
  end

  test "peek_busy derives from live turn" do
    alive = spawn(fn -> Process.sleep(5000) end)
    on_exit(fn -> Process.exit(alive, :kill) end)
    live_state = %{base_state("peek-live", busy: true) | turn_task: alive, turn_ref: make_ref(), turn_id: make_ref()}
    assert {:reply, true, _} = Session.handle_call(:peek_busy, self(), live_state)
    dead = spawn(fn -> :ok end)
    dead_ref = Process.monitor(dead)
    assert_receive {:DOWN, ^dead_ref, :process, ^dead, _}, 1000
    dead_state = %{base_state("peek-dead", busy: true) | turn_task: dead, turn_ref: make_ref(), turn_id: make_ref()}
    assert {:reply, false, _} = Session.handle_call(:peek_busy, self(), dead_state)
    assert {:reply, false, _} = Session.handle_call(:peek_busy, self(), base_state("peek-idle", busy: false))
  end

  test "watchdog mismatch and recover guards are ignored" do
    st = base_state("watch-guard", busy: false)
    assert {:noreply, ^st} = Session.handle_info({:turn_watchdog, make_ref()}, st)
    booting = %{st | booting: true}
    assert {:noreply, ^booting} = Session.handle_info(:recover_kernel, booting)
    active = %{st | turn_id: make_ref()}
    assert {:noreply, ^active} = Session.handle_info(:recover_kernel, active)
  end

  test "abnormal turn with queued input schedules kernel recovery" do
    dead_kernel = spawn(fn -> :ok end)
    kref = Process.monitor(dead_kernel)
    assert_receive {:DOWN, ^kref, :process, ^dead_kernel, _}, 1000
    turn = spawn(fn -> :ok end)
    tref = Process.monitor(turn)
    assert_receive {:DOWN, ^tref, :process, ^turn, _}, 1000

    base = %{
      base_state("recover-q", busy: true)
      | kernel: dead_kernel,
        turn_task: turn,
        turn_ref: make_ref(),
        turn_id: make_ref(),
        current: %{id: "t"}
    }

    queued = %{base | queue: :queue.in(%{id: "q1", kind: "text", text: "hi"}, base.queue)}
    assert {:noreply, _finished} = Session.handle_info({:DOWN, queued.turn_ref, :process, turn, :killed}, queued)
    assert_received :recover_kernel
  end

  test "direct prompt broadcasts started before execution failure and then finished" do
    sid = "qdirect_45402"
    Newbee.Bus.subscribe()
    on_exit(fn -> Newbee.Bus.unsubscribe() end)

    st = base_state(sid, busy: false)
    {:noreply, st2} = Session.handle_cast({:prompt, "run later", "directid"}, st)

    refute st2.busy
    assert st2.current == nil

    assert_receive {:newbee_event, :web_event,
                    {:web_event, ^sid, :queue_updated,
                     %{
                       event: %{type: "started", id: "directid", queued: false},
                       current: %{id: "directid", text: "run later", queued: false}
                     }}},
                   500

    assert_receive {:newbee_event, :web_event, {:web_event, ^sid, :error, _}}, 500

    assert_receive {:newbee_event, :web_event,
                    {:web_event, ^sid, :queue_updated, %{event: %{type: "finished", id: "directid"}, current: nil}}},
                   500
  end

  test "busy queue exposes a steerable head at the model-call checkpoint" do
    sid = "qsteer_45444"
    Newbee.Bus.subscribe()
    on_exit(fn -> Newbee.Bus.unsubscribe() end)

    st = base_state(sid, busy: true)
    {:noreply, queued} = Session.handle_cast({:prompt, "change direction", "steerid"}, st)
    assert {:reply, {:ok, item}, consumed} = Session.handle_call(:take_steering, self(), queued)
    assert item.id == "steerid"
    assert :queue.len(consumed.queue) == 0

    assert_receive {:newbee_event, :web_event,
                    {:web_event, ^sid, :queue_updated,
                     %{event: %{type: "steered", id: "steerid", input: %{text: "change direction"}}}}},
                   500
  end

  test "commands stay queued until the current turn finishes" do
    st = base_state("qcommand_45445", busy: true)
    {:noreply, queued} = Session.handle_cast({:prompt, "/status", "cmdid"}, st)
    assert {:reply, :none, same} = Session.handle_call(:take_steering, self(), queued)
    assert :queue.len(same.queue) == 1
  end

  test "frontend renders pending user input only when the server starts it" do
    js = File.read!("priv/web/app.js")
    css = File.read!("priv/web/style.css")
    [_, send_and_after] = String.split(js, "async function send()", parts: 2)
    [send_body | _] = String.split(send_and_after, "function interrupt()", parts: 2)

    refute send_body =~ "renderUserLine("
    assert send_body =~ "state.pendingPrompts.set(queueId"
    assert js =~ ~s|if (ev.type === "started")|
    assert js =~ "renderStartedPrompt(ev.id, p.current, ev.at)"
    assert js =~ ~s|else if (ev.type === "finished")|
    assert js =~ "const btw = text.match"
    assert js =~ ~s|type: "btw"|
    assert js =~ "renderBtwStart(p)"
    assert css =~ ".msg-btw"
  end

  test "/btw runs independently without changing the main transcript" do
    sid = "qbtw_#{System.unique_integer([:positive])}"
    test_pid = self()
    session = Newbee.Session.open(sid)
    Newbee.Session.append(session, %{"role" => "user", "content" => "主任务上下文"})

    plug = fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:btw_request, Jason.decode!(raw)})

      Req.Test.json(conn, %{
        "output" => [%{"type" => "message", "content" => [%{"type" => "output_text", "text" => "side answer"}]}],
        "usage" => %{"input_tokens" => 3, "output_tokens" => 2, "total_tokens" => 5}
      })
    end

    client =
      Newbee.LLM.Client.new(
        api: "openai-responses",
        model: "test/btw-session",
        api_key: "test",
        base_url: "http://localhost",
        req_options: [plug: plug, retry: false]
      )

    Newbee.Bus.subscribe()

    on_exit(fn ->
      Newbee.Bus.unsubscribe()
      Newbee.Session.delete(sid)
    end)

    st = %Session{sid: sid, client: client, busy: true}
    {:noreply, st2} = Session.handle_cast({:btw, "当前改动做了什么？", "btwid"}, st)
    assert st2.busy
    assert_receive {:newbee_event, :web_event, {:web_event, ^sid, :btw_started, %{id: "btwid"}}}, 500
    assert_receive {:btw_request, body}, 5_000
    assert body["tools"] == []
    assert List.last(body["input"]) == %{"role" => "user", "content" => "当前改动做了什么？"}
    assert_receive {:btw_finished, "btwid", result}, 5_000

    {:noreply, _st3} = Session.handle_info({:btw_finished, "btwid", result}, st2)

    assert_receive {:newbee_event, :web_event, {:web_event, ^sid, :btw_done, %{id: "btwid", content: "side answer"}}},
                   500

    refute Enum.any?(Newbee.Session.messages(session), &(&1["content"] == "当前改动做了什么？"))
  end

  test "collaboration queue retains raw payload and stable delivery id" do
    st = base_state("qraw_45400", busy: true)

    message = %{
      "delivery_id" => "delivery-question-1",
      "message_id" => "m-question-1",
      "group_id" => "g-raw",
      "sender_session_id" => "sender",
      "kind" => "question",
      "body" => "question body"
    }

    {:noreply, st2} = Session.handle_cast({:collaboration_message, message}, st)
    [item] = :queue.to_list(st2.queue)

    assert item.delivery_id == "delivery-question-1"
    assert item.payload == message
    refute Map.has_key?(item, :prompt)
    refute Map.has_key?(item, :text)
  end

  test "task progress is display-only and does not enter the model queue" do
    st = base_state("qprogress_45401", busy: true)

    progress = %{
      "delivery_id" => "delivery-progress-1",
      "message_id" => "m-progress-1",
      "group_id" => "g-progress",
      "task_id" => "task-progress-1",
      "attempt" => 2,
      "kind" => "task_progress",
      "progress" => "50%"
    }

    {:noreply, st2} = Session.handle_cast({:collaboration_message, progress}, st)
    assert :queue.len(st2.queue) == 0
  end
end
