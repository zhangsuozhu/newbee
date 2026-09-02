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
