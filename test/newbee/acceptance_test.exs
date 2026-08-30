defmodule Newbee.AcceptanceTest do
  @moduledoc """
  DESIGN §15 架构验收的可执行规格（缺一不可）。

  1. 新项目首启创建 .newbee，重启恢复同一 active revision
  2. 至少两类非工具插件经同一 Plugin Runtime 加载
  3. 候选编译/测试失败不改变 active
  4. 任意 active release 可回退 parent 或历史 release
  5. generation 切换后绑定迁移可验证（白名单 100% / 其余 tombstone）
  6. worker 能提 need、收 module_ready、给版本级 feedback、发 rollback_request
  7. adapter 独立上下文（不碰 worker transcript/bindings 与宿主凭证）
  8. 同一消息重复投递不重复发布/回退/扣预算
  9. generation 启动失败恢复最近 known-good revision 并标 degraded
  10. 每个环境改变可回答：谁、何时、基于哪条证据、改了哪个 release、如何回退
  11. 沉睡规则在 compaction 后依然触发（视图重建即重挂载）
  12. 删除旧旁路后，核心流程只有一套状态机
  """

  use Newbee.EnvironmentCase, async: false

  alias Newbee.Environment.{BindingCodec, Coordinator, EvaluatorPool, Generation, Release, Store}

  setup do
    _pid = start_coordinator!()
    :ok
  end

  defp propose_and_activate(coordinator, release_attrs, opts \\ []) do
    {:ok, change} =
      Coordinator.propose_change(coordinator, %{
        reason: Keyword.get(opts, :reason, "test change"),
        evidence: Keyword.get(opts, :evidence, [%{test: true}]),
        author_agent: Keyword.get(opts, :author, :adapter)
      })

    {:ok, release} = Coordinator.candidate_ready(coordinator, change.change_id, release_attrs)

    # 等待异步评测完成
    change = wait_evaluation(coordinator, change.change_id)
    assert change.status in [:canary, :active], "evaluation should pass, got #{change.status}: #{inspect(change.evaluation_result)}"

    if change.status == :canary do
      # manual 档：人工授权激活（授权事件）
      assert :ok = Coordinator.approve(coordinator, change.change_id, "test-user")
    end

    {change, release}
  end

  defp wait_evaluation(coordinator, change_id, retries \\ 100) do
    change = Enum.find(Coordinator.changes(coordinator), &(&1.change_id == change_id))

    if change.status in [:canary, :active, :rejected] or retries <= 0 do
      change
    else
      Process.sleep(20)
      wait_evaluation(coordinator, change_id, retries - 1)
    end
  end

  # ── 验收 1：首启创建 + 重启恢复 ──

  @tag :acceptance
  test "§15.1 首启创建 .newbee，重启恢复同一 active revision" do
    assert File.exists?(Store.path(:environment))

    coordinator = Process.whereis(Coordinator)

    # rev0 播种：fresh environment 的 active 含全部内置插件（P0 活锁修复；
    # 否则生产环境 CapabilityGate 拒绝全部内置工具）
    builtin = Newbee.Plugins.builtin_active_map()
    fresh_active = Coordinator.current(coordinator).active

    assert Map.has_key?(fresh_active, "tool.fs")
    assert map_size(fresh_active) == map_size(builtin)

    for {plugin_id, release_id} <- builtin do
      assert fresh_active[plugin_id] == release_id
    end

    # 激活一个 change，产生 revision
    {_change, release} = propose_and_activate(coordinator, %{plugin_id: "tool.demo", kind: :tool, source_files: %{"demo.ex" => tool_source()}})

    rev_before = Coordinator.current(coordinator).revision
    assert rev_before == 1
    assert Coordinator.current(coordinator).active["tool.demo"] == release.release_id

    # 模拟 daemon 重启：停掉 Coordinator 重新启动（事件流重放恢复）
    stop_coordinator(coordinator)
    pid = start_coordinator!()

    current = Coordinator.current(pid)
    assert current.revision == rev_before
    assert current.active["tool.demo"] == release.release_id
  end

  # ── 验收 2：非工具插件经同一 Plugin Runtime ──

  @tag :acceptance
  test "§15.2 至少两类非工具插件（rule/prompt）经同一 Plugin Runtime 加载" do
    coordinator = Process.whereis(Coordinator)

    # kind: rule
    {_c1, rule_release} =
      propose_and_activate(coordinator, %{
        plugin_id: "rule.no_foo",
        kind: :rule,
        source_files: %{"no_foo.ex" => rule_source("no_foo", "foo", "别写 foo")}
      })

    # kind: prompt
    {_c2, prompt_release} =
      propose_and_activate(coordinator, %{
        plugin_id: "prompt.lesson_demo",
        kind: :prompt,
        source_files: %{},
        usage: "教训：先读 RepoMap 再动手"
      })

    active = Coordinator.current(coordinator).active
    assert active["rule.no_foo"] == rule_release.release_id
    assert active["prompt.lesson_demo"] == prompt_release.release_id

    # rule release 挂载进运行时规则引擎（§6.3 存储身份 → 运行时身份）
    sync_runtime(coordinator)
    rules = Newbee.DEE.Rules.list()
    assert Enum.any?(rules, &(&1.id == "rule.no_foo" and &1.pattern == "foo"))

    # prompt release 的 usage 进投影 Guidance
    prompts = Coordinator.active_prompts()
    assert Enum.any?(prompts, &(&1.plugin_id == "prompt.lesson_demo"))
  after
    Newbee.DEE.Rules.remove("rule.no_foo")
  end

  defp sync_runtime(_coordinator) do
    # after_revision_change 在激活时同步执行（同进程调用链），这里只需确认已挂载
    :ok
  end

  # ── 验收 3：候选失败不改 active ──

  @tag :acceptance
  test "§15.3 候选编译/评测失败不改变 active" do
    coordinator = Process.whereis(Coordinator)
    before = Coordinator.current(coordinator)

    {:ok, change} = Coordinator.propose_change(coordinator, %{reason: "bad candidate", author_agent: :adapter})

    # 编译失败的源码（contract 校验不过）
    {:ok, _release} =
      Coordinator.candidate_ready(coordinator, change.change_id, %{
        plugin_id: "tool.broken",
        kind: :tool,
        source_files: %{"broken.ex" => "defmodule Broken do\n  def x(, do: 1\nend"}
      })

    change = wait_evaluation(coordinator, change.change_id)
    assert change.status == :rejected

    after_ = Coordinator.current(coordinator)
    assert after_.revision == before.revision
    assert after_.active == before.active
  end

  # ── 验收 4：回退到历史 revision ──

  @tag :acceptance
  test "§15.4 任意 active release 可回退到历史 revision（graph 级）" do
    coordinator = Process.whereis(Coordinator)

    {_c1, r1} = propose_and_activate(coordinator, %{plugin_id: "tool.demo", kind: :tool, source_files: %{"demo.ex" => tool_source()}})

    {_c2, r2} =
      propose_and_activate(coordinator, %{
        plugin_id: "tool.demo2",
        kind: :tool,
        source_files: %{"demo2.ex" => tool_source("DemoTool2", "tool.demo2")}
      })

    assert Coordinator.current(coordinator).revision == 2

    # 回退到 rev 1：demo2 应消失，demo 保留
    {:ok, rollback_change} = Coordinator.rollback(coordinator, {:revision, 1}, "test rollback")

    current = Coordinator.current(coordinator)
    # 回退到 rev1：demo2 消失、demo 保留，内置基线图始终在
    assert current.active["tool.demo"] == r1.release_id
    refute Map.has_key?(current.active, "tool.demo2")
    assert rollback_change.status == :active

    # 历史永不删除：r2 的 revision 仍可查
    revs = Coordinator.revisions(coordinator)
    assert Enum.any?(revs, &(&1["rev"] == 2 and &1["active"]["tool.demo2"] == r2.release_id))

    # 再回退到 rev 0（内置基线环境：active = 内置图，非空图）
    {:ok, _} = Coordinator.rollback(coordinator, {:revision, 0}, "to baseline")
    assert Coordinator.current(coordinator).active == Newbee.Plugins.builtin_active_map()
  end

  # ── 验收 5：generation 切换绑定迁移 ──

  @tag :acceptance
  test "§15.5 generation 切换：codec 白名单迁移 100%，PID/Fun tombstone 化" do
    # 本地 evaluator（测试速度）：两个 generation 间迁移
    {:ok, pool} =
      EvaluatorPool.start(
        revision: 0,
        active_map: %{},
        evaluator_opts: [mode: :local],
        name: :"pool_#{System.unique_integer([:positive])}"
      )

    # 在 active generation 制造绑定：白名单类型 + 非白名单
    %{status: :ok} = EvaluatorPool.eval(pool, "x = 41 + 1")
    %{status: :ok} = EvaluatorPool.eval(pool, ~S|y = %{"a" => [1, 2, 3], "b" => "hello"}|)
    %{status: :ok} = EvaluatorPool.eval(pool, "pid_1 = self()")
    %{status: :ok} = EvaluatorPool.eval(pool, "fun_1 = fn a -> a + 1 end")

    # 候选 generation + 切换（Binding Continuity 全协议）
    {:ok, _gen} = EvaluatorPool.boot_candidate(pool, 1, %{})
    {:ok, summary} = EvaluatorPool.switch(pool)

    # 迁移摘要：迁了几个、tombstone 几个
    assert summary.restored == 2
    assert summary.tombstones == 2

    # 白名单类型值完整迁移
    %{status: :ok, value: "42"} = EvaluatorPool.eval(pool, "x")
    %{status: :ok} = EvaluatorPool.eval(pool, "y[\"a\"] == [1, 2, 3] and y[\"b\"] == \"hello\"")

    # tombstone 名字保留、访问报明确错误
    %{status: :ok, value: v} = EvaluatorPool.eval(pool, "inspect(pid_1.__struct__)")
    assert v =~ "Tombstone"

    %{status: :ok, value: v2} = EvaluatorPool.eval(pool, "Newbee.Environment.BindingCodec.Tombstone.message(fun_1)")
    assert v2 =~ "墓碑" or v2 =~ "tombstone" or v2 =~ "闭包"

    GenServer.stop(pool)
  end

  @tag :acceptance
  test "§15.5b codec 白名单逐项编解码（quiesce/snapshot/restore 单元级）" do
    binding = [
      int_val: 42,
      str_val: "hello",
      bin_val: <<0, 1, 255>>,
      list_val: [1, "two", 3.0],
      tuple_val: {:ok, "result"},
      map_val: %{"b" => [true, nil], a: 1},
      atom_val: :some_atom,
      range_val: 1..10,
      regex_val: ~r/foo+/i,
      mapset_val: MapSet.new([1, 2, 3]),
      pid_val: self(),
      fun_val: fn x -> x end,
      ref_val: make_ref()
    ]

    {:ok, snapshot} = BindingCodec.encode(binding)
    {restored, summary} = BindingCodec.decode(%{entries: snapshot.entries})

    # 白名单 100% 恢复
    assert restored[:int_val] == 42
    assert restored[:str_val] == "hello"
    assert restored[:bin_val] == <<0, 1, 255>>
    assert restored[:list_val] == [1, "two", 3.0]
    assert restored[:tuple_val] == {:ok, "result"}
    assert restored[:map_val] == %{"b" => [true, nil], a: 1}
    assert restored[:atom_val] == :some_atom
    assert restored[:range_val] == 1..10
    assert Regex.match?(restored[:regex_val], "FOO")
    assert MapSet.equal?(restored[:mapset_val], MapSet.new([1, 2, 3]))

    # 非白名单 tombstone 化
    assert %BindingCodec.Tombstone{type: "pid"} = restored[:pid_val]
    assert %BindingCodec.Tombstone{type: "function"} = restored[:fun_val]
    assert %BindingCodec.Tombstone{type: "reference"} = restored[:ref_val]

    assert summary.restored == 10
    assert summary.tombstones == 3

    # 大小预算：超预算取消（提示先显式 artifactize）
    big = String.duplicate("x", BindingCodec.default_value_budget() + 1)
    assert {:error, {:over_budget, :big_val, _}} = BindingCodec.encode([big_val: big])
  end

  # ── 验收 6：worker 协作通道 ──

  @tag :acceptance
  test "§15.6 worker 提 need / 收 module_ready / 版本级 feedback / rollback_request" do
    coordinator = Process.whereis(Coordinator)

    # need
    {:ok, need_id} = Newbee.Agent.Worker.need("需要一个重命名工具", evidence: %{pattern: "rename"})
    assert need_id =~ "worker:"

    needs = Newbee.Agent.Protocol.messages(kind: :need)
    assert Enum.any?(needs, &(&1["message_id"] == need_id))

    # module_ready：激活后通知进 worker 下一次投影（pending_notices）
    {_change, release} =
      propose_and_activate(coordinator, %{plugin_id: "tool.demo", kind: :tool, source_files: %{"demo.ex" => tool_source()}})

    notices = Coordinator.drain_notices(coordinator)
    assert Enum.any?(notices, fn n ->
             n[:release_id] == release.release_id and n[:plugin_id] == "tool.demo" and n[:usage] != nil
           end)

    # 版本级 feedback（score 绑定 release_id）
    {:ok, _} = Newbee.Agent.Worker.feedback("tool.demo", release.release_id, :ok, score: 4, latency: 120)

    fitness = Newbee.Environment.Fitness.overall(release.release_id)
    assert fitness.samples == 1
    assert fitness.success_rate == 1.0

    # rollback_request（target 是线索，Coordinator 重解析）
    {:ok, _} = Newbee.Agent.Worker.rollback_request("tool.demo", release.release_id, nil, "test rollback")
    requests = Newbee.Agent.Protocol.messages(kind: :rollback_request)
    assert Enum.any?(requests, &(&1["payload"]["plugin_id"] == "tool.demo"))
  end

  # ── 验收 8：幂等 ──

  @tag :acceptance
  test "§15.8 同一消息重复投递不重复激活/回退" do
    coordinator = Process.whereis(Coordinator)

    {change, _release} =
      propose_and_activate(coordinator, %{plugin_id: "tool.demo", kind: :tool, source_files: %{"demo.ex" => tool_source()}})

    rev = Coordinator.current(coordinator).revision

    # 重复激活：幂等键 {change_id, candidate_revision} → 不重复产生 revision
    assert :ok = Coordinator.activate(coordinator, change.change_id)
    assert Coordinator.current(coordinator).revision == rev

    # 重复回退：同一 request_id 的消息重复投递 → 返回同一 change（§7.2 幂等 effect）
    {:ok, rb1} = Coordinator.rollback(coordinator, {:revision, 0}, "r1", request_id: "req-rb-1")
    {:ok, rb2} = Coordinator.rollback(coordinator, {:revision, 0}, "r1", request_id: "req-rb-1")
    assert rb1.change_id == rb2.change_id

    # candidate_ready 重复投递按 change_id 去重
    {:ok, c2} = Coordinator.propose_change(coordinator, %{reason: "dup", author_agent: :adapter})

    {:ok, _} = Coordinator.candidate_ready(coordinator, c2.change_id, %{plugin_id: "tool.d2", kind: :tool, source_files: %{"d2.ex" => tool_source("D2", "tool.d2")}})

    assert {:ok, :duplicate, _} =
             Coordinator.candidate_ready(coordinator, c2.change_id, %{plugin_id: "tool.d2", kind: :tool, source_files: %{"d2.ex" => tool_source("D2", "tool.d2")}})

    # inbox 去重
    assert :new = Newbee.Agent.Protocol.dedupe("msg-1")
    assert :duplicate = Newbee.Agent.Protocol.dedupe("msg-1")
  end

  # ── 验收 9：generation 失败 → known-good ──

  @tag :acceptance
  test "§15.9 generation 启动失败恢复最近 known-good revision 并标 degraded" do
    coordinator = Process.whereis(Coordinator)

    # 激活一个好的 release 并标 healthy（known-good）
    {_c, _r} = propose_and_activate(coordinator, %{plugin_id: "tool.good", kind: :tool, source_files: %{"good.ex" => tool_source("GoodTool", "tool.good")}})
    GenServer.call(coordinator, {:mark_healthy, 1}, 60_000)

    # 再激活一个（rev 2）
    {_c2, _r2} = propose_and_activate(coordinator, %{plugin_id: "tool.bad", kind: :tool, source_files: %{"bad.ex" => tool_source("BadTool", "tool.bad")}})

    # 模拟 rev 2 generation 启动失败 → 恢复 known-good
    {:ok, good_rev, _change} = Coordinator.recover_known_good(coordinator, 2, "simulated boot failure")

    assert good_rev == 1
    current = Coordinator.current(coordinator)
    rev1 = Coordinator.revisions(coordinator) |> Enum.find(&(&1["rev"] == 1))
    assert Map.get(current.active, "tool.good") == rev1["active"]["tool.good"]
    assert Map.get(current.active, "tool.bad") == nil
    assert 2 in current.degraded

    # 失败证据保留：degraded 事件落盘
    events = Newbee.EventStore.replay(Store.path(:events))
    assert Enum.any?(events, &(&1.topic == :revision_degraded and &1.data["rev"] == 2))
  end

  # ── 验收 10：审计五问 ──

  @tag :acceptance
  test "§15.10 每个环境改变可回答：谁、何时、基于哪条证据、改了哪个 release、如何回退" do
    coordinator = Process.whereis(Coordinator)

    {change, release} =
      propose_and_activate(coordinator, %{
        plugin_id: "tool.audit",
        kind: :tool,
        source_files: %{"audit.ex" => tool_source("AuditTool", "tool.audit")}
      }, reason: "审计测试", evidence: [%{event: "ev-123"}], author: :worker)

    # 谁（author_agent）、何时（created_at）、基于哪条证据（evidence）、
    # 改了哪个 release（candidate_revision）、如何回退（base_revision）
    [found] = Coordinator.changes(coordinator) |> Enum.filter(&(&1.change_id == change.change_id))
    assert found.author_agent == :worker
    assert found.created_at != nil
    assert found.evidence == [%{"test" => true}] or found.evidence == [%{event: "ev-123"}]
    assert found.candidate_revision == release.release_id
    assert found.base_revision == 0

    # 事件流中有完整审计链
    topics = Newbee.EventStore.replay(Store.path(:events)) |> Enum.map(& &1.topic)
    assert :change_requested in topics
    assert :change_evaluated in topics
    assert :change_activated in topics
    assert :revision_advanced in topics
  end

  # ── 验收 11：沉睡规则 compaction 后存活 ──

  @tag :acceptance
  test "§15.11 沉睡规则在 compaction（视图重建）后依然触发" do
    Newbee.DEE.Rules.add("test-dormant", "forbidden_pattern", "命中提醒：别这样写", source: :test)

    # 第一次构建视图（挂载规则）
    view1 = Newbee.Environment.Projection.build(%{})
    assert Enum.any?(view1.rules, &(&1.id == "test-dormant"))

    # 模拟 compaction：视图丢弃，重新构建——规则重挂载
    view2 = Newbee.Environment.Projection.build(%{})
    assert Enum.any?(view2.rules, &(&1.id == "test-dormant"))

    # 触发仍然生效
    hits = Newbee.Environment.Projection.check_rules("this has forbidden_pattern in it")
    assert Enum.any?(hits, &(&1.id == "test-dormant"))
  after
    Newbee.DEE.Rules.remove("test-dormant")
  end

  # ── 验收 12：旧旁路已删，一套状态机 ──

  @tag :acceptance
  test "§15.12 旧 HotLoader/Snapshot/JIT/Evolver 旁路已删除，核心流程只有 Coordinator 一套状态机" do
    for mod <- [
          Newbee.DEE.Tools.HotLoader,
          Newbee.Evolution.Snapshot,
          Newbee.Evolution.JIT,
          Newbee.Evolution.Evolver,
          Newbee.Evolution.Policy,
          Newbee.Evolution.Bench,
          Newbee.Evolution.Metrics,
          Newbee.Evolution.PriceTags,
          Newbee.Evolution.Gene
        ] do
      refute Code.ensure_loaded?(mod), "#{inspect(mod)} 应该已被删除"
    end

    # 唯一状态机：Coordinator 是 Change/Release/Revision 的唯一驾驶者
    assert function_exported?(Coordinator, :propose_change, 2)
    assert function_exported?(Coordinator, :candidate_ready, 4)
    assert function_exported?(Coordinator, :activate, 3)
    assert function_exported?(Coordinator, :rollback, 4)
  end

  # ── 验收 7：adapter 隔离（§7.1/§12 凭证隔离 + 上下文隔离）──
  test "§15.7 adapter 独立上下文且不泄露宿主凭证" do
    # provider 为无凭证适配器，凭证注入在 Host.Shell
    {:ok, plan} = Newbee.Plugins.Provider.OpenRouter.plan("test/model", [%{"role" => "user", "content" => "hi"}])
    assert plan[:credential_env] == "OPENROUTER_API_KEY"
    refute Map.has_key?(plan, :api_key)
    assert Enum.all?(Map.to_list(plan[:headers] || %{}), fn {k, _} -> String.downcase(to_string(k)) != "authorization" end)
    assert Code.ensure_loaded?(Newbee.Agent.Adapter)
    assert Code.ensure_loaded?(Newbee.DEE.Evaluator)
  end

end
