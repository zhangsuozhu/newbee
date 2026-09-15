defmodule Newbee.Learning.Sandbox do
  @moduledoc """
  Enforced offline execution sandbox for learning fixture runs (BRS/DRS).

  Untrusted Elixir code is executed in a **separate OS process** under
  `bubblewrap` (`bwrap`) with:

    * all namespaces unshared (`--unshare-all`): no external network, private
      PID/mount/IPC/UTS view;
    * a cleared environment (`env -i` + explicit `--setenv`): host credentials
      and tokens never enter the sandbox;
    * minimal read-only mounts only: the resolved Elixir/OTP toolchain roots
      plus system runtime dirs (`/usr`, `/bin`, `/lib`, `/lib64` when
      present). The project repository, real `$HOME`, `.newbee` state, global
      memory, other sessions and hidden check/oracle code are simply not
      mounted and are therefore unreachable from inside;
    * read-only input (`/sandbox/input`): the runner, the user program,
      `memory.txt` and fixture files;
    * one bounded writable output dir (`/sandbox/out`), captured and deleted
      after each run unless `keep: true`;
    * a wall-clock timeout that SIGKILLs the whole child process group.

  The Host runs the sandbox as a plain OS command (`env -i bwrap ...`), never
  through the DEE bridge, and the model only ever observes the returned
  result map — sandboxed code cannot reach Host APIs.

  **Fail-closed**: when `bwrap` is missing or the kernel denies unprivileged
  user namespaces, `available?/0` is `false` and `run/2` returns
  `{:error, :unavailable}` — there is no weaker fallback executor.

  `run_check/2` executes trusted check code **outside** the sandbox (in the
  caller's Host BEAM) against the captured artifacts/stdout/receipt of a
  previous run, so hidden checks never become visible to the actor.

  ## Known limitations (honest boundary)

    * Uses *unprivileged* user namespaces; `bwrap` must not be setuid here.
    * No cgroup v2 delegation on a typical host: a hostile program can burn
      CPU until `timeout_ms` kills it; memory is bounded only by the kernel.
    * Linux only. `exit_code` is `nil` for timed-out runs (deterministic).
    * Sandboxed code keeps the host UID outside its PID namespace, so it can
      still signal same-UID host processes by PID number (it cannot see or
      ptrace them). Treat this as a confidentiality/integrity boundary for
      files, environment and network — not full resource isolation.
    * stdout and stderr are merged into one captured stream (documented in
      the result as `stderr: ""`) because a single stdio port cannot split
      them; integrity hashes cover the merged stream.
  """

  @sandbox_name "bwrap"
  @default_timeout_ms 30_000
  @default_max_output_bytes 1_048_576
  @sys_mounts ["/usr", "/lib", "/lib64"]

  @type artifact :: %{path: String.t(), sha256: String.t(), bytes: non_neg_integer()}

  @type result :: %{
          sandbox: String.t(),
          exit_code: non_neg_integer() | nil,
          timed_out: boolean(),
          stdout: binary(),
          stderr: binary(),
          stdout_trimmed: boolean(),
          stderr_trimmed: boolean(),
          duration_ms: non_neg_integer(),
          code_sha256: String.t(),
          memory_sha256: String.t() | nil,
          output_sha256: String.t(),
          artifacts: [artifact()],
          receipt: map(),
          run_dir: String.t() | nil
        }

  ## -- public API -------------------------------------------------------------

  @doc """
  Whether enforced sandboxed execution is possible on this host.

  Checks that `bwrap` is on `PATH` and that a real `--unshare-all`
  user-namespace probe succeeds. The result is cached in `:persistent_term`;
  pass `refresh: true` to re-probe.
  """
  @spec available?(keyword()) :: boolean()
  def available?(opts \\ []) do
    key = {__MODULE__, :available}

    case {Keyword.get(opts, :refresh, false), :persistent_term.get(key, :unset)} do
      {false, {_, available}} ->
        available

      _ ->
        available = probe_availability()
        :persistent_term.put(key, {System.monotonic_time(), available})
        available
    end
  end

  @doc """
  Run untrusted Elixir `code` offline inside the bubblewrap sandbox.

  Options:

    * `:root` (required) — experiment workspace owned by the caller. Per-run
      temp dirs are created under `<root>/sandbox_runs/` and deleted after
      capture unless `keep: true`. `root` must be an absolute path other than
      `"/"`; it is only ever bind-mounted under `/sandbox/` (never as the
      sandbox `/`), and no mount source may resolve to host `"/"`.
    * `:memory` — read-only input memory text, mounted at
      `/sandbox/input/memory.txt` (`SANDBOX_MEMORY_PATH` inside).
    * `:files` — map of `relative_path => content` extra read-only fixture
      inputs mounted under `/sandbox/input/`.
    * `:timeout_ms` — wall timeout (default `#{@default_timeout_ms}`); on
      expiry the whole child process group is SIGKILLed, `timed_out` is
      `true` and `exit_code` is `nil`.
    * `:max_output_bytes` — capture cap for the merged output stream
      (default `#{@default_max_output_bytes}`); truncation is always reported
      via `stdout_trimmed` / `stderr_trimmed`, never silent.
    * `:keep` — keep the run directory (needed for host-side artifact
      re-hashing in `run_check/2`; otherwise checks use captured metadata).

  Returns `{:ok, result}` even when the program exits non-zero — a non-zero
  exit is a legitimate sandbox result. `{:error, reason}` is returned only
  when the sandbox itself could not execute the program.
  """
  @spec run(binary(), keyword()) :: {:ok, result()} | {:error, term()}
  def run(code, opts \\ []) when is_list(opts) do
    with :ok <- ensure_available(),
         {:ok, root} <- validate_root(Keyword.get(opts, :root)),
         :ok <- validate_code(code),
         {:ok, memory} <- validate_memory(Keyword.get(opts, :memory)),
         {:ok, files} <- validate_files(Keyword.get(opts, :files)),
         {:ok, timeout_ms} <- validate_timeout(Keyword.get(opts, :timeout_ms)),
         {:ok, max_output} <- validate_max_output(Keyword.get(opts, :max_output_bytes)),
         {:ok, keep} <- validate_keep(Keyword.get(opts, :keep)),
         {:ok, tc} <- toolchain(),
         {:ok, prep} <- prepare_run(root, code, memory, files) do
      try do
        do_run(tc, prep, root, timeout_ms, max_output, keep)
      after
        unless keep, do: File.rm_rf(prep.run_dir)
      end
    end
  end

  @doc """
  Execute trusted check code **outside** the sandbox against a captured run.

  `check_code` runs in the caller's Host BEAM in a monitored task (brutally
  killed after `:timeout_ms`, default 5_000) with one binding, `run`, holding
  the `t:result/0` of a previous `run/2`. When the run was kept
  (`keep: true`), artifact files are re-hashed on the host first; any
  mismatch returns `{:error, :artifact_mismatch}` so tampered output cannot
  satisfy `{:artifact, path, sha256}` style candidates.

  Returns `{:ok, %{passed: boolean, report: binary, check_sha256: hex,
  run_output_sha256: hex}}`; a falsy check value yields `passed: false`.
  Check-code crashes and timeouts return `{:error, _}`.
  """
  @spec run_check(binary(), keyword()) :: {:ok, map()} | {:error, term()}
  def run_check(check_code, opts \\ []) when is_binary(check_code) and is_list(opts) do
    timeout = Keyword.get(opts, :timeout_ms, 5_000)

    with {:ok, run} <- fetch_run(opts),
         :ok <- reverify_artifacts(run) do
      task =
        Task.async(fn ->
          {value, _binding} =
            Code.eval_string(check_code, [run: run], file: "learning_check.exs")

          %{passed: value not in [nil, false], report: inspect(value)}
        end)

      case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
        {:ok, %{passed: passed, report: report}} ->
          {:ok,
           %{
             passed: passed,
             report: report,
             check_sha256: sha256_hex(check_code),
             run_output_sha256: run.output_sha256
           }}

        nil ->
          {:error, :check_timeout}

        {:exit, reason} ->
          {:error, {:check_crashed, reason}}
      end
    end
  rescue
    e -> {:error, {:check_error, Exception.format(:error, e, __STACKTRACE__)}}
  end

  ## -- availability -----------------------------------------------------------

  defp probe_availability do
    case System.find_executable("bwrap") do
      nil ->
        false

      bwrap ->
        args =
          Enum.flat_map(@sys_mounts, fn dir ->
            if File.dir?(dir), do: ["--ro-bind", dir, dir], else: []
          end)

        probe =
          ["--unshare-all", "--die-with-parent", "--dev", "/dev"] ++
            args ++ ["/usr/bin/true"]

        case System.cmd(bwrap, probe, stderr_to_stdout: true) do
          {_, 0} -> true
          _ -> false
        end
    end
  rescue
    _ -> false
  end

  defp ensure_available do
    if available?(), do: :ok, else: {:error, :unavailable}
  end

  ## -- validation ---------------------------------------------------------------

  defp validate_root(root) when is_binary(root) do
    if Path.type(root) == :absolute and root != "/" and String.trim(root) != "" do
      {:ok, Path.expand(root)}
    else
      {:error, :invalid_root}
    end
  end

  defp validate_root(_), do: {:error, :invalid_root}

  defp validate_code(code) when is_binary(code) and byte_size(code) > 0, do: :ok
  defp validate_code(_), do: {:error, :invalid_code}

  defp validate_memory(nil), do: {:ok, nil}
  defp validate_memory(memory) when is_binary(memory), do: {:ok, memory}
  defp validate_memory(_), do: {:error, :invalid_memory}

  defp validate_files(nil), do: {:ok, %{}}

  defp validate_files(files) when is_map(files) do
    if Enum.all?(files, fn {k, v} -> valid_relative_path?(k) and is_binary(v) end) do
      {:ok, files}
    else
      {:error, :invalid_files}
    end
  end

  defp validate_files(_), do: {:error, :invalid_files}

  defp valid_relative_path?(path) when is_binary(path) do
    path != "" and Path.type(path) != :absolute and
      Enum.all?(Path.split(path), &(&1 not in ["..", ".", "/", ""]))
  end

  defp valid_relative_path?(_), do: false

  defp validate_timeout(nil), do: {:ok, @default_timeout_ms}
  defp validate_timeout(t) when is_integer(t) and t > 0 and t <= 3_600_000, do: {:ok, t}
  defp validate_timeout(_), do: {:error, :invalid_options}

  defp validate_max_output(nil), do: {:ok, @default_max_output_bytes}

  defp validate_max_output(n) when is_integer(n) and n > 0 and n <= 67_108_864, do: {:ok, n}
  defp validate_max_output(_), do: {:error, :invalid_options}

  defp validate_keep(nil), do: {:ok, false}
  defp validate_keep(k) when is_boolean(k), do: {:ok, k}
  defp validate_keep(_), do: {:error, :invalid_options}

  ## -- run preparation -----------------------------------------------------------

  defp prepare_run(root, code, memory, files) do
    run_id =
      Integer.to_string(System.unique_integer([:positive, :monotonic])) <>
        "-" <> Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)

    run_dir = Path.join([root, "sandbox_runs", run_id])
    in_dir = Path.join(run_dir, "input")
    out_dir = Path.join(run_dir, "out")

    prep = %{
      run_id: run_id,
      run_dir: run_dir,
      in_dir: in_dir,
      out_dir: out_dir,
      runner_path: Path.join(run_dir, "runner.sh"),
      started_at: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
    }

    with :ok <- File.mkdir_p(in_dir),
         :ok <- File.mkdir_p(out_dir),
         :ok <- write_file(Path.join(in_dir, "user.exs"), code),
         :ok <- write_file(prep.runner_path, runner_script(), 0o755),
         :ok <- maybe_write_memory(in_dir, memory),
         :ok <- write_fixture_files(in_dir, files) do
      {:ok, prep}
    else
      {:error, reason} ->
        File.rm_rf(run_dir)
        {:error, {:prepare_failed, reason}}
    end
  end

  defp write_file(path, content, mode \\ 0o644) do
    with :ok <- File.write(path, content), do: File.chmod(path, mode)
  end

  defp maybe_write_memory(_in_dir, nil), do: :ok
  defp maybe_write_memory(in_dir, memory), do: write_file(Path.join(in_dir, "memory.txt"), memory)

  defp write_fixture_files(in_dir, files) do
    Enum.reduce_while(files, :ok, fn {rel, content}, :ok ->
      path = Path.join(in_dir, rel)

      with :ok <- File.mkdir_p(Path.dirname(path)),
           :ok <- write_file(path, content) do
        {:cont, :ok}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  ## -- toolchain + bwrap argv ------------------------------------------------------

  defp toolchain do
    with elixir when is_binary(elixir) <- System.find_executable("elixir"),
         erl when is_binary(erl) <- System.find_executable("erl"),
         bwrap when is_binary(bwrap) <- System.find_executable("bwrap") do
      elixir_bin = elixir |> realpath() |> Path.dirname()
      erl_bin = erl |> realpath() |> Path.dirname()

      {:ok,
       %{
         bwrap: bwrap,
         elixir: Path.join(elixir_bin, "elixir"),
         elixir_root: Path.dirname(elixir_bin),
         otp_root: otp_root_of(erl_bin),
         path: Enum.join(Enum.uniq([elixir_bin, erl_bin, "/usr/bin", "/bin"]), ":")
       }}
    else
      _ -> {:error, :unavailable}
    end
  end

  defp realpath(path) do
    case File.read_link(path) do
      {:ok, target} -> realpath(resolve_link(path, target))
      {:error, _} -> path
    end
  end

  # The OTP bin dir sits at <otp-root>/bin; the BEAM needs its lib tree, so bind the root.
  defp otp_root_of(erl_bin) do
    case erl_bin |> Path.dirname() |> Path.dirname() do
      root when byte_size(root) > 1 -> root
      _ -> "/usr"
    end
  end


  defp resolve_link(link, target) do
    if Path.type(target) == :absolute do
      target
    else
      link |> Path.dirname() |> Path.join(target) |> Path.expand()
    end
  end

  defp bwrap_args(tc, prep) do
    mounts =
      Enum.flat_map(@sys_mounts, fn dir ->
        if File.dir?(dir), do: ["--ro-bind", dir, dir], else: []
      end)

    [
      "--unshare-all",
      "--die-with-parent",
      "--new-session",
      "--symlink", "usr/bin", "/bin",
      "--symlink", "usr/lib", "/lib",
      "--symlink", "usr/lib64", "/lib64"
    ] ++
      mounts ++
      [
        "--dev", "/dev",
        "--ro-bind", tc.elixir_root, tc.elixir_root,
        "--ro-bind", tc.otp_root, tc.otp_root,
        "--ro-bind", prep.in_dir, "/sandbox/input",
        "--ro-bind", prep.runner_path, "/sandbox/runner.sh",
        "--bind", prep.out_dir, "/sandbox/out",
        "--tmpfs", "/tmp",
        "--chdir", "/sandbox/out",
        "--setenv", "PATH", tc.path,
        "--setenv", "HOME", "/sandbox",
        "--setenv", "SANDBOX_OUT", "/sandbox/out",
        "--setenv", "SANDBOX_INPUT", "/sandbox/input",
        "--setenv", "SANDBOX_USER_PATH", "/sandbox/input/user.exs",
        "--setenv", "SANDBOX_MEMORY_PATH", "/sandbox/input/memory.txt",
        "--setenv", "SANDBOX_ELIXIR", tc.elixir,
        "--setenv", "ELIXIR_ERL_OPTIONS", "+fnu",
        "/usr/bin/sh", "/sandbox/runner.sh"
      ]
  end

  # The trusted Host runner: executes ONLY the mounted user program as an OS
  # process child, never through a DEE bridge. Context arrives exclusively via
  # bwrap --setenv; everything else in the environment was cleared (env -i).
  # The program text is never placed on a command line, so quoting/injection
  # through it is impossible by construction.
  defp runner_script do
    """
    #!/bin/sh
    exec "$SANDBOX_ELIXIR" -e '
    path = System.fetch_env!("SANDBOX_USER_PATH")
    out = System.fetch_env!("SANDBOX_OUT")
    File.cd!(out)

    try do
      Code.eval_file(path)
    rescue
      e ->
        IO.puts(:stderr, Exception.format(:error, e, __STACKTRACE__))
        System.halt(70)
    catch
      kind, value ->
        IO.puts(:stderr, Exception.format(kind, value, __STACKTRACE__))
        System.halt(70)
    end
    ' "$@"
    """
  end

  ## -- execution driver --------------------------------------------------------------

  # System.cmd/3 offers neither a wall-clock timeout nor a bounded capture,
  # so we drive the port ourselves: the port environment is emptied (no
  # credentials even before bwrap's own --setenv handling), the timeout kills
  # the whole child process *group* with SIGKILL (bwrap and the BEAM it
  # spawned share the group; best-effort, documented in @moduledoc), and the
  # merged output stream is capped at max_output_bytes with an explicit,
  # never-silent trim flag.
  defp do_run(tc, prep, root, timeout_ms, max_output, keep) do
    args = bwrap_args(tc, prep)
    started = System.monotonic_time(:millisecond)

    case open_sandbox_port(tc.bwrap, args) do
      {:ok, port} ->
        {stream, trimmed, exit_code, timed_out} = collect(port, timeout_ms, max_output)
        duration_ms = System.monotonic_time(:millisecond) - started

        {artifacts, artifact_sha} = capture_artifacts(prep.out_dir)
        stdout_sha = sha256_hex(stream)
        code_sha = sha256_hex(File.read!(Path.join(prep.in_dir, "user.exs")))
        memory_sha = memory_sha256(prep.in_dir)

        output_sha =
          sha256_hex(Enum.join([code_sha, memory_sha || "-", stdout_sha, artifact_sha], ":"))

        receipt = %{
          run_id: prep.run_id,
          started_at: prep.started_at,
          sandbox: @sandbox_name,
          code_sha256: code_sha,
          memory_sha256: memory_sha,
          stdout_sha256: stdout_sha,
          stderr_sha256: nil,
          artifact_sha256: artifact_sha,
          output_sha256: output_sha,
          timed_out: timed_out,
          exit_code: exit_code,
          root_sha256: sha256_hex(root)
        }

        {:ok,
         %{
           sandbox: @sandbox_name,
           exit_code: exit_code,
           timed_out: timed_out,
           stdout: stream,
           stderr: "",
           stdout_trimmed: trimmed,
           stderr_trimmed: false,
           duration_ms: duration_ms,
           code_sha256: code_sha,
           memory_sha256: memory_sha,
           output_sha256: output_sha,
           artifacts: artifacts,
           receipt: receipt,
           run_dir: if(keep, do: prep.run_dir, else: nil)
         }}

      {:error, reason} ->
        {:error, {:spawn_failed, reason}}
    end
  end

  defp memory_sha256(in_dir) do
    case File.read(Path.join(in_dir, "memory.txt")) do
      {:ok, bytes} -> sha256_hex(bytes)
      {:error, _} -> nil
    end
  end

  defp capture_artifacts(out_dir) do
    artifacts =
      out_dir
      |> list_files()
      |> Enum.map(fn path ->
        rel = Path.relative_to(path, out_dir)
        bytes = File.read!(path)
        %{path: rel, sha256: sha256_hex(bytes), bytes: byte_size(bytes)}
      end)
      |> Enum.sort_by(& &1.path)

    digest =
      artifacts
      |> Enum.map_join("\n", &"#{&1.path} #{&1.sha256} #{&1.bytes}")
      |> sha256_hex()

    {artifacts, digest}
  end

  defp list_files(dir) do
    case File.ls(dir) do
      {:ok, entries} ->
        Enum.flat_map(entries, fn entry ->
          path = Path.join(dir, entry)
          if File.dir?(path), do: list_files(path), else: [path]
        end)

      {:error, _} ->
        []
    end
  end

  ## -- port loop ----------------------------------------------------------------------

  defp open_sandbox_port(bwrap, args) do
    case System.find_executable("env") do
      nil ->
        {:error, :no_env_binary}

      env_bin ->
        port =
          Port.open({:spawn_executable, env_bin}, [
            :binary,
            :stream,
            :use_stdio,
            :stderr_to_stdout,
            :exit_status,
            env: [],
            args: ["-i", bwrap | args]
          ])

        {:ok, port}
    end
  rescue
    e -> {:error, e}
  end

  defp collect(port, timeout_ms, max_output) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    loop(port, deadline, max_output, {"", false}, nil)
  end

  defp loop(port, deadline, max, {acc, trimmed}, exit_status) do
    remaining = deadline - System.monotonic_time(:millisecond)

    cond do
      is_nil(exit_status) and remaining <= 0 ->
        kill_tree(port)
        drain(port, max, {acc, trimmed}, true)

      not is_nil(exit_status) ->
        {acc, trimmed, exit_status, false}

      true ->
        receive do
          {^port, {:data, data}} ->
            loop(port, deadline, max, append_bounded({acc, trimmed}, data, max), exit_status)

          {^port, {:exit_status, status}} ->
            loop(port, deadline, max, {acc, trimmed}, status)
        after
          remaining ->
            kill_tree(port)
            drain(port, max, {acc, trimmed}, true)
        end
    end
  end

  # After the timeout kill we still drain anything the port delivers (plus the
  # exit status) so the result always reflects everything actually produced.
  defp drain(port, max, {acc, trimmed}, timed_out) do
    receive do
      {^port, {:data, data}} ->
        drain(port, max, append_bounded({acc, trimmed}, data, max), timed_out)

      {^port, {:exit_status, _status}} ->
        {acc, trimmed, nil, timed_out}
    after
      500 ->
        {acc, trimmed, nil, timed_out}
    end
  end

  # Kill the whole child process group (negative pid) and the direct child so
  # bwrap and the BEAM it spawned die together.
  defp kill_tree(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, pid} when is_integer(pid) ->
        _ = System.cmd("kill", ["-KILL", "-#{pid}"], stderr_to_stdout: true)
        _ = System.cmd("kill", ["-KILL", "#{pid}"], stderr_to_stdout: true)
        :ok

      _ ->
        :ok
    end
  rescue
    _ -> :ok
  end

  defp append_bounded({acc, trimmed}, data, max) do
    room = max - byte_size(acc)

    cond do
      room <= 0 -> {acc, true}
      byte_size(data) <= room -> {acc <> data, trimmed}
      true -> {acc <> binary_part(data, 0, room), true}
    end
  end

  ## -- checks ---------------------------------------------------------------------------

  defp fetch_run(opts) do
    case Keyword.get(opts, :run) do
      %{output_sha256: out_sha, artifacts: artifacts} = run
      when is_binary(out_sha) and is_list(artifacts) ->
        {:ok, run}

      _ ->
        {:error, :invalid_run}
    end
  end

  # Hidden checks never enter the sandbox. When the run dir was kept we
  # re-hash artifact bytes on the host so a tampered directory cannot satisfy
  # sha256 candidates with stale metadata.
  defp reverify_artifacts(%{run_dir: nil}), do: :ok

  defp reverify_artifacts(%{run_dir: run_dir, artifacts: artifacts}) do
    mismatch? =
      Enum.any?(artifacts, fn
        %{path: rel, sha256: sha} ->
          case File.read(Path.join([run_dir, "out", rel])) do
            {:ok, bytes} -> sha256_hex(bytes) != sha
            {:error, _} -> true
          end

        _ ->
          true
      end)

    if mismatch?, do: {:error, :artifact_mismatch}, else: :ok
  end

  ## -- helpers ----------------------------------------------------------------------------

  defp sha256_hex(data) when is_binary(data) do
    :crypto.hash(:sha256, data) |> Base.encode16(case: :lower)
  end
end