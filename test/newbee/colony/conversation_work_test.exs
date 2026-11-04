defmodule Newbee.Colony.ConversationWorkTest do
  use ExUnit.Case, async: false
  alias Newbee.Colony.{ConversationWork, Store, Work, Control}
  @moduletag :tmp_dir

  defmodule ReceiptSession do
    use GenServer
    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)
    @impl true
    def init(opts) do
      {:ok, _} = Registry.register(Newbee.Web.SessionRegistry, opts[:sid], nil)
      {:ok, opts}
    end

    @impl true
    def handle_call({:colony_received, _}, _from, opts) do
      Process.sleep(opts[:delay] || 0)
      {:reply, opts[:received], opts}
    end
  end

  setup %{tmp_dir: root} do
    File.mkdir_p!(root)
    Store.clear_all()
    %{root: root, sid: "origin-" <> Integer.to_string(System.unique_integer([:positive]))}
  end

  test "retries and concurrent requests create exactly one durable work", %{root: root, sid: sid} do
    results =
      1..12
      |> Task.async_stream(fn _ -> ConversationWork.start(sid, root, "修复导出并验证", "same") end, max_concurrency: 4)
      |> Enum.to_list()

    ids = Enum.map(results, fn {:ok, {:ok, result}} -> result["work"]["id"] end)
    assert length(Enum.uniq(ids)) == 1
    assert length(Store.list_tasks()) == 1
    assert length(Store.all("deliveries")) == 1
    assert length(Store.all("command_receipts")) == 1
    assert {:error, "request_conflict", _} = ConversationWork.start(sid, root, "修改了内容", "same")
    assert {:error, "work_active", _} = ConversationWork.start(sid, root, "另一项工作", "different")
    assert length(Store.all("deliveries")) == 1
  end

  test "follow-up has separate durable receive and consumption facts", %{root: root, sid: sid} do
    {:ok, result} = ConversationWork.start(sid, root, "修复导出", "start")
    id = result["work"]["id"]
    {:ok, received} = ConversationWork.input(sid, id, "不要改变非空日期格式", "followup")
    assert received["work"]["context_revision"] == 1
    assert Enum.all?(received["work"]["inputs"], &is_nil(&1["consumed_at"]))
    assert {:ok, retry} = ConversationWork.input(sid, id, "不要改变非空日期格式", "followup")
    assert retry["input_id"] == received["input_id"]
    assert length(Store.all("deliveries")) == 2
    input = List.last(received["work"]["inputs"])
    {:ok, _} = Store.update("deliveries", input["delivery_id"], nil, &{:ok, Map.put(&1, "status", "accepted")})
    assert :ok = ConversationWork.consumed(input["delivery_id"])
    {:ok, current} = ConversationWork.fetch(sid, id)
    assert List.last(current["inputs"])["consumed_at"] > 0
    assert hd(current["inputs"])["consumed_at"] > 0
    assert current["consumed_context_revision"] == 1
    assert :ok = Store.restore()
    {:ok, restored} = ConversationWork.fetch(sid, id)
    assert restored["inputs"] == current["inputs"]
    assert {:ok, _} = ConversationWork.input(sid, id, "不要改变非空日期格式", "followup")
    assert length(Store.all("deliveries")) == 2
  end

  test "one question can be answered once; retries succeed and stale answers cannot resume", %{root: root, sid: sid} do
    {:ok, result} = ConversationWork.start(sid, root, "修复导出", "start")
    id = result["work"]["id"]
    {:ok, task} = ConversationWork.fetch(sid, id)
    question = ConversationWork.question(task, %{question: "空日期如何表示？", options: ["空字符串", "跳过"]})

    {:ok, _} =
      Store.update(
        "tasks",
        id,
        nil,
        &{:ok, Map.merge(&1, %{"question" => question, "status" => "blocked", "waiting_for" => "user"})}
      )

    assert {:error, "stale_question", _} = ConversationWork.answer(sid, id, "another-question", "空字符串", "bad")
    assert length(Store.all("deliveries")) == 1
    assert {:ok, answer} = ConversationWork.answer(sid, id, question["id"], "空字符串", "answer")
    assert answer["work"]["question"] == nil
    assert {:ok, _} = ConversationWork.answer(sid, id, question["id"], "空字符串", "answer")
    assert {:error, "stale_question", _} = ConversationWork.answer(sid, id, question["id"], "跳过", "another-answer")
    assert length(Store.all("deliveries")) == 2
  end

  test "pausing preserves requirements; follow-up does not resume and recovery fences old generation", %{
    root: root,
    sid: sid
  } do
    {:ok, result} = ConversationWork.start(sid, root, "修复导出", "start")
    id = result["work"]["id"]
    old_delivery = hd(Store.all("deliveries"))
    assert {:ok, paused} = ConversationWork.control(sid, id, "pause")
    assert paused["work"]["stage"] == "paused"
    assert {:ok, _} = ConversationWork.input(sid, id, "新增要求：保留旧格式", "extra")
    {:ok, task} = ConversationWork.fetch(sid, id)
    assert Control.blocked?(task["colony_id"], task["assigned_bee_id"], id)
    assert Enum.all?(task["inputs"], &is_nil(&1["consumed_at"]))
    assert {:ok, resumed} = ConversationWork.control(sid, id, "resume")
    assert resumed["work"]["execution_generation"] == 2
    {:ok, current} = ConversationWork.fetch(sid, id)
    assert not Control.blocked?(task["colony_id"], task["assigned_bee_id"], id)

    assert not ConversationWork.current_event?(current, :done, %{
             execution_generation: 1,
             delivery_id: old_delivery["id"]
           })

    resume_delivery = Enum.find(Store.all("deliveries"), &(&1["status"] == "pending"))
    assert Work.context(current, resume_delivery["instruction"]) =~ "保留旧格式"
  end

  test "work and result messages cannot cross origin conversations", %{root: root, sid: sid} do
    {:ok, result} = ConversationWork.start(sid, root, "修复导出", "start")
    id = result["work"]["id"]
    assert ConversationWork.list("other-session") == []
    assert {:error, "not_found", _} = ConversationWork.fetch("other-session", id)
    assert {:error, "not_found", _} = ConversationWork.input("other-session", id, "越权补充", "attack")
    assert {:error, "not_found", _} = ConversationWork.control("other-session", id, "stop")
    assert length(Store.all("deliveries")) == 1
  end

  test "completed work is immutable and a next request links back to it", %{root: root, sid: sid} do
    {:ok, result} = ConversationWork.start(sid, root, "修复导出", "start")
    id = result["work"]["id"]
    {:ok, _} = Store.update("tasks", id, nil, &{:ok, Map.put(&1, "status", "done")})
    assert {:error, "terminal", _} = ConversationWork.input(sid, id, "更多要求", "extra")
    assert {:ok, next} = ConversationWork.start(sid, root, "补充一项导出规则", "next")
    assert next["work"]["predecessor_id"] == id
    assert next["work"]["id"] != id
  end

  test "disk failure cannot acknowledge a request or leave a partial bootstrap", %{root: root, sid: sid} do
    state = :sys.get_state(Store)
    bad_path = Path.join(root, "directory-not-snapshot")
    File.mkdir_p!(bad_path)
    :sys.replace_state(Store, &Map.put(&1, :path, bad_path))
    on_exit(fn -> :sys.replace_state(Store, fn _ -> state end) end)
    assert {:error, {:persistence_failed, _}} = ConversationWork.start(sid, root, "修复导出", "start")
    assert Store.list_tasks() == []
    assert Store.all("command_receipts") == []
    assert Store.all("colonies") == []
    assert Store.all("deliveries") == []
  end

  test "real runtime events advance triage to result, suppress premature results, and reject duplicate completion", %{
    root: root,
    sid: sid
  } do
    {:ok, result} = ConversationWork.start(sid, root, "修复并验证导出", "start", decompose: false)
    id = result["work"]["id"]
    execution_sid = "execution-" <> sid
    {:ok, task} = ConversationWork.fetch(sid, id)

    :ok =
      Store.put("conversations", %{
        "id" => execution_sid,
        "colony_id" => task["colony_id"],
        "bee_id" => task["assigned_bee_id"],
        "task_id" => id,
        "visibility" => "work"
      })

    {:ok, _} = Store.update("tasks", id, nil, &{:ok, Map.put(&1, "session_id", execution_sid)})
    triage = hd(Store.all("deliveries"))
    {:ok, _} = Store.update("deliveries", triage["id"], nil, &{:ok, Map.put(&1, "status", "accepted")})
    :ok = ConversationWork.consumed(triage["id"])

    Newbee.Colony.Runtime.project(execution_sid, :done, %{
      summary: ~s({"route":"self","reason":"边界明确","participants":[]}),
      delivery_id: triage["id"],
      execution_generation: 1
    })

    {:ok, executing} = ConversationWork.fetch(sid, id)
    assert executing["mode"] == "execution"
    delivery = Enum.find(Store.all("deliveries"), &(&1["status"] == "pending"))
    {:ok, _} = Store.update("deliveries", delivery["id"], nil, &{:ok, Map.put(&1, "status", "accepted")})
    :ok = ConversationWork.consumed(delivery["id"])
    {:ok, followup} = ConversationWork.input(sid, id, "兼容已有格式", "followup")
    event = %{summary: "已完成，真实验证证据在工作记录", delivery_id: delivery["id"], execution_generation: 1}
    Newbee.Colony.Runtime.project(execution_sid, :done, event)
    assert Store.all("honey") == []
    pending = Enum.find(Store.all("deliveries"), &(&1["input_id"] == followup["input_id"]))
    {:ok, _} = Store.update("deliveries", pending["id"], nil, &{:ok, Map.put(&1, "status", "accepted")})
    :ok = ConversationWork.consumed(pending["id"])
    Newbee.Colony.Runtime.project(execution_sid, :done, event)
    {:ok, ready} = ConversationWork.fetch(sid, id)
    assert ready["status"] == "pending_review"
    assert ConversationWork.view(ready)["result"]["work_revision"] == followup["work"]["context_revision"]

    assert {:error, "apply_required", _} =
             Work.review(ready["colony_id"], ready["result"], "accept", ready["created_by"])

    Newbee.Colony.Runtime.project(execution_sid, :done, event)
    assert length(Store.all("honey")) == 1
  end

  test "late dispatches are fenced at the receiver before they can become user prompts", %{root: root, sid: sid} do
    {:ok, result} = ConversationWork.start(sid, root, "修复导出", "start")
    id = result["work"]["id"]
    delivery = hd(Store.all("deliveries"))
    {:ok, _} = Store.update("deliveries", delivery["id"], nil, &{:ok, Map.put(&1, "status", "dispatching")})
    assert ConversationWork.delivery_current?(delivery["id"])
    {:ok, _} = ConversationWork.control(sid, id, "pause")
    {:ok, _} = ConversationWork.control(sid, id, "resume")
    refute ConversationWork.delivery_current?(delivery["id"])
  end

  test "schema v1 and v2 preserve original snapshots and initialize new durable tables", %{root: root} do
    for version <- [1, 2] do
      path = Path.join(root, "legacy-#{version}.json")

      bytes =
        Jason.encode!(%{
          "version" => version,
          "sequence" => 0,
          "tasks" => [%{"id" => "old-task", "title" => "existing"}]
        })

      File.write!(path, bytes)
      assert {:ok, state} = Store.init(path: path)
      assert state.data["version"] == 3
      assert state.data["tasks"]["old-task"]["title"] == "existing"
      assert state.data["command_receipts"] == %{}
      assert state.data["source_events"] == %{}
      assert File.read!(path <> ".v#{version}-backup") == bytes
      assert File.read!(path) == bytes
    end
  end

  test "uncertain execution saves followups without dispatch, then a verified recovery consumes the saved requirements",
       %{root: root, sid: sid} do
    {:ok, result} = ConversationWork.start(sid, root, "修复导出", "start")
    id = result["work"]["id"]

    {:ok, _} =
      Store.update(
        "tasks",
        id,
        nil,
        &{:ok, Map.merge(&1, %{"status" => "blocked", "next_step" => "执行回执丢失，无法确认已有外部效果"})}
      )

    {:ok, received} = ConversationWork.input(sid, id, "不要改变已有格式", "followup")
    {:ok, task} = ConversationWork.fetch(sid, id)
    followup = List.last(task["inputs"])
    assert {:ok, %{"status" => "held"}} = Store.get("deliveries", followup["delivery_id"])
    assert List.last(received["work"]["inputs"])["consumed_at"] == nil
    {:ok, _} = ConversationWork.control(sid, id, "retry")
    delivery = Enum.find(Store.all("deliveries"), &(&1["status"] == "pending"))
    assert :ok = ConversationWork.consumed(delivery["id"])
    {:ok, current} = ConversationWork.fetch(sid, id)
    assert Enum.all?(current["inputs"], &is_integer(&1["consumed_at"]))
  end

  test "background facts keep the original session discoverable and hide its implementation session", %{
    root: root,
    sid: sid
  } do
    start_supervised!(
      {Newbee.Collaboration.Coordinator, path: Path.join(root, "sweep-events.jsonl"), durability: :event}
    )

    :ok = Newbee.Session.set_cwd(sid, root)
    :ok = Newbee.Session.mark_created(sid)
    {:ok, result} = ConversationWork.start(sid, root, "修复日期导出", "start")
    id = result["work"]["id"]
    {:ok, _} = Store.update("tasks", id, nil, &{:ok, Map.put(&1, "session_id", "work-" <> id)})
    entries = ConversationWork.project_index([%{"id" => sid, "mtime" => 1}, %{"id" => "work-" <> id, "mtime" => 1}])
    assert [entry] = entries
    assert entry["id"] == sid
    assert entry["background_title"] == "修复日期导出"
    assert entry["background_count"] == 1
    assert entry["mtime"] > 1
    assert ConversationWork.origin?(sid)
    assert ConversationWork.active?(sid)
    assert sid not in Newbee.Web.Session.sweep_stale_empty(0)
  end

  test "a slow receipt query preserves durable acceptance and the real result", %{root: root, sid: sid} do
    {id, execution_sid, delivery} = receipt_fixture(root, sid)
    start_supervised!({ReceiptSession, sid: execution_sid, delay: 1_200, received: true})
    Newbee.Colony.Runtime.sweep()
    assert {:ok, %{"status" => "accepted"}} = Store.get("deliveries", delivery["id"])
    assert {:ok, %{"status" => "running"}} = ConversationWork.fetch(sid, id)
    event = %{summary: "真实完成回执", delivery_id: delivery["id"], execution_generation: 1}
    Newbee.Colony.Runtime.project(execution_sid, :done, event)
    assert {:ok, %{"status" => "pending_review"}} = ConversationWork.fetch(sid, id)
    Newbee.Colony.Runtime.project(execution_sid, :done, event)
    assert length(Store.all("honey")) == 1
  end

  test "confirmed absence of a receipt still blocks without automatically replaying", %{root: root, sid: sid} do
    {id, execution_sid, delivery} = receipt_fixture(root, sid)
    start_supervised!({ReceiptSession, sid: execution_sid, received: false})
    Newbee.Colony.Runtime.sweep()
    assert {:ok, %{"status" => "unknown"}} = Store.get("deliveries", delivery["id"])
    assert {:ok, %{"status" => "blocked"}} = ConversationWork.fetch(sid, id)
    assert length(Store.all("deliveries")) == 1
  end

  defp receipt_fixture(root, sid) do
    {:ok, result} = ConversationWork.start(sid, root, "修复并验证导出", "receipt")
    id = result["work"]["id"]
    execution_sid = "execution-" <> sid
    {:ok, task} = ConversationWork.fetch(sid, id)

    :ok =
      Store.put("conversations", %{
        "id" => execution_sid,
        "colony_id" => task["colony_id"],
        "bee_id" => task["assigned_bee_id"],
        "task_id" => id,
        "visibility" => "work"
      })

    {:ok, _} =
      Store.update("tasks", id, nil, fn current ->
        {:ok,
         Map.merge(current, %{
           "session_id" => execution_sid,
           "status" => "running",
           "mode" => "execution",
           "workflow" => Map.put(current["workflow"], "phase", "executing")
         })}
      end)

    delivery = hd(Store.all("deliveries"))

    {:ok, delivery} =
      Store.update(
        "deliveries",
        delivery["id"],
        nil,
        &{:ok, Map.merge(&1, %{"status" => "accepted", "session_id" => execution_sid})}
      )

    :ok = ConversationWork.consumed(delivery["id"])
    {id, execution_sid, delivery}
  end
end
