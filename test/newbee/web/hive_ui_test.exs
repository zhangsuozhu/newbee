defmodule Newbee.Web.HiveUiTest do
  use ExUnit.Case, async: true

  @app_path Path.expand("priv/web/app.js")

  test "Web 协作 UI 只使用 Hive Board 合同" do
    js = File.read!(@app_path)
    html = File.read!(Path.expand("priv/web/index.html"))

    for method <- [
          ~s|rpc("hive.board"|,
          ~s|hive.task.create|,
          ~s|hive.task.update|,
          ~s|hive.task.claim|,
          ~s|hive.task.verify|,
          ~s|hive.task.retry|,
          ~s|rpc("hive.delegate"|
        ] do
      assert js =~ method
    end

    refute js =~ "group.task.list"
    refute js =~ "group.task.create"
    refute js =~ "group.task.claim"
    refute js =~ "group.member.delegate"
    refute js =~ "口头约定"

    assert js =~ "boardRevision"
    assert js =~ "writeScopeOverlaps"
    assert js =~ "expectedRevision"
    assert js =~ "data-verify-task"
    assert js =~ "data-retry-task"
    assert js =~ "renderSubmission"
    assert js =~ "collab_task_updated"
    assert html =~ ~s|id="mc-task-conflicts"|
    assert html =~ ~s|id="delegate-acceptance-list"|
    assert html =~ ~s|id="delegate-persona"|
    assert html =~ ~s|id="delegate-fork-turns"|
    assert html =~ ~s|id="delegate-depends"|
    assert html =~ ~s|id="delegate-write-scope"|
  end

  test "Bun 执行真实 Hive UI helper 与 CAS mutation 行为" do
    case System.find_executable("bun") do
      nil ->
        :ok

      bun ->
        script =
          ~S'''
          const fs = require("fs");
          const js = fs.readFileSync(__APP_PATH__, "utf8");

          function between(startText, endText) {
            const start = js.indexOf(startText);
            const end = js.indexOf(endText, start);
            if (start < 0 || end < 0) throw new Error(`missing source range: ${startText}`);
            return js.slice(start, end);
          }
          function assert(condition, message) {
            if (!condition) throw new Error(message);
          }

          const state = { sid: "lead", activeGroupId: "g1", boardRevision: 7 };
          let commandArgs = '["test","--trace","test/path with spaces.exs"]';
          const rows = [
            { querySelector: (selector) => selector.includes("kind") ? { value: "command" } : selector.includes("main") ? { value: "mix" } : { value: commandArgs } },
            { querySelector: (selector) => selector.includes("kind") ? { value: "file_exists" } : selector.includes("main") ? { value: "proof.txt" } : { value: "" } }
          ];
          globalThis.document = { querySelectorAll: () => rows };

          const semantic = between("  function taskAttentionKind", "  function renderCollaborationPane") +
            "\n" + between("  function splitInputList", "  async function delegateSession") +
            "\n" + between("  const acceptancePrograms", "  function buildAcceptance") +
            between("  function buildAcceptance", "  function buildTaskAcceptance");

          const helpers = new Function("state", semantic + "; return { taskAttentionKind, taskMatchesFilter, splitInputList, buildAcceptance }; ")(state);

          assert(helpers.taskAttentionKind({ status: "submitted" }) === "review", "submitted must require acceptance");
          assert(helpers.taskAttentionKind({ status: "running", workspace: { review_status: "pending" } }) === null, "workspace review must not be task acceptance");
          assert(helpers.taskMatchesFilter({ status: "submitted" }) === true, "submitted must be in review filter");
          assert(JSON.stringify(helpers.splitInputList("a, b\n c")) === JSON.stringify(["a", "b", "c"]), "list input parsing");

          const built = helpers.buildAcceptance("acceptance-list");
          assert(JSON.stringify(built.criteria) === JSON.stringify([
            { kind: "command", program: "mix", args: ["test", "--trace", "test/path with spaces.exs"] },
            { kind: "file_exists", path: "proof.txt" }
          ]), "acceptance must be structured: " + JSON.stringify(built));


          commandArgs = 'not-json';
          assert(helpers.buildAcceptance("acceptance-list").error, "invalid JSON must be rejected");
          commandArgs = '["test",3]';
          assert(helpers.buildAcceptance("acceptance-list").error, "non-string argv must be rejected");

          let scenario = "ok";
          let errors = 0;
          let calls = [];
          let reloads = 0;
          async function rpc(method, payload) {
            calls.push({ method, payload });
            if (scenario.startsWith("conflict")) throw new Error("revision_conflict");
            if (scenario === "switch") { state.sid = "other"; state.activeGroupId = "g2"; }
            return { task: { task_id: "t1" }, revision: 8 };
          }
          async function loadActiveGroup() {
            reloads += 1;
            if (scenario === "conflict-switch") { state.sid = "other"; state.activeGroupId = "g2"; }
          }
          function line(kind) { if (kind === "error") errors += 1; }
          const mutation = between("  let hiveCommandSeq = 0;", "  function bindTaskActions");
          const runMutation = new Function("state", "rpc", "loadActiveGroup", "line", "let groupLoadSeq = 11;" + mutation + "; return hiveTaskMutation;")(state, rpc, loadActiveGroup, line);
          await runMutation("hive.task.update", "t1", { status: "submitted" }, "update");
          assert(calls.length === 1 && calls[0].method === "hive.task.update", "Hive update method");
          assert(calls[0].payload.groupId === "g1" && calls[0].payload.taskId === "t1", "task identity payload");
          assert(calls[0].payload.expectedRevision === 7, "expectedRevision payload");
          assert(typeof calls[0].payload.commandId === "string" && calls[0].payload.commandId.length > 0, "commandId payload");
          assert(reloads === 1, "successful mutation reloads board");
          scenario = "switch";
          assert(await runMutation("hive.task.verify", "t1", {}, "verify") === null, "late result must not affect another session");
          assert(reloads === 1, "late result must not reload the new session");
          scenario = "conflict"; state.sid = "lead"; state.activeGroupId = "g1";
          assert(await runMutation("hive.task.update", "t1", {}, "update") === null, "revision conflict stays failed");
          assert(reloads === 2 && errors === 1, "conflict reloads board and reports once without replay");
          scenario = "conflict-switch";
          await runMutation("hive.task.update", "t1", {}, "update");
          assert(errors === 1, "late conflict must not append an error to another session");
          scenario = "ok"; state.sid = "lead"; state.activeGroupId = "g1";
          const retry = await runMutation("hive.task.retry", "t1", { reason: "manual retry" }, "retry");
          assert(retry && calls[calls.length - 1].method === "hive.task.retry", "retry uses Hive mutation");
          assert(calls[calls.length - 1].payload.reason === "manual retry", "retry reason payload");
          console.log("hive ui behavior ok");
          '''
          |> String.replace("__APP_PATH__", Jason.encode!(@app_path))

        {output, status} =
          System.cmd(bun, ["-e", script], cd: File.cwd!(), stderr_to_stdout: true)

        assert status == 0, output
        assert output =~ "hive ui behavior ok"
    end
  end
end
