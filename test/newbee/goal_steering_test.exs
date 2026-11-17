defmodule Newbee.GoalTest do
  # NEWBEE_GOALS_DIR / NEWBEE_JSPACE_DIR 是进程级环境变量，不能和其它用例并行改。
  use ExUnit.Case, async: false

  setup do
    root = Path.join(System.tmp_dir!(), "newbee-goals-#{System.unique_integer([:positive])}")
    jspace = Path.join(System.tmp_dir!(), "newbee-jspace-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    File.mkdir_p!(jspace)

    prev_goals = System.get_env("NEWBEE_GOALS_DIR")
    prev_jspace = System.get_env("NEWBEE_JSPACE_DIR")
    prev_stale = System.get_env("NEWBEE_GOAL_STALE_MS")
    System.put_env("NEWBEE_GOALS_DIR", root)
    System.put_env("NEWBEE_JSPACE_DIR", jspace)

    on_exit(fn ->
      restore("NEWBEE_GOALS_DIR", prev_goals)
      restore("NEWBEE_JSPACE_DIR", prev_jspace)
      restore("NEWBEE_GOAL_STALE_MS", prev_stale)
      File.rm_rf(root)
      File.rm_rf(jspace)
    end)

    {:ok, goals_dir: root, jspace_dir: jspace}
  end

  defp restore(name, nil), do: System.delete_env(name)
  defp restore(name, value), do: System.put_env(name, value)

  defp sid, do: "test-#{System.unique_integer([:positive])}"

  test "new_state creates rich goal" do
    g = Newbee.Goal.new_state("test objective", token_budget: 1000, max_rounds: 10)
    assert g.text == "test objective"
    assert g.status == :active
    assert g.token_budget == 1000
    assert g.max_rounds == 10
    assert g.id =~ ~r/^goal_/
  end

  test "steering templates generate prompts" do
    g = %{text: "fix bug", token_budget: 500, tokens_used: 100, rounds: 2, max_rounds: 10, session_id: nil}
    cont = Newbee.Goal.Steering.continuation(g)
    assert cont =~ "fix bug"
    assert cont =~ "Tokens used"
    budget = Newbee.Goal.Steering.budget_limit(g)
    assert budget =~ "Budget Limited"
    refl = Newbee.Goal.Steering.reflection(g, "重复调用")
    assert refl =~ "Reflection"
    assert Newbee.Goal.Steering.verification_gate_message() =~ "Verification Gate"
  end

  test "goal persist and load" do
    id = sid()
    g = Newbee.Goal.new_state("persist test", session_id: id)
    :ok = Newbee.Goal.persist(g)
    {:ok, loaded} = Newbee.Goal.load(id)
    assert loaded["text"] == "persist test"
    :ok = Newbee.Goal.clear_persist(id)
    assert {:error, _} = Newbee.Goal.load(id)
  end

  test "落盘位置默认在 GlobalStore 下，测试环境不碰用户 home" do
    prev = System.get_env("NEWBEE_GOALS_DIR")
    System.delete_env("NEWBEE_GOALS_DIR")

    try do
      dir = Newbee.Goal.goals_dir()
      assert dir == Path.join(Newbee.GlobalStore.root(), "goals")
      assert String.starts_with?(Path.expand(dir), Path.expand(System.tmp_dir!()))
      refute String.starts_with?(Path.expand(dir), Path.expand(System.user_home!()))
    after
      if prev, do: System.put_env("NEWBEE_GOALS_DIR", prev)
    end
  end

  test "finish 先落终态快照（含最终 tokens_used）再清理目标文件" do
    id = sid()

    g = %Newbee.Goal.State{
      Newbee.Goal.new_state("finish test", session_id: id)
      | tokens_used: 1234,
        rounds: 3,
        status: :active
    }

    :ok = Newbee.Goal.persist(g)
    assert File.regular?(Newbee.Goal.goal_path(id))

    assert {:ok, persisted} = Newbee.Goal.finish(%{g | tokens_used: 4321})
    assert persisted["tokens_used"] == 4321
    assert persisted["status"] == "complete"
    assert persisted["rounds"] == 3
    refute File.regular?(Newbee.Goal.goal_path(id))
  end

  test "load_active 过滤过期与非 active 快照" do
    id = sid()
    now = 1_700_000_000_000

    g = %Newbee.Goal.State{Newbee.Goal.new_state("active", session_id: id) | updated_at: now}
    :ok = Newbee.Goal.persist(g)

    assert {:ok, snap} = Newbee.Goal.load_active(id, now: now + 1_000, check_session: false)
    assert snap["status"] == "active"

    assert {:error, :stale} = Newbee.Goal.load_active(id, now: now + 10 * 24 * 60 * 60 * 1000, check_session: false)

    done = %{g | status: :complete, updated_at: now}
    :ok = Newbee.Goal.persist(done)
    assert {:error, :not_active} = Newbee.Goal.load_active(id, now: now + 1_000, check_session: false)
  end

  test "load_active 默认要求会话仍然存在" do
    id = sid()
    g = Newbee.Goal.new_state("session bound", session_id: id)
    :ok = Newbee.Goal.persist(g)

    # Session.exists? 以 transcript 为准；不存在即视为残留。
    assert {:error, :session_missing} = Newbee.Goal.load_active(id)

    session = Newbee.Session.open(id)
    :ok = Newbee.Session.mark_created(id)
    assert {:ok, _} = Newbee.Goal.load_active(id)
    assert File.regular?(session.transcript)
  end

  test "updated_at 过期阈值可用 NEWBEE_GOAL_STALE_MS 覆盖" do
    assert Newbee.Goal.stale_after_ms() == 24 * 60 * 60 * 1000
    System.put_env("NEWBEE_GOAL_STALE_MS", "1500")
    assert Newbee.Goal.stale_after_ms() == 1500
    assert Newbee.Goal.stale?(%{"updated_at" => 1_000}, 3_000)
    refute Newbee.Goal.stale?(%{"updated_at" => 1_000}, 2_000)
  end

  test "prune_stale 清掉过期/坏文件，保留新鲜 active" do
    fresh = sid()
    stale = sid()
    broken = sid()
    now = 1_700_000_000_000

    :ok = Newbee.Goal.persist(%Newbee.Goal.State{Newbee.Goal.new_state("fresh", session_id: fresh) | updated_at: now})

    :ok =
      Newbee.Goal.persist(%Newbee.Goal.State{
        Newbee.Goal.new_state("stale", session_id: stale)
        | updated_at: now - 48 * 60 * 60 * 1000
      })

    File.write!(Newbee.Goal.goal_path(broken), "{not json")

    assert {:ok, removed} = Newbee.Goal.prune_stale(now: now)
    assert Enum.sort(removed) == Enum.sort([stale, broken])
    assert File.regular?(Newbee.Goal.goal_path(fresh))
  end

  test "discard_stale 只在过期/非 active 时删除该会话快照" do
    id = sid()
    now = 1_700_000_000_000
    g = %Newbee.Goal.State{Newbee.Goal.new_state("keep", session_id: id) | updated_at: now}
    :ok = Newbee.Goal.persist(g)

    assert :kept = Newbee.Goal.discard_stale(id, now: now + 1_000)
    assert File.regular?(Newbee.Goal.goal_path(id))

    assert :ok = Newbee.Goal.discard_stale(id, now: now + 10 * 24 * 60 * 60 * 1000)
    refute File.regular?(Newbee.Goal.goal_path(id))
  end

  test "loop budget parsing" do
    # via Commands parse helpers (indirectly test Loop's parse)
    assert Newbee.Goal.new_state("x", token_budget: "1000").token_budget == 1000
    assert Newbee.Goal.new_state("x", token_budget: "bad").token_budget == nil
  end
end
