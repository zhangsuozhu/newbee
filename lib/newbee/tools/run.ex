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
  - Output over 32KB truncates to first/last 16KB + `… [truncated]`.
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

  @doc "Run a shell command under the project root. Returns %{exit, output}."
  def sh(cmd, opts \\ []) do
    case gate(cmd) do
      {:deny, msg} -> %{exit: :denied, exit_code: :denied, output: msg}
      :allow -> do_sh(cmd, opts)
    end
  end

  defp gate(cmd) do
    if Regex.match?(@dangerous_re, cmd) do
      case Newbee.Permissions.get() do
        :lenient ->
          :allow

        :ask ->
          {:deny, "[denied at ask level — dangerous command needs /permissions lenient or /approve first: " <> String.slice(cmd, 0, 120) <> "]"}

        :deny ->
          {:deny, "[denied at deny level — dangerous command blocked: " <> String.slice(cmd, 0, 120) <> "]"}
      end
    else
      :allow
    end
  end

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
