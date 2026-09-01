defmodule Newbee.Agent.ContextBudgetTest do
  use ExUnit.Case, async: true
  alias Newbee.Agent.ContextBudget

  test "separates soft and hard request limits" do
    budget = ContextBudget.assess([], context_window: 1_000, overhead: 700, output_reserve: 100)

    assert budget.input_tokens == 703
    assert budget.request_tokens == 803
    assert budget.status == :soft_limit
    assert budget.soft_limit == 800
    assert budget.hard_limit == 950
    assert budget.headroom == 197
  end

  test "output reservation can move a request to the hard limit" do
    budget = ContextBudget.assess([], context_window: 1_000, overhead: 700, output_reserve: 300)

    assert budget.status == :hard_limit
    assert budget.request_tokens == 1003
    assert budget.headroom == 0
  end

  test "serialized messages use the conservative fallback estimate" do
    messages = [%{"role" => "user", "content" => String.duplicate("x", 300)}]
    budget = ContextBudget.assess(messages, context_window: 10_000, overhead: 0, output_reserve: 0)

    assert budget.input_tokens == 112
    assert budget.status == :ok
    assert budget.ratio < 0.02
  end

  test "invalid configuration falls back to safe defaults" do
    budget =
      ContextBudget.assess([], context_window: 0, soft_ratio: 2, hard_ratio: -1, overhead: -1, output_reserve: -1)

    assert budget.context_window == 256_000
    assert budget.soft_limit == 204_800
    assert budget.hard_limit == 243_200
    assert budget.output_reserve == 0
  end
end
