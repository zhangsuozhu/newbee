defmodule Newbee.Web.ColonyApi do
  @moduledoc """
  蜂群协作 RPC（`colony.*`）。

  由 `Newbee.Web.Api` 的 `dispatch_rpc("colony." <> _, payload)` 转发进来，
  保持 api.ex 不再膨胀（前端模块化对应后端模块化）。

  wire 键统一 camelCase（与现有 WebUI 一致），内部转 snake 调用 Engine。
  """

  alias Newbee.Colony.Engine

  @methods ~w(colony.list colony.bootstrap colony.create colony.rename colony.dissolve colony.view colony.drill colony.bee.trail colony.bee.add colony.bee.conversation.new colony.bee.conversation.select colony.bee.conversation.rename colony.bee.conversation.delete colony.bee.remove colony.bee.leave colony.task.create colony.task.claim colony.task.transition colony.task.decompose colony.honey.add colony.honey.review colony.signal.emit colony.say colony.trace.list colony.capabilities colony.control colony.invite.create colony.remote.join colony.upload.session colony.work.revise colony.work.continue colony.work.submit colony.work.collaborate colony.work.flow)

  @doc "dispatch/2 返回 {:ok, value} | {:error, code, message}。"
  def dispatch("colony.invite.redeem", p),
    do: Newbee.Colony.Membership.redeem(p["code"], p["display"])

  def dispatch("colony.remote.poll", p), do: Newbee.Colony.Remote.poll(p)
  def dispatch("colony.remote.attachment", p), do: Newbee.Colony.Remote.attachment(p)
  def dispatch("colony.seed_demo", _), do: {:error, "removed", "演示数据入口已关闭"}

  def dispatch(method, p) do
    result = dispatch_authorized(method, p)

    case result do
      {:error, :not_found} -> {:error, "not_found", "对象不存在"}
      {:error, :conflict} -> {:error, "conflict", "版本已变化，请刷新"}
      {:error, reason} -> {:error, "operation_failed", inspect(reason)}
      other -> other
    end
  end

  defp dispatch_authorized(method, p) do
    with {:ok, actor, role} <- Newbee.Colony.Membership.actor(p),
         :ok <- authorize_request(method, p, actor, role) do
      cid = p["colonyId"] || (actor && actor["colony_id"])
      p = p |> Map.put("colonyId", cid) |> Map.put("actorBeeId", actor && actor["id"])

      case method do
        "colony.list" when role == :member ->
          {:ok, %{"colonies" => Enum.filter(Engine.list_colonies(), &(&1["colony"]["id"] == cid))}}

        "colony.view" ->
          with {:ok, view} <- Engine.view(cid) do
            members =
              Enum.map(view["members"], fn bee ->
                Map.merge(bee, %{
                  "control_state" => Newbee.Colony.Control.state(cid, "bee", bee["id"]),
                  "remote" => is_binary(bee["remote_member_id"])
                })
              end)

            tasks =
              Enum.map(view["tasks"], fn t ->
                Map.put(t, "control_state", Newbee.Colony.Control.state(cid, "work", t["id"]))
              end)

            {:ok,
             Map.merge(view, %{
               "members" => members,
               "tasks" => tasks,
               "actor_bee_id" => actor && actor["id"],
               "can_manage" => role == :owner,
               "control_state" => Newbee.Colony.Control.state(cid, "colony", cid)
             })}
          end

        "colony.control" ->
          Newbee.Colony.Control.set(
            cid,
            p["scope"] || "colony",
            p["targetId"] || cid,
            p["action"],
            actor_bee_id: actor["id"],
            revision: p["revision"]
          )

        "colony.invite.create" ->
          with {:ok, invitation} <- Newbee.Colony.Membership.invite(cid, actor["id"], p) do
            fingerprint =
              case Newbee.Web.Cert.fingerprint() do
                {:ok, value} -> value
                _ -> nil
              end

            {:ok, Map.merge(invitation, %{"url" => p["__origin__"], "fingerprint" => fingerprint})}
          end

        "colony.upload.session" ->
          existing =
            Newbee.Colony.Store.all("conversations")
            |> Enum.find(
              &(&1["colony_id"] == cid and &1["visibility"] == "upload" and
                  actor["id"] in (&1["participants"] || []))
            )

          if existing do
            {:ok, %{"sessionId" => existing["id"]}}
          else
            with {:ok, _, sid} <- Newbee.Web.Session.ensure(nil, nil),
                 :ok <-
                   Newbee.Colony.Store.put("conversations", %{
                     "id" => sid,
                     "colony_id" => cid,
                     "bee_id" => actor["id"],
                     "participants" => [actor["id"]],
                     "visibility" => "upload",
                     "kind" => "human"
                   }) do
              {:ok, %{"sessionId" => sid}}
            end
          end

        "colony.remote.join" ->
          Newbee.Colony.Remote.join(p)

        "colony.say" ->
          text = p["text"] || "请处理所附文件"

          if get_in(p, ["context", "beeId"]) do
            Newbee.Colony.Conversation.message(cid, p["context"]["beeId"], actor["id"], text)
          else
            with :ok <-
                   if(p["uploadSid"],
                     do:
                       Newbee.Colony.Membership.session_access(
                         p["__token__"],
                         p["uploadSid"],
                         :write
                       ),
                     else: :ok
                   ) do
              Newbee.Colony.Interaction.say(cid, text,
                actor_bee_id: actor["id"],
                context: p["context"],
                upload_ids: p["uploadIds"] || [],
                upload_sid: p["uploadSid"],
                request_id: p["requestId"]
              )
            end
          end

        "colony.task.create" ->
          attrs =
            Map.new(
              [
                "title",
                "description",
                "requires",
                "acceptance",
                "constraints",
                "facts",
                "decisions"
              ],
              &{&1, p[&1]}
            )
            |> Map.merge(%{
              "assigned_bee_id" => p["beeId"],
              "assignee_display" => p["assignee"],
              "parent_task_id" => p["parentTaskId"],
              "actor_bee_id" => actor["id"],
              "workflow" => true
            })

          with {:ok, task} <- Newbee.Colony.Work.create(cid, attrs), do: {:ok, %{"task" => task}}

        "colony.work.flow" ->
          with {:ok, task} <- Newbee.Colony.Workflow.act(cid, p["taskId"], p["action"], p, actor["id"]),
               do: {:ok, %{"task" => task}}

        "colony.work.revise" ->
          with {:ok, task} <-
                 Newbee.Colony.Work.revise(cid, p["taskId"], p["changes"] || %{}, actor["id"]),
               do: {:ok, %{"task" => task}}

        "colony.work.continue" ->
          with {:ok, task} <-
                 Newbee.Colony.Work.continue(
                   cid,
                   p["taskId"],
                   p["text"] || "按已确认要求继续",
                   actor["id"],
                   p["revision"]
                 ),
               do: {:ok, %{"task" => task}}

        "colony.work.submit" ->
          with {:ok, honey} <-
                 Newbee.Colony.Work.submit(cid, p["taskId"], p["result"] || %{}, actor["id"]),
               do: {:ok, %{"honey" => Newbee.Colony.Honey.public(honey)}}

        "colony.honey.review" ->
          with {:ok, honey} <-
                 Newbee.Colony.Work.review(
                   cid,
                   p["honeyId"],
                   p["verdict"],
                   actor["id"],
                   p["note"] || ""
                 ),
               do: {:ok, %{"honey" => Newbee.Colony.Honey.public(honey)}}

        "colony.work.collaborate" ->
          Newbee.Colony.Work.collaborate(cid, p["taskId"], p["children"] || [], actor["id"])

        method
        when method in ~w(colony.task.claim colony.task.decompose colony.honey.add colony.signal.emit) ->
          {:error, "replaced", "该旧接口已迁移到负责人工作、协作和成果验收流程"}

        "colony.bee.conversation.new" ->
          Newbee.Colony.Conversation.create(cid, p["beeId"], actor["id"])

        "colony.bee.trail" ->
          Newbee.Colony.Conversation.trail(cid, p["beeId"], actor["id"])

        "colony.bee.leave" ->
          if role == :owner or p["beeId"] == actor["id"],
            do: do_dispatch(method, p),
            else: {:error, "forbidden", "只能退出自己的成员身份"}

        "colony.seed_demo" ->
          {:error, "removed", "演示数据入口已关闭"}

        "colony.task.transition" ->
          with {:ok, task} <- Newbee.Colony.Store.get_task(p["taskId"]) do
            if task["owner_kind"] == "human" and task["assigned_bee_id"] == actor["id"] and
                 p["event"] in ["start", "block"],
               do: do_dispatch(method, Map.put(p, "beeId", actor["id"])),
               else: {:error, "forbidden", "AI 状态来自真实执行；完成请提交成果并验收"}
          end

        _ ->
          do_dispatch(method, p)
      end
    end
  end

  defp authorize_request(method, p, actor, role) do
    owner_only =
      ~w(colony.create colony.bootstrap colony.dissolve colony.rename colony.bee.add colony.bee.remove colony.control colony.invite.create colony.remote.join colony.honey.review colony.task.claim colony.task.decompose colony.honey.add colony.signal.emit)

    cond do
      method not in @methods ->
        {:error, "unknown_method", "未知蜂群方法"}

      method == "colony.say" and p["text"] in [nil, ""] and p["uploadIds"] in [nil, []] ->
        {:error, "bad_request", "请填写消息或添加附件"}

      p["colonyId"] == nil and actor == nil and
          method in ~w(colony.view colony.say colony.drill colony.control) ->
        {:error, "bad_request", "缺少参数 colonyId"}

      role != :owner and method in owner_only ->
        {:error, "forbidden", "该操作需要蜂群管理权限"}

      actor == nil and
          method not in ~w(colony.list colony.bootstrap colony.create colony.capabilities colony.remote.join) ->
        {:error, "not_found", "蜂群不存在"}

      true ->
        Enum.reduce_while(
          [{"taskId", "tasks"}, {"beeId", "bees"}, {"honeyId", "honey"}],
          :ok,
          fn {key, table}, :ok ->
            if is_binary(p[key]) do
              case Newbee.Colony.Store.get(table, p[key]) do
                {:ok, value} ->
                  if value["colony_id"] == (p["colonyId"] || (actor && actor["colony_id"])) do
                    {:cont, :ok}
                  else
                    {:halt, {:error, "forbidden", "对象不属于当前蜂群"}}
                  end

                _ ->
                  {:halt, {:error, "not_found", "对象不存在"}}
              end
            else
              {:cont, :ok}
            end
          end
        )
    end
  end

  defp do_dispatch(method, payload) do
    case method do
      "colony.list" ->
        {:ok, %{"colonies" => Engine.list_colonies()}}

      "colony.bootstrap" ->
        with {:ok, colony} <- Engine.bootstrap() do
          {:ok, %{"colony" => colony}}
        end

      "colony.create" ->
        attrs = %{
          "name" => g(payload, "name"),
          "goal" => g(payload, "goal") || "",
          "queen" => g(payload, "queen")
        }

        with {:ok, colony} <- Engine.create_colony(attrs) do
          {:ok, %{"colony" => colony}}
        end

      "colony.dissolve" ->
        with {:ok, cid} <- need(payload, "colonyId"),
             {:ok, result} <- Engine.dissolve(cid, actor_bee_id: g(payload, "actorBeeId")) do
          {:ok, result}
        end

      "colony.view" ->
        with {:ok, cid} <- need(payload, "colonyId"),
             {:ok, view} <- Engine.view(cid) do
          {:ok, view}
        end

      "colony.drill" ->
        with {:ok, cid} <- need(payload, "colonyId"),
             {:ok, tid} <- need(payload, "taskId"),
             {:ok, drill} <- Engine.drill(cid, tid) do
          {:ok, drill}
        end

      "colony.bee.trail" ->
        with {:ok, cid} <- need(payload, "colonyId"),
             {:ok, bid} <- need(payload, "beeId"),
             {:ok, trail} <- Engine.bee_trail(cid, bid) do
          {:ok, trail}
        end

      "colony.bee.add" ->
        with {:ok, cid} <- need(payload, "colonyId"),
             {:ok, bee} <-
               Engine.add_bee(cid, %{
                 "display" => g(payload, "display"),
                 "kind" => g(payload, "kind"),
                 "capabilities" => g(payload, "capabilities"),
                 "session_id" => g(payload, "sessionId"),
                 "bind_session" => g(payload, "bindSession") == true
               }) do
          {:ok, %{"bee" => bee}}
        end

      "colony.bee.conversation.new" ->
        with {:ok, cid} <- need(payload, "colonyId"),
             {:ok, bid} <- need(payload, "beeId"),
             {:ok, res} <- Engine.new_conversation(cid, bid, cwd: g(payload, "cwd")) do
          {:ok, res}
        end

      "colony.bee.conversation.select" ->
        with {:ok, cid} <- need(payload, "colonyId"),
             {:ok, bid} <- need(payload, "beeId"),
             {:ok, sid} <- need(payload, "sessionId"),
             {:ok, res} <- Engine.select_conversation(cid, bid, sid) do
          {:ok, res}
        end

      "colony.bee.conversation.rename" ->
        with {:ok, cid} <- need(payload, "colonyId"),
             {:ok, bid} <- need(payload, "beeId"),
             {:ok, sid} <- need(payload, "sessionId"),
             {:ok, res} <- Engine.rename_conversation(cid, bid, sid, g(payload, "title")) do
          {:ok, res}
        end

      "colony.bee.conversation.delete" ->
        with {:ok, cid} <- need(payload, "colonyId"),
             {:ok, bid} <- need(payload, "beeId"),
             {:ok, sid} <- need(payload, "sessionId"),
             {:ok, res} <- Engine.delete_conversation(cid, bid, sid) do
          {:ok, res}
        end

      "colony.bee.remove" ->
        with {:ok, cid} <- need(payload, "colonyId"),
             {:ok, bid} <- need(payload, "beeId"),
             {:ok, bee} <- Engine.remove_bee(cid, bid, actor_bee_id: g(payload, "actorBeeId")) do
          {:ok, %{"bee" => bee}}
        end

      "colony.bee.leave" ->
        with {:ok, cid} <- need(payload, "colonyId"),
             {:ok, bid} <- need(payload, "beeId"),
             {:ok, result} <- Engine.leave(cid, bid, handover_to: g(payload, "handoverTo")) do
          {:ok, result}
        end

      "colony.task.create" ->
        with {:ok, cid} <- need(payload, "colonyId"),
             {:ok, task} <-
               Engine.create_task(cid, %{
                 "title" => g(payload, "title"),
                 "description" => g(payload, "description"),
                 "requires" => g(payload, "requires"),
                 "assignee_display" => g(payload, "assignee"),
                 "parent_task_id" => g(payload, "parentTaskId"),
                 "priority" => g(payload, "priority"),
                 "actor_bee_id" => g(payload, "actorBeeId")
               }) do
          {:ok, %{"task" => task}}
        end

      "colony.task.claim" ->
        with {:ok, cid} <- need(payload, "colonyId"),
             {:ok, tid} <- need(payload, "taskId"),
             {:ok, bid} <- need(payload, "beeId"),
             {:ok, task} <- Engine.claim_task(cid, tid, bid) do
          {:ok, %{"task" => task}}
        end

      "colony.task.transition" ->
        with {:ok, cid} <- need(payload, "colonyId"),
             {:ok, tid} <- need(payload, "taskId"),
             {:ok, event} <- need(payload, "event"),
             {:ok, task} <-
               Engine.transition_task(cid, tid, event,
                 bee_id: g(payload, "beeId"),
                 result: g(payload, "result")
               ) do
          {:ok, %{"task" => task}}
        end

      "colony.task.decompose" ->
        with {:ok, cid} <- need(payload, "colonyId"),
             {:ok, tid} <- need(payload, "taskId"),
             {:ok, children} <- need_list(payload, "children"),
             {:ok, tasks} <-
               Engine.decompose_task(cid, tid, normalize_children(children), bee_id: g(payload, "beeId")) do
          {:ok, %{"tasks" => tasks}}
        end

      "colony.task.heartbeat" ->
        with {:ok, cid} <- need(payload, "colonyId"),
             {:ok, tid} <- need(payload, "taskId"),
             {:ok, task} <- Engine.heartbeat_task(cid, tid) do
          {:ok, %{"task" => task}}
        end

      "colony.honey.add" ->
        with {:ok, cid} <- need(payload, "colonyId"),
             {:ok, honey} <-
               Engine.add_honey(cid, %{
                 "task_id" => g(payload, "taskId"),
                 "bee_id" => g(payload, "beeId"),
                 "kind" => g(payload, "kind"),
                 "title" => g(payload, "title"),
                 "content" => g(payload, "content"),
                 "content_ref" => g(payload, "contentRef"),
                 "note" => g(payload, "note"),
                 "checks" => g(payload, "checks")
               }) do
          {:ok, %{"honey" => Newbee.Colony.Honey.public(honey)}}
        end

      "colony.honey.review" ->
        with {:ok, cid} <- need(payload, "colonyId"),
             {:ok, hid} <- need(payload, "honeyId"),
             {:ok, verdict} <- need(payload, "verdict"),
             {:ok, honey} <-
               Engine.review_honey(cid, hid, verdict,
                 bee_id: g(payload, "beeId"),
                 note: g(payload, "note")
               ) do
          {:ok, %{"honey" => Newbee.Colony.Honey.public(honey)}}
        end

      "colony.signal.emit" ->
        with {:ok, cid} <- need(payload, "colonyId"),
             {:ok, kind} <- need(payload, "kind"),
             {:ok, from} <- need(payload, "fromBeeId"),
             {:ok, signal} <-
               Engine.emit_signal(cid, %{
                 "kind" => kind,
                 "from_bee_id" => from,
                 "to_bee_id" => g(payload, "toBeeId"),
                 "task_id" => g(payload, "taskId"),
                 "quality" => g(payload, "quality"),
                 "target_proposal_id" => g(payload, "targetProposalId"),
                 "payload" => g(payload, "payload") || %{}
               }) do
          {:ok, %{"signal" => signal}}
        end

      "colony.say" ->
        with {:ok, cid} <- need(payload, "colonyId"),
             {:ok, text} <- need(payload, "text") do
          Engine.say(cid, text,
            actor_bee_id: g(payload, "actorBeeId"),
            context: g(payload, "context"),
            upload_ids: g(payload, "uploadIds") || []
          )
        end

      "colony.trace.list" ->
        with {:ok, cid} <- need(payload, "colonyId") do
          limit = positive_int(g(payload, "limit"), 200)
          task_id = g(payload, "taskId")
          trace = Newbee.Colony.Store.trace_for_colony(cid, limit: limit, task_id: task_id)
          {:ok, %{"trace" => trace}}
        end

      "colony.capabilities" ->
        {:ok, %{"groups" => Newbee.Colony.Intent.capabilities()}}

      "colony.seed_demo" ->
        with {:ok, colony} <- Engine.seed_demo() do
          {:ok, %{"colony" => colony}}
        end

      "colony.rename" ->
        with {:ok, cid} <- need(payload, "colonyId"),
             {:ok, result} <-
               Engine.rename_colony(cid, g(payload, "name"), actor_bee_id: g(payload, "actorBeeId")) do
          {:ok, %{"colony" => result}}
        end

      _ ->
        {:error, "unknown_method", "未知 RPC 方法: #{method}"}
    end
  end

  # ── 参数工具 ──

  defp g(payload, key) when is_map(payload), do: Map.get(payload, key)

  defp need(payload, key) do
    case g(payload, key) do
      v when is_binary(v) and v != "" -> {:ok, v}
      _ -> {:error, "bad_request", "缺少参数 #{key}"}
    end
  end

  defp need_list(payload, key) do
    case g(payload, key) do
      list when is_list(list) and list != [] -> {:ok, list}
      _ -> {:error, "bad_request", "缺少参数 #{key}"}
    end
  end

  defp positive_int(v, _default) when is_integer(v) and v > 0, do: min(v, 1000)
  defp positive_int(_, default), do: default

  defp normalize_children(list) when is_list(list) do
    Enum.map(list, fn
      %{} = child -> child
      title when is_binary(title) -> %{"title" => title}
      _ -> %{}
    end)
    |> Enum.filter(&(Map.get(&1, "title") != nil))
  end

  defp normalize_children(_), do: []
end
