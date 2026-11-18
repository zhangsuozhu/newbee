defmodule Newbee.TestSupport.Lifecycle do
  @moduledoc """
  测试生命周期工具：以「尽力而为」的语义关停全局命名进程。

  起因（R1 门禁实跑）：`on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)`
  在门禁负载下偶发
  `** (exit) exited in: GenServer.stop(#PID<...>, :normal, :infinity) ** (EXIT) no process`。
  这是典型的 TOCTOU：`Process.alive?/1` 与 `GenServer.stop/1` 之间进程可能已经退出——
  共享的 `Newbee.Collaboration.Coordinator` 是全局命名进程，同一分区里多个测试文件都会
  起停它，前一个用例的 on_exit 完全可能先把后一个用例的进程停掉。

  语义：**已死的进程不是错误**。这里只吞 `:exit`，`GenServer.stop/2` 的正常返回值语义
  不变，用例不会因此掩盖产品缺陷。
  """

  @doc "进程还活着就停；已经不在（或被别人抢先停掉）视为成功。"
  def stop_if_alive(nil), do: :ok

  def stop_if_alive(pid) when is_pid(pid) do
    if Process.alive?(pid) do
      try do
        GenServer.stop(pid)
      catch
        :exit, _ -> :ok
      end
    else
      :ok
    end
  end

  @doc "按注册名停进程：名字没注册就是 `:ok`。"
  def stop_if_registered(name) when is_atom(name) do
    case Process.whereis(name) do
      nil -> :ok
      pid -> stop_if_alive(pid)
    end
  end
end
