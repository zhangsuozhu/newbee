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

  test "idle image prompts start a turn and reach the kernel with or without queueId" do
    urls = ["data:image/png;base64," <> Base.encode64("png")]

    for request <- [
          {:prompt_images, urls, "inspect image", "image-id"},
          {:prompt_images, urls, "inspect image"}
        ] do
      st = %{base_state("idle-image-dispatch", busy: false) | kernel: self()}
      assert {:noreply, started} = Session.handle_cast(request, st)
      assert started.busy
      assert started.current.kind == "images"
      assert started.current.queued == false
      assert :queue.is_empty(started.queue)
      if tuple_size(request) == 4, do: assert(started.current.id == "image-id")
      assert Enum.any?(started.queue_events, &(&1.type == "started"))

      assert_receive {:"$gen_call", from, {:submit_images, ^urls, "inspect image"}}, 1_000
      GenServer.reply(from, {:ok, "received"})
      turn_id = started.turn_id
      assert_receive {:turn_finished, ^turn_id, {:ok, "received"}}, 1_000
      Process.cancel_timer(started.turn_timer)
      Process.demonitor(started.turn_ref, [:flush])
    end
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

  test "frontend renders pending input and identifies image turns" do
    js = File.read!("priv/web/app.js")
    css = File.read!("priv/web/style.css")
    html = File.read!("priv/web/index.html")
    [_, send_and_after] = String.split(js, "async function send(", parts: 2)
    [send_body | _] = String.split(send_and_after, "function interrupt()", parts: 2)

    refute send_body =~ "renderUserLine("
    assert send_body =~ "state.pendingPrompts.set(queueId"
    assert js =~ ~s|if (ev.type === "started")|
    assert js =~ "renderStartedPrompt(ev.id, p.current, ev.at)"
    assert js =~ ~s|else if (ev.type === "finished")|
    assert js =~ "normalizeUserAttachments"
    assert js =~ "typeof a === \"string\""
    assert js =~ "正在处理图片..."
    assert js =~ "state.turnKind"
    assert js =~ "const btw = text.match"
    assert js =~ ~s|type: "btw"|
    assert js =~ "renderBtwStart(p)"
    assert css =~ ".msg-btw"
    assert js =~ "state.interrupted"
    assert js =~ "function composerCanWhip"
    assert js =~ "return send(\"继续干活\")"
    assert js =~ "whip-mode"
    assert html =~ "send-icon"
    assert html =~ "whip-icon"
    assert css =~ "#send.whip-mode"
    assert css =~ "#send.whip-cracking"
    assert js =~ "newbee.interrupted."
    assert js =~ "function loadInterrupted"
    assert js =~ "setInterrupted(loadInterrupted(sid))"
    assert js =~ "function historyIndicatesInterrupted"
    assert js =~ "historyIndicatesInterrupted(historyMessages)"
    assert js =~ "last.role === \"tool\""
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

  test "pending task deliveries are recovered after session restart" do
    suffix = Integer.to_string(System.unique_integer([:positive]))
    root = Path.join(System.tmp_dir!(), "session-delivery-recovery-" <> suffix)
    File.mkdir_p!(root)
    path = Path.join(root, "events.jsonl")
    lead = "delivery-lead-" <> suffix
    worker = "delivery-worker-" <> suffix

    {:ok, coordinator} =
      Newbee.Collaboration.Coordinator.start_link(path: path, durability: :event)

    on_exit(fn ->
      if Process.alive?(coordinator), do: GenServer.stop(coordinator)
      File.rm_rf!(root)
    end)

    {:ok, group} =
      Newbee.Collaboration.Coordinator.create_group(%{
        "session_id" => lead,
        "title" => "delivery recovery",
        "project_root" => root,
        "command_id" => "delivery-group-" <> suffix
      })

    {:ok, _member} =
      Newbee.Collaboration.Coordinator.add_member(group["group_id"], %{
        "session_id" => worker,
        "role" => "worker",
        "command_id" => "delivery-member-" <> suffix
      })

    {:ok, board} = Newbee.Collaboration.Coordinator.board(group["group_id"], lead)

    {:ok, %{"task" => task}} =
      Newbee.Collaboration.Coordinator.board_create_task(group["group_id"], %{
        "session_id" => lead,
        "assigned_session_id" => worker,
        "title" => "recover task",
        "acceptance" => [%{"kind" => "file_exists", "path" => "proof.txt"}],
        "expected_revision" => board["revision"],
        "command_id" => "delivery-task-" <> suffix
      })

    {:ok, [delivery]} = Newbee.Collaboration.Coordinator.pending_deliveries(worker)
    assert delivery["kind"] == "task"

    {:noreply, recovered} =
      Session.handle_info(:pull_pending_deliveries, base_state(worker, busy: true))

    [item] = :queue.to_list(recovered.queue)
    assert item.kind == "collab_task"
    assert item.delivery_id == delivery["delivery_id"]
    assert item.payload["task_id"] == task["task_id"]
  end

  test "web render target does not retain a reloadable closure" do
    sid = "render-reload-" <> Integer.to_string(System.unique_integer([:positive]))
    Newbee.Bus.subscribe()
    {:ok, evaluator} = Newbee.DEE.Evaluator.start(mode: :local)

    {:ok, kernel} =
      Newbee.Agent.Loop.start_link(
        client: %{},
        evaluator: evaluator,
        session: false,
        render: {:web_session, sid},
        client_fun: fn _messages, on_text ->
          on_text.("ok")
          {:ok, %{"role" => "assistant", "content" => "ok", "tool_calls" => []}, %{}}
        end
      )

    on_exit(fn ->
      Newbee.Bus.unsubscribe()
      if Process.alive?(kernel), do: GenServer.stop(kernel)
      if Process.alive?(evaluator), do: GenServer.stop(evaluator)
    end)

    assert {:text, "ok"} = Newbee.Agent.Loop.submit(kernel, "hello")
    assert_receive {:newbee_event, :web_event, {:web_event, ^sid, :text, %{delta: "ok"}}}, 500
  end

  test "bounds queued user input and reports backpressure" do
    st = base_state("qfull_45402", busy: true)

    st =
      Enum.reduce(1..128, st, fn n, acc ->
        {:noreply, next} = Session.handle_cast({:prompt, "item #{n}", "id_#{n}"}, acc)
        next
      end)

    {:noreply, full} = Session.handle_cast({:prompt, "overflow", "overflow"}, st)

    assert :queue.len(full.queue) == 128
    assert MapSet.size(full.queue_ids) == 128
  end

  test "collab_lane classifies head vs normal without reading body" do
    assert Session.collab_lane("collab_task", nil) == :head
    assert Session.collab_lane("collab_result", "queue") == :head
    assert Session.collab_lane("collab_message", "wake") == :head
    assert Session.collab_lane("collab_message", :wake) == :head
    assert Session.collab_lane("collab_message", "queue") == :normal
    assert Session.collab_lane("collab_message", "notify") == :normal
    assert Session.collab_lane("collab_message", nil) == :normal
    assert Session.collab_lane("text", nil) == :normal
    # 正文写得再急也不能升级通道：分诊只看结构化头
    assert Session.collab_lane("collab_message", "十万火急快停下") == :normal
  end

  test "wake collab message takes head lane, queue message stays normal" do
    st = base_state("qlane_46001", busy: true)

    wake = %{"message_id" => "m-wake", "group_id" => "g", "body" => "urgent task", "delivery" => "wake"}
    {:noreply, st2} = Session.handle_cast({:collaboration_message, wake}, st)

    queued = %{"message_id" => "m-queue", "group_id" => "g", "body" => "fyi", "delivery" => "queue"}
    {:noreply, st3} = Session.handle_cast({:collaboration_message, queued}, st2)

    [first, second] = :queue.to_list(st3.queue)
    assert first.lane == :head
    assert second.lane == :normal
  end

  test "collab tasks and results take head lane" do
    st = base_state("qlane_46002", busy: true)

    task = %{"task_id" => "t1", "group_id" => "g", "title" => "do it", "attempt" => 0}
    {:noreply, st2} = Session.handle_cast({:collaboration_task, task}, st)
    [item] = :queue.to_list(st2.queue)
    assert item.lane == :head
    assert item.kind == "collab_task"

    result = %{"task_id" => "t2", "group_id" => "g", "title" => "done", "status" => "submitted", "attempt" => 0}
    {:noreply, st3} = Session.handle_cast({:collaboration_result, result}, st2)
    assert Enum.map(:queue.to_list(st3.queue), & &1.lane) == [:head, :head]
  end

  test "dequeue_next prefers head lane but keeps FIFO within lanes" do
    q =
      :queue.from_list([
        %{id: "u1", kind: "text", lane: :normal},
        %{id: "n1", kind: "collab_message", lane: :normal},
        %{id: "h1", kind: "collab_task", lane: :head},
        %{id: "h2", kind: "collab_message", lane: :head}
      ])

    assert {{:value, %{id: "h1"}}, rest, :head} = Session.dequeue_next(q)
    assert {{:value, %{id: "h2"}}, rest2, :head} = Session.dequeue_next(rest)
    assert {{:value, %{id: "u1"}}, rest3, :normal} = Session.dequeue_next(rest2)
    assert {{:value, %{id: "n1"}}, _, :normal} = Session.dequeue_next(rest3)
  end

  test "dequeue_next ignores legacy tuples for head search" do
    q = :queue.from_list([{:text, "old"}, %{id: "h", kind: "collab_task", lane: :head}])
    assert {{:value, %{id: "h"}}, _, :head} = Session.dequeue_next(q)
  end

  test "dequeue_next yields to normal after consecutive head cap" do
    q =
      :queue.from_list([
        %{id: "h1", kind: "collab_task", lane: :head},
        %{id: "h2", kind: "collab_task", lane: :head},
        %{id: "u1", kind: "text", lane: :normal}
      ])

    assert {{:value, %{id: "u1"}}, _, :normal} = Session.dequeue_next(q, 3)
    assert {{:value, %{id: "u1"}}, _, :normal} = Session.dequeue_next(q, 99)
    # 上限未到时仍优先 head
    assert {{:value, %{id: "h1"}}, _, :head} = Session.dequeue_next(q, 2)
  end

  test "dequeue_next on empty queue stays empty" do
    assert {:empty, _} = Session.dequeue_next(:queue.new())
  end

  test "enqueue records collab stats by lane and exposes them" do
    st = base_state("qstats_46003", busy: true)

    wake = %{"message_id" => "m1", "group_id" => "g", "body" => "w", "delivery" => "wake"}
    {:noreply, st2} = Session.handle_cast({:collaboration_message, wake}, st)
    {:noreply, st3} = Session.handle_cast({:prompt, "user words", "u1"}, st2)

    assert {:reply, state, _} = Session.handle_call(:state, self(), st3)
    assert state.collab_stats.enqueued_head == 1
    assert state.collab_stats.enqueued_normal == 0
    assert state.head_streak == 0

    assert {:reply, %{collab_stats: %{enqueued_head: 1}}, _} =
             Session.handle_call(:queue_list, self(), st3)
  end

  test "public queue exposes lane for collab items" do
    st = base_state("qlane_46004", busy: true)
    wake = %{"message_id" => "m1", "group_id" => "g", "body" => "w", "delivery" => "wake"}
    {:noreply, st2} = Session.handle_cast({:collaboration_message, wake}, st)

    assert {:reply, %{queue: [%{lane: :head, kind: "collab_message"}]}, _} =
             Session.handle_call(:queue_list, self(), st2)
  end

  test "preempt request enqueues head lane with badge and stats" do
    sid = "qpreempt_47001"
    Newbee.Bus.subscribe()
    on_exit(fn -> Newbee.Bus.unsubscribe() end)

    st = base_state(sid, busy: true)

    req = %{
      "request_id" => "req-1",
      "group_id" => "g",
      "from_session_id" => "lead",
      "to_session_id" => sid,
      "reason" => "dependency failed"
    }

    {:noreply, st2} = Session.handle_cast({:request_preempt, req}, st)
    [item] = :queue.to_list(st2.queue)
    assert item.kind == "preempt_request"
    assert item.lane == :head
    assert item.text =~ "dependency failed"
    assert item.text =~ "没有打断任何工作"

    assert {:reply, state, _} = Session.handle_call(:state, self(), st2)
    assert state.collab_stats.preempt_requested == 1

    assert_receive {:newbee_event, :web_event, {:web_event, ^sid, :preempt_requested, %{requestId: "req-1"}}},
                   500
  end

  test "preempt request dedups by request id and rejects garbage" do
    st = base_state("qpreempt_47002", busy: true)

    req = %{"request_id" => "req-dup", "group_id" => "g", "reason" => "stop"}
    {:noreply, st2} = Session.handle_cast({:request_preempt, req}, st)
    {:noreply, st3} = Session.handle_cast({:request_preempt, req}, st2)
    assert :queue.len(st3.queue) == 1

    {:noreply, same} = Session.handle_cast({:request_preempt, %{"reason" => "no id"}}, st3)
    assert :queue.len(same.queue) == 1
    {:noreply, same2} = Session.handle_cast({:request_preempt, "garbage"}, same)
    assert :queue.len(same2.queue) == 1

    assert {:reply, state, _} = Session.handle_call(:state, self(), same2)
    assert state.collab_stats.preempt_requested == 1
  end

  test "interrupt clears preempt requests but keeps collaboration deliveries" do
    st = base_state("qpreempt_47003", busy: true)

    {:noreply, st2} =
      Session.handle_cast(
        {:request_preempt, %{"request_id" => "req-x", "group_id" => "g", "reason" => "hold on"}},
        st
      )

    {:noreply, st3} =
      Session.handle_cast(
        {:collaboration_message,
         %{"delivery_id" => "d-keep", "message_id" => "m-keep", "group_id" => "g", "body" => "keep"}},
        st2
      )

    {:noreply, cleared} = Session.handle_cast(:interrupt, st3)
    assert [%{delivery_id: "d-keep"}] = :queue.to_list(cleared.queue)
  end

  test "preempt jumps ahead of queued user text" do
    st = base_state("qpreempt_47004", busy: true)
    {:noreply, st2} = Session.handle_cast({:prompt, "user first", "u1"}, st)

    {:noreply, st3} =
      Session.handle_cast(
        {:request_preempt, %{"request_id" => "req-jump", "group_id" => "g", "reason" => "urgent"}},
        st2
      )

    assert {{:value, %{kind: "preempt_request"}}, _, :head} = Session.dequeue_next(st3.queue)
  end

  defp chat_item(id, group \\ "g", body \\ "hi") do
    %{
      id: id,
      kind: "collab_message",
      lane: :normal,
      payload: %{"message_id" => id, "group_id" => group, "body" => body, "sender_session_id" => "w"}
    }
  end

  test "take_mergeable takes contiguous same-group chats only" do
    task = %{id: "t1", kind: "collab_task", lane: :head, payload: %{}}
    wake = %{id: "w1", kind: "collab_message", lane: :head, payload: %{"group_id" => "g", "body" => "w"}}

    q = :queue.from_list([chat_item("m1"), chat_item("m2"), task, chat_item("m3")])
    {taken, rest} = Session.take_mergeable(q, "g", 0)
    assert Enum.map(taken, & &1.id) == ["m1", "m2"]
    assert Enum.map(:queue.to_list(rest), & &1.id) == ["t1", "m3"]

    # take_mergeable 只看 picked 之后的剩余队列：首条即异组时一张不取
    q2 = :queue.from_list([chat_item("m2", "other"), chat_item("m3")])
    assert {[], _} = Session.take_mergeable(q2, "g", 0)

    q3 = :queue.from_list([wake, chat_item("m1")])
    assert {[], _} = Session.take_mergeable(q3, "g", 0)

    q4 = :queue.from_list([{:text, "legacy"}, chat_item("m1")])
    assert {[], _} = Session.take_mergeable(q4, "g", 0)

    assert {[], _} = Session.take_mergeable(:queue.new(), "g", 0)
  end

  test "take_mergeable respects count and byte caps" do
    many = for n <- 1..6, do: chat_item("m#{n}")
    {taken, rest} = Session.take_mergeable(:queue.from_list(many), "g", 0)
    assert Enum.map(taken, & &1.id) == ["m1", "m2", "m3", "m4"]
    assert :queue.len(rest) == 2

    big = [chat_item("b1", "g", String.duplicate("y", 7_900)), chat_item("b2", "g", "z")]
    {taken2, rest2} = Session.take_mergeable(:queue.from_list(big), "g", 500)
    assert taken2 == []
    assert :queue.len(rest2) == 2
  end

  test "contiguous same-group chats merge into one model turn" do
    if pid = Process.whereis(Newbee.Collaboration.Coordinator), do: GenServer.stop(pid)

    sid = "qmerge_47010"
    Newbee.Bus.subscribe()
    on_exit(fn -> Newbee.Bus.unsubscribe() end)

    st0 = %{base_state(sid, busy: true) | runtime_id: "rt-test"}
    bodies = %{1 => "第一条", 2 => "第二条", 3 => "第三条"}

    st1 =
      Enum.reduce(1..3, st0, fn n, acc ->
        msg = %{
          "message_id" => "m#{n}",
          "group_id" => "g",
          "body" => bodies[n],
          "sender_session_id" => "w",
          "delivery" => "queue"
        }

        {:noreply, next} = Session.handle_cast({:collaboration_message, msg}, acc)
        next
      end)

    assert :queue.len(st1.queue) == 3

    claimed =
      st1.queue
      |> :queue.to_list()
      |> Enum.map(&Map.put(&1, :claimed_runtime_id, "rt-test"))
      |> :queue.from_list()

    tid = make_ref()

    st2 = %{
      st1
      | queue: claimed,
        kernel: self(),
        busy: true,
        turn_task: self(),
        turn_ref: make_ref(),
        turn_id: tid,
        current: %{id: "prev"}
    }

    assert {:noreply, st3} = Session.handle_info({:turn_finished, tid, {:text, "prev"}}, st2)
    assert st3.busy

    assert_receive {:"$gen_call", from, {:submit, text}}, 1_000
    assert text =~ "第一条"
    assert text =~ "第二条"
    assert text =~ "第三条"
    assert text =~ "拼成一轮"
    GenServer.reply(from, {:text, "merged-done"})

    assert_receive {:newbee_event, :web_event,
                    {:web_event, ^sid, :queue_updated, %{event: %{type: "started", merged: 3}}}},
                   500

    assert_receive {:turn_finished, tid2, {:text, "merged-done"}}, 1_000
    assert {:noreply, st4} = Session.handle_info({:turn_finished, tid2, {:text, "merged-done"}}, st3)
    refute st4.busy
    assert :queue.is_empty(st4.queue)
    assert st4.collab_stats.merged_turns == 1
    assert st4.collab_stats.merged_messages == 3

    Process.cancel_timer(st3.turn_timer)
    Process.demonitor(st3.turn_ref, [:flush])
  end

  test "wake message dispatches alone, followers merge in the next turn" do
    if pid = Process.whereis(Newbee.Collaboration.Coordinator), do: GenServer.stop(pid)

    sid = "qwake_47011"
    st0 = %{base_state(sid, busy: true) | runtime_id: "rt-wake", kernel: self()}

    wake = %{
      "message_id" => "mw",
      "group_id" => "g",
      "body" => "wake body",
      "sender_session_id" => "w",
      "delivery" => "wake"
    }

    {:noreply, st1} = Session.handle_cast({:collaboration_message, wake}, st0)

    st2 =
      Enum.reduce(1..2, st1, fn n, acc ->
        msg = %{
          "message_id" => "mn#{n}",
          "group_id" => "g",
          "body" => "chat #{n}",
          "sender_session_id" => "w",
          "delivery" => "queue"
        }

        {:noreply, next} = Session.handle_cast({:collaboration_message, msg}, acc)
        next
      end)

    claimed =
      st2.queue
      |> :queue.to_list()
      |> Enum.map(&Map.put(&1, :claimed_runtime_id, "rt-wake"))
      |> :queue.from_list()

    tid = make_ref()

    st3 = %{
      st2
      | queue: claimed,
        busy: true,
        turn_task: self(),
        turn_ref: make_ref(),
        turn_id: tid,
        current: %{id: "prev"}
    }

    assert {:noreply, st4} = Session.handle_info({:turn_finished, tid, {:text, "prev"}}, st3)

    assert_receive {:"$gen_call", from, {:submit, text}}, 1_000
    assert text =~ "wake body"
    refute text =~ "chat 1"
    GenServer.reply(from, {:text, "wake-done"})

    assert_receive {:turn_finished, tid2, {:text, "wake-done"}}, 1_000
    assert {:noreply, st5} = Session.handle_info({:turn_finished, tid2, {:text, "wake-done"}}, st4)

    # wake 轮结束后，排队的两条闲聊自动续成一轮合并 turn（wake 本身始终单发）
    assert st5.busy
    assert :queue.is_empty(st5.queue)

    assert_receive {:"$gen_call", from2, {:submit, text2}}, 1_000
    assert text2 =~ "chat 1"
    assert text2 =~ "chat 2"
    GenServer.reply(from2, {:text, "chats-done"})

    assert_receive {:turn_finished, tid3, {:text, "chats-done"}}, 1_000
    assert {:noreply, st6} = Session.handle_info({:turn_finished, tid3, {:text, "chats-done"}}, st5)
    refute st6.busy
    assert :queue.is_empty(st6.queue)
    assert st6.collab_stats.merged_turns == 1
    assert st6.collab_stats.merged_messages == 2

    Process.cancel_timer(st4.turn_timer)
    Process.demonitor(st4.turn_ref, [:flush])
    Process.cancel_timer(st5.turn_timer)
    Process.demonitor(st5.turn_ref, [:flush])
  end
end
