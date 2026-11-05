defmodule Newbee.Tools.Run do
  @moduledoc """
  General shell commands; prefer higher-level tools (Git/Scaffold) when they fit.

  ## Functions
  - `sh(cmd, opts \\\\ [])` — run a shell command; returns `%{exit: integer() | :timeout | :denied, exit_code: integer() | :timeout | :denied, output: String.t()}` (`exit_code` aliases `exit` for backward compat).
  Options: `timeout:` millis or `:infinity` (default `:infinity`); `cd:` an existing directory (default `File.cwd!()`); `shared_terminal: false` to skip the session PTY.


  - `mix_compile(opts \\\\ [])` — `mix compile`; `{:ok, output} | {:error, output}`.
  - `mix_test(files \\\\ [], opts \\\\ [])` — `mix test [files...]`; `{:ok, output} | {:error, output}`.
  - `mix_format(files \\\\ [], opts \\\\ [])` — `mix format --check-formatted [files...]`; `{:ok, output} | {:error, output}`.
    All three take the same `opts` as `sh/2` and quote odd file names.


  ## Permissions and truncation
  - Dangerous commands (`rm -rf /`, `git push`, …) are gated by the `Newbee.Permissions` level (`:lenient`/`:ask`/`:deny`); a block returns `%{exit: :denied, output: msg}`.
  - Output over 32KB keeps the first/last 16KB plus a marker; the full text is stored by content hash and the marker carries a readable handle (`Newbee.read("spill://<id>")`). Windows that can be reconstructed exactly are returned verbatim, so short or barely-over-budget output is never falsely marked as truncated. In an AI session the command runs on the shared PTY, whose budget is 32KB head + 32KB tail and whose result keeps only the bytes the command wrote (no echo, sentinel line, prompt, ANSI or backspace residue — see `Newbee.Web.Terminal`).
  - The shell runs in its own process group; timeouts, Esc interrupts, or caller death clean up the whole command tree.


  ## Runnable example
      %{exit: 0, output: out} = Newbee.Tools.Run.sh("ls -la")
      %{exit: 0} = Newbee.Tools.Run.sh("mix compile", timeout: 30_000)
      %{output: out} = Newbee.Tools.Run.sh("ls", cd: "/tmp")
      {:ok, out} = Newbee.Tools.Run.mix_compile()
      {:ok, out} = Newbee.Tools.Run.mix_test(["test/newbee/difftest_test.exs"])
      {:ok, out} = Newbee.Tools.Run.mix_format([], timeout: 60_000)

  """

  @default_timeout :infinity
  @dangerous_re ~r/(rm\s+.*-rf|rm\s+-r\s+\/|git\s+push|rm\s+-rf\s+\/)/i

  @doc """
  @doc \"""
  Run a shell command.

  In an AI session this uses that session's shared PTY; pass `shared_terminal: false`
  for host-internal maintenance. `cd:` scopes the working directory to this call only.
  """
  def sh(cmd, opts \\ []) when is_binary(cmd) and is_list(opts) do
    case working_dir(opts) do
      {:ok, dir} ->
        case gate(cmd) do
          {:deny, msg} -> denied(msg)
          :allow -> do_run(dir, cmd, opts)
        end

      {:error, reason} ->
        # Same envelope as every other failure: callers pattern match on %{exit: _}.
        %{exit: :bad_dir, exit_code: :bad_dir, output: reason}
    end
  end

  # A missing working directory must fail loudly: silently running in the project
  # root is how `cd:` used to be ignored.
  defp working_dir(opts) do
    dir = Keyword.get(opts, :cd) || File.cwd!()

    if is_binary(dir) and File.dir?(dir) do
      {:ok, Path.expand(dir)}
    else
      {:error, inspect(dir) <> " is not a directory"}
    end
  end

  defp do_run(dir, cmd, opts) do
    if Keyword.get(opts, :shared_terminal, true) do
      case shared_terminal_context() do
        {:ok, {sid, root}} -> do_terminal_sh(sid, root, cmd, opts, dir)
        :none -> do_sh(cmd, opts, dir)
      end
    else
      do_sh(cmd, opts, dir)
    end
  end

  defp denied(msg), do: %{exit: :denied, exit_code: :denied, output: msg}

  defp gate(cmd) do
    if Regex.match?(@dangerous_re, cmd) do
      case Newbee.Permissions.get() do
        :lenient ->
          :allow

        :ask ->
          {:deny,
           "[denied at ask level — dangerous command needs /permissions lenient or /approve first: " <>
             String.slice(cmd, 0, 120) <> "]"}

        :deny ->
          {:deny, "[denied at deny level — dangerous command blocked: " <> String.slice(cmd, 0, 120) <> "]"}
      end
    else
      :allow
    end
  end

  defp shared_terminal_context do
    token =
      case Process.get({Newbee.Tools.Hive, :context}) do
        %{capability: value} when is_binary(value) -> value
        _ -> Process.get({Newbee.Tools.Media, :capability})
      end

    case token do
      value when is_binary(value) ->
        case Newbee.Host.call(Newbee.Collaboration.Capability, :resolve, [value]) do
          {:ok, %{session_id: sid, project_root: root}} when is_binary(sid) and is_binary(root) ->
            {:ok, {sid, root}}

          _ ->
            :none
        end

      _ ->
        :none
    end
  end

  defp do_terminal_sh(sid, root, cmd, opts, dir) do
    timeout = normalize_timeout(Keyword.get(opts, :timeout, @default_timeout))

    result =
      Newbee.Host.call(Newbee.Web.Terminal, :exec, [sid, root, cmd, timeout, dir], rpc_timeout(timeout))

    case result do
      %{output: _} = value -> value
      {:error, reason} -> %{exit: 127, exit_code: 127, output: "shared terminal failed: " <> inspect(reason)}
      {:badrpc, reason} -> %{exit: 127, exit_code: 127, output: "shared terminal failed: " <> inspect(reason)}
      other -> %{exit: 127, exit_code: 127, output: "shared terminal failed: " <> inspect(other)}
    end
  end

  defp rpc_timeout(:infinity), do: :infinity
  defp rpc_timeout(timeout), do: timeout + 5_000

  defp do_sh(cmd, opts, dir) do
    timeout = normalize_timeout(Keyword.get(opts, :timeout, @default_timeout))
    args = [self(), cmd, timeout, dir]

    result =
      if Newbee.Host.on_main?() do
        apply(Newbee.Host.Command, :run, args)
      else
        :rpc.call(Newbee.Host.main_node(), Newbee.Host.Command, :run, args, :infinity)
      end

    # Ring0 已按 32KB 头尾缓冲截断；远端 badrpc 时补成错误结果。
    case result do
      %{output: _} = result -> result
      {:badrpc, reason} -> %{exit: 127, exit_code: 127, output: "host command failed: " <> inspect(reason)}
    end
  end

  defp normalize_timeout(:infinity), do: :infinity
  defp normalize_timeout(timeout) when is_integer(timeout) and timeout >= 0, do: timeout

  defp normalize_timeout(timeout) do
    raise ArgumentError, "timeout must be a non-negative integer or :infinity, got: #{inspect(timeout)}"
  end

  @doc "Run `mix compile`. Returns `{:ok, output} | {:error, output}`."
  def mix_compile(opts \\ []), do: run_mix(["compile"], opts)

  @doc "Run `mix test` (optional file list). Returns `{:ok, output} | {:error, output}`."
  def mix_test(files \\ [], opts \\ []), do: run_mix(["test" | files], opts)

  @doc "Run `mix format --check-formatted` (optional file list). Returns `{:ok, output} | {:error, output}`."
  def mix_format(files \\ [], opts \\ []), do: run_mix(["format", "--check-formatted" | files], opts)

  defp run_mix(args, opts) do
    result = sh("mix " <> Enum.map_join(args, " ", &shell_quote/1), opts)
    if result.exit == 0, do: {:ok, result.output}, else: {:error, result.output}
  end

  # File names with spaces or shell metacharacters must survive as one argv entry.
  defp shell_quote(arg) when is_binary(arg), do: "'" <> String.replace(arg, "'", "'\\''") <> "'"
  defp shell_quote(arg), do: arg |> to_string() |> shell_quote()
end
