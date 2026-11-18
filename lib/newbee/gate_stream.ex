defmodule Newbee.GateStream do
  @moduledoc """
  门禁/分区测试的执行器：跑子进程时**实时**转发输出，同时保留完整输出与退出码。

  为什么不用 `System.cmd/3`：它把子进程输出全部缓冲到结束才返回。门禁实际墙钟在
  2000 s 以上、单个分区也能到 600 s，盲等这么久既没法判断"卡住还是慢"，也没法在 CI
  日志上看进度（R1 基线 D8：分区串行 + 逐用例结果不落盘）。这里用 `Port` +
  `:spawn_executable`：边跑边写 `io`，结束时一次拿到退出码。

  `run/2` 返回 `%{output: binary, exit: integer, seconds: integer}`；`output` 与
  `System.cmd(argv, stderr_to_stdout: true)` 的产物同构，可直接替换调用点。
  """

  @doc """
  运行 `argv`（`[executable | args]`），把输出实时写到 `opts[:io]`（默认 `:stdio`）。

  选项：`io:` 输出设备；`env:` `[{key, value}]`（字符串键值）；`cd:` 工作目录。
  """
  def run([cmd | args], opts \\ []) do
    io = Keyword.get(opts, :io, :stdio)
    started = System.monotonic_time(:millisecond)

    case System.find_executable(cmd) do
      nil ->
        %{output: "executable not found: #{cmd}", exit: 127, seconds: 0}

      executable ->
        executable
        |> open(args, opts)
        |> collect(io, [], started)
    end
  end

  @doc "把 `argv` 拼成可读的命令行（日志用）。"
  def command_line(argv), do: Enum.join(argv, " ")

  defp open(executable, args, opts) do
    env =
      opts
      |> Keyword.get(:env, [])
      |> Enum.map(fn {key, value} -> {to_charlist(key), to_charlist(value)} end)

    port_opts = [
      :binary,
      :exit_status,
      :stderr_to_stdout,
      :use_stdio,
      {:args, args},
      {:env, env}
    ]

    port_opts =
      case Keyword.get(opts, :cd) do
        nil -> port_opts
        cd -> [{:cd, to_charlist(cd)} | port_opts]
      end

    Port.open({:spawn_executable, executable}, port_opts)
  end

  defp collect(port, io, acc, started) do
    receive do
      {^port, {:data, data}} ->
        IO.binwrite(io, data)
        collect(port, io, [data | acc], started)

      {^port, {:exit_status, code}} ->
        %{
          output: acc |> Enum.reverse() |> IO.iodata_to_binary(),
          exit: code,
          seconds: div(System.monotonic_time(:millisecond) - started, 1000)
        }
    end
  end
end
