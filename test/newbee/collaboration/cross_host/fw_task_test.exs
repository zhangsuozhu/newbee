defmodule Newbee.Collaboration.CrossHost.FwTaskTest do
  use ExUnit.Case, async: true
  alias Newbee.Collaboration.CrossHost.Firewall
  alias Newbee.Collaboration.CrossHost.Task
  test "loopback only" do
    assert Firewall.loopback?("127.0.0.1") == true
    assert Firewall.loopback?("8.8.8.8") == false
    assert Firewall.preview_bind_ok?("127.0.0.1") == true
    assert Firewall.preview_bind_ok?("0.0.0.0") == false
  end
  test "plan verify" do
    plan = Firewall.plan("192.168.0.20", lan: true)
    assert :ok = Firewall.verify_plan(plan, [%{"proto" => "tcp", "port" => 8443}])
    assert {:error, "overbroad", _} = Firewall.verify_plan(plan, [%{"proto" => "tcp", "port" => 8443}, %{"src" => "0.0.0.0/0"}])
    assert {:error, "preview_exposed", _} = Firewall.verify_plan(plan, [%{"proto" => "tcp", "port" => 8443}, %{"port" => 3000}])
  end
  test "task lifecycle fence handover" do
    assert {:ok, t} = Task.new(%{"group_id" => "g1", "project_id" => "p1", "idempotency_key" => "k1"})
    assert {:ok, t2} = Task.transition(t, "start")
    assert {:ok, t3} = Task.transition(t2, "ok")
    assert Map.get(t3, "status") == "done"
    assert Task.fence_ok?(%{}, 5, 5) == true
    assert Task.fence_ok?(%{}, 3, 5) == false
    assert {:ok, h} = Task.handover(t3, "li", %{"base" => "abc"})
    assert {:error, "forbidden_handover", _} = Task.handover(t3, "li", %{"prod_credential" => "x"})
    assert Map.get(h, "assignee") == "li"
  end
end
