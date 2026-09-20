defmodule Newbee.Compaction.BreakerTest do
  use ExUnit.Case, async: true
  alias Newbee.Compaction.{Breaker, Config}

  setup do
    {:ok, config} = Config.resolve(%{"mode" => "jev", "jev" => %{"failureThreshold" => 3, "cooldownMs" => 1_000}})
    %{config: config}
  end

  test "first failure falls back immediately but does not cool down", %{config: config} do
    b = Breaker.failure(Breaker.new(), :timeout, 10, config)
    assert b.failures == 1
    assert Breaker.allow?(b, 10)
  end

  test "third failure opens cooldown", %{config: config} do
    b =
      Breaker.new()
      |> Breaker.failure(:timeout, 10, config)
      |> Breaker.failure(:timeout, 11, config)
      |> Breaker.failure(:timeout, 12, config)

    refute Breaker.allow?(b, 12)
    refute Breaker.allow?(b, 1011)
    assert Breaker.allow?(b, 1012)
  end

  test "success clears failures", %{config: config} do
    b = Breaker.failure(Breaker.new(), :timeout, 10, config)
    assert Breaker.success(b) == Breaker.new()
  end

  test "auth errors cool down immediately", %{config: config} do
    b = Breaker.failure(Breaker.new(), {:auth_error, 401}, 10, config)
    refute Breaker.allow?(b, 10)
    assert Breaker.allow?(b, 1010)
  end

  test "local skip does not count as service failure", %{config: config} do
    b = Breaker.skip(Breaker.failure(Breaker.new(), :timeout, 10, config))
    assert b.failures == 1
    refute Breaker.service_failure?(:insufficient_reduction)
    refute Breaker.service_failure?(:no_candidates)
  end
end
