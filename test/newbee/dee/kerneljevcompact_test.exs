defmodule Newbee.Agent.LoopJevCompactTest do
  use ExUnit.Case, async: false
  alias Newbee.Agent.Loop
  alias Newbee.Compaction.Config
  alias Newbee.DEE.Evaluator
  alias Newbee.Session

  setup do
    id = "kjev_" <> Integer.to_string(:erlang.unique_integer([:positive]))

    on_exit(fn ->
      Session.delete(id)
      Session.set_current(nil)
    end)

    {:ok, ev} = Evaluator.start(mode: :local)
    on_exit(fn -> if Process.alive?(ev), do: GenServer.stop(ev) end)

    {:ok, config} =
      Config.resolve(%{"mode" => "jev", "jev" => %{"preserveRecentMessages" => 2, "minReductionRatio" => 0.0}})

    {:ok, id: id, ev: ev, config: config}
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

  defp bulky_eval(i) do
    %{
      "code" => "IO.puts(" <> Integer.to_string(i) <> ")",
      "output" => String.duplicate("BULK" <> Integer.to_string(i) <> "-", 400)
    }
  end

  test "default config never calls Jev", %{id: id, ev: ev} do
    parent = self()

    scorer = fn _state, _batches, _config, _opts ->
      send(parent, :jev_called)
      {:error, :should_not_run, %{requests: 1}}
    end

    {:ok, kernel} =
      Loop.start_link(
        client: %{},
        evaluator: ev,
        session_id: id,
        compaction_deps: %{scorer: scorer},
        client_fun: scripted([fn _m, _t -> {:ok, %{"role" => "assistant", "content" => "ok"}, %{}} end])
      )

    assert {:text, "ok"} = Loop.submit(kernel, "hello")
    refute_received :jev_called
    GenServer.stop(kernel)
  end

  test "Jev success skips archive summary", %{id: id, ev: ev, config: config} do
    parent = self()

    scorer = fn state, batches, _config, _opts ->
      send(parent, {:jev, map_size(state), length(batches)})

      answers =
        batches
        |> List.flatten()
        |> Map.new(fn call ->
          {"call_" <> call.id, 0.9}
        end)
        |> Map.merge(
          batches
          |> List.flatten()
          |> Map.new(fn call -> {"result_" <> call.id, 0.1} end)
        )

      {:ok, answers, %{requests: 1, elapsed_ms: 1}}
    end

    s = Session.open(id)

    Enum.each(1..6, fn i ->
      bulk = bulky_eval(i)
      Session.append(s, %{"role" => "user", "content" => "step " <> Integer.to_string(i)})
      Session.append(s, tool_msg(bulk["code"], "c" <> Integer.to_string(i)))
      Session.append(s, %{"role" => "tool", "tool_call_id" => "c" <> Integer.to_string(i), "content" => bulk["output"]})
    end)

    before = File.read!(s.transcript)

    {:ok, kernel} =
      Loop.start_link(
        client: %{},
        evaluator: ev,
        session_id: id,
        compaction_config: config,
        compaction_deps: %{scorer: scorer},
        context_window: 8_000,
        compaction_threshold: 0.2,
        client_fun:
          scripted([
            fn messages, _t ->
              send(parent, {:seen, messages})
              {:ok, %{"role" => "assistant", "content" => "done-view"}, %{}}
            end
          ])
      )

    assert {:text, "done-view"} = Loop.submit(kernel, String.duplicate("N", 1200))
    assert byte_size(File.read!(s.transcript)) >= byte_size(before)
    assert_receive {:jev, _, _}, 2_000

    seen =
      receive do
        {:seen, messages} -> messages
      after
        2_000 -> flunk("no model request")
      end

    refute Enum.any?(seen, fn m -> is_binary(m["content"]) and String.contains?(m["content"] || "", "较早对话的压缩摘要") end)
    GenServer.stop(kernel)
  end

  test "manual compact does not call Jev", %{id: id, ev: ev, config: config} do
    parent = self()

    scorer = fn _, _, _, _ ->
      send(parent, :jev)
      {:error, :should_not_run, %{}}
    end

    s = Session.open(id)
    Enum.each(1..6, fn i -> Session.append(s, %{"role" => "user", "content" => "PRE" <> Integer.to_string(i)}) end)

    {:ok, kernel} =
      Loop.start_link(
        client: %{},
        evaluator: ev,
        session_id: id,
        compaction_config: config,
        compaction_deps: %{scorer: scorer},
        client_fun: scripted([fn _, _ -> {:ok, %{"role" => "assistant", "content" => "x"}, %{}} end])
      )

    assert {:ok, n} = Loop.compact(kernel)
    assert n >= 0
    refute_received :jev
    GenServer.stop(kernel)
  end

  test "missing key falls back to archive without dropping session", %{id: id, ev: ev, config: config} do
    parent = self()

    scorer = fn _, _, _, _ ->
      send(parent, :jev)
      {:error, :missing_key, %{requests: 0, reason: :missing_key}}
    end

    s = Session.open(id)

    Enum.each(1..6, fn i ->
      bulk = bulky_eval(i)
      Session.append(s, %{"role" => "user", "content" => "PRE_" <> Integer.to_string(i)})
      Session.append(s, tool_msg(bulk["code"], "c" <> Integer.to_string(i)))
      Session.append(s, %{"role" => "tool", "tool_call_id" => "c" <> Integer.to_string(i), "content" => bulk["output"]})
    end)

    {:ok, kernel} =
      Loop.start_link(
        client: %{},
        evaluator: ev,
        session_id: id,
        compaction_config: config,
        compaction_deps: %{scorer: scorer},
        context_window: 8_000,
        compaction_threshold: 0.2,
        client_fun: scripted([fn _, _ -> {:ok, %{"role" => "assistant", "content" => "reply"}, %{}} end])
      )

    assert {:text, "reply"} = Loop.submit(kernel, String.duplicate("N", 2000))
    state = :sys.get_state(kernel)
    refute is_nil(state.session)
    assert state.session.id == id
    assert_receive :jev, 2_000
    GenServer.stop(kernel)
  end
end
