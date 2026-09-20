# Manual smoke: run authority and peer in two OS processes with one fresh data directory.
# Exercises pinned TLS and durable synchronization using controlled execution events; no model call.
alias Newbee.Colony.{Store, Engine, Membership, Work, Control, Remote}

defmodule ColonySmoke do
  def until(fun, n \\ 600)
  def until(_, 0), do: raise("smoke wait timed out")

  def until(fun, n) do
    case fun.() do
      value when value in [false, nil] ->
        Process.sleep(100)
        until(fun, n - 1)

      value ->
        value
    end
  end
end

[role, root] = System.argv()
root = Path.expand(root)
Application.put_env(:newbee, :global_root_override, Path.join(root, role))
Application.put_env(:newbee, :colony_background, false)
{:ok, _} = Application.ensure_all_started(:newbee)

if role == "authority" do
  {:ok, _} = Newbee.Web.Server.start_link(port: 4576, host: {127, 0, 0, 1}, https: true)
  {:ok, colony} = Engine.create_colony(%{"name" => "TLS smoke", "cwd" => File.cwd!()})
  cid = colony["id"]
  actor = colony["queen_bee_id"]
  {:ok, invite} = Membership.invite(cid, actor, %{"kind" => "ai"})
  {:ok, fingerprint} = Newbee.Web.Cert.fingerprint()

  File.write!(
    Path.join(root, "invite.json"),
    Jason.encode!(Map.merge(invite, %{"fingerprint" => fingerprint, "url" => "https://127.0.0.1:4576"}))
  )

  File.chmod!(Path.join(root, "invite.json"), 0o600)

  bee =
    ColonySmoke.until(fn ->
      Enum.find(Store.bees_for_colony(cid), &is_binary(&1["remote_member_id"]))
    end)

  {:ok, _} = Control.set(cid, "colony", cid, "pause", actor_bee_id: actor)

  {:ok, upload} =
    Newbee.Upload.store(
      "20260911-210000-AAAA",
      "smoke.txt",
      "text/plain",
      String.duplicate("pinned TLS attachment\n", 20000)
    )

  {:ok, task} =
    Work.create(cid, %{
      "title" => "TLS smoke work",
      "assigned_bee_id" => bee["id"],
      "upload_sid" => "20260911-210000-AAAA",
      "upload_ids" => [upload.id]
    })

  ColonySmoke.until(fn -> File.exists?(Path.join(root, "paused.ok")) end)

  "paused" =
    ColonySmoke.until(fn -> if Control.state(cid, "colony", cid) == "paused", do: "paused" end)

  {:ok, _} = Control.set(cid, "colony", cid, "resume", actor_bee_id: actor)
  honey = ColonySmoke.until(fn -> List.first(Store.honey_for_colony(cid)) end)
  {:ok, _} = Work.review(cid, honey["id"], "accept", actor, "TLS protocol smoke")
  ColonySmoke.until(fn -> File.exists?(Path.join(root, "done.ok")) end)
  {:ok, %{"status" => "done"}} = Store.get_task(task["id"])
  IO.puts("PASS TLS invite, paused import, receiver receipt, result, acceptance, terminal sync")
else
  ColonySmoke.until(fn -> File.exists?(Path.join(root, "invite.json")) end)

  attrs =
    File.read!(Path.join(root, "invite.json"))
    |> Jason.decode!()
    |> Map.merge(%{"cwd" => File.cwd!(), "display" => "peer"})

  rejected = Remote.join(Map.put(attrs, "fingerprint", "sha256:" <> String.duplicate("0", 64)))
  :error = elem(rejected, 0)
  {:ok, enrollment} = Remote.join(attrs)
  reused = Remote.join(attrs)
  :error = elem(reused, 0)
  cid = enrollment["colony"]["id"]
  :ok = :sys.suspend(Newbee.Colony.Runtime)
  Application.put_env(:newbee, :colony_background, true)
  task = ColonySmoke.until(fn -> List.first(Store.tasks_for_colony(cid)) end)
  nil = task["session_id"]
  [] = Store.all("deliveries")
  "paused" = Control.state(cid, "colony", cid)
  File.write!(Path.join(root, "paused.ok"), "ok")
  delivery = ColonySmoke.until(fn -> List.first(Store.all("deliveries")) end)
  {:ok, task} = Store.get_task(task["id"])
  true = is_binary(task["session_id"])
  [upload_id] = delivery["upload_ids"]
  {:ok, upload} = Newbee.Upload.info(task["session_id"], upload_id)
  true = File.read!(upload["path"]) == String.duplicate("pinned TLS attachment\n", 20000)
  :ok = Store.put("deliveries", Map.put(delivery, "status", "accepted"))
  :ok = Remote.report(task, :tool_result, %{"text" => "controlled protocol smoke evidence"})

  :ok =
    Remote.report(task, :text_end, %{
      "text" => "two isolated gardens exchanged this result over pinned TLS"
    })

  :ok = Remote.report(task, :done, %{})

  ColonySmoke.until(fn ->
    case Store.get_task(task["id"]) do
      {:ok, %{"status" => "done"}} -> true
      _ -> false
    end
  end)

  File.write!(Path.join(root, "done.ok"), "ok")
  IO.puts("PASS peer paused without session, received after resume, result accepted")
end
