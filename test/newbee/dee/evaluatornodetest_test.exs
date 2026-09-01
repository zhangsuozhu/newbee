defmodule Newbee.DEE.EvaluatorNodeTest do
  use Newbee.EvaluatorCase
  alias Newbee.DEE.Evaluator

  @tag :node
  test "独立节点: 求值 + 绑定持久 + env 过滤", %{shared_ev: ev} do
    Evaluator.reset(ev)
    assert %{status: :ok, value: "42"} = Evaluator.eval(ev, "x = 40 + 2")
    assert %{status: :ok, value: "84"} = Evaluator.eval(ev, "x * 2")

    info = Evaluator.info(ev)
    assert info.mode == :node
    assert info.node != nil
    assert info.alive

    # env 过滤: 节点内不应看到注入的假凭证
    System.put_env("OPENROUTER_API_KEY", "sk-should-not-leak")
    r = Evaluator.eval(ev, ~s|System.get_env("OPENROUTER_API_KEY")|)
    assert r.value == "nil"
  end

  @tag :node
  test "peer 使用受控语义名称并隐藏于 global 拓扑" do
    {:ok, ev} = Evaluator.start(mode: :node, node_label: "Research Agent / α 01")
    on_exit(fn -> if Process.alive?(ev), do: GenServer.stop(ev) end)

    info = Evaluator.info(ev)
    primary_name = info.node |> Atom.to_string() |> String.split("@") |> hd()

    assert primary_name =~ ~r/^newbee_eval_primary_research_agent_01_[a-z2-7]+$/
    assert info.node in Node.list(:hidden)
    refute info.node in Node.list(:visible)

    # Hidden peer 仍通过跨进程文件锁串行化 Edit 快照写入。
    assert %{status: :ok} = Evaluator.eval(ev, ~S|Newbee.Tools.Edit.show("mix.exs", {1, 1})|)

    standby =
      Enum.reduce_while(1..100, nil, fn _, _ ->
        case Evaluator.info(ev).standby do
          %{alive: true} = ready ->
            {:halt, ready}

          _ ->
            Process.sleep(50)
            {:cont, nil}
        end
      end)

    assert standby
    standby_name = standby.node |> Atom.to_string() |> String.split("@") |> hd()
    assert standby_name =~ ~r/^newbee_eval_standby_research_agent_01_[a-z2-7]+$/
    assert standby.node in Node.list(:hidden)
  end

  @tag :node
  test "节点崩溃后自动重启，重试当前调用，绑定丢失但可用" do
    {:ok, ev} = Evaluator.start(mode: :node)
    Evaluator.eval(ev, "y = 1")
    info1 = Evaluator.info(ev)

    # 杀死节点（模拟崩溃）
    :peer.stop(info1_node(ev, info1))
    Process.sleep(200)

    r = Evaluator.eval(ev, "2 + 2")
    assert r.status == :ok
    assert r[:node_restarted] == true

    info2 = Evaluator.info(ev)
    assert info2.restarts >= 1

    # 旧绑定没了，但新节点可用
    assert Evaluator.bindings_summary(ev) == []
    assert %{status: :ok} = Evaluator.eval(ev, "z = 3")

    GenServer.stop(ev)
  end

  @tag :node
  test "独立节点失败求值在调用超时内返回" do
    {:ok, ev} = Evaluator.start(mode: :node)
    started = System.monotonic_time(:millisecond)

    result = Evaluator.eval(ev, "Process.sleep(:infinity)", timeout: 100)
    elapsed = System.monotonic_time(:millisecond) - started

    assert result.status == :error
    assert result.error =~ "timeout"
    assert elapsed < 3_000
    GenServer.stop(ev)
  end

  @tag :node
  test "双节点冗余: primary 死后立即切 standby，standby 自动补位" do
    {:ok, ev} = Evaluator.start(mode: :node)

    # 等待 standby 补位
    wait_standby = fn ->
      Enum.reduce_while(1..50, false, fn _, _ ->
        case Evaluator.info(ev).standby do
          %{alive: true} ->
            {:halt, true}

          _ ->
            Process.sleep(100)
            {:cont, false}
        end
      end)
    end

    assert wait_standby.(), "standby 应在 5s 内就绪"
    info1 = Evaluator.info(ev)
    assert info1.standby.node != info1.node

    # 杀死 primary → eval 应立即切 standby 成功（零等待重建）
    :peer.stop(info1.peer)
    Process.sleep(200)

    r = Evaluator.eval(ev, "1 + 1")
    assert r.status == :ok
    assert r[:node_restarted] == true

    # 新 primary = 旧 standby，且新 standby 在补位
    info2 = Evaluator.info(ev)
    assert info2.node == info1.standby.node
    assert info2.standby == nil or info2.standby.node != info2.node

    GenServer.stop(ev)
  end

  defp info1_node(_ev, info), do: info.peer
end

:ok
