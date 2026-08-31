defmodule Newbee.Environment.CoordinatorReevaluateTest do
  use Newbee.EnvironmentCase, async: false

  alias Newbee.Environment.Coordinator

  setup do
    coordinator = start_coordinator!()
    {:ok, coordinator: coordinator}
  end

  test "stale candidate must be reevaluated on the current revision before approval", %{
    coordinator: coordinator
  } do
    {:ok, first} =
      Coordinator.propose_change(coordinator, %{reason: "first", author_agent: :adapter})

    {:ok, second} =
      Coordinator.propose_change(coordinator, %{reason: "second", author_agent: :adapter})

    {:ok, _} =
      Coordinator.candidate_ready(coordinator, first.change_id, %{
        plugin_id: "rule.first",
        kind: :rule,
        source_files: %{"first.ex" => rule_source("first", "first", "first rule")}
      })

    {:ok, second_release} =
      Coordinator.candidate_ready(coordinator, second.change_id, %{
        plugin_id: "rule.second",
        kind: :rule,
        source_files: %{"second.ex" => rule_source("second", "second", "second rule")}
      })

    assert %{status: :canary} = wait_for_status(coordinator, first.change_id, [:canary])

    assert %{status: :canary, base_revision: 0, attempt: 1} =
             wait_for_status(coordinator, second.change_id, [:canary])

    assert :ok = Coordinator.approve(coordinator, first.change_id, "test-user")
    assert Coordinator.current(coordinator).revision == 1

    assert {:error, {:stale_base, 0, 1}} =
             Coordinator.approve(coordinator, second.change_id, "test-user")

    assert {:ok, %{base_revision: 1, attempt: 2, status: :building}} =
             Coordinator.reevaluate(coordinator, second.change_id)

    assert %{status: :canary, base_revision: 1, attempt: 2} =
             wait_for_status(coordinator, second.change_id, [:canary])

    assert :ok = Coordinator.approve(coordinator, second.change_id, "test-user")
    current = Coordinator.current(coordinator)
    assert current.revision == 2
    assert current.active["rule.second"] == second_release.release_id
    assert {:error, :already_active} = Coordinator.reevaluate(coordinator, second.change_id)
  end

  defp wait_for_status(coordinator, change_id, statuses, retries \\ 200)

  defp wait_for_status(coordinator, change_id, statuses, retries) do
    change =
      try do
        Enum.find(Coordinator.changes(coordinator), &(&1.change_id == change_id))
      catch
        :exit, _ ->
          Process.sleep(500)
          nil
      end

    change = change || %{status: :missing, change_id: change_id}

    if change.status in statuses or retries == 0 do
      change
    else
      Process.sleep(20)
      wait_for_status(coordinator, change_id, statuses, retries - 1)
    end
  end
end
