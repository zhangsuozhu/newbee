defmodule Newbee.Compaction.Breaker do
  @moduledoc """
  纯会话级失败计数与冷却。无 ETS、进程、持久化或网络。
  """

  def new, do: %{failures: 0, retry_at_ms: nil}

  def allow?(%{retry_at_ms: nil}, _now_ms), do: true
  def allow?(%{retry_at_ms: retry_at}, now_ms) when is_integer(retry_at), do: now_ms >= retry_at
  def allow?(_, _), do: true

  def success(_breaker), do: new()

  def skip(breaker), do: breaker

  def failure(breaker, reason, now_ms, config) when is_map(breaker) and is_map(config) do
    if immediate_cooldown?(reason) do
      %{failures: config.failure_threshold, retry_at_ms: now_ms + config.cooldown_ms}
    else
      failures = breaker.failures + 1

      if failures >= config.failure_threshold do
        %{failures: failures, retry_at_ms: now_ms + config.cooldown_ms}
      else
        %{failures: failures, retry_at_ms: nil}
      end
    end
  end

  def service_failure?(reason) do
    reason in [:timeout, :missing_key, :malformed_response, :network_error, :interrupted] or
      match?({:http_status, _}, reason) or
      match?({:auth_error, _}, reason) or
      match?({:rate_limited, _}, reason) or
      match?({:server_error, _}, reason)
  end

  defp immediate_cooldown?(:missing_key), do: true
  defp immediate_cooldown?({:auth_error, _}), do: true
  defp immediate_cooldown?({:http_status, status}) when status in [401, 403], do: true
  defp immediate_cooldown?(_), do: false
end
