defmodule Newbee.Agent.LoopCompactTest do
  @moduledoc """
  Loop × Archive 集成：压缩经档案库走（不再覆写 transcript），恢复 = 视图重建，
  LLM 看到的请求里带段汇总消息（history:// 拉取自证闭环）。
  """
  use ExUnit.Case, async: false
  alias Newbee.Agent.Loop
  alias Newbee.DEE.Evaluator
  alias Newbee.Session

  setup do
    id = "kcomp_#{:erlang.unique_integer([:positive])}"

    on_exit(fn ->
      Session.delete(id)
      Session.set_current(nil)
    end)

    {:ok, ev} = Evaluator.start(mode: :local)

    on_exit(fn ->
      ref = ev
      if Process.alive?(ref), do: GenServer.stop(ref)
    end)

    {:ok, id: id, ev: ev}
  end

  defp tool_msg(code, id) do
    %{
      "role" => "assistant",
      "content" => "",
      "tool_calls" => [
        %{
          "id" => id,
          "type" => "function",
          "function" => %{"name" => "run_elixir", "arguments" => Jason.encode!(%{code: code})}
        }
      ]
    }
  end

  defp done_msg(summary),
    do: %{
      "role" => "assistant",
      "content" => "done",
      "tool_calls" => [
        %{
          "id" => "call_done",
          "type" => "function",
          "function" => %{"name" => "done", "arguments" => Jason.encode!(%{summary: summary})}
        }
      ]
    }

  defp text_msg(text),
    do: fn _m, on_text ->
      on_text.(text)
      {:ok, %{"role" => "assistant", "content" => text}, %{}}
    end

  test "压缩后 transcript 字节不变；恢复的会话即压缩视图", %{id: id, ev: ev} do
    script =
      Enum.map(1..6, fn i -> fn _m, _t -> {:ok, tool_msg("x = #{i}", "c#{i}"), %{}} end end) ++
        [fn _m, _t -> {:ok, done_msg("完成 6 步"), %{}} end]

    {:ok, kernel} = Loop.start_link(client: %{}, evaluator: ev, session_id: id, client_fun: scripted(script))
    assert {:done, "完成 6 步"} = Loop.submit(kernel, "任务 A：连续六步计算")

    transcript = Session.open(id).transcript
    before = File.read!(transcript)
    assert before != ""

    assert {:ok, n} = Loop.compact(kernel)
    assert n > 0
    # §4.6 承诺：压缩改视图不动日志
    assert File.read!(transcript) == before

    GenServer.stop(kernel)

    # 恢复：新一轮请求捕获 LLM 实际看到的消息（parent = 测试进程；client_fun 在 Loop 进程里跑）
    parent = self()

    {:ok, k2} =
      Loop.start_link(
        client: %{},
        evaluator: ev,
        session_id: id,
        client_fun:
          scripted([
            fn messages, _t ->
              send(parent, {:seen, messages})
              {:ok, %{"role" => "assistant", "content" => "ok"}, %{}}
            end
          ])
      )

    assert {:text, "ok"} = Loop.submit(k2, "继续任务 A")

    seen =
      receive do
        {:seen, m} -> m
      after
        5_000 -> flunk("no capture")
      end

    assert is_list(seen) and length(seen) > 1
    summary = Enum.find(seen, &(&1["role"] == "system" and String.contains?(&1["content"] || "", "已压缩的早期对话")))
    assert summary
    # 意图脊柱：最初的用户请求逐字可见
    assert summary["content"] =~ "任务 A：连续六步计算"
    # 检索通道自证：history:// 能拉回被压缩的原文
    assert {:ok, idx} = Newbee.read("history://")
    assert idx =~ "1 段"
  end

  test "auto compact（token 压力）同样走档案且不炸", %{id: id, ev: ev} do
    big = String.duplicate("数据", 400)

    script =
      Enum.map(1..4, fn i -> fn _m, _t -> {:ok, tool_msg(~s(y = "#{big}#{i}"), "a#{i}"), %{}} end end) ++
        [fn _m, _t -> {:ok, done_msg("done"), %{}} end]

    {:ok, kernel} =
      Loop.start_link(
        client: %{},
        evaluator: ev,
        session_id: id,
        client_fun: scripted(script),
        context_window: 12_000,
        compaction_threshold: 0.2,
        compaction_retain: 0.4
      )

    transcript = Session.open(id).transcript
    assert {:done, "done"} = Loop.submit(kernel, "压力任务 #{big}")

    assert Newbee.Archive.archived?(Session.open(id))
    # transcript 只增不删：所有 4 条工具调用原文仍在
    assert transcript |> File.read!() |> String.contains?("a4")
    GenServer.stop(kernel)
  end

  test "hard limit overflow refuses provider call", %{id: id, ev: ev} do
    big = String.duplicate("X", 8000)

    {:ok, kernel} =
      Loop.start_link(
        client: %{},
        evaluator: ev,
        session_id: id,
        client_fun: fn _m, _t -> flunk("must not call provider") end,
        context_window: 2000,
        compaction_threshold: 0.2,
        compaction_retain: 0.4
      )

    assert {:error, {:context_overflow, details}} = Loop.submit(kernel, big)
    assert details.status_after == :hard_limit
    GenServer.stop(kernel)
  end

  test "session:false（ephemeral）走旧内存路径不落盘", %{ev: ev} do
    script = [fn _m, _t -> {:ok, done_msg("ok"), %{}} end]

    {:ok, kernel} = Loop.start_link(client: %{}, evaluator: ev, session: false, client_fun: scripted(script))
    assert {:done, "ok"} = Loop.submit(kernel, "临时任务")
    assert {:ok, 0} = Loop.compact(kernel)
    GenServer.stop(kernel)
  end

  defp scripted(script) do
    {:ok, agent} = Agent.start_link(fn -> script end)

    fn messages, on_text ->
      fun =
        Agent.get_and_update(agent, fn
          [f | rest] -> {f, rest}
          [] -> {nil, []}
        end)

      if fun, do: fun.(messages, on_text), else: {:error, :script_exhausted}
    end
  end

  test "档案召回：用户输入命中已压缩档案 → 注入指针提示（不推载荷）", %{id: id, ev: ev} do
    script =
      Enum.map(1..6, fn i -> fn _m, _t -> {:ok, tool_msg("x = #{i}", "c#{i}"), %{}} end end) ++
        [fn _m, _t -> {:ok, done_msg("完成"), %{}} end]

    {:ok, kernel} = Loop.start_link(client: %{}, evaluator: ev, session_id: id, client_fun: scripted(script))
    assert {:done, "完成"} = Loop.submit(kernel, "处理 parser utf8 崩溃任务：连续六步")
    assert {:ok, n} = Loop.compact(kernel)
    assert n > 0
    GenServer.stop(kernel)

    # 恢复后再次提交相关请求：LLM 应看到 [档案召回] 指针提示
    parent = self()

    {:ok, k2} =
      Loop.start_link(
        client: %{},
        evaluator: ev,
        session_id: id,
        client_fun:
          scripted([
            fn messages, _t ->
              send(parent, {:seen2, messages})
              {:ok, %{"role" => "assistant", "content" => "ok"}, %{}}
            end
          ])
      )

    assert {:text, "ok"} = Loop.submit(k2, "继续处理 parser utf8 崩溃问题")

    seen =
      receive do
        {:seen2, m} -> m
      after
        5_000 -> flunk("no capture")
      end

    recall = Enum.find(seen, &(&1["role"] == "system" and String.contains?(&1["content"] || "", "[档案召回]")))
    assert recall
    assert recall["content"] =~ "history://"
    GenServer.stop(k2)
  end

  test "archive failure keeps session for retry (no silent persistence loss)", %{id: id, ev: ev} do
    s = Session.open(id)
    Enum.each(1..6, fn i -> Session.append(s, %{"role" => "user", "content" => "PRE_" <> to_string(i)}) end)
    File.write!(Path.join(s.dir, "archive"), "block")

    {:ok, kernel} =
      Loop.start_link(
        client: %{},
        evaluator: ev,
        session_id: id,
        context_window: 20000,
        compaction_threshold: 0.2,
        client_fun: scripted([fn _m, _t -> {:ok, %{"role" => "assistant", "content" => "reply"}, %{}} end])
      )

    assert {:text, "reply"} = Loop.submit(kernel, String.duplicate("N", 2000))
    state = :sys.get_state(kernel)
    refute is_nil(state.session)
    assert state.session.id == id
    GenServer.stop(kernel)
  end

  test "history scope prefers capability over global current", %{id: _id} do
    sid_a = "hist_a_" <> to_string(:erlang.unique_integer([:positive]))
    sid_b = "hist_b_" <> to_string(:erlang.unique_integer([:positive]))
    sa = Session.open(sid_a)
    sb = Session.open(sid_b)
    Enum.each(1..4, fn i -> Session.append(sa, %{"role" => "user", "content" => "A_MARKER_" <> to_string(i)}) end)
    Enum.each(1..4, fn i -> Session.append(sb, %{"role" => "user", "content" => "B_MARKER_" <> to_string(i)}) end)
    {:ok, _} = Newbee.Archive.compact(sa, retain: 1)
    {:ok, _} = Newbee.Archive.compact(sb, retain: 1)
    Session.set_current(sid_b)
    :ok = Newbee.Collaboration.Capability.register(self(), sid_a, File.cwd!())
    {:ok, token} = Newbee.Collaboration.Capability.issue(self())
    Process.put({Newbee.Tools.Collaboration, :context}, %{capability: token})

    try do
      assert {:ok, idx} = Newbee.read("history://")
      assert idx =~ sid_a
      refute idx =~ sid_b
    after
      Process.delete({Newbee.Tools.Collaboration, :context})
      Session.set_current(nil)
      Session.delete(sid_a)
      Session.delete(sid_b)
    end
  end
end
