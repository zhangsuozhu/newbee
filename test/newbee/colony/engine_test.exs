defmodule Newbee.Colony.EngineTest do
  use ExUnit.Case, async: false

  alias Newbee.Colony.{Engine, Store, Task}

  setup do
    Store.clear_all()
    {:ok, colony} = Engine.create_colony(%{"name" => "测试蜂群", "goal" => "验证协作流"})
    %{colony: colony, cid: colony["id"]}
  end

  test "创建蜂群自动生成 Queen（人）", %{colony: colony} do
    assert colony["queen_bee_id"]
    {:ok, queen} = Store.get_bee(colony["queen_bee_id"])
    assert queen["kind"] == "human"
    assert queen["role"] == "queen"
    bees = Store.bees_for_colony(colony["id"])
    assert Enum.any?(bees, &(&1["kind"] == "ai" and &1["display"] == "研发助手"))
  end

  test "加人与移出：任务回流、成果保留", %{cid: cid} do
    {:ok, auth} =
      Engine.add_bee(cid, %{"display" => "auth-bot", "kind" => "ai", "capabilities" => ["edit"]})

    {:ok, task} =
      Engine.create_task(cid, %{
        "title" => "重构",
        "requires" => ["edit"],
        "assignee_display" => "auth-bot"
      })

    assert task["assigned_bee_id"] == auth["id"]

    {:ok, honey} =
      Engine.add_honey(cid, %{"bee_id" => auth["id"], "task_id" => task["id"], "title" => "产出"})

    {:ok, _} = Engine.remove_bee(cid, auth["id"])

    # Bee 不在群里了
    {:ok, view} = Engine.view(cid)
    refute Enum.any?(view["members"], &(&1["id"] == auth["id"]))

    # 任务回流
    {:ok, reflowed} = Store.get_task(task["id"])
    assert reflowed["status"] == "blocked"
    assert reflowed["assigned_bee_id"] == auth["id"]
    assert reflowed["approval_required"]

    # 成果保留
    assert {:ok, _} = Store.get_honey(honey["id"])
  end

  test "阈值自领取：能力匹配者领取，能力不足者被拒", %{cid: cid} do
    {:ok, editor} =
      Engine.add_bee(cid, %{"display" => "editor-bot", "kind" => "ai", "capabilities" => ["edit"]})

    {:ok, tester} =
      Engine.add_bee(cid, %{"display" => "test-bot", "kind" => "ai", "capabilities" => ["test"]})

    {:ok, task} = Engine.create_task(cid, %{"title" => "改代码", "requires" => ["edit"]})

    assert {:error, "incapable", _} = Engine.claim_task(cid, task["id"], tester["id"])
    assert {:ok, claimed} = Engine.claim_task(cid, task["id"], editor["id"])
    assert claimed["assigned_bee_id"] == editor["id"]

    # 已被领取 → 冲突
    {:ok, editor2} =
      Engine.add_bee(cid, %{
        "display" => "editor2-bot",
        "kind" => "ai",
        "capabilities" => ["edit"]
      })

    assert {:error, "conflict", _} = Engine.claim_task(cid, task["id"], editor2["id"])
  end

  test "任务拆分受预算约束，子任务可继续下钻", %{cid: cid} do
    {:ok, lead} =
      Engine.add_bee(cid, %{"display" => "lead-bot", "kind" => "ai", "capabilities" => ["edit"]})

    {:ok, task} =
      Engine.create_task(cid, %{
        "title" => "大任务",
        "requires" => ["edit"],
        "assignee_display" => "lead-bot"
      })

    {:ok, children} =
      Engine.decompose_task(
        cid,
        task["id"],
        [%{"title" => "a"}, %{"title" => "b"}, %{"title" => "c"}, %{"title" => "d"}],
        bee_id: lead["id"]
      )

    assert length(children) == 4

    assert {:error, "budget_exceeded", _} =
             Engine.decompose_task(cid, task["id"], [%{"title" => "e"}], bee_id: lead["id"])

    {:ok, drill} = Engine.drill(cid, task["id"])
    assert length(drill["tasks"]) == 5

    assert Enum.all?(
             drill["tasks"],
             &(&1["id"] == task["id"] or &1["parent_task_id"] == task["id"])
           )
  end

  test "成果验收闭环", %{cid: cid} do
    {:ok, bee} =
      Engine.add_bee(cid, %{"display" => "bot", "kind" => "ai", "capabilities" => ["edit"]})

    {:ok, task} = Engine.create_task(cid, %{"title" => "产出", "requires" => ["edit"]})
    {:ok, _} = Engine.claim_task(cid, task["id"], bee["id"])

    {:ok, honey} =
      Engine.add_honey(cid, %{
        "bee_id" => bee["id"],
        "task_id" => task["id"],
        "title" => "代码",
        "checks" => [%{"check" => "test_pass", "ok" => true}]
      })

    assert get_in(honey, ["review", "state"]) == "auto_verified"

    {:ok, accepted} = Engine.review_honey(cid, honey["id"], "accept", bee_id: cid)
    assert get_in(accepted, ["review", "state"]) == "accepted"

    {:ok, view} = Engine.view(cid)
    assert view["stats"]["honey_accepted"] == 1
  end

  test "signal 校验与冷却", %{cid: cid} do
    {:ok, bee} =
      Engine.add_bee(cid, %{"display" => "bot", "kind" => "ai", "capabilities" => ["edit"]})

    assert {:error, "quality_required", _} =
             Engine.emit_signal(cid, %{"kind" => "recommend", "from_bee_id" => bee["id"]})

    {:ok, _} =
      Engine.emit_signal(cid, %{
        "kind" => "recommend",
        "from_bee_id" => bee["id"],
        "quality" => 0.9,
        "payload" => %{"text" => "缓存方案"}
      })

    {:ok, _} =
      Engine.emit_signal(cid, %{
        "kind" => "inhibit",
        "from_bee_id" => bee["id"],
        "target_proposal_id" => "proposal_1"
      })

    assert {:error, "cooldown", _} =
             Engine.emit_signal(cid, %{
               "kind" => "inhibit",
               "from_bee_id" => bee["id"],
               "target_proposal_id" => "proposal_1"
             })
  end

  test "单一对话框：派活 / 进展 / 验收 / 能力自述", %{cid: cid} do
    {:ok, _} =
      Engine.add_bee(cid, %{
        "display" => "auth-bot",
        "kind" => "ai",
        "capabilities" => ["edit", "shell"]
      })

    {:ok, res} = Engine.say(cid, "让 auth-bot 重构登录模块")
    assert res["reply"] =~ "auth-bot"
    {:ok, view} = Engine.view(cid)
    assert Enum.any?(view["tasks"], &(&1["title"] =~ "重构登录模块"))

    {:ok, res2} = Engine.say(cid, "进展如何")
    assert res2["reply"] =~ "进度"

    {:ok, res3} = Engine.say(cid, "你会做什么")
    assert res3["reply"] =~ "帮你做"
    assert is_list(res3["actions"])

    # 未知语句 → 群聊消息，不报错
    {:ok, res4} = Engine.say(cid, "大家好")
    assert res4["reply"] == nil

    {:ok, trace} = {:ok, Store.trace_for_colony(cid)}
    assert Enum.any?(trace, &(&1["text"] == "大家好"))
  end

  test "退出与 Queen 交接", %{cid: cid, colony: colony} do
    {:ok, bob} = Engine.add_bee(cid, %{"display" => "bob", "kind" => "human"})

    # Queen 直接退出 → 要求交接
    assert {:error, "handover_required", _} = Engine.leave(cid, colony["queen_bee_id"])

    # 交接后退出
    assert {:ok, %{"handover_to" => _}} =
             Engine.leave(cid, colony["queen_bee_id"], handover_to: "bob")

    {:ok, updated} = Store.get_colony(cid)
    assert updated["queen_bee_id"] == bob["id"]

    # 普通成员可直接退出
    {:ok, jim} = Engine.add_bee(cid, %{"display" => "jim", "kind" => "human"})
    assert {:ok, %{"left" => _}} = Engine.leave(cid, jim["id"])
  end

  test "解散蜂群隐藏入口并保留工作历史", %{cid: cid} do
    {:ok, _} = Engine.add_bee(cid, %{"display" => "bot", "kind" => "ai"})
    {:ok, _} = Engine.create_task(cid, %{"title" => "t"})

    {:ok, colony} = Store.get_colony(cid)

    assert {:ok, %{"dissolved" => ^cid}} =
             Engine.dissolve(cid, actor_bee_id: colony["queen_bee_id"])

    assert length(Store.tasks_for_colony(cid)) == 1
    assert Newbee.Colony.Control.blocked?(cid, nil)
    refute Enum.any?(Engine.list_colonies(), &(&1["colony"]["id"] == cid))
  end

  test "演示数据可载入且幂等", %{cid: cid} do
    _ = cid
    {:ok, demo} = Engine.seed_demo()
    {:ok, demo2} = Engine.seed_demo()
    assert demo["id"] == demo2["id"]

    {:ok, view} = Engine.view(demo["id"])
    assert length(view["members"]) >= 4
    assert length(view["tasks"]) >= 3
    assert view["honey"]["recent"] != []
    assert Enum.any?(view["signals"], &(&1["kind"] == "recommend"))
    assert Enum.any?(view["trace"], &(&1["type"] == "message"))
  end

  test "bee_trail 返回该 Bee 的任务与轨迹", %{cid: cid} do
    {:ok, bee} =
      Engine.add_bee(cid, %{"display" => "bot", "kind" => "ai", "capabilities" => ["edit"]})

    {:ok, task} =
      Engine.create_task(cid, %{
        "title" => "活",
        "requires" => ["edit"],
        "assignee_display" => "bot"
      })

    {:ok, _} = Engine.claim_task(cid, task["id"], bee["id"])

    {:ok, trail} = Engine.bee_trail(cid, bee["id"])
    assert trail["bee"]["id"] == bee["id"]
    assert Enum.any?(trail["tasks"], &(&1["id"] == task["id"]))
    assert trail["trace"] != []
  end

  test "任务超时仍保留原负责人，防止重复执行", %{cid: cid} do
    {:ok, b1} =
      Engine.add_bee(cid, %{"display" => "b1", "kind" => "ai", "capabilities" => ["edit"]})

    {:ok, b2} =
      Engine.add_bee(cid, %{"display" => "b2", "kind" => "ai", "capabilities" => ["edit"]})

    {:ok, task} = Engine.create_task(cid, %{"title" => "活", "requires" => ["edit"]})
    {:ok, claimed} = Engine.claim_task(cid, task["id"], b1["id"])

    # 心跳更新后仍被 b1 持有
    {:ok, _} = Engine.heartbeat_task(cid, task["id"])

    # 心跳过期不能证明旧执行已结束
    stale = Map.put(claimed, "heartbeat_at", 0) |> Map.put("claimed_at", 0)
    :ok = Store.put_task(stale)
    assert {:error, "conflict", _} = Engine.claim_task(cid, task["id"], b2["id"])
    assert {:ok, %{"assigned_bee_id" => owner}} = Store.get_task(task["id"])
    assert owner == b1["id"]
  end

  describe "群聊 @ 点名（仿微信群）" do
    test "@某人 只投给被点名的人，并留投递回执", %{cid: cid} do
      {:ok, auth} = Engine.add_bee(cid, %{"display" => "auth-bot", "kind" => "ai"})
      {:ok, other} = Engine.add_bee(cid, %{"display" => "test-bot", "kind" => "ai"})

      assert {:ok, _res} = Engine.say(cid, "@auth-bot 看下登录日志")

      trace = Store.trace_for_colony(cid)
      msg = Enum.find(trace, &(&1["type"] == "message"))
      assert msg["text"] == "@auth-bot 看下登录日志"
      assert msg["data"]["mentions"] == ["auth-bot"]

      receipts = Enum.filter(trace, &(&1["type"] == "command" and &1["channel"] == "colony"))
      assert Enum.any?(receipts, &(&1["to_bee_id"] == auth["id"]))
      refute Enum.any?(receipts, &(&1["to_bee_id"] == other["id"]))
    end

    test "@all 投给所有 AI，没被 @ 的收不到", %{cid: cid} do
      {:ok, a} = Engine.add_bee(cid, %{"display" => "a-bot", "kind" => "ai"})
      {:ok, b} = Engine.add_bee(cid, %{"display" => "b-bot", "kind" => "ai"})
      {:ok, human} = Engine.add_bee(cid, %{"display" => "老李", "kind" => "human"})

      assert {:ok, _} = Engine.say(cid, "@all 各位报一下进展")

      trace = Store.trace_for_colony(cid)
      msg = Enum.find(trace, &(&1["type"] == "message"))
      assert msg["data"]["mentions"] == ["all"]

      receipts = Enum.filter(trace, &(&1["type"] == "command" and &1["channel"] == "colony"))
      assert Enum.any?(receipts, &(&1["to_bee_id"] == a["id"]))
      assert Enum.any?(receipts, &(&1["to_bee_id"] == b["id"]))
      # 真人没有会话可投：@all 只投 AI，真人在群聊里看得到即可
      refute Enum.any?(receipts, &(&1["to_bee_id"] == human["id"]))
    end

    test "@ 了不存在的人：留一条「没找到」回执，不静默", %{cid: cid} do
      assert {:ok, _} = Engine.say(cid, "@查无此人 在吗")

      trace = Store.trace_for_colony(cid)

      assert Enum.any?(
               trace,
               &(&1["type"] == "command" and String.contains?(&1["text"], "没找到被 @ 的「查无此人」"))
             )
    end

    test "没有 @ 时，正文照旧走意图路由（@ 只是指名，不改变无 @ 行为）", %{cid: cid} do
      assert {:ok, res} = Engine.say(cid, "你会做什么")
      assert is_binary(res["reply"])
    end

    test "parse_mentions/1 提取 @ 并剥离正文", _ctx do
      assert {["auth-bot"], "看下日志"} = Engine.parse_mentions("@auth-bot 看下日志")
      assert {["all"], "各位好"} = Engine.parse_mentions("@all 各位好")
      assert {["老王", "auth-bot"], "麻烦两位"} = Engine.parse_mentions("@老王 @auth-bot 麻烦两位")
      assert {[], "进展如何"} = Engine.parse_mentions("进展如何")
      assert {["auth-bot"], ""} = Engine.parse_mentions("@auth-bot")
    end
  end

  test "Queen can rename a colony while other actors are rejected", %{colony: colony, cid: cid} do
    assert {:error, "forbidden", _} =
             Engine.rename_colony(cid, "不应改名", actor_bee_id: "not-the-queen")

    assert {:error, "bad_request", _} =
             Engine.rename_colony(cid, "   ", actor_bee_id: colony["queen_bee_id"])

    assert {:ok, renamed} =
             Engine.rename_colony(cid, "重命名蜂群", actor_bee_id: colony["queen_bee_id"])

    assert renamed["name"] == "重命名蜂群"
    assert {:ok, stored} = Store.get_colony(cid)
    assert stored["name"] == "重命名蜂群"
  end

  test "改名从磁盘快照重载后仍然生效（刷新页面不丢）", %{colony: colony, cid: cid} do
    assert {:ok, _} =
             Engine.rename_colony(cid, "持久化蜂群", actor_bee_id: colony["queen_bee_id"])

    # 模拟页面/进程重载：丢弃内存态，从持久化快照重新读取。
    assert :ok = Store.restore()
    assert {:ok, %{"name" => "持久化蜂群"}} = Store.get_colony(cid)
    assert {:ok, %{"colony" => %{"name" => "持久化蜂群"}}} = Engine.view(cid)
  end
end
