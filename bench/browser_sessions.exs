alias Newbee.Collaboration.Capability
alias Newbee.Tools.Browser

iterations = System.get_env("BROWSER_BENCH_RUNS", "10") |> String.to_integer() |> max(3) |> min(100)
:ok = Capability.register(self(), "browser-benchmark", File.cwd!())
{:ok, token} = Capability.issue(self())
Process.put({Newbee.Tools.Media, :capability}, token)

html =
  ~S|<label>Query<input id="query"></label><button onclick="document.getElementById('status').textContent = document.getElementById('query').value">Apply</button><output id="status"></output>|

actions = [
  %{action: "set_content", html: html},
  %{action: "fill", by: "label", selector: "Query", value: "ok"},
  %{action: "click", by: "role", selector: "button", name: "Apply"},
  %{action: "wait", function: "document.querySelector('#status').textContent === 'ok'"},
  %{action: "text", selector: "#status"}
]

measure = fn request ->
  {elapsed, result} = :timer.tc(fn -> Browser.run(request) end)

  case result do
    {:ok, value} ->
      if List.last(value["results"])["result"] != "ok", do: raise("unexpected page result")
      {elapsed / 1000, value}

    error ->
      raise "benchmark operation failed: " <> inspect(error)
  end
end

summarize = fn samples ->
  sorted = Enum.sort(samples)

  %{
    runs: length(sorted),
    median_ms: Enum.at(sorted, div(length(sorted), 2)),
    p95_ms: Enum.at(sorted, ceil(length(sorted) * 0.95) - 1),
    min_ms: hd(sorted),
    max_ms: List.last(sorted)
  }
end

{startup_ms, opened} = measure.(%{session: "new", timeout: 10_000, actions: actions})
session = opened["session"]

try do
  pairs =
    for _ <- 1..iterations do
      {cold, _} = measure.(%{timeout: 10_000, actions: actions})
      {warm, _} = measure.(%{session: session, timeout: 10_000, actions: actions})
      {cold, warm}
    end

  {cold, warm} = Enum.unzip(pairs)

  report = %{
    scenario: "local set_content, fill, click, condition wait, read; alternating cold and warm calls",
    startup_ms: startup_ms,
    one_shot: summarize.(cold),
    reused_session: summarize.(warm),
    success_count: 2 * iterations + 1
  }

  IO.puts(Jason.encode!(report, pretty: true))
after
  {:ok, _} = Browser.run(%{session: session, actions: [%{action: "close"}]})
end
