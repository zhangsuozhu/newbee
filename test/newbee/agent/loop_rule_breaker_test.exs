defmodule Newbee.Agent.LoopRuleBreakerTest do
  use ExUnit.Case, async: false
  import Newbee.TestScripted
  alias Newbee.Agent.Loop
  alias Newbee.DEE.Evaluator

  defp violating_msg(text) do
    %{"role" => "assistant", "content" => text, "tool_calls" => []}
  end

  test "persistent content-rule violator is released after max retries" do
    Newbee.DEE.Rules.add("breaker-repro", "BREAKER_TRIGGER", "fix it", scope: :content)
    on_exit(fn -> Newbee.DEE.Rules.remove("breaker-repro") end)
    {:ok, counter} = Agent.start_link(fn -> 0 end)
    bump = fn -> Agent.update(counter, &(&1 + 1)) end
    {:ok, ev} = Evaluator.start(mode: :local)

    script =
      for _i <- 1..5 do
        fn _m, _o ->
          bump.()
          {:ok, violating_msg("violation BREAKER_TRIGGER"), %{}}
        end
      end

    {:ok, kernel} = Loop.start_link(client: %{}, evaluator: ev, session: false, client_fun: scripted(script))
    assert {:text, text} = Loop.submit(kernel, "go")
    assert text =~ "BREAKER_TRIGGER"
    count = Agent.get(counter, & &1)
    assert count == 3
    GenServer.stop(kernel)
    GenServer.stop(ev)
    Agent.stop(counter)
  end

  test "single hit still retries and recovers" do
    Newbee.DEE.Rules.add("breaker-once", "ONCE_TRIGGER", "fix it", scope: :content)
    on_exit(fn -> Newbee.DEE.Rules.remove("breaker-once") end)
    {:ok, ev} = Evaluator.start(mode: :local)

    {:ok, kernel} =
      Loop.start_link(
        client: %{},
        evaluator: ev,
        session: false,
        client_fun:
          scripted([
            fn _m, _o -> {:ok, violating_msg("bad ONCE_TRIGGER"), %{}} end,
            fn _m, _o -> {:ok, violating_msg("clean now"), %{}} end
          ])
      )

    assert {:text, "clean now"} = Loop.submit(kernel, "go")
    GenServer.stop(kernel)
    GenServer.stop(ev)
  end
end
