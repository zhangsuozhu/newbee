defmodule Newbee.Colony.ExecutionV2Test do
  use ExUnit.Case, async: false
  alias Newbee.Colony.{Store, Engine, Control, Work, Runtime, Membership, Remote}

  setup do
    Store.clear_all()
    {:ok, colony} = Engine.create_colony(%{"name" => "执行边界"})
    %{cid: colony["id"], actor: colony["queen_bee_id"]}
  end

  test "only the human owner can acknowledge work and idle backlog is not active execution", %{cid: cid, actor: actor} do
    {:ok, task} = Work.create(cid, %{"title" => "真人工作", "assigned_bee_id" => actor})
    {:ok, colleague} = Engine.add_bee(cid, %{"display" => "同事", "kind" => "human"})
    assert {:error, "forbidden", _} = Work.continue(cid, task["id"], "接手", colleague["id"])
    assert {:ok, %{"stats" => %{"working" => 0}}} = Engine.view(cid)
    {:ok, _} = Work.continue(cid, task["id"], "接手", actor)
    assert {:ok, %{"stats" => %{"working" => 1}}} = Engine.view(cid)
    {:ok, _} = Work.submit(cid, task["id"], %{"content" => "完成，待验收"}, actor)
    assert {:ok, %{"stats" => %{"working" => 0}}} = Engine.view(cid)
  end

  test "receiver rechecks pause and acknowledges a retried delivery only once", %{
    cid: cid,
    actor: actor
  } do
    {:ok, task} = Work.create(cid, %{"title" => "投递边界"})
    [delivery] = Store.all("deliveries")
    sid = "receiver-boundary"

    Store.put("conversations", %{
      "id" => sid,
      "colony_id" => cid,
      "bee_id" => task["assigned_bee_id"],
      "task_id" => task["id"],
      "visibility" => "work"
    })

    state = %Newbee.Web.Session{sid: sid}
    message = {:colony_deliver, delivery["id"], "request", []}
    {:ok, _} = Control.set(cid, "colony", cid, "pause", actor_bee_id: actor)

    assert {:reply, {:error, :paused}, ^state} =
             Newbee.Web.Session.handle_call(message, nil, state)

    assert {:ok, %{"status" => "pending"}} = Store.get("deliveries", delivery["id"])
    {:ok, _} = Control.set(cid, "colony", cid, "resume", actor_bee_id: actor)
    assert {:reply, :ok, accepted} = Newbee.Web.Session.handle_call(message, nil, state)
    assert {:reply, :ok, ^accepted} = Newbee.Web.Session.handle_call(message, nil, accepted)
    assert :queue.len(accepted.queue) == 1
    assert {:ok, %{"status" => "accepted"}} = Store.get("deliveries", delivery["id"])
    trace = Store.trace_for_colony(cid, channel: "colony")
    assert Enum.count(trace, &(&1["data"]["delivery_id"] == delivery["id"])) == 1
    assert Enum.any?(trace, &String.contains?(&1["text"], "正在处理"))
  end

  test "paused group prevents queued work from even booting a session", %{cid: cid, actor: actor} do
    {:ok, task} = Work.create(cid, %{"title" => "等待执行"})
    {:ok, _} = Control.set(cid, "colony", cid, "pause", actor_bee_id: actor)
    Runtime.sweep()
    assert {:ok, %{"session_id" => nil}} = Store.get_task(task["id"])
    assert [%{"status" => "pending"}] = Store.all("deliveries")
    assert Control.state(cid, "colony", cid) == "paused"
  end

  test "resuming a group never clears a member or work pause", %{cid: cid, actor: actor} do
    {:ok, one} = Work.create(cid, %{"title" => "父工作"})
    {:ok, child} = Work.create(cid, %{"title" => "子工作", "parent_task_id" => one["id"]})
    {:ok, _} = Control.set(cid, "bee", one["assigned_bee_id"], "pause", actor_bee_id: actor)
    {:ok, _} = Control.set(cid, "work", one["id"], "pause", actor_bee_id: actor)
    {:ok, _} = Control.set(cid, "colony", cid, "pause", actor_bee_id: actor)
    {:ok, _} = Control.set(cid, "colony", cid, "resume", actor_bee_id: actor)
    assert Control.blocked?(cid, one["assigned_bee_id"], one["id"])
    {:ok, _} = Control.set(cid, "bee", one["assigned_bee_id"], "resume", actor_bee_id: actor)
    assert Control.blocked?(cid, child["assigned_bee_id"], child["id"])
    {:ok, _} = Control.set(cid, "work", one["id"], "resume", actor_bee_id: actor)
    refute Control.blocked?(cid, child["assigned_bee_id"], child["id"])
  end

  test "concurrent revisions allow only one writer and retain context", %{cid: cid, actor: actor} do
    {:ok, task} = Work.create(cid, %{"title" => "审查", "assigned_bee_id" => actor})

    results =
      1..8
      |> Elixir.Task.async_stream(
        fn i ->
          Work.revise(
            cid,
            task["id"],
            %{"revision" => task["revision"], "constraints" => ["constraint-" <> to_string(i)]},
            actor
          )
        end,
        max_concurrency: 8
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    assert Enum.count(results, &match?({:error, "conflict", _}, &1)) == 7
    assert {:ok, revised} = Store.get_task(task["id"])
    assert revised["context_revision"] == 1
    assert length(revised["decisions"]) == 1
    assert Work.context(revised) =~ hd(revised["constraints"])
  end

  test "old evidence cannot satisfy changed acceptance criteria", %{cid: cid, actor: actor} do
    {:ok, task} = Work.create(cid, %{"title" => "审核", "assigned_bee_id" => actor})
    {:ok, honey} = Work.submit(cid, task["id"], %{"content" => "旧要求下的审查结果"}, actor)
    {:ok, _} = Work.revise(cid, task["id"], %{"acceptance" => ["新增兼容性检查"]}, actor)
    assert {:error, "stale_result", _} = Work.review(cid, honey["id"], "accept", actor)
  end

  test "accepted delivery with a lost receiver is never replayed", %{cid: cid} do
    {:ok, task} = Work.create(cid, %{"title" => "外部操作"})
    [delivery] = Store.all("deliveries")

    Store.update(
      "deliveries",
      delivery["id"],
      nil,
      &{:ok, Map.merge(&1, %{"status" => "accepted", "session_id" => "missing-receiver"})}
    )

    Runtime.sweep()
    assert {:ok, %{"status" => "unknown"}} = Store.get("deliveries", delivery["id"])

    assert {:ok, %{"status" => "blocked", "assigned_bee_id" => owner}} =
             Store.get_task(task["id"])

    assert owner == task["assigned_bee_id"]
    Runtime.sweep()
    assert length(Store.all("deliveries")) == 1
  end

  test "remote reports are scoped, deduplicated and preserve execution revision", %{
    cid: cid,
    actor: actor
  } do
    {:ok, invite} = Membership.invite(cid, actor, %{"kind" => "ai"})
    {:ok, enrolled} = Membership.redeem(invite["code"], "远端执行者")
    assert {:error, "invalid_invite", _} = Membership.redeem(invite["code"], "重放邀请")

    {:ok, task} =
      Work.create(cid, %{"title" => "远端工作", "assigned_bee_id" => enrolled["bee"]["id"]})

    {:ok, foreign} = Work.create(cid, %{"title" => "其他负责人的工作", "assigned_bee_id" => actor})
    token = enrolled["token"]

    report = %{
      "id" => "event-1",
      "task_id" => foreign["id"],
      "kind" => "done",
      "payload" => %{"summary" => "不能伪造他人成果"}
    }

    assert {:ok, %{"processed" => [nil]}} =
             Remote.poll(%{"__device_token__" => token, "reports" => [report]})

    assert Store.honey_for_colony(cid) == []
    {:ok, _} = Work.revise(cid, task["id"], %{"constraints" => ["新的约束"]}, actor)
    report = Map.merge(report, %{"task_id" => task["id"], "work_revision" => 0})

    for _ <- 1..2 do
      assert {:ok, %{"processed" => ["event-1"]}} =
               Remote.poll(%{"__device_token__" => token, "reports" => [report]})
    end

    assert [honey] = Store.honey_for_colony(cid)
    assert honey["work_revision"] == 0
    assert {:error, "stale_result", _} = Work.review(cid, honey["id"], "accept", actor)
  end

  test "a disconnected remote member cannot acknowledge a pause", %{cid: cid, actor: actor} do
    {:ok, invite} = Membership.invite(cid, actor, %{"kind" => "ai"})
    {:ok, enrolled} = Membership.redeem(invite["code"], "离线环境")
    {:ok, gate} = Control.set(cid, "colony", cid, "pause", actor_bee_id: actor)
    assert gate["state"] == "pausing"

    assert {:ok, _} =
             Remote.poll(%{
               "__device_token__" => enrolled["token"],
               "controls" => %{
                 gate["id"] => %{"revision" => gate["revision"], "state" => "paused"}
               }
             })

    assert Control.state(cid, "colony", cid) == "paused"
    Membership.revoke(cid, enrolled["bee"]["id"], actor)
    assert {:error, "unauthorized", _} = Remote.poll(%{"__device_token__" => enrolled["token"]})
  end
end
