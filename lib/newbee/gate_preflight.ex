defmodule Newbee.GatePreflight do
  @moduledoc """
  门禁前置体检：把"环境不健康"在开跑前就说清楚，而不是让它在 40 分钟后表现为超时。

  起因（R1 基线 D7/D8）：`root` 分区里 `FsWalkTest`、`TestPartitionCoverageTest` 这类
  纯文件系统用例会以 `ExUnit.TimeoutError ... 60000ms` 红掉，看起来像产品缺陷，实际是
  `/tmp` 100% 满 + 40 个 async 用例抢文件服务队列。相同用例单跑 8 个全过、`TMPDIR`
  指到大盘后 root 分区 348 passed exit=0 —— 唯一真因是环境，必须前置暴露。

  检查项（全部只读，不做任何清理；清理需要人工授权）：
  - `TMPDIR` 可用空间（< `min_free_mb` = 2048 MB → `:fail`，阻断开跑）；
  - 系统负载（1 分钟 loadavg > 核数 × 2 → `:warn`）；
  - `TMPDIR` 下的条目数（> 20_000 → `:warn`：目录扫描会明显变慢）；
  - `git worktree list` 注册数（> 300 → `:warn`：R1 D10 的泄漏仍在累积）。
  """

  # 阈值依据：实测 TMPDIR 只剩 933 MB 时，root 分区出现 3 条 60 s 超时假红
  # （FsWalkTest / TestPartitionCoverageTest）；同一批用例换到大盘 348 passed。
  @min_free_mb 2_048
  @tmp_entry_warn 20_000
  @worktree_warn 300

  @doc """
  返回 `[%{level: :fail | :warn, message: binary}]`；空列表表示环境健康。

  选项：`:tmpdir`（默认 `System.tmp_dir!/0`）、`:min_free_mb`、`:cores`、`:root`。
  """
  def checks(opts \\ []) do
    tmp = Keyword.get(opts, :tmpdir, System.tmp_dir!())

    [free_space(tmp, opts), load(opts), tmp_entries(tmp), worktrees(opts)]
    |> Enum.reject(&is_nil/1)
  end

  @doc "全部 `:fail` 级消息；空列表表示可以开跑。"
  def failures(opts \\ []) do
    for %{level: :fail, message: message} <- checks(opts), do: message
  end

  @doc "格式化成日志行（每行都以 `[gate] preflight` 开头）。"
  def report(opts \\ []) do
    case checks(opts) do
      [] ->
        ["[gate] preflight: ok（TMPDIR 空间、负载、临时目录条目、worktree 注册数都正常）"]

      found ->
        Enum.map(found, fn %{level: level, message: message} ->
          "[gate] preflight #{level}: #{message}"
        end)
    end
  end

  defp free_space(tmp, opts) do
    need = Keyword.get(opts, :min_free_mb, @min_free_mb)

    case df_available_mb(tmp) do
      {:ok, mb} when mb >= need ->
        nil

      {:ok, mb} ->
        %{
          level: :fail,
          message:
            "#{tmp} 只剩 #{mb} MB（门禁下测试需要 >= #{need} MB；" <>
              "先清理磁盘或把 TMPDIR 指到大盘，否则文件系统用例会以 60s 超时假红）"
        }

      :error ->
        %{level: :warn, message: "无法读取 #{tmp} 的可用空间（df 不可用？）"}
    end
  end

  defp load(opts) do
    cores = Keyword.get(opts, :cores, System.schedulers_online())

    case cpu_load() do
      {:ok, value} when value > cores * 2 ->
        %{level: :warn, message: "1 分钟负载 #{Float.round(value, 1)} 远高于 #{cores} 核（时序断言可能抖动）"}

      _ ->
        nil
    end
  end

  defp tmp_entries(tmp) do
    case File.ls(tmp) do
      {:ok, entries} when length(entries) > @tmp_entry_warn ->
        %{
          level: :warn,
          message: "#{tmp} 下有 #{length(entries)} 个条目（> #{@tmp_entry_warn}：目录遍历会明显变慢）"
        }

      _ ->
        nil
    end
  end

  defp worktrees(opts) do
    root = Keyword.get(opts, :root, File.cwd!())
    threshold = Keyword.get(opts, :worktree_warn, @worktree_warn)

    case Newbee.GateStream.run(["git", "worktree", "list", "--porcelain"], cd: root, io: silent()) do
      %{exit: 0, output: output} ->
        count = output |> String.split("\n") |> Enum.count(&String.starts_with?(&1, "worktree "))

        if count > threshold do
          %{
            level: :warn,
            message: "git worktree 已注册 #{count} 条（> #{threshold}：泄漏仍在累积，清理需人工授权）"
          }
        end

      _ ->
        nil
    end
  end

  defp df_available_mb(path) do
    case Newbee.GateStream.run(["df", "-P", "-k", path], io: silent()) do
      %{exit: 0, output: output} ->
        output
        |> String.split("\n", trim: true)
        |> Enum.reverse()
        |> case do
          [line | _] -> parse_df_line(line)
          [] -> :error
        end

      _ ->
        :error
    end
  rescue
    _ -> :error
  end

  defp parse_df_line(line) do
    case String.split(line, ~r/\s+/, trim: true) do
      [_fs, _total, _used, available | _] -> {:ok, div(String.to_integer(available), 1024)}
      _ -> :error
    end
  end

  # 探针输出不进日志：只有体检结论该出现在门禁日志里。
  defp silent do
    {:ok, device} = StringIO.open("")
    device
  end

  defp cpu_load do
    case File.read("/proc/loadavg") do
      {:ok, text} ->
        case String.split(text, " ") do
          [first | _] -> {:ok, parse_float(first)}
          _ -> :error
        end

      _ ->
        :error
    end
  end

  defp parse_float(text) do
    case Float.parse(text) do
      {value, _} -> value
      :error -> 0.0
    end
  end
end
