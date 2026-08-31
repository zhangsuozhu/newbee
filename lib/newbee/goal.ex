defmodule Newbee.Goal do
  @moduledoc """
  自主目标驱动（同步版 + 富状态），借鉴 Codex thread_goals。
  """

  @max_rounds 50

  defmodule State do
    @enforce_keys [:id, :text]
    defstruct id: nil,
              text: nil,
              objective: nil,
              status: :active,
              token_budget: nil,
              tokens_used: 0,
              time_used_ms: 0,
              rounds: 0,
              max_rounds: 50,
              idle: 0,
              blocked_streak: 0,
              last_block_reason: nil,
              created_at: nil,
              updated_at: nil,
              session_id: nil

    @statuses [:active, :paused, :budget_limited, :blocked, :complete]
    def statuses, do: @statuses
    def valid_status?(s) when s in @statuses, do: true
    def valid_status?(_), do: false
  end

  def new_state(text, opts \\ []) do
    now = System.system_time(:millisecond)
    tok_budget = Keyword.get(opts, :token_budget) || Keyword.get(opts, :budget)
    %State{
      id: "goal_" <> random_id(),
      text: String.trim(text),
      objective: String.trim(text),
      status: :active,
      token_budget: normalize_budget(tok_budget),
      tokens_used: 0,
      time_used_ms: 0,
      rounds: 0,
      max_rounds: Keyword.get(opts, :max_rounds, @max_rounds),
      idle: 0,
      blocked_streak: 0,
      created_at: now,
      updated_at: now,
      session_id: Keyword.get(opts, :session_id)
    }
  end

  def run(kernel, text, opts \\ []) do
    max_rounds = Keyword.get(opts, :max_rounds, @max_rounds)
    do_run(kernel, text, max_rounds, 1)
  end

  def continue(kernel, text) do
    Newbee.Agent.Loop.submit(kernel, text)
  end

  defp do_run(kernel, text, max_rounds, round, error_retryed? \\ false)
  defp do_run(_kernel, _text, max_rounds, round, _error_retryed?) when round > max_rounds do
    {:goal_limit, round - 1}
  end
  defp do_run(kernel, text, max_rounds, round, error_retryed?) do
    input = if round == 1, do: text, else: "（自主模式第 #{round} 轮：目标未达成，请继续工作。达成后调用 done。）"
    case Newbee.Agent.Loop.submit(kernel, input) do
      {:done, summary} -> {:done, summary}
      {:ask, q} -> {:ask, q}
      {:text, _} -> do_run(kernel, text, max_rounds, round + 1, false)
      {:interrupted, _} -> {:interrupted, :user}
      {:error, e} ->
        if error_retryed? do
          {:error, e}
        else
          Newbee.DebugLog.log(:goal, "LLM error on round #{round}, retrying: #{inspect(e)}")
          do_run(kernel, text, max_rounds, round + 1, true)
        end
    end
  end

  def persist(_state, _ \\ nil)
  def persist(%State{session_id: nil}, _), do: :ok
  def persist(%State{} = s, _) do
    path = goal_path(s.session_id)
    File.mkdir_p!(Path.dirname(path))
    json = %{"id" => s.id, "text" => s.text, "status" => to_string(s.status), "token_budget" => s.token_budget, "tokens_used" => s.tokens_used, "rounds" => s.rounds, "max_rounds" => s.max_rounds, "updated_at" => s.updated_at} |> Jason.encode!()
    File.write!(path, json)
    :ok
  rescue
    _ -> :ok
  end

  def load(session_id) when is_binary(session_id) do
    path = goal_path(session_id)
    case File.read(path) do
      {:ok, body} -> Jason.decode(body)
      e -> e
    end
  end

  def clear_persist(session_id) when is_binary(session_id) do
    File.rm(goal_path(session_id))
    :ok
  end
  def clear_persist(_), do: :ok

  defp goal_path(session_id) do
    root = System.get_env("NEWBEE_GOALS_DIR") || Path.join(System.user_home!(), ".newbee/goals")
    Path.join(root, session_id <> ".json")
  end

  defp normalize_budget(nil), do: nil
  defp normalize_budget(n) when is_binary(n) do
    case Integer.parse(String.trim(n)) do
      {i, ""} when i > 0 -> i
      _ -> nil
    end
  end
  defp normalize_budget(n) when is_integer(n) and n > 0, do: n
  defp normalize_budget(_), do: nil

  defp random_id do
    :crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)
  end
end
