defmodule Newbee.Tools.Edit.SnapshotStore do
  @moduledoc """
  会话级文件快照存储（Edit，docs/edit-design.md §4.1/§9）。

  record 记录完整规范化文本，返回 12 hex 会话标签；
  fetch/mark_seen/promote 供 v2 补丁层做版本校验与已读范围约束。
  进程字典存储（DEE 每会话独立节点），LRU 裁剪路径数，每路径保留最近版本环。
  """

  @max_paths 64
  @max_versions 8
  @tag_bytes 6

  @enforce_keys [:text, :hash, :path, :recorded_at]
  defstruct [:text, :hash, :path, :recorded_at, lines: 0, seen: MapSet.new(), has_trailing: true]

  @type t :: %__MODULE__{
          text: String.t(),
          hash: String.t(),
          path: String.t(),
          recorded_at: integer(),
          lines: pos_integer(),
          seen: MapSet.t(pos_integer()),
          has_trailing: boolean()
        }

  @doc "记录快照，返回标签；同内容重复记录合并 seen（读融合）。"
  @spec record(String.t(), String.t(), Enumerable.t()) :: String.t()
  def record(path, text, seen_lines \\ []) do
    {lines, has_trailing} = split_lines(text)
    hash = content_hash(text)
    store = get_store()
    history = Map.get(store, path, [])

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

        put_store(store |> Map.put(path, history ++ [snap] |> Enum.take(-@max_versions)) |> lru_touch(path))
        hash

      idx ->
        snap = Enum.at(history, idx)
        snap2 = %{snap | seen: MapSet.union(snap.seen, MapSet.new(seen_lines))}
        put_store(store |> Map.put(path, List.replace_at(history, idx, snap2)) |> lru_touch(path))
        hash
    end
  end

  @doc "按标签取该路径最新匹配快照。"
  @spec fetch(String.t(), String.t()) :: t() | nil
  def fetch(path, tag), do: path |> history() |> Enum.reverse() |> Enum.find(&(&1.hash == tag))

  @doc "标签是否已知。"
  @spec known?(String.t(), String.t()) :: boolean()
  def known?(path, tag), do: fetch(path, tag) != nil

  @doc "合并已展示行。"
  @spec mark_seen(String.t(), String.t(), Enumerable.t()) :: :ok | :unknown_snapshot
  def mark_seen(path, tag, lines) do
    store = get_store()
    history = Map.get(store, path, [])

    idx = Enum.find_index(history, &(&1.hash == tag))

    if idx == nil do
      :unknown_snapshot
    else
      snap = Enum.at(history, idx)
      snap2 = %{snap | seen: MapSet.union(snap.seen, MapSet.new(lines))}
      put_store(%{store | path => List.replace_at(history, idx, snap2)})
      :ok
    end
  end

  @doc "提交后登记新版本（全行 seen），返回新标签。"
  @spec promote(String.t(), String.t()) :: String.t()
  def promote(path, new_text) do
    {lines, has_trailing} = split_lines(new_text)
    hash = content_hash(new_text)
    store = get_store()
    history = Map.get(store, path, [])

    snap = %__MODULE__{
      text: new_text,
      hash: hash,
      path: path,
      recorded_at: System.system_time(:millisecond),
      lines: length(lines),
      seen: MapSet.new(1..length(lines)//1),
      has_trailing: has_trailing
    }

    put_store(store |> Map.put(path, history ++ [snap] |> Enum.take(-@max_versions)) |> lru_touch(path))
    hash
  end

  @doc "清空（测试用）。"
  def clear, do: put_store(%{})

  defp history(path), do: get_store() |> Map.get(path, [])
  defp get_store, do: Process.get(:newbee_edit_snapshots) || %{}

  defp put_store(store) do
    Process.put(:newbee_edit_snapshots, lru_trim(store))
    store
  end

  defp lru_touch(store, path), do: Map.put(store, {:lru, path}, System.system_time(:millisecond))

  defp lru_trim(store) do
    paths = store |> Enum.filter(fn {k, _} -> not match?({:lru, _}, k) end) |> Enum.map(fn {k, _} -> k end)

    if length(paths) <= @max_paths do
      store
    else
      drop =
        paths
        |> Enum.map(fn p -> {p, Map.get(store, {:lru, p}, 0)} end)
        |> Enum.sort_by(fn {_p, t} -> t end)
        |> Enum.take(length(paths) - @max_paths)
        |> Enum.map(fn {p, _} -> p end)

      store |> Map.drop(drop) |> Map.drop(Enum.map(drop, &{:lru, &1}))
    end
  end

  defp content_hash(text), do: :crypto.hash(:sha256, text) |> binary_part(0, @tag_bytes) |> Base.encode16(case: :lower)

  defp split_lines(content) do
    has_trailing = String.ends_with?(content, "\n")
    lines = String.split(content, "\n", trim: false)
    lines = if has_trailing and lines != [], do: Enum.drop(lines, -1), else: lines
    {lines, has_trailing}
  end
end
