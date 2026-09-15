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
    const inConversation = state.view === "conversation";
    // 成员层级里也可能深钻任务（历史任务 / 侧栏「›」）：那已经是第三层，
    // 标题必须显示任务名，否则用户看不出自己点进了哪里。
    const inDrill = state.view === "drill";
    const drillTitle = (state.drill && state.drill.task && state.drill.task.title) || "任务";
    title.textContent = inDrill ? drillTitle : (bee.display || "Bee");
    if (!sub) return;
    sub.appendChild(crumb("蜂群", false, () => exitBeeMode()));
    sub.appendChild(sep());
    sub.appendChild(crumb(bee.display || "Bee", !inConversation && !inDrill, () => openBeeTrail(bee.id)));
    if (inConversation) {
      sub.appendChild(sep());
      sub.appendChild(crumb(conversationTitle(state.conversationId), true, () => {}));
    } else if (inDrill) {
      sub.appendChild(sep());
      sub.appendChild(crumb(drillTitle, true, () => {}));
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
