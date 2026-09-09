defmodule Newbee.Collaboration.CrossHost.Scheduler do
  @moduledoc "调度：能力检测、配额、过滤、三机汇总。只用同群获准设备。"
  @spec detect() :: map()
  def detect do
    {fam, name} = :os.type()
    arch = :erlang.system_info(:system_architecture) |> inspect()
    nv = tool_ver("node", "--version")
    %{
      "os" => inspect(fam) <> "/" <> inspect(name),
      "arch" => arch,
      "elixir_ok" => true,
      "elixir_ver" => System.version(),
      "node_ok" => nv != "",
      "node_ver" => nv,
      "docker_ok" => tool_present("docker"),
      "isolation" => isolation_backend(),
      "isolation_ready" => isolation_backend() != "none"
    }
  end
  @spec default_quota() :: map()
  def default_quota, do: %{"max_concurrent" => 2, "host_max_total" => 8}
  @spec eligible?(map(), map(), map(), map()) :: term()
  def eligible?(device, caps, task, usage) when is_map(device) and is_map(caps) and is_map(task) and is_map(usage) do
    with false <- Map.get(device, "paused", false),
         true <- Map.get(caps, "isolation_ready", false) == true,
         true <- caps_ok?(caps, Map.get(task, "requires", %{})),
         true <- quota_ok?(usage) do
      true
    else
      _ -> false
    end
  end
  def eligible?(_, _, _, _), do: false
  @spec select([map()], map(), map()) :: [map()]
  def select(devices, caps_by_id, task) when is_list(devices) and is_map(caps_by_id) and is_map(task) do
    Enum.filter(devices, fn d ->
      caps = Map.get(caps_by_id, Map.get(d, "id", ""), %{})
      usage = Map.get(caps_by_id, "__usage__" <> Map.get(d, "id", ""), %{"running" => 0, "host_running" => 0})
      eligible?(d, caps, task, usage)
    end)
  end
  @spec aggregate([map()]) :: map()
  def aggregate(results) when is_list(results) do
    counts = Enum.reduce(results, %{"ok" => 0, "failed" => 0, "unexecuted" => 0, "na" => 0, "total" => 0}, fn r, acc ->
      s = Map.get(r, "status", "na")
      key = cond do
        s == "ok" or s == :ok -> "ok"
        s == "failed" or s == :failed -> "failed"
        s == "unexecuted" or s == :unexecuted -> "unexecuted"
        true -> "na"
      end
      acc |> Map.update(key, 1, fn v -> v + 1 end) |> Map.update("total", 1, fn v -> v + 1 end)
    end)
    Map.put(counts, "all_ok", counts["failed"] == 0 and counts["unexecuted"] == 0 and counts["total"] > 0)
  end
  defp caps_ok?(_caps, requires) when map_size(requires) == 0, do: true
  defp caps_ok?(caps, requires) when is_map(requires) do
    Enum.all?(requires, fn
      {"elixir", _} -> Map.get(caps, "elixir_ok", false) == true
      {"node", _} -> Map.get(caps, "node_ok", false) == true
      {"docker", _} -> Map.get(caps, "docker_ok", false) == true
      {"os", want} -> String.contains?(Map.get(caps, "os", ""), if(is_atom(want), do: inspect(want), else: want))
      {"arch", want} -> String.contains?(Map.get(caps, "arch", ""), if(is_atom(want), do: inspect(want), else: want))
      _ -> true
    end)
  end
  defp quota_ok?(usage) do
    running = Map.get(usage, "running", 0)
    host = Map.get(usage, "host_running", 0)
    q = default_quota()
    is_integer(running) and is_integer(host) and running < q["max_concurrent"] and host < q["host_max_total"]
  end
  defp tool_present(bin) do
    case System.find_executable(bin) do
      nil -> false
      _ -> true
    end
  end
  defp tool_ver(bin, arg) do
    case System.find_executable(bin) do
      nil -> ""
      path ->
        case System.cmd(path, [arg], stderr_to_stdout: true) do
          {out, 0} -> String.trim(out) |> String.slice(0, 64)
          _ -> ""
        end
    end
  end
  defp isolation_backend do
    cond do
      tool_present("docker") -> "docker"
      System.get_env("XH_TEST_ISOLATION") == "1" -> "test"
      true -> "none"
    end
  end
end
