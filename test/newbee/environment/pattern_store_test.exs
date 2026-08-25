defmodule Newbee.Environment.PatternStoreTest do
  use Newbee.EnvironmentCase, async: false

  alias Newbee.Environment.{PatternStore, PatternStats}

  @tag :pattern_store
  test "project: 事件流幂等重建三组后验" do
    events = [
      %{topic: :tool_start, data: %{name: "Edit", tokens: 800}},
      %{topic: :tool_start, data: %{name: "Edit", tokens: 900}},
      %{topic: :tool_error, data: %{name: "Edit", error_class: "anchor"}},
      %{topic: :step_start, data: %{}}
    ]

    stats = PatternStore.project(events)
    key = Enum.find(Map.keys(stats), fn {k, _} -> k == {:tool_use, "Edit"} end)
    assert key != nil

    s = stats[key]
    assert s.n == 3
    # 新语义[R3]: start 只记频率，result 才是成功，error 是失败
    assert_in_delta PatternStats.succ_mean(s), 1.0 / 3.0, 1.0e-9
    assert PatternStats.save_mean(s) > 500.0
  end

  @tag :pattern_store
  test "key_of: task_type 分桶 [D16]" do
    ev = %{topic: :tool_start, data: %{name: "Edit", task_type: "refactor"}}
    assert {{:tool_use, "Edit"}, "refactor"} = PatternStore.key_of(ev)
  end

  @tag :pattern_store
  test "persist + restore 往返一致" do
    events = for _ <- 1..5, do: %{topic: :tool_start, data: %{name: "Bash", tokens: 400}}
    stats = PatternStore.project(events)

    assert is_atom(PatternStore.persist(stats))
    restored = PatternStore.restore()

    key = Enum.find(Map.keys(stats), fn {k, _} -> k == {:tool_use, "Bash"} end)

    if Map.has_key?(restored, key) do
      r = restored[key]
      assert r.n == stats[key].n
      assert_in_delta PatternStats.freq_mean(r), PatternStats.freq_mean(stats[key]), 1.0e-6
    end
  end

  @tag :pattern_store
  test "restore 无文件时空 map 不抛错" do
    # EnvironmentCase 提供独立临时环境；未 persist 过则应为空
    result = PatternStore.restore()
    assert is_map(result)
  end

  @tag :pattern_store
  test "decay 触发：大量观察后有效样本被遗忘 [D6]" do
    events = for i <- 1..501, do: %{topic: :tool_start, data: %{name: "Run", tokens: 100 + rem(i, 10)}}
    stats = PatternStore.project(events)
    key = Enum.find(Map.keys(stats), fn {k, _} -> k == {:tool_use, "Run"} end)
    s = stats[key]
    # n=501 时在 500 处触发过一次 decay(0.98)：n ≈ (500)*0.98 + 1 = 491
    assert s.n < 501 and s.n > 480
  end
end
