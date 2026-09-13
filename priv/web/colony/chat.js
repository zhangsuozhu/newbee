// 蜂群前端 · 消息流：全部使用主界面的 .msg 组件（msg-user / msg-assistant / msg-tool）
// 不再自创气泡样式；群聊、一对一、深钻共用同一套卡片。
import { renderWorkBoard } from './workflow.js';
import { esc, fmtAgo, fmtTime, kindLabel, signalLabel, statusLabel } from "./util.js";
import { buildTaskCard, isTerminal, statusChip } from "./taskcard.js";
import { state, memberById } from "./store.js";
import { rpc, toast } from "./api.js";
import { refresh } from "./store.js";
import { form } from './forms.js';
import { renderMarkdown } from "./md.js";

// 卡片标题去掉指令前缀，避免用户原话在标题和正文之间重复占屏。
function shortTitle(text, max = 34) {
  const s = String(text || '').replace(/^\s*(请?帮我|帮忙)?(完成|做|处理)[:：]?\s*/, '').trim();
  return s.length > max ? s.slice(0, max) + '…' : s;
}


export function renderGroupView(flow, ctx) {
  const data = state.data || {};
  renderWorkBoard(flow, ctx);
  const hiddenTasks = new Set((data.tasks || []).filter(t => t.workflow || t.workflow_root).map(t => t.id));
  const internalResults = new Set((data.tasks || []).filter(t => t.integration_required).map(t => t.result));
  const trace = (data.trace || []).filter(t => t.channel === 'colony' && !['tool_call','tool','refresh','capabilities'].includes(t.type) && !(t.type === 'task' && hiddenTasks.has(t.task_id || t.data?.task_id)) && !(t.type === 'honey' && internalResults.has(t.data?.honey_id)));
  if (!trace.length) {
    flow.appendChild(emptyNote("还没有公开消息。在下面输入一句话，Bee 们都会看到。"));
    return;
  }
  // 群里最多的噪音是机械进度行（「工具已返回，处理中」）。它们没有额外信息，
  // 收成一行「工具执行 N 次」，点开看时间；其余事件照旧。
  let prevSender = null;
  let noise = [];
  const flushNoise = () => {
    if (!noise.length) return;
    const node = noiseNode(noise);
    if (noise.length) flow.appendChild(node);
    noise = [];
  };
  for (const group of groupTrace(trace)) {
    if (isNoise(group.first)) { noise.push(...group.items); continue; }
    flushNoise();
    const node = traceNode(group.first, ctx);
    const key = senderKey(group.first);
    if (key && key === prevSender) node.classList.add("cont");
    if (group.items.length > 1) annotateRepeat(node, group);
    flow.appendChild(node);
    prevSender = key;
  }
  flushNoise();
  const displayedHoney = new Set(trace.filter(t => t.type === 'honey').map(t => t.data?.honey_id));
  for (const honey of data.honey?.recent || []) {
    if (!internalResults.has(honey.id) && !displayedHoney.has(honey.id)) flow.appendChild(honeyNode({type:'honey', text:honey.title, ts:honey.created_at, data:{honey_id:honey.id}}, ctx));
  }
}

// 机械进度行：无附带数据、文本是执行器的心跳。
function isNoise(t) {
  if (t.data && Object.keys(t.data).length) return false;
  return /^工具已返回[，,]?\s*处理中$/.test((t.text || "").trim());
}

function noiseNode(items) {
  const node = document.createElement("div");
  node.className = "msg msg-tool noise-row";
  const head = document.createElement("div");
  head.className = "tool-head";
  head.innerHTML =
    `<span class="kind-dot" aria-hidden="true"></span>` +
    `<span class="card-kind">执行</span>` +
    `<span class="diffstat">工具执行 ${items.length} 次</span>` +
    `<span class="tool-dur">${esc(fmtAgo(items[items.length - 1].ts))}</span>`;
  node.appendChild(head);
  const list = document.createElement("div");
  list.className = "tool-result repeat-list";
  list.hidden = true;
  list.textContent = items.map((t) => `· ${absTime(t.ts)}`).join("\n");
  node.appendChild(list);
  head.onclick = () => { list.hidden = !list.hidden; };
  return node;
}

function senderKey(t) {
  if (t.type !== "message") return null;
  if (t.data && t.data.from === "colony") return "colony";
  return t.bee_id || "unknown";
}

// 聚合键：同类型 + 同文本（消息按发送者；决定按问题文本，同一个问题只出现一次）。
function groupKey(t) {
  if (t.type === "honey" || t.type === "task") return null; // 工作与成果各自成卡
  if (t.type === "message") return "message|" + (t.bee_id || "") + "|" + (t.text || "").trim();
  if (t.type === "decision") return "decision|" + (t.text || "").trim();
  return [t.type, (t.data && t.data.kind) || "", (t.text || "").trim()].join("|");
}
// 这些类型的事件重复出现时合并成一个 ×N（控制确认、生命周期、系统提示、心跳）。
const COLLAPSIBLE = new Set(["control", "lifecycle", "system", "tool_call", "tool", "refresh", "switch", "capabilities", "decision"]);

function groupTrace(trace) {
  const out = [];
  const byKey = new Map();
  for (const t of trace) {
    const key = groupKey(t);
    if (key && COLLAPSIBLE.has(t.type)) {
      const seen = byKey.get(key);
      if (seen) { seen.items.push(t); continue; }
    }
    const last = out[out.length - 1];

    if (key && last && last.key === key) { last.items.push(t); continue; }
    const group = { key, first: t, items: [t] };
    out.push(group);
    if (key && COLLAPSIBLE.has(t.type)) byKey.set(key, group);
  }
  return out;
}

function annotateRepeat(node, group) {
  const head = node.querySelector(".tool-head") || node;
  const badge = document.createElement("span");
  badge.className = "chip-mini repeat-chip";
  badge.textContent = "×" + group.items.length;
  const first = group.items[0], last = group.items[group.items.length - 1];
  badge.title = `${fmtAgo(first.ts)} — ${fmtAgo(last.ts)}，共 ${group.items.length} 次`;
  const dur = head.querySelector(".tool-dur");
  if (dur) head.insertBefore(badge, dur); else head.appendChild(badge);
  const list = document.createElement("div");
  list.className = "tool-result repeat-list";
  list.hidden = true;
  list.textContent = group.items.map((t) => `· ${absTime(t.ts)}`).join("\n");
  node.appendChild(list);
  head.title = "点开看每次发生的时间";
  head.addEventListener("click", () => { list.hidden = !list.hidden; });
}

export function renderDMView(flow, ctx) {
  const trail = state.trail;
  if (!trail) {
    flow.appendChild(emptyNote("正在加载这只 Bee 的工作轨迹…"));
    return;
  }
  const tasks = trail.tasks || [];
  const taskById = new Map(tasks.map((t) => [t.id, t]));
  flow.appendChild(beeCard(trail, ctx, tasks));

  const trace = trail.trace || [];
  if (!trace.length) {
    flow.appendChild(emptyNote("它还没有工作记录。在下面输入一句话，就是直接给它下指令。"));
    return;
  }

  // 任务第一次出现 → 完整任务卡（即「新建任务」那一刻）；
  // 之后同一任务的状态变化 → 收成一条细状态行，避免刷屏。
  const seenTask = new Set();
  for (const t of trace) {
    const task = t.task_id ? taskById.get(t.task_id) : null;
    if (task && !seenTask.has(task.id)) {
      seenTask.add(task.id);
      flow.appendChild(buildTaskCard(task, ctx));
      continue;
    }
    const node = traceNode(t, ctx);
    if (task) node.classList.add("cont");
    flow.appendChild(node);
  }
}

// ── Bee 头卡：身份 + 进行中任务（可深钻）+ 历史任务（折叠）+ 新建任务 ──
function beeCard(trail, ctx, tasks) {
  const bee = trail.bee || {};
  const node = document.createElement("div");
  node.className = "msg msg-assistant msg-boxed";

  const caps = (bee.capabilities || []).join(" / ");
  node.innerHTML = `
    <div class="msg-from">
      <span class="sess-dot ${bee.status === "working" ? "busy" : "online"}"></span>
      <span class="from-name">${esc(bee.display || "Bee")}</span>
      <span>${esc(kindLabel(bee.kind))} 成员</span>
      <span>${esc(caps || "")}</span>
    </div>`;

  const active = tasks.filter((t) => !isTerminal(t.status));
  const history = tasks.filter((t) => isTerminal(t.status));

  // 进行中：最多 3 条，点一条就地深钻
  const row = document.createElement("div");
  row.className = "bee-tasks";
  if (active.length) {
    for (const t of active.slice(0, 3)) {
      const chip = document.createElement("button");
      chip.className = "bee-task";
      chip.innerHTML = `${esc(t.title)} <span class="chip-mini ${statusChip(t.status)}">${esc(statusLabel(t.status))}</span>`;
      chip.onclick = () => ctx.openTask(t.id, t.title);
      row.appendChild(chip);
    }
    if (active.length > 3) {
      const more = document.createElement("span");
      more.className = "bee-task-more";
      more.textContent = `还有 ${active.length - 3} 条进行中`;
      row.appendChild(more);
    }
  } else {
    const none = document.createElement("span");
    none.className = "bee-task-more";
    none.textContent = "当前没有进行中的任务";
    row.appendChild(none);
  }
  node.appendChild(row);

  const actions = document.createElement("div");
  actions.className = "bee-task-actions";
  const newTask = document.createElement("button");
  newTask.className = "btn-ghost";
  newTask.textContent = "＋ 新任务";
  newTask.title = "给这只 Bee 建一个任务（直接派给它）";
  newTask.onclick = () => ctx.prefillTask();
  actions.appendChild(newTask);

  // 历史任务：折叠一行；展开后每条可深钻
  if (history.length) {
    const toggle = document.createElement("button");
    toggle.className = "btn-ghost";
    toggle.textContent = `历史任务 (${history.length}) ▸`;
    const list = document.createElement("div");
    list.className = "bee-task-history";
    list.hidden = true;
    for (const t of history) {
      const item = document.createElement("button");
      item.className = "bee-task-row";
      item.innerHTML =
        `<span class="bee-task-title">${esc(t.title)}</span>` +
        `<span class="chip-mini ${statusChip(t.status)}">${esc(statusLabel(t.status))}</span>` +
        `<span class="bee-task-time">${esc(fmtTime(t.completed_at || t.updated_at || t.created_at))}</span>`;
      item.onclick = () => ctx.openTask(t.id, t.title);
      list.appendChild(item);
    }
    toggle.onclick = () => {
      list.hidden = !list.hidden;
      toggle.textContent = `历史任务 (${history.length}) ${list.hidden ? "▸" : "▾"}`;
    };
    actions.appendChild(toggle);
    node.appendChild(actions);
    node.appendChild(list);
    return node;
  }

  node.appendChild(actions);
  return node;
}

// ── 通用节点分发 ──
export function traceNode(t, ctx) {
  const taskId = t.task_id || t.data?.task_id || t.data?.taskId;
  if (t.type === 'task' && taskId) {
    const task = (state.data?.tasks || []).find(item => item.id === taskId);
    if (task) return buildTaskCard(task, ctx);
  }
  if (t.type === "message") return messageNode(t);
  if (t.type === "honey") return honeyNode(t, ctx);
  return toolNode(t);
}

// ── 消息：我（Queen）右对齐，其他成员左对齐（与主界面一致）──
function messageNode(t) {
  const who = memberById(t.bee_id);
  const fromColony = !!(t.data && t.data.from === "colony");
  const self = state.data && who && who.id === state.data.actor_bee_id;

  const mentions = (t.data && t.data.mentions) || [];

  if (self) {
    const node = document.createElement("div");
    node.className = "msg msg-user";
    node.innerHTML = renderWithMentions(t.text, mentions);
    const mine = attachmentsRow(t);
    if (mine) node.appendChild(mine);
    node.appendChild(timeEl(t.ts));
    return node;
  }

  const name = fromColony ? "Colony" : who ? who.display : "成员";
  const node = document.createElement("div");
  node.className = "msg msg-assistant msg-boxed";
  const from = document.createElement("div");
  from.className = "msg-from";
  from.innerHTML =
    `<span class="sess-dot ${fromColony ? "online" : (who && who.status === "working" ? "busy" : "online")}"></span>` +
    `<span class="from-name">${esc(name)}</span>` +
    `<span class="from-kind">${esc(fromColony ? "系统" : who ? kindLabel(who.kind) : "")}</span>`;
  const body = document.createElement("div");
  body.className = "md";
  body.innerHTML = renderMarkdown(t.text || "");
  highlightMentions(body, mentions);
  node.appendChild(from);
  node.appendChild(body);
  const atts = attachmentsRow(t);
  if (atts) node.appendChild(atts);
  node.appendChild(timeEl(t.ts));
  return node;
}

// @ 点名高亮：先转义，再把 @名字 包成 chip（仿微信群里的高亮 @）
function renderWithMentions(text, mentions) {
  const safe = esc(text || "");
  if (!mentions || !mentions.length) return safe;
  let out = safe;
  for (const m of mentions) {
    const token = "@" + esc(m);
    out = out.split(token).join(`<span class="mention">${token}</span>`);
  }
  return out;
}

// Markdown 渲染后的 @ 高亮：只改文本节点，不碰标签和属性。
function highlightMentions(root, mentions) {
  if (!mentions || !mentions.length) return;
  const tokens = [...new Set(mentions.map((m) => `@${String(m)}`).filter((tk) => tk.length > 1))]
    .sort((a, b) => b.length - a.length);
  if (!tokens.length) return;
  const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT);
  const nodes = [];
  while (walker.nextNode()) nodes.push(walker.currentNode);
  for (const node of nodes) {
    if (isMentionExcluded(node, root)) continue;
    const text = node.nodeValue || "";
    const fragment = mentionFragment(text, tokens);
    if (fragment) node.parentNode.replaceChild(fragment, node);
  }
}

function isMentionExcluded(node, root) {
  let element = node.parentElement;
  while (element) {
    if (element.matches("code, pre, a")) return true;
    if (element === root) break;
    element = element.parentElement;
  }
  return root.nodeType === Node.ELEMENT_NODE && root.matches("code, pre, a");
}

function mentionFragment(text, tokens) {
  let cursor = 0;
  const fragment = document.createDocumentFragment();
  let found = false;
  while (cursor < text.length) {
    let matchIndex = -1;
    let matchToken = null;
    for (const token of tokens) {
      const index = text.indexOf(token, cursor);
      if (index !== -1 && (matchIndex === -1 || index < matchIndex)) {
        matchIndex = index;
        matchToken = token;
      }
    }
    if (matchIndex === -1) break;
    if (matchIndex > cursor) fragment.appendChild(document.createTextNode(text.slice(cursor, matchIndex)));
    const mention = document.createElement("span");
    mention.className = "mention";
    mention.textContent = matchToken;
    fragment.appendChild(mention);
    cursor = matchIndex + matchToken.length;
    found = true;
  }
  if (!found) return null;
  if (cursor < text.length) fragment.appendChild(document.createTextNode(text.slice(cursor)));
  return fragment;
}


// 附件（主界面的 .msg-user-files / .msg-user-file 同款样式）
function attachmentsRow(t) {
  const atts = (t.data && t.data.attachments) || [];
  if (!atts.length) return null;
  const box = document.createElement("div");
  box.className = "msg-user-files";
  for (const a of atts) {
    const chip = document.createElement("span");
    chip.className = "msg-user-file";
    chip.textContent = `📎 ${a.name || a.id}`;
    chip.title = `${a.name || ""}${a.size ? ` (${a.size} bytes)` : ""}${a.path ? `\\n${a.path}` : ""}`;
    box.appendChild(chip);
  }
  return box;
}

// 事件类型的中文标签：群聊里出现的是「动态」这类词，不是内部事件名。
const TYPE_LABEL = {
  task: "工作", lifecycle: "动态", command: "指令", tool_call: "工具", tool: "工具",
  signal: "信号", dispatch: "派发", system: "系统", decision: "决定", control: "控制",
  honey: "成果", message: "消息", refresh: "刷新", switch: "切换", capabilities: "能力",
};

// ── 事件卡：任务 / 生命周期 / 指令 / 工具调用 / 信号（复用主界面 .msg-tool）──

function toolNode(t) {
  const node = document.createElement("div");
  node.className = "msg msg-tool";

  const head = document.createElement("div");
  head.className = "tool-head";
  const sigKind = t.data && t.data.kind;
  head.innerHTML =
    `<span class="kind-dot" aria-hidden="true"></span>` +
    `<span class="card-kind">${esc(TYPE_LABEL[t.type] || t.type || "动态")}</span>` +
    `<span class="diffstat">${esc(t.text || "")}</span>` +
    (t.type === "signal" && sigKind ? `<span class="chip-mini accent">${esc(signalLabel(sigKind))}</span>` : "") +
    `<span class="tool-dur" title="${esc(absTime(t.ts))}">${esc(fmtAgo(t.ts))}</span>`;
  node.appendChild(head);

  const detail = detailText(t);
  if (detail) {
    const res = document.createElement("div");
    res.className = "tool-result";
    res.textContent = detail;
    res.hidden = true;
    node.appendChild(res);
    head.onclick = () => { res.hidden = !res.hidden; };
    head.title = "点开看详情";
  }
  return node;
}

function detailText(t) {
  const d = t.data;
  if (!d || typeof d !== "object") return "";
  const bits = [];
  if (d.tool) bits.push(`工具：${d.tool}`);
  if (d.cmd) bits.push(`指令：${d.cmd}`);
  if (d.task_id) bits.push(`任务：${d.task_id}`);
  if (d.bee_id) bits.push(`执行：${beeName(d.bee_id)}`);
  if (d.to) bits.push(`状态：${d.from || "?"} → ${d.to}`);
  if (d.kind) bits.push(`类型：${signalLabel(d.kind)}`);
  if (d.summary) bits.push(d.summary);
  if (d.ok === false) bits.push("结果：失败");
  return bits.join("\n");
}

// ── 成果卡：内容 + 验收（内联通过 / 打回）──
function honeyNode(t, ctx) {
  const live = (state.data?.honey?.recent || []).find(h => h.id === t.data?.honey_id);
  const d = {...(t.data || {}), ...(live || {})};
  const reviewState = d.review_state || "pending_review";
  const honeyId = d.honey_id;
  const pending = !!honeyId && (reviewState === "pending_review" || reviewState === "auto_verified");

  const node = document.createElement("div");
  node.className = "msg msg-tool";
  if (pending) node.dataset.honeyPending = "1";

  const head = document.createElement("div");
  head.className = "tool-head";
  head.innerHTML =
    `<span class="card-kind kind-honey">成果</span><span class="diffstat" title="${esc(d.title || t.text || "成果")}">${esc(shortTitle(d.title || t.text || "成果", 34))}</span>` +
    `<span class="chip-mini ${honeyChip(reviewState)}">${esc(honeyStateLabel(reviewState))}</span>` +
    `<span class="tool-dur" title="${esc(absTime(t.ts))}">${esc(fmtAgo(t.ts))}</span>`;
  node.appendChild(head);

  if (d.content) {
    const body = document.createElement("div");
    body.className = "honey-result md";
    body.innerHTML = renderMarkdown(d.content);
    const more = clampBlock(body, d.content, "查看完整成果");
    node.appendChild(body);
    if (more) node.appendChild(more);
  }

  if (d.content_ref || d.evidence?.length || d.limitations?.length) {
    const evidence = document.createElement('details'); evidence.className = 'work-context';
    const title = document.createElement('summary'); title.textContent = `成果与验证记录 · 工作版本 ${d.work_revision ?? '?'}`;
    const content = document.createElement('pre'); content.textContent = [d.content_ref ? `成果引用：${d.content_ref}` : '', ...(d.evidence || []).map(e => e.text || JSON.stringify(e)), '未覆盖范围：', ...(d.limitations || ['尚未说明'])].filter(Boolean).join('\n');
    evidence.append(title,content); node.append(evidence);
  }
  const checks = d.checks || [];
  if (checks.length) {
    const box = document.createElement("div");
    box.className = "honey-checks";
    for (const c of checks) {
      const chip = document.createElement("span");
      chip.className = `chip-mini ${c.ok ? "ok" : "bad"}`;
      chip.textContent = `${c.ok ? "✓" : "✗"} ${c.check || "检查"}`;
      box.appendChild(chip);
    }
    node.appendChild(box);
  }

  const actions = document.createElement("div");
  actions.className = "honey-actions";
  if (pending && state.data?.can_manage) {
    actions.appendChild(reviewBtn("通过", "accept", "btn-allow", honeyId));
    actions.appendChild(reviewBtn("打回", "reject", "btn-deny", honeyId));
  }
  node.appendChild(actions);
  return node;
}

function reviewBtn(label, verdict, cls, honeyId) {
  const b = document.createElement("button");
  b.className = cls;
  b.textContent = label;
  b.onclick = async () => {
    b.disabled = true;
    try {
      let note = '';
      if (verdict === 'reject') {const answer = await form('退回成果', [{name:'note',label:'需要补齐什么',multiline:true,required:true}], '退回'); if (!answer) {b.disabled = false; return;} note = answer.note;}
      await rpc("colony.honey.review", { colonyId: state.colonyId, honeyId, verdict, note });
      toast(verdict === "accept" ? "已验收 ✅" : "已打回 ↩");
      await refresh();
    } catch (e) {
      toast(e.message || "操作失败", true);
      b.disabled = false;
    }
  };
  return b;
}

function honeyChip(s) {
  return { pending_review: "warn", auto_verified: "accent", accepted: "ok", rejected: "bad" }[s] || "";
}

function honeyStateLabel(s) {
  return { pending_review: "待验收", auto_verified: "预检通过", accepted: "已验收", rejected: "已打回" }[s] || "";
}

function beeName(id) {
  const m = memberById(id);
  return m ? m.display : id;
}

function absTime(ts) {
  const d = new Date(ts || Date.now());
  return d.toLocaleString(undefined, { month: "2-digit", day: "2-digit", hour: "2-digit", minute: "2-digit" });
}

function timeEl(ts) {
  const t = document.createElement("time");
  t.className = "msg-time";
  t.dateTime = new Date(ts || Date.now()).toISOString();
  t.title = absTime(ts);
  t.textContent = fmtAgo(ts);
  return t;
}

// 长成果默认折叠：给个高度上限，点按钮再展开。
function clampBlock(body, raw, label) {
  if (!raw || raw.length < 480) return null;
  body.classList.add("clamped");
  const more = document.createElement("button");
  more.type = "button";
  more.className = "md-more";
  more.textContent = label;
  more.onclick = () => {
    const on = body.classList.toggle("clamped");
    more.textContent = on ? label : "收起";
  };
  return more;
}

function emptyNote(text) {
  const node = document.createElement("div");
  node.className = "msg colony-note";
  const ico = document.createElement("span");
  ico.className = "colony-note-ico";
  ico.textContent = "🐝";
  const body = document.createElement("span");
  body.textContent = text;
  node.append(ico, body);
  return node;
}


