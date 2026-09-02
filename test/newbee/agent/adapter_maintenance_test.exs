defmodule Newbee.Agent.AdapterMaintenanceTest do
  use Newbee.EnvironmentCase, async: false

  alias Newbee.Agent.Adapter
  alias Newbee.Environment.{Change, Coordinator, Store}

  defmodule FakeCoordinator do
    use GenServer

    def start_link(state), do: GenServer.start_link(__MODULE__, state)

    @impl true
    def init(state), do: {:ok, state}

    @impl true
    def handle_call(:current, _from, state), do: {:reply, state.current, state}

    def handle_call(:changes, _from, state), do: {:reply, state.changes, state}

    def handle_call({:activate, change_id, _opts}, _from, state) do
      send(state.owner, {:activated, change_id})
      {:reply, Map.get(state.activate_results, change_id, :ok), state}
    end
  end

  setup do
    Store.ensure!()
    :ok
  end

  test "maintenance checks active releases and promotes mature autonomous canaries" do
    ready = canary("chg_ready", "2025-01-01T00:00:00Z")

    {:ok, coordinator} =
      FakeCoordinator.start_link(%{
        owner: self(),
        current: %{autonomy: :autonomous, active: %{"tool.keep" => "rel_keep"}},
        changes: [ready],
        activate_results: %{}
      })

    assert %{
             deopts: [{:keep, "rel_keep"}],
             canaries: [{:activated, "chg_ready"}]
           } = Adapter.maintain(coordinator: coordinator, canary_min_age_ms: 0)

    assert_receive {:activated, "chg_ready"}
  end

  test "canary promotion respects autonomy, age, and Coordinator rejection" do
    now = ~U[2026-01-01 00:00:00Z]
    ready = canary("chg_ready", "2025-12-31T23:00:00Z")
    young = canary("chg_young", "2026-01-01T00:00:00Z")

    {:ok, manual} =
      FakeCoordinator.start_link(%{
        owner: self(),
        current: %{autonomy: :manual, active: %{}},
        changes: [ready],
        activate_results: %{}
      })

    assert [] = Adapter.promote_ready_canaries(manual, now: now, canary_min_age_ms: 60_000)
    refute_receive {:activated, _}

    {:ok, autonomous} =
      FakeCoordinator.start_link(%{
        owner: self(),
        current: %{autonomy: :autonomous, active: %{}},
        changes: [ready, young],
        activate_results: %{"chg_ready" => {:error, {:stale_base, 1, 2}}}
      })

    assert [{:kept, "chg_ready", {:stale_base, 1, 2}}] =
             Adapter.promote_ready_canaries(autonomous,
               now: now,
               canary_min_age_ms: 60_000
             )

    assert_receive {:activated, "chg_ready"}
    refute_receive {:activated, "chg_young"}
  end

  test "repeated API needs promote L1 to L2 once through the full Change lifecycle" do
    coordinator = start_coordinator!(autonomy: :manual)

    needs = [
      need("worker:101", "Newbee.Tools.Run.sh/2 should honor timeout"),
      need("worker:102", "Run.sh should validate cwd before execution"),
      need("worker:103", "Return-shape guard for Newbee.Tools.Run.sh/2")
    ]

    assert [{:ok, change_id, plugin_id, 3}] =
             Adapter.promote_need_clusters(
               coordinator: coordinator,
               needs: needs,
               need_promotion_threshold: 3
             )

    assert String.starts_with?(plugin_id, "rule.jit_need_")

    assert [] =
             Adapter.promote_need_clusters(
               coordinator: coordinator,
               needs: needs,
               need_promotion_threshold: 3
             )

    change = wait_for_status(coordinator, change_id, [:canary, :rejected])
    assert change.status == :canary, inspect(change.evaluation_result)

    [evidence] = change.evidence
    assert (evidence[:jit_promotion] || evidence["jit_promotion"]) == "l1_to_l2"
    assert (evidence[:cluster_key] || evidence["cluster_key"]) == "api:run.sh"

    assert (evidence[:message_ids] || evidence["message_ids"]) ==
             ~w(worker:101 worker:102 worker:103)
  end

  test "duplicate delivery of one need does not satisfy the promotion threshold" do
    coordinator = start_coordinator!(autonomy: :manual)
    duplicate = need("worker:duplicate", "Newbee.Tools.Run.sh/2 timeout guard")

    assert [] =
             Adapter.promote_need_clusters(
               coordinator: coordinator,
               needs: [duplicate, duplicate, duplicate]
             )

    assert [] = Coordinator.changes(coordinator)
  end

  test "observe mode does not create need promotion candidates" do
    coordinator = start_coordinator!(autonomy: :observe)
    needs = Enum.map(1..3, &need("worker:20#{&1}", "Edit.patch replacement guard"))

    assert [] = Adapter.promote_need_clusters(coordinator: coordinator, needs: needs)
    assert [] = Coordinator.changes(coordinator)
  end

  defp need(message_id, capability) do
    %{
      "message_id" => message_id,
      "payload" => %{
        "capability" => capability,
        "expected_api" => "",
        "evidence" => "test"
      }
    }
  end

  defp wait_for_status(coordinator, change_id, statuses, retries \\ 200)

  defp wait_for_status(coordinator, change_id, statuses, retries) do
    change = Enum.find(Coordinator.changes(coordinator), &(&1.change_id == change_id))

    if change.status in statuses or retries == 0 do
      change
    else
      Process.sleep(20)
      wait_for_status(coordinator, change_id, statuses, retries - 1)
    end
  end

  defp canary(id, updated_at) do
    %Change{
      change_id: id,
      status: :canary,
      updated_at: updated_at,
      evaluation_result: %{"passed" => true}
    }
  end
end
