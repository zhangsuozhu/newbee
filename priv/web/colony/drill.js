// 蜂群前端 · 任务深钻：任务头卡（.msg-tool）+ 子任务列表 + 工作轨迹（同款卡片）
import { esc, fmtTime, statusLabel } from "./util.js";
import { state, memberById, refresh, selectWorkSection } from "./store.js";
import { rpc, toast } from "./api.js";
import { traceNode, honeyNode } from './chat.js';
import { prefill } from './composer.js';
import { buildTaskCard, statusChip, collaborate } from './taskcard.js?v=workbench-2';

function paragraph(text, cls = '') { const el = document.createElement('p'); el.className = cls; el.textContent = text; return el; }

export function renderDrillView(flow, ctx) {
  const drill = state.drill;
  if (!drill || !drill.task) {
    flow.appendChild(note("正在加载任务…"));
    return;
  }
  const task = drill.task;
  const tabs = document.createElement('nav');
  tabs.className = 'drill-tabs'; tabs.setAttribute('aria-label', '工作详情');
  const sections = [['overview', '概览'], ['collaboration', '协作记录'], ['execution', '执行观察'], ['results', '成果验收'], ['history', '历史']];
  const activeTab = sections.some(([id]) => id === state.drillTab) ? state.drillTab : 'overview';
  state.drillTab = activeTab;
  for (const [id, label] of sections) {
    const tab = document.createElement('button'); tab.type = 'button'; tab.textContent = label;
    tab.setAttribute('aria-selected', String(activeTab === id)); tab.setAttribute('aria-pressed', String(activeTab === id));
    tab.dataset.drillTab = id;
    tab.onclick = () => {
      selectWorkSection(id);
      setTimeout(() => document.querySelector(`[data-drill-tab="${id}"]`)?.focus(), 0);
    };
    tabs.append(tab);
  }
  flow.append(tabs);
  if (activeTab === 'history') {
    renderWorkHistory(flow, task, drill, ctx);
    return;
  }
  if (activeTab === 'collaboration') {
    renderCollaboration(flow, task, drill, ctx);
    return;
  }

  const taskCard = buildTaskCard(task, ctx, {drill: false, full: true});
  taskCard.dataset.drillSection = 'overview';
  flow.append(taskCard);
  const executions = [task, ...(drill.tasks || []).filter(t => t.id !== task.id)].filter(t => t.session_id);
  if (executions.length) {
    const box = document.createElement('section'); box.className = 'work-executions'; box.dataset.drillSection = 'execution';
    const heading = document.createElement('h3'); heading.textContent = '执行与分工'; box.append(heading);
    for (const execution of executions) {
      const bee = memberById(execution.assigned_bee_id);
      const open = document.createElement('button'); open.type = 'button'; open.className = 'btn-ghost';
      open.textContent = `${execution.title || '执行记录'} · ${bee?.display || 'Bee'} · ${statusLabel(execution.status)} → 打开执行会话`;
      open.onclick = () => ctx.openConversation(execution.session_id, execution.assigned_bee_id);
      box.append(open);
    }
    flow.append(box);
  }

  const honeys = ((drill.honey || []).length ? drill.honey : (((state.data || {}).honey || {}).recent || [])).filter(h => h.task_id === task.id);
  const children = (drill.tasks || []).filter(t => t.parent_task_id === task.id);
  appendCollaboration(flow, task, children, ctx);

  const taskEventId = t => t.task_id || t.data?.task_id || t.data?.taskId;
  const seenTaskCards = new Set();
  const entries = dedupe([...(drill.trace || []), ...(drill.children_trace || [])]).filter(t => {
    // 成果有独立的验收面板；执行观察只保留过程事件，避免同一成果出现两套通过/打回按钮。
    if (t.type === 'honey') return false;
    if (t.type !== 'task') return true;
    const id = taskEventId(t);
    if (!id || id === task.id || seenTaskCards.has(id)) return false;
    seenTaskCards.add(id);
    return true;
  });

  for (const honey of honeys) {
    const card = honeyNode({type: 'honey', text: honey.title, ts: honey.created_at, data: {honey_id: honey.id}}, ctx);
    card.dataset.drillSection = 'results';
    flow.append(card);
  }
  if (!honeys.length) {
    const emptyResults = note('当前还没有提交成果；完成后会在这里验收。');
    emptyResults.dataset.drillSection = 'results';
    flow.append(emptyResults);
  }
  if (!entries.length) {
    const empty = note(honeys.length ? '这条任务的执行过程没有留下轨迹记录；成果见成果验收。' : '这条任务还没有执行记录；可以在概览中补充要求。');
    empty.dataset.drillSection = 'execution';
    flow.append(empty);
    applyDrillTab(flow);
    return;
  }
  const records = document.createElement('details'); records.className = 'work-records'; records.dataset.drillSection = 'execution';
  const summary = document.createElement('summary'); summary.textContent = `工作动态 · ${entries.length} 条`;
  records.append(summary);
  for (const entry of entries) {
    records.append(traceNode(entry, ctx));
    if (entry.text) {
      const quote = document.createElement('button'); quote.type = 'button'; quote.className = 'btn-ghost work-quote'; quote.textContent = '引用并指导本工作';
      quote.onclick = () => prefill(`引用工作「${task.title}」· 记录 ${entry.seq}\n> ${String(entry.text).slice(0, 8000).replace(/\n/g, '\n> ')}\n\n`);
      records.append(quote);
    }
  }
  flow.append(records);
  applyDrillTab(flow);
}

function appendCollaboration(flow, task, children, ctx) {
  if (children.length) {
    const box = document.createElement('div'); box.className = 'drill-children'; box.dataset.drillSection = 'collaboration';
    for (const child of children) box.append(childRow(child, ctx));
    flow.append(box);
  }
  const panel = document.createElement('section'); panel.className = 'work-collab-panel'; panel.dataset.drillSection = 'collaboration';
  const phase = task.workflow?.phase || 'execution';
  const phaseLabels = {triage: '判断投入', proposing: '方案讨论', discussing: '方案讨论', choosing: '选择执行方案', executing: '执行中', integrating: '整合交付', execution: '执行中'};
  const participantIds = [...new Set([task.assigned_bee_id, ...children.map(child => child.assigned_bee_id)].filter(Boolean))];
  const waiting = task.waiting_for === 'user' ? '等待你的答复' : task.waiting_for === 'children' ? '等待协作成员交付' : task.integration_required ? '等待负责人集成' : '正在推进';
  const head = document.createElement('div'); head.className = 'work-collab-head';
  const title = document.createElement('h3'); title.textContent = '协作状态';
  const hint = document.createElement('span'); hint.textContent = waiting; hint.className = 'chip-mini accent';
  head.append(title, hint); panel.append(head);
  const facts = document.createElement('div'); facts.className = 'work-collab-facts';
  const addFact = (label, value) => { const row = document.createElement('div'); row.className = 'work-collab-fact'; row.innerHTML = `<span class="work-label">${esc(label)}</span><strong>${esc(value)}</strong>`; facts.append(row); };
  addFact('负责人', memberById(task.assigned_bee_id)?.display || '尚未分配');
  addFact('参与者', participantIds.length ? participantIds.map(id => memberById(id)?.display || id).join('、') : '暂无');
  addFact('当前阶段', phaseLabels[phase] || phase);
  addFact('交付方式', task.integration_required ? '负责人集成后交付' : '负责人直接交付');
  panel.append(facts);
  if (state.data?.can_manage && !['done', 'failed', 'cancelled'].includes(task.status)) {
    const actions = document.createElement('div'); actions.className = 'work-collab-actions';
    const invite = document.createElement('button'); invite.type = 'button'; invite.className = 'btn-ghost'; invite.textContent = '请成员协作';
    invite.onclick = async () => { invite.disabled = true; try { await collaborate(task); } catch (error) { toast(error.message || '协作请求失败', true); } finally { invite.disabled = false; } };
    actions.append(invite); panel.append(actions);
  }
  panel.append(paragraph(children.length ? '下面列出本工作的子工作；打开后仍保留当前工作作为返回上下文。' : '当前没有拆分的子工作，负责人正在独立处理。', 'work-collab-empty'));
  flow.append(panel);
}

function renderCollaboration(flow, task, drill, ctx) {
  appendCollaboration(flow, task, (drill.tasks || []).filter(t => t.parent_task_id === task.id), ctx);
}

function historyEvent(t) {
  const node = document.createElement('details'); node.className = 'work-history-event';
  const summary = document.createElement('summary');
  const who = memberById(t.bee_id)?.display || (t.type === 'tool' ? '执行记录' : '系统');
  const kind = {task: '工作状态', message: '沟通', honey: '成果', tool: '工具', command: '命令', signal: '协作信号'}[t.type] || '记录';
  const title = t.title || t.data?.title || t.tool || t.data?.tool || (t.status ? statusLabel(t.status) : kind);
  const detail = title !== kind ? `<strong>${esc(title)}</strong>` : '';
  summary.innerHTML = `<span class="work-history-kind">${esc(kind)}</span>${detail}<span class="work-history-who">${esc(who)}</span><time>${esc(fmtTime(t.ts || t.created_at || t.updated_at))}</time>`;
  node.append(summary);

  const text = t.text || t.preview || t.data?.text || t.data?.preview;
  if (text) { const body = document.createElement('div'); body.className = 'work-history-event-body'; body.textContent = text; node.append(body); }
  return node;
}

function renderWorkHistory(flow, task, drill, ctx) {
  const panel = document.createElement('section'); panel.className = 'work-history'; panel.dataset.drillSection = 'history';
  const head = document.createElement('h3'); head.textContent = '工作历史'; panel.append(head);
  const entries = (drill.trace || []).filter(t => !['lifecycle', 'command', 'signal', 'tool', 'dispatch'].includes(t.type));
  const list = document.createElement('details'); list.className = 'work-records'; list.open = true;
  const summary = document.createElement('summary'); summary.textContent = `工作记录 · ${entries.length} 条`;
  list.append(summary);
  if (!entries.length) list.append(note('这项工作还没有关键记录；工具与命令细节留在执行观察。'));
  for (const entry of entries) list.append(historyEvent(entry));
  panel.append(list);
  const honeys = ((drill.honey || []).length ? drill.honey : (((state.data || {}).honey || {}).recent || [])).filter(h => h.task_id === task.id);
  const versions = document.createElement('details'); versions.className = 'work-history-versions';
  const versionsTitle = document.createElement('summary'); versionsTitle.textContent = `成果与验收记录 · ${honeys.length}`;
  versions.append(versionsTitle);
  for (const honey of [...honeys].reverse()) {
    const row = document.createElement('button'); row.type = 'button'; row.className = 'work-history-version';
    const stateLabel = honey.review_state === 'accepted' ? '已验收' : honey.review_state === 'rejected' ? '已打回' : honey.review_state === 'auto_verified' ? '预检通过' : '待验收';
    row.innerHTML = `<span>${esc(honey.title || '成果')}</span><span>${stateLabel}</span><time>${esc(fmtTime(honey.created_at))}</time>`;
    row.onclick = () => selectWorkSection('results');
    versions.append(row);
  }
  if (!honeys.length) versions.append(note('还没有提交过成果；历史里不会显示不存在的版本。'));
  panel.append(versions);
  panel.append(note('当前只提供事件与成果记录；没有不可变快照，因此暂不提供恢复按钮。'));
  flow.append(panel);
  applyDrillTab(flow);
}


function applyDrillTab(flow) {
  const active = state.drillTab || 'overview';
  for (const node of flow.children) {
    if (node.classList.contains('drill-tabs')) continue;
    node.hidden = node.dataset.drillSection ? node.dataset.drillSection !== active : false;
  }
  for (const tab of flow.querySelectorAll('.drill-tabs button')) {
    const selected = tab.textContent === ({overview: '概览', collaboration: '协作记录', execution: '执行观察', results: '成果验收', history: '历史'}[active]);
    tab.setAttribute('aria-selected', String(selected));
    tab.setAttribute('aria-pressed', String(selected));
  }
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

