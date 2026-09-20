import { state, memberById, refresh, attentionFor } from './store.js';
import { rpc, toast } from './api.js';
import { form, confirmAction } from './forms.js';
import { cardMenu, esc, statusLabel } from './util.js';
import { renderMarkdown } from './md.js';
const phases = {triage:'判断投入',proposing:'独立提案',discussing:'讨论方案',choosing:'等你决定',executing:'实施修改',integrating:'集成验证'};
const openFolds = new Set();
const openDetails = new Set();
function rememberDetails(details, taskId, key) {
  const id = `${taskId}:${key}`;
  details.addEventListener('toggle', () => {
    if (details.open) openDetails.add(id);
    else openDetails.delete(id);
  });
  details.open = openDetails.has(id);
  return details;
}
const terminal = t => ['done','failed','cancelled'].includes(t.status);
const name = id => memberById(id)?.display || '已离开的成员';
function workspaceFailure(t) { return typeof t.next_step === 'string' && /workspace_(unsupported_file|missing|git_failed)/.test(t.next_step); }
function canChangeCwd(t) { return !t.workspace && !t.session_id && ['pending', 'claimed', 'blocked'].includes(t.status); }
function nextStepLabel(t) {
  if (workspaceFailure(t)) return '执行环境没有启动：工作目录里有不支持的文件或链接。可以先直接重试；若仍失败，请换到具体项目目录。';
  return t.next_step || '';
}

function button(label, fn, primary = false) {
  const el = document.createElement('button'); el.type = 'button'; el.className = primary ? 'btn-allow' : 'btn-ghost'; el.textContent = label;
  el.onclick = async () => { el.disabled = true; try { await fn(); } catch(e) { toast(e.message || '操作失败', true); } finally { el.disabled = false; } }; return el;
}
function paragraph(text, cls = '') { const el = document.createElement('p'); el.className = cls; el.textContent = text; return el; }
const guard = (fn) => async () => { try { await fn(); } catch (e) { toast(e.message || '操作失败', true); } };
const guardMenu = (items) => items.map(([label, fn]) => [label, guard(fn)]);
async function act(t, action, attrs = {}) {
  // 直接按钮（选它执行/再互评/重试/分工）不经过 guardMenu，失败必须在界面上可见。
  try {
    await rpc('colony.work.flow', {colonyId:state.colonyId,taskId:t.id,revision:t.revision,action,...attrs});
    await refresh();
    const success = action === 'retry' && workspaceFailure(t)
      ? '已重新尝试启动执行'
      : {comment:'已补充讨论意见', discuss:'已发起新一轮互评', retry:'已重新发起初步分析', retry_member:'已提交补充说明，正在重试', execute:'已采纳方案，开始实施'}[action];
    if (success) toast(success);
  } catch (e) {
    if (e?.code === 'timeout') {
      toast('请求超时；结果可能已处理，正在刷新工作卡', true);
      void refresh();
      return;
    }
    toast(e.message || '操作失败', true);
  }
}

async function cleanupWorkspace(task) {
  const yes = await confirmAction('清理隔离工作区', '这会删除该任务的隔离目录和其中未提交的改动；原项目不会被修改。', '清理');
  if (!yes) return;
  await rpc('colony.workspace.cleanup', {colonyId: state.colonyId, taskId: task.id});
  await refresh();
  toast('隔离工作区已清理');
}
export function workflowLabel(t) {
  if (terminal(t) || t.status === 'pending_review') return statusLabel(t.status);
  if (t.control_state === 'pausing') return '正在暂停，等待确认';
  return t.control_state && t.control_state !== 'running' ? '已暂停' : phases[t.workflow?.phase] || statusLabel(t.status);
}
export function renderWorkBoard(flow, ctx, sourceTasks = null) {
  const priority = t => t.status === 'blocked' || t.workflow?.phase === 'choosing' ? 0 : t.status === 'pending_review' ? 1 : 2;
  const tasks = (sourceTasks || state.data?.tasks || []).filter(t => t.workflow && !terminal(t)).sort((a,b) => priority(a) - priority(b)); if (!tasks.length) return;
  const panel = document.createElement('section'); panel.className = 'work-board'; panel.setAttribute('aria-label','协作工作');
  const boardHead = document.createElement('div'); boardHead.className = 'work-section-head';
  boardHead.innerHTML = '<h2>协作工作</h2><span>需要多步判断或多人协作的工作</span>';
  const tabs = document.createElement('div'); tabs.className = 'work-tabs';
  const focused = tasks.find(t => t.id === state.focusedWork) || tasks.find(t => t.workflow.phase === 'choosing') || tasks[0];
  for (const t of tasks) {
    const tab = button(`${t.title.slice(0,30)} · ${workflowLabel(t)}`, () => { state.focusedWork = t.id; const host = document.createElement('div'); renderWorkBoard(host, ctx, sourceTasks); panel.replaceWith(host.querySelector('.work-board')); });
    tab.setAttribute('aria-pressed',String(t.id === focused.id)); tabs.append(tab);
  }
  const jump = button('↑ 查看当前任务', () => flow.querySelector('.work-board')?.scrollIntoView({block:'start',behavior:'smooth'}));
  jump.classList.add('work-jump');
  panel.append(boardHead, tabs, buildWorkflowCard(focused,ctx)); flow.append(panel);
}
export function buildWorkflowCard(t, ctx) {
  const w = t.workflow, manage = state.data?.can_manage && !terminal(t), selected = new Set(state.workSelections?.[t.id] || []);
  const card = document.createElement('article'); card.className = 'work-flow-card'; card.dataset.taskId = t.id;
  const head = document.createElement('div'); head.className = 'work-flow-head'; head.innerHTML = `<strong>${esc(t.title)}</strong><span class="chip-mini accent">${esc(workflowLabel(t))}</span>`;
  const title = head.querySelector('strong'); title.tabIndex = 0; title.setAttribute('role', 'button');
  title.onclick = () => ctx.openTask(t.id, t.title);
  title.onkeydown = e => { if (['Enter', ' '].includes(e.key)) { e.preventDefault(); title.click(); } };
  card.append(head,paragraph(`${name(t.assigned_bee_id)} 负责`,'work-flow-owner'));
  const attention = attentionFor(t);
  if (attention) {
    const reason = paragraph(attention.reason, 'work-attention-reason');
    if (state.view !== 'drill' && t.status !== 'pending_review') reason.append(button(attention.label, () => ctx.openTask(t.id, t.title, attention.section)));
    card.append(reason);
  }
  // 判断依据默认收起：卡面上先给结论，想追原因再展开。
  if (w.reason) {
    const why = document.createElement('details'); why.className = 'work-why';
    const whyTitle = document.createElement('summary'); whyTitle.textContent = '为什么这么安排';
    why.append(whyTitle,paragraph(w.reason,'work-flow-reason'));
    rememberDetails(why, t.id, 'why');
    card.append(why);
  }
  // 七个阶段不再平铺，收成一条进度：当前在哪一步、还剩几步。
  const order = Object.keys(phases);
  const index = Math.max(0, order.indexOf(w.phase));
  const steps = document.createElement('div'); steps.className = 'work-flow-steps';
  steps.title = order.map((phase, i) => `${i + 1}. ${phases[phase]}`).join(' → ');
  const bar = document.createElement('div'); bar.className = 'work-flow-bar';
  order.forEach((phase, i) => { const cell = document.createElement('i'); if (i <= index) cell.className = 'on'; if (i === index) cell.setAttribute('aria-current','step'); bar.append(cell); });
  const now = document.createElement('div'); now.className = 'work-flow-now'; now.textContent = `${phases[w.phase] || statusLabel(t.status)} · ${index + 1}/${order.length}`;
  steps.append(bar, now);
  const process = document.createElement('details'); process.className = 'work-process';
  const processTitle = document.createElement('summary'); processTitle.textContent = '协作阶段与互评';
  process.append(processTitle, steps, paragraph(`互评 ${w.round || 0}/2 轮`)); card.append(process);
  const proposals = document.createElement('div'); proposals.className = 'work-proposals';
  for (const p of w.proposals || []) {
    const child = (state.data?.tasks || []).find(c => c.id === p.task_id);
    const item = document.createElement('section'); item.className = 'work-proposal';
    const label = document.createElement('label'); label.className = 'work-proposal-person';
    if (w.phase === 'choosing' && manage) { const check = document.createElement('input'); check.type = 'checkbox'; check.setAttribute('aria-label',`选择 ${name(p.bee_id)} 参与分工`); check.checked = selected.has(p.bee_id); check.onchange = () => { check.checked ? selected.add(p.bee_id) : selected.delete(p.bee_id); state.workSelections ||= {}; state.workSelections[t.id] = [...selected]; }; label.append(check); }
    const person = document.createElement('strong'); person.textContent = name(p.bee_id); label.append(person); item.append(label);
    const summary = document.createElement('div'); summary.className = 'md work-proposal-summary folded-summary'; summary.innerHTML = renderMarkdown(p.summary || '正在检查代码，准备修改方案…'); item.append(summary);
    // 长方案默认只露六行，避免一张卡被一段分析文本占满整屏。
    if ((p.summary || '').length > 240) {
      const more = document.createElement('button'); more.type = 'button'; more.className = 'md-more';
      more.textContent = '展开完整方案';
      more.onclick = () => { const on = summary.classList.toggle('folded-summary'); more.textContent = on ? '展开完整方案' : '收起'; };
      item.append(more);
    }
    (p.reviews || []).forEach((review, i) => {
      const details = document.createElement('details');
      const key = `review:${p.task_id || p.bee_id || 'member'}:${i}`;
      const title = document.createElement('summary'); title.textContent = `第 ${i + 1} 轮互评`;
      const body = document.createElement('div'); body.className = 'md'; body.innerHTML = renderMarkdown(review);
      details.append(title, body);
      rememberDetails(details, t.id, key);
      item.append(details);
    });
    if(child?.status === 'blocked') {
      item.append(paragraph(child.next_step || '这只 Bee 需要帮助','work-ask'));
      if(manage) item.append(button('补充并重试',async () => { const input = await form('继续当前阶段',[{name:'text',label:'答复或补充说明',multiline:true,required:true}],'重试'); if(input) await act(t,'retry_member',{memberTaskId:p.task_id,text:input.text}); }));
    }
    if(w.phase === 'choosing' && manage) item.append(button('选它执行',() => act(t,'execute',{assignments:[{bee_id:p.bee_id}],text:'采纳该成员方案，按讨论补充实施并验证。'}),true));
    if(child?.session_id) item.append(button('打开执行会话',() => ctx.openConversation(child.session_id,child.assigned_bee_id)));
    proposals.append(item);
  }
  if(proposals.childElementCount) {
    if(['executing','integrating'].includes(w.phase) || terminal(t)) {
      const history = document.createElement('details'); const title = document.createElement('summary');
      title.textContent = `查看已确认的方案与互评 · ${w.proposals.length}`;
      history.append(title, proposals);
      rememberDetails(history, t.id, 'history');
      card.append(history);
    } else card.append(proposals);
  }
  for(const id of w.children || []) { const child = (state.data?.tasks || []).find(c => c.id === id); if(!child) continue; const row = document.createElement('div'); row.className = 'work-assignment'; row.append(paragraph(`${name(child.assigned_bee_id)} · ${child.title} · ${child.integration_required && child.status === 'pending_review' ? '已提交，待负责人集成' : statusLabel(child.status)}`),button('查看分工',() => ctx.openTask(child.id,child.title))); card.append(row); }
  if(t.next_step && t.status === 'blocked') card.append(paragraph(nextStepLabel(t),'work-flow-next'));
  if (t.cwd) {
    const cwd = document.createElement('div'); cwd.className = 'work-cwd';
    cwd.innerHTML = `<span class="work-label">执行目录</span><span class="work-cwd-path" title="${esc(t.cwd)}">${esc(t.cwd)}</span>`;
    card.append(cwd);
  }
  if((w.comments || []).length) {
    const details = document.createElement('details'); const title = document.createElement('summary');
    title.textContent = `人的补充 · ${w.comments.length}`;
    details.append(title); w.comments.forEach(c => details.append(paragraph(`${name(c.by)}：${c.text}`)));
    rememberDetails(details, t.id, 'comments');
    card.append(details);
  }
  if(t.workspace?.path) {
    const details = document.createElement('details'); const title = document.createElement('summary');
    title.textContent = '工作目录与交付位置'; details.append(title, paragraph(t.workspace.path));
    rememberDetails(details, t.id, 'workspace');
    card.append(details);
  }
  const actions = document.createElement('div'); actions.className = 'work-flow-actions';
  if (t.status === 'pending_review' || t.status === 'done') actions.append(button('查看成果', () => ctx.openTask(t.id, t.title, 'results'), true));
  if(!terminal(t) && !['executing','integrating'].includes(w.phase)) actions.append(button('补充讨论意见',async () => { const input = await form('给任务补充意见',[{name:'text',label:'约束、分歧或希望的方案',multiline:true,required:true}],'发送'); if(input) await act(t,'comment',input); }));
  const paused = t.control_state && t.control_state !== 'running';
  if (manage && t.control_state === 'paused') actions.append(button('继续执行', async () => { await rpc('colony.control',{colonyId:state.colonyId,scope:'work',targetId:t.id,action:'resume'}); await refresh(); toast('已恢复这项工作，执行器会继续处理'); }, true));
  if (manage && canChangeCwd(t)) {
    actions.append(button('更换工作目录', () => ctx.openDirectory(t.id)));
  }

  if(manage) {
    if(w.phase === 'choosing') {
      actions.append(button('让所选 Bee 分工执行',async () => {
        const ids = [...selected]; if(ids.length < 2) { toast('请先勾选两只或三只 Bee'); return; }
        const fields = ids.flatMap((id,i) => [{name:`title_${i}`,label:`${name(id)} 的交付目标`,required:true},{name:`scope_${i}`,label:'修改边界、输入输出、依赖及验证要求',multiline:true,required:true}]);
        fields.push({name:'text',label:'整体取舍与集成要求',multiline:true}); const input = await form('确认分工后开工',fields,'确认并执行');
        if(input) await act(t,'execute',{text:input.text,assignments:ids.map((id,i) => ({bee_id:id,title:input[`title_${i}`],scope:input[`scope_${i}`]}))});
      }));
      const discuss = button('再互评一轮',() => act(t,'discuss')); discuss.disabled = w.round >= 2; actions.append(discuss);
    }
      if (w.phase === 'triage' && ['blocked','claimed'].includes(t.status)) {
        const retryLabel = workspaceFailure(t) ? '重试执行' : '继续初步分析';
        actions.append(button(retryLabel, () => act(t, 'retry'), true));
      }
    if (['executing','integrating'].includes(w.phase) && t.status === 'blocked' && t.waiting_for !== 'children') {
      if (workspaceFailure(t)) actions.append(button('重试执行', async () => {
        await rpc('colony.work.continue',{colonyId:state.colonyId,taskId:t.id,revision:t.revision,text:'执行环境已修复，请在当前工作目录继续。'});
        await refresh(); toast('已重新发起执行');
      }, true));
      else actions.append(button('答复并继续',async () => { const input = await form('继续实施',[{name:'text',label:t.next_step || '补充要求',multiline:true,required:true}]); if(input) await guard(() => rpc('colony.work.continue',{colonyId:state.colonyId,taskId:t.id,revision:t.revision,text:input.text}).then(refresh))(); }, true));
    }
    // 低频操作收进「更多」，卡面上只留你此刻要做的决定。
    // 低频操作收进「更多」，卡面上只留你此刻要做的决定。
    const lowFreq = [['工作详情', () => ctx.openTask(t.id, t.title)]];
    if (t.session_id) lowFreq.push(['打开执行会话', () => ctx.openConversation(t.session_id, t.assigned_bee_id)]);
    lowFreq.push([paused ? '恢复任务' : '暂停任务', async () => {
      const action = paused ? 'resume' : 'pause';
      await rpc('colony.control',{colonyId:state.colonyId,scope:'work',targetId:t.id,action});
      await refresh();
      const fresh = (state.data?.tasks || []).find(x => x.id === t.id);
      const stillPaused = !!(fresh && fresh.control_state && fresh.control_state !== 'running');
      const settled = action === 'resume' ? !stillPaused : fresh?.control_state === 'paused';
      const message = action === 'pause'
        ? settled ? '已暂停这项工作（人仍可发言）' : '已请求暂停这项工作，等待执行器确认（人仍可发言）'
        : action === 'resume' && stillPaused
          ? '已恢复这项工作，但蜂群整体仍在暂停，请先恢复全群'
          : settled ? '已恢复这项工作' : '已请求恢复这项工作，等待执行器确认';
      toast(message);
    }]);
    if (t.owner_kind !== 'human' && ['executing','integrating'].includes(w.phase) && t.status !== 'blocked') lowFreq.push(['立即中止', async () => {
      const input = await form('中止这项工作', [{name:'reason',label:'停止原因',multiline:true,required:true,help:'停止执行进程；已发生的文件修改和外部操作不会自动撤回。'}], '立即中止');
      if (!input) return;
      await rpc('colony.control',{colonyId:state.colonyId,scope:'work',targetId:t.id,action:'interrupt'});
      await refresh();
      const fresh = (state.data?.tasks || []).find(x => x.id === t.id);
      toast(fresh?.control_state === 'paused' ? '已中止这项工作' : '已请求中止这项工作，等待执行器确认');
    }]);
    actions.append(cardMenu(guardMenu(lowFreq)));
  }
  const cleanableWorkspace = state.data?.can_manage && terminal(t) && t.workspace &&
    ['filesystem_copy', 'git_worktree'].includes(t.workspace.kind) && t.workspace.review_status !== 'cleaned';
  if (cleanableWorkspace) actions.append(cardMenu(guardMenu([['清理工作区', () => cleanupWorkspace(t)]])));
  card.append(actions);
  if (t.status === 'blocked' || t.status === 'pending_review' || w.phase === 'choosing') return card;
  head.remove();
  const folded = document.createElement('details');
  folded.className = 'work-flow-fold';
  folded.dataset.taskId = t.id;
  const line = document.createElement('summary');
  line.className = 'work-flow-fold-head';
  line.innerHTML = head.innerHTML;
  const direct = line.querySelector('strong');
  direct.tabIndex = 0; direct.setAttribute('role', 'button');
  direct.onclick = event => { event.preventDefault(); event.stopPropagation(); ctx.openTask(t.id, t.title); };
  direct.onkeydown = event => { if (['Enter', ' '].includes(event.key)) { event.preventDefault(); event.stopPropagation(); ctx.openTask(t.id, t.title); } };
  folded.append(line, card);

  folded.addEventListener('toggle', () => {
    if (folded.open) openFolds.add(t.id);
    else openFolds.delete(t.id);
  });
  folded.open = openFolds.has(t.id);
  return folded;
}
