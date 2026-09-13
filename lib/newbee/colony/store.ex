defmodule Newbee.Colony.Store do
  @moduledoc "Serialized durable Colony state; disk failure never acknowledges a mutation."
  use GenServer

  @tables ~w(colonies bees tasks honey trace signals controls deliveries identities conversations invites remote_reports pending_messages)

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def ensure do
    if Process.whereis(__MODULE__) == nil do
      case GenServer.start(__MODULE__, [], name: __MODULE__) do
        {:ok, _} -> :ok
        {:error, {:already_started, _}} -> :ok
        {:error, reason} -> raise inspect(reason)
      end
    end

    :ok
  end

  defp call(message) do
    ensure()
    GenServer.call(__MODULE__, message, 30_000)
  end

  def persist_path,
    do:
      Path.join([
        Newbee.GlobalStore.root(),
        "colonies",
        "store-" <> Atom.to_string(Mix.env()) <> ".json"
      ])

  def clear_all, do: call(:clear)
  def dump, do: call(:dump)
  def restore, do: call(:restore)
  def persist_now, do: call(:persist)

  @doc "Pure callback returns {:ok, result, next_state} or error; never call Store inside it."
  def transaction(fun) when is_function(fun, 1), do: call({:transaction, fun})
  def get(table, id) when table in @tables and is_binary(id), do: call({:get, table, id})
  def get(_, _), do: {:error, :not_found}
  def all(table) when table in @tables, do: call({:all, table})

  def put(table, %{"id" => id} = value) when table in @tables and is_binary(id) do
    transaction(fn data -> {:ok, :ok, put_in(data, [table, id], value)} end)
  end

  def delete(table, id) when table in @tables do
    transaction(fn data -> {:ok, :ok, Map.update!(data, table, &Map.delete(&1, id))} end)
  end

  def update(table, id, revision, fun) when table in @tables do
    transaction(fn data ->
      case get_in(data, [table, id]) do
        nil ->
          {:error, :not_found}

        current ->
          if revision != nil and Map.get(current, "revision", 0) != revision do
            {:error, :conflict}
          else
            case fun.(current) do
              {:ok, value} ->
                value =
                  value
                  |> Map.put("id", id)
                  |> Map.put("revision", Map.get(current, "revision", 0) + 1)

                {:ok, {:ok, value}, put_in(data, [table, id], value)}

              error ->
                error
            end
          end
      end
    end)
  end

  def put_colony(v), do: put("colonies", v)
  def get_colony(id), do: get("colonies", id)

  def list_colonies,
    do:
      all("colonies")
      |> Enum.reject(&(&1["status"] == "dissolved"))
      |> Enum.sort_by(& &1["created_at"])

  def delete_colony(id) do
    case update("colonies", id, nil, &{:ok, Map.put(&1, "status", "dissolved")}) do
      {:ok, _} -> :ok
      error -> error
    end
  end

  def put_bee(v), do: put("bees", v)
  def get_bee(id), do: get("bees", id)
  def list_bees, do: all("bees")
  def bees_for_colony(id), do: in_colony("bees", id) |> Enum.sort_by(& &1["joined_at"])
  def delete_bee(id), do: delete("bees", id)
  def put_task(v), do: put("tasks", v)
  def get_task(id), do: get("tasks", id)
  def list_tasks, do: all("tasks")
  def tasks_for_colony(id), do: in_colony("tasks", id) |> Enum.sort_by(& &1["created_at"])
  def put_honey(v), do: put("honey", v)
  def get_honey(id), do: get("honey", id)
  def list_honey, do: all("honey")
  def honey_for_colony(id), do: in_colony("honey", id) |> Enum.sort_by(& &1["created_at"], :desc)
  defp in_colony(table, id), do: all(table) |> Enum.filter(&(&1["colony_id"] == id))
  def append_trace(entry), do: append("trace", entry)
  def put_signal(entry), do: append("signals", entry)

  defp append(table, %{"colony_id" => cid} = entry) when is_binary(cid) do
    transaction(fn data ->
      seq = data["sequence"] + 1
      id = cid <> ":" <> Integer.to_string(seq)

      entry =
        entry
        |> Map.put("seq", seq)
        |> Map.put_new("id", id)
        |> Map.put_new("created_at", System.system_time(:millisecond))
        |> Map.put_new("ts", System.system_time(:millisecond))

      next = data |> Map.put("sequence", seq) |> put_in([table, id], entry)
      {:ok, {:ok, entry}, next}
    end)
  end

  defp append(_, _), do: {:error, :missing_colony_id}

  def trace_for_colony(cid, opts \\ []) do
    in_colony("trace", cid)
    |> Enum.filter(fn e ->
      (!opts[:task_id] or e["task_id"] == opts[:task_id]) and
        (!opts[:bee_id] or e["bee_id"] == opts[:bee_id] or e["to_bee_id"] == opts[:bee_id]) and
        (!opts[:channel] or e["channel"] == opts[:channel]) and
        (!opts[:since_seq] or e["seq"] > opts[:since_seq])
    end)
    |> Enum.sort_by(& &1["seq"])
    |> Enum.take(-Keyword.get(opts, :limit, 200))
  end

  def signals_for_colony(cid, opts \\ []) do
    in_colony("signals", cid)
    |> Enum.sort_by(& &1["seq"])
    |> Enum.take(-Keyword.get(opts, :limit, 100))
  end

  @impl true
  def init(opts) do
    path = Keyword.get(opts, :path, persist_path())

    case load(path) do
      {:ok, data} -> {:ok, %{data: data, path: path}}
      {:error, reason} -> {:stop, {:snapshot_unreadable, reason}}
    end
  end

  @impl true
  def handle_call({:get, table, id}, _, state) do
    result =
      case get_in(state.data, [table, id]) do
        nil -> {:error, :not_found}
        value -> {:ok, value}
      end

    {:reply, result, state}
  end

  def handle_call({:all, table}, _, state), do: {:reply, Map.values(state.data[table]), state}
  def handle_call(:dump, _, state), do: {:reply, snapshot(state.data), state}
  def handle_call(:persist, _, state), do: {:reply, write(state.path, state.data), state}
  def handle_call(:clear, _, state), do: commit(empty(), :ok, state)

  def handle_call(:restore, _, state) do
    case load(state.path) do
      {:ok, data} -> {:reply, :ok, %{state | data: data}}
      error -> {:reply, error, state}
    end
  end

  def handle_call({:transaction, fun}, _, state) do
    case invoke(fun, state.data) do
      {:ok, result, next} when is_map(next) -> commit(next, result, state)
      error -> {:reply, error, state}
    end
  end

  defp invoke(fun, data) do
    fun.(data)
  rescue
    e -> {:error, {:transaction_failed, Exception.message(e)}}
  catch
    kind, reason -> {:error, {:transaction_failed, kind, inspect(reason)}}
  end

  defp commit(next, result, state) do
    case write(state.path, next) do
      :ok -> {:reply, result, %{state | data: next}}
      {:error, reason} -> {:reply, {:error, {:persistence_failed, reason}}, state}
    end
  end

  defp empty, do: Map.new(@tables, &{&1, %{}}) |> Map.merge(%{"version" => 2, "sequence" => 0})

  defp snapshot(data),
    do: Enum.reduce(@tables, data, fn table, acc -> Map.put(acc, table, Map.values(data[table])) end)

  defp load(path) do
    case File.read(path) do
      {:error, :enoent} ->
        {:ok, empty()}

      {:error, _} = error ->
        error

      {:ok, binary} ->
        with {:ok, decoded} when is_map(decoded) <- Jason.decode(binary),
             true <- decoded["version"] in [1, 2],
             :ok <- backup_legacy(path, binary, decoded["version"]) do
          data =
            Enum.reduce(@tables, empty(), fn table, acc ->
              values = Map.get(decoded, table, [])
              values = if is_map(values), do: Map.values(values), else: values

              indexed =
                Map.new(values, fn value ->
                  id =
                    if table in ["trace", "signals"],
                      do: value["colony_id"] <> ":" <> to_string(value["seq"]),
                      else: value["id"]

                  {id, value}
                end)

              Map.put(acc, table, indexed)
            end)

          max_seq =
            Enum.map(Map.values(data["trace"]) ++ Map.values(data["signals"]), &(&1["seq"] || 0))
            |> Enum.max(fn -> 0 end)

          {:ok, Map.put(data, "sequence", max(max_seq, decoded["sequence"] || 0))}
        else
          false -> {:error, :unsupported_version}
          other -> {:error, {:invalid_snapshot, other}}
        end
    end
  rescue
    e -> {:error, {:invalid_snapshot, Exception.message(e)}}
  end

  defp backup_legacy(path, binary, 1) do
    case File.write(path <> ".v1-backup", binary, [:exclusive]) do
      :ok -> File.chmod(path <> ".v1-backup", 0o600)
      {:error, :eexist} -> :ok
      error -> error
    end
  end

  defp backup_legacy(_, _, _), do: :ok

  defp write(path, data) do
    tmp = path <> ".tmp." <> Integer.to_string(System.unique_integer([:positive]))

    with {:ok, encoded} <- Jason.encode(snapshot(data)),
         :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(tmp, encoded, [:binary, :sync]),
         :ok <- File.chmod(tmp, 0o600),
         :ok <- File.rename(tmp, path) do
      :ok
    else
      error ->
        File.rm(tmp)
        error
    end
  rescue
    e -> {:error, Exception.message(e)}
  end
end
