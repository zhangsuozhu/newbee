defmodule Newbee.Collaboration.CrossHost.SchedTest do
  use ExUnit.Case, async: true
  alias Newbee.Collaboration.CrossHost.Scheduler
  test "detect has keys" do
    System.put_env("XH_TEST_ISOLATION", "1")
    c = Scheduler.detect()
    assert Map.get(c, "elixir_ok") == true
    assert Map.get(c, "isolation_ready") == true
  end
  test "eligible and aggregate three machines" do
    devs = [%{"id" => "d1", "paused" => false}, %{"id" => "d2", "paused" => true}, %{"id" => "d3", "paused" => false}]
    caps = %{"d1" => %{"isolation_ready" => true}, "d3" => %{"isolation_ready" => true}, "__usage__d1" => %{"running" => 0, "host_running" => 0}, "__usage__d3" => %{"running" => 5, "host_running" => 0}}
    task = %{"requires" => %{}}
    sel = Scheduler.select(devs, caps, task)
    assert length(sel) == 1
    assert hd(sel)["id"] == "d1"
    agg = Scheduler.aggregate([%{"status" => "ok"}, %{"status" => "failed"}, %{"status" => "unexecuted"}])
    assert agg["total"] == 3
    assert agg["all_ok"] == false
    agg2 = Scheduler.aggregate([%{"status" => "ok"}, %{"status" => "ok"}])
    assert agg2["all_ok"] == true
  end
end
