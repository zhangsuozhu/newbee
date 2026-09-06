defmodule Newbee.Collaboration.CapabilityTest do
  use ExUnit.Case, async: false

  alias Newbee.Collaboration.{Capability, Coordinator}
  alias Newbee.Tools.Hive

  setup do
    assert is_pid(Process.whereis(Capability))

    on_exit(fn ->
      Process.delete({Newbee.Tools.Hive, :context})
    end)

    :ok
  end

  test "只有 owner 能注册和签发，撤销后立即失效" do
    parent = self()

    assert {:error, "capability_forbidden", _} =
             Task.async(fn -> Capability.register(parent, "session-a", File.cwd!()) end)
             |> Task.await()

    assert :ok = Capability.register(self(), "session-a", File.cwd!())
    assert {:ok, token} = Capability.issue(self())
    assert {:ok, %{session_id: "session-a"}} = Capability.resolve(token)

    Capability.revoke(token)

    assert eventually(fn ->
             match?({:error, "invalid_capability", _}, Capability.resolve(token))
           end)
  end

  test "Hive.send derives sender identity from the capability and addresses the target" do
    if pid = Process.whereis(Coordinator), do: GenServer.stop(pid)

    root = Path.join(System.tmp_dir!(), "newbee-capability-" <> Integer.to_string(System.unique_integer([:positive])))

    {:ok, coordinator} =
      Coordinator.start_link(path: Path.join(root, "events.jsonl"), durability: :event)

    assert {:ok, group} =
             Coordinator.create_group(%{
               "session_id" => "session-a",
               "title" => "安全群",
               "project_root" => File.cwd!(),
               "command_id" => "capability-group"
             })

    assert {:ok, _} = Coordinator.add_member(group["group_id"], %{"session_id" => "session-b"})

    assert :ok = Capability.register(self(), "session-a", File.cwd!())
    assert {:ok, token} = Capability.issue(self())
    Process.put({Newbee.Tools.Hive, :context}, %{capability: token})

    assert {:ok, message} = Hive.send(group["group_id"], "session-b", "真实消息")
    assert message["sender_session_id"] == "session-a"
    assert message["to_session_id"] == "session-b"

    assert {:ok, [%{"sender_session_id" => "session-a", "to_session_id" => "session-b"}]} =
             Coordinator.messages(group["group_id"])

    Process.delete({Newbee.Tools.Hive, :context})
    Capability.revoke(token)
    GenServer.stop(coordinator)
    File.rm_rf!(root)
  end

  test "无 capability 上下文时拒绝 Hive 调用" do
    Process.delete({Newbee.Tools.Hive, :context})

    assert {:error, "no_execution_context", _} =
             Hive.inbox("group-without-context")
  end

  defp eventually(fun), do: eventually(fun, 20)

  defp eventually(fun, attempts) when attempts > 0 do
    if fun.() do
      true
    else
      Process.sleep(10)
      eventually(fun, attempts - 1)
    end
  end

  defp eventually(_fun, 0), do: false
end
