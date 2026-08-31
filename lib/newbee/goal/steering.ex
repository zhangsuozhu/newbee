defmodule Newbee.Goal.Steering do
  @moduledoc """
  Goal steering 注入模板，借鉴 Codex 的三模板设计并融入 JSpace 摘要。
  """

  def continuation(goal) do
    objective = escape(goal.text || goal[:objective] || "")
    tokens_used = to_string(goal.tokens_used || 0)
    token_budget = if goal.token_budget, do: to_string(goal.token_budget), else: "none"
    remaining = if goal.token_budget, do: to_string(max(goal.token_budget - (goal.tokens_used || 0), 0)), else: "unbounded"
    rounds = to_string(goal.rounds || 0)
    max_rounds = to_string(goal.max_rounds || 50)
    jspace_hint = jspace_snippet(goal[:session_id] || goal["session_id"])

    "[Goal Continuation #{rounds}/#{max_rounds}]（自主模式第 #{rounds} 轮）" <>
    "\n目标:\n<objective>\n" <> objective <> "\n</objective>\n\n" <>
    "预算:\n- Tokens used: " <> tokens_used <> "\n- Token budget: " <> token_budget <> "\n- Remaining: " <> remaining <> "\n\n" <>
    jspace_hint <>
    "要求: 持续推进目标，每轮有实质进展。达成后调用 done。"
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
    "[Goal Reflection] 检测到 " <> reason <> "（连续多轮没有调用工具）。请先反思再行动。轮次: " <> to_string(goal.rounds || 0) <> "（自主模式第 #{goal.rounds} 轮）"
  end

  def idle_reminder(round) do
    "（自主模式第 #{round} 轮：连续多轮没有调用工具、没有实质进展。请立即采取行动：检查/运行/修改/验证。若目标已达成请调用 done。）"
  end

  def verification_gate_message do
    "[JSpace Verification Gate] Ledger 存在但 verified 为空。"
  end

  defp escape(text) do
    text |> String.replace("&", "&amp;") |> String.replace("<", "&lt;") |> String.replace(">", "&gt;")
  end

  defp jspace_snippet(nil), do: ""
  defp jspace_snippet(session_id) do
    case Newbee.Tools.JSpace.read(session_id) do
      nil -> ""
      body when byte_size(body) > 800 -> "Ledger 摘要:\n" <> String.slice(body, 0, 800) <> "\n...\n"
      body -> "Ledger:\n" <> body <> "\n"
    end
  rescue
    _ -> ""
  end
end
