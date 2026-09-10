defmodule Newbee.Collaboration.Chat.Room do
  @moduledoc "Persistent, single-writer project discussions. Device identity owns representatives; discussion never grants execution authority."
  use GenServer
  alias Newbee.Collaboration.CrossHost.Store
  alias Newbee.Collaboration.SharedContext

  @active ~w(independent discussing summarizing mention)
  @plain_phases ~w(independent summarizing)
  @roles ["实现与维护", "测试与反例", "需求与体验", "接口与依赖", "运行与诊断"]
  @max_mentions 5
  @max_mention_runs 4
  @max_mentions_per_topic 12
  @queue_window_ms 1_800_000
  @default_human_window_ms 180_000
  @min_human_window_ms 1_000
  @max_human_window_ms 3_600_000

  @styles ["简练直接", "温和严谨", "善用实例", "轻松但尊重事实", "条理清晰"]
  @names ["岩松", "小桥", "阿澄", "北辰", "木木", "青禾", "知秋", "星野"]

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  @impl true
  def init(_), do: {:ok, nil}

  @doc "Execute one bounded room command as the local operator or an authenticated device."
  def command(gid, action, params \\ %{}, actor \\ :local, server \\ __MODULE__)

  def command(gid, action, params, actor, server) when is_binary(gid) and is_binary(action) and is_map(params) do
    GenServer.call(server, {:command, gid, action, params, actor}, 15_000)
  end

  def command(_, _, _, _, _), do: {:error, "bad_request", "聊天室参数无效"}

  @doc "Public snapshot excludes independent drafts and device work envelopes."
  def snapshot(gid) do
    case command(gid, "snapshot") do
      {:ok, room} -> room
      _ -> %{"representatives" => [], "topics" => [], "messages" => [], "revision" => 0}
    end
  end

  @doc "Return only work owned by one device; other independent answers are never included."
  def jobs(gid, did) do
    case command(gid, "jobs", %{}, did) do
      {:ok, jobs} -> jobs
      _ -> []
    end
  end

  @impl true
  def handle_call({:command, gid, action, params, actor}, _from, state) do
    reply =
      with {:ok, group} <- Store.get_group(gid),
           :ok <- local_authority(group),
           :ok <- authorize(group, actor),
           {:ok, room} <- load(gid),
           {:ok, next, result} <- execute(reconcile(room, group), group, action, params, actor) do
        next = if next == room, do: next, else: Map.update!(next, "revision", &(&1 + 1))

        with :ok <- save(gid, next, room) do
          value = if result == :snapshot, do: public(next, group, params), else: result
          {:ok, value}
        end
      end

    {:reply, reply, state}
  rescue
    _ -> {:reply, {:error, "chat_unavailable", "聊天室操作失败，原有任务不受影响"}, state}
  end

  defp empty,
    do: %{
      "revision" => 0,
      "representatives" => %{},
      "topics" => %{},
      "messages" => [],
      "jobs" => %{},
      "receipts" => %{},
      "seq" => 0,
      "human_window_ms" => @default_human_window_ms,
      "auto_discuss" => false
    }

  defp path(gid) do
    hash = :crypto.hash(:sha256, gid) |> Base.encode16(case: :lower)
    Path.join(Path.dirname(Store.persist_path()), "chat-" <> Atom.to_string(Mix.env()) <> "-" <> hash <> ".json")
  end

  defp load(gid) do
    case File.read(path(gid)) do
      {:ok, text} ->
        case Jason.decode(text) do
          {:ok, room} when is_map(room) -> {:ok, Map.merge(empty(), room)}
          _ -> {:error, "chat_corrupt", "聊天室记录损坏，请保留文件后恢复备份"}
        end

      {:error, :enoent} ->
        {:ok, empty()}

      _ ->
        {:error, "chat_storage", "无法读取聊天室记录"}
    end
  end

  defp save(_, room, room), do: :ok

  defp save(gid, room, _) do
    dest = path(gid)

    with :ok <- File.mkdir_p(Path.dirname(dest)),
         {:ok, json} <- Jason.encode(room),
         :ok <- File.write(dest <> ".tmp", json),
         :ok <- File.rename(dest <> ".tmp", dest) do
      _ = Newbee.Events.emit(:project_chat_changed, %{"group_id" => gid, "revision" => room["revision"]})
      :ok
    else
      _ -> {:error, "chat_storage", "无法保存聊天室，操作未确认"}
    end
  end

  defp local_authority(%{"remote" => true}), do: {:error, "remote_group", "请通过群主连接访问聊天室"}
  defp local_authority(_), do: :ok
  defp authorize(_, :local), do: :ok
  defp authorize(%{"remote" => true}, "local"), do: {:error, "forbidden", "本机身份只在群主节点有效"}
  defp authorize(_, "local"), do: :ok

  defp authorize(group, did) when is_binary(did) do
    case get_in(group, ["devices", did]) do
      nil -> {:error, "forbidden", "设备不属于本群"}
      %{"paused" => true} -> {:error, "forbidden", "设备已暂停"}
      _ -> :ok
    end
  end

  defp authorize(_, _), do: {:error, "forbidden", "缺少设备身份"}
  defp owns?(:local, _), do: true
  defp owns?(did, did), do: true
  defp owns?(_, _), do: false

  defp execute(room, _, "snapshot", _, _), do: {:ok, room, :snapshot}

  defp execute(room, group, "jobs", _, actor) do
    roster =
      room["representatives"]
      |> Map.values()
      |> Enum.filter(&(&1["enabled"] == true))
      |> Enum.map(&Map.take(&1, ["id", "name", "kind", "focus"]))

    jobs =
      room["jobs"]
      |> Map.values()
      |> Enum.filter(&(&1["status"] == "pending" and &1["device_id"] == actor))
      |> Enum.sort_by(& &1["created_at"])
      |> Enum.take(3)
      |> Enum.map(fn job ->
        topic = room["topics"][job["topic_id"]]
        rep = room["representatives"][job["representative_id"]]

        messages =
          if job["phase"] == "independent",
            do: [],
            else:
              topic_messages(room, topic["id"])
              |> Enum.take(-16)
              |> Enum.map(&Map.update!(&1, "body", fn body -> String.slice(body, 0, 1_000) end))

        Map.merge(Map.drop(job, ["result"]), %{
          "representative" => rep,
          "topic" => Map.drop(topic, ["applications"]),
          "messages" => messages,
          "representatives" => roster,
          "project_id" => group["project_id"],
          "group_id" => group["id"]
        })
      end)

    {:ok, room, jobs}
  end

  defp execute(room, _, "settings", p, :local) do
    with {:ok, auto} <- optional_bool(Map.get(p, "auto_discuss", room["auto_discuss"]), "auto_discuss"),
         {:ok, window} <- optional_window(Map.get(p, "human_window_ms", room["human_window_ms"])) do
      {:ok, Map.merge(room, %{"auto_discuss" => auto, "human_window_ms" => window}), :snapshot}
    end
  end

  defp execute(room, group, "representative.create", p, actor) do
    did = if actor == :local, do: p["device_id"] || "local", else: actor
    kind = if p["kind"] == "human", do: "human", else: "agent"
    reps = Map.values(room["representatives"])

    with :ok <- authorize(group, did),
         true <- length(reps) < 24 and Enum.count(reps, &(&1["device_id"] == did)) < 6,
         {:ok, name} <- text(p["name"] || Enum.random(@names), 40),
         {:ok, focus} <- text(p["focus"] || Enum.at(@roles, rem(length(reps), length(@roles))), 200),
         {:ok, style} <- text(p["style"] || Enum.random(@styles), 120),
         :ok <- no_model_for_human(kind, [p["provider"], p["model"]]),
         {:ok, provider} <- optional_text(if(kind == "human", do: nil, else: p["provider"]), 160),
         {:ok, model} <- optional_text(if(kind == "human", do: nil, else: p["model"]), 200) do
      rep = %{
        "id" => id("rep"),
        "kind" => kind,
        "device_id" => did,
        "name" => name,
        "focus" => focus,
        "style" => style,
        "provider" => provider,
        "model" => model,
        "enabled" => true,
        "created_at" => now()
      }

      {:ok, put_in(room, ["representatives", rep["id"]], rep), rep}
    else
      false -> bad("每台主机最多6位代表，每群最多24位")
      error -> error
    end
  end

  defp execute(room, _, "representative.update", p, actor) do
    with {:ok, rep} <- fetch(room["representatives"], p["representative_id"]),
         true <- owns?(actor, rep["device_id"]),
         {:ok, name} <- text(p["name"] || rep["name"], 40),
         {:ok, focus} <- text(p["focus"] || rep["focus"], 200),
         {:ok, style} <- text(p["style"] || rep["style"], 120),
         :ok <- no_model_for_human(rep["kind"], [Map.get(p, "provider"), Map.get(p, "model")]),
         {:ok, provider} <- optional_text(Map.get(p, "provider", rep["provider"]), 160),
         {:ok, model} <- optional_text(Map.get(p, "model", rep["model"]), 200),
         enabled when is_boolean(enabled) <- Map.get(p, "enabled", rep["enabled"]) do
      rep =
        Map.merge(rep, %{
          "name" => name,
          "focus" => focus,
          "style" => style,
          "provider" => provider,
          "model" => model,
          "enabled" => enabled
        })

      {:ok, put_in(room, ["representatives", rep["id"]], rep), rep}
    else
      false -> forbidden()
      {:error, _, _} = err -> err
      _ -> bad("enabled 必须为布尔值")
    end
  end

  defp execute(room, group, "topic.open", p, actor) do
    key = p["command_id"]
    previous = if is_binary(key), do: Enum.find(Map.values(room["topics"]), &(&1["command_id"] == key))

    if previous do
      {:ok, room, previous}
    else
      with {:ok, title} <- text(p["title"], 160),
           {:ok, problem} <- text(p["problem"], 8_000),
           {:ok, base} <- optional_text(p["base_revision"], 160),
           :ok <- task_exists(group["id"], p["task_id"]),
           true <- map_size(room["topics"]) < 200 do
        topic = %{
          "id" => id("topic"),
          "title" => title,
          "problem" => problem,
          "base_revision" => base,
          "task_id" => p["task_id"],
          "owner_device_id" => actor_name(actor),
          "status" => "open",
          "round" => 0,
          "participants" => [],
          "decision" => nil,
          "applications" => [],
          "created_at" => now(),
          "command_id" => key,
          "calls" => 0,
          "waits" => 0,
          "skips" => 0,
          "max_calls" => 16,
          "usage" => %{},
          "run" => 0,
          "seen" => %{},
          "pending_mentions" => []
        }

        next = put_in(room, ["topics", topic["id"]], topic)
        {:ok, add_message(next, topic["id"], actor_name(actor), "topic", problem), topic}
      else
        false -> bad("议题数量已达200，请归档项目后建立新群")
        error -> error
      end
    end
  end

  defp execute(room, group, "message.post", p, actor) do
    with {:ok, body} <- text(p["body"], 4_000),
         :ok <- optional_topic(room, p["topic_id"]),
         :ok <- reply_exists(room, p["topic_id"], p["reply_to"]),
         {:ok, author} <- message_author(room, p["representative_id"], actor),
         {:ok, explicit} <- mention_ids(room, p["mentions"]),
         {:ok, all?} <- mention_flag(p["mention_all"]) do
      key = p["command_id"]

      existing =
        if is_binary(key),
          do: Enum.find(room["messages"], &(&1["command_id"] == key and &1["device_id"] == actor_name(actor)))

      if existing do
        {:ok, room, existing}
      else
        author_id = author && author["id"]
        targets = mention_targets(room, group, explicit, all?, author_id)
        registered = registerable_mentions(room, p["topic_id"], targets)

        next =
          add_message(room, p["topic_id"], actor_name(actor), "human", body, %{
            "reply_to" => p["reply_to"],
            "command_id" => key,
            "representative_id" => author_id,
            "name" => author && author["name"],
            "mentions" => registered,
            "mention_all" => all?
          })

        posted = List.last(next["messages"])

        # A human answering inside their own wait window resolves that turn.
        next = resolve_human_wait(next, p["topic_id"], author_id)
        next = if author_id && is_binary(p["topic_id"]), do: advance(next, group, p["topic_id"]), else: next

        # The dispatcher receives the requested targets so a refusal is reported even when
        # the message itself records no invitation (for example on a stopped topic).
        {next, notice} = mentions_after_message(next, group, p["topic_id"], targets, "human")
        final = with_notice(next, p["topic_id"], notice)
        # Return the message itself, not a notice that may have been appended after it.
        {:ok, final, posted}
      end
    end
  end

  defp execute(room, group, "job.skip", p, actor) do
    with {:ok, job} <- fetch(room["jobs"], p["job_id"]),
         {:ok, rep} <- fetch(room["representatives"], job["representative_id"]),
         true <- job["kind"] == "human" and job["status"] == "pending",
         true <- owns?(actor, rep["device_id"]) do
      next =
        room
        |> put_in(["jobs", job["id"], "status"], "skipped")
        |> put_in(["jobs", job["id"], "result"], "本人选择本回合不发言")
        |> put_in(["jobs", job["id"], "completed_at"], now())
        |> advance(group, job["topic_id"])

      {:ok, next, %{"skipped" => true}}
    else
      false -> bad("只能跳过属于自己人类代表的等待回合")
      error -> error
    end
  end

  defp execute(room, group, "discussion.start", p, actor) do
    with {:ok, topic} <- fetch(room["topics"], p["topic_id"]),
         true <- owns?(actor, topic["owner_device_id"]),
         true <- topic["status"] not in @active,
         true <- Enum.count(Map.values(room["topics"]), &(&1["status"] in @active)) < 3,
         rounds when is_integer(rounds) and rounds in 1..2 <- Map.get(p, "rounds", 2),
         {:ok, reps} <- participants(room, group, p["participants"]),
         true <- planned_calls(topic, reps, rounds) <= topic["max_calls"] do
      topic =
        Map.merge(topic, %{
          "status" => "independent",
          "round" => 0,
          "rounds" => rounds,
          "participants" => Enum.map(reps, & &1["id"]),
          "run" => topic["run"] + 1,
          "decision" => nil
        })

      next = room |> put_in(["topics", topic["id"]], topic) |> schedule(topic, "independent", reps)
      {:ok, next, next["topics"][topic["id"]]}
    else
      false -> bad("议题不可启动：检查负责人、进行中状态、并发上限和16次调用预算")
      {:error, _, _} = error -> error
      _ -> bad("讨论轮次必须为1或2")
    end
  end

  defp execute(room, _, "discussion.stop", p, actor) do
    with {:ok, topic} <- fetch(room["topics"], p["topic_id"]), true <- owns?(actor, topic["owner_device_id"]) do
      next = update_in(room, ["topics", topic["id"]], &Map.put(&1, "status", "stopped"))

      next =
        update_in(
          next,
          ["jobs"],
          &Map.new(&1, fn {id, j} ->
            {id,
             if(j["topic_id"] == topic["id"] and j["status"] == "pending",
               do: Map.put(j, "status", "cancelled"),
               else: j
             )}
          end)
        )

      {:ok, next, :snapshot}
    else
      false -> forbidden()
      error -> error
    end
  end

  defp execute(room, _, "job.claim", p, actor) do
    with {:ok, job} <- fetch(room["jobs"], p["job_id"]),
         true <- owns?(actor, job["device_id"]),
         true <- job["status"] == "pending" and job["claimed_at"] == nil do
      {:ok, put_in(room, ["jobs", job["id"], "claimed_at"], now()), %{"claimed" => true}}
    else
      false -> {:error, "job_unavailable", "工作项已领取、结束或不属于本机"}
      error -> error
    end
  end

  defp execute(room, group, "job.complete", p, actor) do
    with {:ok, job} <- fetch(room["jobs"], p["job_id"]), true <- owns?(actor, job["device_id"]) do
      if job["status"] != "pending" do
        {:ok, room, %{"accepted" => true, "duplicate" => true}}
      else
        with {:ok, body} <- text(p["body"] || p["error"], 4_000) do
          failed = is_binary(p["error"])
          mentions = if failed, do: [], else: validated_mentions(room, p["mentions"], job["representative_id"])

          job =
            Map.merge(job, %{
              "status" => if(failed, do: "failed", else: "done"),
              "result" => body,
              "mentions" => mentions,
              "usage" => usage(p["usage"]),
              "completed_at" => now()
            })

          next =
            room
            |> put_in(["jobs", job["id"]], job)
            |> update_in(["topics", job["topic_id"], "usage"], fn totals ->
              Map.merge(totals, job["usage"], fn _, a, b -> a + b end)
            end)
            |> advance(group, job["topic_id"])

          {next, notice} = mention_after_agent(next, group, job, mentions)
          {:ok, with_notice(next, job["topic_id"], notice), %{"accepted" => true}}
        end
      end
    else
      false -> forbidden()
      error -> error
    end
  end

  defp execute(room, group, "decision.apply", p, actor) do
    with {:ok, topic} <- fetch(room["topics"], p["topic_id"]),
         true <- owns?(actor, topic["owner_device_id"]),
         decision when is_map(decision) <- topic["decision"],
         true <- decision["version"] == p["version"],
         true <-
           is_binary(p["base_revision"]) and p["base_revision"] != "" and p["base_revision"] == topic["base_revision"],
         true <- is_binary(topic["task_id"]),
         :ok <- application_allowed(group["id"], topic["task_id"], actor) do
      application = %{
        "decision_id" => decision["id"],
        "version" => decision["version"],
        "task_id" => topic["task_id"],
        "base_revision" => topic["base_revision"],
        "applied_at" => now(),
        "status" => "available"
      }

      apps = topic["applications"]

      next =
        if Enum.any?(apps, &(&1["decision_id"] == decision["id"])),
          do: room,
          else: put_in(room, ["topics", topic["id"], "applications"], apps ++ [application])

      {:ok, next, application}
    else
      false -> bad("决议版本、代码基线或关联任务不匹配；请重新核对后应用")
      nil -> bad("尚无决议")
      error -> error
    end
  end

  defp execute(room, group, "topic.handover", p, actor) do
    with {:ok, topic} <- fetch(room["topics"], p["topic_id"]),
         true <- owns?(actor, topic["owner_device_id"]),
         {:ok, did} <- text(p["device_id"], 160),
         :ok <- authorize(group, did) do
      {:ok, put_in(room, ["topics", topic["id"], "owner_device_id"], did), :snapshot}
    else
      false -> forbidden()
      error -> error
    end
  end

  defp execute(_, _, _, _, _), do: bad("不支持的聊天室操作或没有权限")

  defp reconcile(room, group) do
    room =
      Enum.reduce(room["jobs"], room, fn {jid, job}, acc ->
        if job["status"] == "pending" and
             (job["deadline"] < now() or not available?(group, room["representatives"][job["representative_id"]])) do
          put_in(
            acc,
            ["jobs", jid],
            Map.merge(job, %{"status" => "failed", "result" => "成员离线、已暂停或讨论超时", "usage" => %{}})
          )
        else
          acc
        end
      end)

    room = Enum.reduce(Map.values(room["topics"]), room, fn topic, acc -> advance(acc, group, topic["id"]) end)
    room = dispatch_pending_mentions(room, group)
    room = feedback(room, group)
    auto_open(room, group)
  end

  # Directed mentions raised while a round was still running wait here, so an agent
  # reply can never re-enter the room mid-round or chain without bound.
  defp dispatch_pending_mentions(room, group) do
    Enum.reduce(Map.values(room["topics"]), room, fn topic, acc ->
      pending = List.wrap(topic["pending_mentions"])

      if pending == [] or topic["status"] in @active do
        acc
      else
        ids = pending |> Enum.map(& &1["rep_id"]) |> Enum.uniq()
        origin = pending |> List.first() |> Map.get("origin", "agent")
        {next, notice} = dispatch_mentions(acc, group, topic["id"], ids, origin)
        next |> put_in(["topics", topic["id"], "pending_mentions"], []) |> with_notice(topic["id"], notice)
      end
    end)
  end

  defp auto_open(%{"auto_discuss" => true} = room, group) do
    tasks = Store.list_tasks(group["id"]) |> Enum.filter(&(&1["status"] in ~w(failed waiting_input))) |> Enum.take(20)

    Enum.reduce(tasks, room, fn task, acc ->
      exists = Enum.any?(Map.values(acc["topics"]), &(&1["task_id"] == task["id"]))

      recent =
        Enum.count(
          Map.values(acc["topics"]),
          &(&1["created_at"] > now() - 3_600_000 and &1["command_id"] == "auto:" <> to_string(&1["task_id"]))
        )

      if exists or recent >= 3 do
        acc
      else
        p = %{
          "title" => "任务会诊：" <> String.slice(task["title"] || task["id"], 0, 100),
          "problem" =>
            Jason.encode!(SharedContext.sanitize(Map.take(task, ["title", "description", "status", "result"]))),
          "task_id" => task["id"],
          "base_revision" => task["base_revision"],
          "command_id" => "auto:" <> task["id"]
        }

        case execute(acc, group, "topic.open", p, :local) do
          {:ok, opened, topic} ->
            case execute(opened, group, "discussion.start", %{"topic_id" => topic["id"]}, :local) do
              {:ok, started, _} -> started
              _ -> opened
            end

          _ ->
            acc
        end
      end
    end)
  end

  defp auto_open(room, _), do: room

  defp feedback(room, group) do
    tasks = Map.new(Store.list_tasks(group["id"]), &{&1["id"], &1})

    Enum.reduce(Map.values(room["topics"]), room, fn topic, acc ->
      task = tasks[topic["task_id"]]

      if is_map(task) and topic["applications"] != [] and task["status"] in ~w(done failed cancelled) and
           topic["feedback_status"] != task["status"] do
        result =
          SharedContext.sanitize(Map.take(task, ["id", "status", "result"]))
          |> Jason.encode!()
          |> String.slice(0, 4_000)

        acc
        |> put_in(["topics", topic["id"], "feedback_status"], task["status"])
        |> add_message(topic["id"], "system", "execution", "执行反馈（任务状态不等于独立验证）：" <> result)
      else
        acc
      end
    end)
  end

  # Schedule one turn per representative. Humans get a wait window instead of a model
  # call; agents whose topic has gained no new message since their previous turn are
  # recorded as skipped without spending a call ("speak or stay silent, no cost").
  defp schedule(room, topic, phase, reps) do
    last = room |> topic_messages(topic["id"]) |> List.last()
    last_speaker = last && last["representative_id"]

    # In a discussion or directed round a representative whose own message is still the
    # last thing said has nothing new to answer, so no model call is spent on it.
    silent? = fn rep ->
      rep["kind"] != "human" and phase not in @plain_phases and is_binary(last_speaker) and
        last_speaker == rep["id"]
    end

    Enum.reduce(reps, room, fn rep, acc -> schedule_one(acc, topic, phase, rep, silent?.(rep)) end)
  end

  defp schedule_one(room, topic, phase, rep, silent?) do
    human? = rep["kind"] == "human"
    jid = id("job")

    job = %{
      "id" => jid,
      "topic_id" => topic["id"],
      "representative_id" => rep["id"],
      # Human turns never belong to a device, so the worker poll never picks them up.
      "device_id" => if(human?, do: "human:" <> rep["id"], else: rep["device_id"]),
      "kind" => if(human?, do: "human", else: "agent"),
      "phase" => phase,
      "round" => topic["round"],
      "run" => topic["run"],
      "status" => if(silent?, do: "skipped", else: "pending"),
      "result" => if(silent?, do: "本轮没有需要回应的新消息，未调用模型", else: nil),
      "created_at" => now(),
      "deadline" => now() + if(human?, do: human_window(room), else: @queue_window_ms)
    }

    next = put_in(room, ["jobs", jid], job)

    cond do
      silent? -> update_in(next, ["topics", topic["id"], "skips"], &((&1 || 0) + 1))
      human? -> update_in(next, ["topics", topic["id"], "waits"], &((&1 || 0) + 1))
      true -> update_in(next, ["topics", topic["id"], "calls"], &(&1 + 1))
    end
  end

  defp advance(room, group, tid) do
    topic = room["topics"][tid]

    if topic["status"] in @active do
      jobs =
        room["jobs"]
        |> Map.values()
        |> Enum.filter(
          &(&1["topic_id"] == tid and &1["run"] == topic["run"] and &1["round"] == topic["round"] and
              &1["phase"] == topic["status"])
        )
        |> Enum.sort_by(& &1["id"])

      if jobs != [] and Enum.all?(jobs, &(&1["status"] != "pending")) do
        room =
          Enum.reduce(jobs, room, fn j, acc ->
            rep = acc["representatives"][j["representative_id"]]

            meta = %{
              "representative_id" => rep["id"],
              "name" => rep["name"],
              "round" => j["round"],
              "phase" => j["phase"],
              "mentions" => List.wrap(j["mentions"]),
              "usage" => j["usage"] || %{}
            }

            kind =
              case j["status"] do
                "done" -> "agent"
                "skipped" -> "skipped"
                "failed" -> "error"
                _ -> nil
              end

            if kind && j["result"] do
              add_message(acc, tid, j["device_id"], kind, j["result"], meta)
            else
              acc
            end
          end)

        successful = Enum.filter(jobs, &(&1["status"] in ["done", "answered"]))
        reps = topic["participants"] |> Enum.map(&room["representatives"][&1]) |> Enum.filter(&available?(group, &1))

        failed_all? = Enum.all?(jobs, &(&1["status"] == "failed"))

        cond do
          # A directed round never fails the topic; it just returns to a ready state.
          topic["status"] == "mention" ->
            put_in(room, ["topics", tid, "status"], "open")

          # Only a round where every participant actually failed is unresolvable. A round
          # where everyone stayed silent still proceeds to the summary.
          failed_all? or reps == [] ->
            put_in(room, ["topics", tid, "status"], "unresolved")

          topic["status"] == "summarizing" and is_binary(hd(successful)["result"]) and
              String.trim(hd(successful)["result"]) != "" ->
            body = hd(successful)["result"]

            decision = %{
              "id" => id("decision"),
              "version" => topic["run"],
              "body" => body,
              "status" => "proposed",
              "base_revision" => topic["base_revision"],
              "task_id" => topic["task_id"],
              "created_at" => now(),
              "evidence_message_ids" => Enum.map(topic_messages(room, tid), & &1["id"])
            }

            room |> put_in(["topics", tid, "decision"], decision) |> put_in(["topics", tid, "status"], "proposed")

          topic["round"] >= topic["rounds"] ->
            # A human summariser cannot produce a draft on its own, so only an agent
            # writes the decision; otherwise the topic simply returns to a ready state.
            case Enum.find(reps, &(&1["kind"] != "human")) do
              nil ->
                put_in(room, ["topics", tid, "status"], "open")

              summarizer ->
                next_topic = %{room["topics"][tid] | "status" => "summarizing"}
                room |> put_in(["topics", tid], next_topic) |> schedule(next_topic, "summarizing", [summarizer])
            end

          # Summarising without usable text must not loop on itself.
          topic["status"] == "summarizing" ->
            put_in(room, ["topics", tid, "status"], "open")

          true ->
            next_topic = Map.merge(room["topics"][tid], %{"status" => "discussing", "round" => topic["round"] + 1})
            room |> put_in(["topics", tid], next_topic) |> schedule(next_topic, "discussing", reps)
        end
      else
        room
      end
    else
      room
    end
  end

  defp participants(room, group, ids) do
    available =
      room["representatives"] |> Map.values() |> Enum.filter(&available?(group, &1)) |> Enum.sort_by(& &1["created_at"])

    # Round-robin by device before taking defaults; more local personas do not crowd out other hosts.
    defaults =
      available
      |> Enum.group_by(& &1["device_id"])
      |> Enum.sort()
      |> Enum.flat_map(fn {_, reps} -> Enum.with_index(reps) end)
      |> Enum.sort_by(fn {rep, index} -> {index, rep["device_id"]} end)
      |> Enum.map(&elem(&1, 0))
      |> Enum.take(3)

    selected = if is_list(ids) and ids != [], do: Enum.filter(available, &(&1["id"] in ids)), else: defaults

    if length(selected) in 2..5 and (is_nil(ids) or ids == [] or length(Enum.uniq(ids)) == length(selected)),
      do: {:ok, selected},
      else: bad("请选择2至5位可用代表，默认按主机分散选择3位")
  end

  defp available?(_, nil), do: false

  defp available?(_group, %{"kind" => "human"} = rep), do: rep["enabled"] == true

  # A representative hosted by the Hub itself ("local") needs no enrolled device.
  defp available?(group, %{"device_id" => "local"} = rep), do: rep["enabled"] == true and group["remote"] != true

  defp available?(group, rep) do
    device = get_in(group, ["devices", rep["device_id"]])

    rep["enabled"] == true and is_map(device) and device["paused"] != true and
      (not (device["remote"] == true or device["bridge"] == true) or
         (is_integer(device["last_seen"]) and device["last_seen"] > now() - 90_000))
  end

  defp public(room, group, params) do
    reps =
      room["representatives"]
      |> Map.values()
      |> Enum.map(fn rep -> Map.put(rep, "available", available?(group, rep)) end)
      |> Enum.sort_by(& &1["created_at"])

    %{
      "group_id" => group["id"],
      "revision" => room["revision"],
      "representatives" => reps,
      "auto_discuss" => room["auto_discuss"],
      "human_window_ms" => human_window(room),
      "topics" =>
        room["topics"]
        |> Map.values()
        |> Enum.sort_by(& &1["created_at"], :desc)
        |> Enum.map(&public_topic(room, &1)),
      "messages" =>
        if(is_binary(params["topic_id"]), do: topic_messages(room, params["topic_id"]), else: room["messages"])
        |> Enum.take(-120),
      "messages_truncated" => length(room["messages"]) > 120,
      "limits" => %{
        "representatives_per_device" => 6,
        "active_topics" => 3,
        "calls_per_topic" => 16,
        "output_tokens_per_call" => 800,
        "summary_output_tokens" => 1600,
        "mentions_per_message" => @max_mentions,
        "mentions_per_topic" => @max_mentions_per_topic,
        "mention_runs_per_topic" => @max_mention_runs
      }
    }
  end

  defp public_topic(room, topic) do
    topic
    # seen/pending bookkeeping and the raw problem text stay out of the shared view.
    |> Map.drop(["problem", "seen", "pending_mentions"])
    |> Map.put("open_waits", open_waits(room, topic["id"]))
    |> Map.put("open_mentions", open_mentions(room, topic["id"]))
    |> Map.put("open_waits_for", open_waits(room, topic["id"]) |> Enum.map(& &1["representative_id"]))
  end

  # A human turn still waiting for its owner to answer or skip.
  defp open_waits(room, topic_id) do
    room["jobs"]
    |> Map.values()
    |> Enum.filter(&(&1["topic_id"] == topic_id and &1["kind"] == "human" and &1["status"] == "pending"))
    |> Enum.sort_by(& &1["created_at"])
    |> Enum.map(fn job ->
      rep = room["representatives"][job["representative_id"]] || %{}

      %{
        "job_id" => job["id"],
        "representative_id" => job["representative_id"],
        "name" => rep["name"],
        "device_id" => rep["device_id"],
        "phase" => job["phase"],
        "deadline" => job["deadline"]
      }
    end)
  end

  # Mentions that were never followed by a message from that representative.
  defp open_mentions(room, topic_id) do
    messages = topic_messages(room, topic_id)

    answered =
      messages
      |> Enum.filter(&is_binary(&1["representative_id"]))
      |> Enum.group_by(& &1["representative_id"], &(&1["seq"] || 0))

    messages
    |> Enum.flat_map(fn message ->
      Enum.flat_map(List.wrap(message["mentions"]), fn rid ->
        if Enum.max(answered[rid] || [-1]) < (message["seq"] || 0) do
          [
            %{
              "representative_id" => rid,
              "name" => name_of(room, rid),
              "message_id" => message["id"],
              "created_at" => message["created_at"]
            }
          ]
        else
          []
        end
      end)
    end)
    |> Enum.uniq_by(& &1["representative_id"])
  end

  defp name_of(room, rep_id), do: get_in(room, ["representatives", rep_id, "name"]) || rep_id

  defp add_message(room, tid, did, kind, body, extra \\ %{}) do
    seq = (room["seq"] || 0) + 1

    message =
      Map.merge(
        %{
          "id" => id("msg"),
          "topic_id" => tid,
          "device_id" => did,
          "kind" => kind,
          "body" => SharedContext.sanitize(body),
          "seq" => seq,
          "created_at" => now()
        },
        extra
      )

    room |> Map.put("seq", seq) |> update_in(["messages"], &Enum.take(&1 ++ [message], -600))
  end

  defp topic_messages(room, tid), do: Enum.filter(room["messages"], &(&1["topic_id"] == tid))

  defp application_allowed(gid, tid, actor) do
    case Enum.find(Store.list_tasks(gid), &(&1["id"] == tid)) do
      nil -> bad("关联任务不存在")
      %{"status" => status} when status in ~w(done failed cancelled) -> bad("任务已经结束，请创建后续任务再讨论")
      task -> if actor == :local or task["assigned_device_id"] == actor, do: :ok, else: forbidden()
    end
  end

  defp task_exists(_, nil), do: :ok

  defp task_exists(gid, tid) do
    if Enum.any?(Store.list_tasks(gid), &(&1["id"] == tid)), do: :ok, else: bad("关联任务不存在于本群")
  end

  defp optional_topic(_, nil), do: :ok

  defp optional_topic(room, tid) do
    case fetch(room["topics"], tid) do
      {:ok, _} -> :ok
      error -> error
    end
  end

  defp reply_exists(_, _, nil), do: :ok

  defp reply_exists(room, tid, mid) do
    if Enum.any?(room["messages"], &(&1["id"] == mid and &1["topic_id"] == tid)), do: :ok, else: bad("回复目标不属于当前议题")
  end

  defp message_author(_room, nil, _actor), do: {:ok, nil}

  defp message_author(room, rep_id, actor) when is_binary(rep_id) do
    with {:ok, rep} <- fetch(room["representatives"], rep_id),
         true <- rep["kind"] == "human",
         true <- owns?(actor, rep["device_id"]) do
      {:ok, rep}
    else
      false -> forbidden()
      error -> error
    end
  end

  defp message_author(_, _, _), do: bad("发言身份无效")

  # A stopped topic records no new directed invitations; the refusal is messaged instead.
  defp registerable_mentions(_room, nil, _targets), do: []

  defp registerable_mentions(room, topic_id, targets) do
    case room["topics"][topic_id] do
      %{"status" => "stopped"} -> []
      _ -> targets
    end
  end

  defp no_model_for_human("human", values) do
    if Enum.any?(values, &is_binary/1),
      do: bad("人类代表不调用模型，不能配置 provider 或 model"),
      else: :ok
  end

  defp no_model_for_human(_, _), do: :ok

  defp mention_ids(_room, nil), do: {:ok, []}

  defp mention_ids(room, ids) when is_list(ids) do
    ids = Enum.uniq(ids)

    cond do
      length(ids) > @max_mentions -> bad("一条消息最多定向邀请 #{@max_mentions} 位代表")
      not Enum.all?(ids, &is_binary/1) -> bad("提及目标格式无效")
      not Enum.all?(ids, &match?(%{"enabled" => true}, room["representatives"][&1])) -> bad("提及了不存在的代表")
      true -> {:ok, ids}
    end
  end

  defp mention_ids(_, _), do: bad("提及目标格式无效")

  defp mention_flag(nil), do: {:ok, false}
  defp mention_flag(value) when is_boolean(value), do: {:ok, value}
  defp mention_flag(_), do: bad("mention_all 必须为布尔值")

  defp mention_targets(_room, _group, ids, false, author_id), do: Enum.reject(ids, &(&1 == author_id))

  # @all is explicit, capped, and never includes the author.
  defp mention_targets(room, group, _ids, true, author_id) do
    room["representatives"]
    |> Map.values()
    |> Enum.filter(&available?(group, &1))
    |> Enum.reject(&(&1["id"] == author_id))
    |> Enum.sort_by(& &1["created_at"])
    |> Enum.take(@max_mentions)
    |> Enum.map(& &1["id"])
  end

  defp validated_mentions(_room, ids, _own) when not is_list(ids), do: []

  defp validated_mentions(room, ids, own) do
    ids
    |> Enum.filter(&is_binary/1)
    |> Enum.uniq()
    |> Enum.reject(&(&1 == own))
    |> Enum.filter(&match?(%{"enabled" => true}, room["representatives"][&1]))
    |> Enum.take(@max_mentions)
  end

  defp mention_after_agent(room, _group, _job, []), do: {room, nil}

  defp mention_after_agent(room, group, job, ids) do
    if is_binary(job["topic_id"]),
      do: mentions_after_message(room, group, job["topic_id"], ids, "agent"),
      else: {room, nil}
  end

  # While a round is running the request is queued; once the round ends it becomes a
  # bounded directed round of its own.
  defp mentions_after_message(room, group, topic_id, ids, origin) do
    topic = room["topics"][topic_id]

    cond do
      is_nil(topic) or ids == [] ->
        {room, nil}

      topic["status"] in @active ->
        pending =
          List.wrap(topic["pending_mentions"])
          |> Enum.reject(&(&1["rep_id"] in ids))
          |> Kernel.++(Enum.map(ids, &%{"rep_id" => &1, "origin" => origin, "created_at" => now()}))
          |> Enum.take(@max_mentions)

        {put_in(room, ["topics", topic_id, "pending_mentions"], pending), "已记录定向邀请，将在本轮讨论结束后生效。"}

      true ->
        dispatch_mentions(room, group, topic_id, ids, origin)
    end
  end

  defp dispatch_mentions(room, _group, _topic_id, [], _origin), do: {room, nil}

  defp dispatch_mentions(room, group, topic_id, ids, origin) do
    topic = room["topics"][topic_id] || %{}

    cond do
      topic == %{} ->
        {room, nil}

      topic["status"] == "stopped" ->
        {room, "定向邀请未生效：议题已停止；如需继续请重新发起讨论。"}

      (topic["run"] || 0) >= @max_mention_runs ->
        {room, "定向邀请未生效：该议题的定向发言轮次已达上限，请发起新的讨论。"}

      (topic["mentions_used"] || 0) + length(ids) > @max_mentions_per_topic ->
        {room, "定向邀请未生效：该议题的定向邀请次数已达上限。"}

      true ->
        targets =
          ids
          |> Enum.uniq()
          |> Enum.map(&room["representatives"][&1])
          |> Enum.filter(&available?(group, &1))
          |> Enum.take(@max_mentions)

        planned = Enum.count(targets, &(&1["kind"] != "human"))

        cond do
          targets == [] ->
            {room, "定向邀请未生效：相关代表当前不可用。"}

          (topic["calls"] || 0) + planned > topic["max_calls"] ->
            {room, "定向邀请未生效：该议题的模型调用预算已不足。"}

          true ->
            next_topic =
              Map.merge(topic, %{
                "status" => "mention",
                "round" => 0,
                "run" => (topic["run"] || 0) + 1,
                "participants" => Enum.map(targets, & &1["id"]),
                "mentions_used" => (topic["mentions_used"] || 0) + length(targets),
                "mention_origin" => origin
              })

            next = room |> put_in(["topics", topic_id], next_topic) |> schedule(next_topic, "mention", targets)
            {next, nil}
        end
    end
  end

  # A human answering or skipping their own wait window resolves that turn.
  defp resolve_human_wait(room, _topic_id, nil), do: room

  defp resolve_human_wait(room, topic_id, rep_id) do
    update_in(room, ["jobs"], fn jobs ->
      Map.new(jobs, fn {jid, job} ->
        if job["topic_id"] == topic_id and job["representative_id"] == rep_id and job["kind"] == "human" and
             job["status"] == "pending" do
          {jid, Map.merge(job, %{"status" => "answered", "result" => nil, "completed_at" => now()})}
        else
          {jid, job}
        end
      end)
    end)
  end

  defp with_notice(room, _topic_id, nil), do: room

  defp with_notice(room, topic_id, notice) when is_binary(notice) do
    if is_binary(topic_id), do: add_message(room, topic_id, "system", "notice", notice), else: room
  end

  # Humans cost no model call, so a human summariser never needs the extra slot.
  defp planned_calls(topic, reps, rounds) do
    agents = Enum.count(reps, &(&1["kind"] != "human"))
    topic["calls"] + agents * (rounds + 1) + if(agents == 0, do: 0, else: 1)
  end

  defp human_window(room) do
    case room["human_window_ms"] do
      value when is_integer(value) and value >= @min_human_window_ms and value <= @max_human_window_ms -> value
      _ -> @default_human_window_ms
    end
  end

  defp optional_bool(value, _label) when is_boolean(value), do: {:ok, value}
  defp optional_bool(nil, _label), do: {:ok, false}
  defp optional_bool(_value, label), do: bad(label <> " 必须为布尔值")

  defp optional_window(nil), do: {:ok, @default_human_window_ms}

  defp optional_window(value)
       when is_integer(value) and value >= @min_human_window_ms and value <= @max_human_window_ms,
       do: {:ok, value}

  defp optional_window(_),
    do: bad("human_window_ms 必须在 #{@min_human_window_ms} 到 #{@max_human_window_ms} 毫秒之间")

  defp fetch(map, key) do
    case Map.fetch(map, key) do
      {:ok, item} -> {:ok, item}
      :error -> {:error, "not_found", "代表、议题或工作项不存在"}
    end
  end

  defp text(value, max) when is_binary(value) do
    value = String.trim(value)
    if value != "" and String.length(value) <= max, do: {:ok, SharedContext.sanitize(value)}, else: bad("文本为空或超出长度上限")
  end

  defp text(_, _), do: bad("需要文本参数")
  defp optional_text(nil, _), do: {:ok, nil}
  defp optional_text("", _), do: {:ok, nil}
  defp optional_text(value, max), do: text(value, max)

  defp usage(value) when is_map(value),
    do:
      value
      |> Enum.filter(fn {k, v} ->
        k in ~w(prompt_tokens completion_tokens total_tokens cost) and is_number(v) and v >= 0
      end)
      |> Map.new()

  defp usage(_), do: %{}
  defp actor_name(:local), do: "local"
  defp actor_name(did), do: did
  defp bad(msg), do: {:error, "bad_request", msg}
  defp forbidden, do: {:error, "forbidden", "不能操作其他主机拥有的代表或议题"}
  defp now, do: System.system_time(:millisecond)
  defp id(prefix), do: prefix <> "_" <> Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false)
end
