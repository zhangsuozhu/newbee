defmodule Mix.Tasks.Newbee.Gate do
  @shortdoc "单一门禁：编译零警告 + 格式 + 全分区测试 + 架构验收 + 前端套件"
  @moduledoc """
  一条命令跑完第 1 轮定义的全部门禁（G1/G2/G3/G5/G6/G7），聚合退出码并打印失败项清单。

      mix newbee.gate               # 全量门禁：某步失败也继续跑完，最后给出完整清单
      mix newbee.gate --fail-fast   # 首个失败即停（改动期用，省墙钟）
      mix newbee.gate --list        # 只打印步骤表，不执行

  为什么要有它：README 曾把 `mix test.all` 当完整入口，但它既漏跑测试文件、也不含格式与
  前端套件，于是 6 类红灯能合进 main。门禁必须只有一处定义，且宁可慢也不漏。

  步骤（顺序执行；任一步非 0 → 汇总非 0）：

    1. compile-dev   dev 编译零警告（G1）
    2. compile-test  test 编译零警告（G1）
    3. format        mix format --check-formatted（G2）
    4. test-fast     分区回归，覆盖 test/ 下每个测试文件（G3/G7）
    5. acceptance    §15 架构验收（G5）
    6. web-js        node --test test/web/*.test.js（G6；node 缺失=失败，不静默跳过）

  开跑前先做环境体检（`Newbee.GatePreflight`）：磁盘满/负载爆表时，文件系统用例会以
  60s 超时假红，看起来像产品缺陷。体检只在 `:fail` 级（TMPDIR 空间不足）时阻断。

  子进程输出**实时**转发（见 `Newbee.GateStream`），CI 日志能看到分区进度而不是黑箱。
  """

  use Mix.Task

  @web_test_glob "test/web/*.test.js"
  @web_tests_placeholder "{web_tests}"

  @steps [
    %{name: "compile-dev", command: ["mix", "compile", "--warnings-as-errors"], env: [{"MIX_ENV", "dev"}]},
    %{name: "compile-test", command: ["mix", "compile", "--warnings-as-errors"], env: [{"MIX_ENV", "test"}]},
    %{name: "format", command: ["mix", "format", "--check-formatted"], env: []},
    %{name: "test-fast", command: ["mix", "newbee.test_fast"], env: [{"MIX_ENV", "test"}]},
    %{name: "acceptance", command: ["mix", "test.acceptance"], env: [{"MIX_ENV", "test"}]},
    %{name: "web-js", command: ["node", "--test", @web_tests_placeholder], env: [], glob: @web_test_glob}
  ]

  @doc "门禁步骤表（元测试用）：`[%{name, command, env, glob?}]`。"
  def steps, do: @steps

  @doc "把步骤里的通配占位替换成实际测试文件（基于当前目录）。"
  def resolve_command(step), do: resolve_command(step, File.cwd!())

  @doc "同上，显式指定仓库根（元测试用）；通配结果统一转成相对仓库根的路径。"
  def resolve_command(%{command: command} = step, root) do
    if Map.get(step, :glob) do
      Enum.flat_map(command, fn
        @web_tests_placeholder ->
          @web_test_glob
          |> Path.wildcard(base_dir: root)
          |> Enum.map(&Path.relative_to(&1, Path.expand(root)))
          |> Enum.sort()

        other ->
          [other]
      end)
    else
      command
    end
  end

  @doc "某一步的命令是否能解析到真实入口：mix 任务或 alias、node、可执行文件。"
  def entry_problem(%{name: name} = step, root) do
    case resolve_command(step, root) do
      [] ->
        {:error, "#{name}: 解析出空命令"}

      [cmd | args] ->
        cond do
          System.find_executable(cmd) == nil ->
            {:error, "#{name}: 找不到可执行文件 #{cmd}"}

          cmd == "mix" and not mix_entry?(args) ->
            {:error, "#{name}: mix 入口 #{inspect(args)} 既不是任务也不是 alias"}

          cmd == "node" and args == [] ->
            {:error, "#{name}: node 没有测试文件参数"}

          true ->
            :ok
        end
    end
  end

  defp mix_entry?([task | rest]) do
    cond do
      Mix.Task.get(task) != nil -> true
      task in alias_names() -> mix_entry?(rest ++ alias_args(task))
      true -> false
    end
  end

  defp mix_entry?([]), do: true

  defp alias_args(task) do
    Mix.Project.config()
    |> Keyword.get(:aliases, [])
    |> Keyword.get(String.to_atom(task), [])
    |> Enum.flat_map(&String.split(&1, " ", trim: true))
  end

  defp alias_names do
    Mix.Project.config()
    |> Keyword.get(:aliases, [])
    |> Keyword.keys()
    |> Enum.map(&Atom.to_string/1)
  end

  @impl true
  def run(args) do
    {opts, rest, invalid} = OptionParser.parse(args, strict: [fail_fast: :boolean, list: :boolean])

    if rest != [] or invalid != [] do
      Mix.raise("newbee.gate: 未知参数 #{inspect(rest ++ invalid)}（支持 --fail-fast / --list）")
    end

    cond do
      opts[:list] ->
        Enum.each(@steps, fn step ->
          Mix.shell().info("#{step.name}: #{Newbee.GateStream.command_line(resolve_command(step))}")
        end)

        :ok

      System.find_executable("node") == nil ->
        # 前端套件是门禁的一部分：没有 node 就是门禁不完整，必须显式失败。
        Mix.raise("newbee.gate: 找不到 node（前端套件 G6 无法执行），请安装 Node.js 后重跑")

      true ->
        # 环境体检：磁盘满/负载爆表会让文件系统用例以 60s 超时假红（R1 D7/D8 的真实事故）。
        Enum.each(Newbee.GatePreflight.report(), fn line -> Mix.shell().info(line) end)

        case Newbee.GatePreflight.failures() do
          [] ->
            run_steps(opts[:fail_fast] == true)

          failures ->
            Enum.each(failures, fn message -> Mix.shell().error("[gate] preflight failed: #{message}") end)
            Mix.raise("[gate] preflight failed: #{length(failures)} 项环境检查不通过（先修环境再跑门禁）")
        end
    end
  end

  defp run_steps(fail_fast) do
    results =
      Enum.reduce_while(@steps, [], fn step, acc ->
        case resolve_command(step) do
          [] ->
            Mix.shell().error("[gate] #{step.name}: 没有可执行文件（#{@web_test_glob} 未匹配）")
            next(acc, %{name: step.name, exit: 1, output: "", seconds: 0}, fail_fast)

          argv ->
            Mix.shell().info("[gate] start #{step.name}: #{Newbee.GateStream.command_line(argv)}")
            result = run_step(step, argv)
            Mix.shell().info("[gate] #{step.name} exit=#{result.exit} in #{result.seconds}s")
            next(acc, result, fail_fast)
        end
      end)
      |> Enum.reverse()

    failures = Enum.filter(results, &(&1.exit != 0))

    if failures == [] do
      Mix.shell().info("[gate] PASS #{length(results)} steps: #{Enum.map_join(results, ", ", & &1.name)}")
      :ok
    else
      Enum.each(failures, fn failure ->
        Mix.shell().error("[gate] failed: #{failure.name} (exit=#{failure.exit})")
      end)

      Mix.raise("[gate] FAIL #{length(failures)}/#{length(results)}: " <> Enum.map_join(failures, ", ", & &1.name))
    end
  end

  defp next(acc, %{exit: exit} = result, true) when exit != 0, do: {:halt, [result | acc]}
  defp next(acc, result, _fail_fast), do: {:cont, [result | acc]}

  # 实时转发子进程输出：门禁可能跑 2000 s 以上，缓冲到结束既看不到进度也无法判断卡住。
  defp run_step(step, argv) do
    argv
    |> Newbee.GateStream.run(cd: File.cwd!(), env: step.env, io: :stdio)
    |> Map.put(:name, step.name)
  rescue
    error ->
      %{name: step.name, exit: 1, output: Exception.format(:error, error, __STACKTRACE__), seconds: 0}
  end
end
