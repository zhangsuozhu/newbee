defmodule Newbee.Environment.HumanBriefCoordinatorTest do
  use Newbee.EnvironmentCase, async: false

  alias Newbee.Environment.Coordinator

  setup do
    coordinator = start_coordinator!()
    {:ok, coordinator: coordinator}
  end

  test "propose 即带模板人话卡，不复读裸ID", %{coordinator: coordinator} do
    {:ok, change} =
      Coordinator.propose_change(coordinator, %{
        reason: "adapter: distill-stream-chat-hotpath",
        evidence: [%{proposal: "distill-stream-chat-hotpath", type: "tool"}],
        author_agent: :adapter
      })

    assert is_map(change.human_brief)
    assert change.human_brief["fallback"] == true
    refute change.human_brief["title"] =~ "distill"

    # 落盘可恢复
    [stored] = Enum.filter(Coordinator.changes(coordinator), &(&1.change_id == change.change_id))
    assert is_map(stored.human_brief)
  end

  test "update_brief 覆盖并广播", %{coordinator: coordinator} do
    {:ok, change} =
      Coordinator.propose_change(coordinator, %{reason: "r", author_agent: :adapter})

    fresh =
      Newbee.Environment.HumanBrief.template_brief(%{kind: :rule})
      |> Map.put("fallback", false)

    assert :ok = Coordinator.update_brief(coordinator, change.change_id, fresh)
    [stored] = Enum.filter(Coordinator.changes(coordinator), &(&1.change_id == change.change_id))
    assert stored.human_brief["fallback"] == false
    assert {:error, :change_not_found} = Coordinator.update_brief(coordinator, "chg_missing", fresh)
  end

  test "异步回退不覆盖富模板，LLM成功才覆盖", %{coordinator: coordinator} do
    {:ok, change} =
      Coordinator.propose_change(coordinator, %{
        reason: "adapter: some-hot-path",
        evidence: [%{proposal: "some-hot-path", type: "rule"}],
        author_agent: :adapter
      })

    rich =
      Newbee.Environment.HumanBrief.template_brief(%{
        kind: :rule,
        usage: "命中失败时提醒检查凭证",
        ring: 2
      })

    assert :ok = Coordinator.update_brief(coordinator, change.change_id, rich)

    thin = Newbee.Environment.HumanBrief.template_brief(%{kind: nil})
    GenServer.cast(coordinator, {:brief_ready, change.change_id, thin})
    Process.sleep(100)
    [kept] = Enum.filter(Coordinator.changes(coordinator), &(&1.change_id == change.change_id))
    assert kept.human_brief["change_to"] =~ "检查凭证"

    llm = Map.merge(rich, %{"fallback" => false, "title" => "记住检查凭证这条提醒"})
    GenServer.cast(coordinator, {:brief_ready, change.change_id, llm})
    Process.sleep(100)
    [upgraded] = Enum.filter(Coordinator.changes(coordinator), &(&1.change_id == change.change_id))
    assert upgraded.human_brief["title"] == "记住检查凭证这条提醒"
  end

end
