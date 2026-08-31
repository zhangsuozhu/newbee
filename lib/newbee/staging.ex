defmodule Newbee.Staging do
  @moduledoc """
  编辑暂存区（/approve 流程，DESIGN §5.3）：模型写文件先进暂存，
  用户 `/approve` 统一落盘、`/reject` 丢弃。宽松沙箱的"可回滚"兜底之一。

  存储：`~/.newbee/staging/<id>.json`。条目: %{id, path, content, when, source}。
  """

  use GenServer

  @dir Path.join(System.user_home!(), ".newbee/staging")

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "暂存一个文件写入。返回条目 id。"
  def stage(path, content, source \\ :model) do
    GenServer.call(__MODULE__, {:stage, path, content, source})
  end

  @doc "批准落盘。id = :all | 整数 | 条目 id。返回 {:ok, written_paths} | {:error, :not_staged}。"
  def approve(id \\ :all) do
    GenServer.call(__MODULE__, {:approve, id})
  end

  @doc "丢弃。返回 {:ok, dropped_paths} | {:error, :not_staged}。"
  def reject(id \\ :all) do
    GenServer.call(__MODULE__, {:reject, id})
  end

  @doc "暂存清单（新→旧）。"
  def list do
    GenServer.call(__MODULE__, :list)
  end

  @doc "渲染暂存区为文本（CLI 提示用）。"
  def render do
    list()
    |> Enum.map_join("\n", fn s ->
      "  [#{s.id}] #{s.path}（#{byte_size(s.content)} bytes, #{s.source}）"
    end)
  end

  @impl true
  def init(_) do
    File.mkdir_p!(@dir)
    {:ok, load()}
  end

  @impl true
  def handle_call({:stage, path, content, source}, _from, state) do
    id = :erlang.unique_integer([:positive])
    entry = %{id: id, path: path, content: content, source: source, when: local_iso()}
    state = put_entry(state, entry)
    {:reply, id, state}
  end

  def handle_call({:approve, :all}, _from, state) do
    entries = Map.values(state) |> Enum.sort_by(& &1.id)

    case try_approve_all(entries) do
      {:ok, written} ->
        state = %{}
        persist(state)
        # 用户验收回流（§6.3）：approve 作为真实世界信号进指标/事件日志
        Newbee.Bus.emit(:audit, {:audit, :approved, "user", written, :staging})
        {:reply, {:ok, written}, state}

      {:error, reason} ->
        # 任一条目越界：整体拒绝落盘（原子），暂存区保留
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:approve, id}, _from, state) when is_integer(id) do
    case Map.pop(state, id) do
      {nil, _} ->
        {:reply, {:error, :not_staged}, state}

      {entry, rest} ->
        case try_approve(entry) do
          {:ok, path} ->
            persist(rest)
            Newbee.Bus.emit(:audit, {:audit, :approved, "user", [path], :staging})
            {:reply, {:ok, [path]}, rest}

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end
    end
  end

  def handle_call({:reject, :all}, _from, state) do
    dropped = state |> Map.values() |> Enum.map(& &1.path)
    state = %{}
    persist(state)
    Newbee.Bus.emit(:audit, {:audit, :rejected, "user", dropped, :staging})
    {:reply, {:ok, dropped}, state}
  end

  def handle_call({:reject, id}, _from, state) when is_integer(id) do
    case Map.pop(state, id) do
      {nil, _} ->
        {:reply, {:error, :not_staged}, state}

      {entry, rest} ->
        persist(rest)
        Newbee.Bus.emit(:audit, {:audit, :rejected, "user", [entry.path], :staging})
        {:reply, {:ok, [entry.path]}, rest}
    end
  end

  def handle_call(:list, _from, state) do
    {:reply, state |> Map.values() |> Enum.sort_by(& &1.id), state}
  end

  # 落盘前复核路径（§8 工作目录隔离：工程树或 ~/.newbee 内）
  defp try_approve_all(entries) do
    Enum.reduce_while(entries, {:ok, []}, fn e, {:ok, acc} ->
      case try_approve(e) do
        {:ok, path} -> {:cont, {:ok, [path | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, paths} -> {:ok, Enum.reverse(paths)}
      other -> other
    end
  end

  defp try_approve(entry) do
    path = entry[:path] || entry["path"]
    content = entry[:content] || entry["content"]
    Newbee.Tools.Fs.guard_path!(path)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, content || "")
    {:ok, path}
  rescue
    e in ArgumentError -> {:error, {:outside_project, Exception.message(e)}}
    _ -> {:error, :outside_project}
  end

  defp put_entry(state, entry) do
    state = Map.put(state, entry.id, entry)
    persist(state)
    state
  end

  defp persist(state) do
    File.mkdir_p!(@dir)
    # 简单：每个条目一个文件
    existing = Path.wildcard(Path.join(@dir, "*.json"))
    keep = Map.keys(state) |> MapSet.new()

    Enum.each(existing, fn f ->
      if f |> Path.basename(".json") |> String.to_integer() |> then(&(not MapSet.member?(keep, &1))) do
        File.rm(f)
      end
    end)

    Enum.each(state, fn {id, entry} ->
      File.write!(Path.join(@dir, "#{id}.json"), Jason.encode_to_iodata!(entry))
    end)
  end

  defp load do
    @dir
    |> Path.join("*.json")
    |> Path.wildcard()
    |> Enum.reduce(%{}, fn f, acc ->
      case File.read(f) do
        {:ok, body} ->
          case Jason.decode(body) do
            {:ok, entry} when is_map(entry) ->
              # JSON 回来是 string-key，归一成 atom-key（与 stage 路径一致）
              entry = %{
                id: entry["id"],
                path: entry["path"],
                content: entry["content"] || "",
                source: String.to_atom(entry["source"] || "model"),
                when: entry["when"]
              }

              Map.put(acc, entry.id, entry)

            _ ->
              acc
          end

        _ ->
          acc
      end
    end)
  end

  defp local_iso do
    {{y, m, d}, {h, mi, s}} = :calendar.local_time()
    :io_lib.format("~4..0B-~2..0B-~2..0BT~2..0B:~2..0B:~2..0B", [y, m, d, h, mi, s]) |> IO.iodata_to_binary()
  end
end
