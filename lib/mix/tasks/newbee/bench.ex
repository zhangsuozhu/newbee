defmodule Mix.Tasks.Newbee.Bench do
  @shortdoc "跑公开基准（抗体回放 + bench 任务集）"
  @moduledoc """
  跑公开基准（真实 LLM）：

  1. 确定性门：已验证失败抗体回放（§8.2 Deterministic 层，§15.13 零复现）；
  2. bench/tasks/*.json 端到端任务（真实 LLM 跑，产出通过率/token 报告——
     M5 公开评测基准的底座，§14 P5）。
  """
  use Mix.Task

  @impl true
  def run(_args) do
    Newbee.Cwd.apply!()
    Mix.Task.run("app.start")

    IO.puts("抗体回放（确定性门）…")

    case Newbee.Environment.Antibodies.gate() do
      {:pass, %{ran: ran}} ->
        IO.puts("antibodies: #{ran} ran, 0 failed（零复现）")

      {:fail, %{ran: ran, failed: failed, failures: failures}} ->
        IO.puts("antibodies: #{ran} ran, #{failed} FAILED")

        Enum.each(failures, fn {:fail, id, detail} ->
          IO.puts("  ❌ #{id}: #{String.slice(to_string(detail), 0, 200)}")
        end)
    end

    IO.puts("\n任务集（真实 LLM，可能要几分钟）…")
    client = Newbee.LLM.Config.client_for()
    report = run_tasks(client)
    IO.puts("bench: #{report.passed}/#{report.total} 通过, #{report.tokens} tokens")

    Enum.each(report.details, fn d ->
      IO.puts("  #{if d.passed, do: "✅", else: "❌"} #{d.id} (#{d.tokens} tok)")
    end)
  end

  @doc "跑 bench/tasks/*.json 任务集。每个任务：prompt → worker loop → checker 判定。"
  def run_tasks(client) do
    tasks =
      Path.wildcard("bench/tasks/*.json")
      |> Enum.flat_map(fn f ->
        case File.read(f) do
          {:ok, body} ->
            case Jason.decode(body) do
              {:ok, t} -> [t]
              _ -> []
            end

          _ ->
            []
        end
      end)

    results = Enum.map(tasks, &run_task(&1, client))

    %{
      total: length(results),
      passed: Enum.count(results, & &1.passed),
      tokens: Enum.reduce(results, 0, fn d, acc -> acc + d.tokens end),
      details: results
    }
  end

  defp run_task(%{"id" => id, "prompt" => prompt} = task, client) do
    {:ok, kernel} = Newbee.Agent.Loop.start_link(client: client, session: false)

    {reply, tokens} =
      try do
        r = Newbee.Agent.Loop.submit(kernel, prompt)
        usage = Newbee.Agent.Loop.usage(kernel)

        {r,
         (usage[:input_tokens] || usage["input_tokens"] || 0) + (usage[:output_tokens] || usage["output_tokens"] || 0)}
      after
        if Process.alive?(kernel), do: GenServer.stop(kernel, :normal, 5_000)
      end

    passed =
      case task["check"] do
        %{"contains" => needle} -> String.contains?(inspect(reply), needle)
        %{"file_exists" => path} -> File.exists?(path)
        _ -> match?({:done, _}, reply)
      end

    %{id: id, passed: passed, tokens: tokens}
  rescue
    e -> %{id: id, passed: false, tokens: 0, error: Exception.message(e)}
  end
end
