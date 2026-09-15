defmodule Newbee.Learning.Pipeline do
  @moduledoc "End-to-end offline DRS: reproduce -> practice -> check -> frozen comparison."

  alias Newbee.Learning.{Actor, Evaluation, Fixtures, State}

  @default_budget %{
    "calls" => 40,
    "tokens" => 200_000,
    "wall_ms" => 900_000,
    "disk_bytes" => 67_108_864,
    "eval_reserve" => 12
  }

  def run(opts) do
    experiment_id = Keyword.fetch!(opts, :experiment_id)
    root = Keyword.fetch!(opts, :root)
    model_fun = Keyword.get(opts, :model_fun, &Actor.default_model/2)
    fixtures = Keyword.get(opts, :fixtures, Fixtures.list(:development))
    heldout = Keyword.fetch!(opts, :heldout)
    trials = Keyword.get(opts, :trials, 1)
    max_practices = Keyword.get(opts, :max_practices, 1)

    File.mkdir_p!(Path.join(root, "objects"))
    baseline = baseline_spec(experiment_id)

    {:ok, state0} =
      State.new(%{"id" => experiment_id, "baseline" => baseline, "budget" => %{"total" => @default_budget}})

    {state, _} = attempt(fixtures, root, experiment_id, "", model_fun, "repro", state0, 2, 4000)
    {state, practices} = practice_loop(fixtures, root, experiment_id, state, model_fun, max_practices, 0, [])

    protocol =
      Evaluation.lock(%{
        "source" => %{"tree_hash" => baseline["source_tree_hash"], "dependencies_hash" => baseline["dependencies_hash"]},
        "release_map" => baseline["release_map"],
        "model" => %{"provider" => "offline", "name" => Keyword.get(opts, :model_name, "pilot")},
        "judge" => %{"id" => "deterministic", "version" => Fixtures.version()},
        "fixtures" => %{"development" => Enum.map(fixtures, & &1["id"]), "heldout" => Enum.map(heldout, & &1["id"])},
        "trials" => trials,
        "budget" => %{"per_task" => 20_000},
        "arms" => %{
          "baseline" => %{"memory_id" => baseline["memory_m0"]},
          "candidate" => %{"memory_id" => state["learning_head"]}
        },
        "learning_cost" => %{"tokens" => 0}
      })

    case protocol do
      {:ok, protocol} ->
        outcomes =
          protocol["plan"]
          |> Enum.map(fn cell ->
            arm_memory = arm_memory(state, baseline, cell["arm"])

            result =
              run_fixture(Fixtures.get(cell["fixture_id"]) |> elem(1), root, experiment_id, arm_memory, model_fun)

            %{
              "fixture_id" => cell["fixture_id"],
              "trial" => cell["trial"],
              "arm" => cell["arm"],
              "status" => status_of(result),
              "protocol_hash" => protocol["protocol_hash"],
              "cost" => %{"tokens" => result_usage_tokens(result)}
            }
          end)

        {:ok, report} = Evaluation.summarize(protocol, outcomes)

        {:ok,
         %{"report" => report, "reproduction" => reproduction_verdict(state, experiment_id), "practices" => practices}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp reproduction_verdict(state, id) do
    get_in(state, ["attempts", id <> "-repro", "verdict"])
  end

  defp practice_loop(_fixtures, _root, _id, state, _model_fun, max, n, acc) when n >= max,
    do: {state, Enum.reverse(acc)}

  defp practice_loop(fixtures, root, id, state, model_fun, max, n, acc) do
    case Enum.drop(fixtures, n + 1) do
      [] ->
        {state, Enum.reverse(acc)}

      [next | _] ->
        tag = "p" <> Integer.to_string(n + 1)
        attempt_id = id <> "-" <> tag

        {state, attempt_receipt} =
          attempt([next], root, id, state["learning_head"], model_fun, tag, state, 3, 6000)

        verdict =
          get_in(state, ["attempts", attempt_id, "verdict"]) || attempt_receipt[:verdict] || "unknown"

        lesson = %{
          "claim" => "practice for " <> next["id"] <> " completed with verdict " <> verdict,
          "scope" => "elixir-fixtures",
          "preconditions" => ["fixture " <> next["id"]],
          "counterexample" => "not applicable outside fixture scope",
          "uncertainties" => [],
          "evidence_hashes" => []
        }

        state2 = command(state, tag <> "-prop", "propose_lesson", %{"attempt_id" => attempt_id, "lesson" => lesson})
        state3 = command(state2, tag <> "-admit", "admit", %{"attempt_id" => attempt_id, "lesson" => lesson})
        practice_loop(fixtures, root, id, state3, model_fun, max, n + 1, [attempt_id | acc])
    end
  end


  defp attempt([fx | _], root, experiment_id, memory, model_fun, tag, state, calls, tokens) do
    attempt_id = experiment_id <> "-" <> tag
    contract = Fixtures.version()

    s1 =
      command(state, tag <> "-start", "start_attempt", %{
        "attempt_id" => attempt_id,
        "input_memory_id" => state["learning_head"],
        "contract_hash" => contract,
        "reserve" => %{"calls" => calls, "tokens" => tokens}
      })

    result = run_fixture(fx, root, experiment_id, memory, model_fun)
    verdict = status_of(result)
    s2 = command(s1, tag <> "-run", "record_execution", %{"attempt_id" => attempt_id, "execution_status" => "running"})

    s3 =
      command(s2, tag <> "-sub", "record_execution", %{"attempt_id" => attempt_id, "execution_status" => "submitted"})

    s4 =
      command(s3, tag <> "-term", "record_execution", %{
        "attempt_id" => attempt_id,
        "execution_status" => "terminal",
        "execution_reason" => "completed"
      })

    s5 = command(s4, tag <> "-fin", "finish_attempt", %{"attempt_id" => attempt_id, "verdict" => verdict})
    s6 = command(s5, tag <> "-reconcile", "reconcile_budget", %{"attempt_id" => attempt_id, "cost" => cost_for(result)})
    {s6, %{attempt_id: attempt_id, verdict: verdict}}
  end

  defp arm_memory(_state, baseline, "baseline"), do: baseline["memory_m0"]
  defp arm_memory(state, _baseline, "candidate"), do: state["learning_head"]

  defp run_fixture(fx, root, experiment_id, memory, model_fun) do
    run_root = Path.join([root, "fixtures", fx["id"]])
    File.mkdir_p!(run_root)

    Newbee.Learning.Context.run(experiment_id, "fixture", fn ->
      task = Map.put(fx["task"], "fixture_id", fx["id"])

      case Actor.run(task, memory, root: run_root, experiment_id: experiment_id, model_fun: model_fun, max_calls: 2) do
        {:ok, %{result: nil}} ->
          %{error: :no_actor_result}

        {:ok, %{result: run, usage: usage}} ->
          %{run: run, check: Fixtures.check(fx["id"], string_result(run)), usage: usage}

        {:error, reason} ->
          %{error: reason}
      end
    end)
  end

  defp string_result(run), do: %{"exit_code" => run.exit_code, "stdout" => run.stdout, "stderr" => run.stderr}
  defp status_of(%{check: {:ok, %{"verdict" => v}}}), do: v
  defp status_of(%{error: _}), do: "unknown"
  defp result_usage_tokens(%{usage: %{"tokens" => t}}), do: t
  defp result_usage_tokens(_), do: 0

  defp cost_for(%{usage: usage}) do
    %{"calls" => Map.get(usage, "calls", 0), "tokens" => Map.get(usage, "tokens", 0)}
  end

  defp cost_for(_), do: %{"calls" => 0, "tokens" => 0}

  defp command(state, id, type, payload) do
    {:ok, next, _receipt} =
      State.apply(state, %{"id" => id, "type" => type, "expected_revision" => state["revision"], "payload" => payload})

    next
  end

  defp baseline_spec(id) do
    %{
      "id" => "base-" <> id,
      "source_tree_hash" => String.duplicate("1", 64),
      "project_id" => "learning",
      "dependencies_hash" => String.duplicate("2", 64),
      "release_map" => %{},
      "memory_m0" => "mem-m0-" <> id,
      "model_config_hash" => String.duplicate("3", 64),
      "policy_hash" => String.duplicate("4", 64),
      "fixture_version" => Fixtures.version()
    }
  end
end
