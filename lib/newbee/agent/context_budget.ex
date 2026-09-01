defmodule Newbee.Agent.ContextBudget do
  @moduledoc """
  Context-window budget accounting used at every model-request boundary.

  The estimate intentionally separates serialized input, fixed protocol overhead, and
  output reservation. This keeps the soft trigger from being confused with the provider's
  hard input limit.
  """

  @default_soft_ratio 0.80
  @default_hard_ratio 0.95
  @default_overhead 2_000

  @doc "Returns a structured budget assessment for a model request."
  def assess(messages, opts) when is_list(messages) do
    context_window = positive(Keyword.get(opts, :context_window), 256_000)
    soft_ratio = ratio(Keyword.get(opts, :soft_ratio, @default_soft_ratio), @default_soft_ratio)
    hard_ratio = ratio(Keyword.get(opts, :hard_ratio, @default_hard_ratio), @default_hard_ratio)
    hard_ratio = max(hard_ratio, soft_ratio)
    overhead = non_negative(Keyword.get(opts, :overhead, @default_overhead), @default_overhead)
    output_reserve = non_negative(Keyword.get(opts, :output_reserve, 0), 0)
    input_tokens = estimate(messages) + overhead
    request_tokens = input_tokens + output_reserve
    soft_limit = max(trunc(context_window * soft_ratio), 1)
    hard_limit = max(trunc(context_window * hard_ratio), soft_limit)

    status =
      cond do
        request_tokens >= hard_limit -> :hard_limit
        request_tokens >= soft_limit -> :soft_limit
        true -> :ok
      end

    %{
      status: status,
      context_window: context_window,
      input_tokens: input_tokens,
      output_reserve: output_reserve,
      request_tokens: request_tokens,
      soft_limit: soft_limit,
      hard_limit: hard_limit,
      headroom: max(context_window - request_tokens, 0),
      ratio: request_tokens / context_window
    }
  end

  @doc "Estimates serialized message tokens with the same conservative approximation used by Loop."
  def estimate(messages) when is_list(messages) do
    div(byte_size(Jason.encode!(messages)) + 2, 3) + 2
  rescue
    _ -> Enum.count(messages) * 100
  end

  defp positive(value, _fallback) when is_integer(value) and value > 0, do: value
  defp positive(_value, fallback), do: fallback

  defp non_negative(value, _fallback) when is_integer(value) and value >= 0, do: value
  defp non_negative(value, _fallback) when is_float(value) and value >= 0, do: trunc(value)
  defp non_negative(_value, fallback), do: fallback

  defp ratio(value, fallback) when is_integer(value), do: ratio(value / 1, fallback)
  defp ratio(value, _fallback) when is_float(value) and value > 0 and value <= 1, do: value
  defp ratio(_value, fallback), do: fallback
end
