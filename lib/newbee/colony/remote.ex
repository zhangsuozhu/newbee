defmodule Newbee.Colony.Remote do
  @moduledoc "Pinned, authenticated pull transport. The originating host remains the work authority."
  use GenServer
  alias Newbee.Colony.{Store, Membership, Control, Id}
  alias Newbee.Collaboration.CrossHost.Transport
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def init(_) do
    Process.send_after(self(), :poll, 2_000)
    {:ok, %{}}
  end

  def handle_info(:poll, state) do
    if Application.get_env(:newbee, :colony_background, true) do
      Store.all("identities")
      |> Enum.filter(&(&1["connection"] == true))
      |> Enum.each(&sync_connection/1)
    end

    Process.send_after(self(), :poll, 2_000)
    {:noreply, state}
  end

  def handle_info(_, state), do: {:noreply, state}

  def join(attrs) do
    cwd = attrs["cwd"]

    with true <- is_binary(cwd) and File.dir?(cwd),
         {:ok, enrollment} <-
           Transport.rpc(
             attrs["url"],
             "colony.invite.redeem",
             %{"code" => attrs["code"], "display" => attrs["display"]},
             fingerprint: attrs["fingerprint"]
           ),
         true <- enrollment["bee"]["kind"] == "ai" do
      connection = %{
        "id" => "connection:" <> enrollment["colony"]["id"],
        "connection" => true,
        "colony_id" => enrollment["colony"]["id"],
        "bee_id" => enrollment["bee"]["id"],
        "token" => enrollment["token"],
        "url" => attrs["url"],
        "fingerprint" => attrs["fingerprint"],
        "cwd" => Path.expand(cwd)
      }

      colony =
        enrollment["colony"]
        |> Map.put("authority", "remote")
        |> Map.put("cwd", connection["cwd"])

      bee = enrollment["bee"] |> Map.delete("remote_member_id") |> Map.put("garden_id", "local")

      Store.transaction(fn data ->
        next =
          data
          |> put_in(["identities", connection["id"]], connection)
          |> put_in(["colonies", colony["id"]], colony)
          |> put_in(["bees", bee["id"]], bee)

        {:ok, {:ok, %{"colony" => colony, "bee" => bee}}, next}
      end)
    else
      false -> {:error, "bad_request", "需要确认本地项目目录，并使用 AI 环境邀请码"}
      error -> error
    end
  end

  # Runtime leaves remote work in the durable outbox. Only the authenticated peer may receive it.
  def dispatch(delivery, _task) do
    if delivery["status"] == "pending" do
      Store.update(
        "deliveries",
        delivery["id"],
        nil,
        &{:ok, Map.put(&1, "status", "remote_pending")}
      )
    else
      :ok
    end
  end

  def poll(payload) do
    with {:ok, identity, bee} <- Membership.authenticate(payload["__device_token__"]),
         true <- bee["kind"] == "ai" do
      cid = identity["colony_id"]
      reports = payload["reports"] || []
      processed = Enum.take(reports, 100) |> Enum.map(&accept_report(cid, bee["id"], &1))

      Store.update(
        "bees",
        bee["id"],
        nil,
        &{:ok,
         Map.merge(&1, %{
           "last_seen_at" => now(),
           "status" => "idle",
           "remote_controls" => payload["controls"] || %{}
         })}
      )

      tasks = Store.tasks_for_colony(cid) |> Enum.filter(&(&1["assigned_bee_id"] == bee["id"]))
      ids = Enum.map(tasks, & &1["id"])

      deliveries =
        Store.all("deliveries")
        |> Enum.filter(
          &(&1["colony_id"] == cid and &1["bee_id"] == bee["id"] and
              &1["status"] in ["pending", "remote_pending", "accepted"])
        )

      controls =
        Store.all("controls")
        |> Enum.filter(
          &(&1["colony_id"] == cid and
              (&1["scope"] == "colony" or &1["target_id"] == bee["id"] or &1["target_id"] in ids))
        )

      {:ok,
       %{
         "tasks" => tasks,
         "deliveries" => deliveries,
         "controls" => controls,
         "processed" => processed,
         "server_time" => now()
       }}
    else
      false -> {:error, "forbidden", "该凭据不是 AI 执行环境"}
      error -> error
    end
  end

  defp accept_report(cid, bid, report) do
    id = report["id"]
    key = Enum.join([cid, bid, id], ":")

    case Store.get("remote_reports", key) do
      {:ok, _} ->
        id

      _ ->
        with {:ok, task} <- Store.get_task(report["task_id"]),
             true <- is_binary(id) and task["colony_id"] == cid and task["assigned_bee_id"] == bid do
          if report["kind"] == "receipt" do
            case Store.get("deliveries", report["delivery_id"]) do
              {:ok, %{"bee_id" => ^bid, "colony_id" => ^cid} = delivery} ->
                Store.update("deliveries", delivery["id"], nil, fn current ->
                  if current["task_id"] == task["id"] and
                       current["status"] in ["pending", "remote_pending", "dispatching"],
                     do: {:ok, Map.put(current, "status", "accepted")},
                     else: {:ok, current}
                end)

              _ ->
                :ok
            end
          else
            kinds = %{
              "done" => :done,
              "text_end" => :text_end,
              "ask" => :ask,
              "error" => :error,
              "interrupted" => :interrupted,
              "tool_start" => :tool_start,
              "tool_result" => :tool_result,
              "tool_error" => :tool_error,
              "file_diff" => :file_diff,
              "permission_ask" => :permission_ask
            }

            if kind = kinds[report["kind"]] do
              Newbee.Colony.Runtime.project_remote(
                task,
                kind,
                Map.put(report["payload"] || %{}, "work_revision", report["work_revision"])
              )
            end
          end

          Store.put("remote_reports", %{"id" => key, "received" => true, "colony_id" => cid})
          id
        else
          _ -> nil
        end
    end
  end

  def attachment(payload) do
    with {:ok, identity, _} <- Membership.authenticate(payload["__device_token__"]),
         {:ok, delivery} <- Store.get("deliveries", payload["deliveryId"]),
         true <-
           delivery["colony_id"] == identity["colony_id"] and
             delivery["bee_id"] == identity["bee_id"],
         true <- payload["uploadId"] in delivery["upload_ids"],
         offset when is_integer(offset) and offset >= 0 <- payload["offset"],
         {:ok, info} <- Newbee.Upload.info(delivery["upload_sid"], payload["uploadId"]),
         {:ok, file} <- :file.open(String.to_charlist(info["path"]), [:read, :binary, :raw]) do
      part = :file.pread(file, offset, 65_536)
      :file.close(file)

      case part do
        {:ok, bytes} ->
          {:ok,
           %{
             "data" => Base.encode64(bytes),
             "size" => info["size"],
             "name" => info["name"],
             "content_type" => info["content_type"]
           }}

        :eof ->
          {:ok,
           %{
             "data" => "",
             "size" => info["size"],
             "name" => info["name"],
             "content_type" => info["content_type"]
           }}

        _ ->
          {:error, "read_failed", "附件读取失败"}
      end
    else
      _ -> {:error, "forbidden", "无权读取该附件"}
    end
  end

  def report(task, kind, payload) do
    if task["authority"] == "remote" and
         kind in [
           :done,
           :text_end,
           :ask,
           :error,
           :interrupted,
           :tool_start,
           :tool_result,
           :tool_error,
           :file_diff,
           :permission_ask
         ] do
      delivered =
        Store.all("deliveries")
        |> Enum.filter(&(&1["task_id"] == task["id"] and &1["status"] in ["accepted", "dispatching"]))
        |> Enum.sort_by(& &1["created_at"], :desc)
        |> List.first()

      work_revision =
        if delivered, do: delivered["context_revision"], else: task["context_revision"]

      Store.put("remote_reports", %{
        "id" => Id.new(:message),
        "colony_id" => task["colony_id"],
        "task_id" => task["id"],
        "kind" => Atom.to_string(kind),
        "work_revision" => work_revision,
        "payload" => payload,
        "outbound" => true
      })
    end

    :ok
  end

  defp sync_connection(connection) do
    reports =
      Store.all("remote_reports")
      |> Enum.filter(&(&1["outbound"] == true and &1["colony_id"] == connection["colony_id"]))
      |> Enum.take(100)

    controls =
      Store.all("controls")
      |> Enum.filter(&(&1["colony_id"] == connection["colony_id"]))
      |> Map.new(fn g ->
        {g["id"],
         %{
           "revision" => g["revision"],
           "state" => Control.state(g["colony_id"], g["scope"], g["target_id"])
         }}
      end)

    case rpc(connection, "colony.remote.poll", %{"reports" => reports, "controls" => controls}) do
      {:ok, snapshot} ->
        Enum.each(snapshot["controls"] || [], &import_control/1)

        Enum.each(snapshot["tasks"] || [], fn task ->
          if task["status"] in ["done", "cancelled", "failed"] do
            Store.update("tasks", task["id"], nil, &{:ok, Map.put(&1, "status", task["status"])})
          end
        end)

        Enum.each(snapshot["deliveries"] || [], fn delivery ->
          task = Enum.find(snapshot["tasks"] || [], &(&1["id"] == delivery["task_id"]))
          if task, do: import_delivery(connection, task, delivery)
        end)

        Enum.each(snapshot["processed"] || [], fn id ->
          if is_binary(id), do: Store.delete("remote_reports", id)
        end)

        Store.update(
          "identities",
          connection["id"],
          nil,
          &{:ok, Map.merge(&1, %{"last_sync_at" => now(), "error" => nil})}
        )

      error ->
        Store.update(
          "identities",
          connection["id"],
          nil,
          &{:ok, Map.put(&1, "error", inspect(error))}
        )
    end
  rescue
    e ->
      Store.update(
        "identities",
        connection["id"],
        nil,
        &{:ok, Map.put(&1, "error", Exception.message(e))}
      )
  end

  defp import_control(gate) do
    case Store.get("controls", gate["id"]) do
      {:ok, %{"revision" => revision}} when revision >= :erlang.map_get("revision", gate) ->
        :ok

      _ ->
        Store.put("controls", gate)

        if gate["action"] == "interrupt" do
          Control.affected_sessions(gate["colony_id"], gate["scope"], gate["target_id"])
          |> Enum.each(fn sid ->
            case Newbee.Web.Session.lookup(sid) do
              {:ok, pid} -> Newbee.Web.Session.interrupt(pid)
              _ -> :ok
            end
          end)
        end

        if gate["paused"] == false do
          Control.affected_sessions(gate["colony_id"], gate["scope"], gate["target_id"])
          |> Enum.each(fn sid ->
            case Newbee.Web.Session.lookup(sid) do
              {:ok, pid} -> GenServer.cast(pid, :colony_resume)
              _ -> :ok
            end
          end)
        end
    end
  end

  defp import_delivery(connection, task, delivery) do
    case Store.get("deliveries", delivery["id"]) do
      {:ok, local} ->
        if local["status"] in ["accepted", "completed", "paused"] do
          receipt(task, delivery)
        end

        Store.update("tasks", task["id"], nil, fn current ->
          {:ok,
           Map.merge(
             current,
             Map.take(
               task,
               ~w(constraints acceptance facts decisions context_revision approval_required)
             )
           )}
        end)

      _ ->
        existing_sid =
          case Store.get_task(task["id"]) do
            {:ok, local_task} -> local_task["session_id"]
            _ -> nil
          end

        if Control.blocked?(task["colony_id"], task["assigned_bee_id"], task["id"]) do
          Store.put_task(
            task
            |> Map.put("authority", "remote")
            |> Map.put("session_id", existing_sid)
          )
        else
          with {:ok, _pid, sid} <- Newbee.Web.Session.ensure(existing_sid, connection["cwd"]),
               {:ok, uploads} <- import_uploads(connection, delivery, sid) do
            task = task |> Map.put("session_id", sid) |> Map.put("authority", "remote")

            local =
              Map.merge(delivery, %{
                "session_id" => sid,
                "status" => "pending",
                "upload_ids" => uploads,
                "upload_sid" => sid
              })

            Store.transaction(fn data ->
              next =
                data
                |> put_in(["tasks", task["id"]], task)
                |> put_in(["deliveries", local["id"]], local)
                |> put_in(["conversations", sid], %{
                  "id" => sid,
                  "colony_id" => task["colony_id"],
                  "bee_id" => task["assigned_bee_id"],
                  "task_id" => task["id"],
                  "visibility" => "work"
                })

              {:ok, :ok, next}
            end)
          end
        end
    end
  end

  defp receipt(task, delivery),
    do:
      Store.put("remote_reports", %{
        "id" => "receipt:" <> delivery["id"],
        "outbound" => true,
        "colony_id" => task["colony_id"],
        "task_id" => task["id"],
        "delivery_id" => delivery["id"],
        "kind" => "receipt"
      })

  defp import_uploads(connection, delivery, sid) do
    Enum.reduce_while(delivery["upload_ids"] || [], {:ok, []}, fn id, {:ok, acc} ->
      with {:ok, binary, info} <- download(connection, delivery["id"], id, 0, []),
           {:ok, stored} <- Newbee.Upload.store(sid, info["name"], info["content_type"], binary) do
        {:cont, {:ok, acc ++ [stored[:id] || stored["id"]]}}
      else
        error -> {:halt, error}
      end
    end)
  end

  defp download(connection, did, uid, offset, chunks) do
    with {:ok, part} <-
           rpc(connection, "colony.remote.attachment", %{
             "deliveryId" => did,
             "uploadId" => uid,
             "offset" => offset
           }),
         true <- is_integer(part["size"]) and part["size"] <= Newbee.Upload.max_bytes(),
         {:ok, bytes} <- Base.decode64(part["data"]) do
      next = offset + byte_size(bytes)

      if next >= part["size"],
        do: {:ok, IO.iodata_to_binary(Enum.reverse([bytes | chunks])), part},
        else:
          if(bytes == "",
            do: {:error, :truncated},
            else: download(connection, did, uid, next, [bytes | chunks])
          )
    else
      _ -> {:error, :attachment_transfer_failed}
    end
  end

  defp rpc(connection, method, payload),
    do:
      Transport.rpc(connection["url"], method, payload,
        fingerprint: connection["fingerprint"],
        device_token: connection["token"],
        timeout: 5_000
      )

  defp now, do: System.system_time(:millisecond)
end
