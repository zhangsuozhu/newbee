defmodule Newbee.Web.ConversationApiTest do
  use ExUnit.Case, async: false
  alias Newbee.Colony.{Store, ConversationWork, Work, Workspace}
  @moduletag :tmp_dir
  setup %{tmp_dir: root} do
    Store.clear_all()
    File.mkdir_p!(root)
    sid = "api-origin-" <> Integer.to_string(System.unique_integer([:positive]))
    :ok = Newbee.Session.set_cwd(sid, root)
    :ok = Newbee.Session.mark_created(sid)
    server = start_supervised!({Bandit, plug: Newbee.Web.Router, port: 0, ip: {127, 0, 0, 1}})
    {:ok, {_, port}} = ThousandIsland.listener_info(server)
    %{root: root, sid: sid, base: "http://127.0.0.1:#{port}"}
  end

  defp rpc(ctx, method, payload),
    do:
      Req.post!(ctx.base <> "/api/" <> method,
        json: %{rpcId: "conversation-test", payload: Map.put(payload, :sessionId, ctx.sid)}
      ).body["result"]

  defp ready!(ctx, changed) do
    result = rpc(ctx, "conversation.work.start", %{text: "修复CSV导出并验证", requestId: "start"})
    task = result["ok"]["work"]
    assert is_map(task)
    {:ok, stored} = ConversationWork.fetch(ctx.sid, task["id"])
    {:ok, path} = Workspace.ensure(stored, ctx.root)
    if changed, do: File.write!(Path.join(path, "export.txt"), "fixed\n")

    {:ok, stored} =
      Store.update("tasks", task["id"], nil, fn t ->
        workflow = Map.put(t["workflow"], "phase", "executing")
        {:ok, Map.merge(t, %{"mode" => "execution", "status" => "running", "workflow" => workflow})}
      end)

    {:ok, _} =
      Work.submit(
        stored["colony_id"],
        stored["id"],
        %{"content" => "已修复并验证；测试替身提供确定结果", "evidence" => ["测试中直接核对真实文件内容"]},
        stored["assigned_bee_id"]
      )

    stored["id"]
  end

  test "HTTP start → persist → review → apply → finalize → retry uses the same work and files", ctx do
    File.write!(Path.join(ctx.root, "export.txt"), "old\n")
    id = ready!(ctx, true)
    review = rpc(ctx, "conversation.work.review", %{workId: id})["ok"]["review"]
    assert review["file_count"] == 1
    assert review["files"] |> hd() |> Map.get("path") == "export.txt"
    assert review["target_root"] == ctx.root
    assert File.read!(Path.join(ctx.root, "export.txt")) == "old\n"

    result =
      rpc(ctx, "conversation.work.apply", %{workId: id, patchSha256: review["patch_sha256"], requestId: "apply-1"})

    assert result["ok"]["work"]["status"] == "done"
    assert result["ok"]["work"]["apply_state"] == "applied"
    assert File.read!(Path.join(ctx.root, "export.txt")) == "fixed\n"
    assert :ok = Store.restore()

    again =
      rpc(ctx, "conversation.work.apply", %{workId: id, patchSha256: review["patch_sha256"], requestId: "apply-1"})

    assert again["ok"]["work"]["id"] == id
    assert again["ok"]["work"]["status"] == "done"
    history = rpc(ctx, "session.history", %{})["ok"]["messages"]
    assert Enum.any?(history, &String.contains?(&1["text"] || &1["content"] || "", "修复CSV"))
    assert Enum.any?(history, &String.contains?(&1["text"] || &1["content"] || "", "已修复并验证"))
  end

  test "user changes after review remain intact and never become a falsely completed work", ctx do
    File.write!(Path.join(ctx.root, "export.txt"), "old\n")
    id = ready!(ctx, true)
    review = rpc(ctx, "conversation.work.review", %{workId: id})["ok"]["review"]
    File.write!(Path.join(ctx.root, "export.txt"), "user-new-change\n")

    result =
      rpc(ctx, "conversation.work.apply", %{workId: id, patchSha256: review["patch_sha256"], requestId: "apply-1"})

    assert result["error"]["code"] == "workspace_conflict"
    assert File.read!(Path.join(ctx.root, "export.txt")) == "user-new-change\n"
    {:ok, task} = ConversationWork.fetch(ctx.sid, id)
    assert task["status"] == "pending_review"
    assert task["application"] == nil
  end

  test "plain text result can complete without file application, changed files cannot", ctx do
    id = ready!(ctx, false)
    assert rpc(ctx, "conversation.work.review", %{workId: id})["ok"]["review"]["no_changes"]
    done = rpc(ctx, "conversation.work.complete", %{workId: id, requestId: "complete-1"})
    assert done["ok"]["work"]["status"] == "done"
    assert done["ok"]["work"]["apply_state"] == "text_accepted"

    assert rpc(ctx, "conversation.work.complete", %{workId: id, requestId: "complete-1"})["ok"]["work"]["status"] ==
             "done"
  end

  test "a different session cannot read, answer or apply this work; caller's root is ignored", ctx do
    result = rpc(ctx, "conversation.work.start", %{text: "修复导出", requestId: "start", root: "/", cwd: "/"})
    work = result["ok"]["work"]
    assert work["source_root"] == ctx.root
    other_sid = ctx.sid <> "-other"
    :ok = Newbee.Session.set_cwd(other_sid, ctx.root)
    :ok = Newbee.Session.mark_created(other_sid)
    other = %{ctx | sid: other_sid}

    for {method, payload} <- [
          {"conversation.work.input", %{text: "跨会话注入", requestId: "attack"}},
          {"conversation.work.review", %{}},
          {"conversation.work.answer", %{questionId: "fake", text: "yes", requestId: "attack"}},
          {"conversation.work.apply", %{patchSha256: String.duplicate("0", 64), requestId: "attack"}}
        ] do
      assert rpc(other, method, Map.put(payload, :workId, work["id"]))["error"]["code"] == "not_found"
    end

    assert rpc(other, "conversation.work.list", %{})["ok"]["works"] == []
  end

  test "real page serves the integrated work card and original chat remains the default", ctx do
    html = Req.get!(ctx.base <> "/").body
    assert html =~ "/conversation-work.css"
    assert html =~ "/conversation-work.js"
    assert html =~ "/app.js"
    assert Req.get!(ctx.base <> "/conversation-work.js").body =~ "NewbeeConversationWork"
  end

  test "an answer from the main composer keeps its uploaded file through receipt retries and history", ctx do
    {:ok, upload} = Newbee.Upload.store(ctx.sid, "requirements.txt", "text/plain", "keep CSV compatibility\n")
    started = rpc(ctx, "conversation.work.start", %{text: "修复导出", requestId: "with-answer"})
    id = started["ok"]["work"]["id"]

    {:ok, _} =
      Store.update("tasks", id, nil, fn task ->
        {:ok,
         Map.merge(task, %{
           "status" => "blocked",
           "question" => %{"id" => "format-question", "question" => "以哪个要求为准？", "state" => "open"}
         })}
      end)

    answer = %{
      workId: id,
      questionId: "format-question",
      text: "以附件为准",
      requestId: "attached-answer",
      uploadIds: [upload.id]
    }

    assert %{"ok" => receipt} = rpc(ctx, "conversation.work.answer", answer)
    assert %{"ok" => retry} = rpc(ctx, "conversation.work.answer", answer)
    assert receipt["input_id"] == retry["input_id"]
    {:ok, task} = ConversationWork.fetch(ctx.sid, id)
    input = List.last(task["inputs"])
    assert input["upload_ids"] == [upload.id]
    {:ok, delivery} = Store.get("deliveries", input["delivery_id"])
    assert delivery["upload_ids"] == [upload.id]
    assert delivery["upload_sid"] == ctx.sid

    assert {:ok, prompt} =
             Newbee.Upload.prepare_prompt(delivery["upload_sid"], delivery["upload_ids"], delivery["instruction"])

    assert prompt.text =~ "requirements.txt"
    history = rpc(ctx, "session.history", %{})["ok"]["messages"]
    assert Enum.any?(history, &(&1["role"] == "user" and String.contains?(&1["content"], "requirements.txt")))

    assert %{"error" => %{"code" => "request_conflict"}} =
             rpc(ctx, "conversation.work.answer", Map.put(answer, :uploadIds, []))
  end
end
