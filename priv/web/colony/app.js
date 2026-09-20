import { initWorkbench, renderInspector, renderAttention, rememberReadingPosition, showQuickOpen } from './workbench.js?v=workbench-5';
// 蜂群前端 · 入口：装配模块、轮询、事件绑定。
// 视觉全部复用主界面的组件类（#sidebar / .session-group / .msg-* / .composer-card …），
// 本页只负责「蜂群 = 会话组 + 成员」的数据映射。
import { esc } from "./util.js";
import { form } from './forms.js';
import { initShell, ensureAuthenticated, updateWorkspaceContext, collapseSidebar, selectedWorkspaceCwd, sendIntoConversation, openWorkspace } from './shell.js?v=workbench-6';
import { redeemInvitation } from './manage.js';
import { rpc, toast } from "./api.js";
import {
  state, subscribe, loadColonies, selectColony, refresh, startPolling,
  pushPath, memberById, resetToChat, enterBeeMode, exitBeeMode, openConversation, openBeeTrail,
  restoreLocation, enableNavigation, openHome, attentionTasks, pendingReviewResults,
} from "./store.js";
import { renderSidebar, renderBeeConversations } from "./sidebar.js";
import { renderBreadcrumbs } from "./breadcrumbs.js";
import { renderGroupView, renderDMView } from "./chat.js?v=workbench-1";
import { renderDrillView } from "./drill.js?v=workbench-30";
import { renderComposer, syncComposerDraft, updateScope, updateReviewBar, send, prefill } from './composer.js?v=workbench-4';
import { bindMarkdownCopy } from "./md.js";

const $ = (sel) => document.querySelector(sel);
// 跳转后接管焦点：只在焦点已经落空（body）或落在被替换掉的节点上时才动，
// 免得把用户正在操作的控件（例如输入框）抢走。
function focusMainRegion() {
  const active = document.activeElement;
  const inDoc = active && active !== document.body && document.body.contains(active);
  if (inDoc) return;
  const main = document.getElementById("transcript") || document.getElementById("main");
  if (!main) return;
  if (!main.hasAttribute("tabindex")) main.setAttribute("tabindex", "-1");
  main.focus({ preventScroll: true });
}

let lastSig = null;

let lastRoute = null;

const revealConversation = () => { if (matchMedia('(max-width: 768px)').matches) collapseSidebar(true, false); };

const ctx = {
  quickOpen: () => showQuickOpen(),
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
    state.groupTab = 'messages';
    resetToChat();
    revealConversation();
    refresh();
    render(true);
  },
  openHome: (tab) => { openHome(tab); revealConversation(); render(true); },
  openDirectory: (taskId) => openWorkspace('directory', taskId),
  openTask: (taskId, title, section = 'overview') => {
    state.drillTab = section;
    pushPath({ type: "drill", taskId, title });
    render(true);
  },
  // 侧栏「›」：直接深钻它最近的任务
  drillBee: async (m) => {
    try {
      const trail = await rpc("colony.bee.trail", { colonyId: state.colonyId, beeId: m.id });
      const t = (trail.tasks || [])[0];
      if (t) {
        pushPath({ type: "drill", taskId: t.id, title: t.title, fromBeeId: m.id });
        state.drillTab = 'overview';
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
  // 头部「＋ 新任务」：给这只 Bee 派活。成员层级里打字只会进它的（1:1）对话，
  // 创建不了群任务（服务端对 AI 的 1:1 固定返回 conversation_required）；
  // 真能「直接派给它」的路径是群聊 @点名——服务端按 @ 把这句话派给被点名的 Bee。
  prefillTask: () => {
    const bee = state.beeModeId ? memberById(state.beeModeId) : null;
    resetToChat();
    state.groupTab = "messages"; // 派活这句话落在群聊记录里，别把用户留在工作台
    prefill(bee ? `@${bee.display} 建个任务：` : "建个任务：");
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
      const cwd = selectedWorkspaceCwd();
      const colonyId = state.colonyId;
      const payload = { colonyId, beeId };
      if (cwd) payload.cwd = cwd;
      const res = await rpc("colony.bee.conversation.new", payload);
      if (state.colonyId !== colonyId) return;
      toast("已新建对话");
      await refresh();
      await openConversation(res.sessionId, beeId);
      render(true);
    } catch (e) {
      toast(e.message || "新建对话失败", true);
    }
  },
  // 成员概览里的输入明确发送到该成员已有的当前/最近会话；只有没有会话时才创建。
  deliverToConversation: async (bee, text) => {
    const colonyId = state.colonyId;
    try {
      const conversations = (state.trail?.conversations || []).filter(c => c.kind !== 'human');
      let sid = bee.session_id || conversations.find(c => c.current)?.id || conversations[0]?.id;
      if (!sid) {
        const res = await rpc("colony.bee.conversation.new", { colonyId, beeId: bee.id });
        sid = res.sessionId;
        await refresh();
      }
      if (state.colonyId !== colonyId || state.beeModeId !== bee.id || state.view !== 'dm') throw new Error('指导对象已切换，请回到原成员重试');
      await openConversation(sid, bee.id);
      if (state.inspector?.sessionId !== sid) throw new Error('无法打开目标会话');
      await sendIntoConversation(text);
      toast(`已转到 ${bee.display} 的会话`);
    } catch (e) {
      toast(e.message || "打开会话失败", true);
      throw e;
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
  const traceItems = Array.isArray(d?.trace) ? d.trace : [];
  const trace = traceItems.length ? traceItems[traceItems.length - 1].seq : 0;
  const traceFirst = traceItems.length ? traceItems[0].seq : 0;
  const tracePage = d?.trace_page ? [d.trace_page.before_seq, d.trace_page.snapshot_seq, d.trace_page.has_more].join(':') : '';
  const trail = state.trail && state.trail.trace && state.trail.trace.length ? state.trail.trace[state.trail.trace.length - 1].seq : 0;
  const drillTrace = Array.isArray(state.drill?.trace) ? state.drill.trace : [];
  const drill = state.drill && state.drill.task ? `${state.drill.task.id}:${state.drill.task.status}:${state.drill.task.revision || ''}:${(state.drill.tasks || []).length}` : '';
  const drillFirst = drillTrace.length ? drillTrace[0].seq : 0;
  const drillPage = state.drill?.trace_page ? [state.drill.trace_page.before_seq, state.drill.trace_page.snapshot_seq, state.drill.trace_page.has_more].join(':') : '';
  // 对话列表的标题/条数变化也要触发重绘（改名、删除、新消息都会改它）。
  const convs = (state.trail && state.trail.conversations || []).map((c) => `${c.id}:${c.title}:${c.messages || 0}`).join("|");
  const colonyName = d?.colony?.name || "";
  const colonyNames = (state.colonies || []).map((c) => c.colony?.name || "").join("|");
  return JSON.stringify([state.colonyId, state.drillTab, state.inspector?.sessionId, colonyName, colonyNames, state.groupTab, state.workFilter, state.conversationId, state.mode, state.view, state.stack.map((s) => s.beeId || s.taskId).join('>'), state.filter, members, tasks, trace, traceFirst, tracePage, trail, drill, drillTrace.length, drillFirst, drillPage, state.colonies.length, state.lastError, d?.control_state, d?.can_manage, (d?.honey?.recent || []).map(h=>`${h.id}:${h.review_state}`).join(','), (d?.members || []).map(m=>m.control_state).join(','), convs]);
}

function render(force = false) {
  renderInspector();
  updateWorkspaceContext();
  renderSyncStatus();
  const sig = signature();
  if (!force && sig === lastSig) return;
  lastSig = sig;

  renderSidebar($("#colony-list"), ctx);
  renderBreadcrumbs();
  renderTopMeta();
  renderWorkspaceContext();

  const transcript = $('#transcript');
  const tools = document.querySelector('.session-tools');
  if (tools) tools.classList.remove('hidden');
  const restoredPosition = rememberReadingPosition();

  const flow = $("#flow");
  const route = JSON.stringify([state.colonyId, state.view, state.stack, state.groupTab]);
  const sameRoute = route === lastRoute;
  const scrollTop = transcript.scrollTop;
  const wasNearBottom = transcript.scrollHeight - scrollTop - transcript.clientHeight < 120;
  const focused = document.activeElement;
  const focusTask = sameRoute && flow.contains(focused) ? focused.closest('[data-task-id]')?.dataset.taskId : null;
  const focusLabel = focused?.getAttribute?.('aria-label') || focused?.textContent;
  const disclosures = sameRoute ? [...flow.querySelectorAll('details')].map(d => [d.querySelector('summary')?.textContent, d.open]) : [];
  flow.innerHTML = "";

  if (state.colonyId && !state.data) {
    flow.appendChild(note(state.lastError ? '暂时无法加载蜂群，请点击上方重试。' : '正在加载蜂群…'));
    updateScope();
    return;
  }

  if (!state.colonyId) {
    if (state.lastError) {
      const memberExpired = state.lastError === '成员凭据已失效，请重新加入蜂群';
      const left = state.lastError === '已退出蜂群';
      const failed = document.createElement("div");
      failed.className = "colony-empty";
      const message = memberExpired
        ? '成员凭据已失效，请使用新的邀请链接重新加入蜂群。'
        : left
          ? '已退出蜂群，可使用新的邀请链接重新加入。'
          : `暂时无法加载蜂群：${state.lastError}`;
      failed.innerHTML = `<div>${message}</div>`;
      if (!memberExpired && !left) {
        const retry = document.createElement("button");
        retry.className = "btn-allow";
        retry.textContent = "重试";
        retry.onclick = async () => { await loadColonies(); await refresh(); render(true); };
        failed.appendChild(retry);
      }
      flow.appendChild(failed);
      renderTopMeta();
      return;
    }

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
    if (state.beeModeId) renderBeeConversations($("#colony-list"), ctx);
  } else if (state.groupTab === 'attention') {
    renderAttention(flow, ctx);
  } else {
    renderGroupView(flow, ctx);
  }

  if (sameRoute) {
    const remaining = disclosures.slice();
    for (const details of flow.querySelectorAll('details')) {
      const i = remaining.findIndex(([label]) => label === details.querySelector('summary')?.textContent);
      if (i >= 0) details.open = remaining.splice(i, 1)[0][1];
    }
  }
  if (focusTask && !focused.isConnected) {
    const card = [...flow.querySelectorAll('[data-task-id]')].find(node => node.dataset.taskId === focusTask);
    const target = [...(card?.querySelectorAll('button, summary, input, [tabindex="0"]') || [])].find(node => (node.getAttribute('aria-label') || node.textContent) === focusLabel);
    target?.focus({preventScroll: true});
  }
  const overview = state.view === 'chat' && state.groupTab !== 'messages';
  const startAtTop = state.view === 'drill' || overview;
  if (!sameRoute) transcript.scrollTop = restoredPosition ?? (startAtTop ? 0 : transcript.scrollHeight);
  else if (wasNearBottom && !startAtTop) scrollBottom();
  else transcript.scrollTop = scrollTop;
  // 跳转（面包屑 / 任务卡 / 验收条）后键盘用户的焦点会掉到 body，接着 Tab 就得从页首重来。
  // 只在「不是第一次渲染」且焦点已经落空（body）或落在被替换掉的节点上时才接管，
  // 免得抢用户正在操作的控件（例如输入框）。
  if (!sameRoute && lastRoute !== null) focusMainRegion();
  lastRoute = route;
  updateNewMsgHint(route, wasNearBottom);
  syncComposerDraft();
  updateScope();
  updateReviewBar();
}

// 有新消息时给一个可见入口：不管你在看工作还是别的对话，都不会漏掉群里的发言。
let seenRoute = null;
let seenSeq = 0;
let dialogEscape = false;

function currentFeed() {
  if (state.view === 'drill') return (state.drill && state.drill.trace) || [];
  if (state.view === 'dm') return (state.trail && state.trail.trace) || [];
  return (state.data && state.data.trace) || [];
}

function setNewMsgHint(count) {
  let btn = document.getElementById('new-msgs');
  if (!count) { if (btn) btn.hidden = true; return; }
  if (!btn) {
    btn = document.createElement('button');
    btn.id = 'new-msgs';
    btn.type = 'button';
    btn.onclick = () => {
      btn.hidden = true;
      if (state.view === 'chat' && state.groupTab !== 'messages') { state.groupTab = 'messages'; render(true); }
      scrollBottom();
    };
    document.body.appendChild(btn);
  }
  btn.textContent = `↓ ${count} 条新消息`;
  btn.hidden = false;
}

function updateNewMsgHint(route, nearBottom) {
  const feed = currentFeed();
  const maxSeq = feed.reduce((max, item) => Math.max(max, item.seq || 0), 0);
  if (route !== seenRoute) { seenRoute = route; seenSeq = maxSeq; setNewMsgHint(0); return; }
  if (maxSeq <= seenSeq) { if (nearBottom) setNewMsgHint(0); return; }
  const added = feed.filter((item) => (item.seq || 0) > seenSeq && item.type === 'message').length;
  seenSeq = maxSeq;
  if (added && !nearBottom) setNewMsgHint(added);
}

function renderSyncStatus() {
  let bar = document.getElementById('sync-status');
  if (!bar) {
    bar = document.createElement('div'); bar.id = 'sync-status';
    bar.setAttribute('role', 'status'); bar.setAttribute('aria-live', 'polite');
    document.getElementById('transcript')?.before(bar);
  }
  const error = state.lastError;
  const memberExpired = error === '成员凭据已失效，请重新加入蜂群';
  const left = error === '已退出蜂群';
  bar.hidden = memberExpired || left || (!error && (!state.refreshing || !!state.data));
  bar.classList.toggle('error', !!error && !memberExpired && !left);
  const message = memberExpired || left ? '' : error ? `更新失败：${error}。${state.data ? '当前显示上次成功加载的内容。' : ''}` : '正在加载…';
  if (bar.dataset.message !== message) {
    bar.dataset.message = message; bar.textContent = message;
    if (error && !memberExpired && !left) {
      const retry = document.createElement('button'); retry.type = 'button'; retry.textContent = '重试';
      retry.onclick = () => ctx.refreshNow(); bar.append(retry);
    }
  }
  const retry = bar.querySelector('button');
  if (retry) { retry.disabled = state.refreshing; retry.textContent = state.refreshing ? '重试中…' : '重试'; }
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
  // 顶栏先说「要你做什么」，人数、成果这类背景统计放到右侧小字，避免两处重复。
  const attention = attentionTasks();
  const pendingHoney = pendingReviewResults().length;
  const todo = attention.length + pendingHoney;
  const parts = [];
  if (todo) parts.push(`待你处理 ${todo} 件`);
  if (s.tasks_open) parts.push(`${s.tasks_open} 项在办`);
  if (s.working > 0) parts.push(`${s.working} 只 Bee 在干活`);
  if (!parts.length) parts.push(`${s.members || 0} 成员`);
  if (meta) meta.textContent = parts.join(" · ");
  if (label) label.textContent = `${s.members || 0} 成员 · 成果 ${s.honey_accepted || 0}/${s.honey_total || 0}`;
  const dot = $("#status-dot");
  if (dot) {
    dot.className = "dot" + (s.working > 0 ? " busy" : "");
    dot.title = s.working > 0 ? `${s.working} 只 Bee 正在干活` : "空闲";
  }
}

function renderWorkspaceContext() {
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
    // 建群要依次走 create → loadColonies → selectColony；这段窗口里界面还停在旧群、
    // 输入框仍可用，用户此刻发送会把消息投进上一个蜂群（实测窗口 1.6s~数秒）。
    state.switching = true;
    try {
      input.cwd = selectedWorkspaceCwd() || undefined;
      const created = await rpc('colony.create', input);
      await loadColonies();
      await selectColony(created.colony.id);
      toast('蜂群已创建，可以开始讨论或添加伙伴');
      render(true);
    } catch (e) {
      toast(e.message || "创建失败", true);
    } finally {
      state.switching = false;
    }
  });

  $("#to-bottom").addEventListener("click", scrollBottom);

  // 自己滚到底部就说明看过了，收起「新消息」提示。
  $("#transcript")?.addEventListener("scroll", (event) => {
    const el = event.currentTarget;
    if (el.scrollHeight - el.scrollTop - el.clientHeight < 80) setNewMsgHint(0);
  });


}

async function boot() {
  initShell();
  initWorkbench(ctx);
  // 代码块「复制」用的是 document 级事件委托，必须调用一次；
  // 之前只 import 没调用，群聊里的复制按钮点了没反应。
  bindMarkdownCopy();
  bindChrome();
  subscribe(() => render());
  try {
    await redeemInvitation();
    await ensureAuthenticated();
    await loadColonies();
    await refresh();
    await restoreLocation();
    enableNavigation();
    window.addEventListener('popstate', () => { void restoreLocation(); });
  } catch (e) {
    state.lastError = e.message || String(e);
  }
  // Start updates independently of the first render; one card must not freeze the whole feed.
  startPolling(3000);
  renderComposer(ctx);
  render(true);
  window.addEventListener("resize", () => render(true));
  document.addEventListener("keydown", (e) => {
    if (e.key !== "Escape" || !e.target?.closest?.("dialog")) return;
    dialogEscape = true;
    setTimeout(() => { dialogEscape = false; }, 0);
  }, true);

}

export const colonyCtx = ctx;

// 便于调试 / 端到端测试：暴露状态与操作入口
window.__colony = { state, ctx, rpc, render, refresh };

boot().catch(error => { console.error('[colony] boot failed', error); toast(error.message || '界面初始化失败，请刷新', true); });

