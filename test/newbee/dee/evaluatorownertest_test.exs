defmodule Newbee.DEE.EvaluatorOwnerTest do
  @moduledoc """
  会话资源随会话释放（epmd 残留 newbee_eval_* 事故回归）：

  - kernel 停止（GenServer.stop）→ 会话私有求值器自停（monitor_owner）
  - 宿主进程（web 会话）死亡/崩溃 → kernel 自停 → 求值器自停
  - :node 模式：求值器停 → primary/standby peer 节点全部从分布式集群消失
  """
  use ExUnit.Case, async: false
  alias Newbee.Agent.Loop
  alias Newbee.DEE.Evaluator

  defp wait_dead(pid, tries \\ 100)
  defp wait_dead(_pid, 0), do: false

  defp wait_dead(pid, tries) do
    if Process.alive?(pid) do
      Process.sleep(50)
      wait_dead(pid, tries - 1)
    else
      true
    end
  end

  test "evaluator_owned: kernel 停止 → 私有求值器随停" do
    {:ok, ev} = Evaluator.start(mode: :local)

    {:ok, kernel} =
      Loop.start_link(
        client: %{},
        evaluator: ev,
        evaluator_owned: true,
        session: false,
        client_fun: fn _m, _t, _r -> {:ok, %{"role" => "assistant", "content" => "ok"}, %{}} end
      )

    GenServer.stop(kernel)
    assert wait_dead(ev), "kernel 停止后求值器应随停"
  end

  test "未标 evaluator_owned 的求值器不随 kernel 释放（共享兜底语义）" do
    {:ok, ev} = Evaluator.start(mode: :local)

    {:ok, kernel} =
      Loop.start_link(
        client: %{},
        evaluator: ev,
        session: false,
        client_fun: fn _m, _t, _r -> {:ok, %{"role" => "assistant", "content" => "ok"}, %{}} end
      )

    GenServer.stop(kernel)
    Process.sleep(100)
    assert Process.alive?(ev)
    GenServer.stop(ev)
  end

  test "owner 死亡（崩溃）→ kernel 自停 → 求值器链式随停" do
    {:ok, ev} = Evaluator.start(mode: :local)
    test_pid = self()

    owner =
      spawn(fn ->
        {:ok, kernel} =
          Loop.start_link(
            client: %{},
            evaluator: ev,
            evaluator_owned: true,
            owner: self(),
            session: false,
            client_fun: fn _m, _t, _r -> {:ok, %{"role" => "assistant", "content" => "ok"}, %{}} end
          )

        send(test_pid, {:kernel, kernel})

        receive do
          :crash -> exit(:boom)
        end
      end)

    assert_receive {:kernel, kernel}, 30_000
    Process.unlink(kernel)
    send(owner, :crash)

    assert wait_dead(kernel), "owner 崩溃后 kernel 应自停"
    assert wait_dead(ev), "kernel 停止后求值器应链式随停"
  end

  @tag :node
  @tag timeout: 120_000
  test "node 模式: kernel 停止 → 求值器自停 → primary/standby peer 节点全部消失" do
    {:ok, ev} = Evaluator.start(mode: :node)

    {:ok, kernel} =
      Loop.start_link(
        client: %{},
        evaluator: ev,
        evaluator_owned: true,
        session: false,
        client_fun: fn _m, _t, _r -> {:ok, %{"role" => "assistant", "content" => "ok"}, %{}} end
      )

    info = Evaluator.info(ev)
    nodes = [info.node, info.standby && info.standby.node] |> Enum.reject(&is_nil/1)
    assert nodes != []

    GenServer.stop(kernel)
    assert wait_dead(ev), "kernel 停止后求值器应随停"

    # peer 节点（BEAM 进程）应全部退出分布式集群——epmd 不再残留
    remaining =
      Enum.filter(nodes, fn n ->
        Enum.reduce_while(1..100, true, fn _, _ ->
          if n in Node.list(),
            do:
              (
                Process.sleep(50)
                {:cont, true}
              ),
            else: {:halt, false}
        end)
      end)

    assert remaining == [], "节点未释放: #{inspect(remaining)}"
  end
end
