defmodule Newbee.Environment.UsageTrackerTest do
  use Newbee.EnvironmentCase, async: false

  alias Newbee.Environment.{Coordinator, Fitness, UsageTracker}

  setup do
    coordinator = start_coordinator!()
    on_exit(fn -> stop_coordinator(coordinator) end)
    {:ok, coordinator: coordinator}
  end

  test "attributes one cell use to each referenced active release", %{coordinator: coordinator} do
    active = Coordinator.current(coordinator).active
    fs_release = active["tool.fs"]
    json_release = active["tool.json"]
    run_release = active["tool.run"]

    assert :ok =
             UsageTracker.observe_code(
               "Newbee.Tools.Fs.read!(\"a\"); Newbee.Tools.Fs.exists?(\"b\"); Newbee.Tools.Json.decode(\"{}\")",
               %{success: true, latency_ms: 25, output_bytes: 12, task_type: "run_elixir"}
             )

    assert %{samples: 1, success_rate: 1.0, avg_latency_ms: 25.0} = Fitness.overall(fs_release)
    assert %{samples: 1, success_rate: 1.0} = Fitness.overall(json_release)
    assert %{samples: 0} = Fitness.overall(run_release)
  end

  test "tracks direct plugin use and ignores unknown plugins", %{coordinator: coordinator} do
    release = Coordinator.current(coordinator).active["projection.repomap"]

    assert :ok =
             UsageTracker.observe_plugin("projection.repomap", %{success: true, output_bytes: 100})

    assert :ok = UsageTracker.observe_plugin("tool.not-active", %{success: true})
    assert Fitness.overall(release).samples == 1
  end
end
