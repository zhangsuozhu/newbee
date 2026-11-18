defmodule Newbee.LLM.InterruptScopeTest do
  # 中断位是 VM 级 persistent_term，测试之间必须串行。
  use ExUnit.Case, async: false

  alias Newbee.LLM.Client

  setup do
    # 上一个用例若被中断打断，可能留下位；先确保干净。
    Client.clear_interrupt()
    on_exit(fn -> Client.clear_interrupt() end)
    :ok
  end

  defp client_keys do
    :persistent_term.get()
    |> Enum.filter(fn {k, _} -> match?({mod, _} when mod == Client, k) end)
  end

  test "无 scope 时按 Esc 只在自己进程树生效，不影响另一个会话树（R2P-02 误中断）" do
    before = client_keys()

    Client.interrupt()
    assert Client.interrupted?(), "本进程树应当看到自己置的中断位"

    # spawn/1 出来的进程没有 $callers 关系 = 另一个 nil-scope 会话/会话树。
    parent = self()

    other =
      spawn(fn ->
        receive do
          :go -> send(parent, {:seen, Client.interrupted?()})
        end
      end)

    send(other, :go)

    assert_receive {:seen, seen}, 2_000
    assert seen == false, "另一个会话树不应看到中断位（改前共享 VM 级 legacy 位，会被误中断）"

    # 本进程的 Task 子树（$callers 继承）应当看到——这是"停得住子树"的另一面
    assert Task.async(fn -> Client.interrupted?() end) |> Task.await()

    Client.clear_interrupt()
    assert client_keys() -- before == [], "置位→清除后不应在本树残留键"
  end

  test "真实 scope 在多层 Task 中仍可读到（R2P-02 三：Esc 停得住子树）" do
    scope = Client.register_interrupt_scope()
    client = %Client{interrupt_scope: scope}
    on_exit(fn -> Client.clear_interrupt(client) end)
    Client.interrupt(client)

    result =
      Task.async(fn ->
        depth1 = Client.interrupted?(client)

        depth2 = Task.async(fn -> Client.interrupted?(client) end) |> Task.await()

        depth3 =
          Task.async(fn -> Task.async(fn -> Client.interrupted?(client) end) |> Task.await() end)
          |> Task.await()

        {depth1, depth2, depth3}
      end)
      |> Task.await()

    assert result == {true, true, true},
           "显式 client 在任意深度 Task 里都必须读到同一 scope 标志（改前 depth≥2 丢失）"

    # 无 client 的旧路径：子树沿 $callers 找到本进程注册的 scope
    assert Task.async(fn -> Client.interrupted?() end) |> Task.await()
  end

  test "不存在 :undefined 伪 scope（R2P-02 一）" do
    Client.interrupt()
    assert Client.interrupted?()

    assert :persistent_term.get({Client, {:interrupt, :undefined}}, :absent) == :absent,
           "改前 :proplists.get_value/2 缺键返回 :undefined 并被当成找到的 scope，于是全 VM 共享伪 scope"
  end

  test "clear_interrupt/0 只清自己树，不清别的会话" do
    mine = Client.register_interrupt_scope()
    other = %Client{interrupt_scope: Client.new_interrupt_scope()}
    on_exit(fn -> Client.clear_interrupt(other) end)

    Client.interrupt(other)
    Client.interrupt()
    assert Client.interrupted?()
    assert Client.interrupted?(other)

    Client.clear_interrupt()
    refute Client.interrupted?(), "自己的树被清掉"
    assert Client.interrupted?(other), "别的会话的中断位不受影响"
    assert Process.get({Client, :interrupt_scope}) == mine
  end
end
