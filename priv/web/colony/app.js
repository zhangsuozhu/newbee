// 蜂群前端 · 入口：装配模块、轮询、事件绑定。
// 视觉全部复用主界面的组件类（#sidebar / .session-group / .msg-* / .composer-card …），
// 本页只负责「蜂群 = 会话组 + 成员」的数据映射。
import { esc } from "./util.js";
import { form } from './forms.js';
import { initShell, ensureAuthenticated, updateWorkspaceContext, collapseSidebar } from './shell.js';
import { redeemInvitation } from './manage.js';
import { rpc, toast } from "./api.js";
import {
  state, subscribe, loadColonies, selectColony, refresh, startPolling,
  pushPath, memberById, resetToChat, enterBeeMode, exitBeeMode, openConversation, openBeeTrail,
} from "./store.js";
import { renderSidebar } from "./sidebar.js";
import { renderBreadcrumbs } from "./breadcrumbs.js";
import { renderGroupView, renderDMView } from "./chat.js";
import { renderDrillView } from "./drill.js";
import { renderComposer, updateScope, updateReviewBar, send, prefill } from "./composer.js";
import { bindMarkdownCopy } from "./md.js";

const $ = (sel) => document.querySelector(sel);
let lastSig = null;

const revealConversation = () => { if (matchMedia('(max-width: 768px)').matches) collapseSidebar(true, false); };

const ctx = {
  switchColony: async (id) => {
    await selectColony(id);
    render(true);
  },
  openDM: (beeId) => {
    if (state.data && state.data.actor_bee_id === beeId) { toast('这是你自己，不用和自己对话'); return; }
    const m = memberById(beeId);
    pushPath({ type: "dm", beeId, display: m ? m.display : beeId });
    revealConversation();
    render(true);
  },
  // 左侧「群聊」：所有成员（人 / AI）的公共对话
  openGroupChat: () => {
    resetToChat();
    revealConversation();
    refresh();
    render(true);
  },
  openTask: (taskId, title) => {
    pushPath({ type: "drill", taskId, title });
    render(true);
  },
  // 侧栏「›」：直接深钻它最近的任务
  drillBee: async (m) => {
    try {
      const trail = await rpc("colony.bee.trail", { colonyId: state.colonyId, beeId: m.id });
      const t = (trail.tasks || [])[0];
      if (t) {
        pushPath({ type: "drill", taskId: t.id, title: t.title });
        render(true);
      } else if (state.data && state.data.actor_bee_id === m.id) {
        toast("这是你自己，没有任务可钻");
      } else {
        toast("它还没有任务，先给它派一个");
        ctx.openDM(m.id);
      }
    } catch (e) {
      toast(e.message || "打不开它的任务", true);
    }
  },
  // 头部「＋ 新任务」：预填任务指令，1:1 里发出去就是直接派给这只 Bee
  prefillTask: () => {
    prefill("建个任务：");
  },
  // 点 Bee：左侧换成它的对话列表；有对话就直接打开最近一条（真实 newbee 会话）
  enterBeeMode: async (beeId) => {
    await enterBeeMode(beeId);
    revealConversation();
    render(true);
  },
  exitBeeMode: async () => {
    await exitBeeMode();
    render(true);
  },
  openConversation: async (sessionId, beeId) => {
    await openConversation(sessionId, beeId);
    revealConversation();
    render(true);
  },
  openBeeTrail: async (beeId) => {
    await openBeeTrail(beeId);
    render(true);
  },
  newConversation: async (beeId) => {
    try {
      const res = await rpc("colony.bee.conversation.new", { colonyId: state.colonyId, beeId });
      toast("已新建对话");
      await refresh();
      await openConversation(res.sessionId, beeId);
      render(true);
    } catch (e) {
      toast(e.message || "新建对话失败", true);
    }
  },
  refreshNow: async () => {
    await refresh();
    render(true);
  },
  render: (force) => render(force),
  autofocus: window.matchMedia("(min-width: 769px)").matches,
};

function signature() {
  const d = state.data;
  const members = d ? (d.members || []).map((m) => `${m.id}:${m.status}:${m.active_tasks}`).join(",") : "";
  const tasks = d ? (d.tasks || []).map((t) => `${t.id}:${t.status}:${t.revision || ""}`).join(",") : "";
  const trace = d && d.trace && d.trace.length ? d.trace[d.trace.length - 1].seq : 0;
  const trail = state.trail && state.trail.trace && state.trail.trace.length ? state.trail.trace[state.trail.trace.length - 1].seq : 0;
  const drill = state.drill && state.drill.task ? `${state.drill.task.id}:${state.drill.task.status}:${state.drill.task.revision || ""}:${(state.drill.tasks || []).length}` : "";
  // 对话列表的标题/条数变化也要触发重绘（改名、删除、新消息都会改它）。
  const convs = (state.trail && state.trail.conversations || []).map((c) => `${c.id}:${c.title}:${c.messages || 0}`).join("|");
  const colonyName = d?.colony?.name || "";
  const colonyNames = (state.colonies || []).map((c) => c.colony?.name || "").join("|");
  return JSON.stringify([state.colonyId, colonyName, colonyNames, state.view, state.stack.map((s) => s.beeId || s.taskId).join(">"), state.filter, members, tasks, trace, trail, drill, state.colonies.length, state.lastError, d?.control_state, d?.can_manage, (d?.honey?.recent || []).map(h=>`${h.id}:${h.review_state}`).join(','), (d?.members || []).map(m=>m.control_state).join(','), convs]);
}

function render(force = false) {
  const sig = signature();
  if (!force && sig === lastSig) return;
  lastSig = sig;

  renderSidebar($("#colony-list"), ctx);
  renderBreadcrumbs();
  renderTopMeta();
  renderFoot();

  // 视图切换：会话视图用内嵌的真实 newbee 界面，其余用蜂群自己的流
  const embedding = state.view === "conversation" && !!state.conversationId && state.mode === "bee";
  const transcript = $("#transcript");
  const composer = $("#composer");
  const embedHost = $("#embed-host");
  const tools = document.querySelector(".session-tools");

  if (tools) tools.classList.toggle("hidden", state.mode === "bee");
  if (transcript) transcript.classList.toggle("hidden", embedding);
  if (composer) composer.classList.toggle("hidden", embedding);
  if (embedHost) embedHost.classList.toggle("hidden", !embedding);

  if (embedding) {
    const frame = $("#embed-frame");
    const src = `/workspace.html?session=${encodeURIComponent(state.conversationId)}&embed=1`;
    if (frame.dataset.src !== src) {
      frame.dataset.src = src;
      frame.src = src;
    }
    $("#review-bar").classList.add("hidden");
    renderTopMeta();
    renderFoot();
    return;
  }

  const flow = $("#flow");
  const wasNearBottom = flow.scrollHeight - flow.scrollTop - flow.clientHeight < 120;
  flow.innerHTML = "";

  if (state.lastError) flow.appendChild(note(`加载失败：${state.lastError}`, true));

  if (!state.colonyId) {
    const empty = document.createElement("div");
    empty.className = "colony-empty";
    empty.innerHTML = `<div>还没有蜂群。蜂群 = 一群一起干活的 Bee（人 / AI）。</div>`;
    const btn = document.createElement("button");
    btn.className = "btn-allow";
    btn.textContent = "创建一个蜂群";
    btn.onclick = async () => {
      await rpc("colony.bootstrap", {});
      await loadColonies();
      await refresh();
      render(true);
    };
    empty.appendChild(btn);
    flow.appendChild(empty);
  } else if (state.view === "drill") {
    renderDrillView(flow, ctx);
  } else if (state.view === "dm") {
    renderDMView(flow, ctx);
  } else {
    renderGroupView(flow, ctx);
  }

  if (wasNearBottom) scrollBottom();
  updateScope();
  updateReviewBar();
}

function renderTopMeta() {
  const d = state.data;
  const meta = $("#session-meta");
  const label = $("#usage-label");
  if (!d) {
    if (meta) meta.textContent = "";
    if (label) label.textContent = "";
    return;
  }
  const s = d.stats || {};
  const parts = [];
  parts.push(`${s.members || 0} 成员`);
  if (s.tasks_open) parts.push(`${s.tasks_open} 项在办`);
  if (s.honey_total) parts.push(`成果 ${s.honey_accepted || 0}/${s.honey_total}`);
  if (meta) meta.textContent = parts.join(" · ");
  // 详细统计仍保留在顶栏右侧（桌面端可见，手机端由 CSS 收起）。
  if (label) {
    const tasks = (s.tasks_open || 0) + (s.tasks_done || 0);
    label.textContent = `共 ${tasks} 项工作 · 成果 ${s.honey_accepted || 0}/${s.honey_total || 0}`;
  }
  const dot = $("#status-dot");
  if (dot) {
    dot.className = "dot" + (s.working > 0 ? " busy" : "");
    dot.title = s.working > 0 ? `${s.working} 只 Bee 正在干活` : "空闲";
  }
}

function renderFoot() {
  const colony = state.data?.colony;
  $("#colony-footnote").textContent = colony?.goal || "蜂群 = 一起干活的 Bee（人 / AI）";
  updateWorkspaceContext();
}

function note(text, bad) {
  const node = document.createElement("div");
  node.className = "msg msg-assistant";
  node.style.color = bad ? "var(--nb-red)" : "var(--nb-label-caption)";
  node.textContent = text;
  return node;
}

function scrollBottom() {
  const tr = $("#transcript");
  if (tr) tr.scrollTop = tr.scrollHeight;
}

// ── 绑定固定控件 ──
function bindChrome() {
  $("#colony-filter").addEventListener("input", (e) => {
    state.filter = e.target.value;
    render(true);
  });

  $("#new-colony").addEventListener("click", async () => {
    const input = await form('新建蜂群', [{name:'name',label:'蜂群名称',required:true,placeholder:'例如：蜂群体验验收'}, {name:'goal',label:'共同目标',multiline:true,placeholder:'希望这群 Bee 一起完成什么？'}], '创建蜂群');
    if (!input) return;
    try {
      const created = await rpc('colony.create', input);
      await loadColonies();
      await selectColony(created.colony.id);
      toast('蜂群已创建，可以开始讨论或添加伙伴');
      render(true);
    } catch (e) {
      toast(e.message || "创建失败", true);
    }
  });

  $("#to-bottom").addEventListener("click", scrollBottom);


}

async function boot() {
  initShell();
  bindChrome();
  subscribe(() => render());
  try {
    await redeemInvitation();
    await ensureAuthenticated();
    await loadColonies();
    await refresh();
  } catch (e) {
    state.lastError = e.message || String(e);
  }
  // Start updates independently of the first render; one card must not freeze the whole feed.
  startPolling(3000);
  renderComposer(ctx);
  render(true);
  window.addEventListener("resize", () => render(true));
  window.addEventListener("keydown", (e) => {
    if (e.key !== "Escape") return;
    if (document.activeElement && document.activeElement.id === "input") return;
    if (!state.stack.length) return;
    resetToChat();
    revealConversation();
    refresh();
    render(true);
  });
}

export const colonyCtx = ctx;

// 便于调试 / 端到端测试：暴露状态与操作入口
window.__colony = { state, ctx, rpc, render, refresh };

boot().catch(error => { console.error('[colony] boot failed', error); toast(error.message || '界面初始化失败，请刷新', true); });

