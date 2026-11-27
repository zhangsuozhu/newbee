defmodule Newbee.Colony.ProjectRunner do
  @moduledoc "Mirror a project offer to an isolated local session and retain its bounded delivery until acknowledged."
  alias Newbee.Colony.{ProjectLease, ProjectRemote, Store}
  alias Newbee.Collaboration.Workspace, as: Snapshot

  def heartbeat(connection) do
    task = Enum.find(local_tasks(connection), &(&1["status"] in ~w(claimed running pending_review)))
    %{"projectRunner" => ProjectLease.version(), "projectLease" => get_in(task || %{}, ["project_lease", "id"])}
  end

  def reconcile(connection, offers, rpc) do
    current = MapSet.new(offers, & &1["task"]["project_lease"]["id"])

    for task <- local_tasks(connection),
        task["status"] in ~w(claimed running pending_review),
        not MapSet.member?(current, task["project_lease"]["id"]) do
      stop(task)
    end

    Enum.each(offers, &import_offer(connection, &1, rpc))
  end

  def disconnected(connection) do
    if now() - (connection["last_sync_at"] || 0) > 15_000 do
      for task <- local_tasks(connection), task["status"] in ~w(claimed running), do: stop(task)
    end
  end

  def flush(connection, rpc) do
    Store.all("remote_reports")
    |> Enum.filter(&(&1["project_result"] == true and &1["colony_id"] == connection["colony_id"]))
    |> Enum.take(4)
    |> Enum.each(fn report ->
      case rpc.(report["payload"]) do
        {:ok, %{"accepted" => true}} ->
          Store.delete("remote_reports", report["id"])

        {:error, "lease_lost", _} ->
          Store.delete("remote_reports", report["id"])

        {:error, "project_candidate", message} ->
          case rpc.(
                 report["payload"]
                 |> Map.take(~w(taskId lease))
                 |> Map.merge(%{"op" => "fail", "message" => message})
               ) do
            {:ok, _} -> Store.delete("remote_reports", report["id"])
            {:error, "lease_lost", _} -> Store.delete("remote_reports", report["id"])
            _ -> :ok
          end

        _ ->
          :ok
      end
    end)
  end

  def local?(task), do: task["authority"] == "remote" and ProjectLease.remote?(task)

  def event(task, kind, payload) when kind in [:done, :text_end, :ask, :error] do
    id = task["id"]
    current_lease = task["project_lease"]

    report =
      case kind do
        kind when kind in [:done, :text_end] ->
          summary = payload[:summary] || payload["summary"] || payload[:body] || payload["body"]
          ProjectRemote.result(task, task["workspace"]["path"], task["project_baseline"], summary)

        :ask ->
          ProjectRemote.args(task, "fail") |> Map.put("message", "远端分项需要补充信息，请在主会话澄清并重试。")

        :error ->
          ProjectRemote.args(task, "fail") |> Map.put("message", "远端模型执行失败，请检查执行设备的模型配置和会话。")
      end

    Store.transaction(fn data ->
      case data["tasks"][id] do
        %{"status" => status, "project_lease" => lease} when status in ~w(claimed running) and lease == current_lease ->
          entry = %{
            "id" => "project:" <> lease["id"],
            "project_result" => true,
            "colony_id" => task["colony_id"],
            "payload" => report
          }

          next =
            data |> put_in(["remote_reports", entry["id"]], entry) |> put_in(["tasks", id, "status"], "pending_review")

          {:ok, :ok, settle(next, task, "completed")}

        _ ->
          {:ok, :ok, data}
      end
    end)
  end

  def event(_, _, _), do: :ok

  defp import_offer(connection, %{"task" => task, "delivery" => delivery}, rpc) do
    lease = task["project_lease"]["id"]

    case Store.get_task(task["id"]) do
      {:ok, %{"project_lease" => %{"id" => ^lease}, "status" => "cancelled"}} ->
        rpc.(Map.put(ProjectRemote.args(task, "fail"), "message", "执行端离线后已停工，需重新认领。"))

      {:ok, %{"project_lease" => %{"id" => ^lease}}} ->
        :ok

      _ ->
        case create(connection, task, delivery, rpc) do
          :ok ->
            :ok

          {:error, code, message} when code in ~w(project_baseline workspace_copy_failed) ->
            rpc.(Map.put(ProjectRemote.args(task, "fail"), "message", message))

          _ ->
            :ok
        end
    end
  end

  defp create(connection, task, delivery, rpc) do
    lease = task["project_lease"]["id"]

    with true <- is_binary(lease) and Regex.match?(~r/\A[0-9A-Za-z_-]{1,90}\z/, lease),
         cwd <- Path.join([connection["cwd"], ".newbee", "remote-projects", lease]),
         {:ok, snapshot} when is_map(snapshot) <- ProjectRemote.fetch_baseline(rpc, task),
         :ok <- Snapshot.materialize_snapshot(snapshot, cwd),
         baseline <- cwd <> ".json",
         :ok <- File.write(baseline, Jason.encode!(snapshot), [:binary]),
         {:ok, _pid, sid} <- Newbee.Web.Session.ensure("project-" <> lease, cwd) do
      task =
        Map.merge(task, %{
          "authority" => "remote",
          "conversation" => true,
          "conversation_child" => true,
          "session_id" => sid,
          "workspace" => %{"path" => cwd},
          "project_baseline" => baseline,
          "consumed_context_revision" => 0,
          "status" => "claimed",
          "updated_at" => now(),
          "inputs" => []
        })

      delivery =
        Map.merge(delivery, %{
          "session_id" => sid,
          "task_id" => task["id"],
          "colony_id" => task["colony_id"],
          "bee_id" => task["assigned_bee_id"],
          "status" => "pending",
          "created_at" => now(),
          "revision" => 0,
          "input_ids" => [],
          "upload_ids" => []
        })

      binding = %{
        "id" => sid,
        "colony_id" => task["colony_id"],
        "bee_id" => task["assigned_bee_id"],
        "task_id" => task["id"],
        "visibility" => "work"
      }

      Store.transaction(fn data ->
        next =
          data
          |> put_in(["tasks", task["id"]], task)
          |> put_in(["deliveries", delivery["id"]], delivery)
          |> put_in(["conversations", sid], binding)

        {:ok, :ok, next}
      end)
    end
  end

  defp stop(task) do
    current_lease = task["project_lease"]

    Store.transaction(fn data ->
      case data["tasks"][task["id"]] do
        %{"project_lease" => lease} when lease == current_lease ->
          next = data |> put_in(["tasks", task["id"], "status"], "cancelled") |> settle(task, "superseded")
          {:ok, :ok, next}

        _ ->
          {:ok, :ok, data}
      end
    end)

    case Newbee.Web.Session.lookup(task["session_id"]) do
      {:ok, pid} -> Newbee.Web.Session.interrupt(pid)
      _ -> :ok
    end
  end

  defp settle(data, task, status) do
    Map.update!(data, "deliveries", fn entries ->
      Map.new(entries, fn {id, d} ->
        if d["task_id"] == task["id"] and d["execution_generation"] == task["execution_generation"] and
             d["status"] in ~w(pending dispatching accepted), do: {id, Map.put(d, "status", status)}, else: {id, d}
      end)
    end)
  end

  defp local_tasks(connection), do: Enum.filter(Store.tasks_for_colony(connection["colony_id"]), &local?/1)
  defp now, do: System.system_time(:millisecond)
end
