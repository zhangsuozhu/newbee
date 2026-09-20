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

# 登录后主页是原会话界面；Colony 作为待处理和验收嵌进该界面。
test "会话主页保留原界面，并把蜂群待处理嵌进侧栏" do
home = File.read!(Path.expand("priv/web/index.html"))
js = File.read!(Path.expand("priv/web/app.js"))
surface = File.read!(Path.expand("priv/web/workspace.html"))

assert home =~ ~s|id="session-list"|
assert home =~ ~s|src="/app.js|
assert home =~ ~s|id="work-inbox"|
assert home =~ ~s|id="work-review-bar"|
refute home =~ ~s|id="colony-entry"|
refute home =~ "colony/app.js"
refute home =~ ~s|id="colony-list"|
assert js =~ "startWorkInbox"
assert js =~ "colony.honey.review"
refute js =~ "请从蜂群中打开一个 AI 对话"

assert surface =~ ~s|id="input"|
assert surface =~ ~s|id="terminal-panel"|
end

  test "勾选会话后侧栏出现批量删除按钮" do
    home = File.read!(Path.expand("priv/web/index.html"))
    js = File.read!(Path.expand("priv/web/app.js"))
    css = File.read!(Path.expand("priv/web/style.css"))

    assert home =~ ~s|id="delete-selected-sessions"|
    assert home =~ ~s|class="session-group-actions hidden"|
    assert js =~ "function requestDeleteSelectedSessions()"
    assert js =~ ~s|bind("delete-selected-sessions", requestDeleteSelectedSessions)|
    assert js =~ ~s|bar.classList.toggle("hidden", n === 0)|
    assert js =~ "bar.hidden = n === 0"
    assert js =~ ~s|rpc("session.delete", { sessionId: s.id })|
    assert css =~ ".session-group-actions"
    assert css =~ ".session-delete-selected"
    assert css =~ "#session-list:has(+ .session-group-actions:not(.hidden)) .session-select"
    assert File.read!(Path.expand("priv/web/workspace.html")) =~ ~s|id="delete-selected-sessions"|
  end



  test "工作卡显示任务 cwd，目录入口保留 taskId" do
    taskcard = File.read!("priv/web/colony/taskcard.js")
    workflow = File.read!("priv/web/colony/workflow.js")
    shell = File.read!("priv/web/colony/shell.js")
    css = File.read!("priv/web/colony/colony.css")
    app = File.read!("priv/web/colony/app.js")

    assert taskcard =~ "className = 'work-cwd'"
    assert taskcard =~ "work-cwd-path"
    assert workflow =~ "className = 'work-cwd'"
    assert shell =~ "taskIdOverride"
    assert shell =~ "params.set('task', taskId)"
    assert css =~ ".work-cwd-path"
    assert css =~ "#flow > [data-drill-section][hidden]"
    assert app =~ "const todo = attention.length + pendingHoney;"
  end

  test "工作详情提供成果、历史、协作和可恢复的 Esc 关闭行为" do
    drill = File.read!("priv/web/colony/drill.js")
    workbench = File.read!("priv/web/colony/workbench.js")
    store = File.read!("priv/web/colony/store.js")
    app = File.read!("priv/web/colony/app.js")
    taskcard = File.read!("priv/web/colony/taskcard.js")
    workflow = File.read!("priv/web/colony/workflow.js")
    composer = File.read!("priv/web/colony/composer.js")
    colony = File.read!("priv/web/colony.html")


    assert drill =~ "成果验收"
    assert drill =~ "renderWorkHistory"
    assert drill =~ "work-collab-panel"
    assert drill =~ "没有不可变快照"
    assert drill =~ "if (t.type === 'honey') return false;"
    assert drill =~ "node.append(summary);"
    assert taskcard =~ "direct.onclick"
    assert workflow =~ "direct.onclick"
    assert workbench =~ "closeInspector();"
    refute workbench =~ "history.back()"
    assert store =~ "'section'"
    assert app =~ "drill.js?v=workbench-"
    assert composer =~ "aria-describedby"
    assert composer =~ "给当前工作补充要求"
    assert colony =~ ~s|aria-label="发起新工作或发送群聊消息"|

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
