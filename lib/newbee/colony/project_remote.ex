defmodule Newbee.Colony.ProjectRemote do
  @moduledoc "Project execution transport: host-owned baseline and file-only delivery scoped to one lease."
  alias Newbee.Colony.{Membership, ProjectLease, Store, Work, Workspace}
  alias Newbee.Collaboration.Workspace, as: Snapshot

  @chunk 512_000
  @baseline_limit 32_000_000
  @result_limit 1_500_000

  def poll(cid, bid, payload) do
    now = now()

    Store.transaction(fn data ->
      supported =
        payload["projectRunner"] == ProjectLease.version() and
          get_in(data, ["bees", bid, "project_runner_allowed"]) == true

      next = put_in(data, ["bees", bid, "project_runner"], if(supported, do: ProjectLease.version()))
      next = if supported, do: ProjectLease.renew(next, cid, bid, payload["projectLease"], now), else: next

      offers =
        for task <- Map.values(next["tasks"]),
            supported,
            ProjectLease.permitted?(next, task, cid, bid, get_in(task, ["project_lease", "id"]), now),
            delivery <- Map.values(next["deliveries"]),
            delivery["task_id"] == task["id"] and delivery["context_revision"] == task["context_revision"] and
              delivery["status"] in ~w(pending remote_pending accepted) do
          %{
            "task" =>
              Map.take(
                task,
                ~w(id colony_id assigned_bee_id title description context_revision execution_generation project_writes project_lease)
              ),
            "delivery" => Map.take(delivery, ~w(id instruction context_revision execution_generation)),
            "remaining_ms" => task["project_lease"]["expires_at"] - now
          }
        end

      {:ok, Enum.take(offers, 1), next}
    end)
  end

  def request(payload) do
    with {:ok, identity, %{"kind" => "ai"}} <- Membership.authenticate(payload["__device_token__"]),
         %{"taskId" => tid, "lease" => lease} when is_binary(tid) and is_binary(lease) <- payload do
      :global.trans({{__MODULE__, tid}, self()}, fn -> handle(identity, tid, lease, payload) end)
    else
      _ -> lost()
    end
  end

  defp handle(identity, tid, lease, payload) do
    cid = identity["colony_id"]
    bid = identity["bee_id"]

    case Store.get_task(tid) do
      {:ok, task} ->
        cond do
          payload["op"] == "finish" and task["colony_id"] == cid and task["assigned_bee_id"] == bid and
            get_in(task, ["project_lease", "id"]) == lease and task["status"] in ~w(pending_review done) ->
            {:ok, %{"accepted" => true}}

          not permitted?(task, cid, bid, lease) ->
            lost()

          payload["op"] == "baseline" ->
            download(task, payload["offset"])

          payload["op"] == "finish" ->
            finish(task, lease, payload)

          payload["op"] == "fail" ->
            fail(task, lease, payload["message"])

          true ->
            {:error, "bad_request", "未知项目传输操作"}
        end

      _ ->
        lost()
    end
  end

  defp permitted?(task, cid, bid, lease, renew? \\ false) do
    Store.transaction(fn data ->
      current = data["tasks"][task["id"]]
      time = now()
      permitted = ProjectLease.permitted?(data, current, cid, bid, lease, time)
      next = if permitted and renew?, do: ProjectLease.renew(data, cid, bid, lease, time), else: data
      {:ok, permitted, next}
    end) == true
  end

  defp download(task, offset) when is_integer(offset) and offset >= 0 and offset < @baseline_limit do
    with {:ok, path} <- Workspace.ensure(task, task["workspace_source"]),
         {:ok, file} <- baseline_file(path),
         true <- permitted?(task, task["colony_id"], task["assigned_bee_id"], task["project_lease"]["id"], true),
         {:ok, %{size: total}} when offset < total <- File.stat(file),
         {:ok, fd} <- :file.open(file, [:read, :raw, :binary]) do
      try do
        case :file.pread(fd, offset, @chunk) do
          {:ok, bytes} -> {:ok, %{"data" => Base.encode64(bytes), "total" => total}}
          _ -> {:error, "project_baseline", "项目基线片段不可读"}
        end
      after
        :file.close(fd)
      end
    else
      false -> lost()
      {:error, _, _} = error -> error
      _ -> {:error, "project_baseline", "项目基线不可用"}
    end
  end

  defp download(_, _), do: {:error, "bad_request", "项目基线偏移无效"}

  defp baseline_file(path) do
    file = path <> ".project-baseline.json"

    if File.regular?(file) do
      {:ok, file}
    else
      with {:ok, snapshot} <- Snapshot.snapshot(path, max_bytes: @baseline_limit),
           {:ok, encoded} <- Jason.encode(snapshot),
           true <- byte_size(encoded) <= @baseline_limit,
           :ok <- File.write(file <> ".tmp", encoded, [:binary]),
           :ok <- File.rename(file <> ".tmp", file) do
        {:ok, file}
      else
        _ -> {:error, "project_baseline", "跨机项目快照超过 32 MB 或不可读取"}
      end
    end
  end

  defp finish(task, lease, payload) do
    # The worker can only provide bytes for its declared paths, never filesystem locations or commands.
    cid = task["colony_id"]
    bid = task["assigned_bee_id"]

    with %{"entries" => entries, "summary" => summary} when is_map(entries) and is_binary(summary) <- payload,
         true <- Enum.sort(Map.keys(entries)) == Enum.sort(task["project_writes"]),
         {:ok, encoded} <- Jason.encode(entries),
         true <- byte_size(encoded) <= @result_limit,
         {:ok, path} <- Workspace.ensure(task, task["workspace_source"]),
         {:ok, task} <- Store.get_task(task["id"]),
         true <- permitted?(task, cid, bid, lease),
         :ok <- write_candidate(entries, path),
         {:ok, _} <-
           Work.submit(
             cid,
             task["id"],
             %{
               "content" => bounded(summary, "远端分项已提交文件"),
               "work_revision" => task["context_revision"],
               "evidence" => ["受邀执行端提交文件；由主机独立复核范围及内容"]
             },
             bid,
             lease
           ) do
      {:ok, %{"accepted" => true}}
    else
      {:error, "lease_lost", _} = error -> error
      _ -> {:error, "project_candidate", "远端文件不符合当前分项范围或传输上限"}
    end
  end

  defp write_candidate(entries, path) do
    {remove, update} = Enum.split_with(entries, fn {_, entry} -> is_nil(entry) end)

    with :ok <- Snapshot.materialize_snapshot(Map.new(update), path) do
      Enum.reduce_while(remove, :ok, fn {name, _}, :ok ->
        case File.rm(Path.join(path, name)) do
          :ok -> {:cont, :ok}
          {:error, :enoent} -> {:cont, :ok}
          error -> {:halt, error}
        end
      end)
    end
  end

  defp fail(task, lease, message) do
    Store.transaction(fn data ->
      current = data["tasks"][task["id"]]

      if ProjectLease.permitted?(data, current, task["colony_id"], task["assigned_bee_id"], lease, now()) do
        next = ProjectLease.reset(data, current, true, bounded(message, "远端执行失败，核对后可重试。"))
        {:ok, {:ok, %{"accepted" => true}}, next}
      else
        lost()
      end
    end)
  end

  def fetch_baseline(rpc, task) do
    args = args(task, "baseline")
    fetch_parts(rpc, args, 0, nil, [])
  end

  defp fetch_parts(_rpc, _args, total, total, acc) when is_integer(total) do
    acc |> Enum.reverse() |> IO.iodata_to_binary() |> Jason.decode()
  end

  defp fetch_parts(rpc, args, offset, previous_total, acc) do
    with {:ok, %{"data" => data, "total" => total}} <- rpc.(Map.put(args, "offset", offset)),
         true <- is_integer(total) and total in 1..@baseline_limit and previous_total in [nil, total],
         {:ok, bytes} <- Base.decode64(data),
         true <- byte_size(bytes) == min(@chunk, total - offset) and byte_size(bytes) > 0 do
      fetch_parts(rpc, args, offset + byte_size(bytes), total, [bytes | acc])
    else
      {:error, _, _} = error -> error
      _ -> {:error, "project_baseline", "项目基线传输不完整"}
    end
  end

  def result(task, path, baseline, summary) do
    with {:ok, after_files} <- Snapshot.snapshot(path, max_bytes: @baseline_limit),
         {:ok, before_files} <- File.read(baseline),
         {:ok, before_files} <- Jason.decode(before_files),
         actual <- Enum.uniq(Map.keys(before_files) ++ Map.keys(after_files)),
         changes <- Enum.filter(actual, &(before_files[&1] != after_files[&1])),
         true <- Enum.sort(changes) == Enum.sort(task["project_writes"]),
         entries <- Map.new(changes, &{&1, after_files[&1]}),
         {:ok, encoded} <- Jason.encode(entries),
         true <- byte_size(encoded) <= @result_limit do
      args(task, "finish") |> Map.merge(%{"entries" => entries, "summary" => bounded(summary, "远端分项已提交文件")})
    else
      _ -> Map.put(args(task, "fail"), "message", "远端文件范围不符或改动超过 1.5 MB，需要检查后重试。")
    end
  end

  def args(task, op), do: %{"taskId" => task["id"], "lease" => task["project_lease"]["id"], "op" => op}

  defp bounded(s, fallback),
    do: if(is_binary(s) and String.trim(s) != "", do: String.slice(s, 0, 1_000), else: fallback)

  defp lost, do: {:error, "lease_lost", "远端项目租约已失效或暂停"}
  defp now, do: System.system_time(:millisecond)
end
