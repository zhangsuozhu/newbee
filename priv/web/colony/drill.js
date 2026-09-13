// 蜂群前端 · 任务深钻：任务头卡（.msg-tool）+ 子任务列表 + 工作轨迹（同款卡片）
import { esc, fmtTime, statusLabel } from "./util.js";
import { state, memberById, refresh } from "./store.js";
import { rpc, toast } from "./api.js";
import { traceNode } from "./chat.js";
import { buildTaskCard, statusChip } from './taskcard.js';

export function renderDrillView(flow, ctx) {
  const drill = state.drill;
  if (!drill || !drill.task) {
    flow.appendChild(note("正在加载任务…"));
    return;
  }
  const task = drill.task;
  flow.appendChild(buildTaskCard(task, ctx, { drill: false }));

  const children = (drill.tasks || []).filter((t) => t.parent_task_id === task.id);
  if (children.length) {
    const box = document.createElement("div");
    box.className = "drill-children";
    for (const child of children) box.appendChild(childRow(child, ctx));
    flow.appendChild(box);
  }

  const entries = dedupe([
    ...(drill.trace || []),
    ...(drill.children_trace || []),
  ]);
  if (!entries.length) {
    flow.appendChild(note("这条任务还没有工作记录；在下面输入即向当前执行者下达指令。"));
    return;
  }
  for (const t of entries) flow.appendChild(traceNode(t, ctx));
}

function childRow(child, ctx) {
  const row = document.createElement("div");
  row.className = "drill-child";
  row.innerHTML =
    `<span class="child-title">${esc(child.title)}</span>` +
    `<span class="chip-mini ${statusChip(child.status)}">${esc(statusLabel(child.status))}</span>` +
    `<span class="child-caret">›</span>`;
  row.onclick = () => ctx.openTask(child.id, child.title);
  return row;
}


function dedupe(list) {
  const seen = new Set();
  return list
    .filter((t) => {
      if (t == null || seen.has(t.seq)) return false;
      seen.add(t.seq);
      return true;
    })
    .sort((a, b) => (a.seq || 0) - (b.seq || 0));
}

function note(text) {
  const node = document.createElement("div");
  node.className = "msg msg-assistant";
  node.style.color = "var(--nb-label-caption)";
  node.textContent = text;
  return node;
}

