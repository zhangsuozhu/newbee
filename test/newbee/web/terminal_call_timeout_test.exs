# 回归：终端 RPC 超时必须降级成错误元组，而不是 exit 把 WebSocket 处理进程带崩。
# 背景：并行负载下 terminal_wake 的 take_context 撞到 5s GenServer.call 超时，
# collaboration_socket_test 里表现为 `(exit) exited in: GenServer.call(..., :take_context, 5000)`。
defmodule Newbee.Web.TerminalCallTimeoutTest do
  use ExUnit.Case, async: false

  alias Newbee.Web.Terminal

  defmodule BusyTerminal do
    @moduledoc "替身：收下 :take_context 但久不回应，模拟终端进程卡住。"
    use GenServer

    def start_link(sid) do
      GenServer.start_link(__MODULE__, nil, name: {:via, Registry, {Newbee.Web.TerminalRegistry, sid}})
    end

    @impl true
    def init(_), do: {:ok, nil}

    @impl true
    def handle_call(:take_context, _from, state) do
      Process.sleep(30_000)
      {:reply, {:ok, ""}, state}
    end
  end

  test "take_context 超时返回 {:error, :timeout} 而不是退出" do
    sid = "terminal-timeout-" <> Integer.to_string(System.unique_integer([:positive]))
    {:ok, pid} = BusyTerminal.start_link(sid)
    on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :kill) end)

    assert {:error, :timeout} = Terminal.take_context(sid)
  end

  test "没有终端时仍返回原行为" do
    absent = "terminal-absent-" <> Integer.to_string(System.unique_integer([:positive]))
    assert {:ok, ""} = Terminal.take_context(absent)
    assert {:error, :not_open} = Terminal.interrupt(absent)
  end
end
