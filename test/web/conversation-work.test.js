// 定向测试：priv/web/conversation-work.js（原会话工作卡 / 后台操作）。
// 运行：node --test test/web/conversation-work.test.js
// 只测组件自身行为，不启动 Elixir 服务；RPC 用记录调用的假实现。

const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const {install} = require("./conversation_work_dom.js");

const ROOT = path.resolve(__dirname, "..", "..");
const SOURCE = fs.readFileSync(path.join(ROOT, "priv/web/conversation-work.js"), "utf8");
const CSS = fs.readFileSync(path.join(ROOT, "priv/web/conversation-work.css"), "utf8");

function loadComponent() {
  install();
  delete require.cache[require.resolve(path.join(ROOT, "priv/web/conversation-work.js"))];
  require(path.join(ROOT, "priv/web/conversation-work.js"));
  return globalThis.window.NewbeeConversationWork;
}

function work(overrides) {
  return Object.assign({
    id: "w1",
    title: "修复 CSV 导出空日期",
    status: "running",
    stage: "working",
    origin_session_id: "s1",
    source_root: "/projects/demo",
    workspace_path: "/tmp/ws-1",
    isolated: false,
    summary: "",
    result: {},
    apply_state: "",
    activity: [],
    next_step: "",
    revision: 3,
    context_revision: 7,
    execution_generation: 1
  }, overrides || {});
}

// 假 RPC：按方法返回预设结果，并记录每次调用。
function fakeRpc(handlers) {
  const calls = [];
  const rpc = async (method, payload) => {
    calls.push({method: method, payload: payload});
    const handler = handlers[method];
    if (typeof handler === "function") return handler(payload, calls);
    return {};
  };
  return {rpc: rpc, calls: calls, methods: () => calls.map((c) => c.method)};
}

function hostFor(env, extra) {
  env.draft = env.draft || "";
  env.notices = env.notices || [];
  env.appended = env.appended || [];
  return Object.assign({
    rpc: env.rpc,
    getSessionId: () => env.sessionId,
    getDirectory: () => "/projects/demo",
    notify: (text, kind) => { env.notices.push({text: text, kind: kind}); },
    readDraft: () => env.draft,
    writeDraft: (text) => { env.draft = text; },
    appendUser: (text) => { env.appended.push(text); }
  }, extra || {});
}

function card() { return document.getElementById("conversation-work"); }

function textOfCard() {
  const node = card();
  return node ? node.textContent : "";
}

function findByText(root, needle) {
  return root.allElements().find((node) =>
    node.nodeType === 1 &&
    node.children.every((child) => child.nodeType === 3) &&
    node.textContent.trim() === needle
  ) || null;
}

function buttons(root) {
  return root.allElements().filter((node) => node.tagName === "BUTTON");
}

const live = [];

function setup(env, overrides) {
  const Component = loadComponent();
  const instance = Component.init(hostFor(env, overrides));
  live.push(instance);
  return {Component: Component, instance: instance};
}

// 每个用例结束后销毁组件，避免残留的轮询/提示定时器把测试进程拖到超时。
test.afterEach(() => {
  while (live.length) {
    const instance = live.pop();
    try { instance.destroy(); } catch (err) { /* 已销毁 */ }
  }
  if (globalThis.document) globalThis.document.hidden = false;
});

test("源码契约：导出名、RPC 名、无 innerHTML、只追加 CSS 变量", () => {
  assert.match(SOURCE, /window\.NewbeeConversationWork\s*=\s*api/);
  for (const method of ["list", "start", "input", "answer", "control", "review", "apply", "complete"]) {
    assert.match(SOURCE, new RegExp("conversation\\.work\\." + method));
  }
  assert.doesNotMatch(SOURCE, /innerHTML/);
  assert.match(SOURCE, /textContent/);
  assert.match(CSS, /--nb-border/);
  assert.doesNotMatch(CSS, /#0f1115/);
});

test("没有会话时不发任何请求", async () => {
  const env = {sessionId: "", rpc: null};
  const fake = fakeRpc({});
  env.rpc = fake.rpc;
  const {instance} = setup(env);
  await instance.refresh();
  assert.deepEqual(fake.calls, []);
  assert.equal(card().hidden, true);
  assert.equal(document.getElementById('work-start').disabled, true);
  instance.destroy();
});

test("list 结果渲染标题、目录、状态；用户文本只作为文本", async () => {
  const env = {sessionId: "s1"};
  const evil = "<img src=x onerror=alert(1)>";
  const fake = fakeRpc({
    "conversation.work.list": () => ({works: [work({title: evil, activity: ["核对 export_date.ex", "<script>bad()</script>"]})]})
  });
  env.rpc = fake.rpc;
  const {instance} = setup(env);
  await instance.refresh();
  assert.deepEqual(fake.calls[0].payload, {sessionId: "s1"});
  const cardNode = card();
  assert.match(cardNode.textContent, /修复|CSV|img src=x/);
  assert.ok(cardNode.textContent.includes(evil), "用户文本应原样作为文本出现");
  assert.equal(cardNode.allElements().filter((n) => n.tagName === "IMG").length, 0);
  assert.equal(cardNode.allElements().filter((n) => n.tagName === "SCRIPT").length, 0);
  assert.ok(findByText(cardNode, "正在做"), "状态/阶段要用人能读的文案");
  assert.match(cardNode.textContent, /\/projects\/demo/, "必须显示实际目录");
  instance.destroy();
});

test("已收到/已采用只来自服务端 inputs，不用发送与否冒充采用", async () => {
  const env = {sessionId: "s1"};
  const fake = fakeRpc({
    "conversation.work.list": () => ({works: [work({
      inputs: [
        {text: "别改现有日期格式", state: "received"},
        {text: "只补空值", state: "adopted"}
      ]
    })]})
  });
  env.rpc = fake.rpc;
  const {instance} = setup(env);
  await instance.refresh();
  const text = card().textContent;
  assert.match(text, /服务端已收到 2 条补充/);
  assert.match(text, /已采用 1 条/);
  assert.match(text, /等待采用 1 条/);
  instance.destroy();
});

test("submit：没有后台工作时返回 false 且不发请求（普通对话不被接管）", async () => {
  const env = {sessionId: "s1"};
  const fake = fakeRpc({"conversation.work.list": () => ({works: []})});
  env.rpc = fake.rpc;
  const {instance} = setup(env);
  await instance.refresh();
  const before = fake.calls.length;
  const handled = await instance.submit("普通问题：帮我解释这段代码", []);
  assert.equal(handled, false);
  assert.equal(fake.calls.length, before, "普通对话不应触发工作 RPC");
  instance.destroy();
});

test("submit：有当前后台工作时送 input，带 sessionId 与稳定 requestId", async () => {
  const env = {sessionId: "s1"};
  let fail = true;
  const fake = fakeRpc({
    "conversation.work.list": () => ({works: [work()]}),
    "conversation.work.input": (payload) => {
      if (fail) throw new Error("网络断了");
      return {work: work(), receipt: {state: "received", text: "已收到，等待下一安全步骤采用"}};
    }
  });
  env.rpc = fake.rpc;
  const {instance} = setup(env);
  await instance.refresh();
  await assert.rejects(() => instance.submit("别改现有日期格式", ["u1"]), /网络断了/);
  const firstInput = fake.calls.find((c) => c.method === "conversation.work.input");
  assert.equal(firstInput.payload.sessionId, "s1");
  assert.equal(firstInput.payload.workId, "w1");
  assert.equal(firstInput.payload.text, "别改现有日期格式");
  assert.deepEqual(firstInput.payload.uploadIds, ["u1"]);
  const firstId = firstInput.payload.requestId;
  assert.ok(firstId, "start/input 必须带 requestId");
  assert.match(textOfCard(), /补充没有送达后台/);

  fail = false;
  const handled = await instance.submit("别改现有日期格式", ["u1"]);
  assert.equal(handled, true);
  const inputs = fake.calls.filter((c) => c.method === "conversation.work.input");
  assert.equal(inputs.length, 2);
  assert.equal(inputs[1].payload.requestId, firstId, "失败重试必须复用同一 requestId");
  assert.match(textOfCard(), /已收到，等待下一安全步骤采用/);
  instance.destroy();
});

test("答复：带 questionId 与 value/text；IM composing 的 Enter 不误发", async () => {
  const env = {sessionId: "s1"};
  const fake = fakeRpc({
    "conversation.work.list": () => ({works: [work({
      status: "blocked",
      stage: "needs_answer",
      question: {id: "q1", question: "空日期怎么显示？", options: [{value: "blank", label: "保留空白"}, {value: "none", label: "显示未提供"}], kind: "choice"}
    })]})
  });
  env.rpc = fake.rpc;
  const {instance} = setup(env);
  await instance.refresh();
  const cardNode = card();
  const option = buttons(cardNode).find((b) => b.textContent === "保留空白");
  assert.ok(option, "选项要能点");
  option.click();
  await new Promise((resolve) => setImmediate(resolve));
  const answerCall = fake.calls.find((c) => c.method === "conversation.work.answer");
  assert.equal(answerCall.payload.workId, "w1");
  assert.equal(answerCall.payload.questionId, "q1");
  assert.equal(answerCall.payload.value, "blank");
  assert.equal(answerCall.payload.sessionId, "s1");
  assert.ok(answerCall.payload.requestId, '真实后端要求答复携带稳定请求ID');

  // 自由文本：composing 期间 Enter 不能提交；Ctrl+Enter 才提交。
  const input = card().allElements().find((n) => n.dataset && n.dataset.cwKey === "answer:w1");
  assert.ok(input, "要有就地答复输入框");
  input.value = "保留空白，别改格式";
  input.dispatch("input");
  input.dispatch("keydown", {key: "Enter", isComposing: true});
  assert.equal(fake.calls.filter((c) => c.method === "conversation.work.answer").length, 1);
  input.dispatch("compositionstart");
  input.dispatch("keydown", {key: "Enter"});
  assert.equal(fake.calls.filter((c) => c.method === "conversation.work.answer").length, 1, "composing 中的 Enter 不提交");
  input.dispatch("compositionend");
  input.dispatch("keydown", {key: "Enter", ctrlKey: true});
  await new Promise((resolve) => setImmediate(resolve));
  const answers = fake.calls.filter((c) => c.method === "conversation.work.answer");
  assert.equal(answers.length, 2);
  assert.equal(answers[1].payload.text, "保留空白，别改格式");
  assert.equal(answers[1].payload.questionId, "q1");
  instance.destroy();
});

test("暂停/结束有真实回执；结束先确认，且不表示撤回", async () => {
  const env = {sessionId: "s1"};
  const fake = fakeRpc({
    "conversation.work.list": () => ({works: [work()]}),
    "conversation.work.control": (payload) => ({
      work: work({status: payload.action === "stop" ? "cancelled" : payload.action === "pause" ? "running" : "running", stage: payload.action === "stop" ? "ended" : payload.action === "pause" ? "paused" : "working"}),
      receipt: {text: payload.action === "stop" ? "已结束，改动保留" : "已暂停"}
    })
  });
  env.rpc = fake.rpc;
  const {instance} = setup(env);
  await instance.refresh();
  const pause = buttons(card()).find((b) => b.textContent === "暂停");
  assert.ok(pause);
  pause.click();
  await new Promise((resolve) => setImmediate(resolve));
  const controlCall = fake.calls.find((c) => c.method === "conversation.work.control");
  assert.deepEqual(controlCall.payload, {sessionId: "s1", workId: "w1", action: "pause"});
  assert.match(textOfCard(), /已暂停/);

  const stopAsk = buttons(card()).find((b) => b.textContent === "结束工作");
  assert.ok(stopAsk);
  stopAsk.click();
  assert.equal(fake.calls.filter((c) => c.method === "conversation.work.control").length, 1, "第一下只弹确认");
  assert.match(textOfCard(), /结束不表示撤回/);
  const confirm = buttons(card()).find((b) => b.textContent === "确认结束");
  assert.ok(confirm);
  confirm.click();
  await new Promise((resolve) => setImmediate(resolve));
  const stops = fake.calls.filter((c) => c.method === "conversation.work.control");
  assert.equal(stops.length, 2);
  assert.deepEqual(stops[1].payload, {sessionId: "s1", workId: "w1", action: "stop"});
  assert.match(textOfCard(), /已结束，改动保留/);
  instance.destroy();
});

test("review/apply：核对 hash 与版本后才应用，冲突不覆盖", async () => {
  const env = {sessionId: "s1"};
  let conflict = true;
  const reviewPayload = {
    patch_sha256: "abc123def4567890",
    target_root: "/projects/demo",
    summary: "改 1 个文件",
    files: [{path: "lib/export_date.ex", kind: "modify", before: "old", after: "new"}],
    conflicts: []
  };
  const fake = fakeRpc({
    "conversation.work.list": () => ({works: [work({status: "pending_review", stage: "needs_review", isolated: true, apply_state: ""})]}),
    "conversation.work.review": () => ({review: Object.assign({}, reviewPayload, {conflicts: conflict ? [{path: "lib/export_date.ex", reason: "目标文件已被修改"}] : []})}),
    "conversation.work.apply": (payload) => ({work: work({status: "done", stage: "ended", isolated: true, apply_state: "applied"}), receipt: {text: "已应用并完成"}})
  });
  env.rpc = fake.rpc;
  const {instance} = setup(env);
  await instance.refresh();
  const reviewBtn = buttons(card()).find((b) => b.textContent === "比较改动");
  assert.ok(reviewBtn, "独立工作区要能比较改动");
  reviewBtn.click();
  await new Promise((resolve) => setImmediate(resolve));
  assert.match(textOfCard(), /目标项目有新修改，不能直接覆盖/);
  assert.equal(
    buttons(card()).filter((b) => b.textContent === "应用并完成").length,
    0,
    "有冲突时不提供应用按钮，避免覆盖"
  );

  conflict = false;
  const again = buttons(card()).find((b) => b.textContent === "重新比较");
  again.click();
  await new Promise((resolve) => setImmediate(resolve));
  const ready = buttons(card()).find((b) => b.textContent === "应用并完成");
  assert.equal(ready.disabled, false);
  ready.click();
  await new Promise((resolve) => setTimeout(resolve, 0));
  await new Promise((resolve) => setTimeout(resolve, 0));
  const applied = fake.calls.filter((c) => c.method === "conversation.work.apply");
  assert.equal(applied.length, 1);
  assert.equal(applied[0].payload.sessionId, "s1");
  assert.equal(applied[0].payload.workId, "w1");
  assert.equal(applied[0].payload.patchSha256, "abc123def4567890");
  assert.ok(applied[0].payload.requestId);
  assert.match(textOfCard(), /已应用并完成/);
  instance.destroy();
});

test("切换会话后旧响应作废，不覆盖新会话的卡", async () => {
  const env = {sessionId: "s1"};
  let release;
  const gate = new Promise((resolve) => { release = resolve; });
  const fake = fakeRpc({
    "conversation.work.list": async (payload) => {
      if (payload.sessionId === "s1") {
        await gate;
        return {works: [work({title: "旧会话的工作"})]};
      }
      return {works: [work({id: "w2", title: "新会话的工作", origin_session_id: "s2"})]};
    }
  });
  env.rpc = fake.rpc;
  const {instance} = setup(env);
  const pending = instance.refresh();
  env.sessionId = "s2";
  release();
  await pending;
  await instance.refresh();
  assert.doesNotMatch(textOfCard(), /旧会话的工作/);
  assert.match(textOfCard(), /新会话的工作/);
  instance.destroy();
});

test("页面隐藏时不轮询，回到前台立即刷新", async () => {
  const env = {sessionId: "s1"};
  const fake = fakeRpc({"conversation.work.list": () => ({works: [work()]})});
  env.rpc = fake.rpc;
  const {instance} = setup(env);
  await instance.refresh();
  const afterFirst = fake.calls.length;
  document.hidden = true;
  document.dispatch("visibilitychange");
  await new Promise((resolve) => setTimeout(resolve, 30));
  assert.equal(fake.calls.length, afterFirst, "隐藏时不应有新的轮询请求");
  document.hidden = false;
  document.dispatch("visibilitychange");
  await new Promise((resolve) => setTimeout(resolve, 10));
  assert.ok(fake.calls.length > afterFirst, "回到前台要刷新");
  instance.destroy();
});

test("start：draft + uploadIds 交给后台，成功后清空草稿并回显；失败保留草稿", async () => {
  const env = {sessionId: "s1", draft: "顺手把导出测试补上", uploads: ["u9"]};
  let fail = true;
  const fake = fakeRpc({
    "conversation.work.list": () => ({works: []}),
    "conversation.work.start": () => {
      if (fail) throw new Error("后台暂时不可用");
      return {work: work({id: "w9", title: "顺手把导出测试补上"}), receipt: {state: "accepted"}};
    }
  });
  env.rpc = fake.rpc;
  const {instance} = setup(env, {getUploadIds: () => env.uploads});
  await instance.refresh();
  await assert.rejects(() => instance.start(), /后台暂时不可用/);
  assert.equal(env.draft, "顺手把导出测试补上", "失败必须保留草稿");
  assert.equal(env.appended.length, 0, "失败不能在会话里假装已发送");
  const firstId = fake.calls.find((c) => c.method === "conversation.work.start").payload.requestId;
  assert.ok(firstId);
  assert.match(textOfCard(), /没有交给后台/);

  fail = false;
  assert.equal(await instance.start(), true);
  const starts = fake.calls.filter((c) => c.method === "conversation.work.start");
  assert.equal(starts.length, 2);
  assert.equal(starts[1].payload.requestId, firstId, "重试复用同一 requestId");
  assert.deepEqual(starts[1].payload.uploadIds, ["u9"]);
  assert.equal(starts[1].payload.sessionId, "s1");
  assert.equal("root" in starts[1].payload, false, "客户端不传 root");
  assert.equal(env.draft, "", "成功后清空草稿");
  assert.deepEqual(env.appended, ["顺手把导出测试补上"]);
  instance.destroy();
});

test("apply：比较后工作版本变了就停止，不写入旧哈希", async () => {
  const env = {sessionId: "s1"};
  let revision = 3;
  const fake = fakeRpc({
    "conversation.work.list": () => ({works: [work({status: "pending_review", stage: "needs_review", isolated: true, revision: revision})]}),
    "conversation.work.review": () => ({review: {patch_sha256: "deadbeefcafe0001", target_root: "/projects/demo", files: [{path: "a.ex", kind: "modify"}], conflicts: []}}),
    "conversation.work.apply": () => ({work: work({apply_state: "applied"}), receipt: {text: "已应用"}})
  });
  env.rpc = fake.rpc;
  const {instance} = setup(env);
  await instance.refresh();
  buttons(card()).find((b) => b.textContent === "比较改动").click();
  await new Promise((resolve) => setImmediate(resolve));
  // 比较之后，工作在别处被推进（revision 变化）。
  revision = 4;
  const applyBtn = buttons(card()).find((b) => b.textContent === "应用并完成");
  assert.equal(applyBtn.disabled, false);
  applyBtn.click();
  await new Promise((resolve) => setTimeout(resolve, 0));
  await new Promise((resolve) => setTimeout(resolve, 0));
  assert.equal(fake.calls.filter((c) => c.method === "conversation.work.apply").length, 0, "版本变化后不能应用");
  assert.match(textOfCard(), /请重新比较/);
  instance.destroy();
});

test("destroy：停止轮询并移除卡片", async () => {
  const env = {sessionId: "s1"};
  const fake = fakeRpc({"conversation.work.list": () => ({works: [work()]})});
  env.rpc = fake.rpc;
  const {instance} = setup(env);
  await instance.refresh();
  const count = fake.calls.length;
  instance.destroy();
  assert.equal(document.getElementById("conversation-work"), null, "卡片要随组件移除");
  await new Promise((resolve) => setTimeout(resolve, 30));
  assert.equal(fake.calls.length, count, "销毁后不再轮询");
});

test("多条工作时优先本会话自己的工作，别的工作只读展示", async () => {
  const env = {sessionId: "s1"};
  const fake = fakeRpc({
    "conversation.work.list": () => ({works: [
      work({id: "w-other", title: "别处的紧急问题", origin_session_id: "s9", status: "blocked", stage: "needs_answer", question: {id: "q9", question: "别人的问题", options: []}}),
      work({id: "w-mine", title: "本会话的工作", origin_session_id: "s1", status: "running", stage: "working"})
    ]}),
    "conversation.work.input": () => ({work: work({id: "w-mine"}), receipt: {state: "received", text: "已收到"}})
  });
  env.rpc = fake.rpc;
  const {instance} = setup(env);
  await instance.refresh();
  const text = textOfCard();
  assert.match(text, /本会话的工作/);
  assert.match(text, /其他工作（1）/);
  assert.equal(await instance.submit("这条补充属于本会话", []), true);
  const input = fake.calls.find((c) => c.method === "conversation.work.input");
  assert.equal(input.payload.workId, "w-mine", "补充不能发到别的工作上");
  instance.destroy();
});

test("只有其他会话的工作时，本会话的普通发送不被接管", async () => {
  const env = {sessionId: "s1"};
  const fake = fakeRpc({
    "conversation.work.list": () => ({works: [work({id: "w-other", origin_session_id: "s9", status: "running", stage: "working"})]})
  });
  env.rpc = fake.rpc;
  const {instance} = setup(env);
  await instance.refresh();
  assert.match(textOfCard(), /属于另一个会话/);
  assert.equal(await instance.submit("普通对话", []), false);
  assert.equal(fake.calls.filter((c) => c.method === "conversation.work.input").length, 0);
  instance.destroy();
});

test("轮询刷新不清空正在写的答案，焦点回到原输入框", async () => {
  const env = {sessionId: "s1"};
  let revision = 1;
  const fake = fakeRpc({
    "conversation.work.list": () => ({works: [work({
      status: "blocked",
      stage: "needs_answer",
      revision: revision,
      question: {id: "q1", question: "空日期怎么显示？", options: []}
    })]})
  });
  env.rpc = fake.rpc;
  const {instance} = setup(env);
  await instance.refresh();
  const input = card().allElements().find((n) => n.dataset && n.dataset.cwKey === "answer:w1");
  input.value = "保留空白";
  input.dispatch("input");
  input.focus();
  // 服务端状态变化触发重渲染（模拟轮询到 activity 更新）。
  revision = 2;
  await instance.refresh();
  const again = card().allElements().find((n) => n.dataset && n.dataset.cwKey === "answer:w1");
  assert.equal(again.value, "保留空白", "重渲染不能清空用户正在写的答案");
  assert.equal(document.activeElement, again, "焦点应回到原来的答案输入框");
  instance.destroy();
});

test("卡片挂在 #main 内、#composer 之前，切会话不改宿主结构", async () => {
  const env = {sessionId: "s1"};
  const fake = fakeRpc({"conversation.work.list": () => ({works: [work()]})});
  env.rpc = fake.rpc;
  const {instance} = setup(env);
  await instance.refresh();
  const main = document.getElementById("main");
  const composer = document.getElementById("composer");
  const cardNode = document.getElementById("conversation-work");
  assert.equal(cardNode.parentNode, main, "卡片必须在 #main 内");
  const order = main.children.map((node) => node.id || node.tagName);
  assert.ok(order.indexOf("conversation-work") < order.indexOf("composer"), "卡片要在输入区之前");
  env.sessionId = "s2";
  await instance.refresh();
  assert.equal(document.getElementById("conversation-work"), cardNode, "刷新不应重建卡片");
  assert.equal(cardNode.parentNode, main);
  assert.ok(composer.parentNode === main);
  instance.destroy();
});

test("进行中的工作有真实活动时可展开查看，且不把活动写成结果", async () => {
  const env = {sessionId: "s1"};
  const fake = fakeRpc({
    "conversation.work.list": () => ({works: [work({activity: ["读取 lib/export_date.ex", "运行 3 项定向测试"]})]})
  });
  env.rpc = fake.rpc;
  const {instance} = setup(env);
  await instance.refresh();
  const toggle = buttons(card()).find((b) => b.textContent === "查看过程");
  assert.ok(toggle, "有活动记录就要能展开");
  toggle.click();
  const text = textOfCard();
  assert.match(text, /运行 3 项定向测试/);
  assert.doesNotMatch(text, /不需要「应用」/, "非隔离且无结果时不该出现应用说明");
  const collapse = buttons(card()).find((b) => b.textContent === "收起过程");
  assert.ok(collapse);
  collapse.click();
  assert.doesNotMatch(textOfCard(), /运行 3 项定向测试/);
  instance.destroy();
});

test("完整故事：后台做 → 答复 → 待审阅 → 应用 → 已应用", async () => {
  const env = {sessionId: "s1", draft: "修复 CSV 导出空日期，加测试"};
  let phase = "working";
  const stageOfWork = () => {
    if (phase === "working") return work({status: "running", stage: "working"});
    if (phase === "question") {
      return work({
        status: "blocked",
        stage: "needs_answer",
        question: {id: "q1", question: "空日期怎么显示？", options: [{value: "blank", label: "保留空白"}]}
      });
    }
    if (phase === "review") {
      return work({status: "pending_review", stage: "needs_review", isolated: true, workspace_path: "/tmp/ws-1", apply_state: ""});
    }
    return work({status: "done", stage: "ended", isolated: true, workspace_path: "/tmp/ws-1", apply_state: "applied"});
  };
  const fake = fakeRpc({
    "conversation.work.list": () => ({works: [stageOfWork()]}),
    "conversation.work.start": () => ({work: stageOfWork(), receipt: {state: "accepted"}}),
    "conversation.work.answer": () => ({work: stageOfWork(), receipt: {text: "已记录，继续"}}),
    "conversation.work.review": () => ({review: {patch_sha256: "0011223344556677", target_root: "/projects/demo", files: [{path: "lib/export_date.ex", kind: "modify"}], conflicts: []}}),
    "conversation.work.apply": () => {
      phase = "applied";
      return {work: stageOfWork(), receipt: {text: "已应用并完成"}};
    }
  });
  env.rpc = fake.rpc;
  const {instance} = setup(env);
  await instance.refresh();
  assert.equal(await instance.start(), true);
  assert.equal(env.draft, "", "交给后台后清空草稿");

  phase = "question";
  await instance.refresh();
  assert.match(textOfCard(), /等待答复/);
  buttons(card()).find((b) => b.textContent === "保留空白").click();
  await new Promise((resolve) => setImmediate(resolve));
  assert.ok(fake.calls.some((c) => c.method === "conversation.work.answer"));

  phase = "review";
  await instance.refresh();
  assert.match(textOfCard(), /尚未写入项目/);
  buttons(card()).find((b) => b.textContent === "比较改动").click();
  await new Promise((resolve) => setImmediate(resolve));
  buttons(card()).find((b) => b.textContent === "应用并完成").click();
  await new Promise((resolve) => setTimeout(resolve, 0));
  await new Promise((resolve) => setTimeout(resolve, 0));
  await new Promise((resolve) => setTimeout(resolve, 0));
  assert.match(textOfCard(), /已应用并完成/);
  assert.match(textOfCard(), /已应用到这个项目/);
  assert.equal(buttons(card()).filter((b) => b.textContent === "应用并完成").length, 0, "已应用后不再提供应用按钮");
  instance.destroy();
});

test("回执形状兼容：字符串 / {text,state} / 缺失都不崩，也不虚报", async () => {
  const env = {sessionId: "s1"};
  let shape = "string";
  const fake = fakeRpc({
    "conversation.work.list": () => ({works: [work()]}),
    "conversation.work.input": () => {
      if (shape === "string") return {work: work(), receipt: "已收到，下一安全步骤采用"};
      if (shape === "object") return {work: work(), receipt: {text: "已收到", state: "received"}};
      return {work: work()};
    }
  });
  env.rpc = fake.rpc;
  const {instance} = setup(env);
  await instance.refresh();
  assert.equal(await instance.submit("第一句补充", []), true);
  assert.match(textOfCard(), /已收到，下一安全步骤采用/);

  shape = "object";
  assert.equal(await instance.submit("第二句补充", []), true);
  assert.match(textOfCard(), /已收到/);

  shape = "none";
  assert.equal(await instance.submit("第三句补充", []), true);
  const text = textOfCard();
  assert.match(text, /后台已收到这条补充/);
  assert.doesNotMatch(text, /已采用/, "缺失状态时不能声称已采用");
  instance.destroy();
});

test("apply 没拿到 applied 状态时不显示“已应用”", async () => {
  const env = {sessionId: "s1"};
  const fake = fakeRpc({
    "conversation.work.list": () => ({works: [work({status: "pending_review", stage: "needs_review", isolated: true, apply_state: ""})]}),
    "conversation.work.review": () => ({review: {patch_sha256: "aa11bb22cc33dd44", target_root: "/projects/demo", files: [{path: "a.ex", kind: "modify"}], conflicts: []}}),
    "conversation.work.apply": () => ({receipt: "请求已受理，检查待完成"})
  });
  env.rpc = fake.rpc;
  const {instance} = setup(env);
  await instance.refresh();
  buttons(card()).find((b) => b.textContent === "比较改动").click();
  await new Promise((resolve) => setImmediate(resolve));
  buttons(card()).find((b) => b.textContent === "应用并完成").click();
  await new Promise((resolve) => setTimeout(resolve, 0));
  await new Promise((resolve) => setTimeout(resolve, 0));
  await new Promise((resolve) => setTimeout(resolve, 0));
  const text = textOfCard();
  assert.match(text, /请求已受理，检查待完成/);
  assert.doesNotMatch(text, /已应用到这个项目/, "没有 applied 状态时不能声称已写入");
  instance.destroy();
});


test('真实后端 consumed_at 回执可确认采用，内部展示选择不改变当前输入', async () => {
  const fake = fakeRpc({
    'conversation.work.list': () => ({works:[work({inputs:[{text:'保留格式',consumed_at:1790000000000}]}),work({id:'old',status:'done',stage:'completed'})]}),
    'conversation.work.input': () => ({work:work()})
  });
  const env = {sessionId:'s1',rpc:fake.rpc};
  const {instance} = setup(env); await instance.refresh();
  assert.match(textOfCard(),/已采用 1 条/);
  assert.equal(await instance.submit('补充同一工作'),true);
  assert.equal(fake.calls.find(c=>c.method==='conversation.work.input').payload.workId,'w1');
});

test('普通输入框可直接回答当前问题并携带稳定请求ID', async () => {
  const question = {id:'current-q',question:'保留哪种格式？',options:[]};
  const fake = fakeRpc({'conversation.work.list':()=>({works:[work({status:'blocked',stage:'needs_answer',question})]}),'conversation.work.answer':()=>({work:work()})});
  const {instance} = setup({sessionId:'s1',rpc:fake.rpc}); await instance.refresh();
  assert.equal(await instance.submit('保留已有格式'),true);
  const answer = fake.calls.find(c=>c.method==='conversation.work.answer');
  assert.equal(answer.payload.questionId,'current-q');
  assert.ok(answer.payload.requestId);
  assert.equal(fake.calls.some(c=>c.method==='conversation.work.input'),false);
});

test('核对到没有文件变化的独立文本成果可确认完成', async () => {
  const pending = work({status:'pending_review',stage:'needs_review',isolated:true,result:{content:'分析结论'}});
  const fake = fakeRpc({'conversation.work.list':()=>({works:[pending]}),'conversation.work.review':()=>({review:{files:[],no_changes:true,file_count:0,patch_sha256:'a'.repeat(64)}})});
  const {instance} = setup({sessionId:'s1',rpc:fake.rpc}); await instance.refresh();
  const compare = buttons(card()).find(b=>b.textContent==='比较改动'); compare.click();
  await new Promise(resolve=>setImmediate(resolve));
  assert.ok(buttons(card()).some(b=>b.textContent==='确认完成'));
});


test('只发附件也属于当前后台工作，不回落到另一个前台执行者', async () => {
  const fake = fakeRpc({'conversation.work.list':()=>({works:[work()]}),'conversation.work.input':()=>({work:work()})});
  const {instance} = setup({sessionId:'s1',rpc:fake.rpc}); await instance.refresh();
  assert.equal(await instance.submit('', ['file-1']), true);
  const sent = fake.calls.find(call=>call.method==='conversation.work.input');
  assert.equal(sent.payload.workId, 'w1');
  assert.deepEqual(sent.payload.uploadIds, ['file-1']);
  assert.match(sent.payload.text, /附件/);
});


test("自动分工卡展示阶段、完成数、依赖标题，并隐藏内部标识和来源入口", async () => {
  const root = work({title: "总任务", coordination: {phase: "executing", summary: "拆分后独立推进", concurrency: 3, total: 2, completed: 1, children: [
    {id: "api", title: "接口实现", status: "done", depends_on: [], activity: "已交付"},
    {id: "test", title: "补充测试", status: "running", depends_on: ["api"], activity: "正在验证"}
  ]}});
  const fake = fakeRpc({"conversation.work.list": () => ({works: [root]})});
  const {instance} = setup({sessionId: "s1", rpc: fake.rpc});
  await instance.refresh();
  const text = textOfCard();
  assert.match(text, /任务分工/);
  assert.match(text, /1\/2 项/);
  assert.match(text, /执行中/);
  assert.match(text, /接口实现/);
  assert.match(text, /依赖：接口实现/);
  assert.doesNotMatch(text, /来源设置/);
  assert.doesNotMatch(text, /api|workId/);
  assert.equal(buttons(card()).some((node) => node.textContent === "分工执行"), false);
  assert.ok(document.getElementById('work-start').parentNode.classList.contains('cw-team-split'));
  assert.equal(document.getElementById('work-start').parentNode.parentNode.id, 'composer-actions');
  assert.equal(document.getElementById('work-start').disabled, true);
  instance.destroy();
});

// ── 进度条：必须能真正走到“结束” ─────────────────────────────────────────
// 现场：三个分项全部 cancelled，接口却返回 completed=0 → 卡片长期显示 0/2，
// 用户看到的进度条永远没有结束。分项被取消/失败也算收尾。

test("全部取消的分项也走完进度条，并显示为已结束而不是进行中", async () => {
  const root = work({
    status: "cancelled",
    stage: "ended",
    coordination: {
      phase: "ended", total: 2, completed: 0, settled: 2, failed: 0, cancelled: 2,
      children: [
        {id: "a", title: "重设计输出窗口", status: "cancelled"},
        {id: "b", title: "修复状态闭环", status: "cancelled"}
      ]
    }
  });
  const fake = fakeRpc({"conversation.work.list": () => ({works: [root]})});
  const {instance} = setup({sessionId: "s1", rpc: fake.rpc});
  await instance.refresh();

  const bar = card().allElements().find((node) => node.className === "cw-progress");
  assert.ok(bar, "要真的画出进度条，而不是只有一行文字");
  assert.equal(bar.dataset.tone, "stop", "已结束且没走完，不能用「进行中」的颜色");
  assert.equal(bar.getAttribute("role"), "progressbar");
  assert.equal(bar.getAttribute("aria-valuemax"), "2");
  assert.equal(bar.getAttribute("aria-valuenow"), "2", "两个分项都已收尾，进度必须是满的");
  const text = textOfCard();
  assert.match(text, /2\/2 项/);
  assert.doesNotMatch(text, /0\/2/, "不能停在 0/2");
  assert.match(text, /已结束/);
  instance.destroy();
});

test("老后端没有 settled 字段时，前端按子项状态自己算收尾数", async () => {
  const root = work({
    status: "cancelled",
    stage: "ended",
    coordination: {
      phase: "ended", total: 3, completed: 0,
      children: [
        {id: "a", title: "甲", status: "cancelled"},
        {id: "b", title: "乙", status: "failed"},
        {id: "c", title: "丙", status: "running"}
      ]
    }
  });
  const fake = fakeRpc({"conversation.work.list": () => ({works: [root]})});
  const {instance} = setup({sessionId: "s1", rpc: fake.rpc});
  await instance.refresh();
  const bar = card().allElements().find((node) => node.className === "cw-progress");
  assert.equal(bar.getAttribute("aria-valuenow"), "2", "取消 + 失败都算收尾");
  assert.match(textOfCard(), /2\/3 项/);
  assert.match(textOfCard(), /取消 1/);
  assert.match(textOfCard(), /未完成 1/);
  instance.destroy();
});

test("全部交付时进度条满格并用成功色，失败时用错误色", async () => {
  const delivered = work({status: "done", stage: "completed", coordination: {
    phase: "completed", total: 2, completed: 2, settled: 2,
    children: [{id: "a", title: "甲", status: "done"}, {id: "b", title: "乙", status: "done"}]
  }});
  const fake = fakeRpc({"conversation.work.list": () => ({works: [delivered]})});
  const {instance} = setup({sessionId: "s1", rpc: fake.rpc});
  await instance.refresh();
  let bar = card().allElements().find((node) => node.className === "cw-progress");
  assert.equal(bar.dataset.tone, "done");
  assert.equal(bar.getAttribute("aria-valuenow"), "2");

  const failed = work({status: "blocked", stage: "blocked", coordination: {
    phase: "executing", total: 2, completed: 1, settled: 1, failed: 1,
    children: [{id: "a", title: "甲", status: "done"}, {id: "b", title: "乙", status: "failed"}]
  }});
  const fake2 = fakeRpc({"conversation.work.list": () => ({works: [failed]})});
  instance.init(hostFor({sessionId: "s1", rpc: fake2.rpc}));
  await instance.refresh();
  bar = card().allElements().find((node) => node.className === "cw-progress");
  assert.equal(bar.dataset.tone, "err", "有失败分项要点出来，不能装作一切正常");
  instance.destroy();
});

test("进度条宽度跟着收尾比例走，且不会超过满格", async () => {
  const root = work({coordination: {
    phase: "executing", total: 4, completed: 1, settled: 2,
    children: [
      {id: "a", title: "甲", status: "done"},
      {id: "b", title: "乙", status: "cancelled"},
      {id: "c", title: "丙", status: "running"},
      {id: "d", title: "丁", status: "pending"}
    ]
  }});
  const fake = fakeRpc({"conversation.work.list": () => ({works: [root]})});
  const {instance} = setup({sessionId: "s1", rpc: fake.rpc});
  await instance.refresh();
  const fill = card().allElements().find((node) => node.className === "cw-progress-fill");
  assert.equal(fill.style.getPropertyValue("width"), "50%");

  const over = work({coordination: {
    phase: "completed", total: 2, completed: 5, settled: 9,
    children: [{id: "a", title: "甲", status: "done"}, {id: "b", title: "乙", status: "done"}]
  }});
  const fake2 = fakeRpc({"conversation.work.list": () => ({works: [over]})});
  instance.init(hostFor({sessionId: "s1", rpc: fake2.rpc}));
  await instance.refresh();
  const fill2 = card().allElements().find((node) => node.className === "cw-progress-fill");
  assert.equal(fill2.style.getPropertyValue("width"), "100%", "超额计数要夹到 100%，不能溢出");
  instance.destroy();
});

test("子任务问题显示来源标题，但回答仍走根工作问题", async () => {
  const question = {id: "q1", question: "选择方案", task_title: "接口实现", options: []};
  const fake = fakeRpc({
    "conversation.work.list": () => ({works: [work({status: "blocked", stage: "needs_answer", question})]}),
    "conversation.work.answer": () => ({work: work()})
  });
  const {instance} = setup({sessionId: "s1", rpc: fake.rpc});
  await instance.refresh();
  assert.match(textOfCard(), /来自分工：接口实现/);
  assert.equal(await instance.submit("保留方案"), true);
  const answer = fake.calls.find((call) => call.method === "conversation.work.answer");
  assert.equal(answer.payload.workId, "w1");
  assert.equal(answer.payload.questionId, "q1");
  instance.destroy();
});


test("等待依赖只显示等待上游，已交付子项不变成总任务完成", async () => {
  const root = work({coordination: {phase: "executing", total: 2, completed: 1, children: [
    {id: "api", title: "实现接口", status: "pending_review"},
    {id: "verify", title: "组合验证", status: "blocked", waiting_for: "dependencies", depends_on: ["api"]}
  ]}});
  const fake = fakeRpc({"conversation.work.list": () => ({works: [root]})});
  const {instance} = setup({sessionId: "s1", rpc: fake.rpc});
  await instance.refresh();
  assert.match(textOfCard(), /已交付/);
  assert.match(textOfCard(), /等待上游/);
  assert.doesNotMatch(textOfCard(), /需要处理/);
  assert.equal(buttons(card()).some((b) => /应用到当前项目/.test(b.textContent)), false);
  instance.destroy();
});

test("规划阶段显示任务分工入口且刷新保留用户的展开选择", async () => {
  const root = work({coordination: {phase: "planning", total: 0, completed: 0, children: []}});
  const fake = fakeRpc({"conversation.work.list": () => ({works: [root]})});
  const {instance} = setup({sessionId: "s1", rpc: fake.rpc});
  await instance.refresh();
  assert.match(textOfCard(), /正在规划分工/);
  const detail = card().allElements().find((node) => node.className === "cw-coordination");
  assert.equal(detail.open, true);
  detail.open = false;
  detail.dispatch("toggle");
  await instance.refresh();
  assert.equal(card().allElements().find((node) => node.className === "cw-coordination").open, false);
  instance.destroy();
});



test("原输入框操作区只有一个分工按钮，无任务时不显示空白工作卡", async () => {
  const fake = fakeRpc({"conversation.work.list": () => ({works: []})});
  const {instance} = setup({sessionId: "s1", rpc: fake.rpc});
  await instance.refresh();
  assert.equal(card().hidden, true);
  const entry = document.getElementById("work-start");
  assert.ok(entry.parentNode.classList.contains("cw-team-split"));
  assert.equal(entry.parentNode.parentNode.id, "composer-actions");
  assert.equal(entry.textContent, "");
  assert.equal(entry.children.find((node) => node.nodeType === 1).tagName, "SVG");
  assert.match(entry.getAttribute('aria-label'), /分工/);
  assert.match(entry.title, /快速分工/);
  assert.equal(entry.disabled, false);
  await instance.refresh();
  assert.equal(document.body.allElements().filter(e => e.id === "work-start").length, 1);
  instance.destroy();
  assert.equal(document.getElementById("work-start"), null);
});

test("输入框内分工按钮使用原草稿和附件；重复初始化不复制入口", async () => {
  const env = {sessionId: "s1", draft: "实现导出并验证"};
  const fake = fakeRpc({"conversation.work.list": () => ({works: []}), "conversation.work.start": () => ({work: work()})});
  env.rpc = fake.rpc;
  const {instance} = setup(env, {getUploadIds: () => ["u-one"]});
  await instance.refresh();
  document.getElementById("work-start").click();
  await new Promise(resolve => setTimeout(resolve, 0));
  const sent = fake.calls.find(c => c.method === "conversation.work.start");
  assert.equal(sent.payload.text, "实现导出并验证");
  assert.deepEqual(sent.payload.uploadIds, ["u-one"]);
  assert.equal(env.draft, "");
  instance.init(hostFor(env));
  await instance.refresh();
  assert.equal(document.body.allElements().filter(e => e.id === "work-start").length, 1);
  instance.destroy();
});

// ── 团队入口的 DOM 构建契约（不得回到 innerHTML）─────────────────────────
test("classList.toggle 与真实 DOM 同语义：无 force 取反，有 force 强制，返回最终态", () => {
  const {Element} = require("./conversation_work_dom.js");
  const node = new Element("div");
  assert.equal(node.classList.contains("cw-team-off"), false);
  assert.equal(node.classList.toggle("cw-team-off"), true);
  assert.equal(node.classList.contains("cw-team-off"), true);
  assert.equal(node.classList.toggle("cw-team-off"), false);
  assert.equal(node.classList.toggle("cw-team-off", true), true);
  assert.equal(node.classList.toggle("cw-team-off", false), false);
  assert.equal(node.classList.contains("cw-team-off"), false);
});

test("分体按钮置灰态跟随主按钮：有活跃工作时 cw-team-off 上身，清空后摘掉", async () => {
  const running = work({status: "running", stage: "working"});
  const fake = fakeRpc({"conversation.work.list": () => ({works: [running]})});
  const {instance} = setup({sessionId: "s1", rpc: fake.rpc});
  await instance.refresh();
  const wrap = document.getElementById("work-start").parentNode;
  assert.equal(wrap.classList.contains("cw-team-off"), true);
  const empty = fakeRpc({"conversation.work.list": () => ({works: []})});
  instance.init(hostFor({sessionId: "s1", rpc: empty.rpc}));
  await instance.refresh();
  assert.equal(document.getElementById("work-start").parentNode.classList.contains("cw-team-off"), false);
  instance.destroy();
});

test("团队菜单项用 DOM 构建：图标/标题/副标题都在，模板名走 textContent 不当标记", async () => {
  const tpl = {id: "t1", name: "<img src=x onerror=1>", stages: [{}, {}], roles: [{}, {}, {}]};
  const fake = fakeRpc({
    "conversation.work.list": () => ({works: []}),
    "colony.team.templates": () => ({templates: [tpl]})
  });
  const {instance} = setup({sessionId: "s1", rpc: fake.rpc});
  await instance.refresh();
  const caret = document.getElementById("work-start").parentNode.children.find((n) => n.className === "cw-team-caret");
  caret.click();
  await new Promise((resolve) => setTimeout(resolve, 0));
  const menu = document.body.allElements().find((n) => n.className === "cw-team-menu");
  assert.ok(menu, "菜单要真的挂出来");
  const items = menu.allElements().filter((n) => n.className.includes("cw-team-menu-item"));
  assert.ok(items.length >= 3, "快速分工 + 工作室 + 模板项");
  const names = items.map((n) => n.allElements().filter((c) => c.tagName === "B").map((b) => b.textContent).join(""));
  assert.ok(names.includes("<img src=x onerror=1>"), "模板名必须原样作为文本");
  assert.equal(document.body.allElements().filter((n) => n.tagName === "IMG").length, 0, "不能被当成标记插进 DOM");
  const subs = items.map((n) => n.allElements().filter((c) => c.tagName === "I").map((i) => i.textContent).join(""));
  assert.ok(subs.some((s) => s.includes("2 阶段闭环") && s.includes("3 角色")));
  instance.destroy();
});

// ── 窗口：放大 / 缩放 / 最小化 ────────────────────────────────────────────
// 用户的原始诉求是「输出窗口太难用，要能放大缩中和最小化」：
//   ① 控件必须在标题栏，内容再长也点得到；
//   ② 最小化后只留标题栏，内容不再占高度；
//   ③ 放大铺满，再点还原；
//   ④ 拖动/键盘能改高度，双击回到自适应；
//   ⑤ 窗口状态跨刷新、跨重建保留。

function byKey(root, key) {
  return root.allElements().find((node) => node.dataset && node.dataset.cwKey === key) || null;
}

function scrollOf(root) {
  return root.allElements().find((node) => node.className === "cw-scroll") || null;
}

test("窗口控件在标题栏内，内容区单独滚动（控件不会被长内容顶走）", async () => {
  const fake = fakeRpc({"conversation.work.list": () => ({works: [work({
    activity: ["读取 lib/export_date.ex"],
    coordination: {phase: "executing", total: 3, completed: 1, children: [
      {id: "api", title: "接口实现", status: "done"},
      {id: "test", title: "补充测试", status: "running"},
      {id: "docs", title: "更新文档", status: "running"}
    ]}
  })]})});
  const {instance} = setup({sessionId: "s1", rpc: fake.rpc});
  await instance.refresh();
  const head = card().allElements().find((node) => node.className === "cw-head");
  const minimize = byKey(card(), "window:minimize");
  const maximize = byKey(card(), "window:maximize");
  assert.ok(head && minimize && maximize, "标题栏里要有最小化和放大");
  assert.ok(head.contains(minimize) && head.contains(maximize), "窗口控件必须在标题栏内");
  const scroll = scrollOf(card());
  assert.ok(scroll, "内容区要有独立滚动容器");
  assert.equal(scroll.contains(minimize), false, "控件不能放进滚动区");
  assert.equal(card().dataset.mode, "normal");
  instance.destroy();
});

test("最小化只留标题栏，还原后回到原来的内容；按钮状态与读屏文案同步", async () => {
  const fake = fakeRpc({"conversation.work.list": () => ({works: [work()]})});
  const {instance} = setup({sessionId: "s1", rpc: fake.rpc});
  await instance.refresh();
  const minimize = byKey(card(), "window:minimize");
  assert.equal(minimize.getAttribute("aria-pressed"), "false");
  assert.match(minimize.title, /最小化/);
  minimize.click();
  assert.equal(card().dataset.mode, "minimized");
  assert.equal(byKey(card(), "window:minimize").getAttribute("aria-pressed"), "true");
  assert.match(byKey(card(), "window:minimize").title, /还原/);
  assert.equal(scrollOf(card()).hidden || false, false, "内容节点仍在（CSS 负责隐藏），状态可逆");
  byKey(card(), "window:minimize").click();
  assert.equal(card().dataset.mode, "normal");
  assert.equal(byKey(card(), "window:minimize").getAttribute("aria-pressed"), "false");
  instance.destroy();
});

test("放大铺满再还原，两个按钮互斥且不互相踩", async () => {
  const fake = fakeRpc({"conversation.work.list": () => ({works: [work()]})});
  const {instance} = setup({sessionId: "s1", rpc: fake.rpc});
  await instance.refresh();
  byKey(card(), "window:maximize").click();
  assert.equal(card().dataset.mode, "maximized");
  assert.equal(byKey(card(), "window:maximize").getAttribute("aria-pressed"), "true");
  assert.match(byKey(card(), "window:maximize").title, /还原/);
  // 放大期间再点最小化：模式切到 minimized，放大按钮必须回到未按下。
  byKey(card(), "window:minimize").click();
  assert.equal(card().dataset.mode, "minimized");
  assert.equal(byKey(card(), "window:maximize").getAttribute("aria-pressed"), "false");
  byKey(card(), "window:minimize").click();
  assert.equal(card().dataset.mode, "normal");
  instance.destroy();
});

test("拖动上边缘改高度用 CSS 变量，双击回到自适应", async () => {
  const fake = fakeRpc({"conversation.work.list": () => ({works: [work()]})});
  const {instance} = setup({sessionId: "s1", rpc: fake.rpc});
  await instance.refresh();
  const resize = card().allElements().find((node) => node.className === "cw-resize");
  assert.ok(resize, "上边缘要能拖");
  assert.equal(resize.hidden, false);
  resize.dispatch("pointerdown", {clientY: 400});
  globalThis.document.dispatch("pointermove", {clientY: 340});
  assert.equal(card().dataset.sized, "1");
  assert.match(card().style.getPropertyValue("--cw-h"), /^\d+px$/);
  const raised = parseInt(card().style.getPropertyValue("--cw-h"), 10);
  assert.ok(raised > 0);
  globalThis.document.dispatch("pointerup", {});
  resize.dispatch("dblclick", {});
  assert.equal(card().dataset.sized, "0");
  assert.equal(card().style.getPropertyValue("--cw-h"), "");
  instance.destroy();
});

test("键盘可调高度：↑↓ 改像素，End 到上限，Home 到下限", async () => {
  const fake = fakeRpc({"conversation.work.list": () => ({works: [work()]})});
  const {instance} = setup({sessionId: "s1", rpc: fake.rpc});
  await instance.refresh();
  const resize = card().allElements().find((node) => node.className === "cw-resize");
  resize.dispatch("keydown", {key: "End"});
  const top = parseInt(card().style.getPropertyValue("--cw-h"), 10);
  assert.ok(top > 0);
  resize.dispatch("keydown", {key: "Home"});
  const bottom = parseInt(card().style.getPropertyValue("--cw-h"), 10);
  assert.ok(bottom > 0 && bottom < top, "Home 的高度要小于 End");
  resize.dispatch("keydown", {key: "ArrowUp"});
  assert.ok(parseInt(card().style.getPropertyValue("--cw-h"), 10) > bottom);
  instance.destroy();
});

test("窗口大小跨刷新与重建保留；放大态刷新不回到默认窗口", async () => {
  const fake = fakeRpc({"conversation.work.list": () => ({works: [work()]})});
  const {instance} = setup({sessionId: "s1", rpc: fake.rpc});
  await instance.refresh();
  byKey(card(), "window:maximize").click();
  await instance.refresh();
  assert.equal(card().dataset.mode, "maximized", "刷新不能把放大的窗口收回");
  assert.equal(byKey(card(), "window:maximize").getAttribute("aria-pressed"), "true");
  instance.init(hostFor({sessionId: "s1", rpc: fake.rpc}));
  await new Promise((resolve) => setImmediate(resolve));
  assert.equal(card().dataset.mode, "maximized", "重新初始化后仍是同一个窗口状态");
  byKey(card(), "window:maximize").click();
  assert.equal(card().dataset.mode, "normal");
  instance.destroy();
});

test("已结束/仍在推进的独立工作不再给「比较改动」，避免点了必然报错", async () => {
  const ended = work({status: "cancelled", stage: "ended", isolated: true, apply_state: ""});
  const fake = fakeRpc({"conversation.work.list": () => ({works: [ended]})});
  const {instance} = setup({sessionId: "s1", rpc: fake.rpc});
  await instance.refresh();
  assert.equal(buttons(card()).some((b) => b.textContent === "比较改动"), false);
  assert.match(textOfCard(), /服务端不再接受比较或应用/);

  // 仍在推进：给出原因而不是死按钮。
  const running = work({status: "running", stage: "working", isolated: true, apply_state: ""});
  const fake2 = fakeRpc({"conversation.work.list": () => ({works: [running]})});
  instance.init(hostFor({sessionId: "s1", rpc: fake2.rpc}));
  await instance.refresh();
  assert.equal(buttons(card()).some((b) => b.textContent === "比较改动"), false);
  assert.match(textOfCard(), /等结果准备好/);
  instance.destroy();
});

test("等待查看的独立成果仍能比较与应用（门禁没有误伤正常路径）", async () => {
  const ready = work({status: "pending_review", stage: "needs_review", isolated: true, apply_state: ""});
  const fake = fakeRpc({
    "conversation.work.list": () => ({works: [ready]}),
    "conversation.work.review": () => ({review: {patch_sha256: "0011223344556677", target_root: "/projects/demo", files: [{path: "a.ex", kind: "modify"}], conflicts: []}})
  });
  const {instance} = setup({sessionId: "s1", rpc: fake.rpc});
  await instance.refresh();
  const compare = buttons(card()).find((b) => b.textContent === "比较改动");
  assert.ok(compare, "等待查看时必须能比较");
  compare.click();
  await new Promise((resolve) => setImmediate(resolve));
  assert.ok(buttons(card()).some((b) => b.textContent === "应用并完成"));
  instance.destroy();
});
