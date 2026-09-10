defmodule Newbee.Collaboration.ChatTest do
  use ExUnit.Case, async: false
  alias Newbee.Collaboration.{Chat, SharedContext}
  alias Newbee.Collaboration.Chat.{Room, Runner}
  alias Newbee.Collaboration.CrossHost.{Auth, Group, Store, Bridge}

  setup do
    Store.clear()
    {:ok, group, _} = Group.create("项目议事厅", "chat-project")
    {:ok, group, a} = Auth.issue_device(group, "owner-a", "主机A")
    {:ok, group, b} = Auth.issue_device(group, "owner-b", "主机B")
    :ok = Store.put_group(group)
    on_exit(fn -> Store.clear() end)
    %{gid: group["id"], group: group, a: a, b: b}
  end

  defp rep(gid, device, name) do
    {:ok, value} = Room.command(gid, "representative.create", %{"device_id" => device["id"], "name" => name})
    value
  end

  defp topic(gid, opts \\ %{}) do
    {:ok, value} =
      Room.command(
        gid,
        "topic.open",
        Map.merge(%{"title" => "跨主机文件替换故障", "problem" => "A成功、B失败。需要验证文件句柄关闭顺序。", "base_revision" => "abc"}, opts)
      )

    value
  end

  defp complete(gid, job, body \\ "建议补充文件句柄关闭的回归用例") do
    assert {:ok, _} =
             Room.command(
               gid,
               "job.complete",
               %{"job_id" => job["id"], "body" => body, "usage" => %{"total_tokens" => 25}},
               job["device_id"]
             )
  end

  defp drain(gid, devices, rounds \\ 8)
  defp drain(_, _, 0), do: flunk("discussion did not terminate")

  defp drain(gid, devices, remaining) do
    jobs = Enum.flat_map(devices, &Room.jobs(gid, &1["id"]))

    if jobs == [],
      do: Room.snapshot(gid),
      else:
        (
          Enum.each(jobs, &complete(gid, &1))
          drain(gid, devices, remaining - 1)
        )
  end

  test "one host has several persistent representatives and only owns its own identities", %{gid: gid, a: a, b: b} do
    r1 = rep(gid, a, "岩松")
    r2 = rep(gid, a, "小桥")
    assert r1["id"] != r2["id"]
    assert r1["focus"] != r2["focus"]
    assert r1["device_id"] == r2["device_id"]

    assert {:error, "forbidden", _} =
             Room.command(gid, "representative.update", %{"representative_id" => r1["id"], "name" => "冒名"}, b["id"])

    assert {:ok, own} =
             Bridge.chat(%{
               "device_id" => b["id"],
               "token" => b["plain"],
               "action" => "representative.create",
               "params" => %{"device_id" => a["id"], "name" => "本机代表"}
             })

    assert own["device_id"] == b["id"]
    assert Room.snapshot(gid)["representatives"] |> Enum.find(&(&1["id"] == r1["id"])) == Map.put(r1, "available", true)
    for i <- 3..6, do: rep(gid, a, "代表#{i}")
    assert {:error, "bad_request", _} = Room.command(gid, "representative.create", %{"device_id" => a["id"]})
  end

  test "independent drafts stay private, rounds terminate, and replies are idempotent", %{gid: gid, a: a, b: b} do
    ra = rep(gid, a, "岩松")
    rep(gid, a, "小桥")
    rb = rep(gid, b, "木木")
    t = topic(gid)
    assert {:ok, _} = Room.command(gid, "discussion.start", %{"topic_id" => t["id"], "rounds" => 2})
    [aj | _] = Room.jobs(gid, a["id"])
    assert aj["messages"] == []
    complete(gid, aj, "独立证据-A")
    refute Enum.any?(Room.snapshot(gid)["messages"], &(&1["body"] == "独立证据-A"))
    [bj] = Room.jobs(gid, b["id"])
    assert bj["messages"] == []
    assert bj["representative_id"] == rb["id"]

    assert {:error, "forbidden", _} =
             Room.command(gid, "job.complete", %{"job_id" => bj["id"], "body" => "伪造"}, a["id"])

    assert {:ok, %{"duplicate" => true}} =
             Room.command(gid, "job.complete", %{"job_id" => aj["id"], "body" => "重复"}, a["id"])

    room = drain(gid, [a, b])
    [result] = room["topics"]
    assert result["status"] == "proposed"
    # 3 位代表：独立 3 次 + 讨论两轮各 2 次（说过最后一句的人不重复付费）+ 总结 1 次。
    assert result["calls"] == 8
    assert result["skips"] == 2
    assert result["decision"]["status"] == "proposed"
    assert Enum.count(room["messages"], &(&1["body"] == "独立证据-A")) == 1
    assert Enum.any?(room["messages"], &(&1["representative_id"] == ra["id"]))
    refute Jason.encode!(room) =~ "token_hash"
    refute Map.has_key?(room, "jobs")
  end

  test "stopping cancels outstanding work and prevents late replies changing state", %{gid: gid, a: a, b: b} do
    rep(gid, a, "甲")
    rep(gid, b, "乙")
    t = topic(gid)
    {:ok, _} = Room.command(gid, "discussion.start", %{"topic_id" => t["id"]})
    [job] = Room.jobs(gid, a["id"])
    {:ok, _} = Room.command(gid, "discussion.stop", %{"topic_id" => t["id"]})
    complete(gid, job, "迟到消息")
    assert Room.jobs(gid, b["id"]) == []
    assert hd(Room.snapshot(gid)["topics"])["status"] == "stopped"
    refute Enum.any?(Room.snapshot(gid)["messages"], &(&1["body"] == "迟到消息"))
  end

  test "paused and missing devices cannot participate or post through bridge", %{gid: gid, a: a, b: b, group: group} do
    rep(gid, a, "甲")
    rep(gid, b, "乙")
    t = topic(gid)
    Store.put_group(put_in(group, ["devices", b["id"], "paused"], true))
    assert {:error, "bad_request", _} = Room.command(gid, "discussion.start", %{"topic_id" => t["id"]})
    assert {:error, _, _} = Bridge.chat(%{"device_id" => b["id"], "token" => b["plain"], "action" => "snapshot"})
    assert {:error, _, _} = Bridge.chat(%{"device_id" => a["id"], "token" => "wrong", "action" => "snapshot"})
  end

  test "bound sessions can propose but outsiders cannot, shared snapshots expose chat", %{gid: gid, a: a} do
    assert {:error, "not_member", _} = Chat.for_session("outsider", gid, "snapshot", %{})

    Store.bind_session(%{
      "session_id" => "chat-author",
      "group_id" => gid,
      "device_id" => a["id"],
      "member_id" => a["member_id"]
    })

    assert {:ok, t} = Chat.for_session("chat-author", gid, "topic.open", %{"title" => "问题", "problem" => "请求交叉验证"})
    assert t["owner_device_id"] == a["id"]
    assert {:ok, shared} = SharedContext.fetch("chat-author", gid <> "/chat")
    assert length(shared["topics"]) == 1
    assert {:ok, snapshot} = SharedContext.remote_snapshot(gid)
    assert snapshot["chat"]["topics"] == shared["topics"]
    assert {:error, "not_member", _} = Chat.for_session("chat-author", gid, "representative.create", %{})
  end

  test "topic and human message retries deduplicate; cross-thread replies are rejected", %{gid: gid} do
    t = topic(gid, %{"command_id" => "retry-open"})
    again = topic(gid, %{"command_id" => "retry-open"})
    assert again["id"] == t["id"]
    params = %{"topic_id" => t["id"], "body" => "补充证据", "command_id" => "retry-post"}
    {:ok, message} = Room.command(gid, "message.post", params)
    assert {:ok, ^message} = Room.command(gid, "message.post", params)
    another = topic(gid)

    assert {:error, "bad_request", _} =
             Room.command(gid, "message.post", %{
               "topic_id" => another["id"],
               "reply_to" => message["id"],
               "body" => "错线程"
             })
  end

  test "decision application is versioned, scoped to assigned session and baseline-checked", %{gid: gid, a: a, b: b} do
    {sha, 0} = System.cmd("git", ["rev-parse", "HEAD"])
    sha = String.trim(sha)

    Store.put_task(%{
      "id" => "chat-task",
      "group_id" => gid,
      "assigned_session_id" => "chat-executor",
      "status" => "running"
    })

    Store.bind_session(%{"session_id" => "chat-executor", "group_id" => gid, "device_id" => a["id"]})
    rep(gid, a, "甲")
    rep(gid, b, "乙")
    t = topic(gid, %{"task_id" => "chat-task", "base_revision" => sha})
    {:ok, _} = Room.command(gid, "discussion.start", %{"topic_id" => t["id"], "rounds" => 1})
    [result] = drain(gid, [a, b])["topics"]
    p = %{"topic_id" => t["id"], "version" => result["decision"]["version"], "base_revision" => sha}
    assert {:error, "bad_request", _} = Room.command(gid, "decision.apply", Map.put(p, "base_revision", "stale"))
    assert {:error, "bad_request", _} = Room.command(gid, "decision.apply", Map.put(p, "version", 99))
    assert {:ok, _} = Room.command(gid, "decision.apply", p)
    assert {:ok, _} = Room.command(gid, "decision.apply", p)
    assert length(hd(Room.snapshot(gid)["topics"])["applications"]) == 1
    assert length(Chat.decisions_for("chat-executor")) == 1
    assert Chat.decisions_for("other") == []
    msgs = [%{"role" => "user", "content" => "运行任务"}]
    clean_root = Path.join(Newbee.GlobalStore.root(), "chat-clean-6723")

    {_, 0} =
      System.cmd("git", ["clone", "--local", "--no-hardlinks", "--quiet", File.cwd!(), clean_root],
        stderr_to_stdout: true
      )

    on_exit(fn -> File.rm_rf(clean_root) end)
    injected = Chat.execution_messages(msgs, %{id: "chat-executor"}, clean_root)
    assert length(injected) == 2
    assert List.last(injected)["content"] =~ "\"baseline_matches\":true"
    assert List.last(injected)["role"] == "user"
    File.write!(Path.join(clean_root, "unverified-change.txt"), "changed")
    stale = Chat.execution_messages(msgs, %{id: "chat-executor"}, clean_root)
    assert List.last(stale)["content"] =~ "\"baseline_matches\":false"
    assert length(Chat.execution_messages(msgs, %{id: "other"}, File.cwd!())) == 1

    Store.put_task(%{
      "id" => "chat-task",
      "group_id" => gid,
      "assigned_session_id" => "chat-executor",
      "status" => "done",
      "result" => "命令退出0"
    })

    assert Chat.decisions_for("chat-executor") == []
    room = Room.snapshot(gid)
    assert Enum.any?(room["messages"], &(&1["kind"] == "execution"))
    assert hd(room["topics"])["decision"]["status"] == "proposed"
  end

  test "persistent room survives server restart and snapshot never includes credentials", %{gid: gid, a: a} do
    rep = rep(gid, a, "稳定人设")
    before = Room.snapshot(gid)
    pid = Process.whereis(Room)
    Supervisor.terminate_child(Newbee.Supervisor, Room)
    assert {:ok, _} = Supervisor.restart_child(Newbee.Supervisor, Room)
    refute Process.alive?(pid)
    after_restart = Room.snapshot(gid)
    assert before == after_restart
    assert hd(after_restart["representatives"])["style"] == rep["style"]
    refute Jason.encode!(after_restart) =~ a["plain"]
  end

  test "runner uses real job lifecycle, deduplicates delivery, and can finish a whole discussion", %{
    gid: gid,
    a: a,
    b: b
  } do
    rep(gid, a, "甲")
    rep(gid, b, "乙")
    t = topic(gid)
    {:ok, _} = Room.command(gid, "discussion.start", %{"topic_id" => t["id"], "rounds" => 1})
    owner = self()

    generator = fn job ->
      send(owner, {:generated, job["id"]})
      {:ok, "可验证建议", %{usage: %{"total_tokens" => 10}}}
    end

    start_supervised!({Runner, name: __MODULE__.Runner, tick: false, generator: generator})

    for _ <- 1..6 do
      jobs = Enum.flat_map([a, b], &Room.jobs(gid, &1["id"]))
      Runner.enqueue(jobs ++ jobs, :local, __MODULE__.Runner)
      wait_idle(__MODULE__.Runner)
    end

    assert hd(Room.snapshot(gid)["topics"])["status"] == "proposed"
    messages = collect_generated([])
    assert length(messages) == length(Enum.uniq(messages))
    # 独立 2 次 + 讨论 1 次（最后发言者静默）+ 总结 1 次。\n    assert length(messages) == 4
  end

  test "automatic failure topics are opt-in, deduplicated and rate bounded", %{gid: gid, a: a, b: b} do
    rep(gid, a, "甲")
    rep(gid, b, "乙")

    for n <- 1..5,
        do: Store.put_task(%{"id" => "auto-task-#{n}", "group_id" => gid, "title" => "任务#{n}", "status" => "failed"})

    assert Room.snapshot(gid)["topics"] == []
    {:ok, _} = Room.command(gid, "settings", %{"auto_discuss" => true})
    snapshot = Room.snapshot(gid)
    assert length(snapshot["topics"]) == 3
    assert length(Room.snapshot(gid)["topics"]) == 3
  end

  test "claims survive restart, preserve private drafts and cannot be claimed twice", %{gid: gid, a: a, b: b} do
    rep(gid, a, "甲")
    rep(gid, b, "乙")
    t = topic(gid)
    {:ok, _} = Room.command(gid, "discussion.start", %{"topic_id" => t["id"], "rounds" => 1})
    [job] = Room.jobs(gid, a["id"])
    assert {:ok, _} = Room.command(gid, "job.claim", %{"job_id" => job["id"]}, a["id"])
    Supervisor.terminate_child(Newbee.Supervisor, Room)
    assert {:ok, _} = Supervisor.restart_child(Newbee.Supervisor, Room)
    assert {:error, "job_unavailable", _} = Room.command(gid, "job.claim", %{"job_id" => job["id"]}, a["id"])
    complete(gid, job, "重启后保留的独立证据")
    refute Enum.any?(Room.snapshot(gid)["messages"], &(&1["body"] == "重启后保留的独立证据"))
    Supervisor.terminate_child(Newbee.Supervisor, Room)
    assert {:ok, _} = Supervisor.restart_child(Newbee.Supervisor, Room)
    [other] = Room.jobs(gid, b["id"])
    assert other["messages"] == []
    complete(gid, other)
    assert Enum.any?(Room.snapshot(gid)["messages"], &(&1["body"] == "重启后保留的独立证据"))
  end

  test "expired persisted work becomes unresolved, late completions cannot reopen it", %{gid: gid, a: a, b: b} do
    rep(gid, a, "甲")
    rep(gid, b, "乙")
    t = topic(gid)
    {:ok, _} = Room.command(gid, "discussion.start", %{"topic_id" => t["id"]})
    [job] = Room.jobs(gid, a["id"])
    hash = :crypto.hash(:sha256, gid) |> Base.encode16(case: :lower)
    path = Path.join(Path.dirname(Store.persist_path()), "chat-test-" <> hash <> ".json")
    stored = path |> File.read!() |> Jason.decode!()
    expired = update_in(stored, ["jobs"], &Map.new(&1, fn {id, j} -> {id, Map.put(j, "deadline", 0)} end))
    File.write!(path, Jason.encode!(expired))
    assert hd(Room.snapshot(gid)["topics"])["status"] == "unresolved"
    complete(gid, job, "过期结论")
    refute Enum.any?(Room.snapshot(gid)["messages"], &(&1["body"] == "过期结论"))
  end

  test "runner timeout reports failure and cancelled queued jobs never invoke a model", %{gid: gid, a: a, b: b} do
    rep(gid, a, "甲")
    rep(gid, b, "乙")
    t = topic(gid)
    {:ok, _} = Room.command(gid, "discussion.start", %{"topic_id" => t["id"]})
    jobs = Room.jobs(gid, a["id"])
    runner = __MODULE__.TimeoutRunner
    start_supervised!({Runner, name: runner, tick: false, timeout: 10, generator: fn _ -> Process.sleep(5000) end})
    Runner.enqueue(jobs, :local, runner)
    wait_idle(runner)
    [other] = Room.jobs(gid, b["id"])
    {:ok, _} = Room.command(gid, "discussion.stop", %{"topic_id" => t["id"]})
    parent = self()
    second = __MODULE__.CancelledRunner

    start_supervised!(
      {Runner,
       name: second,
       tick: false,
       generator: fn _ ->
         send(parent, :unexpected_call)
         {:ok, "不应调用", %{}}
       end},
      id: :cancelled_runner
    )

    Runner.enqueue([other], :local, second)
    wait_idle(second)
    refute_receive :unexpected_call
    assert hd(Room.snapshot(gid)["topics"])["status"] == "stopped"
  end

  test "empty model answers become terminal errors with usage rather than retrying forever", %{gid: gid, a: a, b: b} do
    rep(gid, a, "甲")
    rep(gid, b, "乙")
    t = topic(gid)
    {:ok, _} = Room.command(gid, "discussion.start", %{"topic_id" => t["id"]})
    runner = __MODULE__.EmptyRunner

    start_supervised!(
      {Runner, name: runner, tick: false, generator: fn _ -> {:ok, "  ", %{usage: %{"total_tokens" => 800}}} end}
    )

    for device <- [a, b], do: Runner.enqueue(Room.jobs(gid, device["id"]), :local, runner)
    wait_idle(runner)
    snapshot = Room.snapshot(gid)
    assert hd(snapshot["topics"])["status"] == "unresolved"
    assert hd(snapshot["topics"])["usage"]["total_tokens"] == 1600
    assert Enum.count(snapshot["messages"], &(&1["kind"] == "error")) == 2
    assert Room.jobs(gid, a["id"]) == []
  end

  defp human(gid, name) do
    {:ok, value} = Room.command(gid, "representative.create", %{"kind" => "human", "name" => name})
    value
  end

  defp rep_named(gid, name), do: Enum.find(Room.snapshot(gid)["representatives"], &(&1["name"] == name))

  @active_phases ["independent", "discussing", "summarizing", "mention"]

  # Test stand-in for the humans and workers: skips open waits and answers agent turns.
  defp service(gid, devices, rounds \\ 14) do
    Enum.reduce_while(1..rounds, Room.snapshot(gid), fn _, _ ->
      snapshot = Room.snapshot(gid)
      topic = snapshot["topics"] |> Enum.find(&(&1["status"] in @active_phases))

      if is_nil(topic) do
        {:halt, snapshot}
      else
        Enum.each(topic["open_waits"], fn wait -> _ = Room.command(gid, "job.skip", %{"job_id" => wait["job_id"]}) end)
        jobs = Enum.flat_map(devices, &Room.jobs(gid, &1))
        Enum.each(jobs, &complete(gid, &1, "自动回复：已复核。"))
        after_all = Room.snapshot(gid)
        now = after_all["topics"] |> Enum.find(&(&1["id"] == topic["id"]))

        if jobs == [] and (is_nil(now) or (now["status"] not in @active_phases and now["open_waits"] == [])) do
          {:halt, after_all}
        else
          {:cont, after_all}
        end
      end
    end)
  end

  test "human representatives speak as themselves and never cost a model call", %{gid: gid, a: a} do
    agent = rep(gid, a, "岩松")
    person = human(gid, "Alan")
    assert person["kind"] == "human"
    assert person["device_id"] == "local"
    assert person["provider"] == nil and person["model"] == nil
    assert rep_named(gid, "Alan")["available"] == true

    t = topic(gid)

    assert {:ok, _} =
             Room.command(gid, "discussion.start", %{
               "topic_id" => t["id"],
               "rounds" => 1,
               "participants" => [agent["id"], person["id"]]
             })

    now = hd(Room.snapshot(gid)["topics"])
    assert now["calls"] == 1
    assert now["waits"] == 1
    assert now["open_waits_for"] == [person["id"]]
    assert [%{"name" => "Alan"}] = now["open_waits"]
    assert Room.jobs(gid, a["id"]) |> Enum.map(& &1["phase"]) == ["independent"]
    # A human turn is never handed to a worker.
    assert Room.jobs(gid, "local") == []

    assert {:ok, message} =
             Room.command(gid, "message.post", %{
               "topic_id" => t["id"],
               "representative_id" => person["id"],
               "body" => "我的人类看法：先保证可观察性。"
             })

    assert message["representative_id"] == person["id"]
    assert message["name"] == "Alan"
    assert hd(Room.snapshot(gid)["topics"])["open_waits"] == []

    result = service(gid, [a["id"]])
    topic_now = hd(result["topics"])
    assert topic_now["status"] == "proposed"
    assert Enum.any?(result["messages"], &(&1["body"] == "我的人类看法：先保证可观察性。"))
    assert Enum.any?(result["messages"], &(&1["kind"] == "agent"))
    assert topic_now["uses_human"] || topic_now["calls"] >= 1
  end

  test "an explicit skip records the human choice without a model call", %{gid: gid, a: a} do
    agent = rep(gid, a, "小桥")
    person = human(gid, "Alan")
    t = topic(gid)

    {:ok, _} =
      Room.command(gid, "discussion.start", %{
        "topic_id" => t["id"],
        "rounds" => 1,
        "participants" => [agent["id"], person["id"]]
      })

    [wait] = hd(Room.snapshot(gid)["topics"])["open_waits"]
    assert {:ok, %{"skipped" => true}} = Room.command(gid, "job.skip", %{"job_id" => wait["job_id"]})
    assert hd(Room.snapshot(gid)["topics"])["open_waits"] == []

    # Nobody else may skip a human's turn, and a resolved turn cannot be replayed.
    assert {:error, "bad_request", _} = Room.command(gid, "job.skip", %{"job_id" => wait["job_id"]}, a["id"])
    assert {:error, "bad_request", _} = Room.command(gid, "job.skip", %{"job_id" => wait["job_id"]})

    result = service(gid, [a["id"]])
    assert hd(result["topics"])["status"] == "proposed"
  end

  test "an unanswered human window expires and never blocks the discussion", %{gid: gid, a: a} do
    agent = rep(gid, a, "小桥")
    person = human(gid, "Alan")
    {:ok, _} = Room.command(gid, "settings", %{"human_window_ms" => 1_000})
    t = topic(gid)

    {:ok, _} =
      Room.command(gid, "discussion.start", %{
        "topic_id" => t["id"],
        "rounds" => 1,
        "participants" => [agent["id"], person["id"]]
      })

    assert hd(Room.snapshot(gid)["topics"])["open_waits_for"] == [person["id"]]

    result =
      Enum.reduce_while(1..8, nil, fn _, _ ->
        Process.sleep(1_100)
        _ = Enum.map(Room.jobs(gid, a["id"]), &complete(gid, &1, "证据回复。"))
        snapshot = Room.snapshot(gid)
        topic_now = hd(snapshot["topics"])

        if topic_now["status"] in ["proposed", "unresolved"],
          do: {:halt, snapshot},
          else: {:cont, snapshot}
      end)

    assert hd(result["topics"])["status"] == "proposed"
    assert hd(result["topics"])["open_waits"] == []
  end

  test "directed mentions wake only the named representative and track who has not replied", %{gid: gid, a: a, b: b} do
    rep(gid, a, "岩松")
    target = rep(gid, b, "木木")
    person = human(gid, "Alan")
    t = topic(gid)

    assert {:ok, message} =
             Room.command(gid, "message.post", %{
               "topic_id" => t["id"],
               "representative_id" => person["id"],
               "body" => "请 @木木 复核 Windows 结论。",
               "mentions" => [target["id"]]
             })

    assert message["mentions"] == [target["id"]]
    assert message["mention_all"] == false

    topic_now = hd(Room.snapshot(gid)["topics"])
    assert topic_now["status"] == "mention"
    assert topic_now["calls"] == 1
    assert topic_now["open_mentions"] |> Enum.map(& &1["representative_id"]) == [target["id"]]

    [job] = Room.jobs(gid, b["id"])
    assert job["phase"] == "mention"
    assert job["representative_id"] == target["id"]
    # Only the named host is woken.
    assert Room.jobs(gid, a["id"]) == []

    # Unknown targets are rejected up front rather than silently ignored.
    assert {:error, "bad_request", _} =
             Room.command(gid, "message.post", %{"topic_id" => t["id"], "body" => "x", "mentions" => ["rep_missing"]})

    complete(gid, job, "复核完成：Windows 侧确实会失败。")
    after_reply = hd(Room.snapshot(gid)["topics"])
    assert after_reply["status"] == "open"
    assert after_reply["open_mentions"] == []
  end

  test "mention-all is capped, excludes the author, and cannot revive a stopped topic", %{gid: gid, a: a, b: b} do
    for i <- 1..7, do: rep(gid, if(rem(i, 2) == 0, do: a, else: b), "代表#{i}")
    person = human(gid, "Alan")
    t = topic(gid)

    assert {:ok, message} =
             Room.command(gid, "message.post", %{
               "topic_id" => t["id"],
               "representative_id" => person["id"],
               "body" => "请大家看一下",
               "mention_all" => true
             })

    assert length(message["mentions"]) == 5
    refute person["id"] in message["mentions"]

    assert Enum.all?(message["mentions"], fn id ->
             Enum.find(Room.snapshot(gid)["representatives"], &(&1["id"] == id))["kind"] == "agent"
           end)

    assert {:ok, _} = Room.command(gid, "discussion.stop", %{"topic_id" => t["id"]})

    assert {:ok, stopped} =
             Room.command(gid, "message.post", %{
               "topic_id" => t["id"],
               "representative_id" => person["id"],
               "body" => "再说一句",
               "mentions" => [hd(message["mentions"])]
             })

    # A stopped topic never gets new directed rounds; the refusal is visible and the
    # message still records who the author tried to reach.
    assert stopped["mentions"] == []
    assert hd(Room.snapshot(gid)["topics"])["status"] == "stopped"
    assert Enum.any?(Room.snapshot(gid)["messages"], &(&1["kind"] == "notice"))
    assert Room.jobs(gid, a["id"]) == [] and Room.jobs(gid, b["id"]) == []
  end

  test "agent mentions queue behind a running round, drop own/unknown targets, and run afterwards", %{
    gid: gid,
    a: a,
    b: b
  } do
    first = rep(gid, a, "岩松")
    second = rep(gid, b, "木木")
    t = topic(gid)

    {:ok, _} =
      Room.command(gid, "discussion.start", %{
        "topic_id" => t["id"],
        "rounds" => 1,
        "participants" => [first["id"], second["id"]]
      })

    [job] = Room.jobs(gid, a["id"])

    assert {:ok, _} =
             Room.command(
               gid,
               "job.complete",
               %{
                 "job_id" => job["id"],
                 "body" => "请 @木木 补充。",
                 "mentions" => [second["id"], first["id"], "rep_unknown"]
               },
               a["id"]
             )

    # The mention cannot start a new round while the first one is running: the second
    # participant still owes its independent answer.
    [job_b] = Room.jobs(gid, b["id"])
    complete(gid, job_b, "乙的独立意见。")
    assert hd(Room.snapshot(gid)["topics"])["status"] == "discussing"

    result = service(gid, [a["id"], b["id"]])
    first_message = result["messages"] |> Enum.find(&(&1["representative_id"] == first["id"]))
    assert first_message["mentions"] == [second["id"]]

    # After the queued mention was dispatched and answered, it is recorded with a phase.
    directed =
      result["messages"] |> Enum.filter(&(&1["representative_id"] == second["id"] and &1["phase"] == "mention"))

    assert length(directed) == 1
    assert hd(result["topics"])["status"] in ["open", "proposed"]
  end

  test "a representative that already spoke last is not paid again for silence", %{gid: gid, a: a, b: b} do
    first = rep(gid, a, "岩松")
    second = rep(gid, b, "木木")
    t = topic(gid)

    {:ok, _} =
      Room.command(gid, "discussion.start", %{
        "topic_id" => t["id"],
        "rounds" => 1,
        "participants" => [first["id"], second["id"]]
      })

    [job_a] = Room.jobs(gid, a["id"])
    [job_b] = Room.jobs(gid, b["id"])
    complete(gid, job_a, "甲的第一轮意见。")
    complete(gid, job_b, "乙的第一轮意见。")

    result = service(gid, [a["id"], b["id"]])
    topic_now = hd(result["topics"])

    assert topic_now["status"] == "proposed"
    # 2 independent + 1 discussing (the last speaker is silent) + 1 summary.
    assert topic_now["calls"] == 4
    assert topic_now["skips"] == 1
    assert Enum.count(result["messages"], &(&1["kind"] == "skipped")) == 1
  end

  test "human representatives reject model fields and expose window settings", %{gid: gid} do
    person = human(gid, "Alan")
    assert person["kind"] == "human"
    assert {:ok, _} = Room.command(gid, "settings", %{"human_window_ms" => 5_000})
    room = Room.snapshot(gid)
    assert room["human_window_ms"] == 5_000
    assert room["limits"]["mentions_per_message"] == 5

    assert {:error, "bad_request", _} = Room.command(gid, "settings", %{"human_window_ms" => 10})

    assert {:error, "bad_request", _} =
             Room.command(gid, "representative.create", %{"kind" => "human", "name" => "x", "provider" => "vendor"})

    assert room["human_window_ms"] == 5_000
  end

  # The suite runs with up to 16 cases in parallel, so one delivery chain can be
  # slow under load; wait on the real state instead of a tight 1 s guess.
  defp wait_idle(name, tries \\ 600)

  defp wait_idle(_, 0), do: flunk("runner did not finish")

  defp wait_idle(name, tries) do
    state = :sys.get_state(name)

    if state.active == nil and state.queue == [],
      do: :ok,
      else:
        (
          Process.sleep(25)
          wait_idle(name, tries - 1)
        )
  end

  defp collect_generated(acc) do
    receive do
      {:generated, id} -> collect_generated([id | acc])
    after
      0 -> acc
    end
  end
end
