defmodule Newbee.Tools.Run do
  @moduledoc """
  General shell commands; prefer higher-level tools (Git/Scaffold, …) when they fit.

  ## Functions
  - `sh(cmd, opts \\\\ [])` — run a shell command under the project root; returns `%{exit: integer() | :timeout | :denied, exit_code: integer() | :timeout | :denied, output: String.t()}` (`exit_code` aliases `exit` for backward compat).
    Options: `timeout:` millis or `:infinity` (default `:infinity`); `cd` pinned to `File.cwd!()`.

  - `mix_compile(opts \\\\ [])` — `mix compile`; `{:ok, output} | {:error, output}`.
  - `mix_test(files \\\\ [], opts \\\\ [])` — `mix test [files...]`; `{:ok, output} | {:error, output}`.
  - `mix_format(files \\\\ [])` — `mix format --check-formatted [files...]`; `{:ok, output} | {:error, output}`.

  ## Permissions and truncation
  - Dangerous commands (`rm -rf /`, `git push`, …) are gated by the `Newbee.Permissions` level (`:lenient`/`:ask`/`:deny`); a block returns `%{exit: :denied, output: msg}`.
  - Output over 32KB keeps the first/last 16KB plus a marker; the full text is stored by content hash and the marker carries a readable handle (`Newbee.read("spill://<id>")`). Windows that can be reconstructed exactly are returned verbatim, so short or barely-over-budget output is never falsely marked as truncated.

  - The shell runs in its own process group; timeouts, Esc interrupts, or caller death clean up the whole command tree.


  ## Runnable example
      %{exit: 0, output: out} = Newbee.Tools.Run.sh("ls -la")
      %{exit: 0} = Newbee.Tools.Run.sh("mix compile", timeout: 30_000)
      {:ok, out} = Newbee.Tools.Run.mix_compile()
      {:ok, out} = Newbee.Tools.Run.mix_test(["test/newbee/difftest_test.exs"])
      {:ok, out} = Newbee.Tools.Run.mix_format()
  """

  @default_timeout :infinity

  @dangerous_re ~r/(rm\s+.*-rf|rm\s+-r\s+\/|git\s+push|rm\s+-rf\s+\/)/i

  @doc "Run a shell command. In an AI session this uses that session's shared PTY; pass shared_terminal: false for host-internal maintenance."
  def sh(cmd, opts \\ []) do
    case gate(cmd) do
      {:deny, msg} ->
        %{exit: :denied, exit_code: :denied, output: msg}

      :allow ->
        if Keyword.get(opts, :shared_terminal, true) do
          case shared_terminal_context() do
            {:ok, {sid, root}} -> do_terminal_sh(sid, root, cmd, opts)
            :none -> do_sh(cmd, opts)
          end
        else
          do_sh(cmd, opts)
        end
    end
  end

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

  defp do_terminal_sh(sid, root, cmd, opts) do
    timeout = normalize_timeout(Keyword.get(opts, :timeout, @default_timeout))
    result = Newbee.Host.call(Newbee.Web.Terminal, :exec, [sid, root, cmd, timeout], rpc_timeout(timeout))

    case result do
      %{output: _} = value -> value
      {:error, reason} -> %{exit: 127, exit_code: 127, output: "shared terminal failed: #{inspect(reason)}"}
      {:badrpc, reason} -> %{exit: 127, exit_code: 127, output: "shared terminal failed: #{inspect(reason)}"}
      other -> %{exit: 127, exit_code: 127, output: "shared terminal failed: #{inspect(other)}"}
    end
  end

  defp rpc_timeout(:infinity), do: :infinity
  defp rpc_timeout(timeout), do: timeout + 5_000

  defp do_sh(cmd, opts) do
    timeout = normalize_timeout(Keyword.get(opts, :timeout, @default_timeout))
    args = [self(), cmd, timeout, File.cwd!()]

    result =
      if Newbee.Host.on_main?() do
        apply(Newbee.Host.Command, :run, args)
      else
        :rpc.call(Newbee.Host.main_node(), Newbee.Host.Command, :run, args, :infinity)
      end

    # Ring0 已按 32KB 头尾缓冲截断；远端 badrpc 时补成错误结果。
    case result do
      %{output: _} = result -> result
      {:badrpc, reason} -> %{exit: 127, exit_code: 127, output: "host command failed: #{inspect(reason)}"}
    end
  end

  defp normalize_timeout(:infinity), do: :infinity
  defp normalize_timeout(timeout) when is_integer(timeout) and timeout >= 0, do: timeout

  defp normalize_timeout(timeout) do
    raise ArgumentError, "timeout must be a non-negative integer or :infinity, got: #{inspect(timeout)}"
  end

  @doc "Run mix compile. Returns {:ok, output} | {:error, output}."
  def mix_compile(opts \\ []) do
    result = sh("mix compile", opts)
    if result.exit == 0, do: {:ok, result.output}, else: {:error, result.output}
  end

  @doc "Run mix test (optional file list). Returns {:ok, output} | {:error, output}."
  def mix_test(files \\ [], opts \\ []) do
    cmd = "mix test " <> Enum.join(files, " ")
    result = sh(cmd, opts)
    if result.exit == 0, do: {:ok, result.output}, else: {:error, result.output}
  end

  @doc "Run a mix format check. Returns {:ok, output} | {:error, output}."
  def mix_format(files \\ []) do
    cmd = "mix format --check-formatted " <> Enum.join(files, " ")
    result = sh(cmd)
    if result.exit == 0, do: {:ok, result.output}, else: {:error, result.output}
  end
end
