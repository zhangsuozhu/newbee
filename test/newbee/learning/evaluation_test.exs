defmodule Newbee.Learning.EvaluationTest do
  use ExUnit.Case, async: true
  alias Newbee.Learning.{Evaluation, Fixtures}

  defp spec do
    heldout = Fixtures.list(:heldout) |> Enum.take(2) |> Enum.map(& &1["id"])
    %{
      "source" => %{"tree_hash" => String.duplicate("a", 64), "dependencies_hash" => String.duplicate("b", 64)},
      "release_map" => %{},
      "model" => %{"provider" => "test", "name" => "fixture-model"},
      "judge" => %{"id" => "deterministic", "version" => "1"},
      "fixtures" => %{"development" => ["dev_syntax_missing_do"], "heldout" => heldout},
      "trials" => 1,
      "budget" => %{"per_task" => 10},
      "arms" => %{"baseline" => %{"memory_id" => "m0"}, "candidate" => %{"memory_id" => "m1"}}
    }
  end

  test "locks disjoint cohort and interleaved paired plan" do
    assert {:ok, protocol} = Evaluation.lock(spec())
    assert protocol["schema_version"] == 1
    assert length(protocol["plan"]) == 4
    assert Enum.map(protocol["plan"], & &1["sequence"]) == [0, 1, 2, 3]
    assert MapSet.size(MapSet.new(protocol["spec"]["fixtures"]["heldout"])) == 2
  end

  test "summarize retains unresolved outcomes and refuses duplicates" do
    {:ok, protocol} = Evaluation.lock(spec())
    [first | rest] = protocol["plan"]
    outcome = Map.merge(first, %{"status" => "pass", "protocol_hash" => protocol["protocol_hash"], "cost" => %{"tokens" => 3}})
    assert {:error, {:duplicate_attempt, _}} = Evaluation.summarize(protocol, [outcome, outcome])
    missing = Enum.map(rest, &Map.merge(&1, %{"status" => "missing", "protocol_hash" => protocol["protocol_hash"]}))
    assert {:ok, report} = Evaluation.summarize(protocol, [outcome | missing])
    assert report["conclusion"] == "invalid"
    assert report["promotion"] == "manual_review_required"
    assert report["coverage"]["planned_cells"] == 4
  end

  test "public fixture descriptors do not expose oracle fields" do
    assert {:ok, descriptor} = Fixtures.get("held_case_clause_add_clause")
    refute Map.has_key?(descriptor, "expect")
    refute Map.has_key?(descriptor, "oracle")
  end
end