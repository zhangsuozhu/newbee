// 蜂群前端 · 左侧列表：蜂群（会话组样式）+ 成员（会话项样式），完全复用主界面组件类
import { esc, statusLabel, kindLabel } from "./util.js";
import { state, currentBeeId, refresh, openBeeTrail } from "./store.js";
import { form } from './forms.js';
import { rpc, toast } from './api.js';
import {renameColony, dissolveColony} from './manage.js';

export function renderSidebar(root, ctx) {
  root.innerHTML = "";
  // Bee 模式：左侧换成「和这只 Bee 的对话列表」（返回键回到蜂群）
  if (state.mode === "bee" && state.beeModeId) {
    renderBeeConversations(root, ctx);
    return;
  }
  const kw = (state.filter || "").trim().toLowerCase();

  const activeMembers = (state.data && state.data.members) || [];
  const items = (state.colonies || []).filter((item) => {
    if (!kw) return true;
    const c = item.colony || {};
    const inName = String(c.name || "").toLowerCase().includes(kw) || String(c.goal || "").toLowerCase().includes(kw);
    const inMembers = c.id === state.colonyId && activeMembers.some((m) => String(m.display || "").toLowerCase().includes(kw));
    return inName || inMembers;
  });

  if (!items.length) {
    const empty = document.createElement("div");
    empty.className = "session-empty";
    empty.textContent = state.colonies.length ? "没有匹配的蜂群" : "还没有蜂群，点右上角 + 建一个";
    root.appendChild(empty);
    return;
  }

  for (const item of items) root.appendChild(colonyGroup(item, ctx));
}

// ── Bee 模式：这只 Bee 的对话列表（点对话 = 打开真实 newbee 会话）──
function renderBeeConversations(root, ctx) {
  const bee = beeOf(state.beeModeId) || (state.trail && state.trail.bee) || {};
  const isAi = bee.kind === "ai";

  const head = document.createElement("div");
  head.className = "bee-mode-head";
  head.innerHTML = `
    <button class="btn-ghost bee-back" id="beeBack" title="返回蜂群">‹ 返回</button>
    <span class="bee-mode-name" title="${esc(bee.display || "")}">${esc(bee.display || "Bee")}</span>
    <span class="session-role">${esc(kindLabel(bee.kind))}</span>`;
  head.querySelector("#beeBack").onclick = () => ctx.exitBeeMode();
  root.appendChild(head);

  const tools = document.createElement("div");
  tools.className = "bee-mode-tools";
  const newBtn = document.createElement("button");
  newBtn.className = "btn-ghost";
  newBtn.textContent = "＋ 新建对话";
  newBtn.title = isAi ? "开一条新会话（真实 newbee 会话）" : "真人成员的对话由对方创建";
  newBtn.disabled = !isAi;
  newBtn.onclick = () => ctx.newConversation(bee.id);
  tools.appendChild(newBtn);

  root.appendChild(tools);

  const convs = (state.trail && state.trail.conversations) || [];
  if (!convs.length) {
    const empty = document.createElement("div");
    empty.className = "session-empty";
    empty.textContent = isAi ? "还没有对话，点上面「＋ 新建对话」开始" : "真人成员还没有绑定会话";
    root.appendChild(empty);
    return;
  }

  for (const c of convs) {
    const cell = document.createElement("div");
    cell.className = "swipe-cell session-child";
    const item = document.createElement("div");
    const active = state.view === "conversation" && state.conversationId === c.id;
    item.className = "session-item" + (active ? " active" : "");
    item.dataset.conversation = c.id;
    // 真人对话是消息线程（没有会话），不能当会话打开、也没有改名/删除。
    const isSession = c.kind !== "human";
    const dot = c.busy ? "busy" : c.running ? "online" : "offline";
    item.innerHTML = `
      <span class="t"><span class="sess-dot ${dot}"></span>${esc(c.title || "新对话")}${c.current ? '<span class="session-role">当前</span>' : ""}</span>
      <span class="meta">${esc(`${c.messages || 0} 条${c.when ? " · " + c.when : ""}`)}</span>`;
    item.onclick = () => {
      if (cell.dataset.swipeOpen === "1") { closeSwipe(cell); return; }
      if (isSession) ctx.openConversation(c.id, bee.id);
      else ctx.openDM(bee.id);
    };
    cell.appendChild(item);

    if (isSession) {
      const more = document.createElement("button");
      more.className = "menu-btn";
      more.textContent = "⋯";
      more.title = "更多操作（改名 / 删除）";
      more.onclick = (event) => { event.stopPropagation(); conversationMenu(bee, c); };
      item.append(more);

       // 手机端左滑提供改名与删除，和主界面保持一致。
       const actions = document.createElement("div");
       actions.className = "swipe-actions";
       const rename = document.createElement("button");
       rename.className = "swipe-action swipe-rename";
       rename.type = "button";
       rename.textContent = "改名";
       rename.title = "改名该对话";
       rename.setAttribute("aria-label", "改名该对话");
       rename.onclick = (event) => { event.stopPropagation(); closeSwipe(cell); renameConversation(bee, c); };
       const del = document.createElement("button");
       del.className = "swipe-action swipe-delete";
       del.type = "button";
       del.textContent = "删除";
       del.title = "删除该对话";
       del.setAttribute("aria-label", "删除该对话");
       del.onclick = (event) => { event.stopPropagation(); closeSwipe(cell); deleteConversation(bee, c); };
       actions.append(rename, del);
       cell.appendChild(actions);
       attachSwipe(cell, item);
     }


    root.appendChild(cell);
  }
}

function beeOf(id) {
  return ((state.data && state.data.members) || []).find((m) => m.id === id) || null;
}
function colonyGroup(item, ctx) {
  const colony = item.colony || {};
  const stats = item.stats || {};
  const active = colony.id === state.colonyId;
  const members = active ? ((state.data && state.data.members) || []) : [];
  const collapsed = active ? !!state.collapsed[colony.id] : true;

  const wrap = document.createElement("div");
  wrap.className = "session-group" + (collapsed ? " collapsed" : "");
  wrap.dataset.groupId = colony.id;

  const busy = stats.working || 0;
  const canManage = active && !!state.data?.can_manage;
  const header = document.createElement("div");
  header.className = "session-group-header" + (active ? " current" : "");
  header.innerHTML = `
    <button class="session-group-toggle" title="${collapsed ? "展开" : "收起"}">${collapsed ? "▸" : "▾"}</button>
    <span class="session-group-title" title="${esc(colony.goal || colony.name || "")}">${esc(colony.name || "蜂群")}</span>
    <span class="session-group-spacer"></span>
    ${busy ? `<span class="session-group-busy">● ${busy} 运行中</span>` : ""}
    ${active ? '<span class="group-current-badge">当前</span>' : ""}
    ${canManage ? '<button class="session-group-menu-btn" type="button" title="群操作" aria-label="群操作">⋯</button>' : ""}
    <span class="session-group-count">${stats.members || members.length || 0} 成员</span>`;
  if (canManage) {
    header.querySelector(".session-group-menu-btn").onclick = async (event) => {
      event.stopPropagation();
      const choice = await pick("群操作", [
        {value: "rename", label: "改名蜂群"},
        {value: "dissolve", label: "解散蜂群", danger: true}
      ], colony.name || "蜂群");
      if (choice === "rename") await renameColony();
      if (choice === "dissolve") await dissolveColony();
    };
  }

  header.onclick = () => {
    setCollapsed(colony.id, !collapsed);
    if (!active) ctx.switchColony(colony.id);
    else ctx.render(true);
  };
  wrap.appendChild(header);

  if (!collapsed) {
    const body = document.createElement("div");
    body.className = "session-group-body";
    body.appendChild(groupChatItem(colony, members, ctx));
    if (!members.length) {
      const loading = document.createElement("div");
      loading.className = "session-empty";
      loading.textContent = "加载成员…";
      body.appendChild(loading);
    }
    for (const m of members) body.appendChild(beeItem(m, colony.id, ctx));
    wrap.appendChild(body);
  }
  return wrap;
}

// ── 私有对话：左滑删除 + ⋯ 菜单（改名 / 删除），与主界面同一套交互 ──
let openSwipeCell = null;
function closeSwipe(cell) {
  if (!cell) return;
  const item = cell.querySelector(":scope > .session-item");
  if (item) item.style.transform = "";
  delete cell.dataset.swipeOpen;
  delete cell.dataset.swipeActive;
  if (openSwipeCell === cell) openSwipeCell = null;
}
function closeAllSwipes(except) {
  document.querySelectorAll('.swipe-cell[data-swipe-open="1"], .swipe-cell[data-swipe-active="1"]').forEach((cell) => {
    if (cell !== except) closeSwipe(cell);
  });
}
function attachSwipe(cell, item) {
  const width = () => {
    const actions = cell.querySelector(":scope > .swipe-actions");
    return (actions && actions.offsetWidth) || 132;
  };
  const settle = (fromRight) => {
    if (fromRight < -width() * 0.4) {
      closeAllSwipes(cell);
      item.style.transform = "translateX(" + (-width()) + "px)";
      cell.dataset.swipeOpen = "1";
      openSwipeCell = cell;
    } else {
      closeSwipe(cell);
    }
  };
  let startX = 0, startY = 0, base = 0, dragging = false, horizontal = null;
  const begin = (x, y) => {
    closeAllSwipes(cell);
    startX = x; startY = y;
    base = cell.dataset.swipeOpen === "1" ? -width() : 0;
    dragging = true; horizontal = null;
    item.style.transition = "none";
  };
  const move = (x, y) => {
    if (!dragging) return;
    const dx = x - startX, dy = y - startY;
    if (horizontal === null) {
      if (Math.abs(dx) < 8 && Math.abs(dy) < 8) return;
      horizontal = Math.abs(dx) > Math.abs(dy);
      if (!horizontal) { dragging = false; item.style.transition = ""; return; }
    }
    cell.dataset.swipeActive = "1";
    const limit = width();
    const next = Math.max(-limit, Math.min(0, base + dx));
    item.style.transform = next ? "translateX(" + next + "px)" : "";
    if (Math.abs(dx) > 10) item.dataset.dragged = "1";
  };
  const end = (x) => {
    if (!dragging) { if (item.dataset.dragged) delete item.dataset.dragged; return; }
    dragging = false;
    item.style.transition = "";
    delete cell.dataset.swipeActive;
    settle(base + (x - startX));
    setTimeout(() => { if (cell.dataset.swipeOpen !== "1") delete item.dataset.dragged; }, 60);
  };
  item.addEventListener("touchstart", (event) => { const t = event.touches[0]; begin(t.clientX, t.clientY); }, {passive: true});
  item.addEventListener("touchmove", (event) => { const t = event.touches[0]; move(t.clientX, t.clientY); }, {passive: true});
  item.addEventListener("touchend", (event) => { const t = (event.changedTouches && event.changedTouches[0]) || null; end(t ? t.clientX : startX); });
  item.addEventListener("touchcancel", () => {
    dragging = false;
    item.style.transition = "";
    delete cell.dataset.swipeActive;
    if (cell.dataset.swipeOpen === "1") item.style.transform = "translateX(" + (-width()) + "px)";
    else closeSwipe(cell);
  });
  // 桌面端：按住左键横向拖拽；只在拖拽期间挂全局监听，松手即摘。
  item.addEventListener("mousedown", (event) => {
    if (event.button !== 0 || event.target.closest(".menu-btn") || event.target.closest(".member-control")) return;
    begin(event.clientX, event.clientY);
    const onMove = (moveEvent) => move(moveEvent.clientX, moveEvent.clientY);
    const onUp = (upEvent) => {
      window.removeEventListener("mousemove", onMove);
      window.removeEventListener("mouseup", onUp);
      end(upEvent.clientX);
    };
    window.addEventListener("mousemove", onMove);
    window.addEventListener("mouseup", onUp);
  });
}
function pick(title, actions, target = "") {
  return new Promise((resolve) => {
    const dialog = document.createElement("dialog");
    dialog.className = "colony-dialog";
    const node = document.createElement("div");
    const heading = document.createElement("h3");
    heading.textContent = title;
    node.append(heading);
    if (target) {
      const context = document.createElement("p");
      context.className = "dialog-target";
      context.textContent = "对话：" + target;
      node.append(context);
    }
    const row = document.createElement("div");
    row.className = "colony-dialog-actions";
    const cancel = document.createElement("button");
    cancel.type = "button";
    cancel.className = "btn-ghost";
    cancel.textContent = "取消";
    cancel.onclick = () => dialog.close("");
    row.append(cancel);
    for (const action of actions) {
      const button = document.createElement("button");
      button.type = "button";
      button.className = action.danger ? "btn-deny" : "btn-ghost";
      button.textContent = action.label;
      button.onclick = () => dialog.close(action.value);
      row.append(button);
    }
    node.append(row);
    dialog.append(node);
    document.body.append(dialog);
    dialog.onclose = () => { const value = dialog.returnValue; dialog.remove(); resolve(value === "" || value === undefined ? null : value); };
    dialog.showModal();
  });
}

function confirmAction(title, text, confirmLabel) {
  return new Promise((resolve) => {
    const dialog = document.createElement("dialog");
    dialog.className = "colony-dialog";
    const node = document.createElement("div");
    const heading = document.createElement("h3");
    heading.textContent = title;
    const body = document.createElement("p");
    body.textContent = text;
    const actions = document.createElement("div");
    actions.className = "colony-dialog-actions";
    const cancel = document.createElement("button");
    cancel.type = "button";
    cancel.className = "btn-ghost";
    cancel.textContent = "取消";
    cancel.onclick = () => dialog.close("cancel");
    const ok = document.createElement("button");
    ok.type = "button";
    ok.className = "btn-deny";
    ok.textContent = confirmLabel;
    ok.onclick = () => dialog.close("confirm");
    actions.append(cancel, ok);
    node.append(heading, body, actions);
    dialog.append(node);
    document.body.append(dialog);
    dialog.onclose = () => { const value = dialog.returnValue; dialog.remove(); resolve(value === "confirm"); };
    dialog.showModal();
  });
}
async function conversationMenu(bee, conversation) {
  const target = conversation.title || "新对话";
  const choice = await pick("对话操作", [
    {value: "rename", label: "改名"},
    {value: "delete", label: "删除", danger: true}
  ], target);
  if (choice === "rename") return renameConversation(bee, conversation);
  if (choice === "delete") return deleteConversation(bee, conversation);
}

async function renameConversation(bee, conversation) {
  const value = await form("给对话改名", [{name: "title", label: "名称", value: conversation.title || "", required: true, placeholder: "例如：登录模块重构"}], "保存");
  if (!value || !value.title) return;
  try {
    await rpc("colony.bee.conversation.rename", {colonyId: state.colonyId, beeId: bee.id, sessionId: conversation.id, title: value.title});
    toast("已改名");
  } catch (error) {
    toast(error.message || "改名失败", true);
  }
  await refresh();
}
async function deleteConversation(bee, conversation) {
  const confirmed = await confirmAction("删除对话", `删除「${conversation.title || "新对话"}」？这条对话的内容会一并删除，无法恢复。`, "删除");
  if (!confirmed) return;
  try {
    await rpc("colony.bee.conversation.delete", {colonyId: state.colonyId, beeId: bee.id, sessionId: conversation.id});
    toast("已删除");
  } catch (error) {
    toast(error.message || "删除失败", true);
    return;
  }
  if (state.conversationId === conversation.id) await openBeeTrail(bee.id);
  else await refresh();
}

// 群聊：所有成员（人 / AI）的公共对话——与会话项同款，排在一对一之上
function groupChatItem(colony, members, ctx) {
  const cell = document.createElement("div");
  cell.className = "swipe-cell session-child";

  const item = document.createElement("div");
  const here = state.colonyId === colony.id && state.view === "chat";
  item.className = "session-item" + (here ? " active" : "");
  item.dataset.groupChat = colony.id;

  const anyWorking = members.some((m) => m.status === "working");
  const latest = latestColonyLine();
  item.innerHTML = `
    <span class="t"><span class="sess-dot ${anyWorking ? "busy" : "online"}"></span>群聊<span class="session-role">所有人</span></span>
    <span class="meta">${esc(`${members.length} 成员${anyWorking ? " · 有人正在干活" : ""}${latest ? " · " + latest : ""}`)}</span>`;

  item.onclick = () => ctx.openGroupChat();
  cell.appendChild(item);
  return cell;
}

function latestColonyLine() {
  const trace = (state.data && state.data.trace) || [];
  for (let i = trace.length - 1; i >= 0; i--) {
    const t = trace[i];
    if (t.channel !== "colony" || t.type !== "message") continue;
    const m = t.bee_id ? memberByIdLocal(t.bee_id) : null;
    const who = t.data && t.data.from === "colony" ? "Colony" : m ? m.display : "";
    const text = String(t.text || "").replace(/\\s+/g, " ").trim();
    if (!text) continue;
    return (who ? who + "：" : "") + text.slice(0, 18);
  }
  return "";
}

function memberByIdLocal(id) {
  return ((state.data && state.data.members) || []).find((m) => m.id === id) || null;
}

function beeItem(m, colonyId, ctx) {
  const cell = document.createElement("div");
  cell.className = "swipe-cell session-child";

  const item = document.createElement("div");
  const here = state.colonyId === colonyId && state.view === "dm" && currentBeeId() === m.id;
  item.className = "session-item" + (here ? " active" : "");
  item.dataset.sid = m.id;
  // 自己和自己对话没有意义：本人那一项不进入对话，也不提供新建对话。
  const isMe = !!(state.data && state.data.actor_bee_id === m.id);
  item.innerHTML = `
    <span class="t"><span class="sess-dot ${dotClass(m)}"></span>${esc(m.display)}<span class="session-role">${esc(kindLabel(m.kind))}</span></span>
    <span class="meta">${esc(isMe ? '你自己 · 不需要和自己对话' : metaLine(m))}</span>`;

  if (isMe) {
    item.classList.add('session-self');
    item.title = '这是你自己';
  } else {
    item.onclick = () => ctx.enterBeeMode(m.id);
    item.tabIndex = 0; item.setAttribute('role', 'button');
    item.onkeydown = (event) => {if (event.target === item && ['Enter',' '].includes(event.key)) {event.preventDefault(); ctx.enterBeeMode(m.id);}};
  }
  if (m.kind === 'ai' && state.data?.can_manage) {
    const control = document.createElement('button'); control.className = 'member-control';
    const paused = m.control_state !== 'running';
    control.textContent = paused ? '继续' : '暂停';
    control.title = m.control_state === 'pausing' ? '正在暂停，等待执行确认' : `${control.textContent}${m.display}在当前群的执行`;
    control.setAttribute('aria-label', control.title);
    control.onclick = async (event) => {event.stopPropagation(); control.disabled = true; try {await rpc('colony.control', {colonyId, scope:'bee', targetId:m.id, action:paused ? 'resume' : 'pause'}); await refresh();} catch (error) {toast(error.message, true);} finally {control.disabled = false;}};
    item.append(control);
  }

  if (!isMe) {
    const more = document.createElement("button");
    more.className = "menu-btn";
    more.textContent = "›";
    more.title = "深钻它的任务";
    more.onclick = (e) => {
      e.stopPropagation();
      ctx.drillBee(m);
    };
    item.appendChild(more);
  }
  cell.appendChild(item);
  return cell;
}

function dotClass(m) {
  if (m.kind !== 'human' && m.control_state === 'paused') return 'offline';
  if (m.kind !== 'human' && m.control_state === 'pausing') return 'busy';
  if (m.status === "working") return "busy";
  if (m.status === "offline") return "offline";
  return "online";
}

function metaLine(m) {
  const bits = [];
  if (m.kind !== 'human' && m.control_state === 'paused') bits.push('已暂停');
  if (m.kind !== 'human' && m.control_state === 'pausing') bits.push('暂停中 · 等待确认');
  const doing = m.status === "working" ? currentTaskTitle(m.id) : "";
  if (doing) bits.push(`在干：${doing}`);
  else if (m.active_tasks) bits.push(`${m.active_tasks} 个任务在手`);
  else bits.push(statusLabel(m.status));
  if (m.remote) bits.push('远端环境');
  else if (m.kind === 'human') bits.push('真人成员');
  return bits.join(" · ");
}

function currentTaskTitle(beeId) {
  const tasks = (state.data && state.data.tasks) || [];
  const t = tasks.find((x) => x.assigned_bee_id === beeId && x.status === 'running');
  return t ? String(t.title || "").slice(0, 16) : "";
}

export function setCollapsed(colonyId, val) {
  state.collapsed[colonyId] = val;
}
