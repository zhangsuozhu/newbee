defmodule Newbee.Environment.ReplayCoverageTest do
  use Newbee.EnvironmentCase, async: false

  alias Newbee.Environment.{Change, Coordinator, Store}

  test "coverage counts executed counterfactual evidence among evaluated changes" do
    Store.ensure!()

    persist_change(
      change("covered", %{
        "passed" => true,
        "layers" => %{"counterfactual" => %{"passed" => true, "diffs" => []}}
      })
    )

    persist_change(
      change("skipped", %{
        "passed" => true,
        "layers" => %{
          "counterfactual" => %{
            "passed" => "true",
            "skipped" => "true",
            "reason" => "not_required_at_ring"
          }
        }
      })
    )

    persist_change(change("unevaluated", nil))

    coordinator = start_coordinator!()
    evidence = Coordinator.autonomy_evidence(coordinator)

    assert evidence.replay_coverage == 0.5
  end

  test "Coordinator updates autonomy without a restart" do
    coordinator = start_coordinator!(autonomy: :manual)

    assert Coordinator.current(coordinator).autonomy == :manual
    assert :ok = Coordinator.set_autonomy(coordinator, :autonomous)
    assert Coordinator.current(coordinator).autonomy == :autonomous

    assert {:error, :invalid_level} = Coordinator.set_autonomy(coordinator, :invalid)
    assert Coordinator.current(coordinator).autonomy == :autonomous
  end

  test "migrates the removed collaboration builtin to Hive on store recovery" do
    Store.ensure!()

    legacy_active =
      Newbee.Plugins.builtin_active_map()
      |> Map.delete("tool.hive")
      |> Map.put("tool.collaboration", "tool.collaboration@d58e9a462bfc")

    environment = %{
      "schema" => Store.schema_version(),
      "revision" => 3,
      "active" => legacy_active,
      "checkpoint" => 7,
      "manifest" => %{
        "revision" => 3,
        "active" => legacy_active,
        "revisions" => [],
        "checkpoint" => 7,
        "degraded" => []
      }
    }

    Store.write_atomic!(
      Store.path(:environment),
      Jason.encode_to_iodata!(environment, pretty: true)
    )

    assert :ok = Store.ensure!()
    assert {:ok, restored} = Store.load_environment()
    assert restored["active"]["tool.hive"] == Newbee.Plugins.builtin("tool.hive").release_id
    refute Map.has_key?(restored["active"], "tool.collaboration")
    assert restored["manifest"]["active"] == restored["active"]

    assert {:ok, _release} =
             Newbee.Environment.PluginManager.fetch_or_builtin(restored["active"]["tool.hive"])

    assert :ok = Newbee.Environment.Generation.load_active_into(Node.self())
  end

  defp change(id, evaluation_result) do
    %Change{
      change_id: "chg_#{id}",
      status: :canary,
      created_at: "2026-01-01T00:00:00Z",
      updated_at: "2026-01-01T00:00:00Z",
      evaluation_result: evaluation_result
    }
  end

  defp persist_change(change) do
    dir = Path.join(Store.dir(:changes), change.change_id)
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "change.json"), Jason.encode!(Change.to_map(change)))
  end
end
