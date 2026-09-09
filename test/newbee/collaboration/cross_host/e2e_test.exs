defmodule Newbee.Collaboration.CrossHost.E2ETest do
  use ExUnit.Case, async: false
  alias Newbee.Collaboration.CrossHost.Group
  alias Newbee.Collaboration.CrossHost.Join
  alias Newbee.Collaboration.CrossHost.Auth
  alias Newbee.Collaboration.CrossHost.Scheduler
  alias Newbee.Collaboration.CrossHost.Task
  alias Newbee.Collaboration.CrossHost.Execution
  alias Newbee.Collaboration.CrossHost.Firewall
  test "single person three machines schedule and aggregate" do
    assert {:ok, g0, plain} = Group.create("order-dev", "order-system", password: "s3cure-pass-9")
    fp = "fp-abcdef-12345678"
    assert {:ok, g1, _} = Join.join(g0, %{"expected_fp" => fp, "presented_fp" => fp, "password" => plain, "member_id" => "alan", "display" => "dev-8"})
    assert {:ok, g2, _} = Join.join(g1, %{"expected_fp" => fp, "presented_fp" => fp, "password" => plain, "member_id" => "alan", "display" => "builder-20"})
    assert {:ok, g3, _} = Join.join(g2, %{"expected_fp" => fp, "presented_fp" => fp, "password" => plain, "member_id" => "alan", "display" => "tester-21"})
    devs = g3 |> Map.get("devices", %{}) |> Map.values()
    assert length(devs) == 3
    System.put_env("XH_TEST_ISOLATION", "1")
    caps = Scheduler.detect()
    assert Map.get(caps, "isolation_ready") == true
    assert {:ok, t} = Task.new(%{"group_id" => Map.get(g3, "id"), "project_id" => "order-system", "idempotency_key" => "k-e2e-1"})
    assert {:ok, t2} = Task.transition(t, "start")
    assert {:ok, exec} = Execution.start(t2, %{"files" => %{"app.ex" => "hello"}, "version" => 1})
    assert {:ok, exec2} = Execution.attach_preview(exec, "127.0.0.1", 4001)
    assert Firewall.preview_bind_ok?("127.0.0.1") == true
    assert {:error, "preview_exposed", _} = Execution.attach_preview(exec, "0.0.0.0", 3000)
    assert Execution.resume(exec2)["task_id"] == Map.get(t2, "id")
    :ok = Execution.cleanup(exec2)
    agg = Scheduler.aggregate([%{"status" => "ok"}, %{"status" => "ok"}, %{"status" => "failed"}])
    assert agg["total"] == 3
    assert agg["all_ok"] == false
  end
  test "multi person handover keeps isolation" do
    assert {:ok, g0, plain} = Group.create("order-dev", "order-system", password: "s3cure-pass-9")
    fp = "fp-abcdef-12345678"
    assert {:ok, g1, _} = Join.join(g0, %{"expected_fp" => fp, "presented_fp" => fp, "password" => plain, "member_id" => "alan", "display" => "dev-8"})
    assert {:ok, g2, _} = Join.join(g1, %{"expected_fp" => fp, "presented_fp" => fp, "password" => plain, "member_id" => "li", "display" => "dev-9"})
    assert {:ok, t} = Task.new(%{"group_id" => Map.get(g2, "id"), "project_id" => "order-system", "idempotency_key" => "k-handover-1", "creator" => "alan"})
    assert {:ok, h} = Task.handover(t, "li", %{"base" => "abc123", "progress" => "iface done, 2 tests failing"})
    assert Map.get(h, "assignee") == "li"
    assert Map.get(h, "status") == "queued"
    g3 = Auth.remove_member(g2, "li")
    assert map_size(Map.get(g3, "members", %{})) == 1
  end
end
