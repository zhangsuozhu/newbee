defmodule Newbee.Tools.Edit.SnapshotStore do
  @moduledoc """
  跨求值进程和 BEAM 节点共享的文件快照存储（Edit，docs/edit-design.md §4.1/§9）。

  `show` 和 `patch` 可能由不同求值进程执行，因此快照保存到共享的 `.newbee`
  状态目录；进程内 ETS 只作为缓存。标签用于版本校验，内容不会执行或解析。
  """

  @max_paths 64
  @max_versions 8
  @tag_bytes 6
  @table :newbee_edit_snapshots

  @enforce_keys [:text, :hash, :path, :recorded_at]
  defstruct [:text, :hash, :path, :recorded_at, lines: 0, seen: MapSet.new(), has_trailing: true]

  @type t :: %__MODULE__{
          text: String.t(),
          hash: String.t(),
          path: String.t(),
          recorded_at: integer(),
          lines: non_neg_integer(),
          seen: MapSet.t(non_neg_integer()),
          has_trailing: boolean()
        }

  @doc "记录快照，返回标签；同内容重复记录合并已读范围。"
  @spec record(String.t(), String.t(), Enumerable.t()) :: String.t()
  def record(path, text, seen_lines \\ []) do
    with_store(fn store ->
      {lines, has_trailing} = split_lines(text)
      hash = content_hash(text)
      history = Map.get(store, path, [])

      next =
        case Enum.find_index(history, &(&1.hash == hash)) do
          nil ->
            snap = %__MODULE__{
              text: text,
              hash: hash,
              path: path,
              recorded_at: System.system_time(:millisecond),
              lines: length(lines),
              seen: MapSet.new(seen_lines),
              has_trailing: has_trailing
            }

            Map.put(store, path, (history ++ [snap]) |> Enum.take(-@max_versions))

          idx ->
            snap = Enum.at(history, idx)
            updated = %{snap | seen: MapSet.union(snap.seen, MapSet.new(seen_lines))}
            Map.put(store, path, List.replace_at(history, idx, updated))
        end

      {hash, lru_touch(next, path)}
    end)
  end

  @doc "按标签取该路径快照。"
  @spec fetch(String.t(), String.t()) :: t() | nil
  def fetch(path, tag), do: history(path) |> Enum.reverse() |> Enum.find(&(&1.hash == tag))

  @doc "标签是否已知。"
  @spec known?(String.t(), String.t()) :: boolean()
  def known?(path, tag), do: fetch(path, tag) != nil

  @doc "合并已展示行。"
  @spec mark_seen(String.t(), String.t(), Enumerable.t()) :: :ok | :unknown_snapshot
  def mark_seen(path, tag, lines) do
    with_store(fn store ->
      history = Map.get(store, path, [])

      case Enum.find_index(history, &(&1.hash == tag)) do
        nil ->
          {:unknown_snapshot, store}

        idx ->
          snap = Enum.at(history, idx)
          updated = %{snap | seen: MapSet.union(snap.seen, MapSet.new(lines))}
          {:ok, lru_touch(Map.put(store, path, List.replace_at(history, idx, updated)), path)}
      end
    end)
  end

  @doc "提交后登记新版本（全行已读），返回新标签。"
  @spec promote(String.t(), String.t()) :: String.t()
  def promote(path, new_text) do
    with_store(fn store ->
      {lines, has_trailing} = split_lines(new_text)
      hash = content_hash(new_text)
      history = Map.get(store, path, [])

      snap = %__MODULE__{
        text: new_text,
        hash: hash,
        path: path,
        recorded_at: System.system_time(:millisecond),
        lines: length(lines),
        seen: MapSet.new(1..max(length(lines), 1)//1),
        has_trailing: has_trailing
      }

      {hash, lru_touch(Map.put(store, path, (history ++ [snap]) |> Enum.take(-@max_versions)), path)}
    end)
  end

  @doc "清空快照（测试用）。"
  def clear do
    ensure_table()
    :ets.delete_all_objects(@table)
    File.rm(snapshot_path())
    :ok
  end

  defp history(path), do: get_store() |> Map.get(path, [])

  defp get_store do
    ensure_table()

    case :ets.lookup(@table, :store) do
      [{:store, store}] ->
        store

      [] ->
        store = read_store()
        :ets.insert(@table, {:store, store})
        store
    end
  end

  defp put_store(store) do
    ensure_table()
    trimmed = lru_trim(store)
    :ets.insert(@table, {:store, trimmed})
    write_store(trimmed)
    trimmed
  end

  defp with_store(fun) do
    # The file is the cross-node source of truth. A global lock protects
    # concurrent writers when nodes share the same Erlang distribution.
    lock = {__MODULE__, :snapshot_store}

    transaction = fn ->
      store = read_store()
      {result, next_store} = fun.(store)
      put_store(next_store)
      result
    end

    if Node.alive?(), do: :global.trans(lock, transaction), else: transaction.()
  end

  defp ensure_table do
    case :ets.whereis(@table) do
      :undefined ->
        try do
          :ets.new(@table, [:named_table, :public, :set, read_concurrency: true, write_concurrency: true])
        rescue
          ArgumentError -> @table
        end

      _tid ->
        @table
    end
  end

  defp snapshot_path do
    Path.join(Newbee.GlobalStore.root(), "edit_snapshots.term")
  end

  defp read_store do
    case File.read(snapshot_path()) do
      {:ok, binary} ->
        try do
          :erlang.binary_to_term(binary, [:safe])
        rescue
          _ -> %{}
        end

      {:error, :enoent} ->
        %{}

      {:error, _reason} ->
        %{}
    end
  end

  defp write_store(store) do
    path = snapshot_path()
    File.mkdir_p!(Path.dirname(path))
    temp = path <> ".tmp." <> Integer.to_string(System.unique_integer([:positive]))

    try do
      File.write!(temp, :erlang.term_to_binary(store, [:compressed]))
      File.rename!(temp, path)
      :ok
    rescue
      _ ->
        File.rm(temp)
        :ok
    end
  end

  defp lru_trim(store) do
    paths = store |> Enum.filter(fn {key, _} -> not match?({:lru, _}, key) end) |> Enum.map(fn {key, _} -> key end)

    if length(paths) <= @max_paths do
      store
    else
      drop =
        paths
        |> Enum.map(fn path -> {path, Map.get(store, {:lru, path}, 0)} end)
        |> Enum.sort_by(fn {_path, time} -> time end)
        |> Enum.take(length(paths) - @max_paths)
        |> Enum.map(fn {path, _time} -> path end)

      store |> Map.drop(drop) |> Map.drop(Enum.map(drop, &{:lru, &1}))
    end
  end

  defp lru_touch(store, path), do: Map.put(store, {:lru, path}, System.system_time(:millisecond))

  defp content_hash(text), do: :crypto.hash(:sha256, text) |> binary_part(0, @tag_bytes) |> Base.encode16(case: :lower)

  defp split_lines(content) do
    has_trailing = String.ends_with?(content, "\n")
    lines = String.split(content, "\n", trim: false)
    lines = if has_trailing and lines != [], do: Enum.drop(lines, -1), else: lines
    {lines, has_trailing}
  end
end
