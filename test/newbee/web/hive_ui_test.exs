defmodule Newbee.Web.HiveUiTest do
  use ExUnit.Case, async: true

  @app_path Path.expand("priv/web/app.js")

  test "Web 协作 UI 只使用 Hive Board 合同" do
    js = File.read!(@app_path)

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

    refute js =~ ~s|rpc("group.task.list"|
    refute js =~ ~s|rpc("group.task.create"|
    refute js =~ ~s|rpc("group.task.claim"|
    refute js =~ ~s|rpc("group.member.delegate"|
    refute js =~ "group.member.delegate"
    refute js =~ "口头约定"

    assert js =~ "boardRevision"
    assert js =~ "writeScopeOverlaps"
    assert js =~ "expectedRevision"
    assert js =~ "data-verify-task"
    assert js =~ "data-retry-task"
    assert js =~ "data-cancel-task"
    assert js =~ "cancelCollaborationTask"
    assert js =~ "session-group-rename"
    assert js =~ "renameGroup"
    assert js =~ "group.rename"
    assert js =~ "createdFresh"
    assert js =~ "已清理半成品组"
    assert js =~ "renderSubmission"
    assert js =~ "collab_task_updated"
  end

  # 蜂群是登录后的唯一主页：旧工作组/跨主机建群的可见入口与其对话框全部移除，
  # 原会话界面作为工作区表面继续提供终端、模型、目录、监控等能力。
  test "蜂群主页取代旧工作组入口，会话界面退居工作区表面" do
    home = File.read!(Path.expand("priv/web/index.html"))
    surface = File.read!(Path.expand("priv/web/workspace.html"))

    assert home =~ ~s|id="colony-list"|
    assert home =~ ~s|id="model-label"|
    assert home =~ ~s|id="cwd-label"|
    assert home =~ ~s|id="terminal-toggle"|
    assert home =~ ~s|id="mc-expand"|
    assert home =~ "colony/app.js"
    assert home =~ "colony/shell.css"
    # 主页的输入框是蜂群群聊用的；会话界面独有的元素不出现。
    refute home =~ ~s|id="session-list"|, "主页不再内嵌会话列表"
    refute home =~ ~s|id="mission-control"|, "Mission Control 跟随 AI 对话"

    for page <- [home, surface] do
      for id <- ~w(group-modal delegate-modal task-modal xcreate-modal xjoin-modal xmanage-modal) do
        refute page =~ ~s|id="#{id}"|, "#{id} 应已移除"
      end

      refute page =~ ~s|id="delegate-session"|
      refute page =~ ~s|id="colony-entry"|
      refute page =~ ~s|id="session-menu-remove-group"|
      refute page =~ ~s|选择会话组成工作组|
    end

    assert surface =~ ~s|id="input"|
    assert surface =~ ~s|id="terminal-panel"|
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

  test "WebSocket 切会话后丢弃旧连接的事件帧" do
    case System.find_executable("bun") do
      nil ->
        :ok

      bun ->
        script =
          ~S'''
          const fs = require("fs");
          const js = fs.readFileSync(__APP_PATH__, "utf8");
          const start = js.indexOf("  let reconnectTimer = 0;");
          const end = js.indexOf("  // ── 终端 ──", start);
          if (start < 0 || end < 0) throw new Error("missing WebSocket source");
          const source = js.slice(start, end);
          const state = { sid: "session-a", ws: null, token: null, terminal: { open: false } };
          const sockets = [];
          class FakeWebSocket {
            constructor(url) { this.url = url; this.readyState = 1; sockets.push(this); }
            close() { this.readyState = 3; }
          }
          let events = 0;
          let groupEvents = 0;
          function assert(condition, message) { if (!condition) throw new Error(message); }
          function line() {}
          function onEvent() { events += 1; }
          function onGroupEvent() { groupEvents += 1; }
          function onTerminalFrame() {}
          function pushEvoEvent() {}
          function terminalRequestOpen() {}
          function terminalSetInterruptEnabled() {}
          function terminalStatus() {}
          const api = new Function(
            "state", "WebSocket", "location", "line", "onEvent", "onGroupEvent",
            "onTerminalFrame", "pushEvoEvent", "terminalRequestOpen",
            "terminalSetInterruptEnabled", "terminalStatus",
            source + "; return { connect, disconnectSocket };"
          )(state, FakeWebSocket, { protocol: "http:", host: "example.test" }, line, onEvent, onGroupEvent,
            onTerminalFrame, pushEvoEvent, terminalRequestOpen, terminalSetInterruptEnabled, terminalStatus);

          api.connect();
          const first = sockets[0];
          const staleMessage = first.onmessage;
          const staleOpen = first.onopen;
          staleMessage({ data: JSON.stringify({ type: "group_event", sessionId: "session-a" }) });
          assert(groupEvents === 1, "current connection should deliver its group event");

          state.sid = "session-b";
          api.connect();
          staleMessage({ data: JSON.stringify({ type: "group_event", sessionId: "session-a" }) });
          staleOpen();
          assert(groupEvents === 1, "stale group events must not reach the new session");

          const second = sockets[1];
          second.onmessage({ data: JSON.stringify({ type: "group_event", sessionId: "session-a" }) });
          second.onmessage({ data: JSON.stringify({ type: "group_event", sessionId: "session-b" }) });
          second.onmessage({ data: JSON.stringify({ type: "event", sessionId: "session-a", kind: "text", payload: {} }) });
          second.onmessage({ data: JSON.stringify({ type: "event", sessionId: "session-b", kind: "text", payload: {} }) });
          assert(groupEvents === 2, "only the active session group event should render");
          assert(events === 1, "only the active session event should render");
          console.log("session output isolation ok");
          '''
          |> String.replace("__APP_PATH__", Jason.encode!(@app_path))

        {output, status} =
          System.cmd(bun, ["-e", script], cd: File.cwd!(), stderr_to_stdout: true)

        assert status == 0, output
        assert output =~ "session output isolation ok"
    end
  end

  test "历史回放切换会话时重置分页与工具状态" do
    case System.find_executable("bun") do
      nil ->
        :ok

      bun ->
        script =
          ~S'''
          const fs = require("fs");
          const js = fs.readFileSync(__APP_PATH__, "utf8");
          const start = js.indexOf("  // 分页加载常量");
          const end = js.indexOf("  // 回放专用静态工具卡", start);
          if (start < 0 || end < 0) throw new Error("missing history source");
          const source = js.slice(start, end);
          const flow = { innerHTML: "stale" };
          const MC = { _replaying: false, steps: [] };
          const rendered = [];
          function assert(condition, message) { if (!condition) throw new Error(message); }
          function renderLoadMoreBtn(remaining) { rendered.push("more:" + remaining); }
          function renderOneMsg(message) { rendered.push(message.id); }
          function renderMCSteps() {}
          function initInfiniteHistory() {}
          function scrollBottom() {}
          const body = [
            "let replayToolCards = {};",
            "let replayPendingUsage = { old: true };",
            source,
            "return { renderHistory, state: () => ({ historyOffset, replayPendingUsage, allHistoryMsgs }) };"
          ].join("\\n");
          const api = new Function(
            "flow", "MC", "renderLoadMoreBtn", "renderOneMsg", "renderMCSteps", "initInfiniteHistory", "scrollBottom", body
          )(flow, MC, renderLoadMoreBtn, renderOneMsg, renderMCSteps, initInfiniteHistory, scrollBottom);

          api.renderHistory(Array.from({ length: 51 }, (_, index) => ({ id: "long-" + index })));
          assert(api.state().historyOffset === 1, "long history should expose one earlier message");
          assert(api.state().replayPendingUsage === null, "history replay must clear pending usage");
          flow.innerHTML = "old session";
          api.renderHistory([{ id: "short" }]);
          assert(flow.innerHTML === "", "history replay must replace the old flow");
          assert(api.state().historyOffset === 0, "short history must reset the old pagination cursor");
          assert(api.state().allHistoryMsgs.length === 1 && api.state().allHistoryMsgs[0].id === "short", "history cache must belong to the active session");
          assert(rendered[rendered.length - 1] === "short", "only the active history should render");
          console.log("history isolation ok");
          '''
          |> String.replace("__APP_PATH__", Jason.encode!(@app_path))

        {output, status} =
          System.cmd(bun, ["-e", script], cd: File.cwd!(), stderr_to_stdout: true)

        assert status == 0, output
    end
  end

  test "群头部提供群管理操作且成员数保持在右侧" do
    sidebar = File.read!("priv/web/colony/sidebar.js")
    manage = File.read!("priv/web/colony/manage.js")
    css = File.read!("priv/web/colony/colony.css")

    assert sidebar =~ "session-group-menu-btn"
    assert sidebar =~ "renameColony"
    assert sidebar =~ "dissolveColony"
    assert manage =~ "colony.rename"
    assert manage =~ "colony.dissolve"
    assert css =~ ".session-group-menu-btn"
  end
end
