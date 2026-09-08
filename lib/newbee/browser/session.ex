defmodule Newbee.Browser.Session do
  @moduledoc false
  use GenServer, restart: :temporary

  @idle_ms 120_000
  @max_idle_ms 1_800_000
  @max_output_bytes 1_048_576

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))
  end

  def run(pid, request) do
    GenServer.call(pid, {:run, request}, request["timeout"] + 4_000)
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    root = Keyword.fetch!(opts, :root)
    python = if File.regular?("/usr/bin/python3"), do: "/usr/bin/python3", else: System.find_executable("python3")
    runner = Keyword.get(opts, :runner, Path.join(root, "priv/browser/playwright_runner.py"))

    if is_binary(python) and File.regular?(runner) do
      tmp_dir = Keyword.get_lazy(opts, :tmp_dir, fn -> session_tmp_dir(root) end)

      with :ok <- File.mkdir_p(tmp_dir),
           port <-
             Port.open({:spawn_executable, python}, [
               :binary,
               :exit_status,
               :stderr_to_stdout,
               {:line, 8_192},
               args: ["-u", runner, "--serve"],
               cd: String.to_charlist(root),
               env: [{String.to_charlist("TMPDIR"), String.to_charlist(tmp_dir)} | env_unsets()]
             ]),
           {:os_pid, os_pid} <- Port.info(port, :os_pid) do
        state = %{
          port: port,
          os_pid: os_pid,
          pending: nil,
          buffer: "",
          bytes: 0,
          diagnostics: "",
          idle: nil,
          idle_ms: min(Keyword.get(opts, :idle_ms, @idle_ms), @max_idle_ms),
          closing: false,
          close_payload: nil,
          tmp_dir: tmp_dir
        }

        {:ok, arm_idle(state)}
      else
        _ ->
          cleanup_tmp(tmp_dir)
          {:stop, :runtime_missing}
      end
    else
      {:stop, :runtime_missing}
    end
  end

  @impl true
  def handle_call({:run, _request}, _from, %{pending: pending} = state) when not is_nil(pending) do
    {:reply, {:error, %{reason: :session_busy, hint: "another plan is running in this browser session"}}, state}
  end

  def handle_call({:run, request}, from, state) do
    cancel_idle(state.idle)
    ref = make_ref()
    timer = Process.send_after(self(), {:deadline, ref}, request["timeout"] + 1_000)
    monitor = Process.monitor(elem(from, 0))
    true = Port.command(state.port, Jason.encode!(request) <> "\n")
    pending = %{from: from, ref: ref, timer: timer, monitor: monitor}
    {:noreply, %{state | pending: pending, idle: nil, bytes: 0, buffer: "", diagnostics: ""}}
  end

  @impl true
  def handle_info({port, {:data, {kind, data}}}, %{port: port} = state) do
    state = %{state | bytes: state.bytes + byte_size(data), buffer: state.buffer <> data}

    cond do
      state.bytes > @max_output_bytes ->
        fail(state, :response_too_large, "browser response exceeded 1 MiB; session was closed")

      kind == :noeol ->
        {:noreply, state}

      true ->
        case Jason.decode(state.buffer) do
          {:ok, %{"ok" => true, "result" => result} = payload} when is_map(result) and not is_nil(state.pending) ->
            finish(state, payload)

          {:ok, %{"ok" => false, "error" => error} = payload} when is_map(error) and not is_nil(state.pending) ->
            finish(state, payload)

          _ ->
            diagnostics = String.slice(state.diagnostics <> state.buffer <> "\n", -4_000, 4_000)
            {:noreply, %{state | buffer: "", diagnostics: diagnostics}}
        end
    end
  end

  def handle_info({port, {:exit_status, 0}}, %{port: port, closing: true, close_payload: payload} = state)
      when not is_nil(payload) do
    clear_pending(state.pending)
    GenServer.reply(state.pending.from, {:ok, payload})
    {:stop, :normal, %{state | pending: nil}}
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    fail(
      state,
      :session_lost,
      "browser worker exited with " <> Integer.to_string(status) <> "; inspect before replaying writes"
    )
  end

  def handle_info({:deadline, ref}, %{pending: %{ref: ref}} = state) do
    fail(state, :runner_timeout, "browser plan exceeded its total budget; session was closed and its state is lost")
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{pending: %{monitor: ref}} = state) do
    clear_pending(state.pending)
    {:stop, :normal, %{state | pending: nil}}
  end

  def handle_info({:idle, ref}, %{idle: {ref, _}, pending: nil} = state) do
    {:stop, :normal, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    cancel_idle(state.idle)
    if state.pending, do: clear_pending(state.pending)
    port = state.port

    # The worker owns its process group. Allow cleanup before a forced stop.
    if Port.info(port) do
      if not state.closing, do: signal(state.os_pid, "-TERM")

      receive do
        {^port, {:exit_status, _}} -> :ok
      after
        1_000 -> signal(-state.os_pid, "-KILL")
      end

      if Port.info(port), do: Port.close(port)
    end

    if not state.closing, do: signal(-state.os_pid, "-KILL")
    # A SIGKILLed worker cannot remove its own files; the owner reaps them.
    cleanup_tmp(Map.get(state, :tmp_dir))
    :ok
  end

  defp finish(state, payload) do
    if get_in(payload, ["result", "closed"]) == true do
      {:noreply, %{state | closing: true, close_payload: payload, buffer: "", bytes: 0}}
    else
      clear_pending(state.pending)
      GenServer.reply(state.pending.from, {:ok, payload})
      {:noreply, arm_idle(%{state | pending: nil, buffer: "", bytes: 0, diagnostics: ""})}
    end
  end

  defp fail(state, reason, hint) do
    if state.pending do
      clear_pending(state.pending)

      GenServer.reply(
        state.pending.from,
        {:error, %{reason: reason, hint: hint, output: state.diagnostics, state_lost: true}}
      )
    end

    {:stop, :normal, %{state | pending: nil}}
  end

  defp clear_pending(pending) do
    Process.cancel_timer(pending.timer)
    Process.demonitor(pending.monitor, [:flush])
  end

  defp arm_idle(state) do
    ref = make_ref()
    timer = Process.send_after(self(), {:idle, ref}, state.idle_ms)
    %{state | idle: {ref, timer}}
  end

  defp cancel_idle(nil), do: :ok
  defp cancel_idle({_ref, timer}), do: Process.cancel_timer(timer)

  defp session_tmp_dir(root) do
    token = :crypto.strong_rand_bytes(9) |> Base.encode32(case: :lower, padding: false)
    Path.join([root, ".newbee", "browser", "tmp", "session-" <> token])
  end

  defp cleanup_tmp(dir) when is_binary(dir) do
    if String.contains?(dir, ".newbee/browser/tmp/") and
         String.starts_with?(Path.basename(dir), ["session-", "runtime-"]) do
      File.rm_rf(dir)
    end

    :ok
  end

  defp cleanup_tmp(_), do: :ok

  defp signal(pid, signal) do
    case System.find_executable("kill") do
      nil -> :ok
      executable -> System.cmd(executable, [signal, "--", Integer.to_string(pid)], stderr_to_stdout: true)
    end
  end

  defp env_unsets do
    System.get_env()
    |> Map.keys()
    |> Enum.filter(fn name ->
      name == "NEWBEE_CWD" or
        Enum.any?(~w(OPENROUTER_ DEEPSEEK_ ANTHROPIC_ OPENAI_), &String.starts_with?(name, &1)) or
        Enum.any?(~w(_KEY _TOKEN _SECRET), &String.ends_with?(name, &1))
    end)
    |> Enum.map(&{String.to_charlist(&1), false})
  end
end
