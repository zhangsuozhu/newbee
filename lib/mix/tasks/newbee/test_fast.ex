defmodule Mix.Tasks.Newbee.TestFast do
  @shortdoc "Run non-acceptance tests in isolated partitions"
  use Mix.Task

  @partition_specs [
    {"agent-dee", ["test/newbee/agent", "test/newbee/dee"]},
    {"environment", ["test/newbee/environment"]},
    {"llm", ["test/newbee/llm"]},
    {"tools-tui", ["test/newbee/tools", "test/newbee/tui"]},
    {"web", ["test/newbee/web"]},
    {"collaboration", ["test/newbee/collaboration"]},
    {"root", :root}
  ]

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

  defp partitions(root) do
    Enum.map(@partition_specs, fn
      {"root", :root} -> %{name: "root", files: root_files(root)}
      {name, paths} -> %{name: name, files: paths}
    end)
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

    {output, exit} =
      System.cmd("mix", args,
        cd: root,
        env: [{"MIX_ENV", "test"}],
        stderr_to_stdout: true
      )

    Mix.shell().info("[test.fast] done #{name} exit=#{exit}")

    if exit != 0, do: Mix.shell().error(output)

    %{name: name, exit: exit, output: output}
  end

  defp print_result(%{name: name, exit: exit, output: output}) do
    summary =
      output
      |> String.split("\n")
      |> Enum.filter(
        &(String.contains?(&1, "Result:") or String.contains?(&1, "Failed:") or String.contains?(&1, "Finished in"))
      )
      |> Enum.join(" | ")

    Mix.shell().info("[test.fast] #{name}: exit=#{exit} #{summary}")

    if exit != 0 do
      Mix.shell().error(output)
    end
  end
end
