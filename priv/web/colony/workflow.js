import { state, memberById, refresh } from './store.js';
import { rpc, toast } from './api.js';
import { form } from './forms.js';
import { cardMenu, esc, statusLabel } from './util.js';
import { renderMarkdown } from './md.js';
const phases = {triage:'判断投入',proposing:'独立提案',discussing:'讨论方案',choosing:'等你决定',executing:'实施修改',integrating:'集成验证'};
const terminal = t => ['done','failed','cancelled'].includes(t.status);
const name = id => memberById(id)?.display || '已离开的成员';
function button(label, fn, primary = false) {
  const el = document.createElement('button'); el.type = 'button'; el.className = primary ? 'btn-allow' : 'btn-ghost'; el.textContent = label;
  el.onclick = async () => { el.disabled = true; try { await fn(); } catch(e) { toast(e.message || '操作失败', true); } finally { el.disabled = false; } }; return el;
}
function paragraph(text, cls = '') { const el = document.createElement('p'); el.className = cls; el.textContent = text; return el; }
const guard = (fn) => async () => { try { await fn(); } catch (e) { toast(e.message || '操作失败', true); } };
const guardMenu = (items) => items.map(([label, fn]) => [label, guard(fn)]);
async function act(t, action, attrs = {}) { await rpc('colony.work.flow', {colonyId:state.colonyId,taskId:t.id,revision:t.revision,action,...attrs}); await refresh(); }
export function workflowLabel(t) {
  if (terminal(t) || t.status === 'pending_review') return statusLabel(t.status);
  return t.control_state && t.control_state !== 'running' ? '已暂停' : phases[t.workflow?.phase] || statusLabel(t.status);
}
export function renderWorkBoard(flow, ctx) {
  const priority = t => t.status === 'blocked' || t.workflow?.phase === 'choosing' ? 0 : t.status === 'pending_review' ? 1 : 2;
  const tasks = (state.data?.tasks || []).filter(t => t.workflow && !terminal(t)).sort((a,b) => priority(a) - priority(b)); if (!tasks.length) return;
  const panel = document.createElement('section'); panel.className = 'work-board'; panel.setAttribute('aria-label','当前协作任务');
  const tabs = document.createElement('div'); tabs.className = 'work-tabs';
  const focused = tasks.find(t => t.id === state.focusedWork) || tasks.find(t => t.workflow.phase === 'choosing') || tasks[0];
  for (const t of tasks) {
    const tab = button(`${t.title.slice(0,30)} · ${workflowLabel(t)}`, () => { state.focusedWork = t.id; const host = document.createElement('div'); renderWorkBoard(host,ctx); panel.replaceWith(host.querySelector('.work-board')); });
    tab.setAttribute('aria-pressed',String(t.id === focused.id)); tabs.append(tab);
  }
  const jump = button('↑ 查看当前任务', () => flow.querySelector('.work-board')?.scrollIntoView({block:'start',behavior:'smooth'}));
  jump.classList.add('work-jump');
  panel.append(tabs,buildWorkflowCard(focused,ctx)); flow.append(panel);
}
export function buildWorkflowCard(t, ctx) {
  const w = t.workflow, manage = state.data?.can_manage && !terminal(t), selected = new Set(state.workSelections?.[t.id] || []);
  const card = document.createElement('article'); card.className = 'work-flow-card'; card.dataset.taskId = t.id;
  const head = document.createElement('div'); head.className = 'work-flow-head'; head.innerHTML = `<strong>${esc(t.title)}</strong><span class="chip-mini accent">${esc(workflowLabel(t))}</span>`;
  card.append(head,paragraph(`${name(t.assigned_bee_id)} 负责 · 互评 ${w.round}/2 轮`,'work-flow-owner'));
  // 判断依据默认收起：卡面上先给结论，想追原因再展开。
  if (w.reason) { const why = document.createElement('details'); why.className = 'work-why'; const whyTitle = document.createElement('summary'); whyTitle.textContent = '为什么这么安排'; why.append(whyTitle,paragraph(w.reason,'work-flow-reason')); card.append(why); }
  // 七个阶段不再平铺，收成一条进度：当前在哪一步、还剩几步。
  const order = Object.keys(phases);
  const index = Math.max(0, order.indexOf(w.phase));
  const steps = document.createElement('div'); steps.className = 'work-flow-steps';
  steps.title = order.map((phase, i) => `${i + 1}. ${phases[phase]}`).join(' → ');
  const bar = document.createElement('div'); bar.className = 'work-flow-bar';
  order.forEach((phase, i) => { const cell = document.createElement('i'); if (i <= index) cell.className = 'on'; if (i === index) cell.setAttribute('aria-current','step'); bar.append(cell); });
  const now = document.createElement('div'); now.className = 'work-flow-now'; now.textContent = `${phases[w.phase] || statusLabel(t.status)} · ${index + 1}/${order.length}`;
  steps.append(bar, now); card.append(steps);
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
    (p.reviews || []).forEach((review,i) => { const details = document.createElement('details'); details.open = false; const title = document.createElement('summary'); title.textContent = `第 ${i+1} 轮互评`; const body = document.createElement('div'); body.className = 'md'; body.innerHTML = renderMarkdown(review); details.append(title,body); item.append(details); });
    if(child?.status === 'blocked') {
      item.append(paragraph(child.next_step || '这只 Bee 需要帮助','work-ask'));
      if(manage) item.append(button('补充并重试',async () => { const input = await form('继续当前阶段',[{name:'text',label:'答复或补充说明',multiline:true,required:true}],'重试'); if(input) await act(t,'retry_member',{memberTaskId:p.task_id,text:input.text}); }));
    }
    if(w.phase === 'choosing' && manage) item.append(button('选它执行',() => act(t,'execute',{assignments:[{bee_id:p.bee_id}],text:'采纳该成员方案，按讨论补充实施并验证。'}),true));
    if(child?.session_id) item.append(button('查看调查过程',() => ctx.openConversation(child.session_id,child.assigned_bee_id)));
    proposals.append(item);
  }
  if(proposals.childElementCount) {
    if(['executing','integrating'].includes(w.phase) || terminal(t)) {
      const history = document.createElement('details'); const title = document.createElement('summary');
      title.textContent = `查看已确认的方案与互评 · ${w.proposals.length}`; history.append(title,proposals); card.append(history);
    } else card.append(proposals);
  }
  for(const id of w.children || []) { const child = (state.data?.tasks || []).find(c => c.id === id); if(!child) continue; const row = document.createElement('div'); row.className = 'work-assignment'; row.append(paragraph(`${name(child.assigned_bee_id)} · ${child.title} · ${child.integration_required && child.status === 'pending_review' ? '已提交，待负责人集成' : statusLabel(child.status)}`),button('查看分工',() => ctx.openTask(child.id,child.title))); card.append(row); }
  if(t.next_step && t.status === 'blocked') card.append(paragraph(t.next_step,'work-flow-next'));
  if((w.comments || []).length) { const details = document.createElement('details'); const title = document.createElement('summary'); title.textContent = `人的补充 · ${w.comments.length}`; details.append(title); w.comments.forEach(c => details.append(paragraph(`${name(c.by)}：${c.text}`))); card.append(details); }
  if(t.workspace?.path) { const details = document.createElement('details'); const title = document.createElement('summary'); title.textContent = '工作目录与交付位置'; details.append(title,paragraph(t.workspace.path)); card.append(details); }
  const actions = document.createElement('div'); actions.className = 'work-flow-actions';
  if(!terminal(t) && !['executing','integrating'].includes(w.phase)) actions.append(button('补充讨论意见',async () => { const input = await form('给任务补充意见',[{name:'text',label:'约束、分歧或希望的方案',multiline:true,required:true}],'发送'); if(input) await act(t,'comment',input); }));
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
    if(w.phase === 'triage' && t.status === 'blocked') actions.append(button('重试初步分析',() => act(t,'retry')));
    if(['executing','integrating'].includes(w.phase) && t.status === 'blocked' && t.waiting_for !== 'children') actions.append(button('答复并继续',async () => { const input = await form('继续实施',[{name:'text',label:t.next_step || '补充要求',multiline:true,required:true}]); if(input) { await rpc('colony.work.continue',{colonyId:state.colonyId,taskId:t.id,revision:t.revision,text:input.text}); await refresh(); } }));
    const paused = t.control_state && t.control_state !== 'running';
    // 低频操作收进「更多」，卡面上只留你此刻要做的决定。
    const lowFreq = [['工作详情', () => ctx.openTask(t.id, t.title)]];
    if (t.session_id) lowFreq.push(['查看执行过程', () => ctx.openConversation(t.session_id, t.assigned_bee_id)]);
    lowFreq.push([paused ? '恢复任务' : '暂停任务', async () => { await rpc('colony.control',{colonyId:state.colonyId,scope:'work',targetId:t.id,action:paused?'resume':'pause'}); await refresh(); toast(paused ? '已恢复这项工作' : '已暂停这项工作（人仍可发言）'); }]);
    actions.append(cardMenu(guardMenu(lowFreq)));
  }
  card.append(actions);
  // 不需要你现在决定的协作任务折成一行，真正等你拍板的才整卡铺开。
  if (t.status === 'blocked' || t.status === 'pending_review' || w.phase === 'choosing') return card;
  head.remove();
  const folded = document.createElement('details');
  folded.className = 'work-flow-fold';
  folded.dataset.taskId = t.id;
  const line = document.createElement('summary');
  line.className = 'work-flow-fold-head';
  line.innerHTML = head.innerHTML;
  folded.append(line, card);
  return folded;
}
