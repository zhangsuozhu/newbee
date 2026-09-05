defmodule Newbee.DEE.EvalJob do
  @moduledoc false
  @default_timeout 300_000
  @max_timeout 1_800_000
  @terminal_statuses [:succeeded, :failed, :interrupted, :timed_out, :outcome_unknown]
  defstruct [:job_id, :owner, :evaluator, :node, :started_at, :deadline, :timeout, :status, :reason]
  def default_timeout, do: min(positive_config(:eval_default_timeout_ms, @default_timeout), max_timeout())
  def max_timeout, do: min(positive_config(:eval_max_timeout_ms, @max_timeout), @max_timeout)
  def default_reductions_limit, do: positive_config(:eval_reductions_limit, 50_000_000)
  def default_output_limit, do: positive_config(:eval_output_limit, 1_048_576)

  def new(opts \\ []) do
    timeout = normalize_timeout(Keyword.get(opts, :timeout, default_timeout()))
    started_at = System.monotonic_time(:millisecond)

    %__MODULE__{
      job_id: Keyword.get(opts, :job_id, make_ref()),
      owner: Keyword.get(opts, :owner),
      evaluator: Keyword.get(opts, :evaluator),
      node: Keyword.get(opts, :node, node()),
      started_at: started_at,
      deadline: started_at + timeout,
      timeout: timeout,
      status: :running
    }
  end

  def normalize_timeout(:infinity), do: default_timeout()
  def normalize_timeout(value) when is_integer(value) and value >= 0, do: min(value, max_timeout())
  def normalize_timeout(value), do: raise(ArgumentError, inspect({:invalid_eval_timeout, value}))
  def terminal?(%__MODULE__{status: status}), do: status in @terminal_statuses

  def finish(%__MODULE__{status: status}, _new_status, _reason) when status in @terminal_statuses,
    do: {:error, :already_terminal}

  def finish(%__MODULE__{} = job, status, reason) when status in @terminal_statuses,
    do: {%{job | status: status, reason: reason}, :accepted}

  def finish(%__MODULE__{}, status, _reason), do: {:error, {:invalid_status, status}}

  defp positive_config(key, default) do
    case Application.get_env(:newbee, key, default) do
      value when is_integer(value) and value > 0 -> value
      _ -> default
    end
  end
end
