defmodule Newbee.Browser.SessionTest do
  use ExUnit.Case, async: false
  alias Newbee.Browser.Session

  setup do
    %{root: File.cwd!(), runner: Path.expand("test/fixtures/browser_session.py")}
  end

  defp worker(context, opts \\ []) do
    start_supervised!({Session, Keyword.merge([root: context.root, runner: context.runner], opts)})
  end

  defp request(extra \\ %{}), do: Map.merge(%{"timeout" => 2_000}, extra)

  defp eventually(fun, attempts \\ 100)
  defp eventually(fun, 0), do: assert(fun.())

  defp eventually(fun, attempts) do
    if fun.() do
      :ok
    else
      Process.sleep(20)
      eventually(fun, attempts - 1)
    end
  end

  test "reuses one worker and reassembles responses larger than one port line", context do
    pid = worker(context)
    assert {:ok, %{"result" => first}} = Session.run(pid, request(%{"size" => 20_000}))
    assert byte_size(first["text"]) == 20_000
    assert {:ok, %{"result" => second}} = Session.run(pid, request())
    assert first["pid"] == second["pid"]
    assert second["count"] == 2
    assert second["closed"] === false
  end

  test "rejects overlapping plans rather than interleaving writes", context do
    pid = worker(context)
    task = Task.async(fn -> Session.run(pid, request(%{"sleep_ms" => 250})) end)
    eventually(fn -> :sys.get_state(pid).pending != nil end)
    assert {:error, %{reason: :session_busy}} = Session.run(pid, request())
    assert {:ok, _} = Task.await(task)
    assert {:ok, %{"result" => %{"count" => 2}}} = Session.run(pid, request())
  end

  test "idle expiration terminates the worker process", context do
    pid = worker(context, idle_ms: 80)
    assert {:ok, %{"result" => %{"pid" => os_pid}}} = Session.run(pid, request())
    eventually(fn -> not Process.alive?(pid) end)
    eventually(fn -> not File.exists?("/proc/" <> Integer.to_string(os_pid)) end)
  end

  test "total deadline loses the session and stops its OS process", context do
    pid = worker(context)
    assert {:ok, %{"result" => %{"pid" => os_pid}}} = Session.run(pid, request())

    assert {:error, %{reason: :runner_timeout, state_lost: true}} =
             Session.run(pid, request(%{"timeout" => 500, "sleep_ms" => 5_000}))

    eventually(fn -> not Process.alive?(pid) end)
    eventually(fn -> not File.exists?("/proc/" <> Integer.to_string(os_pid)) end)
  end

  test "caller death cancels an in-flight plan", context do
    pid = worker(context)
    parent = self()

    caller =
      spawn(fn ->
        send(parent, :calling)
        Session.run(pid, request(%{"sleep_ms" => 5_000, "timeout" => 10_000}))
      end)

    assert_receive :calling
    eventually(fn -> :sys.get_state(pid).pending != nil end)
    Process.exit(caller, :kill)
    eventually(fn -> not Process.alive?(pid) end)
  end

  test "crashed and oversized workers are not silently restarted", context do
    pid = worker(context)
    assert {:error, %{reason: :session_lost}} = Session.run(pid, request(%{"mode" => "crash"}))
    eventually(fn -> not Process.alive?(pid) end)
    stop_supervised(Session)
    other = worker(context)
    assert {:error, %{reason: :response_too_large}} = Session.run(other, request(%{"mode" => "oversize"}))
    eventually(fn -> not Process.alive?(other) end)
  end

  test "explicit close returns its result before stopping", context do
    pid = worker(context)
    assert {:ok, %{"result" => %{"closed" => true}}} = Session.run(pid, request(%{"mode" => "close"}))
    eventually(fn -> not Process.alive?(pid) end)
  end

  test "worker termination removes its isolated tmp dir", context do
    pid = worker(context)
    tmp_dir = :sys.get_state(pid).tmp_dir
    assert String.contains?(tmp_dir, ".newbee/browser/tmp/session-")
    assert File.dir?(tmp_dir)
    stop_supervised(Session)
    eventually(fn -> not File.exists?(tmp_dir) end)
  end

  test "oversized idle_ms is clamped to the maximum", context do
    pid = worker(context, idle_ms: 9_999_999)
    assert :sys.get_state(pid).idle_ms == 1_800_000
    stop_supervised(Session)
  end
end
