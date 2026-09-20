defmodule Newbee.Compaction.PolicyTest do
  use ExUnit.Case, async: true
  alias Newbee.Compaction.{Config, Policy}

  defp cfg(overrides \\ %{}) do
    {:ok, config} = Config.resolve(Map.merge(%{"mode" => "jev"}, overrides))
    config
  end

  defp call(id, code, result, opts \\ []) do
    assistant = %{
      "role" => "assistant",
      "content" => Keyword.get(opts, :text, ""),
      "tool_calls" => [
        %{
          "id" => id,
          "type" => "function",
          "function" => %{"name" => "run_elixir", "arguments" => Jason.encode!(%{"code" => code, "title" => "t"})}
        }
      ]
    }

    assistant =
      if Keyword.get(opts, :reasoning) do
        Map.put(assistant, "reasoning_content", "secret")
      else
        assistant
      end

    tool = %{"role" => "tool", "tool_call_id" => id, "content" => result}
    {assistant, tool}
  end

  defp transcript(extra) do
    [%{"role" => "system", "content" => "base"} | extra]
  end

  test "pairs multiple calls on one assistant and pins recent/first" do
    {a1, t1} = call("c1", "1", String.duplicate("old-result-", 50))
    {a2, t2} = call("c2", "2", String.duplicate("mid-result-", 50))
    {a3, t3} = call("c3", "3", "recent")

    messages =
      transcript([
        %{"role" => "user", "content" => "do it"},
        a1,
        t1,
        a2,
        t2,
        %{"role" => "user", "content" => "now"},
        a3,
        t3
      ])

    config = %{cfg() | preserve_recent_messages: 2}
    source = %{cut: 0, calls: Policy.index_calls(messages)}
    assert {:ok, calls} = Policy.collect_calls(messages, config, source, nil)
    by_id = Map.new(calls, &{&1.tool_call_id, &1})
    assert by_id["c3"].pinned
    refute by_id["c1"].pinned
  end

  test "pins incomplete, unparseable, error, coupled, and unverified calls" do
    {ok_a, ok_t} = call("ok", "ok()", String.duplicate("ok-output-", 40))

    incomplete_a = %{
      "role" => "assistant",
      "content" => "",
      "tool_calls" => [
        %{"id" => "inc", "type" => "function", "function" => %{"name" => "run_elixir", "arguments" => "{}"}}
      ]
    }

    bad_args = %{
      "role" => "assistant",
      "content" => "",
      "tool_calls" => [
        %{"id" => "bad", "type" => "function", "function" => %{"name" => "run_elixir", "arguments" => "{"}}
      ]
    }

    bad_t = %{"role" => "tool", "tool_call_id" => "bad", "content" => String.duplicate("x", 40)}
    {err_a, err_t} = call("err", "err()", "failed ✗ boom")
    {coup_a, coup_t} = call("coup", "c()", String.duplicate("y", 40), reasoning: true)

    messages =
      transcript([
        %{"role" => "user", "content" => "u"},
        ok_a,
        ok_t,
        incomplete_a,
        bad_args,
        bad_t,
        err_a,
        err_t,
        coup_a,
        coup_t,
        %{"role" => "user", "content" => "tail extra extra extra extra"}
      ])

    source = %{cut: 0, calls: Policy.index_calls(messages)}
    config = %{cfg() | preserve_recent_messages: 1}
    assert {:ok, calls} = Policy.collect_calls(messages, config, source, nil)
    reasons = Map.new(calls, &{&1.tool_call_id, &1.pin_reason})
    assert reasons["inc"] == :incomplete
    assert reasons["bad"] == :unparseable
    assert reasons["err"] == :error
    assert reasons["coup"] == :coupled
    refute reasons["ok"] in [:incomplete, :unparseable, :error, :coupled]
  end

  test "already pruned ids are pinned and not scored twice" do
    {a, t} = call("old", "x", String.duplicate("z", 80))

    messages =
      transcript([
        %{"role" => "user", "content" => "u1"},
        a,
        t,
        %{"role" => "user", "content" => "later later later later"}
      ])

    source = %{cut: 0, calls: Policy.index_calls(messages)}
    projection = %{records: [%{tool_call_id: "old", action: :drop_result}]}
    config = %{cfg() | preserve_recent_messages: 1}
    assert {:ok, [call]} = Policy.collect_calls(messages, config, source, projection)
    assert call.pinned
    assert call.pin_reason == :already_pruned
  end

  test "run_elixir state includes code/title and result tail" do
    result = String.duplicate("head-", 80) <> "UNIQUE_TAIL_ERROR"
    {a, t} = call("r1", "File.read!(\"a\")", result)

    messages =
      transcript([
        %{"role" => "user", "content" => "fix UNIQUE_TAIL_ERROR please"},
        a,
        t,
        %{"role" => "user", "content" => "continue"}
      ])

    source = %{cut: 0, calls: Policy.index_calls(messages)}
    config = %{cfg() | preserve_recent_messages: 1, max_state_tokens: 20_000}
    assert {:ok, calls} = Policy.collect_calls(messages, config, source, nil)
    scored = Enum.reject(calls, & &1.pinned)
    assert {:ok, state, %{stage: stage}} = Policy.build_state(messages, scored, config: config)
    assert stage >= 1
    encoded = Jason.encode!(state)
    assert encoded =~ "File.read"
    assert encoded =~ "UNIQUE_TAIL_ERROR"
    assert state["goal"] =~ "fix UNIQUE_TAIL_ERROR"
  end

  test "threshold boundaries" do
    call = %{id: "t0", tool_call_id: "c", pinned: false}
    config = cfg()
    assert Policy.decide(call, %{keep_call: 0.4, keep_result: 0.5}, config).action == :keep
    assert Policy.decide(call, %{keep_call: 0.5, keep_result: 0.49}, config).action == :drop_result
    assert Policy.decide(call, %{keep_call: 0.49, keep_result: 0.49}, config).action == :drop_call
    assert Policy.decide(%{call | pinned: true}, %{keep_call: 0.0, keep_result: 0.0}, config).action == :keep
  end

  test "batching skips when a question cannot fit" do
    {a, t} = call("r1", "1", String.duplicate("n", 20))
    messages = transcript([%{"role" => "user", "content" => "u"}, a, t])
    source = %{cut: 0, calls: Policy.index_calls(messages)}
    config = %{cfg() | max_request_tokens: 2_000, max_state_tokens: 20_000, preserve_recent_messages: 0}
    assert {:ok, calls} = Policy.collect_calls(messages, config, source, nil)
    {:ok, state, _} = Policy.build_state(messages, calls, config: config)
    tiny = %{config | max_request_tokens: 1}
    assert {:skip, :question_too_large} = Policy.batch_calls(state, Enum.reject(calls, & &1.pinned), tiny)
  end
end
