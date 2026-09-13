defmodule Newbee.Colony.Runtime do
  @moduledoc "Supervised durable outbox dispatcher and real execution event projection."
  use GenServer
  alias Newbee.Colony.{Store, Control, Work, Task, Workflow}
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  @impl true
  def init(_) do
    Newbee.Bus.subscribe()
    Process.send_after(self(), :tick, 1_000)
    {:ok, %{}}
  end

  @impl true
  def handle_info(:tick, state) do
    if Application.get_env(:newbee, :colony_background, true), do: sweep()
    Process.send_after(self(), :tick, 1_000)
    {:noreply, state}
  end

  def handle_info({:newbee_event, :web_event, {:web_event, sid, kind, payload}}, state) do
    project(sid, kind, payload)
    {:noreply, state}
  end

  def handle_info(_, state), do: {:noreply, state}

  def sweep do
    Newbee.Colony.Workflow.advance()

    Store.all("pending_messages")
    |> Enum.filter(&(&1["status"] == "waiting"))
    |> Enum.each(fn entry ->
      if not Control.blocked?(entry["colony_id"], entry["actor_bee_id"]) and
           not Enum.any?(entry["targets"], &Control.blocked?(entry["colony_id"], &1)) do
        Newbee.Colony.Interaction.resume_pending(entry)
      end
    end)

    Store.list_tasks() |> Enum.filter(& &1["resume_needed"]) |> Enum.each(&resume_work/1)

    Store.all("deliveries")
    |> Enum.filter(&(&1["status"] in ["pending", "dispatching", "accepted"]))
    |> Enum.sort_by(& &1["created_at"])
    |> Enum.each(&dispatch/1)
  end

  defp resume_work(task) do
    if not Control.blocked?(task["colony_id"], task["assigned_bee_id"], task["id"]) do
      Store.transaction(fn data ->
        current = get_in(data, ["tasks", task["id"]])

        if current["resume_needed"] and current["status"] == "running" and
             not Task.terminal?(current) do
          current = Map.put(current, "resume_needed", false)

          queued =
            Enum.any?(
              Map.values(data["deliveries"]),
              &(&1["task_id"] == current["id"] and &1["status"] == "pending" and
                  &1["context_revision"] == current["context_revision"])
            )

          delivery =
            Work.new_delivery(current, %{
              "instruction" => "从已保存进度继续。先核对最新约束、代码状态与已发生的外部操作；不要直接重放上次工具调用。"
            })

          next = put_in(data, ["tasks", current["id"]], current)
          next = if queued, do: next, else: put_in(next, ["deliveries", delivery["id"]], delivery)
          {:ok, :ok, next}
        else
          {:ok, :ok, data}
        end
      end)
    end
  end

  defp dispatch(delivery) do
    with {:ok, task} <- Store.get_task(delivery["task_id"]),
         false <- Task.terminal?(task),
         false <- task["approval_required"] == true,
         false <- Control.blocked?(task["colony_id"], task["assigned_bee_id"], task["id"]) do
      if delivery["status"] == "pending" and
           (delivery["context_revision"] || 0) < (task["context_revision"] || 0) do
        Store.update(
          "deliveries",
          delivery["id"],
          nil,
          &{:ok, Map.put(&1, "status", "superseded")}
        )
      else
        dispatch_current(delivery, task)
      end
    else
      _ -> :ok
    end
  catch
    :exit, _ -> mark_unknown(delivery)
  end

  defp dispatch_current(delivery, task) do
    if is_binary(delivery["session_id"]) do
      local_dispatch(delivery, task)
    else
      case Store.get_bee(task["assigned_bee_id"]) do
        {:ok, bee} ->
          if is_binary(bee["remote_member_id"]),
            do: Newbee.Colony.Remote.dispatch(delivery, task),
            else: ensure_local_session(delivery, task)

        _ ->
          block(delivery, "负责人已离开，需要重新安排")
      end
    end
  end

  defp ensure_local_session(delivery, task) do
    with {:ok, colony} <- Store.get_colony(task["colony_id"]),
         {:ok, cwd} <- Newbee.Colony.Workspace.ensure(task, colony["cwd"]),
         {:ok, _pid, sid} <- Newbee.Web.Session.ensure(task["session_id"], cwd) do
      Store.transaction(fn data ->
        current = get_in(data, ["tasks", task["id"]])
        queued = get_in(data, ["deliveries", delivery["id"]])

        if current && queued && not Task.terminal?(current) do
          next =
            data
            |> put_in(["tasks", task["id"], "session_id"], sid)
            |> put_in(["deliveries", delivery["id"], "session_id"], sid)
            |> put_in(["conversations", sid], %{
              "id" => sid,
              "colony_id" => task["colony_id"],
              "bee_id" => task["assigned_bee_id"],
              "task_id" => task["id"],
              "participants" =>
                [get_in(data, ["colonies", task["colony_id"], "queen_bee_id"]), task["assigned_bee_id"]]
                |> Enum.reject(&is_nil/1),
              "visibility" => "work"
            })
            |> update_in(["bees", task["assigned_bee_id"], "conversations"], fn ids ->
              Enum.uniq([sid | List.wrap(ids)])
            end)

          {:ok, :ok, next}
        else
          {:ok, :ok, data}
        end
      end)
    else
      error -> block(delivery, "执行会话启动失败：" <> inspect(error))
    end
  end

  defp local_dispatch(delivery, task) do
    case Newbee.Web.Session.lookup(delivery["session_id"]) do
      {:ok, pid} ->
        cond do
          delivery["status"] == "accepted" ->
            if not GenServer.call(pid, {:colony_received, delivery["id"]}, 1_000),
              do: mark_unknown(delivery)

          delivery["status"] == "dispatching" ->
            if GenServer.call(pid, {:colony_received, delivery["id"]}, 1_000),
              do: :ok,
              else: mark_unknown(delivery)

          GenServer.call(pid, :peek_busy, 1_000) ->
            :ok

          true ->
            send_local(pid, delivery, task)
        end

      _ ->
        if delivery["status"] == "pending" do
          case Newbee.Web.Session.ensure(delivery["session_id"], nil) do
            {:ok, _, _} -> :ok
            _ -> mark_unknown(delivery)
          end
        else
          mark_unknown(delivery)
        end
    end
  end

  defp send_local(pid, delivery, task) do
    with {:ok, prepared} <- prepare(delivery, task),
         {:ok, _} <-
           Store.update(
             "deliveries",
             delivery["id"],
             delivery["revision"],
             &{:ok,
              Map.merge(&1, %{
                "status" => "dispatching",
                "context_revision" => task["context_revision"] || 0
              })}
           ) do
      case GenServer.call(
             pid,
             {:colony_deliver, delivery["id"], prepared.text, prepared.images},
             5_000
           ) do
        :ok ->
          Store.update("tasks", task["id"], nil, fn current ->
            if Task.terminal?(current),
              do: {:ok, current},
              else: {:ok, Map.put(current, "status", "running")}
          end)

        {:error, reason} when reason in [:paused, :queue_full] ->
          Store.update(
            "deliveries",
            delivery["id"],
            nil,
            &{:ok, Map.put(&1, "status", "pending")}
          )

        _ ->
          mark_unknown(delivery)
      end
    else
      {:error, reason} -> block(delivery, "附件或投递失败：" <> inspect(reason))
      _ -> :ok
    end
  end

  defp prepare(delivery, task) do
    text = Work.context(task, delivery["instruction"])

    if delivery["upload_ids"] == [] do
      {:ok, %{text: text, images: []}}
    else
      Newbee.Upload.prepare_prompt(delivery["upload_sid"], delivery["upload_ids"], text)
    end
  end

  defp mark_unknown(delivery), do: block(delivery, "执行回执丢失，不能确定外部操作是否完成；请检查会话后继续，系统不会自动重放。")

  defp block(delivery, reason) do
    Store.update(
      "deliveries",
      delivery["id"],
      nil,
      &{:ok, Map.merge(&1, %{"status" => "unknown", "error" => reason})}
    )

    Store.update("tasks", delivery["task_id"], nil, fn task ->
      if Task.terminal?(task),
        do: {:ok, task},
        else: {:ok, Map.merge(task, %{"status" => "blocked", "next_step" => reason})}
    end)
  end

  def project(sid, kind, payload) do
    case Control.binding(sid) do
      %{"task_id" => tid} = binding when is_binary(tid) ->
        case Store.get_task(tid) do
          {:ok, task} ->
            Newbee.Colony.Remote.report(task, kind, payload)
            project_work(binding, task, kind, payload)

          _ ->
            :ok
        end

      _ ->
        :ok
    end
  end

  def project_remote(task, kind, payload),
    do:
      project_work(
        %{"bee_id" => task["assigned_bee_id"], "task_id" => task["id"]},
        task,
        kind,
        payload
      )

  defp project_work(binding, task, kind, payload) do
    activity = activity(kind, payload)

    if activity do
      Store.update(
        "tasks",
        task["id"],
        nil,
        &{:ok, Map.merge(&1, %{"activity" => activity, "activity_at" => now()})}
      )

      Store.append_trace(%{
        "colony_id" => task["colony_id"],
        "task_id" => task["id"],
        "bee_id" => binding["bee_id"],
        "type" => "tool_call",
        "channel" => "work",
        "text" => activity,
        "data" => safe_payload(payload),
        "created_at" => now()
      })
    end

    cond do
      Task.terminal?(task) or task["status"] == "pending_review" ->
        :ok

      kind in [:done, :text_end] and Newbee.Colony.Workflow.managed?(task) and not active_delivery?(task) ->
        :ok

      kind in [:done, :text_end] and Newbee.Colony.Workflow.planning?(task) ->
        summary = value(payload, :summary) || value(payload, :body) || ""
        Newbee.Colony.Workflow.complete(task, summary, value(payload, :work_revision) || task["context_revision"])

      kind in [:done, :text_end] ->
        delivered =
          Store.all("deliveries")
          |> Enum.filter(&(&1["task_id"] == task["id"] and &1["status"] in ["accepted", "dispatching"]))
          |> Enum.sort_by(& &1["created_at"], :desc)
          |> List.first()

        work_revision =
          value(payload, :work_revision) ||
            if(delivered, do: delivered["context_revision"], else: task["context_revision"])

        settle_deliveries(task, "completed")
        summary = value(payload, :summary) || value(payload, :body) || "执行已结束，请查看会话。"

        evidence =
          Store.trace_for_colony(task["colony_id"],
            task_id: task["id"],
            channel: "work",
            limit: 100
          )
          |> Enum.map(&Map.take(&1, ~w(id seq text created_at)))

        case Work.submit(
               task["colony_id"],
               task["id"],
               %{
                 "content" => summary,
                 "work_revision" => work_revision,
                 "content_ref" => task["session_id"],
                 "evidence" => evidence
               },
               binding["bee_id"]
             ) do
          {:ok, honey} ->
            unless task["integration_required"], do: trace(task, "honey", summary, %{"honey_id" => honey["id"]})
            Newbee.Colony.Workflow.advance()

          _ ->
            :ok
        end

      kind == :ask ->
        settle_deliveries(task, "completed")
        question = value(payload, :question) || "需要你决定"

        Store.update(
          "tasks",
          task["id"],
          nil,
          &{:ok,
           Map.merge(&1, %{
             "status" => "blocked",
             "waiting_for" => "user",
             "next_step" => question,
             "question" => safe_payload(payload)
           })}
        )

        trace(task, "decision", question, safe_payload(payload))

      kind == :interrupted ->
        settle_deliveries(task, "paused")
        paused = Control.blocked?(task["colony_id"], task["assigned_bee_id"], task["id"])

        attrs =
          if paused do
            %{"resume_needed" => true}
          else
            %{
              "status" => "blocked",
              "waiting_for" => "user",
              "resume_needed" => false,
              "next_step" => interruption_next_step(task)
            }
          end

        Store.update("tasks", task["id"], nil, &{:ok, Map.merge(&1, attrs)})

      kind == :error ->
        settle_deliveries(task, "failed")
        message = value(payload, :message) || "执行错误"

        Store.update(
          "tasks",
          task["id"],
          nil,
          &{:ok, Map.merge(&1, %{"status" => "blocked", "next_step" => message})}
        )

        trace(task, "task", message, %{})

      true ->
        :ok
    end
  end

  defp active_delivery?(task) do
    Enum.any?(
      Store.all("deliveries"),
      &(&1["task_id"] == task["id"] and &1["status"] in ["accepted", "dispatching"] and
          &1["context_revision"] == task["context_revision"])
    )
  end

  defp settle_deliveries(task, status) do
    Store.all("deliveries")
    |> Enum.filter(&(&1["task_id"] == task["id"] and &1["status"] in ["accepted", "dispatching"]))
    |> Enum.each(fn d ->
      Store.update("deliveries", d["id"], nil, &{:ok, Map.put(&1, "status", status)})
    end)
  end

  defp trace(task, type, text, data),
    do:
      Store.append_trace(%{
        "colony_id" => task["colony_id"],
        "task_id" => task["id"],
        "bee_id" => task["assigned_bee_id"],
        "type" => type,
        "text" => text,
        "channel" => "colony",
        "data" => data,
        "created_at" => now()
      })

  defp activity(:tool_start, p), do: value(p, :title) || value(p, :name) || "执行工具"
  defp activity(:tool_result, _), do: nil
  defp activity(:tool_error, _), do: "工具执行出错"
  defp activity(:permission_ask, _), do: "等待操作授权"
  defp activity(:file_diff, p), do: "修改文件：" <> to_string(value(p, :path) || "")
  defp activity(_, _), do: nil

  defp interruption_next_step(task) do
    if Workflow.planning?(task),
      do: "方案阶段会话意外中断，已暂停当前工作。请核对已发生的外部操作后，返回任务卡继续方案讨论；不会自动重放未知操作。",
      else: "执行会话意外中断，已暂停当前工作。请核对已发生的外部操作后，点击“答复并继续”恢复；不会自动重放未知操作。"
  end

  defp value(p, key), do: Map.get(p, key) || Map.get(p, Atom.to_string(key))
  defp safe_payload(p), do: p |> Jason.encode!() |> Jason.decode!()
  defp now, do: System.system_time(:millisecond)
end
