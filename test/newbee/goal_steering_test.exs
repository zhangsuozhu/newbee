defmodule Newbee.GoalTest do
  use ExUnit.Case, async: true

  test "new_state creates rich goal" do
    g = Newbee.Goal.new_state("test objective", token_budget: 1000, max_rounds: 10)
    assert g.text == "test objective"
    assert g.status == :active
    assert g.token_budget == 1000
    assert g.max_rounds == 10
    assert g.id =~ ~r/^goal_/
  end

  test "steering templates generate prompts" do
    g = %{text: "fix bug", token_budget: 500, tokens_used: 100, rounds: 2, max_rounds: 10, session_id: nil}
    cont = Newbee.Goal.Steering.continuation(g)
    assert cont =~ "fix bug"
    assert cont =~ "Tokens used"
    budget = Newbee.Goal.Steering.budget_limit(g)
    assert budget =~ "Budget Limited"
    refl = Newbee.Goal.Steering.reflection(g, "重复调用")
    assert refl =~ "Reflection"
  end

  test "goal persist and load" do
    sid = "test-#{System.unique_integer([:positive])}"
    g = Newbee.Goal.new_state("persist test", session_id: sid)
    :ok = Newbee.Goal.persist(g)
    {:ok, loaded} = Newbee.Goal.load(sid)
    assert loaded["text"] == "persist test"
    :ok = Newbee.Goal.clear_persist(sid)
    assert {:error, _} = Newbee.Goal.load(sid)
  end

  test "loop budget parsing" do
    # via Commands parse helpers (indirectly test Loop's parse)
    assert Newbee.Goal.new_state("x", token_budget: "1000").token_budget == 1000
    assert Newbee.Goal.new_state("x", token_budget: "bad").token_budget == nil
  end
end
