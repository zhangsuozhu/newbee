defmodule Newbee.Colony.HoneyTest do
  use ExUnit.Case, async: true

  alias Newbee.Colony.{Honey, Signal}

  test "成果默认待验收；自动预检全过 → auto_verified" do
    h = Honey.new(%{"colony_id" => "col_l_a", "title" => "登录模块", "bee_id" => "bee_l_a"})
    assert get_in(h, ["review", "state"]) == "pending_review"

    h2 = Honey.auto_verify(h, [%{"check" => "test_pass", "ok" => true}])
    assert get_in(h2, ["review", "state"]) == "auto_verified"

    h3 = Honey.auto_verify(h, [%{"check" => "test_pass", "ok" => false}])
    assert get_in(h3, ["review", "state"]) == "pending_review"
    assert [%{"ok" => false}] = get_in(h3, ["review", "auto_checks"])
  end

  test "Queen 验收 accept / reject，且不可重复验收" do
    h = Honey.new(%{"colony_id" => "col_l_a", "title" => "x"})

    {:ok, accepted} = Honey.review(h, "accept", "bee_l_queen", "可以")
    assert get_in(accepted, ["review", "state"]) == "accepted"
    assert get_in(accepted, ["review", "verdict", "note"]) == "可以"

    assert {:error, :already_reviewed} = Honey.review(accepted, "reject", "bee_l_queen")
    assert {:error, :invalid_verdict} = Honey.review(h, "maybe", "bee_l_queen")
  end

  test "public 附带 preview 与状态" do
    h =
      Honey.new(%{
        "colony_id" => "col_l_a",
        "title" => "x",
        "content" => String.duplicate("a", 500)
      })

    pub = Honey.public(h)
    assert pub["review_state"] == "pending_review"
    assert String.length(pub["preview"]) <= 240
  end

  test "recommend 信号必须带质量评分" do
    assert {:error, :quality_required} =
             Signal.new(%{
               "colony_id" => "col_l_a",
               "kind" => "recommend",
               "from_bee_id" => "bee_l_a"
             })

    assert {:ok, s} =
             Signal.new(%{
               "colony_id" => "col_l_a",
               "kind" => "recommend",
               "from_bee_id" => "bee_l_a",
               "quality" => 0.8
             })

    assert s["quality"] == 0.8
  end

  test "inhibit 必须指向竞争方案且有冷却" do
    assert {:error, :target_required} =
             Signal.new(%{
               "colony_id" => "col_l_a",
               "kind" => "inhibit",
               "from_bee_id" => "bee_l_a"
             })

    {:ok, s} =
      Signal.new(%{
        "colony_id" => "col_l_a",
        "kind" => "inhibit",
        "from_bee_id" => "bee_l_a",
        "target_proposal_id" => "proposal_1",
        "created_at" => 1_000
      })

    assert Signal.allowed?(s, [])

    recent = [Map.put(s, "created_at", 2_000)]
    refute Signal.allowed?(Map.put(s, "created_at", 3_000), recent)

    old = Map.put(s, "created_at", 10 * 60 * 1000 + 2_000)
    assert Signal.allowed?(old, recent)
  end

  test "describe 生成可读摘要" do
    {:ok, s} =
      Signal.new(%{
        "colony_id" => "col_l_a",
        "kind" => "report",
        "from_bee_id" => "bee_l_a",
        "payload" => %{"text" => "登录模块完成"}
      })

    assert Signal.describe(s) =~ "登录模块完成"
    assert Signal.public_view(s)["text"] =~ "汇报"
  end
end
