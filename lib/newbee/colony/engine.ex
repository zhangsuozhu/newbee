defmodule Newbee.Colony.Engine do
  @moduledoc """
  蜂群协作编排引擎：把 Colony/Bee/Task/Honey/Signal/Trace 串成可用的业务流。

  设计约定（附录 L/N）：
  - Bee 在 Colony 中平级；临时协调关系只存在于任务图。
  - 协调权来自任务授权；权限不随父子关系继承。
  - 所有变更写 Trace；聊天/信号/任务/成果共用一条日志。
  - AI Bee 若绑定了会话，派活/发消息会尽力投递到会话（best-effort，失败只记 Trace）。
  """

  alias Newbee.Colony.{Bee, Honey, Id, Intent, Signal, Store, Task, Trace}

  @default_colony_name "我的蜂群"
  @leave_handover_hint "Queen 是责任载体，退出前需要指定继任：说「我退出，让某人当 Queen」。"

  # ───────────────────────── 群 ─────────────────────────

  @doc "确保存在至少一个蜂群（首次使用自动创建，零配置）。"
  def bootstrap do
    case Store.list_colonies() do
      [] -> create_colony(%{"name" => @default_colony_name, "goal" => ""})
      [c | _] -> {:ok, c}
    end
  end

  @doc "创建蜂群，同时创建 Queen（人）和默认 AI Bee；AI 会在首次工作时懒启动会话。"
  def create_colony(attrs) when is_map(attrs) do
    name = blank_to_nil(Map.get(attrs, "name")) || @default_colony_name
    now = now_ms()

    colony = %{
      "id" => Map.get(attrs, "id") || Id.new(:colony, scope_for(attrs)),
      "name" => name,
      "goal" => Map.get(attrs, "goal") || "",
      "cwd" => Map.get(attrs, "cwd") || File.cwd!(),
      "status" => "active",
      "scope" => Map.get(attrs, "scope") || "local",
      "queen_bee_id" => nil,
      "created_at" => now,
      "updated_at" => now
    }

    :ok = Store.put_colony(colony)

    queen_attrs = %{
      "colony_id" => colony["id"],
      "kind" => "human",
      "display" => Map.get(attrs, "queen") || default_queen_display(),
      "role" => "queen",
      "capabilities" => Bee.human_default_capabilities()
    }

    {:ok, queen} = add_bee(colony["id"], queen_attrs)

    if Map.get(attrs, "with_default_ai", true) do
      {:ok, _default_ai} =
        add_bee(colony["id"], %{
          "kind" => "ai",
          "display" => Map.get(attrs, "default_ai") || "研发助手",
          "role" => "worker",
          "bind_session" => false
        })
    end

    colony =
      colony |> Map.put("queen_bee_id", queen["id"]) |> Map.put("admin_bee_ids", [queen["id"]])

    :ok = Store.put_colony(colony)

    trace(colony["id"], %{
      "type" => "lifecycle",
      "bee_id" => queen["id"],
      "text" => "蜂群「" <> name <> "」创建，Queen：" <> queen["display"]
    })

    {:ok, colony}
  end

  @doc "解散蜂群（Queen 专属）。"
  def dissolve(colony_id, opts \\ []) do
    with {:ok, colony} <- fetch_colony(colony_id),
         :ok <- require_queen(colony, Keyword.get(opts, :actor_bee_id)) do
      with {:ok, _} <-
             Newbee.Colony.Control.set(colony_id, "colony", colony_id, "interrupt",
               actor_bee_id: Keyword.get(opts, :actor_bee_id)
             ),
           :ok <- Store.delete_colony(colony_id) do
        {:ok, %{"dissolved" => colony_id, "name" => colony["name"]}}
      end
    end
  end

  def list_colonies do
    Store.list_colonies()
    |> Enum.map(fn c -> %{"colony" => c, "stats" => colony_stats(c["id"])} end)
  end

  # ───────────────────────── Bee ─────────────────────────

  @doc "加入一只 Bee（人或 AI）。attrs: kind?, display, capabilities?, session_id?, bind_session?, garden_id?"
  def add_bee(colony_id, attrs) do
    with {:ok, colony} <- fetch_colony(colony_id) do
      display = blank_to_nil(Map.get(attrs, "display")) || "bee"
      kind = normalize_kind(Map.get(attrs, "kind"), display)

      attrs =
        attrs
        |> Map.put("colony_id", colony_id)
        |> Map.put("kind", kind)
        |> Map.put("display", display)

      attrs = maybe_bind_session(attrs, kind)
      bee = Bee.new(attrs)
      :ok = Store.put_bee(bee)

      trace(colony_id, %{
        "type" => "lifecycle",
        "bee_id" => bee["id"],
        "text" => "「#{bee["display"]}」（#{kind_label(kind)}）加入了蜂群"
      })

      {:ok, bee}
    end
  end

  @doc "移出一只 Bee：吊销身份、未完成任务回流、成果保留（附录 I.1）。"
  def remove_bee(colony_id, bee_id, opts \\ []) do
    with {:ok, colony} <- fetch_colony(colony_id),
         {:ok, bee} <- fetch_bee(bee_id),
         :ok <- require_queen(colony, Keyword.get(opts, :actor_bee_id)),
         :ok <- require_same_colony(bee, colony_id) do
      reflow_tasks(colony_id, bee_id)
      :ok = Store.delete_bee(bee_id)

      trace(colony_id, %{
        "type" => "lifecycle",
        "bee_id" => bee_id,
        "text" => "「#{bee["display"]}」已被移出蜂群，未完成任务回流，产出成果保留"
      })

      {:ok, bee}
    end
  end

  @doc "主动退出。Queen 退群必须交接（handover_to: 继任者显示名）。"
  def leave(colony_id, bee_id, opts \\ []) do
    with {:ok, colony} <- fetch_colony(colony_id),
         {:ok, bee} <- fetch_bee(bee_id),
         :ok <- require_same_colony(bee, colony_id) do
      cond do
        colony["queen_bee_id"] != bee_id ->
          reflow_tasks(colony_id, bee_id)
          :ok = Store.delete_bee(bee_id)

          trace(colony_id, %{
            "type" => "lifecycle",
            "bee_id" => bee_id,
            "text" => "「#{bee["display"]}」退出了蜂群"
          })

          {:ok, %{"left" => bee_id}}

        Keyword.get(opts, :handover_to) ->
          with {:ok, successor} <- find_bee_by_display(colony_id, Keyword.get(opts, :handover_to)),
               :ok <- handover_queen(colony, successor) do
            reflow_tasks(colony_id, bee_id)
            :ok = Store.delete_bee(bee_id)
            {:ok, %{"left" => bee_id, "handover_to" => successor["id"]}}
          end

        true ->
          {:error, "handover_required", @leave_handover_hint}
      end
    end
  end

  @doc "Queen 交接。"
  def handover_queen(colony, successor) do
    colony =
      colony
      |> Map.put("queen_bee_id", successor["id"])
      |> Map.put("admin_bee_ids", [successor["id"]])

    :ok = Store.put_colony(colony)

    successor = Map.put(successor, "role", "queen")
    :ok = Store.put_bee(successor)

    trace(colony["id"], %{
      "type" => "lifecycle",
      "bee_id" => successor["id"],
      "text" => "Queen 交接给「#{successor["display"]}」"
    })

    :ok
  end

  # ───────────────────────── 任务 ─────────────────────────

  @doc "创建任务；指定 assignee 时直接派活，否则作为刺激广播自领取。"
  def create_task(colony_id, attrs) do
    with {:ok, colony} <- fetch_colony(colony_id) do
      attrs = attrs |> Map.put("colony_id", colony_id)
      task = Task.new(attrs)
      task = maybe_assign(task, Map.get(attrs, "assignee_display"), colony_id)
      :ok = Store.put_task(task)

      trace(colony_id, %{
        "type" => "task",
        "bee_id" => Map.get(attrs, "actor_bee_id"),
        "task_id" => task["id"],
        "text" => task_created_text(task, colony)
      })

      maybe_deliver_task(
        colony,
        task,
        normalize_upload_ids(Map.get(attrs, "upload_ids")),
        Map.get(attrs, "upload_sid")
      )

      {:ok, task}
    end
  end

  @doc "领取任务（CAS）。"
  def claim_task(colony_id, task_id, bee_id) do
    with {:ok, _colony} <- fetch_colony(colony_id),
         {:ok, task} <- fetch_task(task_id),
         {:ok, bee} <- fetch_bee(bee_id),
         :ok <- require_same_colony(bee, colony_id),
         :ok <- require_same_colony(task, colony_id),
         {:ok, task} <- Store.update("tasks", task_id, task["revision"], &claim_or_error(&1, bee)) do
      trace(colony_id, %{
        "type" => "task",
        "bee_id" => bee_id,
        "task_id" => task_id,
        "text" => "「#{bee["display"]}」领取了任务「#{task["title"]}」（刺激 #{fmt(Task.stimulate(task))}）"
      })

      public_task_status(colony_id, task, bee, "已接受任务，正在处理。")

      {:ok, task}
    end
  end

  defp claim_or_error(task, bee) do
    case Task.claim(task, bee) do
      {:ok, claimed} ->
        {:ok, claimed}

      {:error, :conflict} ->
        {:error, "conflict", "任务已被其他 Bee 领取"}

      {:error, :incapable} ->
        {:error, "incapable", "能力不匹配：缺少 #{Enum.join(Map.get(task, "requires", []), "/")}"}

      {:error, :not_claimable} ->
        {:error, "not_claimable", "任务已结束，无法领取"}
    end
  end

  @doc "任务状态迁移。event: start/block/unblock/complete/fail/cancel/release。"
  def transition_task(colony_id, task_id, event, opts \\ []) do
    with {:ok, _colony} <- fetch_colony(colony_id),
         {:ok, task} <- fetch_task(task_id),
         :ok <- require_same_colony(task, colony_id),
         {:ok, task} <-
           Store.update("tasks", task_id, task["revision"], &do_transition(&1, event, opts)) do
      trace(colony_id, %{
        "type" => "task",
        "bee_id" => Keyword.get(opts, :bee_id),
        "task_id" => task_id,
        "text" => "任务「#{task["title"]}」：#{transition_text(event)}"
      })

      {:ok, task}
    end
  end

  defp do_transition(task, event, opts) do
    case Task.transition(task, event, opts) do
      {:ok, t} -> {:ok, t}
      {:error, :invalid_transition} -> {:error, "invalid_transition", "当前状态不允许该操作"}
    end
  end

  @doc "任务心跳（AI 执行中定期上报，防止被判定超时）。"
  def heartbeat_task(colony_id, task_id) do
    with {:ok, _} <- fetch_colony(colony_id),
         {:ok, task} <- fetch_task(task_id) do
      with :ok <- require_same_colony(task, colony_id) do
        Store.update("tasks", task_id, nil, &{:ok, Task.heartbeat(&1)})
      end
    end
  end

  @doc "任务拆分为子任务（受并行/深度预算约束）。"
  def decompose_task(colony_id, task_id, children, opts \\ []) do
    with {:ok, _colony} <- fetch_colony(colony_id),
         {:ok, parent} <- fetch_task(task_id),
         {:ok, children} <- build_children(parent, children, opts) do
      Enum.each(children, &Store.put_task/1)

      trace(colony_id, %{
        "type" => "task",
        "bee_id" => Keyword.get(opts, :bee_id) || parent["assigned_bee_id"],
        "task_id" => task_id,
        "text" =>
          "任务「#{parent["title"]}」拆出 #{length(children)} 个子任务：" <>
            Enum.map_join(children, "、", &"「#{&1["title"]}」")
      })

      {:ok, children}
    end
  end

  defp build_children(parent, children, opts) do
    all = Store.tasks_for_colony(parent["colony_id"])
    opts = Keyword.put_new(opts, :coordinator_bee_id, Map.get(parent, "assigned_bee_id"))

    case Task.decompose(parent, children, all, opts) do
      {:ok, built} -> {:ok, built}
      {:error, :budget_exceeded} -> {:error, "budget_exceeded", "超出并行子任务预算（默认最多 4 个）"}
      {:error, :depth_exceeded} -> {:error, "depth_exceeded", "超出任务深度预算（默认最多 3 层）"}
      {:error, :not_claimable} -> {:error, "not_claimable", "已完成的任务不能拆分"}
      {:error, :no_children} -> {:error, "no_children", "没有可拆分的子任务"}
    end
  end

  # ───────────────────────── 成果 ─────────────────────────

  @doc "记录成果；checks 非空时自动预检。"
  def add_honey(colony_id, attrs) do
    with {:ok, _colony} <- fetch_colony(colony_id) do
      honey = Honey.new(Map.put(attrs, "colony_id", colony_id))

      honey =
        if Map.get(attrs, "checks"),
          do: Honey.auto_verify(honey, Map.get(attrs, "checks")),
          else: honey

      :ok = Store.put_honey(honey)

      trace(colony_id, %{
        "type" => "honey",
        "bee_id" => honey["bee_id"],
        "task_id" => honey["task_id"],
        "text" => "产出成果「#{honey["title"]}」（#{review_state_label(honey)}）",
        "data" => %{
          "honey_id" => honey["id"],
          "review_state" => get_in(honey, ["review", "state"])
        }
      })

      {:ok, Honey.public(honey)}
    end
  end

  @doc "Queen 验收成果。verdict: accept | reject。"
  def review_honey(colony_id, honey_id, verdict, opts \\ []) do
    with {:ok, _colony} <- fetch_colony(colony_id),
         {:ok, honey} <- fetch_honey(honey_id),
         {:ok, honey} <- do_review(honey, verdict, opts) do
      :ok = Store.put_honey(honey)

      trace(colony_id, %{
        "type" => "honey",
        "bee_id" => Keyword.get(opts, :bee_id),
        "task_id" => honey["task_id"],
        "text" => "成果「#{honey["title"]}」#{if verdict == "accept", do: "已验收通过 ✅", else: "被打回 ↩"}",
        "data" => %{
          "honey_id" => honey["id"],
          "review_state" => get_in(honey, ["review", "state"])
        }
      })

      {:ok, Honey.public(honey)}
    end
  end

  defp do_review(honey, verdict, opts) do
    case Honey.review(honey, verdict, Keyword.get(opts, :bee_id), Keyword.get(opts, :note, "")) do
      {:ok, h} -> {:ok, h}
      {:error, :already_reviewed} -> {:error, "already_reviewed", "该成果已经验收过"}
      {:error, :invalid_verdict} -> {:error, "invalid_verdict", "验收结论无效"}
    end
  end

  # ───────────────────────── 信号 ─────────────────────────

  @doc "发送信号（recommend/rebalance/inhibit/report/command/notify/escalate/handoff）。"
  def emit_signal(colony_id, attrs) do
    with {:ok, _colony} <- fetch_colony(colony_id) do
      attrs = Map.put(attrs, "colony_id", colony_id)

      case Signal.new(attrs) do
        {:ok, signal} ->
          recent = Store.signals_for_colony(colony_id, limit: 100)

          cond do
            not Signal.allowed?(signal, recent) ->
              {:error, "cooldown", "同一竞争方案的抑制信号在冷却期内"}

            true ->
              {:ok, signal} = Store.put_signal(signal)

              trace(colony_id, %{
                "type" => "signal",
                "bee_id" => signal["from_bee_id"],
                "to_bee_id" => signal["to_bee_id"],
                "task_id" => signal["task_id"],
                "text" => Signal.describe(signal),
                "data" => %{"signal_id" => signal["id"], "kind" => signal["kind"]}
              })

              maybe_deliver_signal(signal)
              {:ok, signal}
          end

        {:error, :invalid_kind} ->
          {:error, "invalid_kind", "未知信号类型"}

        {:error, :quality_required} ->
          {:error, "quality_required", "recommend 信号必须带质量评分（0..1）"}

        {:error, :target_required} ->
          {:error, "target_required", "inhibit 信号必须指向竞争方案"}
      end
    end
  end

  # ───────────────────────── 对话（单一入口） ─────────────────────────

  @doc """
  单一对话框入口：解析意图并执行。
  opts: actor_bee_id（默认 Queen）、context（%{"bee_id" => ..., "task_id" => ...}）。
  返回 %{"reply" => text | nil, "actions" => [...], "colony_id" => ...}。
  """
  def say(colony_id, text, opts \\ []) do
    with {:ok, colony} <- fetch_colony(colony_id),
         {:ok, actor} <- resolve_actor(colony, opts) do
      context = opts |> Keyword.get(:context) |> normalize_context()
      upload_ids = normalize_upload_ids(Keyword.get(opts, :upload_ids))

      case context_scope(context) do
        :bee -> say_to_bee(colony, actor, text, context, upload_ids)
        :task -> say_to_task(colony, actor, text, context, upload_ids)
        :colony -> say_to_colony(colony, actor, text, opts, upload_ids)
      end
    end
  end

  defp say_to_colony(colony, actor, text, opts, upload_ids) do
    {mentions, core} = parse_mentions(text)

    # 用户发言统一入 Trace（对话连续性：无论意图还是闲聊都在消息流里）；附件与 @ 一并记录
    trace(colony["id"], %{
      "type" => "message",
      "channel" => "colony",
      "bee_id" => actor["id"],
      "text" => text,
      "data" =>
        attachments_data(actor["session_id"], upload_ids)
        |> Map.merge(mention_data(mentions))
    })

    # 仿微信群：@ 了人就把这句话交给被点名的人；没 @ 才走蜂群自己的意图路由
    if mentions != [] do
      {:ok, deliver_mentions(colony, actor, mentions, core, upload_ids, opts)}
    else
      result =
        case Intent.parse(core) do
          {:ok, intent} ->
            run_intent(colony, actor, intent, core, Keyword.put(opts, :upload_ids, upload_ids))

          {:error, :unknown} ->
            {:ok, %{"reply" => nil, "actions" => [], "colony_id" => colony["id"]}}
        end

      case result do
        {:ok, res} ->
          maybe_trace_reply(colony["id"], res)
          {:ok, res}

        other ->
          other
      end
    end
  end

  # ── @ 点名（仿微信群）────────────────────────────────────────────
  # @某人 → 只投给这个人；@all / @所有人 / @全体 → 投给群里所有 AI。
  # 被 @ 的正文若本身是派活意图（「建个任务：…」），则直接派给被点名的人。

  @mention_re ~r/@([\p{L}\p{N}_\-.]+)/u

  @doc false
  def parse_mentions(text) when is_binary(text) do
    mentions =
      Regex.scan(@mention_re, text)
      |> Enum.map(fn [_, name] -> name end)
      |> Enum.uniq()

    core =
      text
      |> then(&Regex.replace(@mention_re, &1, ""))
      |> String.replace(~r/\s+/u, " ")
      |> String.trim()

    {mentions, core}
  end

  def parse_mentions(_), do: {[], ""}

  defp mention_data([]), do: %{}
  defp mention_data(mentions), do: %{"mentions" => mentions}

  defp mention_all?(name) do
    String.downcase(String.trim(name)) in ["all", "everyone", "所有人", "全体", "大家"]
  end

  # 返回 {scope, [bee], [没找到的名字]}
  defp mention_targets(colony, mentions) do
    bees = Store.bees_for_colony(colony["id"])

    if Enum.any?(mentions, &mention_all?/1) do
      {:all, Enum.filter(bees, &(&1["kind"] == "ai")), []}
    else
      {found, missed} =
        Enum.reduce(mentions, {[], []}, fn name, {acc, miss} ->
          case find_bee_by_display(colony["id"], name) do
            {:ok, bee} -> {[bee | acc], miss}
            _ -> {acc, [name | miss]}
          end
        end)

      {:some, found |> Enum.uniq_by(& &1["id"]) |> Enum.reverse(), Enum.reverse(missed)}
    end
  end

  defp deliver_mentions(colony, actor, mentions, core, upload_ids, _opts) do
    {scope, bees, missed} = mention_targets(colony, mentions)

    case Intent.parse(core) do
      {:ok, %{kind: :dispatch} = intent} ->
        assignee = List.first(bees)
        title = Map.get(intent, :title) || core

        attrs =
          %{
            "title" => title,
            "actor_bee_id" => actor["id"],
            "source" => "group_mention",
            "upload_ids" => upload_ids,
            "upload_sid" => actor["session_id"]
          }
          |> then(fn a ->
            if assignee, do: Map.put(a, "assigned_bee_id", assignee["id"]), else: a
          end)

        case create_task(colony["id"], attrs) do
          {:ok, task} ->
            who = if assignee, do: "「#{assignee["display"]}」", else: "群里能干的 Bee"

            %{
              "reply" => "已建任务「#{task["title"]}」并派给#{who}。",
              "actions" => [%{"type" => "task", "task_id" => task["id"]}],
              "colony_id" => colony["id"]
            }

          {:error, code, msg} ->
            %{"reply" => "建任务失败：#{msg}（#{code}）", "actions" => [], "colony_id" => colony["id"]}
        end

      _ ->
        text = if core == "", do: "（在群里 @ 了你）", else: core
        prompt = "【群聊·#{actor["display"]} 点名】" <> text

        results =
          Enum.map(bees, fn bee ->
            status =
              if bee["kind"] == "ai" do
                deliver_to_session(bee, prompt, upload_ids, actor["session_id"])
              else
                :skipped
              end

            {bee, status}
          end)

        trace_mention_receipts(colony["id"], scope, results, missed)

        %{
          "reply" => nil,
          "actions" => [%{"type" => "mention", "scope" => to_string(scope)}],
          "colony_id" => colony["id"]
        }
    end
  end

  defp trace_mention_receipts(colony_id, scope, results, missed) do
    Enum.each(results, fn {bee, status} ->
      text =
        case status do
          :ok -> "已把消息投递给「#{bee["display"]}」"
          :skipped -> "「#{bee["display"]}」是真人成员，只在群里看得到"
          _ -> "「#{bee["display"]}」暂未绑定可投递的会话，消息已记录"
        end

      trace(colony_id, %{
        "type" => "command",
        "channel" => "colony",
        "bee_id" => nil,
        "to_bee_id" => bee["id"],
        "text" => text,
        "data" => %{"delivered" => status == :ok, "mention" => to_string(scope)}
      })
    end)

    Enum.each(missed, fn name ->
      trace(colony_id, %{
        "type" => "command",
        "channel" => "colony",
        "bee_id" => nil,
        "text" => "没找到被 @ 的「#{name}」",
        "data" => %{"delivered" => false, "mention" => "missing"}
      })
    end)
  end

  defp maybe_trace_reply(_colony_id, %{"reply" => reply}) when not is_binary(reply), do: :ok

  defp maybe_trace_reply(colony_id, %{"reply" => reply}) do
    trace(colony_id, %{
      "type" => "message",
      "channel" => "colony",
      "bee_id" => nil,
      "text" => reply,
      "data" => %{"from" => "colony"}
    })
  end

  defp maybe_trace_reply(_colony_id, _), do: :ok

  defp say_to_bee(colony, actor, text, context, upload_ids) do
    bee_id = context["bee_id"]

    with {:ok, bee} <- fetch_bee(bee_id) do
      trace(colony["id"], %{
        "type" => "message",
        "channel" => "dm",
        "bee_id" => actor["id"],
        "to_bee_id" => bee_id,
        "text" => text,
        "data" => attachments_data(bee["session_id"], upload_ids)
      })

      delivery = deliver_to_session(bee, text, upload_ids, bee["session_id"])

      trace(colony["id"], %{
        "type" => "command",
        "channel" => "dm",
        "bee_id" => actor["id"],
        "to_bee_id" => bee_id,
        "text" =>
          if(delivery == :ok,
            do: "已把消息投递给「#{bee["display"]}」",
            else: "「#{bee["display"]}」暂未绑定可投递的会话，消息已记录"
          ),
        "data" => %{"delivered" => delivery == :ok}
      })

      {:ok,
       %{
         "reply" => nil,
         "actions" => [%{"type" => "dm", "bee_id" => bee_id, "delivered" => delivery == :ok}],
         "colony_id" => colony["id"]
       }}
    end
  end

  defp say_to_task(colony, actor, text, context, upload_ids) do
    task_id = context["task_id"]

    with {:ok, task} <- fetch_task(task_id),
         {:ok, bee} <- resolve_task_bee(colony, task) do
      trace(colony["id"], %{
        "type" => "command",
        "channel" => "task",
        "bee_id" => actor["id"],
        "to_bee_id" => bee["id"],
        "task_id" => task_id,
        "text" => text,
        "data" => attachments_data(bee["session_id"], upload_ids)
      })

      delivery =
        deliver_to_session(bee, task_prompt(colony, task, text), upload_ids, bee["session_id"])

      trace(colony["id"], %{
        "type" => "command",
        "channel" => "task",
        "bee_id" => actor["id"],
        "to_bee_id" => bee["id"],
        "task_id" => task_id,
        "text" =>
          if(delivery == :ok,
            do: "指令已发给「#{bee["display"]}」",
            else: "指令已记录（「#{bee["display"]}」暂未绑定可投递的会话）"
          ),
        "data" => %{"delivered" => delivery == :ok}
      })

      {:ok,
       %{
         "reply" => nil,
         "actions" => [%{"type" => "task_command", "task_id" => task_id, "bee_id" => bee["id"]}],
         "colony_id" => colony["id"]
       }}
    end
  end

  defp run_intent(colony, actor, intent, text, opts) do
    cid = colony["id"]

    case intent.kind do
      :help ->
        {:ok,
         %{
           "reply" => help_reply(),
           "actions" => [%{"type" => "capabilities", "groups" => Intent.capabilities()}],
           "colony_id" => cid
         }}

      :progress ->
        {:ok, %{"reply" => progress_reply(cid), "actions" => [], "colony_id" => cid}}

      :create_colony ->
        name = Map.get(intent, :name) || extract_colony_name(text)

        case create_colony(%{"name" => name}) do
          {:ok, created} ->
            {:ok,
             %{
               "reply" => "已建蜂群「#{created["name"]}」，你是 Queen。要拉人说「加某人进来」，或说「建个任务做…」。",
               "actions" => [
                 %{"type" => "switch", "colony_id" => created["id"], "name" => created["name"]}
               ],
               "colony_id" => cid
             }}

          {:error, code, msg} ->
            {:error, code, msg}
        end

      :add_bee ->
        display = Map.get(intent, :who)
        kind = Intent.infer_bee_kind(display)

        case add_bee(cid, %{"display" => display, "kind" => kind}) do
          {:ok, bee} ->
            reply =
              if bee["kind"] == "ai" do
                "已把「#{bee["display"]}」加进来（AI Bee，能力：#{Enum.join(bee["capabilities"], "/")}）。可以直接说「让 #{bee["display"]} 做 …」。"
              else
                "已把「#{bee["display"]}」加进来（人 Bee）。跨机接入时把邀请串发给 TA 即可（见设计附录 F）。"
              end

            {:ok,
             %{
               "reply" => reply,
               "actions" => [%{"type" => "refresh", "colony_id" => cid}],
               "colony_id" => cid
             }}

          {:error, _, _} = err ->
            err
        end

      :remove_bee ->
        with {:ok, bee} <- find_bee_by_display(cid, Map.get(intent, :who)),
             {:ok, _} <- remove_bee(cid, bee["id"], actor_bee_id: actor["id"]) do
          {:ok,
           %{
             "reply" => "已把「#{bee["display"]}」移出蜂群：身份吊销、任务回流、成果保留。",
             "actions" => [],
             "colony_id" => cid
           }}
        else
          {:error, :not_found} -> {:error, "not_found", "没找到这只 Bee"}
          {:error, code, msg} -> {:error, code, msg}
        end

      :leave ->
        handover = Map.get(intent, :handover_to)

        case leave(cid, actor["id"], handover_to: handover) do
          {:ok, _} ->
            reply = if handover, do: "已把 Queen 交接给「#{handover}」，你已退出。", else: "你已退出蜂群。"

            {:ok,
             %{
               "reply" => reply,
               "actions" => [%{"type" => "refresh", "colony_id" => cid}],
               "colony_id" => cid
             }}

          {:error, code, msg} ->
            {:error, code, msg}
        end

      :dissolve ->
        case dissolve(cid, actor_bee_id: actor["id"]) do
          {:ok, %{"name" => name}} ->
            {:ok,
             %{
               "reply" => "已归档并解散蜂群「#{name}」。",
               "actions" => [%{"type" => "dissolved", "colony_id" => cid}],
               "colony_id" => cid
             }}

          {:error, code, msg} ->
            {:error, code, msg}
        end

      :handover ->
        case find_bee_by_display(cid, Map.get(intent, :to)) do
          {:ok, successor} ->
            :ok = handover_queen(colony, successor)

            {:ok,
             %{
               "reply" => "已把 Queen 交接给「" <> successor["display"] <> "」。",
               "actions" => [%{"type" => "refresh", "colony_id" => cid}],
               "colony_id" => cid
             }}

          {:error, :not_found} ->
            {:error, "not_found", "没找到「" <> to_string(Map.get(intent, :to)) <> "」，先把 TA 加进来再说"}
        end

      :switch ->
        target = find_colony_by_name(Map.get(intent, :to))

        case target do
          {:ok, c} ->
            {:ok,
             %{
               "reply" => "已切换到「#{c["name"]}」。",
               "actions" => [%{"type" => "switch", "colony_id" => c["id"], "name" => c["name"]}],
               "colony_id" => c["id"]
             }}

          :error ->
            {:error, "not_found", "没有找到「#{Map.get(intent, :to)}」这个蜂群"}
        end

      :dispatch ->
        title = Map.get(intent, :title)
        assignee_display = Map.get(intent, :assignee)

        upload_ids = Keyword.get(opts, :upload_ids, [])

        attrs = %{
          "title" => title,
          "actor_bee_id" => actor["id"],
          "source" => "user",
          "upload_ids" => upload_ids,
          "upload_sid" => actor["session_id"]
        }

        case create_task(cid, attrs) do
          {:ok, task} ->
            case assignee_display && find_bee_by_display(cid, assignee_display) do
              {:ok, bee} ->
                task = assign_and_deliver(cid, task, bee, upload_ids, actor["session_id"])

                {:ok,
                 %{
                   "reply" => "已把「#{task["title"]}」派给「#{bee["display"]}」。",
                   "actions" => [%{"type" => "task", "task_id" => task["id"]}],
                   "colony_id" => cid
                 }}

              _ ->
                {:ok,
                 %{
                   "reply" => "已建任务「#{task["title"]}」，作为刺激广播；有能力的 Bee 会自动领取。",
                   "actions" => [%{"type" => "task", "task_id" => task["id"]}],
                   "colony_id" => cid
                 }}
            end

          {:error, code, msg} ->
            {:error, code, msg}
        end

      :decompose ->
        context_task_id =
          (opts |> Keyword.get(:context) |> normalize_context())["task_id"] ||
            latest_active_task_id(cid)

        if is_binary(context_task_id) do
          case decompose_task(cid, context_task_id, Map.get(intent, :children), bee_id: actor["id"]) do
            {:ok, children} ->
              {:ok,
               %{
                 "reply" =>
                   "已拆出 #{length(children)} 个子任务：" <>
                     Enum.map_join(children, "、", &"「#{&1["title"]}」"),
                 "actions" => [%{"type" => "task", "task_id" => context_task_id}],
                 "colony_id" => cid
               }}

            {:error, code, msg} ->
              {:error, code, msg}
          end
        else
          {:error, "no_task", "当前没有可拆分的任务"}
        end

      :accept ->
        review_latest(cid, actor, "accept")

      :reject ->
        review_latest(cid, actor, "reject")

      _ ->
        {:ok, %{"reply" => nil, "actions" => [], "colony_id" => cid}}
    end
  end

  defp review_latest(cid, actor, verdict) do
    case latest_reviewable_honey(cid) do
      {:ok, honey} ->
        {:ok, _} = review_honey(cid, honey["id"], verdict, bee_id: actor["id"])

        reply =
          if verdict == "accept",
            do: "已验收「#{honey["title"]}」✅",
            else: "已打回「#{honey["title"]}」，产出方可按意见重做。"

        {:ok,
         %{
           "reply" => reply,
           "actions" => [%{"type" => "honey", "honey_id" => honey["id"]}],
           "colony_id" => cid
         }}

      :none ->
        {:error, "not_found", "当前没有待验收的成果"}
    end
  end

  defp assign_and_deliver(cid, task, bee, upload_ids, upload_sid) do
    task =
      task
      |> Map.put("assigned_bee_id", bee["id"])
      |> Map.put("status", "claimed")
      |> Map.put("claimed_at", now_ms())
      |> Map.put("heartbeat_at", now_ms())
      |> Map.put("revision", Map.get(task, "revision", 0) + 1)
      |> Map.put("updated_at", now_ms())

    :ok = Store.put_task(task)

    trace(cid, %{
      "type" => "task",
      "bee_id" => bee["id"],
      "task_id" => task["id"],
      "text" => "「#{bee["display"]}」被指派任务「#{task["title"]}」"
    })

    public_task_status(cid, task, bee, "已接受任务「#{task["title"]}」，正在处理。")

    maybe_deliver_task(Store.get_colony(cid) |> elem(1), task, upload_ids, upload_sid)
    task
  end

  defp public_task_status(cid, task, bee, text) do
    trace(cid, %{
      "type" => "message",
      "channel" => "colony",
      "bee_id" => bee["id"],
      "task_id" => task["id"],
      "text" => text,
      "data" => %{"status" => "working", "task_id" => task["id"]}
    })
  end

  # ───────────────────────── 视图 ─────────────────────────

  @doc "蜂群总览（前端轮询用）：成员、任务树、成果、信号、Trace、统计。"
  def view(colony_id) do
    with {:ok, colony} <- fetch_colony(colony_id) do
      bees = Store.bees_for_colony(colony_id)
      tasks = Store.tasks_for_colony(colony_id)
      honey = Store.honey_for_colony(colony_id)
      signals = Store.signals_for_colony(colony_id, limit: 40)
      trace = Store.trace_for_colony(colony_id, limit: 200, channel: "colony")
      now = now_ms()

      {:ok,
       %{
         "colony" => colony,
         "members" => Enum.map(bees, &bee_view(&1, tasks)),
         "tasks" => Enum.map(tasks, &Task.public(&1, now)),
         "task_tree" => Task.tree(tasks),
         "honey" => %{
           "counts" => honey_counts(honey),
           "recent" => Enum.map(Enum.take(honey, 20), &Honey.public/1)
         },
         "signals" => Enum.map(signals, &Signal.public_view/1),
         "trace" => trace,
         "stats" => colony_stats(colony_id)
       }}
    end
  end

  @doc "任务深钻：子树 + 该任务相关 Trace。"
  def drill(colony_id, task_id) do
    with {:ok, _} <- fetch_colony(colony_id),
         {:ok, task} <- fetch_task(task_id) do
      tasks = Store.tasks_for_colony(colony_id)
      ids = subtree_ids(task_id, tasks)
      subtree_tasks = Enum.filter(tasks, &(Map.get(&1, "id") in ids))
      now = now_ms()

      {:ok,
       %{
         "task" => Task.public(task, now),
         "subtree" => Task.tree(Enum.filter(tasks, &(&1["id"] in ids))),
         "tasks" => Enum.map(subtree_tasks, &Task.public(&1, now)),
         "trace" => Store.trace_for_colony(colony_id, task_id: task_id, limit: 100),
         "children_trace" =>
           Enum.flat_map(subtree_tasks, fn t ->
             if t["id"] == task_id,
               do: [],
               else: Store.trace_for_colony(colony_id, task_id: t["id"], limit: 40)
           end)
       }}
    end
  end

  @doc "Bee 工作轨迹（一对一视图）：与这只 Bee 相关的 Trace。"
  def bee_trail(colony_id, bee_id) do
    with {:ok, _} <- fetch_colony(colony_id),
         {:ok, bee} <- fetch_bee(bee_id) do
      trace = Store.trace_for_colony(colony_id, bee_id: bee_id, limit: 200)
      tasks = Store.tasks_for_colony(colony_id)
      now = now_ms()

      owned =
        Enum.filter(
          tasks,
          &(Map.get(&1, "assigned_bee_id") == bee_id or
              Map.get(&1, "coordinator_bee_id") == bee_id)
        )

      # 任务的活跃优先、最近更新优先（历史任务在 UI 里折叠）
      owned =
        owned
        |> Enum.sort_by(fn t ->
          {if(Task.terminal?(t), do: 1, else: 0), -Map.get(t, "updated_at", 0)}
        end)

      {:ok,
       %{
         "bee" => Bee.public(bee),
         "tasks" => Enum.map(owned, &Task.public(&1, now)),
         "conversations" => conversations_view(bee),
         "trace" => trace
       }}
    end
  end

  @doc """
  给 Bee 新建一个对话（真实会话）。新对话成为它当前的会话，之后消息/任务都投递到这里。
  """
  def new_conversation(colony_id, bee_id, opts \\ []) do
    with {:ok, colony} <- fetch_colony(colony_id),
         {:ok, bee} <- fetch_bee(bee_id) do
      cond do
        not session_runtime?() ->
          {:error, "unavailable", "会话运行时不可用，无法新建对话"}

        bee["kind"] != "ai" ->
          {:error, "bad_request", "真人成员的对话由对方创建，蜂群里只能记录消息"}

        true ->
          cwd = Keyword.get(opts, :cwd) || Map.get(bee, "cwd")

          case Newbee.Web.Session.ensure(nil, cwd) do
            {:ok, _pid, sid} ->
              # 保留历史对话：老记录没有 conversations 字段时用 bee_conversations/1 回退
              conversations =
                bee_conversations(bee)
                |> Enum.reject(&(&1 == sid))
                |> then(&[sid | &1])

              bee = bee |> Map.put("conversations", conversations) |> Map.put("session_id", sid)
              :ok = Store.put_bee(bee)

              trace(colony["id"], %{
                "type" => "lifecycle",
                "channel" => "dm",
                "bee_id" => bee_id,
                "to_bee_id" => bee_id,
                "text" => "给「#{bee["display"]}」开了一个新对话"
              })

              {:ok, %{"bee" => Bee.public(bee), "sessionId" => sid, "colony" => colony["id"]}}

            other ->
              {:error, "session_error", inspect(other)}
          end
      end
    end
  end

  @doc "把 Bee 的当前会话切到某个已有对话（切换后消息与任务投递都走这条）。"
  def select_conversation(colony_id, bee_id, session_id) do
    with {:ok, _colony} <- fetch_colony(colony_id),
         {:ok, bee} <- fetch_bee(bee_id),
         true <- is_binary(session_id) and session_id != "" do
      conversations = bee_conversations(bee)

      if session_id in conversations do
        bee = Map.put(bee, "session_id", session_id)
        :ok = Store.put_bee(bee)
        {:ok, %{"bee" => Bee.public(bee), "sessionId" => session_id}}
      else
        {:error, "not_found", "这条对话不属于该 Bee"}
      end
    else
      false -> {:error, "bad_request", "需要 sessionId"}
      {:error, code, msg} -> {:error, code, msg}
    end
  end

  @doc "给一条 AI 私有对话改名（写会话元数据，列表与内嵌界面共用同一标题）。"
  def rename_conversation(colony_id, bee_id, session_id, title) do
    title = if is_binary(title), do: String.trim(title), else: ""

    with {:ok, _colony} <- fetch_colony(colony_id),
         {:ok, bee} <- fetch_bee(bee_id) do
      cond do
        not (is_binary(session_id) and session_id != "") ->
          {:error, "bad_request", "需要 sessionId"}

        title == "" ->
          {:error, "bad_request", "名称不能为空"}

        bee["kind"] != "ai" ->
          {:error, "bad_request", "真人对话由对方命名，蜂群里只能记消息"}

        session_id not in bee_conversations(bee) ->
          {:error, "not_found", "这条对话不属于该 Bee"}

        true ->
          _ = Newbee.Session.rename(session_id, title)
          {:ok, %{"sessionId" => session_id, "title" => title}}
      end
    end
  end

  @doc "删除一条 AI 私有对话：销毁真实会话，并从 Bee 的对话列表移除。"
  def delete_conversation(colony_id, bee_id, session_id) do
    with {:ok, _colony} <- fetch_colony(colony_id),
         {:ok, bee} <- fetch_bee(bee_id) do
      cond do
        not (is_binary(session_id) and session_id != "") ->
          {:error, "bad_request", "需要 sessionId"}

        bee["kind"] != "ai" ->
          {:error, "bad_request", "真人对话没有会话，无法删除"}

        session_id not in bee_conversations(bee) ->
          {:error, "not_found", "这条对话不属于该 Bee"}

        session_busy?(session_id) ->
          {:error, "busy", "对话正在运行中，无法删除。请先等待完成。"}

        true ->
          remaining = Enum.reject(bee_conversations(bee), &(&1 == session_id))

          next_current =
            if bee["session_id"] == session_id, do: List.first(remaining), else: bee["session_id"]

          bee =
            bee
            |> Map.put("conversations", remaining)
            |> Map.put("session_id", next_current)

          :ok = Store.put_bee(bee)

          # 对话登记也一并清掉（工作执行会话不在此路径，永远不会被删）。
          case Store.get("conversations", session_id) do
            {:ok, %{"visibility" => "work"}} -> :ok
            {:ok, _} -> _ = Store.delete("conversations", session_id)
            _ -> :ok
          end

          _ = Newbee.Web.Session.destroy(session_id)

          trace(colony_id, %{
            "type" => "lifecycle",
            "channel" => "dm",
            "bee_id" => bee_id,
            "to_bee_id" => bee_id,
            "text" => "删除了该 Bee 的一条私有对话"
          })

          {:ok, %{"sessionId" => session_id, "bee" => Bee.public(bee)}}
      end
    end
  end

  # 对话列表：Bee 的会话 + 会话元信息（标题/消息数/活跃时间），当前会话置顶标记
  defp conversations_view(bee) do
    ids = bee_conversations(bee)
    if ids == [], do: [], else: do_conversations_view(bee, ids)
  end

  # 兼容早期记录：没有 conversations 字段时，退化成它绑定的那一条会话
  defp bee_conversations(bee) do
    case List.wrap(bee["conversations"]) do
      [] ->
        case Map.get(bee, "session_id") do
          sid when is_binary(sid) and sid != "" -> [sid]
          _ -> []
        end

      list ->
        list
    end
  end

  defp do_conversations_view(bee, ids) do
    metas =
      try do
        {list, _total} = Newbee.Session.list_page(200, 0)
        Map.new(list, fn m -> {m[:id] || m["id"], m} end)
      rescue
        _ -> %{}
      end

    current = bee["session_id"]

    ids
    # 已删除的会话不再出现在对话列表里（会话索引是唯一事实来源）。
    |> Enum.filter(fn sid ->
      Map.has_key?(metas, sid) or match?({:ok, _}, session_lookup(sid))
    end)
    |> Enum.map(fn sid ->
      meta = Map.get(metas, sid) || %{}

      %{
        "id" => sid,
        "title" => (meta[:title] || meta["title"] || "新对话") |> to_string(),
        "messages" => meta[:messages] || meta["messages"] || 0,
        "when" => meta[:when_str] || meta["when_str"] || "",
        "updated_at" => meta[:updated_at] || meta["updated_at"],
        "running" => match?({:ok, _}, session_lookup(sid)),
        "busy" => session_busy?(sid),
        "visibility" => conversation_visibility(sid),
        "current" => sid == current
      }
    end)
    |> Enum.sort_by(fn c -> {if(c["current"], do: 0, else: 1), -(c["updated_at"] || 0)} end)
  end

  # 私有对话 = Bee 自己的会话；工作执行会话由 Runtime/Remote 登记为 work。
  defp conversation_visibility(sid) do
    case Store.get("conversations", sid) do
      {:ok, %{"visibility" => v}} when is_binary(v) -> v
      _ -> "private"
    end
  end

  defp session_lookup(sid) do
    if session_runtime?(), do: Newbee.Web.Session.lookup(sid), else: :error
  rescue
    _ -> :error
  end

  defp session_busy?(sid) do
    if session_runtime?(), do: Newbee.Web.Session.peek_busy(sid), else: false
  rescue
    _ -> false
  end

  defp subtree_ids(root_id, tasks) do
    children = Enum.group_by(tasks, &Map.get(&1, "parent_task_id"))

    walk = fn walk, id ->
      [id | Enum.flat_map(Map.get(children, id, []), fn c -> walk.(walk, c["id"]) end)]
    end

    walk.(walk, root_id) |> Enum.uniq()
  end

  # ───────────────────────── 会话投递 ─────────────────────────

  @doc """
  把任务尽力投递到 AI Bee 绑定的会话。返回 :ok | :no_session | :unavailable。

  upload_ids 非空时按主界面同款路径投递：Newbee.Upload.prepare_prompt 把附件里的图片
  转成 data URL（多模态），其余文件以 local_path 形式写进提示词。
  """
  def deliver_to_session(bee, text, upload_ids \\ [], upload_sid \\ nil) do
    sid = Map.get(bee, "session_id")

    cond do
      not is_binary(sid) or sid == "" ->
        :no_session

      not session_runtime?() ->
        :unavailable

      true ->
        case Newbee.Web.Session.lookup(sid) do
          {:ok, pid} ->
            deliver_prompt(pid, upload_sid || sid, text, upload_ids)

          _ ->
            :no_session
        end
    end
  rescue
    _ -> :unavailable
  end

  # 无附件：纯文本投递（与既有行为一致）
  defp deliver_prompt(pid, _sid, text, []), do: prompt_session(pid, text)

  # 有附件：图片走多模态，普通文件写 local_path（与 session.promptAttachments 同路径）
  defp deliver_prompt(pid, sid, text, upload_ids) do
    case Newbee.Upload.prepare_prompt(sid, upload_ids, text) do
      {:ok, %{images: []} = prepared} -> prompt_session(pid, prepared.text)
      {:ok, %{images: images} = prepared} -> prompt_images_session(pid, images, prepared.text)
      _ -> prompt_session(pid, text)
    end
  rescue
    _ -> prompt_session(pid, text)
  end

  defp prompt_session(pid, text) do
    Newbee.Web.Session.prompt(pid, text)
    :ok
  end

  defp prompt_images_session(pid, images, text) do
    Newbee.Web.Session.prompt_images(pid, images, text)
    :ok
  end

  # 附件元信息（写入 Trace 供前端渲染；sid 为上传归属会话）
  defp attachments_data(_sid, []), do: %{}

  defp attachments_data(sid, upload_ids) when is_binary(sid) do
    items =
      upload_ids
      |> Enum.map(fn id ->
        case Newbee.Upload.info(sid, id) do
          {:ok, item} ->
            Map.take(item, ["id", "name", "content_type", "size", "image", "path"])

          _ ->
            nil
        end
      end)
      |> Enum.reject(&is_nil/1)

    if items == [], do: %{}, else: %{"attachments" => items}
  end

  defp attachments_data(_sid, _ids), do: %{}

  defp normalize_upload_ids(ids) when is_list(ids) do
    ids
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.take(8)
  end

  defp normalize_upload_ids(_), do: []

  defp maybe_deliver_task(colony, task, upload_ids, upload_sid) do
    bee_id = task["assigned_bee_id"]

    with true <- is_binary(bee_id),
         {:ok, bee} <- Store.get_bee(bee_id),
         true <- bee["kind"] == "ai" do
      case deliver_to_session(bee, task_prompt(colony, task, nil), upload_ids, upload_sid) do
        :ok ->
          trace(colony["id"], %{
            "type" => "command",
            "channel" => "task",
            "bee_id" => bee["id"],
            "task_id" => task["id"],
            "text" => "任务已投递到「#{bee["display"]}」的会话",
            "data" => %{"delivered" => true}
          })

        _ ->
          trace(colony["id"], %{
            "type" => "command",
            "channel" => "task",
            "bee_id" => bee["id"],
            "task_id" => task["id"],
            "text" => "「#{bee["display"]}」暂未绑定可投递的会话，任务已记录待领取",
            "data" => %{"delivered" => false}
          })
      end
    end

    :ok
  end

  defp maybe_deliver_signal(signal) do
    with bee_id when is_binary(bee_id) <- signal["to_bee_id"],
         {:ok, bee} <- Store.get_bee(bee_id),
         "ai" <- bee["kind"] do
      deliver_to_session(bee, "[蜂群信号·#{signal["kind"]}] #{Signal.describe(signal)}")
    end

    :ok
  end

  defp session_runtime? do
    Code.ensure_loaded?(Newbee.Web.Session) and
      is_pid(Process.whereis(Newbee.Web.SessionRegistry))
  end

  defp task_prompt(colony, task, extra) do
    base = """
    【蜂群任务】#{colony["name"]} · #{task["title"]}
    任务 ID：#{task["id"]}
    说明：#{task["description"]}
    要求：#{Enum.join(Map.get(task, "requires", []), "、")}
    完成后请汇报结果（成果、测试情况、遗留问题）。
    """

    if extra, do: base <> "\n补充指令：" <> extra, else: base
  end

  # ───────────────────────── 演示数据 ─────────────────────────

  @doc "写入演示蜂群（幂等；用于原型/联调）。"
  def seed_demo do
    case find_colony_by_name("认证系统重构") do
      {:ok, existing} ->
        {:ok, existing}

      :error ->
        {:ok, colony} = create_colony(%{"name" => "认证系统重构", "goal" => "重构认证系统并补齐测试"})
        cid = colony["id"]

        {:ok, auth_bot} =
          add_bee(cid, %{
            "display" => "auth-bot",
            "kind" => "ai",
            "capabilities" => ["edit", "shell", "test"]
          })

        {:ok, test_bot} =
          add_bee(cid, %{
            "display" => "test-bot",
            "kind" => "ai",
            "capabilities" => ["test", "shell"]
          })

        {:ok, data_bot} =
          add_bee(cid, %{
            "display" => "data-bot",
            "kind" => "ai",
            "capabilities" => ["research", "shell"]
          })

        {:ok, bob} = add_bee(cid, %{"display" => "bob", "kind" => "human"})

        :ok = Store.put_bee(Map.put(auth_bot, "status", "working"))

        {:ok, login_task} =
          create_task(cid, %{
            "title" => "重构 login 模块",
            "description" => "抽离 token 刷新逻辑，补齐测试",
            "requires" => ["edit", "shell"],
            "assignee_display" => "auth-bot",
            "actor_bee_id" => colony["queen_bee_id"]
          })

        login_task =
          Map.merge(login_task, %{"status" => "running", "revision" => login_task["revision"] + 1})

        :ok = Store.put_task(login_task)

        {:ok, _honey} =
          add_honey(cid, %{
            "task_id" => login_task["id"],
            "bee_id" => auth_bot["id"],
            "kind" => "source",
            "title" => "login 模块重构",
            "content" => "auth/login.ex 抽离 refresh_token/0；mix test 14 passed",
            "checks" => [%{"check" => "test_pass", "ok" => true}]
          })

        {:ok, session_task} =
          create_task(cid, %{
            "title" => "session 模块重构",
            "description" => "按 login 的模式重构 session",
            "requires" => ["edit", "shell"],
            "assignee_display" => "auth-bot",
            "actor_bee_id" => colony["queen_bee_id"]
          })

        session_task =
          Map.merge(session_task, %{
            "status" => "running",
            "revision" => session_task["revision"] + 1
          })

        :ok = Store.put_task(session_task)

        {:ok, _child} =
          decompose_task(
            cid,
            login_task["id"],
            [%{"title" => "token 刷新子任务", "requires" => ["edit"]}],
            bee_id: auth_bot["id"]
          )

        {:ok, _} =
          emit_signal(cid, %{
            "kind" => "report",
            "from_bee_id" => auth_bot["id"],
            "payload" => %{"text" => "login 模块完成，已自测通过，待 Queen 验收"},
            "task_id" => login_task["id"]
          })

        {:ok, _} =
          emit_signal(cid, %{
            "kind" => "recommend",
            "from_bee_id" => data_bot["id"],
            "quality" => 0.8,
            "payload" => %{"text" => "发现缓存方案可优化 session 读取"},
            "task_id" => session_task["id"]
          })

        {:ok, _} =
          emit_signal(cid, %{
            "kind" => "rebalance",
            "from_bee_id" => test_bot["id"],
            "payload" => %{"text" => "测试队列积压，招募一只 Bee 支援"},
            "task_id" => session_task["id"]
          })

        trace(cid, %{
          "type" => "message",
          "channel" => "colony",
          "bee_id" => bob["id"],
          "text" => "login 模块我看了，token 刷新建议抽出来，其余 OK"
        })

        trace(cid, %{
          "type" => "message",
          "channel" => "colony",
          "bee_id" => colony["queen_bee_id"],
          "text" => "好，抽完给我看下。"
        })

        {:ok, colony}
    end
  end

  # ───────────────────────── 内部工具 ─────────────────────────

  defp trace(colony_id, attrs) do
    attrs
    |> Map.put("colony_id", colony_id)
    |> Trace.entry()
    |> Store.append_trace()
  end

  defp fetch_colony(id) do
    case Store.get_colony(id) do
      {:ok, c} -> {:ok, c}
      {:error, :not_found} -> {:error, "not_found", "蜂群不存在"}
    end
  end

  defp fetch_bee(id) do
    case Store.get_bee(id) do
      {:ok, b} -> {:ok, b}
      {:error, :not_found} -> {:error, "not_found", "Bee 不存在"}
    end
  end

  defp fetch_task(id) do
    case Store.get_task(id) do
      {:ok, t} -> {:ok, t}
      {:error, :not_found} -> {:error, "not_found", "任务不存在"}
    end
  end

  defp fetch_honey(id) do
    case Store.get_honey(id) do
      {:ok, h} -> {:ok, h}
      {:error, :not_found} -> {:error, "not_found", "成果不存在"}
    end
  end

  defp require_queen(colony, actor_id) do
    cond do
      is_nil(actor_id) -> :ok
      actor_id == colony["queen_bee_id"] -> :ok
      true -> {:error, "forbidden", "只有 Queen 能做这个操作"}
    end
  end

  defp require_same_colony(bee, colony_id) do
    if Map.get(bee, "colony_id") == colony_id,
      do: :ok,
      else: {:error, "not_found", "Bee 不属于该蜂群"}
  end

  defp resolve_actor(colony, opts) do
    case Keyword.get(opts, :actor_bee_id) do
      nil ->
        case Store.get_bee(colony["queen_bee_id"]) do
          {:ok, queen} -> {:ok, queen}
          _ -> {:error, "not_found", "蜂群没有 Queen"}
        end

      id ->
        fetch_bee(id)
    end
  end

  defp normalize_context(context) when is_map(context) do
    %{
      "bee_id" => Map.get(context, "bee_id") || Map.get(context, "beeId"),
      "task_id" => Map.get(context, "task_id") || Map.get(context, "taskId")
    }
  end

  defp normalize_context(_), do: %{"bee_id" => nil, "task_id" => nil}

  defp context_scope(%{"bee_id" => bee_id, "task_id" => _}) when is_binary(bee_id), do: :bee

  defp context_scope(%{"task_id" => task_id}) when is_binary(task_id), do: :task
  defp context_scope(_), do: :colony

  defp resolve_task_bee(colony, task) do
    candidates = [Map.get(task, "assigned_bee_id"), Map.get(task, "coordinator_bee_id")]

    Enum.find_value(candidates, {:error, "not_found", "任务没有可对话的 Bee"}, fn id ->
      if is_binary(id) do
        case Store.get_bee(id) do
          {:ok, bee} -> {:ok, bee}
          _ -> nil
        end
      end
    end)
  end

  defp maybe_assign(task, nil, _colony_id), do: task

  defp maybe_assign(task, display, colony_id) do
    case find_bee_by_display(colony_id, display) do
      {:ok, bee} ->
        now = now_ms()

        task
        |> Map.put("assigned_bee_id", bee["id"])
        |> Map.put("status", "claimed")
        |> Map.put("claimed_at", now)
        |> Map.put("heartbeat_at", now)

      _ ->
        task
    end
  end

  defp find_bee_by_display(colony_id, display) when is_binary(display) do
    display = String.trim(display)

    bees = Store.bees_for_colony(colony_id)

    found =
      Enum.find(bees, fn b -> Map.get(b, "display") == display end) ||
        Enum.find(bees, fn b -> String.contains?(Map.get(b, "display", ""), display) end)

    if found, do: {:ok, found}, else: {:error, :not_found}
  end

  defp find_bee_by_display(_, _), do: {:error, :not_found}

  defp find_colony_by_name(name) when is_binary(name) do
    name = String.trim(name)

    case Enum.find(Store.list_colonies(), fn c -> c["name"] == name end) ||
           Enum.find(Store.list_colonies(), fn c -> String.contains?(c["name"], name) end) do
      nil -> :error
      c -> {:ok, c}
    end
  end

  defp find_colony_by_name(_), do: :error

  defp latest_reviewable_honey(cid) do
    Store.honey_for_colony(cid)
    |> Enum.find(fn h ->
      get_in(h, ["review", "state"]) in ["pending_review", "auto_verified"]
    end)
    |> case do
      nil -> :none
      h -> {:ok, h}
    end
  end

  defp latest_active_task_id(cid) do
    Store.tasks_for_colony(cid)
    |> Enum.filter(fn t -> Map.get(t, "status") in ["claimed", "running", "blocked"] end)
    |> List.last()
    |> case do
      nil -> nil
      t -> t["id"]
    end
  end

  defp reflow_tasks(colony_id, bee_id) do
    Store.tasks_for_colony(colony_id)
    |> Enum.filter(fn t -> Map.get(t, "assigned_bee_id") == bee_id and not Task.terminal?(t) end)
    |> Enum.each(fn t ->
      Store.update(
        "tasks",
        t["id"],
        nil,
        &{:ok,
         Map.merge(&1, %{
           "status" => "blocked",
           "approval_required" => true,
           "next_step" => "负责人已离开，需核对已发生操作后重新安排；不会自动重放。"
         })}
      )

      Store.put("controls", %{
        "id" => Newbee.Colony.Control.key(colony_id, "work", t["id"]),
        "colony_id" => colony_id,
        "scope" => "work",
        "target_id" => t["id"],
        "paused" => true,
        "revision" => 1,
        "updated_at" => now_ms()
      })

      case Newbee.Web.Session.lookup(t["session_id"]) do
        {:ok, pid} -> Newbee.Web.Session.interrupt(pid)
        _ -> :ok
      end

      trace(colony_id, %{
        "type" => "task",
        "bee_id" => bee_id,
        "task_id" => t["id"],
        "text" => "任务「#{t["title"]}」因执行者离开保留，等待核对与重新安排"
      })
    end)
  end

  defp maybe_bind_session(attrs, "ai") do
    should_bind = Map.get(attrs, "bind_session") == true

    if should_bind and session_runtime?() do
      case Newbee.Web.Session.ensure(nil, Map.get(attrs, "cwd")) do
        {:ok, _pid, sid} -> Map.put(attrs, "session_id", sid)
        _ -> attrs
      end
    else
      attrs
    end
  rescue
    _ -> attrs
  end

  defp maybe_bind_session(attrs, _), do: attrs

  defp normalize_kind(kind, display),
    do:
      Newbee.Colony.Bee.infer_kind(display)
      |> then(fn inferred ->
        case kind do
          "ai" -> "ai"
          "human" -> "human"
          _ -> inferred
        end
      end)

  defp colony_stats(colony_id) do
    bees = Store.bees_for_colony(colony_id)
    tasks = Store.tasks_for_colony(colony_id)
    honey = Store.honey_for_colony(colony_id)

    open = Enum.count(tasks, &(not Task.terminal?(&1)))
    done = Enum.count(tasks, &(Map.get(&1, "status") == "done"))
    accepted = Enum.count(honey, &(get_in(&1, ["review", "state"]) == "accepted"))

    pending_review =
      Enum.count(honey, &(get_in(&1, ["review", "state"]) in ["pending_review", "auto_verified"]))

    working =
      tasks
      |> Enum.filter(&(&1["status"] == "running"))
      |> Enum.map(& &1["assigned_bee_id"])
      |> Enum.uniq()
      |> length()

    total = max(1, length(honey))

    %{
      "members" => length(bees),
      "working" => working,
      "tasks_open" => open,
      "tasks_done" => done,
      "honey_total" => length(honey),
      "honey_accepted" => accepted,
      "honey_pending_review" => pending_review,
      "progress" => Float.round(accepted / total, 2)
    }
  end

  defp bee_view(bee, tasks) do
    active =
      Enum.count(tasks, fn t ->
        Map.get(t, "assigned_bee_id") == bee["id"] and not Task.terminal?(t)
      end)

    status =
      cond do
        Map.get(bee, "status") == "offline" ->
          "offline"

        Enum.any?(tasks, &(&1["assigned_bee_id"] == bee["id"] and &1["status"] == "running")) ->
          "working"

        true ->
          "idle"
      end

    bee |> Bee.public() |> Map.put("active_tasks", active) |> Map.put("status", status)
  end

  defp honey_counts(honey) do
    base = %{"pending_review" => 0, "auto_verified" => 0, "accepted" => 0, "rejected" => 0}

    Enum.reduce(honey, base, fn h, acc ->
      state = get_in(h, ["review", "state"]) || "pending_review"
      Map.update(acc, state, 1, &(&1 + 1))
    end)
  end

  defp help_reply do
    groups = Intent.capabilities()

    "我能帮你做这些（直接说一句就行）：\n" <>
      Enum.map_join(groups, "\n", fn g ->
        "#{g["icon"]} #{g["group"]} → " <> Enum.map_join(g["examples"], " / ", &"「#{&1}」")
      end)
  end

  defp progress_reply(cid) do
    stats = colony_stats(cid)
    honey = Store.honey_for_colony(cid)

    pending =
      Enum.filter(
        honey,
        &(get_in(&1, ["review", "state"]) in ["pending_review", "auto_verified"])
      )

    parts = [
      "目标进度 #{round(stats["progress"] * 100)}%。",
      "#{stats["members"]} 只 Bee，#{stats["working"]} 只在干活。",
      "任务：#{stats["tasks_open"]} 个待处理、#{stats["tasks_done"]} 个已完成。",
      "成果：#{stats["honey_accepted"]}/#{stats["honey_total"]} 已验收。"
    ]

    parts =
      if pending == [] do
        parts
      else
        parts ++ ["待你验收：#{Enum.map_join(pending, "、", &"「#{&1["title"]}」")}（说「通过」或「打回」）。"]
      end

    Enum.join(parts, " ")
  end

  defp task_created_text(task, colony) do
    if task["assigned_bee_id"] do
      "任务「#{task["title"]}」已创建并指派"
    else
      "任务「#{task["title"]}」已创建，作为刺激广播（蜂群：#{colony["name"]}）"
    end
  end

  defp transition_text("start"), do: "开始执行"
  defp transition_text("block"), do: "被阻塞"
  defp transition_text("unblock"), do: "解除阻塞"
  defp transition_text("complete"), do: "完成 ✅"
  defp transition_text("fail"), do: "失败 ✗"
  defp transition_text("cancel"), do: "取消"
  defp transition_text("release"), do: "回流待领取"
  defp transition_text(other), do: other

  defp review_state_label(honey) do
    case get_in(honey, ["review", "state"]) do
      "auto_verified" -> "自动预检通过"
      "pending_review" -> "待验收"
      "accepted" -> "已验收"
      "rejected" -> "已打回"
      other -> to_string(other)
    end
  end

  defp kind_label("ai"), do: "AI Bee"
  defp kind_label(_), do: "人 Bee"

  defp extract_colony_name(text) do
    case Regex.run(~r/(?:建|创建|新建|开)(?:一个|个)?(?:新)?群(?:做|干|叫|名为)?\s*([^\s,，。;；]*)/u, text) do
      [_, ""] -> @default_colony_name
      [_, name] -> String.trim(name)
      _ -> @default_colony_name
    end
  end

  defp default_queen_display do
    case System.get_env("USER") || System.get_env("USERNAME") do
      nil -> "我"
      "" -> "我"
      user -> user
    end
  end

  defp blank_to_nil(v) when is_binary(v),
    do: if(String.trim(v) == "", do: nil, else: String.trim(v))

  defp blank_to_nil(v), do: v

  defp scope_for(%{"scope" => "xhost"}), do: :xhost
  defp scope_for(_), do: :local

  defp fmt(f) when is_float(f), do: :erlang.float_to_binary(f, decimals: 2)
  defp fmt(f), do: to_string(f)

  defp now_ms, do: System.system_time(:millisecond)

  defp normalize_colony_name(value) when is_binary(value) do
    name = String.trim(value)

    cond do
      name == "" -> {:error, "bad_request", "蜂群名称不能为空"}
      String.length(name) > 80 -> {:error, "bad_request", "蜂群名称不能超过 80 个字符"}
      true -> {:ok, name}
    end
  end

  defp normalize_colony_name(_), do: {:error, "bad_request", "蜂群名称不能为空"}

  def rename_colony(colony_id, name, opts) do
    with {:ok, colony} <- fetch_colony(colony_id),
         :ok <- require_queen(colony, Keyword.get(opts, :actor_bee_id)),
         {:ok, name} <- normalize_colony_name(name) do
      renamed =
        colony
        |> Map.put("name", name)
        |> Map.put("updated_at", now_ms())

      :ok = Store.put_colony(renamed)

      trace(colony_id, %{
        "type" => "lifecycle",
        "bee_id" => Keyword.get(opts, :actor_bee_id),
        "text" => "蜂群改名：「" <> colony["name"] <> "」→「" <> name <> "」"
      })

      {:ok, renamed}
    end
  end
end
