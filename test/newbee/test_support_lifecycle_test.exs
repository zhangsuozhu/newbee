defmodule Newbee.TestSupport.LifecycleTest do
  @moduledoc """
  生命周期工具的契约：关停必须是幂等的，且不能掩盖真实关停语义。

  R1 门禁实跑出现过一次 `GenServer.stop(...) -> ** (EXIT) no process`：共享命名进程
  （`Newbee.Collaboration.Coordinator`）在同一分区里被多个测试文件起停，`Process.alive?/1`
  与 `GenServer.stop/1` 之间的 TOCTOU 把用例变成假红。这条用例锁住"重复关停不报错"。
  """
  use ExUnit.Case, async: true

  alias Newbee.TestSupport.Lifecycle

  test "对 nil / 已死进程 / 未注册名字都返回 :ok" do
    assert Lifecycle.stop_if_alive(nil) == :ok

    pid = spawn(fn -> :ok end)
    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, _}, 1_000
    assert Lifecycle.stop_if_alive(pid) == :ok

    assert Lifecycle.stop_if_registered(:no_such_process_newbee_test) == :ok
    assert Lifecycle.stop_if_registered(:no_such_process_newbee_test) == :ok
  end

  test "活着就停：进程确实退出，重复调用仍然 :ok" do
    {:ok, pid} = Agent.start_link(fn -> :state end)
    ref = Process.monitor(pid)

    assert Lifecycle.stop_if_alive(pid) == :ok
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 1_000
    assert Lifecycle.stop_if_alive(pid) == :ok
  end

  test "按名字停：注册后停掉，名字随之消失" do
    name = :"lifecycle_probe_#{System.unique_integer([:positive])}"
    {:ok, pid} = Agent.start_link(fn -> :ok end, name: name)
    assert Process.whereis(name) == pid

    assert Lifecycle.stop_if_registered(name) == :ok
    assert Process.whereis(name) == nil
    assert Lifecycle.stop_if_registered(name) == :ok
  end

  test "并发关停同一个进程不会抛异常（TOCTOU 的原始触发条件）" do
    {:ok, pid} = Agent.start_link(fn -> :ok end)

    results =
      1..8
      |> Enum.map(fn _ -> Task.async(fn -> Lifecycle.stop_if_alive(pid) end) end)
      |> Enum.map(&Task.await(&1, 5_000))

    assert Enum.all?(results, &(&1 == :ok))
  end
end
