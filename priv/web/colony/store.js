// 蜂群前端 · 状态中心（订阅 + 轮询）
import { rpc, toast, isMemberSession } from "./api.js";

const listeners = new Set();
let refreshSequence = 0;
let authRetryUsed = false;

export const state = {
  colonies: [],
  filter: "",
  collapsed: {},
  mode: "colony",        // colony | bee（点了某只 Bee，左侧换成它的对话列表）
  beeModeId: null,
  conversationId: null,   // 当前打开的对话（会话）
  modeBeforeBee: null,
  attachments: [],
  uploading: 0,
  attachSid: null,
  effortSid: null,
  token: null,
  colonyId: null,
  view: "chat",            // chat | dm | drill
  stack: [],               // [{type:'chat'} | {type:'dm',beeId,display} | {type:'drill',taskId,title}]
  data: null,              // colony.view 载荷
  trail: null,             // colony.bee.trail 载荷
  drill: null,             // colony.drill 载荷
  capabilities: [],
  lastError: null,
  polling: false,
  refreshing: false,
  groupTab: 'work',
  workFilter: 'attention',
  inspector: null,
  routeNotice: '',
};

function syncConversationUrl(replace = false, allowBeforeEnable = false, allowDuringRestore = false) {
  if (typeof window === 'undefined' || (!navigationEnabled && !allowBeforeEnable) || (restoringRoute && !allowDuringRestore)) return;
  const url = new URL(location.href);
  for (const key of ['colony', 'bee', 'conversation', 'task', 'view', 'queue', 'sourceBee', 'section']) url.searchParams.delete(key);
  if (state.colonyId) url.searchParams.set('colony', state.colonyId);
  const taskId = currentTaskId();
  const sourceBeeId = taskId && state.stack.find(entry => entry.type === 'drill')?.fromBeeId;
  if (taskId) {
    url.searchParams.set('task', taskId);
    if (state.drillTab && state.drillTab !== 'overview') url.searchParams.set('section', state.drillTab);
    if (sourceBeeId) url.searchParams.set('sourceBee', sourceBeeId);
  }
  else {
    url.searchParams.set('view', state.view === 'dm' ? 'member' : state.groupTab);
    if (state.view === 'chat' && state.groupTab === 'work' && ['attention', 'active', 'finished'].includes(state.workFilter)) url.searchParams.set('queue', state.workFilter);
  }
  const beeId = state.inspector?.beeId || state.beeModeId;
  if (beeId) url.searchParams.set('bee', beeId);
  if (state.inspector) url.searchParams.set('conversation', state.inspector.sessionId);
  const next = url.pathname + url.search + url.hash;
  if (next !== location.pathname + location.search + location.hash) {
    history[replace ? 'replaceState' : 'pushState']({newbee: true}, '', next);
  }
}

export function selectWorkSection(section) {
  if (!['overview', 'collaboration', 'execution', 'results', 'history'].includes(section)) return;
  state.drillTab = section;
  syncConversationUrl();
  emit();
}

export function subscribe(fn) {
  listeners.add(fn);
  return () => listeners.delete(fn);
}

export function emit() {
  for (const fn of listeners) {
    try { fn(state); } catch (e) { console.error("[colony] listener failed", e); }
  }
}

function invalidateMemberSession() {
  state.inspector = null; inspectorSequence += 1;
  state.colonies = [];
  state.colonyId = null;
  state.data = null;
  state.trail = null;
  state.drill = null;
  state.stack = [];
  state.mode = "colony";
  state.beeModeId = null;
  state.conversationId = null;
  state.lastError = "成员凭据已失效，请重新加入蜂群";
}

export async function loadColonies() {
  let res;
  try {
    res = await rpc("colony.list");
    authRetryUsed = false;
  } catch (error) {
    if (error?.code === "unauthorized" && isMemberSession()) {
      invalidateMemberSession();
      emit();
      return state.colonies;
    }
    // 加载失败时不要清空已有列表、也不要让界面退回「还没有蜂群」的引导态：
    // 那会让用户以为数据丢了（真实场景：令牌过期后本地模式也会被拒）。
    state.lastError = error.message || String(error);
    emit();
    // rpc 遇到 unauthorized 会清掉失效令牌；本地模式本来就免认证，
    // 这里自动重试一次即可自愈（有界，避免死循环）。
    if (!authRetryUsed) {
      authRetryUsed = true;
      setTimeout(() => { void loadColonies(); }, 600);
    }
    return state.colonies;
  }
  state.colonies = res.colonies || [];
  if (!state.colonies.some(item => item.colony.id === state.colonyId)) {
    let remembered = null;
    try { remembered = localStorage.getItem('newbee.colony.active'); } catch (_) {}
    const target = state.colonies.find(item => item.colony.id === remembered) || state.colonies[0];
    await selectColony(target?.colony.id || null);
  }
  emit();
  return state.colonies;
}

export async function selectColony(colonyId, internal = false) {
  beginNavigation(internal);
  if (state.colonyId === colonyId) return;
  state.inspector = null; inspectorSequence += 1;
  state.colonyId = colonyId;
  try { if (colonyId) localStorage.setItem('newbee.colony.active', colonyId); else localStorage.removeItem('newbee.colony.active'); } catch (_) {}
  state.attachments = []; state.uploadSid = null; state.uploadColony = null;
  state.mode = 'colony'; state.beeModeId = null; state.conversationId = null;
  state.stack = [];
  state.view = "chat";
  state.data = null;
  state.trail = null;
  state.drill = null;
  syncConversationUrl();
  emit();
  await refresh();
}

export async function refresh() {
  if (!state.colonyId) return;
  const colonyId = state.colonyId;
  const sequence = ++refreshSequence;
  const routeKey = () => JSON.stringify([state.colonyId, state.view, state.beeModeId, state.conversationId, state.stack]);
  const route = routeKey();
  const current = () => sequence === refreshSequence && route === routeKey();
  state.refreshing = true;
  emit();
  let detailRequest = false;
  try {
    const params = { colonyId };
    const prevRev = state.data && state.data.view_revision;
    if (prevRev != null) params.sinceRevision = prevRev;
    const view = await rpc("colony.view", params);
    if (!current()) return;
    // An unchanged overview does not imply unchanged member or task detail.
    if (view.changed !== false) state.data = view;
    state.lastError = null;

    // 一对一视图与「Bee 模式」都需要 trail（Bee 模式靠它出对话列表）
    const trailBeeId = state.view === "dm" ? currentBeeId() : state.mode === "bee" ? state.beeModeId : null;
    if (trailBeeId) {
      const trail = await rpc("colony.bee.trail", { colonyId, beeId: trailBeeId });
      if (!current()) return;
      state.trail = trail;
    }
    if (state.view === "drill" && currentTaskId()) {
      detailRequest = true;
      const drill = await rpc("colony.drill", { colonyId, taskId: currentTaskId() });
      if (!current()) return;
      state.drill = drill;
    }
  } catch (e) {
    if (!current()) return;
    if (detailRequest && ['not_found', 'forbidden'].includes(e?.code)) {
      state.routeNotice = '该工作不存在或当前不可访问，已返回工作列表。';
      state.lastError = null; state.groupTab = 'work';
      resetToChat(true); syncConversationUrl(true, true, true); return;
    }
    if (e?.code === "unauthorized" && isMemberSession()) {
      invalidateMemberSession();
      return;
    }
    if (e && e.code === "dissolved") {
      // 蜂群可能在别的标签 / 别的设备上被解散：localStorage 里的 active 还指着它，
      // 不处理就会永远显示一个幽灵蜂群并对着它空转轮询。
      state.lastError = null;
      await selectColony(null);
      await loadColonies();
      toast("蜂群已解散，已回到蜂群列表");
      return;
    }
    state.lastError = e.message || String(e);
    console.error("[colony] refresh failed", e);
  } finally {
    if (sequence === refreshSequence) { state.refreshing = false; emit(); }
  }
}

export function startPolling(ms = 3000) {
  if (state.polling) return;
  state.polling = true;
  const tick = async () => {
    if (document.visibilityState === "visible") await refresh();
    setTimeout(tick, ms);
  };
  setTimeout(tick, ms);
}

// ── 面包屑路径 ──

export function pushPath(entry) {
  beginNavigation();
  state.inspector = null; inspectorSequence += 1;
  // 同级重复点击不叠加
  const top = state.stack[state.stack.length - 1];
  if (top && top.type === entry.type &&
      top.beeId === entry.beeId && top.taskId === entry.taskId) { syncConversationUrl(false, true); emit(); return; }
  state.stack = [entry];
  state.mode = entry.type === 'dm' ? 'bee' : 'colony';
  state.beeModeId = entry.type === 'dm' ? entry.beeId : null;
  state.view = entry.type;
  state.trail = null;
  state.drill = null;
  syncConversationUrl(false, true);
  // 进入新层级立刻拉取该层级数据（不等下一次轮询）
  void refresh();
  emit();
}

export function gotoLevel(index) {
  beginNavigation();
  state.inspector = null; inspectorSequence += 1;
  state.stack = state.stack.slice(0, index + 1);
  const top = state.stack[state.stack.length - 1];
  state.view = top ? top.type : "chat";
  state.trail = null;
  state.drill = null;
  syncConversationUrl(false, true);
  void refresh();
  emit();
}

export function resetToChat(internal = false) {
  beginNavigation(internal);
  state.inspector = null; inspectorSequence += 1;
  state.mode = 'colony'; state.beeModeId = null; state.conversationId = null; state.modeBeforeBee = null;
  state.stack = [];
  state.view = "chat";
  state.trail = null;
  state.drill = null;
  syncConversationUrl(false, !internal);
  emit();
}

// ── 左侧模式：蜂群 ↔ 某只 Bee 的对话列表 ──

export async function enterBeeMode(beeId, internal = false) {
  beginNavigation(internal);
  state.inspector = null; inspectorSequence += 1;
  const m = memberById(beeId);
  if (state.mode !== 'bee') state.modeBeforeBee = { view: state.view, stack: state.stack.slice() };
  state.trail = null;
  state.drill = null;
  state.conversationId = null;
  state.mode = "bee";
  state.beeModeId = beeId;
  state.view = "dm";
  state.stack = [{ type: "dm", beeId, display: m ? m.display : beeId }];
  syncConversationUrl(false, !internal);
  await refresh();
  if (state.mode !== 'bee' || state.beeModeId !== beeId || state.view !== 'dm') return;
  emit();
}

export async function exitBeeMode() {
  beginNavigation();
  state.inspector = null; inspectorSequence += 1;
  state.mode = "colony";
  state.beeModeId = null;
  state.conversationId = null;
  const prev = state.modeBeforeBee || { view: "chat", stack: [] };
  state.stack = prev.stack || [];
  state.view = prev.view === "conversation" ? "chat" : prev.view;
  state.modeBeforeBee = null;
  syncConversationUrl(false, true);
  await refresh();
  emit();
}

export async function openConversation(sessionId, beeId, internal = false) {
  beginNavigation(internal);
  const colonyId = state.colonyId;
  const sequence = ++inspectorSequence;
  const task = (state.data?.tasks || []).find(t => t.session_id === sessionId);
  beeId = beeId || task?.assigned_bee_id;
  state.inspector = {sessionId, beeId, inspectionId: crypto.randomUUID(), status: 'loading', title: task?.title || '执行会话', taskId: task?.id};
  syncConversationUrl(internal, !internal);
  if (!internal && history.state?.newbee) history.replaceState({...history.state, inspector: true}, '', location.href);
  emit();
  try {
    if (!beeId || !memberById(beeId)) {
      state.routeNotice = '该会话不存在或已不属于当前成员。';
      closeInspector(true);
      return;
    }
    const trail = await rpc('colony.bee.trail', {colonyId, beeId});
    if (sequence !== inspectorSequence || colonyId !== state.colonyId) return;
    const conversation = (trail.conversations || []).find(c => c.id === sessionId && c.kind !== 'human');
    if (!conversation) {
      state.routeNotice = '该会话不存在或已不属于当前成员，已保留原工作页面。';
      closeInspector(true);
      return;
    }
    state.inspector = {...state.inspector, status: 'connecting', title: conversationLabel(conversation, beeId), conversation};
    emit();
  } catch (error) {
    if (sequence !== inspectorSequence || colonyId !== state.colonyId) return;
    state.inspector = {...state.inspector, status: 'error', error: error.message || '连接失败'};
    emit();
  }
}

export async function openBeeTrail(beeId) {
  beginNavigation();
  state.inspector = null; inspectorSequence += 1;
  const m = memberById(beeId);
  state.mode = "bee";
  state.beeModeId = beeId;
  state.conversationId = null;
  state.view = "dm";
  state.stack = [{ type: "dm", beeId, display: m ? m.display : beeId }];
  syncConversationUrl(false, true);
  await refresh();
  emit();
}
export function currentBeeId() {
  for (let i = state.stack.length - 1; i >= 0; i--) {
    if (state.stack[i].beeId) return state.stack[i].beeId;
  }
  return null;
}

export function currentTaskId() {
  for (let i = state.stack.length - 1; i >= 0; i--) {
    if (state.stack[i].taskId) return state.stack[i].taskId;
  }
  return null;
}

export function me() {
  const data = state.data;
  if (!data) return null;
  const queenId = data.colony && data.colony.queen_bee_id;
  return (data.members || []).find((m) => m.id === queenId) || null;
}

export function memberById(id) {
  if (!state.data) return null;
  return (state.data.members || []).find((m) => m.id === id) || null;
}

export function memberByName(name) {
  if (!state.data) return null;
  return (state.data.members || []).find((m) => m.display === name) || null;
}


// A location describes the work being read; inspecting an execution never changes its send target.
let navigationEnabled = false;
let restoringRoute = false;
let navigationSequence = 0;
let inspectorSequence = 0;
function beginNavigation(internal = false) {
  if (!internal) { navigationSequence += 1; restoringRoute = false; }
}
export function enableNavigation() { navigationEnabled = true; if (!state.lastError && state.inspector?.status !== 'error') syncConversationUrl(true); }
export function openHome(tab = 'work') {
  if (tab === 'attention') { state.groupTab = 'work'; state.workFilter = 'attention'; }
  else state.groupTab = tab;
  resetToChat();
}
export function closeInspector(internal = false) {
  beginNavigation(internal);
  inspectorSequence += 1;
  state.inspector = null;
  syncConversationUrl(true, !internal);
  emit();
}
export function conversationLabel(conversation, beeId) {
  const task = (state.data?.tasks || []).find(t => t.session_id === conversation?.id);
  const title = String(conversation?.title || '').trim();
  if (title && !['工作执行', '私聊', '新对话', '新会话'].includes(title)) return title;
  return task?.title || `${memberById(beeId)?.display || 'Bee'} · ${conversation?.when || (conversation?.id || '').slice(-6) || '新会话'}`;
}
export async function restoreLocation() {
  const sequence = ++navigationSequence;
  const params = new URLSearchParams(location.search);
  const colonyId = params.get('colony');
  const taskId = params.get('task');
  const beeId = params.get('bee');
  const sourceBeeId = params.get('sourceBee');
  const sid = params.get('conversation');
  restoringRoute = true;
  state.routeNotice = '';
  try {
    if (state.lastError && !state.colonies.length) return;
    if (colonyId && !state.colonies.some(c => c.colony.id === colonyId)) {
      state.routeNotice = '无法打开该蜂群：它可能已删除，或你当前无法访问。';
      resetToChat(true);
      syncConversationUrl(true, true, true);
      return;
    }
    if (colonyId && colonyId !== state.colonyId) await selectColony(colonyId, true);
    if (sequence !== navigationSequence) return;
    if (state.lastError && !state.data) return;
    closeInspector(true);
    const routeView = params.get('view');
    if (routeView === 'attention') { state.groupTab = 'work'; state.workFilter = 'attention'; }
    else { state.groupTab = ['work', 'messages'].includes(routeView) ? routeView : 'work'; }
    if (state.groupTab === 'work' && ['attention', 'active', 'finished'].includes(params.get('queue'))) state.workFilter = params.get('queue');
    resetToChat(true);
    if (taskId) {
      state.drillTab = ['overview', 'collaboration', 'execution', 'results', 'history'].includes(params.get('section')) ? params.get('section') : 'overview';
      state.stack = [{type: 'drill', taskId, fromBeeId: sourceBeeId || undefined}];
      state.view = 'drill';
      await refresh();
      if (sequence !== navigationSequence) return;
      if (!state.drill?.task && !state.lastError) {
        state.routeNotice = '该工作不存在或当前不可访问，已返回工作列表。';
        resetToChat(true);
        syncConversationUrl(true, true, true);
      }
    } else if (params.get('view') === 'member' && beeId) {
      if (memberById(beeId)) await enterBeeMode(beeId, true);
      else { state.routeNotice = '该成员已不属于当前蜂群，已返回工作列表。'; syncConversationUrl(true, true, true); }
    }
    if (sequence !== navigationSequence) return;
    if (sid) await openConversation(sid, beeId, true);
  } finally {
    if (sequence === navigationSequence) {
      restoringRoute = false;
      // A failed request remains retryable at the original address.
      if (!state.lastError && state.inspector?.status !== 'error') syncConversationUrl(true);
      emit();
    }
  }
}

// One attention policy for the sidebar count and the actionable inbox.
export function attentionTasks() {
  const tasks = state.data?.tasks || [];
  const byId = new Map(tasks.map(task => [task.id, task]));
  const result = new Map();
  for (const task of tasks) {
    if (['done', 'cancelled'].includes(task.status)) continue;
    const needsHuman = ['blocked', 'pending_review', 'failed'].includes(task.status) || task.waiting_for === 'user' || task.approval_required || task.workflow?.phase === 'choosing';
    if (!needsHuman) continue;
    // Internal deliverables are integrated by the owner, not a second human review.
    if (task.integration_required && task.status === 'pending_review') continue;
    const parent = byId.get(task.parent_task_id || task.workflow_root);
    const visible = parent && !['done', 'cancelled'].includes(parent.status) ? parent : task;
    result.set(visible.id, visible);
  }
  return [...result.values()];
}

