defmodule Newbee.Colony.ProjectLease do
  @moduledoc "Bounded remote seats with durable, generation-fenced assignments. Caller supplies the host clock."
  alias Newbee.Colony.{Control, Id}
  @version 1
  @lease_ms 90_000
  @live_ms 15_000
  @max_attempts 3
  @global_limit 24
  @active ~w(claimed running)
  @terminal ~w(done cancelled failed)

  def version, do: @version

  def device_status(bee, now) do
    cond do
      bee["project_runner"] != @version -> "not_ready"
      is_integer(bee["last_seen_at"]) and bee["last_seen_at"] > now - @live_ms -> "online"
      true -> "offline"
    end
  end

  def remote?(task), do: is_map(task["project_lease"])
  def pool?(root), do: get_in(root, ["workflow", "project_pool"]) == "remote"

  def allocate(data, root, child, now) do
    cond do
      is_list(child["project_writes"]) and not under_limit?(data) -> :wait
      pool?(root) -> allocate_remote(data, root, child, now)
      true -> {:ok, child}
    end
  end

  defp allocate_remote(data, root, child, now) do
    case available(data, root["colony_id"], now) do
      nil ->
        :wait

      bee ->
        lease = %{
          "id" => Id.new(:delivery, :xhost),
          "bee_id" => bee["id"],
          "expires_at" => now + @lease_ms,
          "attempt" => (child["project_attempt"] || 0) + 1
        }

        {:ok,
         child
         |> Map.put("assigned_bee_id", bee["id"])
         |> Map.put("project_attempt", lease["attempt"])
         |> Map.put("project_lease", lease)}
    end
  end

  defp under_limit?(data) do
    Enum.count(Map.values(data["tasks"]), &(is_list(&1["project_writes"]) and &1["status"] in @active)) < @global_limit
  end

  def available(data, cid, now) do
    busy =
      for task <- Map.values(data["tasks"]), task["status"] in @active, into: MapSet.new(), do: task["assigned_bee_id"]

    if under_limit?(data) do
      allowed = device_ids(data["identities"], cid)

      data["bees"]
      |> Map.values()
      |> Enum.filter(fn bee ->
        bee["colony_id"] == cid and is_binary(bee["remote_member_id"]) and bee["project_runner_allowed"] == true and
          bee["project_runner"] == @version and
          is_integer(bee["last_seen_at"]) and bee["last_seen_at"] > now - @live_ms and
          MapSet.member?(allowed, bee["id"]) and not MapSet.member?(busy, bee["id"]) and
          not paused?(data, cid, "bee", bee["id"])
      end)
      |> Enum.min_by(&{&1["project_last_claimed_at"] || 0, &1["id"]}, fn -> nil end)
    end
  end

  def device_ids(identities, cid) do
    MapSet.new(
      for {_, device} <- identities, device["colony_id"] == cid and device["revoked"] == false, do: device["bee_id"]
    )
  end

  def assigned?(task, cid, bid, token, now) when is_map(task) and is_binary(token) do
    lease = task["project_lease"]

    is_map(lease) and task["colony_id"] == cid and task["assigned_bee_id"] == bid and
      lease["bee_id"] == bid and lease["id"] == token and lease["expires_at"] > now and task["status"] in @active
  end

  def assigned?(_, _, _, _, _), do: false

  def permitted?(data, task, cid, bid, token, now) do
    root = data["tasks"][task && task["workflow_root"]]

    assigned?(task, cid, bid, token, now) and root_active?(root) and pool?(root) and root["colony_id"] == cid and
      task["id"] in (get_in(root, ["workflow", "children"]) || []) and
      not paused?(data, cid, "work", task["id"]) and not paused?(data, cid, "work", task["workflow_root"]) and
      not paused?(data, cid, "colony", cid) and not paused?(data, cid, "bee", bid) and
      match?(%{"status" => status} when status != "dissolved", data["colonies"][cid]) and
      Enum.any?(data["identities"], fn {_, actor} ->
        actor["colony_id"] == cid and actor["bee_id"] == bid and actor["revoked"] == false
      end)
  end

  def renew(data, cid, bid, lease_id, now) do
    case Enum.find(Map.values(data["tasks"]), &permitted?(data, &1, cid, bid, lease_id, now)) do
      nil ->
        data

      task ->
        if task["project_lease"]["expires_at"] - now <= div(@lease_ms, 2),
          do: put_in(data, ["tasks", task["id"], "project_lease", "expires_at"], now + @lease_ms),
          else: data
    end
  end

  def expire(data, now) do
    Enum.reduce(Map.values(data["tasks"]), data, fn task, acc ->
      lease = task["project_lease"]

      if task["authority"] != "remote" and task["status"] in @active and is_map(lease) and
           (lease["expires_at"] <= now or
              not MapSet.member?(device_ids(acc["identities"], task["colony_id"]), lease["bee_id"])) do
        reset(acc, task, lease["attempt"] >= @max_attempts, "执行端租约到期，旧回执不再有效。")
      else
        acc
      end
    end)
  end

  def reset(data, task, exhausted, note) do
    next =
      task
      |> Map.drop(~w(workspace project_lease application question))
      |> Map.merge(%{
        "status" => "blocked",
        "waiting_for" => if(exhausted, do: "lease_failed", else: "capacity"),
        "assigned_bee_id" => nil,
        "session_id" => nil,
        "result" => nil,
        "resume_needed" => false,
        "next_step" => note,
        "revision" => task["revision"] + 1,
        "execution_generation" => (task["execution_generation"] || 0) + 1
      })

    dels =
      Map.new(data["deliveries"], fn {id, delivery} ->
        if delivery["task_id"] == task["id"] and delivery["status"] in ~w(pending accepted dispatching remote_pending) do
          {id, Map.put(delivery, "status", "superseded")}
        else
          {id, delivery}
        end
      end)

    data |> put_in(["tasks", task["id"]], next) |> Map.put("deliveries", dels)
  end

  def paused?(data, cid, scope, id), do: get_in(data, ["controls", Control.key(cid, scope, id), "paused"]) == true

  def root_active?(root),
    do: is_map(root) and root["status"] not in @terminal and get_in(root, ["workflow", "phase"]) == "executing"
end
