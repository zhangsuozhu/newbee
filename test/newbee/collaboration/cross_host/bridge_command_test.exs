defmodule Newbee.Collaboration.CrossHost.BridgeCommandTest do
  use ExUnit.Case, async: false

  alias Newbee.Collaboration.{SharedContext, CrossHost.Auth}
  alias Newbee.Collaboration.CrossHost.{Bridge, Group, Store}

  setup do
    Store.clear()
    :ok
  end

  defp remote_group do
    {:ok, group, _pw} = Group.create("远程命令", "demo")
    group = Map.merge(group, %{"server_fp" => "sha256:" <> String.duplicate("a", 64), "members" => %{}})

    device = %{
      "id" => "dev-remote",
      "member_id" => "m-1",
      "display" => "远端机",
      "bridge" => true,
      "remote" => true,
      "capabilities" => [%{"name" => "demo.ping", "version" => "1", "arity" => 1}],
      "full_control" => false
    }

    group = Map.put(group, "devices", %{"dev-remote" => device})
    :ok = Store.put_group(group)
    group
  end

  test "queues an advertised capability invocation as an auditable task" do
    group = remote_group()

    assert {:ok, task} =
             Bridge.dispatch_command(
               group["id"],
               "dev-remote",
               "capability_invoke",
               %{
                 "capability" => "demo.ping",
                 "args" => ["hello"]
               },
               idempotency_key: "cmd-1"
             )

    assert task["kind"] == "capability_invoke"
    assert task["status"] == "accepted"
    assert task["command"]["args"] == ["hello"]
    assert [%{"task_id" => tid}] = Store.pending_deliveries("dev-remote")
    assert tid == task["id"]

    # 幂等：同一个 command_id 不会重复投递
    assert {:ok, again} =
             Bridge.dispatch_command(
               group["id"],
               "dev-remote",
               "capability_invoke",
               %{
                 "capability" => "demo.ping",
                 "args" => ["hello"]
               },
               idempotency_key: "cmd-1"
             )

    assert again["id"] == task["id"]
    assert length(Store.pending_deliveries("dev-remote")) == 1
  end

  test "refuses capabilities the device never advertised" do
    group = remote_group()

    assert {:error, "capability_unavailable", _} =
             Bridge.dispatch_command(group["id"], "dev-remote", "capability_invoke", %{
               "capability" => "demo.unknown",
               "args" => []
             })

    assert {:error, "bad_request", _} =
             Bridge.dispatch_command(group["id"], "dev-remote", "capability_invoke", %{
               "capability" => "demo.ping",
               "args" => "not-a-list"
             })
  end

  test "code push requires explicit opt-in and pins the source digest" do
    group = remote_group()
    source = "defmodule Newbee.RemoteExtensions.Demo do\n  def ping(v), do: v\nend"

    manifest = %{
      "name" => "demo.ping",
      "version" => "1",
      "module" => "Newbee.RemoteExtensions.Demo",
      "function" => "ping",
      "arity" => 1
    }

    assert {:error, "full_control_required", _} =
             Bridge.dispatch_command(group["id"], "dev-remote", "code_update", %{
               "source" => source,
               "manifest" => manifest
             })

    assert {:error, "full_control_required", _} =
             Bridge.dispatch_command(group["id"], "dev-remote", "full_control_eval", %{
               "source" => "System.cmd(\"id\", [])"
             })

    device = get_in(group, ["devices", "dev-remote"]) |> Map.put("full_control", true)
    :ok = Store.put_group(put_in(group, ["devices", "dev-remote"], device))

    assert {:ok, task} =
             Bridge.dispatch_command(group["id"], "dev-remote", "code_update", %{
               "source" => source,
               "manifest" => manifest
             })

    expected = :crypto.hash(:sha256, source) |> Base.encode16(case: :lower)
    assert task["command"]["source_sha256"] == expected
    assert task["source_digest"] == expected

    assert {:ok, control_task} =
             Bridge.dispatch_command(group["id"], "dev-remote", "full_control_eval", %{"source" => "File.cwd!()"})

    assert control_task["kind"] == "full_control_eval"
    assert control_task["source_digest"] == control_task["command"]["source_sha256"]
  end

  test "publishes a remote conversation so other members can read it" do
    group = remote_group()
    {group, device} = enrolled_device(group)

    assert {:ok, _} =
             Bridge.publish(%{
               "device_id" => device["id"],
               "token" => device["plain"],
               "session_id" => "far-session",
               "title" => "远端编译会话",
               "messages" => [
                 %{"role" => "user", "content" => "OPENAI_API_KEY=sk-should-redact"},
                 %{"role" => "assistant", "content" => "已编译通过"}
               ]
             })

    assert {:ok, entry} = Store.remote_session(group["id"], "far-session")
    refute inspect(entry) =~ "sk-should-redact"
    assert length(entry["messages"]) == 2

    :ok = Store.bind_session(%{"session_id" => "hub-lead", "group_id" => group["id"], "device_id" => nil})

    assert {:ok, history} = SharedContext.fetch("hub-lead", group["id"] <> "/history")
    assert Enum.any?(get_in(history, ["group", "sessions"]), &(&1["session_id"] == "far-session"))

    assert {:ok, detail} = SharedContext.fetch("hub-lead", group["id"] <> "/history/far-session")
    assert [%{"role" => "user"}, %{"role" => "assistant"}] = get_in(detail, ["group", "session", "messages"])
  end

  # 签发一枚真实设备凭据并登记到群，模拟已入群的远端 Worker。
  defp enrolled_device(group) do
    {:ok, updated, device} = Auth.issue_device(group, "m-1", "远端机")
    updated = put_in(updated, ["devices", device["id"], "bridge"], true)
    :ok = Store.put_group(updated)
    {updated, device}
  end

  test "authenticated group devices may request advertised capabilities" do
    group = remote_group()
    {_group, caller} = enrolled_device(group)

    assert {:ok, task} =
             Bridge.request_command(%{
               "device_id" => caller["id"],
               "token" => caller["plain"],
               "target_device_id" => "dev-remote",
               "capability" => "demo.ping",
               "args" => ["from-member"],
               "command_id" => "member-call-1"
             })

    assert task["kind"] == "capability_invoke"
    refute Map.has_key?(task, "command")
    assert Enum.any?(Store.pending_deliveries("dev-remote"), &(&1["task_id"] == task["id"]))

    assert {:error, "unauthorized", _} =
             Bridge.request_command(%{
               "device_id" => caller["id"],
               "token" => "bad-token",
               "target_device_id" => "dev-remote",
               "capability" => "demo.ping",
               "args" => []
             })
  end
end
