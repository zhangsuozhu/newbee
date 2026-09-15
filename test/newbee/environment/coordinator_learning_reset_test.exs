defmodule Newbee.Environment.CoordinatorLearningResetTest do
  use Newbee.EnvironmentCase, async: false

  alias Newbee.Environment.Coordinator

  test "reset returns self-learning to no active lineage and keeps an audit event" do
    coordinator = start_coordinator!()

    baseline = %{
      "id" => "base-reset",
      "project_id" => "reset-test",
      "source_tree_hash" => String.duplicate("1", 64),
      "dependencies_hash" => String.duplicate("2", 64),
      "release_map" => %{},
      "memory_m0" => "mem-m0-reset",
      "model_config_hash" => String.duplicate("3", 64),
      "policy_hash" => String.duplicate("4", 64),
      "fixture_version" => "fixture-reset"
    }

    assert {:ok, _lineage} =
             Coordinator.learning_start(coordinator, %{
               "id" => "lineage-reset",
               "baseline" => baseline,
               "budget" => %{"total" => %{"calls" => 1}}
             })

    assert length(Coordinator.learning_list(coordinator)) == 1

    assert {:ok, %{reset: true, lineage_ids: ["lineage-reset"]}} =
             Coordinator.learning_reset(coordinator, "测试：恢复初始状态")

    assert Coordinator.learning_list(coordinator) == []
    assert File.read!(Newbee.Environment.Store.path(:events)) =~ "learning_reset"
  end
end
