defmodule Mix.Tasks.Newbee.TestFast do
  @shortdoc "Run non-acceptance tests in isolated partitions"
  use Mix.Task

  @partition_specs [
    {"agent-dee", ["test/newbee/agent", "test/newbee/dee"]},
    {"environment", ["test/newbee/environment"]},
    {"llm", ["test/newbee/llm", "test/newbee/codec"]},
    {"tools-tui", ["test/newbee/tools", "test/newbee/tui", "test/newbee/terminal", "test/newbee/truncate"]},
    {"web", ["test/newbee/web"]},
    {"collaboration", ["test/newbee/collaboration"]},
    {"colony", ["test/newbee/colony"]},
    {"plugins-learning", ["test/newbee/plugins", "test/newbee/learning", "test/newbee/evals", "test/newbee/host"]},
    {"root", :root}
  ]

  @doc "分区表（元测试用）：`[{name, paths_or_:root}]`。"
  def partition_specs, do: @partition_specs

  @impl true
  def run(args) do
    if args != [], do: Mix.raise("test.fast does not accept extra arguments")

    Mix.Task.run("compile", ["--warnings-as-errors"])
    root = File.cwd!()
    partitions = partitions(root)

    results =
      partitions
      |> Task.async_stream(
        &run_partition(&1, root),
        max_concurrency: 1,
        ordered: false,
        timeout: :infinity
      )
      |> Enum.map(fn
        {:ok, result} -> result
        {:exit, reason} -> %{name: "unknown", exit: 1, output: inspect(reason)}
      end)

    Enum.each(results, &print_result/1)

    case Enum.filter(results, &(&1.exit != 0)) do
      [] -> :ok
      failed -> Mix.raise("test.fast failed: " <> Enum.map_join(failed, ", ", & &1.name))
    end
  end

  @doc "展开后的分区（元测试用）：每个分区给出相对仓库根的测试文件列表。"
  def partitions(root) do
    Enum.map(@partition_specs, fn
      {"root", :root} -> %{name: "root", files: root_files(root)}
      {name, paths} -> %{name: name, files: dir_files(root, paths)}
    end)
  end

  defp dir_files(root, paths) do
    paths
    |> Enum.flat_map(&Path.wildcard(Path.join([root, &1, "**", "*_test.exs"])))
    |> Enum.filter(&File.regular?/1)
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.map(&Path.relative_to(&1, root))
  end

  defp root_files(root) do
    ["test/newbee/*_test.exs", "test/web_image_test.exs"]
    |> Enum.flat_map(&Path.wildcard(Path.join(root, &1)))
    |> Enum.filter(&File.regular?/1)
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.map(&Path.relative_to(&1, root))
    |> Enum.reject(&(&1 == "test/newbee/acceptance_test.exs"))
  end

  defp run_partition(%{name: name, files: files}, root) do
    Mix.shell().info("[test.fast] start #{name} (#{length(files)} files)")
    args = ["test", "--no-compile", "--warnings-as-errors", "--seed", "1" | files]

    # 实时转发：分区动辄数百秒，缓冲到结束会让人误以为门禁卡死（R1 D8）。
    result =
      ["mix" | args]
      |> Newbee.GateStream.run(cd: root, env: [{"MIX_ENV", "test"}], io: :stdio)

    exit = result.exit
    Mix.shell().info("[test.fast] done #{name} exit=#{exit} in #{result.seconds}s")

    %{name: name, exit: exit, output: result.output, seconds: result.seconds}
  end

  defp print_result(%{name: name, exit: exit, output: output} = result) do
    summary =
      output
      |> String.split("\n")
      |> Enum.filter(
        &(String.contains?(&1, "Result:") or String.contains?(&1, "Failed:") or String.contains?(&1, "Finished in"))
      )
      |> Enum.join(" | ")

    seconds = Map.get(result, :seconds, 0)
    Mix.shell().info("[test.fast] #{name}: exit=#{exit} #{seconds}s #{summary}")

    # 失败分区的完整输出已经实时转发过，这里只重复失败摘要，避免日志翻倍。
    if exit != 0 do
      output
      |> String.split("\n")
      |> Enum.filter(&(String.starts_with?(&1, "  ") or String.contains?(&1, "** (")))
      |> Enum.take(80)
      |> Enum.each(fn line -> Mix.shell().error(line) end)
    end
  end
end
