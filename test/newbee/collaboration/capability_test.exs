defmodule Newbee.Collaboration.CapabilityTest do
  use ExUnit.Case, async: false

  alias Newbee.Collaboration.{Capability, Coordinator}

  setup do
    assert is_pid(Process.whereis(Capability))

    on_exit(fn ->
      Process.delete({Newbee.Tools.Collaboration, :context})
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

  test "工具拒绝 token 身份与参数身份不一致" do
    if pid = Process.whereis(Coordinator), do: GenServer.stop(pid)

    root = Path.join(System.tmp_dir!(), "newbee-capability-#{System.unique_integer([:positive])}")

    {:ok, coordinator} =
      Coordinator.start_link(path: Path.join(root, "events.jsonl"), durability: :event)

    assert {:ok, group} =
             Coordinator.create_group(%{"session_id" => "session-a", "title" => "安全群"})

    assert {:ok, _} = Coordinator.add_member(group["group_id"], %{"session_id" => "session-b"})

    assert :ok = Capability.register(self(), "session-a", File.cwd!())
    assert {:ok, token} = Capability.issue(self())
    Process.put({Newbee.Tools.Collaboration, :context}, %{capability: token})

    assert {:error, "identity_mismatch", _} =
             Newbee.Tools.Collaboration.send_message(group["group_id"], "session-b", "伪造消息")

    assert {:ok, []} = Coordinator.messages(group["group_id"])

    assert {:ok, message} =
             Newbee.Tools.Collaboration.send_message(group["group_id"], "session-a", "真实消息")

    assert message["sender_session_id"] == "session-a"

    Process.delete({Newbee.Tools.Collaboration, :context})
    Capability.revoke(token)
    GenServer.stop(coordinator)
    File.rm_rf!(root)
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
