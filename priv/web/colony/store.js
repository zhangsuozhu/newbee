// 蜂群前端 · 状态中心（订阅 + 轮询）
import { rpc } from "./api.js";

const listeners = new Set();

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
};

export function subscribe(fn) {
  listeners.add(fn);
  return () => listeners.delete(fn);
}

export function emit() {
  for (const fn of listeners) {
    try { fn(state); } catch (e) { console.error("[colony] listener failed", e); }
  }
}

export async function loadColonies() {
  const res = await rpc("colony.list");
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
  emit();
  await refresh();
}

export async function refresh() {
  if (!state.colonyId) return;
  const colonyId = state.colonyId;
  const route = JSON.stringify([colonyId, state.view, state.beeModeId, state.stack]);
  const current = () => route === JSON.stringify([state.colonyId, state.view, state.beeModeId, state.stack]);
  try {
    const view = await rpc("colony.view", { colonyId });
    if (!current()) return;
    state.data = view;
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
    state.lastError = e.message || String(e);
    console.error("[colony] refresh failed", e);
  }
  emit();
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
  void refresh();
  emit();
}

export function resetToChat() {
  state.mode = 'colony'; state.beeModeId = null; state.conversationId = null; state.modeBeforeBee = null;
  state.stack = [];
  state.view = "chat";
  state.trail = null;
  state.drill = null;
  emit();
}

// ── 左侧模式：蜂群 ↔ 某只 Bee 的对话列表 ──

export async function enterBeeMode(beeId) {
  const m = memberById(beeId);
  state.modeBeforeBee = { view: state.view, stack: state.stack.slice() };
  state.mode = "bee";
  state.beeModeId = beeId;
  state.view = "dm";
  state.stack = [{ type: "dm", beeId, display: m ? m.display : beeId }];
  await refresh();
  if (state.mode !== 'bee' || state.beeModeId !== beeId || state.view !== 'dm') return;
  const first = (state.trail && state.trail.conversations) || [];
  if (m?.kind === 'human') {emit(); return;}
  if (first.length) {
    await openConversation(first[0].id, beeId);
  } else {
    emit();
  }
}

export async function exitBeeMode() {
  state.mode = "colony";
  state.beeModeId = null;
  state.conversationId = null;
  const prev = state.modeBeforeBee || { view: "chat", stack: [] };
  state.stack = prev.stack || [];
  state.view = prev.view === "conversation" ? "chat" : prev.view;
  state.modeBeforeBee = null;
  await refresh();
  emit();
}

export async function openConversation(sessionId, beeId) {
  state.mode = "bee";
  state.beeModeId = beeId;
  state.conversationId = sessionId;
  state.view = "conversation";
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


