defmodule Newbee.Web.Socket do
  @moduledoc """
  WebUI 事件下行通道（移植 dsh websocket-downlink 语义）：浏览器连
  `GET /ws?session=<sid>`，本进程订阅 Bus，把该会话的 Loop 事件以 JSON
  帧推下去；同时接收上行控制帧（interrupt / permission_reply / btw / terminal）。

  下行帧： {"type": "event", "sessionId": sid, "kind": "text", "payload": {...}}
           {"type": "terminal", "event": "output", "data": "..."}
  上行帧： {"type": "interrupt"} | {"type": "permission", "ok": true} |
           {"type": "prompt", "text": "..."} | {"type": "btw", "question": "..."} |
           {"type": "terminal_open"} | {"type": "terminal_input", "data": "..."} | {"type": "terminal_interrupt"} | {"type": "terminal_wake"} | {"type": "terminal_resize", "cols": 120, "rows": 40}


  """
  @behaviour WebSock

  alias Newbee.Web.Session, as: WSession

  @max_terminal_input_bytes 64_000

  @impl true
  def init(%{assigns: %{session: sid}}) do
    Newbee.Bus.subscribe()
    {:ok, _pid, _sid} = WSession.ensure(sid)
    {:ok, %{sid: sid, terminal: nil}}
  end

  @impl true
  def handle_in({text, [opcode: :text]}, st) do
    case Jason.decode(text) do
      {:ok, %{"type" => "terminal_open"}} ->
        terminal_open(st)

      {:ok, %{"type" => "terminal_input", "data" => data}} when is_binary(data) ->
        terminal_input(st, data)

      {:ok, %{"type" => "terminal_resize", "cols" => cols, "rows" => rows}} ->
        terminal_resize(st, cols, rows)

      {:ok, %{"type" => "terminal_interrupt"}} ->
        terminal_interrupt(st)

      {:ok, %{"type" => "terminal_wake"}} ->
        terminal_wake(st)

      {:ok, %{"type" => "terminal_close"}} ->
        {:ok, close_terminal(st)}

      {:ok, %{"type" => "interrupt"}} ->
        cast_session(st.sid, &WSession.interrupt/1)
        {:ok, st}

      {:ok, %{"type" => "permission", "ok" => ok} = frame} ->
        target = frame["sessionId"] || st.sid

        if Newbee.Collaboration.Coordinator.can_approve_permission?(st.sid, target) do
          cast_session(target, &WSession.permission_reply(&1, ok))
        end

        {:ok, st}

      {:ok, %{"type" => "btw", "question" => question} = frame} ->
        request_id = frame["requestId"] || frame["request_id"]
        cast_session(st.sid, &WSession.btw(&1, question, request_id))
        {:ok, st}

      {:ok, %{"type" => "prompt", "text" => t} = frame} ->
        qid = frame["queueId"] || frame["queue_id"]

        if is_binary(qid) and String.trim(qid) != "" do
          cast_session(st.sid, &WSession.prompt(&1, t, qid))
        else
          cast_session(st.sid, &WSession.prompt(&1, t))
        end

        {:ok, st}

      {:ok, %{"type" => "promptImage", "images" => images, "text" => t} = frame} ->
        qid = frame["queueId"] || frame["queue_id"]

        if is_binary(qid) and String.trim(qid) != "" do
          cast_session(st.sid, &WSession.prompt_images(&1, images || [], t || "", qid))
        else
          cast_session(st.sid, &WSession.prompt_images(&1, images || [], t || ""))
        end

        {:ok, st}

      {:ok, %{"type" => "cancelQueued"} = frame} ->
        qid = frame["queueId"] || frame["queue_id"] || frame["id"]

        if is_binary(qid) do
          q = String.trim(qid)

          if q != "" do
            case WSession.lookup(st.sid) do
              {:ok, pid} ->
                case WSession.cancel_queued(pid, q) do
                  {:ok, _} -> :ok
                  _ -> :ok
                end

              _ ->
                :ok
            end
          end
        end

        {:ok, st}

      {:ok, %{"type" => "clearQueue"}} ->
        case WSession.lookup(st.sid) do
          {:ok, pid} ->
            case WSession.clear_queue(pid) do
              {:ok, _} -> :ok
              _ -> :ok
            end

          _ ->
            :ok
        end

        {:ok, st}

      _ ->
        {:ok, st}
    end
  end

  def handle_in(_, st), do: {:ok, st}

  @impl true
  def handle_info({:newbee_event, :terminal_event, {:terminal_event, sid, event, payload}}, %{sid: sid} = st) do
    frame = terminal_frame(event, payload)
    {:push, [{:text, frame}], st}
  end

  def handle_info({:newbee_event, :web_event, {:web_event, sid, kind, payload}}, %{sid: sid} = st) do
    frame = Jason.encode_to_iodata!(%{type: "event", sessionId: sid, kind: to_string(kind), payload: payload})
    {:push, [{:text, frame}], st}
  end

  def handle_info(
        {:newbee_event, :collab_event, %{"session_ids" => session_ids} = event},
        %{sid: sid} = st
      )
      when is_list(session_ids) do
    if sid in session_ids do
      frame =
        Jason.encode_to_iodata!(%{
          type: "group_event",
          groupId: event["group_id"],
          eventId: event["event_id"],
          topic: event["topic"],
          payload: json_safe(event["payload"])
        })

      {:push, [{:text, frame}], st}
    else
      {:ok, st}
    end
  end

  # 系统级进化事件下行（与具体 session 无关；前端进化面板消费）
  @evo_topics ~w(evolution_published evolution_rejected release_observation
                  change_requested change_building change_evaluated change_canary
                  change_approved change_activated change_rejected change_rolled_back change_brief_ready
                  revision_advanced revision_degraded revision_healthy
                  snapshot_created snapshot_restored
                  generation_switched generation_switch_failed)a

  def handle_info({:newbee_event, topic, payload}, st) when topic in @evo_topics do
    frame =
      Jason.encode_to_iodata!(%{
        type: "system",
        topic: to_string(topic),
        payload: json_safe(payload)
      })

    {:push, [{:text, frame}], st}
  end

  # 其它会话的事件、以及总线上其它事件，直接忽略
  def handle_info({:newbee_event, _, _}, st), do: {:ok, st}
  def handle_info(_, st), do: {:ok, st}

  @impl true
  def terminate(_reason, st) do
    # 终端是 session 级资源，不归 WebSocket 管。WS 断开（切会话/刷新/网络抖动）
    # 只退订总线，PTY 保留——重连时重新 open/订阅即可恢复，历史不丢。
    # 真正的终端清理由 WSession 终止或显式 terminal_close 负责。
    Newbee.Bus.unsubscribe()
    {:ok, st}
  end
  defp terminal_open(st) do
    cwd = Newbee.Session.cwd(st.sid) || File.cwd!()

    case Newbee.Web.Terminal.open(st.sid, cwd) do
      {:ok, payload} -> terminal_ready(st, payload)
      {:error, reason} -> terminal_error(st, "无法启动终端: " <> inspect(reason))
    end
  end

  defp terminal_ready(st, payload) when is_map(payload) do
    {scrollback, ready} = Map.pop(payload, :scrollback)

    frames =
      case scrollback do
        # 重连/重开：先把滚动历史作为一帧 output 回放，再发 ready，
        # 让人能看到断开期间 AI 在终端里干了啥。
        data when is_binary(data) and data != "" ->
          [{:text, terminal_frame("output", %{data: data, replay: true})}, {:text, terminal_frame("ready", ready)}]

        _ ->
          [{:text, terminal_frame("ready", ready)}]
      end

    {:push, frames, st}
  end
  defp terminal_input(st, data) when byte_size(data) > @max_terminal_input_bytes do
    terminal_error(st, "单次输入不能超过 #{@max_terminal_input_bytes} 字节")
  end

  defp terminal_input(st, data) do
    case Newbee.Web.Terminal.input(st.sid, data) do
      :ok -> {:ok, st}
      {:error, reason} -> terminal_error(st, "写入终端失败: " <> inspect(reason))
    end
  end

  defp terminal_resize(st, cols, rows) do
    case Newbee.Web.Terminal.resize(st.sid, cols, rows) do
      {:ok, _state} -> {:ok, st}
      {:error, reason} -> terminal_error(st, "调整终端大小失败: " <> inspect(reason))
    end
  end

  defp terminal_interrupt(st) do
    case Newbee.Web.Terminal.interrupt(st.sid) do
      :ok -> {:ok, st}
      {:error, reason} -> terminal_error(st, "中断终端失败: " <> inspect(reason))
    end
  end

  # 终端唤醒：AI 一轮结束后人在终端里继续操作，点工具栏「让 AI 跟进」即走这里。
  # take_context 先收割未落袋的手动输入，再复用 prompt 路径：空闲直达 do_submit 起新一轮，
  # 正忙或 boot 中则排队，不丢不插队。
  defp terminal_wake(st) do
    content =
      case Newbee.Web.Terminal.take_context(st.sid) do
        {:ok, text} when is_binary(text) -> text
        _ -> ""
      end

    cast_session(st.sid, &WSession.prompt(&1, wake_prompt(content)))
    {:ok, st}
  end

  defp wake_prompt(content) do
    context =
      if String.trim(content) == "",
        do: "（终端暂无新的手动操作记录，请结合对话中已有的[手动终端上下文]判断）",
        else: content

    context <>
      "\n\n用户在终端工具栏点了「让 AI 跟进」。请结合以上终端上下文继续；" <>
      "若没有相关上下文，请简要说明需要用户先在终端里操作或直接描述需求，不要编造执行结果。"
  end

  defp close_terminal(st) do
    _ = Newbee.Web.Terminal.close(st.sid)
    Map.put(st, :terminal, nil)
  end

  defp terminal_error(st, message) do
    {:push, [{:text, terminal_frame("error", %{message: message})}], st}
  end

  defp terminal_frame(event, payload) do
    Jason.encode_to_iodata!(Map.merge(%{type: "terminal", event: event}, payload))
  end

  defp json_safe(%{__struct__: _} = v), do: v |> Map.from_struct() |> json_safe()
  defp json_safe(%{} = v), do: Map.new(v, fn {k, val} -> {to_string(k), json_safe(val)} end)
  defp json_safe(v) when is_list(v), do: Enum.map(v, &json_safe/1)
  defp json_safe(v) when is_tuple(v), do: v |> Tuple.to_list() |> json_safe()
  defp json_safe(v) when is_atom(v), do: to_string(v)
  defp json_safe(v) when is_binary(v) or is_number(v) or is_boolean(v) or is_nil(v), do: v
  defp json_safe(v), do: inspect(v)

  defp cast_session(sid, fun) do
    case WSession.ensure(sid) do
      {:ok, pid, _} -> fun.(pid)
      _ -> :ok
    end
  end
end
