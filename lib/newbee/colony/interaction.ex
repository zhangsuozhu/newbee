defmodule Newbee.Colony.Interaction do
  @moduledoc "Single conversation entry; work cards retain the context for every continuation."
  alias Newbee.Colony.{Store, Work, Control, Engine, Task}

  def say(cid, text, opts \\ []) do
    actor = Keyword.get(opts, :actor_bee_id)
    context = Keyword.get(opts, :context) || %{}

    with {:ok, member} <- Work.member(cid, actor) do
      {names, core} = Engine.parse_mentions(text)
      members = Store.bees_for_colony(cid)
      targets = Enum.filter(members, &(&1["display"] in names or &1["id"] in names))
      all = Enum.any?(names, &(&1 in ["all", "所有人", "全体"]))
      targets = if all, do: Enum.filter(members, &(&1["kind"] == "ai")), else: targets

      targets =
        if targets == [],
          do:
            Enum.filter(
              members,
              &(String.contains?(core, "让 " <> &1["display"]) or
                  String.contains?(core, "让" <> &1["display"]))
            ),
          else: targets

      targets =
        if context["beeId"],
          do: Enum.filter(members, &(&1["id"] == context["beeId"])),
          else: targets

      tid = context["taskId"]

      attachments =
        Enum.flat_map(Keyword.get(opts, :upload_ids, []), fn id ->
          case Newbee.Upload.info(Keyword.get(opts, :upload_sid) || member["session_id"], id) do
            {:ok, item} -> [Map.drop(item, ["path"])]
            _ -> []
          end
        end)

      trace(cid, actor, text, tid, %{"mentions" => names, "attachments" => attachments})

      cond do
        core in ["你会做什么", "能做什么", "帮助"] ->
          response("可以帮你完成研发工作、提出方案、查看真实进度、邀请协作和验收成果。直接说需求，或使用输入框上方的功能入口。", [])

        core in ["看看成果", "看成果"] ->
          response(
            "成果与验证证据显示在工作卡及待验收栏。",
            Store.tasks_for_colony(cid)
            |> Enum.filter(&(&1["status"] in ["done", "pending_review"]))
          )

        Regex.match?(~r/^(暂停|停一下|先停|全部暂停|全员暂停)/u, core) ->
          control(cid, actor, targets, tid, "pause")

        Regex.match?(~r/^(立即中止|立即停止|杀掉|终止执行)/u, core) ->
          control(cid, actor, targets, tid, "interrupt")

        Regex.match?(~r/^(恢复执行|恢复全部|恢复AI|恢复 AI)/u, core) ->
          control(cid, actor, targets, tid, "resume")

        Regex.match?(~r/^(进度|进展|怎么样了|现在在做什么|做到哪)/u, core) ->
          progress(cid, targets, tid)

        Control.blocked?(
          cid,
          if(List.first(targets), do: List.first(targets)["id"], else: actor),
          tid
        ) ->
          queue_paused(cid, actor, targets, tid, core, opts)

        is_binary(tid) ->
          case continue_or_discuss(cid, tid, core, actor, targets) do
            {:ok, task} -> response("已补充到当前工作，执行器会使用最新上下文继续。", [task])
            error -> error
          end

        Regex.match?(~r/^(继续|同意|按这个做|开始吧|开工)/u, core) ->
          continue_latest(cid, actor, targets, core)

        names != [] and targets == [] ->
          response("没有找到被点名的成员，请从 @ 列表选择。", [])

        all and Regex.match?(~r/(讨论|方案|评估|建议)/u, core) ->
          proposals(cid, actor, Enum.take(targets, 3), core, opts)

        length(targets) > 1 ->
          proposals(cid, actor, Enum.take(targets, 3), core, opts)

        true ->
          owner = List.first(targets)

          proposal =
            Regex.match?(~r/(讨论|方案|评估|建议|怎么做|梳理)/u, core) and
              not Regex.match?(~r/(直接实现|立即执行|开始实施)/u, core)

          attrs = %{
            "title" => String.slice(core, 0, 100),
            "description" => core,
            "assigned_bee_id" => if(owner, do: owner["id"]),
            "mode" => if(proposal, do: "proposal", else: "execution"),
            "workflow" => true,
            "actor_bee_id" => actor,
            "request_id" => Keyword.get(opts, :request_id),
            "upload_ids" => Keyword.get(opts, :upload_ids, []),
            "upload_sid" => Keyword.get(opts, :upload_sid) || member["session_id"]
          }

          case Work.create(cid, attrs) do
            {:ok, task} ->
              response(
                if(task["owner_kind"] == "human",
                  do: "已交给真人成员，等待对方接手。",
                  else: if(proposal, do: "负责人先判断范围，再邀请伙伴提案讨论，由你选择执行或分工。", else: "负责人先判断投入：简单任务自己完成，需要比较方案时邀请伙伴讨论。")
                ),
                [task],
                %{"owner" => task["assigned_bee_id"]}
              )

            error ->
              error
          end
      end
      |> record_reply(cid)
    end
  end

  defp queue_paused(cid, actor, targets, tid, text, opts) do
    tasks = Store.tasks_for_colony(cid) |> Enum.reject(&Task.terminal?/1)

    current =
      if tid,
        do: Enum.find(tasks, &(&1["id"] == tid)),
        else: if(length(tasks) == 1, do: hd(tasks))

    if current do
      with {:ok, task} <-
             Work.revise(
               cid,
               current["id"],
               %{"constraints" => (current["constraints"] || []) ++ [text]},
               actor
             ) do
        response("已记录新要求。工作保持暂停，恢复前会应用最新约束。", [task])
      end
    else
      key = Enum.join([cid, actor, tid || "group"], ":")

      Store.transaction(fn data ->
        previous = get_in(data, ["pending_messages", key])

        entry = %{
          "id" => key,
          "colony_id" => cid,
          "actor_bee_id" => actor,
          "targets" => Enum.map(targets, & &1["id"]),
          "text" => if(previous, do: previous["text"] <> "\n补充要求：" <> text, else: text),
          "status" => "waiting",
          "request_id" => if(previous, do: previous["request_id"], else: Newbee.Colony.Id.new(:message)),
          "upload_ids" =>
            Enum.uniq(
              if(previous, do: previous["upload_ids"], else: []) ++
                Keyword.get(opts, :upload_ids, [])
            ),
          "upload_sid" => Keyword.get(opts, :upload_sid)
        }

        {:ok, :ok, put_in(data, ["pending_messages", key], entry)}
      end)

      response("消息已保存，真人可以继续交流；恢复后才会创建并派发 AI 工作。", [])
    end
  end

  def resume_pending(entry) do
    targets =
      Enum.map(entry["targets"], fn id ->
        case Store.get_bee(id) do
          {:ok, b} -> "@" <> b["display"] <> " "
          _ -> ""
        end
      end)
      |> Enum.join()

    result =
      say(entry["colony_id"], targets <> entry["text"],
        actor_bee_id: entry["actor_bee_id"],
        upload_ids: entry["upload_ids"],
        upload_sid: entry["upload_sid"],
        request_id: entry["request_id"]
      )

    case result do
      {:ok, _} ->
        Store.delete("pending_messages", entry["id"])

      error ->
        Store.update(
          "pending_messages",
          entry["id"],
          nil,
          &{:ok, Map.merge(&1, %{"status" => "blocked", "error" => inspect(error)})}
        )
    end
  end

  defp control(cid, actor, targets, tid, action) do
    scopes =
      cond do
        is_binary(tid) -> [{"work", tid}]
        targets != [] -> Enum.map(targets, &{"bee", &1["id"]})
        true -> [{"colony", cid}]
      end

    results =
      Enum.map(scopes, fn {scope, id} ->
        Control.set(cid, scope, id, action, actor_bee_id: actor)
      end)

    case Enum.find(results, &match?({:error, _, _}, &1)) do
      nil ->
        response(
          if(action == "resume",
            do: "已恢复所选范围；独立暂停的成员和工作仍保持暂停。",
            else: "已记录停止要求，等待执行器确认。已发生的外部操作不会自动撤回。"
          ),
          []
        )

      error ->
        error
    end
  end

  defp progress(cid, targets, tid) do
    ids = Enum.map(targets, & &1["id"])

    tasks =
      Store.tasks_for_colony(cid)
      |> Enum.filter(fn t ->
        (tid == nil or t["id"] == tid) and (ids == [] or t["assigned_bee_id"] in ids) and
          not Task.terminal?(t)
      end)

    response(if(tasks == [], do: "目前没有进行中的工作。", else: "以下是工作记录中的真实进度状态；点击工作查看执行会话和证据。"), tasks)
  end

  defp continue_latest(cid, actor, targets, text) do
    ids = Enum.map(targets, & &1["id"])

    tasks =
      Store.tasks_for_colony(cid)
      |> Enum.filter(
        &(&1["status"] in ["blocked", "pending_review"] and
            (ids == [] or &1["assigned_bee_id"] in ids))
      )

    case tasks do
      [task] ->
        case Work.continue(cid, task["id"], text, actor) do
          {:ok, task} -> response("已继续这项工作。", [task])
          error -> error
        end

      [] ->
        response("没有需要继续的工作；如果工作已暂停，请在工作卡中恢复。", [])

      _ ->
        response("有多项工作等待决定，请点击要继续的工作。", tasks)
    end
  end

  defp proposals(cid, actor, members, text, opts) do
    case Work.create(cid, %{
           "title" => String.slice(text, 0, 100),
           "description" => text,
           "assigned_bee_id" => if(List.first(members), do: List.first(members)["id"]),
           "workflow" => true,
           "mode" => "proposal",
           "proposal_bee_ids" => Enum.map(members, & &1["id"]),
           "actor_bee_id" => actor,
           "request_id" => Keyword.get(opts, :request_id),
           "upload_ids" => Keyword.get(opts, :upload_ids, []),
           "upload_sid" => Keyword.get(opts, :upload_sid)
         }) do
      {:ok, task} -> response("已建立共同任务。负责人先分析，再邀请最多三只 Bee 提案互评，方案齐后由你决定。", [task])
      error -> error
    end
  end

  defp continue_or_discuss(cid, tid, text, actor, targets) do
    with {:ok, task} <- Store.get_task(tid) do
      if is_map(task["workflow"]) and task["workflow"]["phase"] in ["triage", "proposing", "discussing", "choosing"] do
        candidates = Enum.map(task["workflow"]["proposals"], & &1["bee_id"])
        chosen = Enum.filter(targets, &(&1["id"] in candidates))

        cond do
          task["workflow"]["phase"] == "choosing" and length(chosen) == 1 and
              Regex.match?(~r/(执行|实施|来做|去做|去干|来干|开工)/u, text) ->
            Newbee.Colony.Workflow.act(
              cid,
              tid,
              "execute",
              %{"revision" => task["revision"], "text" => text, "assignments" => [%{"bee_id" => hd(chosen)["id"]}]},
              actor
            )

          task["workflow"]["phase"] == "choosing" and Regex.match?(~r/^(再讨论|再互评)/u, text) ->
            Newbee.Colony.Workflow.act(cid, tid, "discuss", %{"revision" => task["revision"]}, actor)

          true ->
            Newbee.Colony.Workflow.act(cid, tid, "comment", %{"revision" => task["revision"], "text" => text}, actor)
        end
      else
        Work.continue(cid, tid, text, actor)
      end
    end
  end

  defp response(reply, tasks, extra \\ %{}),
    do:
      {:ok,
       Map.merge(
         %{
           "reply" => reply,
           "tasks" => tasks,
           "actions" => Enum.map(tasks, &%{"type" => "task_created", "task_id" => &1["id"]})
         },
         extra
       )}

  defp record_reply({:ok, result} = ok, cid) do
    trace(cid, nil, result["reply"], nil, %{})

    Enum.each(result["tasks"] || [], fn task ->
      Store.append_trace(%{
        "colony_id" => cid,
        "task_id" => task["id"],
        "type" => "task",
        "channel" => "colony",
        "text" => task["title"],
        "data" => %{"task_id" => task["id"]}
      })
    end)

    ok
  end

  defp record_reply(error, _), do: error

  defp trace(cid, actor, text, tid, data),
    do:
      Store.append_trace(%{
        "colony_id" => cid,
        "bee_id" => actor,
        "task_id" => tid,
        "type" => if(actor, do: "message", else: "system"),
        "channel" => "colony",
        "text" => text,
        "data" => data,
        "created_at" => System.system_time(:millisecond)
      })
end
