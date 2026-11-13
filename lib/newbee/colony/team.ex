defmodule Newbee.Colony.Team do
  @moduledoc """
  团队模板域逻辑：main 提案 → 人审批建队 → 模板入库 → 引用模板开项目 → 阶段闭环推进。

  持久化复用 Colony.Store（team_templates / team_proposals / team_runs 三张表）。
  沟通机制 = 角色间按阶段交接成果（上游已验收成果自动注入下游工作上下文）+ 蜂群既有群聊/@提及；
  运营机制 = 阶段流水线 + 验收闸门 + 打回回退（rework_to）+ 轮次预算（max_rounds）。
  所有推进都是幂等的：同一成果/同一任务重复回调不会重复建任务或重复计轮。
  """

  alias Newbee.Colony.{Store, Engine, Work, Task, Bee, Id, Trace, TeamTemplate}

  @statuses ~w(active completed halted)

  @doc "运行状态枚举。"
  def statuses, do: @statuses

  # ── 模板 ──

  @doc "入库团队模板（调用方负责权限）。attrs 见 TeamTemplate.normalize/1；source: manual|proposal|builtin。"
  def save_template(attrs, actor, source \\ "manual") do
    with {:ok, definition} <- TeamTemplate.normalize(attrs) do
      now = now()

      template =
        Map.merge(definition, %{
          "id" => Id.new(:team_template),
          "version" => 1,
          "source" => source,
          "created_by" => actor,
          "created_at" => now,
          "updated_at" => now
        })

      with :ok <- Store.put("team_templates", template), do: {:ok, template}
    end
  end

  @doc "全部模板（按创建时间排序）。"
  def list_templates do
    Store.all("team_templates") |> Enum.sort_by(& &1["created_at"])
  end

  @doc "取单个模板。"
  def get_template(id), do: Store.get("team_templates", id)

  @doc "内置「产研团队」模板入库（幂等：同名 builtin 模板已存在则直接返回）。"
  def seed_builtin(actor \\ nil) do
    definition = TeamTemplate.product_team()

    case Enum.find(list_templates(), &(&1["source"] == "builtin" and &1["name"] == definition["name"])) do
      nil -> save_template(definition, actor, "builtin")
      existing -> {:ok, existing}
    end
  end

  # ── 组建提案（main 角色） ──

  @doc """
  在蜂群里发起组建团队提案：创建（或复用）名为「团队主理人」的 main AI 角色，
  并派发一个只读规划任务；main 完成后产出模板草案 JSON，等人审批。
  attrs: goal, colony_id?, origin_session_id?
  """
  def start_proposal(attrs, actor) when is_map(attrs) do
    goal = attrs["goal"] |> to_string() |> String.trim()

    cond do
      goal == "" ->
        {:error, "bad_request", "请说明这个团队要做什么（目标/项目类型）"}

      String.length(goal) > 4_000 ->
        {:error, "bad_request", "目标说明过长（≤4000字）"}

      true ->
        with {:ok, colony} <- proposal_colony(attrs),
             {:ok, main} <- ensure_main(colony["id"]) do
          proposal = %{
            "id" => Id.new(:team_proposal),
            "colony_id" => colony["id"],
            "main_bee_id" => main["id"],
            "goal" => goal,
            "status" => "planning",
            "draft" => nil,
            "note" => nil,
            "template_id" => nil,
            "task_id" => nil,
            "origin_session_id" => attrs["origin_session_id"],
            "requested_by" => actor,
            "revision" => 0,
            "created_at" => now(),
            "updated_at" => now()
          }

          task_attrs = %{
            "title" => "组建团队提案：" <> String.slice(goal, 0, 40),
            "description" => goal,
            "assigned_bee_id" => main["id"],
            "actor_bee_id" => actor,
            "mode" => "team_plan",
            "source" => "team_proposal"
          }

          with {:ok, task} <- Work.create(colony["id"], task_attrs) do
            proposal = Map.merge(proposal, %{"task_id" => task["id"]})

            with :ok <- Store.put("team_proposals", proposal) do
              {:ok, proposal}
            end
          end
        end
    end
  end

  @doc "提案列表；opts: colony_id 过滤。"
  def list_proposals(opts \\ []) do
    cid = Keyword.get(opts, :colony_id)

    Store.all("team_proposals")
    |> then(fn all -> if cid, do: Enum.filter(all, &(&1["colony_id"] == cid)), else: all end)
    |> Enum.sort_by(& &1["created_at"], :desc)
  end

  @doc "取单个提案。"
  def get_proposal(id), do: Store.get("team_proposals", id)

  @doc """
  main 规划任务的完成回调（由 Workflow.complete 路由进来）。
  解析模板草案 JSON；无效草案把提案置为 draft_invalid，任务保持可重试，不入库。
  """
  def plan_complete(task, summary) do
    Store.transaction(fn data -> apply_plan_complete(data, task, summary) end)
  end

  @doc "纯函数版：在已有 Store 事务内应用 main 的草案（Workflow.complete 路由用，避免嵌套事务）。"
  def apply_plan_complete(data, task, summary) do
    proposal =
      Enum.find(Map.values(data["team_proposals"]), &(&1["task_id"] == task["id"]))

    cond do
      proposal == nil ->
        {:ok, :ignored, data}

      proposal["status"] not in ["planning", "draft_invalid"] ->
        {:ok, :ignored, data}

      true ->
        case parse_draft(summary) do
          {:ok, definition} ->
            proposal =
              Map.merge(proposal, %{
                "status" => "draft_ready",
                "draft" => definition,
                "revision" => proposal["revision"] + 1,
                "updated_at" => now()
              })

            task =
              Map.merge(task, %{
                "status" => "blocked",
                "waiting_for" => "user",
                "next_step" => "团队草案已生成，等待审批：批准后自动建立角色与运营机制并入库为模板。",
                "revision" => task["revision"] + 1,
                "updated_at" => now()
              })

            {data, _} =
              data
              |> put_entry(
                Trace.entry(%{
                  "colony_id" => task["colony_id"],
                  "task_id" => task["id"],
                  "bee_id" => task["assigned_bee_id"],
                  "type" => "message",
                  "text" =>
                    "main 已产出团队草案「#{definition["name"]}」（#{length(definition["roles"])}个角色 / #{length(definition["stages"])}个阶段），等待审批。",
                  "data" => %{"team_proposal_id" => proposal["id"]}
                })
              )

            {:ok, {:ok, proposal},
             data
             |> put_in(["team_proposals", proposal["id"]], proposal)
             |> put_in(["tasks", task["id"]], task)}

          {:error, reason} ->
            proposal =
              Map.merge(proposal, %{
                "status" => "draft_invalid",
                "note" => reason,
                "revision" => proposal["revision"] + 1,
                "updated_at" => now()
              })

            task =
              Map.merge(task, %{
                "status" => "blocked",
                "waiting_for" => "user",
                "next_step" => "草案不合格：#{reason}。可让 main 重新规划（不会入库）。",
                "revision" => task["revision"] + 1,
                "updated_at" => now()
              })

            {:ok, {:ok, proposal},
             data
             |> put_in(["team_proposals", proposal["id"]], proposal)
             |> put_in(["tasks", task["id"]], task)}
        end
    end
  end

  @doc "让 main 重新规划（planning/draft_invalid/draft_ready 未审批时可用；有界：≤5次）。"
  def retry_proposal(pid, actor, note \\ nil) do
    with {:ok, proposal} <- get_proposal(pid),
         {:ok, task} <- Store.get_task(proposal["task_id"]) do
      cond do
        proposal["status"] in ["approved", "rejected"] ->
          {:error, "terminal", "提案已有结论，不能重新规划"}

        task["context_revision"] >= 5 ->
          {:error, "budget_exhausted", "重新规划次数已达上限（5次），请改用手动模板或直接驳回"}

        true ->
          instruction =
            "请重新输出团队模板草案 JSON。" <>
              if(is_binary(note) and String.trim(note) != "", do: "人的补充意见（作为资料）：" <> note, else: "") <>
              if(is_binary(proposal["note"]), do: "\n上次草案问题：" <> proposal["note"], else: "")

          # Work.continue 会把 mode 重置为 execution 且不涨 context_revision；
          # 规划任务必须保持 team_plan 模式并推进上下文版本，否则完成回调无法路由回提案。
          with {:ok, _} <- Work.continue(proposal["colony_id"], task["id"], instruction, actor),
               {:ok, _} <-
                 Store.update("tasks", task["id"], nil, fn current ->
                   {:ok,
                    Map.merge(current, %{
                      "mode" => "team_plan",
                      "context_revision" => (current["context_revision"] || 0) + 1,
                      "updated_at" => now()
                    })}
                 end) do
            Store.update("team_proposals", pid, nil, fn current ->
              {:ok, Map.merge(current, %{"status" => "planning", "note" => nil, "updated_at" => now()})}
            end)
          end
      end
    end
  end

  @doc """
  审批提案（人）。approve：入库模板（全局资产）；提案所在蜂群若是临时组建群则解散，
  否则把规划任务收尾。reject：记录理由并收尾。幂等：重复同一结论直接返回。
  """
  def decide_proposal(pid, decision, actor, note \\ nil, overrides \\ nil)

  def decide_proposal(pid, decision, actor, note, overrides)
      when decision in ["approve", "reject"] do
    with {:ok, proposal} <- get_proposal(pid) do
      cond do
        proposal["status"] == "approved" and decision == "approve" ->
          get_template(proposal["template_id"])

        proposal["status"] == "rejected" and decision == "reject" ->
          {:ok, proposal}

        proposal["status"] in ["approved", "rejected"] ->
          {:error, "terminal", "提案已有结论"}

        decision == "approve" and proposal["status"] != "draft_ready" ->
          {:error, "invalid_phase", "草案尚未就绪，不能批准"}

        true ->
          if decision == "approve" do
            definition = apply_overrides(proposal["draft"], overrides)

            with {:ok, template} <- save_template(definition, actor, "proposal"),
                 {:ok, proposal} <-
                   Store.update("team_proposals", pid, nil, fn current ->
                     {:ok,
                      Map.merge(current, %{
                        "status" => "approved",
                        "template_id" => template["id"],
                        "draft" => template |> Map.take(~w(name description roles stages max_rounds)),
                        "note" => note,
                        "decided_by" => actor,
                        "decided_at" => now(),
                        "updated_at" => now()
                      })}
                   end) do
              close_proposal_task(proposal, actor, "团队模板「#{template["name"]}」已批准入库，可随时引用开项目。")
              {:ok, %{"proposal" => proposal, "template" => template}}
            end
          else
            with {:ok, proposal} <-
                   Store.update("team_proposals", pid, nil, fn current ->
                     {:ok,
                      Map.merge(current, %{
                        "status" => "rejected",
                        "note" => note,
                        "decided_by" => actor,
                        "decided_at" => now(),
                        "updated_at" => now()
                      })}
                   end) do
              close_proposal_task(proposal, actor, "组建提案被驳回：" <> to_string(note || "未说明原因"))
              {:ok, %{"proposal" => proposal}}
            end
          end
      end
    end
  end

  def decide_proposal(_, _, _, _, _), do: {:error, "bad_request", "decision 只能是 approve 或 reject"}

  # ── 引用模板开项目 ──

  @doc """
  引用模板启动项目：新建项目蜂群，按模板建立全部 AI 角色（沟通机制=阶段交接+群聊），
  建立运行记录并派发第一个阶段。attrs: template_id, name, goal, cwd?, actor 必填。
  """
  def start_run(attrs, actor) when is_map(attrs) do
    goal = attrs["goal"] |> to_string() |> String.trim()

    with {:ok, template} <- get_template(attrs["template_id"]),
         :ok <- validate_goal(goal) do
      name = blank(attrs["name"]) || template["name"] <> " · " <> String.slice(goal, 0, 24)

      with {:ok, colony} <-
             Engine.create_colony(%{
               "name" => name,
               "goal" => goal,
               "cwd" => blank(attrs["cwd"]) || File.cwd!(),
               "with_default_ai" => false
             }) do
        # 发起人必须是项目蜂群管理员，才能验收各阶段成果（Work.review 走 Control.authorize）。
        # 工具/系统发起（actor=nil）时回落到群主（人）：auto 闸门与阶段验收都有合法身份。
        sponsor = if is_binary(actor), do: actor, else: colony["queen_bee_id"]

        colony =
          if sponsor not in (colony["admin_bee_ids"] || []) do
            updated =
              Map.merge(colony, %{
                "admin_bee_ids" => Enum.uniq([sponsor | colony["admin_bee_ids"] || []]),
                "team_sponsor_bee_id" => sponsor
              })

            :ok = Store.put_colony(updated)
            updated
          else
            updated = Map.put(colony, "team_sponsor_bee_id", sponsor)
            :ok = Store.put_colony(updated)
            updated
          end

        actor = sponsor
        cid = colony["id"]

        with {:ok, role_bees} <- create_role_bees(cid, template) do
          run = %{
            "id" => Id.new(:team_run),
            "template_id" => template["id"],
            "template_version" => template["version"],
            "template" => Map.take(template, ~w(name description roles stages max_rounds)),
            "colony_id" => cid,
            "name" => name,
            "goal" => goal,
            "status" => "active",
            "round" => 1,
            "reworks" => 0,
            "stage_index" => 0,
            "role_bees" => role_bees,
            "history" => [],
            "current_task_id" => nil,
            "last_feedback" => nil,
            "created_by" => actor,
            "revision" => 0,
            "created_at" => now(),
            "updated_at" => now()
          }

          with :ok <- Store.put("team_runs", run),
               {:ok, run} <- dispatch_stage(run, nil) do
            {:ok, run}
          end
        end
      end
    end
  end

  @doc "运行列表；opts: colony_id 过滤。"
  def list_runs(opts \\ []) do
    cid = Keyword.get(opts, :colony_id)

    Store.all("team_runs")
    |> then(fn all -> if cid, do: Enum.filter(all, &(&1["colony_id"] == cid)), else: all end)
    |> Enum.sort_by(& &1["created_at"], :desc)
    |> Enum.map(&run_summary/1)
  end

  @doc """
  团队会话索引：把散落的执行会话按项目聚合，供主界面侧栏分组。
  返回 [%{run_id, run_name, run_status, round, colony_id, sessions: [%{session_id, role, role_name, stage, stage_name, status, task_id}]}]。
  """
  def session_map do
    runs = Store.all("team_runs")
    convs = Store.all("conversations")
    bees = Map.new(Store.all("bees"), &{&1["id"], &1})
    tasks = Map.new(Store.all("tasks"), &{&1["id"], &1})

    Enum.map(runs, fn run ->
      stages = Map.new(run["template"]["stages"], &{&1["key"], &1})
      roles = Map.new(run["template"]["roles"], &{&1["key"], &1})

      sessions =
        convs
        |> Enum.filter(&(&1["colony_id"] == run["colony_id"]))
        |> Enum.map(fn c ->
          task = tasks[c["task_id"]]
          bee = bees[c["bee_id"]]
          stage = task && stages[task["team_stage"]]
          role_key = (bee && bee["role"]) || (stage && stage["role"])
          role = roles[role_key]

          %{
            "session_id" => c["id"],
            "task_id" => c["task_id"],
            "role" => role_key,
            "role_name" => (role && role["name"]) || (bee && bee["display"]) || "成员",
            "stage" => task && task["team_stage"],
            "stage_name" => (stage && stage["name"]) || (task && task["team_stage"]),
            "round" => task && task["team_round"],
            "status" => task && task["status"]
          }
        end)
        |> Enum.sort_by(& &1["session_id"])

      %{
        "run_id" => run["id"],
        "run_name" => run["name"],
        "run_status" => run["status"],
        "round" => run["round"],
        "colony_id" => run["colony_id"],
        "needs_action" => run["needs_action"] || false,
        "sessions" => sessions
      }
    end)
    |> Enum.filter(&(&1["sessions"] != []))
    |> Enum.sort_by(& &1["run_name"])
  end

  # 列表摘要：附带 needs_action（待验收/待确认/已停下/受阻），主界面徽标用。
  defp run_summary(run) do
    task =
      run["current_task_id"] &&
        case Store.get_task(run["current_task_id"]) do
          {:ok, t} -> t
          _ -> nil
        end

    needs =
      cond do
        run["status"] in ["completed", "halted"] -> true
        task && task["status"] == "pending_review" -> true
        task && task["status"] == "blocked" -> true
        true -> false
      end

    run
    |> Map.put("needs_action", needs)
    |> Map.put("current_status", task && task["status"])
  end

  @doc "取单个运行。"
  def get_run(id), do: Store.get("team_runs", id)

  @doc "按蜂群找运行（一个项目蜂群一个运行）。"
  def run_for_colony(cid) do
    case Enum.find(Store.all("team_runs"), &(&1["colony_id"] == cid)) do
      nil -> {:error, "not_found", "该蜂群不是团队项目"}
      run -> {:ok, run}
    end
  end

  @doc """
  阶段任务完成回调（Runtime 在普通任务提交成果后调用；幂等）。
  - review 闸门：成果保持待验收，等人通过/打回；
  - auto 闸门：成果自动通过验收并推进下一阶段。
  """
  def stage_complete(task) do
    case run_for_task(task) do
      {:ok, run} ->
        cond do
          run["status"] != "active" or run["current_task_id"] != task["id"] ->
            {:ok, :ignored}

          task["status"] not in ["pending_review", "done"] or not is_binary(task["result"]) ->
            {:ok, :ignored}

          true ->
            stage = Enum.at(run["template"]["stages"], run["stage_index"])

            if stage && stage["gate"] == "auto" do
              review_stage(run["id"], task["result"], "accept", run["created_by"], "auto 闸门：完成即推进")
            else
              {:ok, :ignored}
            end
        end

      _ ->
        {:ok, :ignored}
    end
  end

  @doc """
  阶段成果验收（人，或 auto 闸门内部调用）。
  accept：记录已验收成果并推进（最后阶段→项目完成待确认）；
  reject：按 rework_to 回退重做，轮次+1；超过 max_rounds 则停下等人决策。
  """
  def review_stage(run_id, honey_id, verdict, actor, note \\ "")

  def review_stage(run_id, honey_id, verdict, actor, note) when verdict in ["accept", "reject"] do
    with {:ok, run} <- get_run(run_id),
         {:ok, task} <- Store.get_task(run["current_task_id"] || ""),
         :ok <- check_reviewable(run, task, honey_id) do
      case Work.review(run["colony_id"], honey_id, verdict, actor, note) do
        {:ok, honey} ->
          result =
            Store.transaction(fn data ->
              run = get_in(data, ["team_runs", run_id])
              stage = Enum.at(run["template"]["stages"], run["stage_index"])
              entry = history_entry(run, stage, task, honey, verdict, note, actor)
              run = Map.update!(run, "history", &(&1 ++ [entry]))
              previous_task_id = run["current_task_id"]

              run =
                if verdict == "accept" do
                  advance_run(run, honey)
                else
                  rework_run(run, note)
                end

              run = Map.merge(run, %{"revision" => run["revision"] + 1, "updated_at" => now()})
              {:ok, {:ok, run, previous_task_id}, put_in(data, ["team_runs", run_id], run)}
            end)

          case result do
            {:ok, run, previous_task_id} ->
              # 以事务里的最新 run 为准：阶段推进/回退后 current_task_id 仍指向旧任务，
              # 由 dispatch_current 的幂等检查决定是否派发下一阶段。
              if run["status"] == "active" and run["current_task_id"] == previous_task_id do
                dispatch_current(run)
              else
                {:ok, run}
              end

            error ->
              error
          end

        error ->
          error
      end
    end
  end

  def review_stage(_, _, _, _, _), do: {:error, "bad_request", "verdict 只能是 accept 或 reject"}

  @doc "项目完成后的确认（人）：满意→结束；继续迭代→带反馈回到第一阶段。"
  def finish(run_id, decision, actor, note \\ nil)

  def finish(run_id, decision, actor, note) when decision in ["complete", "iterate"] do
    with {:ok, run} <- get_run(run_id) do
      cond do
        run["status"] == "closed" and decision == "complete" ->
          {:ok, run}

        run["status"] != "completed" ->
          {:error, "invalid_phase", "项目还没有走完全部阶段"}

        decision == "complete" ->
          Store.update("team_runs", run_id, nil, fn current ->
            {:ok,
             Map.merge(current, %{
               "status" => "closed",
               "closed_by" => actor,
               "closed_at" => now(),
               "updated_at" => now()
             })}
          end)

        run["reworks"] >= run["template"]["max_rounds"] ->
          {:error, "budget_exhausted", "迭代轮次已用完（#{run["template"]["max_rounds"]}），可提高预算或结束项目"}

        true ->
          with {:ok, run} <-
                 Store.update("team_runs", run_id, nil, fn current ->
                   {:ok,
                    Map.merge(current, %{
                      "status" => "active",
                      "round" => current["round"] + 1,
                      "reworks" => current["reworks"] + 1,
                      "stage_index" => 0,
                      "current_task_id" => nil,
                      "last_feedback" => blank(note) || "上一轮已完成，请复盘并继续改进产品。",
                      "updated_at" => now()
                    })}
                 end) do
            dispatch_current(run)
          end
      end
    end
  end

  def finish(_, _, _, _), do: {:error, "bad_request", "decision 只能是 complete 或 iterate"}

  @doc "轮次用尽被停下的项目：提高预算并继续（人）。"
  def extend(run_id, extra_rounds, actor) do
    with {:ok, run} <- get_run(run_id),
         :ok <- check_extendable(run, extra_rounds) do
      feedback = run["last_feedback"] || "轮次预算已提高，请针对上轮反馈继续修复。"

      with {:ok, run} <-
             Store.update("team_runs", run_id, nil, fn current ->
               template = Map.update!(current["template"], "max_rounds", &(&1 + extra_rounds))

               {:ok,
                Map.merge(current, %{
                  "template" => template,
                  "status" => "active",
                  "last_feedback" => feedback,
                  "extended_by" => actor,
                  "updated_at" => now()
                })}
             end) do
        dispatch_current(run)
      end
    end
  end

  @doc "运行视图：运行记录 + 当前任务 + 各阶段成果摘要（UI/工具用）。"
  def run_view(run_id) do
    with {:ok, run} <- get_run(run_id) do
      stages =
        run["template"]["stages"]
        |> Enum.with_index()
        |> Enum.map(fn {stage, index} ->
          entries = Enum.filter(run["history"], &(&1["stage"] == stage["key"]))
          latest = List.last(entries)

          %{
            "key" => stage["key"],
            "name" => stage["name"],
            "role" => stage["role"],
            "gate" => stage["gate"],
            "state" =>
              cond do
                index < run["stage_index"] or run["status"] in ["completed", "closed"] -> "done"
                index == run["stage_index"] and run["status"] == "active" -> "current"
                true -> "pending"
              end,
            "attempts" => length(entries),
            "last_verdict" => latest && latest["verdict"],
            "last_task_id" => latest && latest["task_id"]
          }
        end)

      current =
        case run["current_task_id"] && Store.get_task(run["current_task_id"]) do
          {:ok, task} ->
            Map.take(task, ~w(id title status next_step result revision context_revision session_id))
            |> Map.put("result_content", result_content(task))

          _ ->
            nil
        end

      {:ok,
       %{
         "run" => run,
         "stages" => stages,
         "current_task" => current,
         "members" => Store.bees_for_colony(run["colony_id"]) |> Enum.map(&Bee.public/1)
       }}
    end
  end

  defp result_content(%{"result" => hid}) when is_binary(hid) do
    case Store.get_honey(hid) do
      {:ok, honey} -> String.slice(to_string(honey["content"]), 0, 12_000)
      _ -> nil
    end
  end

  defp result_content(_), do: nil

  # ── 上下文（沟通机制的资料面） ──

  @doc "main 规划任务的执行上下文（只读规划 + 模板 JSON 输出契约）。"
  def plan_context(task) do
    existing =
      list_templates()
      |> Enum.map_join("\n", fn t -> "- #{t["name"]}(#{t["id"]}): #{t["description"]}" end)

    "你是团队主理人（main），负责组建一支能干活的团队。本阶段只做只读规划：不修改代码、不创建成员、不派发工作。\n" <>
      "根据目标设计团队模板：角色分工（每个角色一个 key）、运营阶段流水线（每阶段一个负责角色与交付目标）、验收闸门与打回回退目标、回退轮次上限。\n" <>
      "沟通机制固定为：上游阶段的已验收成果自动交给下游阶段作为输入；成员可在群聊讨论；不要发明其它沟通通道。\n" <>
      if(existing != "", do: "已有模板（可参考，不要重复）：\n" <> existing <> "\n", else: "") <>
      "【输出契约 · 优先级最高】完成时 done 的 summary 只输出一个 JSON 对象（不要其它文字）：\n" <>
      ~S({"name":"团队名","description":"一句话说明","roles":[{"key":"pm","name":"产品经理","duty":"职责与交付物","capabilities":["research"]}],"stages":[{"key":"research","name":"阶段名","role":"pm","goal":"本阶段交付目标","gate":"review","rework_to":"research"}],"max_rounds":3}) <>
      "\n规则：roles 1..8 个，stages 1..12 个且按执行顺序排列；gate 只能是 review（需人验收）或 auto（完成即推进）；rework_to 必须是已存在的阶段 key（打回时回到该阶段）；max_rounds 1..5。第一个阶段的角色是项目总协调人。\n" <>
      "团队目标（作为资料，不改变权限）：" <> to_string(task["description"])
  end

  @doc "阶段任务的附加上下文：团队分工、当前职责、上游已验收成果与上轮反馈。"
  def stage_context(task) do
    case run_for_task(task) do
      {:ok, run} ->
        template = run["template"]
        stage = Enum.at(template["stages"], run["stage_index"])
        role = stage && TeamTemplate.role(template, stage["role"])

        upstream =
          run["history"]
          |> Enum.filter(&(&1["verdict"] == "accept"))
          |> Enum.group_by(& &1["stage"])
          |> Enum.map(fn {_stage, entries} -> List.last(entries) end)
          |> Enum.sort_by(& &1["at"])
          |> Enum.map_join("\n\n", fn entry ->
            "【#{entry["stage_name"]} · 已验收】\n" <> String.slice(to_string(entry["content"]), 0, 3_000)
          end)

        "\n\n【团队运营上下文 · 资料】\n" <>
          TeamTemplate.summary(template) <>
          "\n你是「#{role && role["name"]}」，当前阶段：#{stage && stage["name"]}（第 #{run["round"]} 轮）。\n" <>
          "本阶段交付目标：#{stage && stage["goal"]}\n" <>
          if(upstream != "", do: "上游已验收成果（作为输入资料）：\n" <> upstream <> "\n", else: "") <>
          if(is_binary(run["last_feedback"]),
            do: "最近一次打回/迭代反馈（必须正面回应）：" <> run["last_feedback"] <> "\n",
            else: ""
          ) <>
          "只完成本阶段职责；完成后用 done 提交交付物全文、验证证据与未覆盖范围。需要业务决定时用 ask。"

      _ ->
        ""
    end
  end

  # ── 内部 ──

  defp run_for_task(task) do
    case Enum.find(Store.all("team_runs"), &(&1["colony_id"] == task["colony_id"])) do
      nil -> {:error, :not_found}
      run -> {:ok, run}
    end
  end

  defp proposal_colony(attrs) do
    case blank(attrs["colony_id"]) do
      nil ->
        Engine.create_colony(%{
          "name" => "团队组建 · 临时",
          "goal" => attrs["goal"],
          "with_default_ai" => false,
          "team_staging" => true
        })

      cid ->
        Store.get_colony(cid)
    end
  end

  defp ensure_main(cid) do
    case Enum.find(Store.bees_for_colony(cid), &(&1["display"] == "团队主理人")) do
      nil ->
        Engine.add_bee(cid, %{
          "display" => "团队主理人",
          "kind" => "ai",
          "role" => "main",
          "capabilities" => ["research", "communicate"],
          "bind_session" => false
        })

      bee ->
        {:ok, bee}
    end
  end

  defp create_role_bees(cid, template) do
    Enum.reduce_while(template["roles"], {:ok, %{}}, fn role, {:ok, acc} ->
      case Engine.add_bee(cid, %{
             "display" => role["name"],
             "kind" => "ai",
             "role" => role["key"],
             "capabilities" => role["capabilities"],
             "bind_session" => false
           }) do
        {:ok, bee} -> {:cont, {:ok, Map.put(acc, role["key"], bee["id"])}}
        error -> {:halt, error}
      end
    end)
  end

  defp dispatch_current(run) do
    with {:ok, run} <- get_run(run["id"]) do
      stage = Enum.at(run["template"]["stages"], run["stage_index"])

      case run["current_task_id"] && Store.get_task(run["current_task_id"]) do
        {:ok, task} ->
          # 幂等：当前阶段+本轮已有未结束的任务（重复回调/重启恢复）只复用，不重复派发；
          # 打回回退后阶段/轮次已变化，即使旧任务未终态也要派发新的阶段任务。
          if task["team_stage"] == stage["key"] and task["team_round"] == run["round"] and
               not Newbee.Colony.Task.terminal?(task),
             do: {:ok, run},
             else: dispatch_stage(run, run["last_feedback"])

        _ ->
          dispatch_stage(run, run["last_feedback"])
      end
    end
  end

  # 派发当前阶段：建任务 + 投递；同一阶段重复调用不会重复建任务（current_task_id 幂等）。
  defp dispatch_stage(run, feedback) do
    Store.transaction(fn data ->
      run = get_in(data, ["team_runs", run["id"]])
      stage = Enum.at(run["template"]["stages"], run["stage_index"])
      bee_id = run["role_bees"][stage["role"]]
      bee = get_in(data, ["bees", bee_id])
      colony = get_in(data, ["colonies", run["colony_id"]])

      if run["status"] != "active" or stage == nil or bee == nil or colony == nil do
        {:ok, {:ok, run}, data}
      else
        title = "第#{run["round"]}轮 · #{stage["name"]} · @#{bee["display"]}"

        description =
          "项目目标：" <>
            run["goal"] <>
            "\n本阶段交付目标：" <>
            stage["goal"] <>
            if(is_binary(feedback), do: "\n本轮必须回应的反馈：" <> feedback, else: "")

        task =
          Work.build(colony, bee, %{
            "title" => title,
            "description" => description,
            "actor_bee_id" => run["created_by"],
            "acceptance" => [stage["goal"]],
            "source" => "team_run"
          })
          |> Map.merge(%{"team_run_id" => run["id"], "team_stage" => stage["key"], "team_round" => run["round"]})

        delivery = Work.new_delivery(task, %{"instruction" => description})

        run =
          Map.merge(run, %{
            "current_task_id" => task["id"],
            "last_feedback" => feedback,
            "revision" => run["revision"] + 1,
            "updated_at" => now()
          })

        {data, _} =
          data
          |> put_in(["tasks", task["id"]], task)
          |> put_in(["deliveries", delivery["id"]], delivery)
          |> put_in(["team_runs", run["id"]], run)
          |> put_entry(
            Trace.entry(%{
              "colony_id" => run["colony_id"],
              "task_id" => task["id"],
              "bee_id" => bee_id,
              "type" => "task",
              "text" => "团队项目「#{run["name"]}」第#{run["round"]}轮：#{stage["name"]} 交给 #{bee["display"]}。",
              "data" => %{"team_run_id" => run["id"], "stage" => stage["key"]}
            })
          )

        {:ok, {:ok, run}, data}
      end
    end)
  end

  defp advance_run(run, honey) do
    next_index = run["stage_index"] + 1

    if next_index >= length(run["template"]["stages"]) do
      Map.merge(run, %{
        "status" => "completed",
        "stage_index" => next_index,
        "last_feedback" => nil,
        "final_honey_id" => honey["id"]
      })
    else
      Map.merge(run, %{"stage_index" => next_index, "last_feedback" => nil})
    end
  end

  defp rework_run(run, note) do
    stage = Enum.at(run["template"]["stages"], run["stage_index"])
    target = stage["rework_to"] || stage["key"]
    index = TeamTemplate.stage_index(run["template"], target) || run["stage_index"]

    if run["reworks"] >= run["template"]["max_rounds"] do
      Map.merge(run, %{
        "status" => "halted",
        "last_feedback" => blank(note) || "验收未通过，轮次预算已用完。",
        "halt_reason" => "round_budget"
      })
    else
      Map.merge(run, %{
        "round" => run["round"] + 1,
        "reworks" => run["reworks"] + 1,
        "stage_index" => index,
        "last_feedback" => blank(note) || "验收未通过，请修复后重新交付。"
      })
    end
  end

  defp history_entry(run, stage, task, honey, verdict, note, actor) do
    %{
      "round" => run["round"],
      "stage" => stage["key"],
      "stage_name" => stage["name"],
      "role" => stage["role"],
      "task_id" => task["id"],
      "honey_id" => honey["id"],
      "verdict" => verdict,
      "note" => blank(note),
      "content" => String.slice(to_string(honey["content"]), 0, 12_000),
      "by" => actor,
      "at" => now()
    }
  end

  defp check_reviewable(run, task, honey_id) do
    cond do
      run["status"] != "active" ->
        {:error, "invalid_phase", "项目不在推进中"}

      task["colony_id"] != run["colony_id"] ->
        {:error, "forbidden", "成果不属于该项目"}

      task["id"] != run["current_task_id"] or task["result"] != honey_id ->
        {:error, "invalid_phase", "这不是当前阶段的待验收成果"}

      task["status"] not in ["pending_review", "done"] ->
        {:error, "invalid_phase", "当前阶段成果不在待验收状态"}

      true ->
        :ok
    end
  end

  defp check_extendable(run, extra) do
    cond do
      run["status"] != "halted" -> {:error, "invalid_phase", "只有轮次用尽被停下的项目可以提高预算"}
      not is_integer(extra) or extra < 1 or extra > 5 -> {:error, "bad_request", "extra_rounds 必须是 1..5"}
      run["template"]["max_rounds"] + extra > 10 -> {:error, "budget_exhausted", "总轮次预算不能超过 10"}
      true -> :ok
    end
  end

  defp validate_goal(goal) do
    cond do
      goal == "" -> {:error, "bad_request", "请说明项目目标"}
      String.length(goal) > 4_000 -> {:error, "bad_request", "项目目标过长（≤4000字）"}
      true -> :ok
    end
  end

  defp apply_overrides(draft, overrides) when is_map(overrides) do
    Map.merge(draft, Map.take(overrides, ~w(name description max_rounds)))
  end

  defp apply_overrides(draft, _), do: draft

  defp close_proposal_task(proposal, actor, text) do
    with {:ok, task} <- Store.get_task(proposal["task_id"]) do
      unless Task.terminal?(task) do
        _ =
          Store.update("tasks", task["id"], nil, fn current ->
            {:ok,
             Map.merge(current, %{
               "status" => "done",
               "waiting_for" => nil,
               "completed_at" => now(),
               "next_step" => text,
               "updated_at" => now()
             })}
          end)
      end

      _ =
        Store.append_trace(
          Trace.entry(%{
            "colony_id" => proposal["colony_id"],
            "task_id" => proposal["task_id"],
            "bee_id" => actor,
            "type" => "lifecycle",
            "text" => text,
            "data" => %{"team_proposal_id" => proposal["id"]}
          })
        )

      :ok
    end
  end

  defp parse_draft(summary) do
    text = summary |> to_string() |> String.trim()
    unfenced = text |> String.replace(~r/\A```(?:json)?\s*|\s*```\z/u, "") |> String.trim()

    sliced =
      with {a, 1} <- :binary.match(text, "{") do
        rest = binary_part(text, a, byte_size(text) - a)

        case rest |> :binary.matches("}") |> List.last() do
          {offset, 1} -> binary_part(rest, 0, offset + 1)
          _ -> ""
        end
      else
        _ -> ""
      end

    [text, unfenced, sliced]
    |> Enum.uniq()
    |> Enum.find_value({:error, "没有解析到模板 JSON"}, fn candidate ->
      case Jason.decode(candidate) do
        {:ok, %{} = map} ->
          case TeamTemplate.normalize(map) do
            {:ok, definition} -> {:ok, definition}
            {:error, _code, message} -> {:error, message}
          end

        _ ->
          nil
      end
    end)
  end

  defp put_entry(data, entry) do
    Store.put_entry(data, "trace", entry)
  end

  defp blank(value) when is_binary(value) do
    trimmed = String.trim(value)
    if trimmed == "", do: nil, else: trimmed
  end

  defp blank(_), do: nil

  defp now, do: System.system_time(:millisecond)
end
