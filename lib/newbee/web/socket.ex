defmodule Newbee.Web.Socket do
  @moduledoc """
  WebUI 事件下行通道（移植 dsh websocket-downlink 语义）：浏览器连
  `GET /ws?session=<sid>`，本进程订阅 Bus，把该会话的 Loop 事件以 JSON
  帧推下去；同时接收上行控制帧（interrupt / permission_reply）。

  下行帧： {"type": "event", "sessionId": sid, "kind": "text", "payload": {...}}
  上行帧： {"type": "interrupt"} | {"type": "permission", "ok": true} |
           {"type": "prompt", "text": "..."}（等价 POST session.prompt，省一跳）
  """
  @behaviour WebSock

  alias Newbee.Web.Session, as: WSession

  @impl true
  def init(%{assigns: %{session: sid}}) do
    Newbee.Bus.subscribe()
    {:ok, _pid, _sid} = WSession.ensure(sid)
    {:ok, %{sid: sid}}
  end

  @impl true
  def handle_in({text, [opcode: :text]}, st) do
    case Jason.decode(text) do
      {:ok, %{"type" => "interrupt"}} ->
        cast_session(st.sid, &WSession.interrupt/1)

      {:ok, %{"type" => "permission", "ok" => ok} = frame} ->
        target = frame["sessionId"] || st.sid

        if Newbee.Collaboration.Coordinator.can_approve_permission?(st.sid, target) do
          cast_session(target, &WSession.permission_reply(&1, ok))
        end

      {:ok, %{"type" => "prompt", "text" => t}} ->
        cast_session(st.sid, &WSession.prompt(&1, t))

      {:ok, %{"type" => "promptImage", "images" => images, "text" => t}} ->
        cast_session(st.sid, &WSession.prompt_images(&1, images || [], t || ""))

      _ ->
        :ok
    end

    {:ok, st}
  end

  def handle_in(_, st), do: {:ok, st}

  @impl true
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
                  change_approved change_activated change_rejected change_rolled_back
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
    Newbee.Bus.unsubscribe()
    {:ok, st}
  end

  # JSON 安全化（atom key / tuple / struct 都能编）
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
