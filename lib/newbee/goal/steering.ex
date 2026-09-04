defmodule Newbee.Goal.Steering do
  @moduledoc """
  Goal steering templates: three Codex-style injections plus a JSpace ledger excerpt.
  """

  def continuation(goal) do
    objective = escape(goal.text || goal[:objective] || "")
    tokens_used = to_string(goal.tokens_used || 0)
    token_budget = if goal.token_budget, do: to_string(goal.token_budget), else: "none"
    remaining = if goal.token_budget, do: to_string(max(goal.token_budget - (goal.tokens_used || 0), 0)), else: "unbounded"
    rounds = to_string(goal.rounds || 0)
    max_rounds = to_string(goal.max_rounds || 50)
    jspace_hint = jspace_snippet(goal[:session_id] || goal["session_id"])

    "[Goal Continuation #{rounds}/#{max_rounds}] (autonomous round #{rounds})" <>
    "\nObjective:\n<objective>\n" <> objective <> "\n</objective>\n\n" <>
    "Budget:\n- Tokens used: " <> tokens_used <> "\n- Token budget: " <> token_budget <> "\n- Remaining: " <> remaining <> "\n\n" <>
    jspace_hint <>
    "Keep pushing the objective; show real progress every round. Call done when achieved."
  end

  def budget_limit(goal) do
    objective = escape(goal.text || goal[:objective] || "")
    tokens_used = to_string(goal.tokens_used || 0)
    token_budget = to_string(goal.token_budget || 0)
    "[Goal Budget Limited]\n<objective>\n" <> objective <> "\n</objective>\n\nBudget: " <> tokens_used <> " / " <> token_budget
  end

  def objective_updated(goal) do
    objective = escape(goal.text || goal[:objective] || "")
    "[Goal Objective Updated]\n<new_objective>\n" <> objective <> "\n</new_objective>"
  end
  def reflection(goal, reason) do
    "[Goal Reflection] Detected " <> reason <> " (no tool calls for several rounds). Reflect before acting. Round: " <> to_string(goal.rounds || 0) <> " (autonomous round #{goal.rounds})"
  end
  def idle_reminder(round) do
    "(Autonomous round #{round}: no tool calls and no real progress for several rounds. Act now: inspect/run/edit/verify. Call done if the goal is met.)"
  end

  def verification_gate_message do
    "[JSpace Verification Gate] Ledger exists but verified is empty."
  end

  defp escape(text) do
    text |> String.replace("&", "&amp;") |> String.replace("<", "&lt;") |> String.replace(">", "&gt;")
  end

  defp jspace_snippet(nil), do: ""
  defp jspace_snippet(session_id) do
    case Newbee.Tools.JSpace.read(session_id) do
      nil -> ""
      body when byte_size(body) > 800 -> "Ledger excerpt:\n" <> String.slice(body, 0, 800) <> "\n...\n"
      body -> "Ledger:\n" <> body <> "\n"
    end
  rescue
    _ -> ""
  end
end
