// 蜂群前端 · 任务深钻：任务头卡（.msg-tool）+ 子任务列表 + 工作轨迹（同款卡片）
import { esc, fmtTime, statusLabel } from "./util.js";
import { state, memberById, refresh } from "./store.js";
import { rpc, toast } from "./api.js";
import { traceNode, honeyNode } from "./chat.js";
import { buildTaskCard, statusChip } from './taskcard.js';

export function renderDrillView(flow, ctx) {
  const drill = state.drill;
  if (!drill || !drill.task) {
    flow.appendChild(note("正在加载任务…"));
    return;
  }
  const task = drill.task;
  flow.appendChild(buildTaskCard(task, ctx, { drill: false }));

  // 成果：任务详情此前只渲染 Trace，而人的提交（colony.work.submit）不一定留下
  // 任务级 Trace，于是「已提交、待验收」的任务在详情里显示「还没有工作记录」。
  // 服务端 drill 现在直接给出该子树的成果；老接口缺这个字段时退回本群视图的 recent。
  const honeys = ((drill.honey || []).length
    ? drill.honey
    : (((state.data || {}).honey || {}).recent || [])
  ).filter((h) => h.task_id === task.id);
  const children = (drill.tasks || []).filter((t) => t.parent_task_id === task.id);
  if (children.length) {
    const box = document.createElement("div");
    box.className = "drill-children";
    for (const child of children) box.appendChild(childRow(child, ctx));
    flow.appendChild(box);
  }

  const taskEventId = (t) => t.task_id || t.data?.task_id || t.data?.taskId;
  // 轨迹里的任务事件会被 traceNode 渲染成「该任务的当前卡片」（不是当时的状态），
  // 所以：① 被深钻任务自己的事件由上面那张头卡承载，不再重复；
  //       ② 其余任务每个最多渲染一张，避免同一张卡出现两三次。
  const seenTaskCards = new Set();
  const entries = dedupe([
    ...(drill.trace || []),
    ...(drill.children_trace || []),
  ]).filter((t) => {
    if (t.type !== "task") return true;
    const id = taskEventId(t);
    if (!id || id === task.id) return false;
    if (seenTaskCards.has(id)) return false;
    seenTaskCards.add(id);
    return true;
  });
  // 轨迹里若已经带了这些成果事件（AI 提交路径会写 Trace），就别再画一遍。
  const tracedHoneyIds = new Set(entries.map((e) => e.data && e.data.honey_id).filter(Boolean));
  for (const h of honeys) {
    if (tracedHoneyIds.has(h.id)) continue;
    flow.appendChild(honeyNode({ type: 'honey', text: h.title, ts: h.created_at, data: { honey_id: h.id } }, ctx));
  }

  if (!entries.length) {
    // 轨迹为空时别急着说「没有工作记录」：可能成果已经提交（上面已渲染成果卡），
    // 只是没有任务级 Trace，这时给一句更准确的话。
    flow.appendChild(note(honeys.length
      ? "这条任务的执行过程没有留下轨迹记录；成果见上方成果卡，可直接验收。"
      : "这条任务还没有工作记录；在下面输入即向当前执行者下达指令。"));
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

