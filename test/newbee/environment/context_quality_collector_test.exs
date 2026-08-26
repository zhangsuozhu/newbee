defmodule Newbee.Environment.ContextQuality.CollectorTest do
  use ExUnit.Case, async: false

  alias Newbee.Environment.ContextQuality
  alias Newbee.Environment.ContextQuality.Collector

  # 直接测 handle_event 纯函数（不依赖 Bus/GenServer 进程）
  defp fresh, do: %Collector{}

  defp inject(s, sid, rid),
    do: Collector.handle_event(:prompt_injection, %{session_id: sid, source: rid}, s)

  defp goal_done(s, sid), do: Collector.handle_event(:goal_done, %{session_id: sid}, s)
  defp turn_end(s, sid), do: Collector.handle_event(:turn_end, %{session_id: sid}, s)
  defp err(s, sid), do: Collector.handle_event(:tool_error, %{session_id: sid}, s)

  describe "差分归因闭环" do
    test "注入的 release 记 with_ctx，未注入的活跃记 without_ctx" do
      s = fresh()
      # 注册两个活跃 release
      {:noreply, s} = Collector.handle_cast({:register, "rule_a"}, s)
      {:noreply, s} = Collector.handle_cast({:register, "rule_b"}, s)

      # turn1: 注入 rule_a，成功（goal_done 无 error）
      s = inject(s, "s1", "rule_a") |> goal_done("s1")

      la = s.ledgers["rule_a"]
      lb = s.ledgers["rule_b"]
      assert la.n_with == 1 and la.n_without == 0
      assert la.with_ctx == {2.0, 1.0}  # 1 成功
      # rule_b 未注入 → 记 without_ctx
      assert lb.n_without == 1 and lb.n_with == 0
    end

    test "goal_done 带 tool_error → failure" do
      s = fresh()
      {:noreply, s} = Collector.handle_cast({:register, "rule_a"}, s)
      s = inject(s, "s1", "rule_a") |> err("s1") |> goal_done("s1")
      la = s.ledgers["rule_a"]
      assert la.with_ctx == {1.0, 2.0}  # 1 失败（β+1）
    end

    test "turn_end 干净但无 goal → 不记账（成败未定，诚实计量）" do
      s = fresh()
      {:noreply, s} = Collector.handle_cast({:register, "rule_a"}, s)
      s = inject(s, "s1", "rule_a") |> turn_end("s1")
      # 无明确成败信号 → 不产生样本
      assert map_size(s.ledgers) == 0
    end

    test "turn_end 有 error 无 goal → failure" do
      s = fresh()
      {:noreply, s} = Collector.handle_cast({:register, "rule_a"}, s)
      s = inject(s, "s1", "rule_a") |> err("s1") |> turn_end("s1")
      assert s.ledgers["rule_a"].with_ctx == {1.0, 2.0}
    end

    test "多次 turn 累积后统计方向正确" do
      s = fresh()
      {:noreply, s} = Collector.handle_cast({:register, "good_rule"}, s)
      {:noreply, s} = Collector.handle_cast({:register, "bad_rule"}, s)

      # good_rule 参与的 turn 总成功；bad_rule 参与的 turn 总失败
      s =
        Enum.reduce(1..12, s, fn i, acc ->
          sid = "t#{i}"
          acc
          |> inject(sid, "good_rule")
          |> goal_done(sid)
        end)

      s =
        Enum.reduce(1..12, s, fn i, acc ->
          sid = "b#{i}"
          acc
          |> inject(sid, "bad_rule")
          |> err(sid)
          |> turn_end(sid)
        end)

      good = s.ledgers["good_rule"]
      bad = s.ledgers["bad_rule"]

      # good_rule: 注入时全成功(with)，未注入时是 bad 的失败 turn(without)
      assert ContextQuality.verdict(good) in [:ok, :insufficient]
      refute ContextQuality.verdict(good) == :harmful

      # bad_rule: 注入时全失败 → with_ctx 成功率低
      assert Newbee.Environment.PatternStats.beta_mean(bad.with_ctx) < 0.3
    end
  end

  describe "健壮性" do
    test "无 session_id 的事件不崩" do
      s = fresh()
      assert Collector.handle_event(:prompt_injection, %{source: "r"}, s) == s
      assert Collector.handle_event(:tool_error, %{}, s) == s
      assert Collector.handle_event(:unknown_topic, %{}, s) == s
    end

    test "turn 边界外孤立 goal_done 不崩" do
      s = fresh()
      assert Collector.handle_event(:goal_done, %{session_id: "ghost"}, s) == s
    end
  end

  describe "GenServer 集成" do
    test "start_link + ledger/price_tags/retire_candidates" do
      {:ok, pid} = Collector.start_link(subscribe: false, name: nil)
      GenServer.cast(pid, {:register, "rule_x"})
      # 通过 call 拿空账本
      l = Collector.ledger("rule_x", pid)
      assert l.n_with == 0
      assert is_map(Collector.price_tags(pid))
      assert is_list(Collector.retire_candidates(pid))
      GenServer.stop(pid)
    end
  end
end
