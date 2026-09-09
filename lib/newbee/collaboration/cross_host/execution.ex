defmodule Newbee.Collaboration.CrossHost.Execution do
  @moduledoc "本地执行隔离：每任务独立目录、源码快照、日志、启停、断线恢复同任务。"
  @spec start(map(), map()) :: {:ok, map()} | {:error, term(), term()}
  def start(task, opts) when is_map(task) and is_map(opts) do
    base = Map.get(opts, "base_dir", System.tmp_dir())
    tid = Map.get(task, "id", "t_unknown")
    dir = Path.join([base, "xh-" <> tid])
    File.mkdir_p!(dir)
    files = Map.get(opts, "files", %{})
    Enum.each(files, fn {rel, content} ->
      p = Path.join(dir, rel)
      File.mkdir_p!(Path.dirname(p))
      File.write!(p, content)
    end)
    exec = %{"task_id" => tid, "dir" => dir, "status" => "running", "log" => [], "preview" => nil, "version" => Map.get(opts, "version", 1)}
    {:ok, exec}
  end
  @spec append_log(map(), binary()) :: map()
  def append_log(exec, line) when is_map(exec) and is_binary(line) do
    Map.update(exec, "log", [line], fn l -> l ++ [line] end)
  end
  @spec attach_preview(map(), binary(), integer()) :: {:ok, map()} | {:error, term(), term()}
  def attach_preview(exec, bind, port) when is_map(exec) and is_binary(bind) and is_integer(port) do
    alias Newbee.Collaboration.CrossHost.Firewall
    if Firewall.preview_bind_ok?(bind) do
      {:ok, Map.put(exec, "preview", %{"bind" => bind, "port" => port})}
    else
      {:error, "preview_exposed", "预览只允许回环"}
    end
  end
  @spec stop(map()) :: map()
  def stop(exec) when is_map(exec), do: Map.put(exec, "status", "stopped")
  @spec resume(map()) :: map()
  def resume(exec) when is_map(exec), do: exec
  @spec cleanup(map()) :: :ok
  def cleanup(exec) when is_map(exec) do
    case Map.get(exec, "dir") do
      nil -> :ok
      dir -> File.rm_rf!(dir); :ok
    end
  end
end
