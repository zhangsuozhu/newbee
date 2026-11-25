defmodule Newbee.Collaboration.CrossHost.TaskLifecycleTest do
  use ExUnit.Case, async: true
  alias Newbee.Collaboration.CrossHost.Task

  test "accepted command tasks can start and reach terminal states" do
    assert {:ok, task} = Task.new(%{"group_id" => "g", "project_id" => "p", "idempotency_key" => "k"})
    accepted = Map.put(task, "status", "accepted")
    assert Task.status_valid?("accepted")
    assert {:ok, running} = Task.transition(accepted, "start")
    assert running["status"] == "running"
    assert running["attempts"] == 1
    assert {:ok, done} = Task.transition(running, "ok")
    assert done["status"] == "done"
    assert {:error, "bad_transition", _} = Task.transition(done, "start")
  end

  test "accepted tasks can be cancelled" do
    assert {:ok, task} = Task.new(%{"group_id" => "g", "project_id" => "p", "idempotency_key" => "k2"})
    assert {:ok, cancelled} = task |> Map.put("status", "accepted") |> then(&Task.transition(&1, "cancel"))
    assert cancelled["status"] == "failed"
  end
end
