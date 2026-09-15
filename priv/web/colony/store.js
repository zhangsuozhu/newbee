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
};

function syncConversationUrl() {
  if (typeof window === "undefined") return;
  const url = new URL(location.href);
  const active = state.colonyId && state.beeModeId && state.conversationId &&
    state.mode === "bee" && state.view === "conversation";
  if (active) {
    url.searchParams.set("colony", state.colonyId);
    url.searchParams.set("bee", state.beeModeId);
    url.searchParams.set("conversation", state.conversationId);
  } else {
    ["colony", "bee", "conversation"].forEach((key) => url.searchParams.delete(key));
  }
  const next = url.pathname + url.search + url.hash;
  const current = location.pathname + location.search + location.hash;
  if (next !== current) history.replaceState(null, "", next);
}

export function conversationRouteFromUrl() {
  if (typeof window === "undefined") return null;
  const params = new URLSearchParams(location.search);
  const colonyId = params.get("colony");
  const beeId = params.get("bee");
  const conversationId = params.get("conversation");
  return colonyId && beeId && conversationId ? { colonyId, beeId, conversationId } : null;
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

export async function selectColony(colonyId) {
  if (state.colonyId === colonyId) return;
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
      const drill = await rpc("colony.drill", { colonyId, taskId: currentTaskId() });
      if (!current()) return;
      state.drill = drill;
    }
  } catch (e) {
    if (!current()) return;
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
  // 同级重复点击不叠加
  const top = state.stack[state.stack.length - 1];
  if (top && top.type === entry.type &&
      top.beeId === entry.beeId && top.taskId === entry.taskId) return;
  state.stack.push(entry);
  state.view = entry.type;
  state.trail = null;
  state.drill = null;
  syncConversationUrl();
  // 进入新层级立刻拉取该层级数据（不等下一次轮询）
  void refresh();
  emit();
}

export function gotoLevel(index) {
  state.stack = state.stack.slice(0, index + 1);
  const top = state.stack[state.stack.length - 1];
  state.view = top ? top.type : "chat";
  state.trail = null;
  state.drill = null;
  syncConversationUrl();
  void refresh();
  emit();
}

export function resetToChat() {
  state.mode = 'colony'; state.beeModeId = null; state.conversationId = null; state.modeBeforeBee = null;
  state.stack = [];
  state.view = "chat";
  state.trail = null;
  state.drill = null;
  syncConversationUrl();
  emit();
}

// ── 左侧模式：蜂群 ↔ 某只 Bee 的对话列表 ──

export async function enterBeeMode(beeId) {
  const m = memberById(beeId);
  if (state.mode !== 'bee') state.modeBeforeBee = { view: state.view, stack: state.stack.slice() };
  state.trail = null;
  state.drill = null;
  state.conversationId = null;
  state.mode = "bee";
  state.beeModeId = beeId;
  state.view = "dm";
  state.stack = [{ type: "dm", beeId, display: m ? m.display : beeId }];
  syncConversationUrl();
  await refresh();
  if (state.mode !== 'bee' || state.beeModeId !== beeId || state.view !== 'dm') return;
  emit();
}

export async function exitBeeMode() {
  state.mode = "colony";
  state.beeModeId = null;
  state.conversationId = null;
  const prev = state.modeBeforeBee || { view: "chat", stack: [] };
  state.stack = prev.stack || [];
  state.view = prev.view === "conversation" ? "chat" : prev.view;
  state.modeBeforeBee = null;
  syncConversationUrl();
  await refresh();
  emit();
}

export async function openConversation(sessionId, beeId) {
  state.mode = "bee";
  state.beeModeId = beeId;
  state.conversationId = sessionId;
  state.view = "conversation";
  syncConversationUrl();
  void refresh();
  emit();
}

export async function openBeeTrail(beeId) {
  const m = memberById(beeId);
  state.mode = "bee";
  state.beeModeId = beeId;
  state.conversationId = null;
  state.view = "dm";
  state.stack = [{ type: "dm", beeId, display: m ? m.display : beeId }];
  syncConversationUrl();
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


