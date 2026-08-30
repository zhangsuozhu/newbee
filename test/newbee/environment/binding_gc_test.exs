defmodule Newbee.Environment.BindingGCTest do
  use Newbee.EnvironmentCase, async: false

  alias Newbee.ArtifactRef
  alias Newbee.Environment.{BindingCodec, BindingGC}

  @tag timeout: 2_000
  test "pathological shared graphs cannot block the evaluator" do
    shared = Enum.reduce(1..60, :leaf, fn _, acc -> {acc, acc} end)
    binding = [shared: shared]

    started = System.monotonic_time(:millisecond)
    assert {^binding, []} = BindingGC.maybe_gc(binding, 1, resident_budget: 1_024)
    assert System.monotonic_time(:millisecond) - started < 500

    assert [%{name: :shared, state: :resident, bytes: bytes}] = BindingGC.inventory(binding)
    assert bytes > BindingGC.default_resident_budget()
  end

  @tag timeout: 2_000
  test "binding codec rejects pathological shared graphs within its work budget" do
    shared = Enum.reduce(1..60, :leaf, fn _, acc -> {acc, acc} end)
    started = System.monotonic_time(:millisecond)

    assert {:error, {:over_budget, :shared, _}} = BindingCodec.encode(shared: shared)
    assert System.monotonic_time(:millisecond) - started < 500
  end

  test "ordinary serializable values still evict when over budget" do
    value = :binary.copy("x", 8_192)
    assert {binding, [:large]} = BindingGC.maybe_gc([large: value], 1, resident_budget: 1_024)
    assert %ArtifactRef{} = binding[:large]
    assert File.exists?(binding[:large].path)
  end

  test "values above the measurement cap are kept resident" do
    value = :binary.copy("x", 1_100_000)
    binding = [huge: value]

    assert {^binding, []} = BindingGC.maybe_gc(binding, 1, resident_budget: 1_024)
  end

  test "pathological values do not block ordinary candidates from eviction" do
    shared = Enum.reduce(1..60, :leaf, fn _, acc -> {acc, acc} end)
    value = :binary.copy("x", 8_192)

    assert {binding, [:large]} =
             BindingGC.maybe_gc([shared: shared, large: value], 1, resident_budget: 1_024)

    assert binding[:shared] == shared
    assert %ArtifactRef{} = binding[:large]
  end

  test "small bindings stay resident" do
    binding = [answer: 42, text: "small"]
    assert {^binding, []} = BindingGC.maybe_gc(binding, 1, resident_budget: 1_024)
  end
end
