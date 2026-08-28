defmodule Newbee.Tools.Run do
  @moduledoc """
  命令执行工具 (DESIGN §3.2)：超时 + 输出上限，结果返回 exit code 与输出。

  ## 函数清单
  - `sh(cmd, opts \\ [])` — 在工程根下执行 shell 命令，返回 `%{exit: integer() | :timeout | :denied, exit_code: integer() | :timeout | :denied, output: String.t()}`。
    选项：`timeout:` 毫秒（默认 120_000），`cd` 固定为 `File.cwd!()`，`MIX_ENV=test`。
  - `sh_long(cmd, opts \\ [])` — `sh` 的长超时版，默认 180_000ms，适合 harness/全量测试。
  - `mix_compile(opts \\ [])` — `mix compile`，返回 `{:ok, output} | {:error, output}`。
  - `mix_test(files \\ [], opts \\ [])` — `mix test [files...]`，返回 `{:ok, output} | {:error, output}`。
  - `mix_format(files \\ [])` — `mix format --check-formatted [files...]`，返回 `{:ok, output} | {:error, output}`。
  - `django_test(args \\ "apps.ha_bridge", opts \\ [])` — Django 场景：自动选 `python3.11`（无 `cgi` 时）跑 `BackCode/manage.py test`。

  ## 权限与截断
  - 高危命令（`rm -rf /`, `git push` 等）受 `Newbee.Permissions` 档位（`:lenient`/`:ask`/`:deny`）拦截，拦截时返回 `%{exit: :denied, exit_code: :denied, output: msg}`。
  - 输出超 32KB 自动截断为头尾各 16KB + `… [输出截断]`。

  ## 可跑示例
      %{exit: 0, exit_code: 0, output: out} = Newbee.Tools.Run.sh("ls -la")
      %{exit: 0} = Newbee.Tools.Run.sh("mix compile", timeout: 30_000)
      {:ok, out} = Newbee.Tools.Run.mix_compile()
      {:ok, out} = Newbee.Tools.Run.mix_test(["test/newbee/difftest_test.exs"])
      {:ok, out} = Newbee.Tools.Run.mix_format()
      %{exit: 0} = Newbee.Tools.Run.sh_long("mix test 2>&1 | tail -n 20", timeout: 180_000)

  """

  @default_timeout 120_000
  @max_output 32_000

  @dangerous_re ~r/(rm\s+.*-rf|rm\s+-r\s+\/|git\s+push|rm\s+-rf\s+\/)/i

  @doc "在工程根下执行 shell 命令。返回 %{exit, exit_code, output}；exit_code 是 exit 的直觉别名。"
  def sh(cmd, opts \\ []) do
    case gate(cmd) do
      :allow -> do_sh(cmd, opts)
      {:deny, msg} -> %{exit: :denied, exit_code: :denied, output: msg}
    end
  end

  defp gate(cmd) do
    if Regex.match?(@dangerous_re, cmd) do
      case Newbee.Permissions.get() do
        :lenient ->
          :allow

        :ask ->
          {:deny, "[denied: ask 档 — 高危命令需 /permissions lenient 或 /approve 后执行: " <> String.slice(cmd, 0, 120) <> "]"}

        :deny ->
          {:deny, "[denied: deny 档 — 高危命令已拦截: " <> String.slice(cmd, 0, 120) <> "]"}
      end
    else
      :allow
    end
  end

  defp do_sh(cmd, opts) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)

    task =
      Task.async(fn ->
        System.cmd("sh", ["-c", cmd],
          cd: File.cwd!(),
          stderr_to_stdout: true,
          env: [{"MIX_ENV", "test"}]
        )
      end)

    case Task.yield(task, timeout) do
      {:ok, {out, code}} ->
        %{exit: code, exit_code: code, output: truncate(out)}

      nil ->
        Task.shutdown(task, :brutal_kill)
        %{exit: :timeout, exit_code: :timeout, output: ""}
    end
  end

  @doc "跑 mix compile。返回 {:ok, output} | {:error, output}。"
  def mix_compile(opts \\ []) do
    result = sh("mix compile", opts)
    if result.exit == 0, do: {:ok, result.output}, else: {:error, result.output}
  end

  @doc "跑 mix test（可传文件列表）。返回 {:ok, output} | {:error, output}。"
  def mix_test(files \\ [], opts \\ []) do
    cmd = "mix test " <> Enum.join(files, " ")
    result = sh(cmd, opts)
    if result.exit == 0, do: {:ok, result.output}, else: {:error, result.output}
  end

  @doc "跑 mix format 检查。返回 {:ok, output} | {:error, output}。"
  def mix_format(files \\ []) do
    cmd = "mix format --check-formatted " <> Enum.join(files, " ")
    result = sh(cmd)
    if result.exit == 0, do: {:ok, result.output}, else: {:error, result.output}
  end

  @doc "Django test helper: auto picks python3.11 when cgi missing."
  def django_test(args \\ "apps.ha_bridge", opts \\ []) do
    py = if System.find_executable("python3.11"), do: "python3.11", else: "python3"
    sh(py <> " BackCode/manage.py test " <> args, opts)
  end

  @doc "Long-running variant: default 180s for harness run-group."
  def sh_long(cmd, opts \\ []) do
    sh(cmd, Keyword.put_new(opts, :timeout, 180_000))
  end

  defp truncate(s) when byte_size(s) <= @max_output, do: s

  defp truncate(s) do
    head = binary_part(s, 0, div(@max_output, 2))
    tail = binary_part(s, byte_size(s) - div(@max_output, 2), div(@max_output, 2))
    head <> "\n… [输出截断: " <> to_string(byte_size(s)) <> " bytes] …\n" <> tail
  end
end
