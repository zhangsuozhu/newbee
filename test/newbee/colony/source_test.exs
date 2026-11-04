defmodule Newbee.Colony.SourceTest do
  use ExUnit.Case, async: false
  alias Newbee.Colony.{Source, Store, ConversationWork}
  @moduletag :tmp_dir
  setup %{tmp_dir: root} do
    Store.clear_all()
    File.mkdir_p!(root)
    %{root: root}
  end

  defp config(root, opts \\ %{}),
    do: Map.merge(%{"kind" => "local", "root" => root, "allowed_actors" => ["alice"], "cooldown_ms" => 0}, opts)

  defp event(id, opts \\ %{}),
    do:
      Map.merge(
        %{
          "id" => id,
          "thread" => "42",
          "actor" => "alice",
          "text" => "@newbee 修复导出并测试",
          "event_type" => "comment.created",
          "explicit" => true,
          "machine" => false
        },
        opts
      )

  test "new sources only observe and replay after explicit enable is atomic and idempotent", %{root: root} do
    {:ok, cfg} = Source.configure(config(root))
    assert cfg["mode"] == "observe"
    {:ok, observed} = Source.ingest(cfg["id"], event("1"))
    assert observed["disposition"] == "observed"
    assert observed["predicted"] == "create"
    assert Store.list_tasks() == []
    {:ok, _} = Source.configure(config(root, %{"id" => cfg["id"], "revision" => cfg["revision"], "mode" => "explicit"}))
    {:ok, replayed} = Source.replay(cfg["id"], observed["id"])
    assert replayed["disposition"] == "owned"
    {:ok, again} = Source.replay(cfg["id"], observed["id"])
    assert again["task_id"] == replayed["task_id"]
    assert length(Store.list_tasks()) == 1
    assert length(Store.all("deliveries")) == 1
  end

  test "duplicates deduplicate, changed contents require a distinct external revision", %{root: root} do
    {:ok, cfg} = Source.configure(config(root, %{"mode" => "explicit"}))
    assert {:ok, first} = Source.ingest(cfg["id"], event("1"))
    assert {:ok, again} = Source.ingest(cfg["id"], event("1"))
    assert first == again
    assert {:error, "event_conflict", _} = Source.ingest(cfg["id"], event("1", %{"text" => "changed"}))
    assert length(Store.all("source_events")) == 1
    assert length(Store.all("deliveries")) == 1
  end

  test "unapproved users, unowned discussion and bot/self feedback never wake or create", %{root: root} do
    {:ok, cfg} = Source.configure(config(root, %{"mode" => "explicit"}))

    for {id, override} <- [
          {"1", %{"actor" => "mallory"}},
          {"2", %{"explicit" => false}},
          {"3", %{"machine" => true}},
          {"4", %{"self_reply" => true}}
        ] do
      {:ok, receipt} = Source.ingest(cfg["id"], event(id, override))
      assert receipt["disposition"] in ["context_only", "self_event"]
    end

    assert Store.list_tasks() == []
    assert Store.all("deliveries") == []
    {:ok, owned} = Source.ingest(cfg["id"], event("5"))
    task_id = owned["task_id"]
    {:ok, task} = Store.get_task(task_id)

    {:ok, qtask} =
      Store.update(
        "tasks",
        task_id,
        nil,
        &{:ok, Map.merge(&1, %{"status" => "blocked", "question" => %{"id" => "question-1", "question" => "采用哪个格式？"}})}
      )

    {:ok, bot} = Source.ingest(cfg["id"], event("6", %{"machine" => true}))
    assert bot["disposition"] == "context_only"
    assert {:ok, ^qtask} = Store.get_task(task_id)
    assert length(Store.all("deliveries")) == 1
    assert task["context_revision"] == qtask["context_revision"]
  end

  test "human followups update the same work; ending it never revives its record", %{root: root} do
    {:ok, cfg} = Source.configure(config(root, %{"mode" => "explicit"}))
    {:ok, first} = Source.ingest(cfg["id"], event("1"))
    {:ok, second} = Source.ingest(cfg["id"], event("2", %{"text" => "@newbee 保留已有格式"}))
    assert first["task_id"] == second["task_id"]
    {:ok, task} = Store.get_task(first["task_id"])
    assert task["context_revision"] == 1
    assert length(task["inputs"]) == 2
    {:ok, _} = ConversationWork.control(task["origin_session_id"], task["id"], "stop")
    {:ok, bot} = Source.ingest(cfg["id"], event("3", %{"machine" => true}))
    assert bot["task_id"] == nil
    assert {:ok, %{"status" => "cancelled"}} = Store.get_task(task["id"])
  end

  test "budgets block new work but allow an explicitly addressed followup", %{root: root} do
    {:ok, cfg} = Source.configure(config(root, %{"mode" => "explicit", "max_per_hour" => 1}))
    {:ok, first} = Source.ingest(cfg["id"], event("1"))
    {:ok, limited} = Source.ingest(cfg["id"], event("2", %{"thread" => "99"}))
    assert limited["disposition"] == "budget_exhausted"
    {:ok, followup} = Source.ingest(cfg["id"], event("3"))
    assert followup["task_id"] == first["task_id"]
    assert followup["disposition"] == "owned"
    assert length(Store.list_tasks()) == 1
  end

  test "reply intentions deduplicate and transport failure cannot change completed work", %{root: root} do
    {:ok, cfg} = Source.configure(config(root, %{"mode" => "explicit"}))
    {:ok, receipt} = Source.ingest(cfg["id"], event("1"))
    id = receipt["task_id"]
    {:ok, _} = Store.update("tasks", id, nil, &{:ok, Map.merge(&1, %{"status" => "done", "result" => "honey-1"})})
    :ok = Store.put("honey", %{"id" => "honey-1", "task_id" => id, "content" => "已完成并验证"})
    assert :ok = Source.collect_replies()
    assert :ok = Source.collect_replies()
    assert [outbox] = Store.all("source_outbox")
    assert {:ok, failed} = Source.deliver(outbox["id"], fn _, _ -> {:error, :timeout} end)
    assert failed["status"] == "pending"
    assert failed["attempts"] == 1
    assert {:ok, %{"status" => "done"}} = Store.get_task(id)
    {:ok, _} = Store.update("source_outbox", outbox["id"], nil, &{:ok, Map.put(&1, "next_at", 0)})
    assert {:ok, delivered} = Source.deliver(outbox["id"], fn _, entry -> {:ok, %{"marker" => entry["id"]}} end)
    assert delivered["status"] == "delivered"
    assert {:ok, ^delivered} = Source.deliver(outbox["id"], fn _, _ -> flunk("duplicate send") end)
    assert :ok = Store.restore()
    assert {:ok, ^delivered} = Store.get("source_outbox", outbox["id"])
  end

  test "GitHub bytes need a valid signature and exact repository; forged caller permissions have no effect", %{
    root: root
  } do
    name = "NEWBEE_SOURCE_TEST_SECRET"
    System.put_env(name, "a-long-test-only-webhook-secret")
    on_exit(fn -> System.delete_env(name) end)

    {:ok, cfg} =
      Source.configure(
        config(root, %{"kind" => "github", "repository" => "owner/repo", "secret_env" => name, "mode" => "explicit"})
      )

    payload = %{
      "action" => "created",
      "repository" => %{"full_name" => "owner/repo"},
      "sender" => %{"login" => "alice", "type" => "User"},
      "issue" => %{"number" => 42, "html_url" => "https://github.com/owner/repo/issues/42"},
      "comment" => %{"body" => "@newbee 修复导出"}
    }

    body = Jason.encode!(payload)
    signature = "sha256=" <> Base.encode16(:crypto.mac(:hmac, :sha256, System.get_env(name), body), case: :lower)
    assert {:error, "unauthorized", _} = Source.github(cfg["id"], "delivery-1", "issue_comment", "bad", body)
    assert Store.all("source_events") == []
    assert {:ok, receipt} = Source.github(cfg["id"], "delivery-1", "issue_comment", signature, body)
    assert receipt["disposition"] == "owned"
    assert {:ok, ^receipt} = Source.github(cfg["id"], "delivery-1", "issue_comment", signature, body)
    assert {:error, "unauthorized", _} = Source.github(cfg["id"], "delivery-2", "issue_comment", signature, body <> " ")
  end

  test "configuration revisions, actor allowlists and stable source roots are enforced", %{root: root} do
    assert {:error, "bad_request", _} = Source.configure(config(root, %{"mode" => "auto", "allowed_actors" => []}))
    {:ok, cfg} = Source.configure(config(root))
    assert {:error, "conflict", _} = Source.configure(config(root, %{"id" => cfg["id"], "revision" => 999}))
    other = Path.join(root, "other")
    File.mkdir_p!(other)

    assert {:error, "source_identity", _} =
             Source.configure(config(other, %{"id" => cfg["id"], "revision" => cfg["revision"]}))
  end

  test "auto requires explicit scoped rules, respects their event type and never admits bots", %{root: root} do
    assert {:error, "bad_request", _} = Source.configure(config(root, %{"mode" => "auto"}))

    {:ok, cfg} =
      Source.configure(
        config(root, %{"mode" => "auto", "auto_prefix" => "[work]", "allowed_event_types" => ["issue.opened"]})
      )

    {:ok, ignored} =
      Source.ingest(
        cfg["id"],
        event("1", %{"explicit" => false, "event_type" => "comment.created", "text" => "[work] 内容"})
      )

    assert ignored["disposition"] == "context_only"

    {:ok, bot} =
      Source.ingest(
        cfg["id"],
        event("2", %{"explicit" => false, "event_type" => "issue.opened", "text" => "[work] 内容", "machine" => true})
      )

    assert bot["disposition"] == "context_only"

    {:ok, owned} =
      Source.ingest(
        cfg["id"],
        event("3", %{"explicit" => false, "event_type" => "issue.opened", "text" => "[work] 有界自动工作"})
      )

    assert owned["disposition"] == "owned"
    assert length(Store.list_tasks()) == 1
  end
end
