defmodule Newbee.Environment.ContextQuality.CollectorTest do
  use ExUnit.Case, async: false

  alias Newbee.Environment.ContextQuality.Collector

  defp fresh, do: %Collector{}

  # 真实载荷形状辅助
  defp inject_evt(rid), do: %{rules: [%{id: rid, pattern: "p", injection: "i"}], source: "sleeping_rule"}
  defp turn_end_evt(type), do: %{payload: ["turn_end", type, 123]}

  describe "真实载荷解析" do
    test "prompt_injection 从 rules[].id 提取规则" do
      s = Collector.handle_event(:prompt_injection, inject_evt("rule_a"), fresh())
      assert MapSet.member?(s.current_turn.injected, "rule_a")
      assert MapSet.member?(s.active, "rule_a")
    end

    test "多个规则一次注入" do
      ev = %{rules: [%{id: "r1"}, %{id: "r2"}], source: "sleeping_rule"}
      s = Collector.handle_event(:prompt_injection, ev, fresh())
      assert MapSet.size(s.current_turn.injected) == 2
    end

    test "turn_end 从 payload[1] 解析 outcome" do
      s = fresh()
      s = Collector.handle_event(:prompt_injection, inject_evt("rule_a"), s)
      s = Collector.handle_event(:turn_end, turn_end_evt("done"), s)
      assert s.ledgers["rule_a"].with_ctx == {2.0, 1.0}
    end
  end

  describe "差分归因（单活跃 turn）" do
    test "注入记 with_ctx，未注入活跃记 without_ctx" do
      s = %Collector{} |> Map.put(:active, MapSet.new(["rule_a", "rule_b"]))
      s = Collector.handle_event(:prompt_injection, inject_evt("rule_a"), s)
      s = Collector.handle_event(:turn_end, turn_end_evt("done"), s)

      assert s.ledgers["rule_a"].n_with == 1
      assert s.ledgers["rule_b"].n_without == 1
    end

    test "turn_end done 但有 tool_error → failure" do
      s = fresh()
      s = Collector.handle_event(:prompt_injection, inject_evt("rule_a"), s)
      s = Collector.handle_event(:tool_error, %{payload: ["tool_error", "boom"]}, s)
      s = Collector.handle_event(:turn_end, turn_end_evt("done"), s)
      assert s.ledgers["rule_a"].with_ctx == {1.0, 2.0}
    end

    test "turn_end error → failure" do
      s = fresh()
      s = Collector.handle_event(:prompt_injection, inject_evt("rule_a"), s)
      s = Collector.handle_event(:turn_end, turn_end_evt("error"), s)
      assert s.ledgers["rule_a"].with_ctx == {1.0, 2.0}
    end

    test "turn_end text/ask（成败未定）→ 不记账（诚实缺测）" do
      s = fresh()
      s = Collector.handle_event(:prompt_injection, inject_evt("rule_a"), s)
      s = Collector.handle_event(:turn_end, turn_end_evt("text"), s)
      assert map_size(s.ledgers) == 0
    end

    test "goal_done → success" do
      s = fresh()
      s = Collector.handle_event(:prompt_injection, inject_evt("rule_a"), s)
      s = Collector.handle_event(:goal_done, %{payload: %{session_id: "x"}}, s)
      assert s.ledgers["rule_a"].with_ctx == {2.0, 1.0}
    end

    test "usage token 累积进 turn" do
      s = fresh()
      s = Collector.handle_event(:prompt_injection, inject_evt("rule_a"), s)
      s = Collector.handle_event(:usage, %{payload: ["usage", %{total_tokens: 500}]}, s)
      s = Collector.handle_event(:turn_end, turn_end_evt("done"), s)
      assert s.ledgers["rule_a"].with_tokens == 500.0
    end

    test "无注入的 turn 不记账" do
      s = fresh()
      s = Collector.handle_event(:turn_end, turn_end_evt("done"), s)
      assert map_size(s.ledgers) == 0
    end
  end

  describe "健壮性（隔离性）" do
    test "畸形事件不崩" do
      s = fresh()
      s = Collector.handle_event(:prompt_injection, %{}, s)
      s = Collector.handle_event(:tool_error, nil, s)
      s = Collector.handle_event(:usage, %{payload: ["usage", %{total_tokens: "bad"}]}, s)
      s = Collector.handle_event(:turn_end, %{payload: ["turn_end", "done"]}, s)
      assert is_struct(s, Collector)
    end
  end

  describe "GenServer 集成" do
    test "start_link + API" do
      {:ok, pid} = Collector.start_link(subscribe: false, name: nil)
      GenServer.cast(pid, {:register, "rule_x"})
      assert Collector.ledger("rule_x", pid).n_with == 0
      assert is_map(Collector.price_tags(pid))
      assert is_list(Collector.retire_candidates(pid))
      GenServer.stop(pid)
    end
  end
end
