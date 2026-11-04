defmodule Newbee.Colony.ConversationWork do
  @moduledoc "Conversation-owned work: durable request receipts, inputs and execution-bound questions."
  alias Newbee.Colony.{Store, Work, Bee, Id, Control, Trace, Decomposition}
  @terminal ~w(done failed cancelled)
  @max_text 100_000

  @doc "Start isolated work from an authenticated conversation, without creating a second conversation UI."
  def start(sid, root, text, request_id, opts \\ []) do
    with :ok <- text(sid, 96),
         :ok <- text(text, @max_text),
         :ok <- text(request_id, 180),
         :ok <- quiet_before_retry(%{"session_id" => sid}, "resume"),
         true <- is_binary(root) and File.dir?(root) do
      root = Path.expand(root)
      principal = Keyword.get(opts, :principal, :owner)

      config = %{
        "provider" => Newbee.Session.provider(sid),
        "model" => Newbee.Session.model(sid),
        "effort" => Newbee.Session.effort(sid)
      }

      command(
        sid,
        "start",
        request_id,
        %{
          text: text,
          root: root,
          uploads: Keyword.get(opts, :upload_ids, []),
          decompose: Keyword.get(opts, :decompose, true)
        },
        fn data ->
          with {:ok, data, colony, actor, bee} <- context(data, sid, root, principal),
               nil <- active_work(data, sid) do
            attrs = %{
              "title" => String.slice(String.trim(text), 0, 100),
              "description" => text,
              "actor_bee_id" => actor["id"],
              "cwd" => root,
              "workflow" => true,
              "decompose" => Keyword.get(opts, :decompose, true),
              "autonomous" => true,
              "conversation" => true,
              "origin_session_id" => sid,
              "source_root" => root,
              "source" => "conversation",
              "inputs" => [],
              "execution_generation" => 1,
              "consumed_context_revision" => 0,
              "execution_config" => config,
              "facts" => predecessor_facts(data, sid),
              "predecessor_id" => latest_done(data, sid),
              "request_id" => request_id,
              "upload_ids" => Keyword.get(opts, :upload_ids, []),
              "upload_sid" => sid
            }

            task = Work.build(colony, bee, attrs) |> Map.put("request_id", request_id)
            {data, task, input} = enqueue(data, task, text, request_id, attrs)
            {:ok, %{"work_id" => task["id"], "input_id" => input["id"]}, put_in(data, ["tasks", task["id"]], task)}
          else
            %{} -> {:error, "work_active", "本对话已有工作，请补充原工作，或另开对话"}
            error -> error
          end
        end
      )
    else
      false -> {:error, "workspace_missing", "请先为当前会话选择真实项目目录"}
      error -> error
    end
  end

  @doc "List only work originated in this conversation."
  def list(sid) do
    Store.list_tasks()
    |> Enum.filter(&(root?(&1) and &1["origin_session_id"] == sid))
    |> Enum.sort_by(& &1["created_at"], :desc)
    |> Enum.take(50)
    |> Enum.map(&view/1)
  end

  @doc "Server-side fallback for older clients; a live origin never silently starts a second foreground executor."
  def route(sid, body, request_id) do
    task =
      Store.list_tasks()
      |> Enum.find(&(root?(&1) and &1["origin_session_id"] == sid and &1["status"] not in @terminal))

    question = if is_map(task), do: view(task)["question"], else: nil

    cond do
      not is_map(task) -> :none
      not is_binary(body) or String.starts_with?(String.trim(body), ["/", "!"]) -> :none
      is_map(question) -> answer(sid, task["id"], question["id"], body, request_id)
      true -> input(sid, task["id"], body, request_id)
    end
  end

  def origin?(sid), do: Enum.any?(Store.list_tasks(), &(root?(&1) and &1["origin_session_id"] == sid))

  def active?(sid),
    do:
      Enum.any?(
        Store.list_tasks(),
        &(root?(&1) and &1["origin_session_id"] == sid and &1["status"] not in @terminal)
      )

  @doc "Overlay background facts on the existing session index; the Colony snapshot remains authoritative."
  def project_index(entries) do
    hidden =
      Store.list_tasks() |> Enum.filter(&(&1["conversation"] == true)) |> Enum.map(& &1["session_id"]) |> MapSet.new()

    entries = Enum.reject(entries, &MapSet.member?(hidden, &1["id"]))

    grouped =
      Store.list_tasks() |> Enum.filter(&root?/1) |> Enum.group_by(& &1["origin_session_id"])

    Enum.map(entries, fn entry ->
      case grouped[entry["id"]] do
        nil ->
          entry

        tasks ->
          latest = Enum.max_by(tasks, & &1["created_at"])

          count =
            Enum.reduce(tasks, 0, fn task, total ->
              total + Enum.count(task["inputs"] || [], &(&1["origin"] != "internal")) +
                if(is_binary(task["result"]), do: 1, else: 0)
            end)

          at = tasks |> Enum.map(&max(&1["updated_at"] || 0, &1["created_at"] || 0)) |> Enum.max() |> div(1000)

          entry
          |> Map.put("mtime", max(entry["mtime"] || 0, at))
          |> Map.put("background_title", latest["title"])
          |> Map.put("background_count", count)
      end
    end)
    |> Enum.sort_by(& &1["mtime"], :desc)
  end

  @doc "Resolve a work without allowing a different origin conversation to address it."
  def fetch(sid, id) do
    case Store.get_task(id) do
      {:ok, %{"conversation" => true, "origin_session_id" => ^sid} = task} ->
        if root?(task), do: {:ok, task}, else: {:error, "not_found", "请通过总任务操作子任务"}

      _ ->
        {:error, "not_found", "本对话没有这项工作"}
    end
  end

  @doc "Persist a follow-up together with its delivery; paused work stays paused."
  def input(sid, id, body, request_id, opts \\ []) do
    with :ok <- text(body, @max_text), :ok <- text(request_id, 180) do
      command(sid, "input", request_id, %{work: id, text: body, uploads: Keyword.get(opts, :upload_ids, [])}, fn data ->
        with {:ok, task} <- owned(data, sid, id), :ok <- editable(task) do
          task = task |> bump() |> Map.put("question", nil)

          task =
            if task["status"] == "pending_review",
              do: Map.merge(task, %{"status" => "claimed", "result" => nil}),
              else: task

          attrs = %{"upload_ids" => Keyword.get(opts, :upload_ids, []), "upload_sid" => sid}
          {data, task, input} = enqueue_followup(data, task, body, request_id, attrs)
          {:ok, %{"work_id" => id, "input_id" => input["id"]}, put_in(data, ["tasks", id], task)}
        end
      end)
    end
  end

  @doc "Answer exactly one current question, never a stale or another work's question."
  def answer(sid, id, question_id, body, request_id, opts \\ []) do
    with :ok <- text(body, @max_text), :ok <- text(request_id, 180) do
      command(
        sid,
        "answer",
        request_id,
        %{work: id, question: question_id, text: body, uploads: Keyword.get(opts, :upload_ids, [])},
        fn data ->
          with {:ok, task} <- owned(data, sid, id), :ok <- editable(task) do
            target = question_target(data, task, question_id)
            q = target && target["question"]

            if is_map(q) and q["state"] in [nil, "open"] do
              target = target |> bump() |> Map.merge(%{"question" => nil, "waiting_for" => nil, "status" => "claimed"})

              target =
                Map.put(
                  target,
                  "last_answer",
                  Map.merge(q, %{"state" => "answered", "answer" => body, "answered_at" => now()})
                )

              attrs = %{"upload_ids" => Keyword.get(opts, :upload_ids, []), "upload_sid" => sid}
              {data, target, input} = enqueue(data, target, body, request_id, attrs)
              data = put_in(data, ["tasks", target["id"]], target)

              if target["id"] == id do
                {:ok, %{"work_id" => id, "input_id" => input["id"]}, data}
              else
                task =
                  task |> bump() |> Map.update!("inputs", &(&1 ++ [Map.put(input, "delegated_work_id", target["id"])]))

                {:ok, %{"work_id" => id, "input_id" => input["id"]}, put_in(data, ["tasks", id], task)}
              end
            else
              {:error, "stale_question", "问题已变化或已经回答，请查看当前问题"}
            end
          end
        end
      )
    end
  end

  @doc "Pause, resume, stop or recover with a real Control gate and no blind second execution."
  def control(sid, id, action) when action in ~w(pause resume stop retry) do
    :global.trans({{__MODULE__, "control", id}, self()}, fn -> do_control(sid, id, action) end)
  end

  def control(_, _, _), do: {:error, "bad_request", "未知工作控制动作"}

  defp do_control(sid, id, action) do
    with {:ok, task} <- fetch(sid, id) do
      if action == "retry" and delegated_execution?(task) and
           not Control.blocked?(task["colony_id"], task["assigned_bee_id"], task["id"]) do
        retry_children(sid, task)
      else
        do_control_all(sid, id, action)
      end
    end
  end

  defp do_control_all(sid, id, action) do
    config = %{
      "provider" => Newbee.Session.provider(sid),
      "model" => Newbee.Session.model(sid),
      "effort" => Newbee.Session.effort(sid)
    }

    with {:ok, task} <- fetch(sid, id),
         {:ok, colony} <- Store.get_colony(task["colony_id"]),
         :ok <- allowed_control(task, action),
         :ok <- quiet_before_retry(task, action),
         {:ok, _} <- Control.set(colony["id"], "work", id, "interrupt", actor_bee_id: task["created_by"]),
         :ok <- refresh_for_resume(sid, task, action),
         {:ok, result} <-
           Store.transaction(fn data ->
             with {:ok, current} <- owned(data, sid, id) do
               cond do
                 action == "stop" ->
                   next =
                     current
                     |> bump()
                     |> Map.merge(%{
                       "status" => "cancelled",
                       "question" => nil,
                       "waiting_for" => nil,
                       "resume_needed" => false,
                       "next_step" => "已结束；已有改动保留，未撤回文件"
                     })

                   data = cancel_children(data, current)
                   {:ok, {:ok, %{"work_id" => id}}, put_in(data, ["tasks", id], next) |> settle(id, "cancelled")}

                 action == "pause" ->
                   next = Map.put(current, "next_step", "暂停请求已保存；已有输入和修改保留")
                   {:ok, {:ok, %{"work_id" => id}}, put_in(data, ["tasks", id], next)}

                 delegated_execution?(current) ->
                   {data, next} = resume_children(data, current, config)
                   {:ok, {:ok, %{"work_id" => id}}, put_in(data, ["tasks", id], next)}

                 true ->
                   generation = (current["execution_generation"] || 0) + 1
                   current = Map.put(current, "execution_config", config)

                   next =
                     current
                     |> bump()
                     |> Map.merge(%{
                       "status" => "claimed",
                       "execution_generation" => generation,
                       "next_step" => nil,
                       "waiting_for" => nil,
                       "resume_needed" => false
                     })

                   data = settle(data, id, "superseded")

                   {data, next, _} =
                     enqueue(
                       data,
                       next,
                       "从保存进度继续。读取pending_inputs、已有修改和已发生的外部操作；不重放旧工具调用。",
                       "resume:" <> Integer.to_string(generation),
                       %{"internal" => true}
                     )

                   {:ok, {:ok, %{"work_id" => id}}, put_in(data, ["tasks", id], next)}
               end
             end
           end) do
      if action in ["resume", "retry"] do
        with {:ok, _} <- Control.set(colony["id"], "work", id, "resume", actor_bee_id: task["created_by"]),
             do: response({:ok, result})
      else
        response({:ok, result})
      end
    end
  end

  @doc "Mark a delivered input as consumed only at an actual model-request boundary."
  def consumed(delivery_id) when is_binary(delivery_id) do
    with {:ok, delivery} <- Store.get("deliveries", delivery_id),
         {:ok, %{"conversation" => true}} <- Store.get_task(delivery["task_id"]) do
      consume_receipt(delivery_id)
    else
      _ -> :ok
    end
  end

  def consumed(_), do: :ok

  defp consume_receipt(delivery_id) do
    Store.transaction(fn data ->
      case get_in(data, ["deliveries", delivery_id]) do
        %{"task_id" => id} = delivery ->
          case get_in(data, ["tasks", id]) do
            %{"conversation" => true} = task ->
              if delivery["execution_generation"] == task["execution_generation"] do
                inputs =
                  Enum.map(task["inputs"] || [], fn input ->
                    if input["delivery_id"] == delivery_id or input["id"] in (delivery["input_ids"] || []),
                      do: Map.put(input, "consumed_at", now()),
                      else: input
                  end)

                next =
                  task
                  |> Map.put("inputs", inputs)
                  |> Map.put(
                    "consumed_context_revision",
                    max(task["consumed_context_revision"] || 0, delivery["context_revision"] || 0)
                  )

                data = data |> put_in(["tasks", id], next) |> put_in(["deliveries", delivery_id, "consumed_at"], now())

                data =
                  if task["conversation_child"] == true and is_map(data["tasks"][task["workflow_root"]]) do
                    update_in(data, ["tasks", task["workflow_root"], "inputs"], fn rows ->
                      Enum.map(rows || [], fn row ->
                        if row["delivery_id"] == delivery_id, do: Map.put(row, "consumed_at", now()), else: row
                      end)
                    end)
                  else
                    data
                  end

                {:ok, :ok, data}
              else
                {:error, "stale_execution", "输入属于过期执行代次"}
              end

            _ ->
              {:ok, :ok, data}
          end

        _ ->
          {:ok, :ok, data}
      end
    end)
  end

  @doc "Fence a late dispatch at the Session receiving boundary."
  def delivery_current?(delivery_id) do
    case Store.get("deliveries", delivery_id) do
      {:ok, delivery} ->
        case Store.get_task(delivery["task_id"]) do
          {:ok, %{"conversation" => true} = task} ->
            task["status"] not in @terminal and delivery["status"] == "dispatching" and
              delivery["execution_generation"] == task["execution_generation"]

          _ ->
            true
        end

      _ ->
        true
    end
  end

  @doc "Validate a turn result against the generation and consumed requirements."
  def current_event?(%{"conversation" => true} = task, kind, payload)
      when kind in [:done, :text_end, :ask, :error, :interrupted] do
    generation = Map.get(payload, :execution_generation) || Map.get(payload, "execution_generation")
    delivery_id = Map.get(payload, :delivery_id) || Map.get(payload, "delivery_id")

    case Store.get("deliveries", delivery_id) do
      {:ok, delivery} ->
        generation == task["execution_generation"] and delivery["task_id"] == task["id"] and
          delivery["status"] in ["accepted", "dispatching"]

      _ ->
        false
    end
  end

  def current_event?(_, _, _), do: true

  @doc "Persist one current question with a stable, execution-scoped identity."
  def question(task, payload) do
    q = Map.new(payload, fn {k, v} -> {to_string(k), v} end)
    id = "q:" <> task["id"] <> ":" <> Integer.to_string(task["execution_generation"] || 0) <> ":" <> hash(q)
    Map.merge(q, %{"id" => id, "state" => "open", "context_revision" => task["context_revision"]})
  end

  @doc "Public, derived presentation; never changes the input's sending destination."
  def view(task) do
    honey =
      case Store.get_honey(task["result"] || "") do
        {:ok, h} -> h
        _ -> nil
      end

    paused = Control.blocked?(task["colony_id"], task["assigned_bee_id"], task["id"])
    coordination = if Decomposition.managed?(task), do: Decomposition.view(task), else: nil
    children = if is_map(coordination), do: coordination["children"] || [], else: []

    question =
      task["question"] ||
        Enum.find_value(children, fn child ->
          if is_map(child["question"]),
            do: Map.merge(child["question"], %{"work_id" => child["id"], "task_title" => child["title"]})
        end)

    blocked_child =
      Enum.find(children, fn child ->
        child["status"] in ["blocked", "failed"] and child["waiting_for"] not in ["dependencies", "capacity"] and
          not is_map(child["question"])
      end)

    stage =
      cond do
        task["status"] == "done" ->
          "completed"

        task["status"] == "cancelled" and Control.state(task["colony_id"], "work", task["id"]) == "pausing" ->
          "stopping"

        task["status"] in @terminal ->
          "ended"

        paused ->
          Control.state(task["colony_id"], "work", task["id"])

        is_map(question) ->
          "needs_answer"

        task["status"] == "pending_review" ->
          "needs_review"

        task["status"] == "blocked" and String.contains?(task["next_step"] || "", "回执") ->
          "unknown"

        is_map(blocked_child) ->
          "blocked"

        Decomposition.managed?(task) and task["waiting_for"] == "children" ->
          "working"

        task["status"] in ~w(blocked failed) ->
          "blocked"

        task["status"] in ~w(pending claimed) ->
          "queued"

        task["status"] == "running" ->
          "working"

        true ->
          "waiting"
      end

    result = if honey, do: Map.take(honey, ~w(id content evidence limitations work_revision)), else: nil

    task
    |> Map.take(
      ~w(id title status origin_session_id source_root question activity next_step revision context_revision execution_generation inputs predecessor_id created_at updated_at)
    )
    |> Map.put(
      "status",
      cond do
        stage == "working" and delegated_execution?(task) -> "running"
        task["status"] in ["pending", "claimed"] -> "queued"
        true -> task["status"]
      end
    )
    |> Map.merge(%{
      "stage" => stage,
      "question" => question,
      "coordination" => coordination,
      "next_step" =>
        if(blocked_child,
          do: (blocked_child["title"] || "子任务") <> "：" <> (blocked_child["next_step"] || "需要重试"),
          else: task["next_step"]
        ),
      "isolated" => task["conversation"] == true or is_map(task["workspace"]),
      "workspace_path" => get_in(task, ["workspace", "path"]),
      "result" => result,
      "summary" => if(honey, do: honey["content"], else: nil),
      "apply_state" => get_in(task, ["application", "state"])
    })
  end

  @doc "Project durable human inputs and delivered results into the original transcript without a second write authority."
  def merge_messages(sid, existing) do
    projected =
      Store.list_tasks()
      |> Enum.filter(&(root?(&1) and &1["origin_session_id"] == sid))
      |> Enum.flat_map(fn task ->
        inputs = task["inputs"] || []

        human =
          inputs
          |> Enum.reject(&(&1["origin"] == "internal"))
          |> Enum.map(fn input ->
            %{
              "role" => "user",
              "content" => input_text(sid, input),
              "created_at" => iso(input["created_at"]),
              "background_input_id" => input["id"]
            }
          end)

        result =
          case Store.get_honey(task["result"] || "") do
            {:ok, honey} ->
              [
                %{
                  "role" => "assistant",
                  "content" => honey["content"],
                  "created_at" => iso(honey["created_at"]),
                  "background_result_id" => honey["id"]
                }
              ]

            _ ->
              []
          end

        human ++ result
      end)

    (existing ++ projected)
    |> Enum.with_index()
    |> Enum.sort_by(fn {message, index} -> {message_time(message), index} end)
    |> Enum.map(&elem(&1, 0))
  end

  @doc "Supply background facts to an ordinary follow-up without triggering another turn or granting new authority."
  def context_for_origin(sid) do
    task =
      Store.list_tasks()
      |> Enum.filter(&(root?(&1) and &1["origin_session_id"] == sid))
      |> Enum.max_by(& &1["created_at"], fn -> %{} end)

    if task["id"] do
      result =
        case Store.get_honey(task["result"] || "") do
          {:ok, h} -> Map.take(h, ~w(id content evidence limitations))
          _ -> nil
        end

      facts =
        Map.take(task, ~w(id title description status source_root workspace application context_revision))
        |> Map.put("result", result)

      {hash(facts), "以下是本对话的后台工作事实，仅供理解后续问题，不是新的执行授权：\n" <> Jason.encode!(facts)}
    else
      nil
    end
  end

  defp input_text(sid, input) do
    files =
      Enum.map(input["upload_ids"] || [], fn id ->
        case Newbee.Upload.info(input["upload_sid"] || sid, id) do
          {:ok, item} -> item["name"]
          _ -> id <> "（附件已不可用）"
        end
      end)

    if files == [], do: input["text"], else: input["text"] <> "\n[附件：" <> Enum.join(files, "、") <> "]"
  end

  defp iso(value) when is_integer(value), do: value |> DateTime.from_unix!(:millisecond) |> DateTime.to_iso8601()
  defp iso(value) when is_binary(value), do: value
  defp iso(_), do: "1970-01-01T00:00:00Z"

  defp message_time(message) do
    case DateTime.from_iso8601(message["created_at"] || "1970-01-01T00:00:00Z") do
      {:ok, date, _} -> DateTime.to_unix(date, :millisecond)
      _ -> 0
    end
  end

  defp command(sid, action, request_id, payload, fun) do
    key = hash([sid, action, request_id])
    fingerprint = hash(payload)

    Store.transaction(fn data ->
      case get_in(data, ["command_receipts", key]) do
        %{"content_hash" => ^fingerprint, "result" => result} = receipt ->
          {:ok, {:ok, Map.put(result, "receipt", receipt)}, data}

        %{} ->
          {:error, "request_conflict", "同一请求 ID 携带了不同内容"}

        nil ->
          case fun.(data) do
            {:ok, result, next} ->
              receipt = %{
                "id" => key,
                "origin_session_id" => sid,
                "request_id" => request_id,
                "content_hash" => fingerprint,
                "result" => result,
                "created_at" => now()
              }

              {:ok, {:ok, Map.put(result, "receipt", receipt)}, put_in(next, ["command_receipts", key], receipt)}

            error ->
              error
          end
      end
    end)
    |> response()
  end

  defp response({:ok, %{"work_id" => id} = result}) do
    case Store.get_task(id) do
      {:ok, task} -> {:ok, Map.put(result, "work", view(task))}
      _ -> {:error, "not_found", "工作记录不存在"}
    end
  end

  defp response(other), do: other

  defp question_target(data, root, question_id) do
    if get_in(root, ["question", "id"]) == question_id do
      root
    else
      (get_in(root, ["workflow", "children"]) || [])
      |> Enum.map(&data["tasks"][&1])
      |> Enum.find(fn child ->
        child && child["conversation_child"] == true && child["workflow_root"] == root["id"] &&
          child["origin_session_id"] == root["origin_session_id"] && get_in(child, ["question", "id"]) == question_id &&
          child["status"] not in @terminal
      end)
    end
  end

  # Keep the human's input on the original task. The coordinator reads it at integration;
  # each unfinished worker also receives it through their own durable input queue.
  defp enqueue_followup(data, task, body, request_id, attrs) do
    {data, task, input} = enqueue(data, task, body, request_id, attrs)

    if Decomposition.managed?(task) and get_in(task, ["workflow", "phase"]) == "executing" do
      data = put_in(data, ["deliveries", input["delivery_id"], "status"], "held")

      task =
        Map.merge(task, %{
          "status" => "blocked",
          "waiting_for" => "children",
          "next_step" => "补充要求已保存，并转交各项分工；完成后统一集成验证。"
        })

      data =
        Enum.reduce(get_in(task, ["workflow", "children"]) || [], data, fn id, acc ->
          child = acc["tasks"][id]

          if child && child["status"] not in ["cancelled", "pending_review", "done"] do
            uncertain =
              child["status"] == "blocked" and String.contains?(child["next_step"] || "", ["回执", "无法确认", "没有心跳"])

            waiting = child["waiting_for"] in ["dependencies", "capacity"] or uncertain
            child = child |> bump() |> Map.merge(%{"question" => nil, "result" => nil})
            child = if waiting, do: child, else: Map.merge(child, %{"status" => "claimed", "waiting_for" => nil})
            text = "原任务补充要求（在你的分工边界内采用；不要扩大修改范围）：\n" <> body

            {acc, child, forwarded} =
              enqueue(acc, child, text, "forward:" <> request_id, Map.put(attrs, "internal", true))

            acc = if waiting, do: put_in(acc, ["deliveries", forwarded["delivery_id"], "status"], "held"), else: acc
            put_in(acc, ["tasks", id], child)
          else
            acc
          end
        end)

      {data, task, input}
    else
      {data, task, input}
    end
  end

  defp enqueue(data, task, instruction, request_id, attrs) do
    input_id = "input:" <> hash([task["id"], request_id])
    delivery = Work.new_delivery(task, Map.merge(attrs, %{"instruction" => instruction, "input_id" => input_id}))

    delivery =
      if task["status"] == "blocked" and is_nil(task["question"]) and
           String.contains?(task["next_step"] || "", ["回执", "无法确认", "没有心跳"]),
         do: Map.put(delivery, "status", "held"),
         else: delivery

    input = %{
      "origin" => if(attrs["internal"], do: "internal", else: "user"),
      "id" => input_id,
      "request_id" => request_id,
      "text" => instruction,
      "upload_ids" => attrs["upload_ids"] || [],
      "upload_sid" => attrs["upload_sid"],
      "delivery_id" => delivery["id"],
      "created_at" => now(),
      "consumed_at" => nil,
      "context_revision" => task["context_revision"]
    }

    task = Map.update(task, "inputs", [input], &(&1 ++ [input]))

    {data, _} =
      Store.put_entry(
        data,
        "trace",
        Trace.entry(%{
          "colony_id" => task["colony_id"],
          "task_id" => task["id"],
          "bee_id" => task["created_by"],
          "type" => "input",
          "channel" => "work",
          "text" => instruction,
          "data" => %{"input_id" => input_id}
        })
      )

    {put_in(data, ["deliveries", delivery["id"]], delivery), task, input}
  end

  defp context(data, sid, root, :owner) do
    colony = Enum.find(Map.values(data["colonies"]), &(&1["conversation_owner_session"] == sid and &1["cwd"] == root))

    if colony do
      {:ok, data, colony, data["bees"][colony["queen_bee_id"]], data["bees"][colony["worker_bee_id"]]}
    else
      cid = Id.new(:colony, :local)
      human = Bee.new(%{"colony_id" => cid, "kind" => "human", "role" => "queen", "display" => "项目用户"})
      bee = Bee.new(%{"colony_id" => cid, "kind" => "ai", "role" => "worker", "display" => "工作负责人"})

      colony = %{
        "id" => cid,
        "name" => "对话工作",
        "cwd" => root,
        "status" => "active",
        "created_at" => now(),
        "queen_bee_id" => human["id"],
        "worker_bee_id" => bee["id"],
        "admin_bee_ids" => [human["id"]],
        "conversation_owner_session" => sid,
        "conversation_only" => true
      }

      next =
        data
        |> put_in(["colonies", cid], colony)
        |> put_in(["bees", human["id"]], human)
        |> put_in(["bees", bee["id"]], bee)

      {:ok, next, colony, human, bee}
    end
  end

  defp context(data, _sid, root, {:member, actor_id, cid}) do
    with %{} = colony <- data["colonies"][cid],
         %{"colony_id" => ^cid} = actor <- data["bees"][actor_id],
         true <- Path.expand(colony["cwd"]) == root,
         %{} = bee <-
           Enum.find(
             Map.values(data["bees"]),
             &(&1["colony_id"] == cid and &1["kind"] == "ai" and is_nil(&1["remote_member_id"]))
           ) do
      {:ok, data, colony, actor, bee}
    else
      _ -> {:error, "forbidden", "成员只能在当前项目及已授权蜂群内创建工作"}
    end
  end

  defp context(_, _, _, _), do: {:error, "forbidden", "缺少可信请求身份"}

  defp root?(task), do: task["conversation"] == true and task["conversation_child"] != true

  defp active_work(data, sid),
    do:
      Enum.find(
        Map.values(data["tasks"]),
        &(root?(&1) and &1["origin_session_id"] == sid and &1["status"] not in @terminal)
      )

  defp latest_done(data, sid),
    do:
      data["tasks"]
      |> Map.values()
      |> Enum.filter(&(root?(&1) and &1["origin_session_id"] == sid and &1["status"] == "done"))
      |> Enum.max_by(& &1["created_at"], fn -> %{} end)
      |> Map.get("id")

  defp predecessor_facts(data, sid) do
    case latest_done(data, sid) do
      nil ->
        []

      id ->
        old = data["tasks"][id]
        honey = data["honey"][old["result"]] || %{}

        [
          %{
            "predecessor_id" => id,
            "title" => old["title"],
            "accepted_result" => honey["content"],
            "constraints" => old["constraints"],
            "application" => Map.take(old["application"] || %{}, ~w(state target_root patch_sha256))
          }
        ]
    end
  end

  defp owned(data, sid, id) do
    case get_in(data, ["tasks", id]) do
      %{"conversation" => true, "origin_session_id" => ^sid} = task ->
        if root?(task), do: {:ok, task}, else: {:error, "not_found", "请通过总任务操作子任务"}

      _ ->
        {:error, "not_found", "本对话没有这项工作"}
    end
  end

  defp editable(task) do
    cond do
      task["status"] in @terminal ->
        {:error, "terminal", "工作已经结束，请明确发起后续工作"}

      get_in(task, ["application", "state"]) in [
        "preparing",
        "applying",
        "prepared",
        "unknown",
        "partial",
        "failed",
        "applied",
        "text_accepted"
      ] ->
        {:error, "application_in_progress", "成果正在采用或等待完成回执，请先核对采用状态"}

      true ->
        :ok
    end
  end

  defp delegated_execution?(task),
    do: Decomposition.managed?(task) and get_in(task, ["workflow", "phase"]) == "executing"

  defp family(task) do
    children = if Decomposition.managed?(task), do: get_in(task, ["workflow", "children"]) || [], else: []

    [
      task
      | Enum.flat_map(children, fn id ->
          case Store.get_task(id) do
            {:ok, child} -> [child]
            _ -> []
          end
        end)
    ]
  end

  defp all_ok(items, fun),
    do:
      Enum.reduce_while(items, :ok, fn item, :ok ->
        case fun.(item) do
          :ok -> {:cont, :ok}
          error -> {:halt, error}
        end
      end)

  defp quiet_before_retry(task, action), do: all_ok(family(task), &quiet_one(&1, action))
  defp refresh_for_resume(sid, task, action), do: all_ok(family(task), &refresh_one(sid, &1, action))

  defp cancel_children(data, task) do
    Enum.reduce(get_in(task, ["workflow", "children"]) || [], data, fn id, acc ->
      case acc["tasks"][id] do
        %{"conversation_child" => true} = child ->
          next =
            child
            |> bump()
            |> Map.merge(%{
              "status" => "cancelled",
              "question" => nil,
              "resume_needed" => false,
              "next_step" => "总任务已结束；已有成果保留。",
              "execution_generation" => (child["execution_generation"] || 0) + 1
            })

          acc |> put_in(["tasks", id], next) |> settle(id, "cancelled")

        _ ->
          acc
      end
    end)
  end

  defp submitted?(data, child) do
    honey = data["honey"][child["result"]]

    child["status"] in ["pending_review", "done"] and is_map(honey) and
      honey["work_revision"] == child["context_revision"]
  end

  defp resume_children(data, root, config) do
    data = settle(data, root["id"], "superseded")

    data =
      Enum.reduce(get_in(root, ["workflow", "children"]) || [], data, fn id, acc ->
        child = acc["tasks"][id]

        cond do
          not is_map(child) ->
            acc

          submitted?(acc, child) or child["status"] == "cancelled" ->
            acc

          child["waiting_for"] in ["dependencies", "capacity"] or is_map(child["question"]) ->
            put_in(acc, ["tasks", id, "execution_config"], config)

          true ->
            restart_child(acc, child, config)
        end
      end)

    next =
      root
      |> bump()
      |> Map.merge(%{
        "status" => "blocked",
        "waiting_for" => "children",
        "resume_needed" => false,
        "question" => nil,
        "execution_config" => config,
        "execution_generation" => (root["execution_generation"] || 0) + 1,
        "next_step" => "继续各项分工，全部交付后统一集成验证。"
      })

    {data, next}
  end

  defp restart_child(data, child, config) do
    data = settle(data, child["id"], "superseded")

    next =
      child
      |> bump()
      |> Map.merge(%{
        "status" => "claimed",
        "waiting_for" => nil,
        "question" => nil,
        "resume_needed" => false,
        "execution_config" => config,
        "execution_generation" => (child["execution_generation"] || 0) + 1
      })

    {data, next, _input} =
      enqueue(
        data,
        next,
        "从此项分工的保存进度继续。先核对新要求、依赖成果、已有文件和外部操作；不要盲目重放旧工具。",
        "resume:" <> Integer.to_string(next["execution_generation"]),
        %{"internal" => true}
      )

    put_in(data, ["tasks", child["id"]], next)
  end

  # A failed child can be retried while unrelated children continue. Never interrupt the
  # whole root merely to retry one isolated worker, and never restart a busy old writer.
  defp retry_children(sid, root) do
    children =
      family(root)
      |> tl()
      |> Enum.filter(fn child ->
        child["status"] in ["blocked", "failed"] and child["waiting_for"] not in ["dependencies", "capacity"] and
          not is_map(child["question"])
      end)

    config = %{
      "provider" => Newbee.Session.provider(sid),
      "model" => Newbee.Session.model(sid),
      "effort" => Newbee.Session.effort(sid)
    }

    with true <- children != [],
         :ok <- all_ok(children, &quiet_one(&1, "retry")),
         :ok <- all_ok(children, &refresh_one(sid, &1, "retry")),
         {:ok, result} <-
           Store.transaction(fn data ->
             current = data["tasks"][root["id"]]

             valid =
               current && delegated_execution?(current) && current["revision"] == root["revision"] &&
                 Enum.all?(children, fn child ->
                   get_in(data, ["tasks", child["id"], "revision"]) == child["revision"]
                 end)

             if valid do
               data = Enum.reduce(children, data, &restart_child(&2, &1, config))
               current = current |> bump() |> Map.put("next_step", "正在重试未完成的分工，其余执行继续。")
               {:ok, {:ok, %{"work_id" => root["id"]}}, put_in(data, ["tasks", root["id"]], current)}
             else
               {:error, "conflict", "分工状态已变化，请刷新后重试"}
             end
           end) do
      response({:ok, result})
    else
      false -> {:error, "nothing_to_retry", "没有失败的分工；需要继续时请先检查当前问题或暂停状态"}
      error -> error
    end
  end

  defp refresh_one(sid, task, action) when action in ["resume", "retry"] do
    case Newbee.Web.Session.lookup(task["session_id"] || "") do
      {:ok, pid} ->
        with {:ok, client} <- Newbee.Web.Session.client_for_session(sid),
             true <- is_binary(client.api_key) and String.trim(client.api_key) != "",
             :ok <- Newbee.Web.Session.switch_model(pid, client.provider, client.model) do
          :ok
        else
          _ -> {:error, "model_unavailable", "请先在原会话模型设置中修复凭据或模型，再重试此项工作"}
        end

      _ ->
        :ok
    end
  catch
    :exit, _ -> {:error, "execution_unknown", "执行环境尚不能确认，未恢复工作"}
  end

  defp refresh_one(_, _, _), do: :ok

  defp allowed_control(task, "retry"), do: if(task["status"] in ~w(blocked failed), do: :ok, else: editable(task))
  defp allowed_control(task, _), do: editable(task)

  defp quiet_one(task, action) when action in ["resume", "retry"] do
    case Newbee.Web.Session.lookup(task["session_id"] || "") do
      {:ok, pid} ->
        if GenServer.call(pid, :peek_busy, 1_000), do: {:error, "execution_busy", "旧执行者仍在运行，请先暂停并确认"}, else: :ok

      _ ->
        :ok
    end
  catch
    :exit, _ -> {:error, "execution_unknown", "无法确认旧执行者状态，不能启动第二个写入者"}
  end

  defp quiet_one(_, _), do: :ok

  defp settle(data, id, status) do
    Map.update!(data, "deliveries", fn rows ->
      Map.new(rows, fn {key, d} ->
        next =
          if d["task_id"] == id and d["status"] in ~w(pending dispatching accepted paused held) do
            d |> Map.put("status", status) |> Map.update("revision", 1, &(&1 + 1))
          else
            d
          end

        {key, next}
      end)
    end)
  end

  defp bump(task),
    do:
      task
      |> Map.update("revision", 1, &(&1 + 1))
      |> Map.update("context_revision", 1, &(&1 + 1))
      |> Map.put("updated_at", now())

  defp text(value, limit),
    do:
      if(is_binary(value) and String.trim(value) != "" and byte_size(value) <= limit,
        do: :ok,
        else: {:error, "bad_request", "缺少必要文本或超过长度限制"}
      )

  defp hash(value), do: Newbee.Collaboration.Verification.value_sha256(value)
  defp now, do: System.system_time(:millisecond)
end
