defmodule Newbee.Environment.JitTest do
  use ExUnit.Case, async: true

  alias Newbee.Environment.Jit

  test "热度剖析：频率 × token 成本 = 编译收益，按收益排序" do
    events =
      List.duplicate(%{topic: :tool_start, data: %{name: "rename"}, tokens: 2_000}, 10) ++
        List.duplicate(%{topic: :tool_start, data: %{name: "ls"}, tokens: 50}, 3)

    [hot | _] = Jit.profile(events)
    assert hot.pattern == {:tool_use, "rename"}
    assert hot.count == 10
    assert hot.compile_benefit > 0
  end

  test "热模式进 need 队列，不热的不编译（§8.5 避免过度工程）" do
    hot_events = List.duplicate(%{topic: :tool_start, data: %{name: "hot_pattern"}, tokens: 30_000}, 10)
    cold_events = [%{topic: :tool_start, data: %{name: "once"}, tokens: 10}]

    needs = Jit.hot_needs(hot_events ++ cold_events)
    assert Enum.any?(needs, &String.contains?(&1.capability, "hot_pattern"))
    refute Enum.any?(needs, &String.contains?(&1.capability, "once"))
    assert Enum.all?(needs, &(&1.urgency == :high))
  end

  test "高成本 prompt 注入进入 adapter 优化队列" do
    event = %{
      topic: :prompt_injection,
      data: %{
        "payload" => [
          "prompt_injection",
          %{"source" => "sleeping_rule", "rules" => [%{"id" => "jspace-outer"}]}
        ]
      },
      tokens: 150_000
    }

    assert [need] = Jit.hot_needs([event])
    assert need.capability == "optimize prompt injection jspace-outer"
    assert need.evidence.pattern == {:prompt_injection, "jspace-outer"}
  end

  test "晋升路径产物（L1→L2 rule / L2→L3 tool）" do
    l2 = Jit.promote_l1_to_l2("总在提交前忘跑测试", "git commit", "先跑 mix test")
    assert l2.kind == :rule
    assert l2.derived_from == :l1_prompt
    assert l2.spec.injection == "先跑 mix test"

    l3 = Jit.promote_l2_to_l3("rename_callers", "defmodule X do\nend", "defmodule XTest do\nend")
    assert l3.kind == :tool
    assert l3.derived_from == :l2_rule
    assert Map.has_key?(l3.source_files, "rename_callers.ex")
  end

  test "deopt 判定：样本不足不降级" do
    assert :keep = Jit.deopt_decision("tool.nonexistent@abc")
  end
end

defmodule Newbee.Environment.FitnessTest do
  use Newbee.EnvironmentCase, async: false

  alias Newbee.Environment.Fitness

  test "价签：样本不足的桶不展示（§3.3）" do
    rid = "tool.demo@abc123"

    for _ <- 1..2 do
      Fitness.observe(rid, %{success: true, latency_ms: 100, tokens: 200, model: "m1", task_type: "edit"})
    end

    # 2 个样本 < min_samples(3) → 不展示
    assert Fitness.price_tag(rid) == nil

    Fitness.observe(rid, %{success: false, latency_ms: 300, tokens: 500, model: "m1", task_type: "edit"})

    tag = Fitness.price_tag(rid)
    assert tag =~ "✓67%"
    assert tag =~ "n=3"
  end

  test "fitness 分桶聚合（模型 × 任务类型 × 窗口）" do
    rid = "tool.bucket@def456"

    Fitness.observe(rid, %{success: true, latency_ms: 100, tokens: 100, model: "m1", task_type: "edit"})
    Fitness.observe(rid, %{success: false, latency_ms: 200, tokens: 200, model: "m1", task_type: "test"})
    Fitness.observe(rid, %{success: true, latency_ms: 50, tokens: 50, model: "m2", task_type: "edit"})

    buckets = Fitness.fitness(rid)
    assert map_size(buckets) == 3

    overall = Fitness.overall(rid)
    assert overall.samples == 3
    assert_in_delta overall.success_rate, 0.666, 0.01
  end

  test "收敛检查（§15.16）：滑动窗口偏差" do
    rid = "tool.conv@ghi"

    # 前一半全失败，后一半全成功 → 偏差大
    for _ <- 1..3, do: Fitness.observe(rid, %{success: false, latency_ms: 1, tokens: 1})
    for _ <- 1..3, do: Fitness.observe(rid, %{success: true, latency_ms: 1, tokens: 1})

    result = Fitness.convergence(rid, deviation_threshold: 0.1)
    refute result.converged?
    assert result.deviation == 1.0
  end
end

defmodule Newbee.Agent.ProtocolTest do
  use Newbee.EnvironmentCase, async: false

  alias Newbee.Agent.Protocol

  test "message_id 单调不回退（重启后续号）" do
    id1 = Protocol.gen_message_id("worker")
    id2 = Protocol.gen_message_id("worker")

    [_, s1] = String.split(id1, ":")
    [_, s2] = String.split(id2, ":")
    assert String.to_integer(s2) == String.to_integer(s1) + 1
  end

  test "need/feedback/rollback_request 载荷（§7.2）" do
    {:ok, _} = Protocol.need("cap", expected_api: "X.y/2", urgency: :low, evidence: %{e: 1})
    {:ok, _} = Protocol.feedback("tool.x", "tool.x@abc", :ok, score: 5)
    {:ok, _} = Protocol.rollback_request("tool.x", "tool.x@abc", nil, "退化")

    needs = Protocol.messages(kind: :need)
    assert hd(needs)["payload"]["capability"] == "cap"
    assert hd(needs)["payload"]["urgency"] == "low"

    fb = Protocol.messages(kind: :feedback)
    assert hd(fb)["payload"]["release_id"] == "tool.x@abc"
    assert hd(fb)["payload"]["score"] == 5

    rb = Protocol.messages(kind: :rollback_request)
    assert hd(rb)["payload"]["reason"] == "退化"
  end

  test "inbox 去重：同一 message_id 不重复受理" do
    assert :new = Protocol.dedupe("agent:1")
    assert :duplicate = Protocol.dedupe("agent:1")
    assert :new = Protocol.dedupe("agent:2")
  end
end
