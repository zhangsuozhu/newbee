// 蜂群前端 · 顶部标题与面包屑（主界面 topbar 的标题行 + 一行小字）
import { esc } from "./util.js";
import { state, gotoLevel, resetToChat, memberById, exitBeeMode, openBeeTrail } from "./store.js";

export function renderBreadcrumbs() {
  const title = document.getElementById("session-title");
  const sub = document.getElementById("session-sub");
  if (!title) return;
  // sub 缺失时仍然更新标题：容器是可选装饰，标题是必要信息。
  if (sub) sub.innerHTML = "";
  if (state.mode === "bee" && state.beeModeId) {
    const bee = memberById(state.beeModeId) || (state.trail && state.trail.bee) || {};
    const stack = state.stack || [];
    // 成员层级里也会嵌套深钻（父任务 → 子任务）：栈里每一层都要给出来，
    // 否则从子任务回不到父任务，只能绕回成员层级再找一遍。
    const drills = [];
    stack.forEach((entry, index) => { if (entry.type === "drill") drills.push({ entry, index }); });
    const inConversation = state.view === "conversation";
    const topDrill = drills[drills.length - 1];
    title.textContent = topDrill ? (topDrill.entry.title || "任务") : (bee.display || "Bee");
    if (!sub) return;
    sub.appendChild(crumb("蜂群", false, () => exitBeeMode()));
    sub.appendChild(sep());
    sub.appendChild(crumb(bee.display || "Bee", !inConversation && drills.length === 0, () => openBeeTrail(bee.id)));
    if (inConversation) {
      sub.appendChild(sep());
      sub.appendChild(crumb(conversationTitle(state.conversationId), true, () => {}));
    } else {
      drills.forEach((d, i) => {
        sub.appendChild(sep());
        const last = i === drills.length - 1;
        sub.appendChild(crumb(d.entry.title || "任务", last, last ? () => {} : () => gotoLevel(d.index)));
      });
    }
    return;
  }

  const stack = state.stack || [];
  const top = stack[stack.length - 1];
  title.textContent = top ? (top.type === "dm" ? (top.display || "Bee") : (top.title || "任务")) : "群聊";

  if (!sub) return;
  sub.appendChild(crumb("群聊", stack.length === 0, () => resetToChat()));
  stack.forEach((entry, i) => {
    sub.appendChild(sep());
    const isLast = i === stack.length - 1;
    sub.appendChild(crumb(label(entry), isLast, () => gotoLevel(i)));
  });
}

function conversationTitle(id) {
  const list = (state.trail && state.trail.conversations) || [];
  const c = list.find((x) => x.id === id);
  return (c && c.title) || "对话";
}

function sep() {
  const s = document.createElement("span");
  s.className = "crumb-sep";
  s.textContent = "›";
  return s;
}

function crumb(text, active, onClick) {
  const b = document.createElement("button");
  b.className = "crumb-link" + (active ? " active" : "");
  b.textContent = text;
  b.onclick = onClick;
  return b;
}

function label(entry) {
  if (entry.type === "dm") return entry.display || "Bee";
  if (entry.type === "drill") return entry.title || "任务";
  return entry.type;
}
