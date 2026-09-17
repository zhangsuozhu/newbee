import { buildWorkflowCard } from './workflow.js?v=workbench-2';
import { cardMenu, esc, absTime, fmtAgo, statusLabel } from './util.js';
import { state, memberById, refresh } from './store.js';
import { rpc, toast } from './api.js';
import { form, confirmAction } from './forms.js';
import { renderInline, renderMarkdown } from './md.js';

export function isTerminal(status) { return ['done', 'failed', 'cancelled'].includes(status); }
function workspaceFailure(task) { return typeof task.next_step === 'string' && /workspace_(unsupported_file|missing|git_failed)/.test(task.next_step); }
function canChangeCwd(task) { return !task.workspace && !task.session_id && ['pending', 'claimed', 'blocked'].includes(task.status); }
function nextStepLabel(task) { return workspaceFailure(task) ? '执行环境没有启动：工作目录里有不支持的文件或链接。可以先直接重试；若仍失败，请换到具体项目目录。' : task.next_step || ''; }

function shortTitle(text, max = 34) {
  const s = String(text || '').replace(/^\s*(请?帮我|帮忙)?(完成|做|处理)[:：]?\s*/, '').trim();
  return s.length > max ? s.slice(0, max) + '…' : s;
}
export function statusChip(status) { return {running:'accent', pending_review:'accent', done:'ok', blocked:'bad', failed:'bad'}[status] || ''; }
export function buildTaskCard(task, ctx, opts = {}) {
  task = {...task, ...((state.data?.tasks || []).find(t => t.id === task.id) || {})};
  if (task.workflow && !opts.compact) return buildWorkflowCard(task, ctx);
  const bee = memberById(task.assigned_bee_id);
  const node = document.createElement('div'); node.className = 'msg msg-tool work-card'; node.dataset.taskId = task.id;
  const paused = task.control_state && task.control_state !== 'running';
  const label = paused ? ({paused:'已暂停', pausing:'正在暂停，等待确认'}[task.control_state] || task.control_state) : task.approval_required ? '等待授权' : task.mode === 'proposal' && task.status === 'pending_review' ? '方案待决定' : statusLabel(task.status);
  const stamp = task.activity_at || task.updated_at || task.created_at;
  // 要人动手的任务才铺开；纯进展折成一行，点开才是完整卡片，首屏才不会被卡片撑满。
  const mine = task.owner_kind === 'human' && task.assigned_bee_id === state.data?.actor_bee_id;
  const needsYou = !!(!isTerminal(task.status) && (task.approval_required || task.waiting_for === 'user' || ['blocked', 'pending_review'].includes(task.status) || mine));
  const fold = !needsYou && !opts.compact && !opts.full;
  // 卡面只留「是什么 + 谁在做 + 状态 + 下一步」；描述、最近动态、上下文都进折叠区。
  const headMarkup =
    `<span class="work-dot ${statusChip(task.status)}"></span>` +
    `<span class="work-title" title="${esc(task.title || task.id)}">${esc(shortTitle(task.title || task.id, 34))}</span>` +
    (bee ? `<span class="work-owner" title="负责人">${esc(bee.display)}</span>` : "") +
    `<span class="chip-mini ${statusChip(task.status)}">${esc(label)}</span>` +
    `<span class="work-time" title="${esc(absTime(stamp))}">${esc(fmtAgo(stamp))}</span>`;
  const head = document.createElement('div'); head.className = 'work-head'; head.innerHTML = headMarkup;
  node.append(head);
  if (!opts.compact) {
    const title = head.querySelector('.work-title');
    title.tabIndex = 0; title.setAttribute('role', 'button');
    title.onclick = () => ctx.openTask(task.id, task.title);
    title.onkeydown = e => { if (['Enter', ' '].includes(e.key)) { e.preventDefault(); title.click(); } };
  }
  if (opts.compact) {
    head.tabIndex = 0; head.setAttribute('role', 'button');
    head.onclick = () => ctx.openTask(task.id, task.title);
    head.onkeydown = event => { if (['Enter', ' '].includes(event.key)) { event.preventDefault(); head.click(); } };
    return node;
  }
  const body = document.createElement('div'); body.className = 'work-body';
  const brief = [];
  if (bee) brief.push(`<span class="work-label">负责人</span><span class="work-value">${esc(bee.display)}${task.owner_kind === 'human' ? ' · 真人' : ''}</span>`);
  if (task.activity) brief.push(`<span class="work-label">最近</span><span class="work-value">${renderInline(task.activity)}</span>`);
  const nextStep = task.integration_required && ['claimed','running'].includes(task.status) ? '按已确认分工实施，完成后提交负责人集成。' : nextStepLabel(task);
  if (nextStep) {
    const next = document.createElement('div'); next.className = 'work-next';
    next.innerHTML = `<span class="work-label">下一步</span><span class="work-next-text">${renderInline(nextStep)}</span>`;
    // 长段落先折三行，需要时再展开——避免整张卡被一段分析文本占满。
    if (String(nextStep).length > 180) {
      const text = next.querySelector('.work-next-text');
      text.classList.add('clamp3');
      const more = document.createElement('button');
      more.type = 'button'; more.className = 'md-more work-more'; more.textContent = '展开';
      more.onclick = () => { const on = text.classList.toggle('clamp3'); more.textContent = on ? '展开' : '收起'; };
      next.appendChild(more);
    }
    body.append(next);
  }
  if (task.cwd) {
    const cwd = document.createElement('div'); cwd.className = 'work-cwd';
    cwd.innerHTML = `<span class="work-label">执行目录</span><span class="work-cwd-path" title="${esc(task.cwd)}">${esc(task.cwd)}</span>`;
    body.append(cwd);
  }
  if (task.waiting_for === 'user') {
    const wait = document.createElement('div'); wait.className = 'work-ask'; wait.textContent = '需要你决定后才能继续';
    body.append(wait);
  }
  node.append(body);
  const details = document.createElement('details'); details.className = 'work-context';
  const summary = document.createElement('summary'); summary.textContent = `工作上下文 · 版本 ${task.context_revision || 0}`; details.append(summary);
  if (brief.length) { const meta = document.createElement('div'); meta.className = 'work-meta'; meta.innerHTML = brief.join(''); details.append(meta); }
  // description 常常就是用户原话（= 卡片标题），是同一句话就不再重复。
  if (task.description && !sameBrief(task.description, task.title)) {
    const desc = document.createElement('div'); desc.className = 'md work-desc'; desc.innerHTML = renderMarkdown(task.description); details.append(desc);
  }
  const content = document.createElement('pre');
  content.textContent = [['验收标准', task.acceptance], ['约束', task.constraints], ['已知事实', task.facts], ['已确认决定', task.decisions]].map(([label, value]) => `${label}：
${Array.isArray(value) ? value.map(v => typeof v === 'string' ? v : JSON.stringify(v)).join('\n') || '尚未记录' : value || '尚未记录'}`).join('\n\n');
  details.append(content); node.append(details);
  const actions = document.createElement('div'); actions.className = 'honey-actions work-actions';
  // 主操作（最多两个）留在卡面上；其余收进「更多」，避免一排按钮把卡片压成工具栏。
  const menu = [];
  if (task.status === 'pending_review') {
    const review = document.createElement('button'); review.type = 'button'; review.className = 'btn-allow';
    review.textContent = '查看成果'; review.onclick = () => ctx.openTask(task.id, task.title, 'results'); actions.append(review);
  }
  menu.push(['查看工作', () => ctx.openTask(task.id, task.title)]);
  if (task.session_id) menu.push(['打开执行会话', () => ctx.openConversation(task.session_id, task.assigned_bee_id)]);
  const cleanableWorkspace = task.workspace && ['filesystem_copy', 'git_worktree'].includes(task.workspace.kind) && task.workspace.review_status !== 'cleaned';
  if (state.data?.can_manage && isTerminal(task.status) && cleanableWorkspace) {
    menu.push(['清理工作区', async () => {
      const yes = await confirmAction('清理隔离工作区', '这会删除该任务的隔离目录和其中未提交的改动；原项目不会被修改。', '清理');
      if (!yes) return;
      await rpc('colony.workspace.cleanup', {colonyId: state.colonyId, taskId: task.id});
      await refresh();
      toast('隔离工作区已清理');
    }]);
  }

  if (!isTerminal(task.status)) {
    if (state.data?.can_manage) {
      menu.push([paused ? '恢复这项工作' : '暂停这项工作', () => control(task, paused ? 'resume' : 'pause')]);
      if (task.owner_kind !== 'human' && (task.status === 'running' || task.control_state === 'pausing')) menu.push(['立即中止', async () => {
        const yes = await form('中止这项工作', [{name:'reason', label:'停止原因', multiline:true, required:true, help:'停止执行进程；已发生的文件修改和外部操作不会自动撤回。'}], '立即中止');
        if (yes) await control(task, 'interrupt');
      }]);
    }
    if (state.data?.can_manage && task.control_state === 'paused') actions.append(action('继续执行', guard(() => control(task, 'resume'))));
    if (state.data?.can_manage && canChangeCwd(task)) actions.append(action('更换工作目录', () => ctx.openDirectory(task.id), true));
    if (task.approval_required || task.status === 'blocked') actions.append(action(workspaceFailure(task) ? '重试执行' : task.mode === 'proposal' ? '采纳方案并实施' : '答复并继续', async () => {
      if (workspaceFailure(task)) {
        await guard(() => rpc('colony.work.continue', {colonyId:state.colonyId, taskId:task.id, revision:task.revision, text:'执行环境已修复，请在当前工作目录继续。'}).then(refresh))();
        return;
      }
      const answer = await form(task.question?.question || '继续这项工作', [{name:'text', label:'决定或补充要求', multiline:true, required:true, value:task.mode === 'proposal' ? '按该方案实施，完成后给出验证证据。' : ''}], '继续');
      if (answer) await guard(() => rpc('colony.work.continue', {colonyId:state.colonyId, taskId:task.id, revision:task.revision, text:answer.text}).then(refresh))();
    }));
    menu.push(['补充要求', () => revise(task)]);
    if (state.data?.can_manage) menu.push(['请成员协作', () => collaborate(task)]);
    if (task.owner_kind === 'human' && task.assigned_bee_id === state.data?.actor_bee_id) {
      if (task.status === 'pending') actions.append(action('我来处理', guard(() => rpc('colony.task.transition', {colonyId:state.colonyId, taskId:task.id, event:'start'}).then(refresh))));
      if (task.status !== 'pending_review') actions.append(action('提交成果', async () => {
        const result = await form('提交工作成果', [{name:'content', label:'成果、验证方法与结果', required:true, multiline:true}, {name:'content_ref', label:'成果位置或版本'}, {name:'limitations', label:'未验证范围', multiline:true}], '提交验收');
        if (result) { result.limitations = result.limitations.split('\n').filter(Boolean); await guard(() => rpc('colony.work.submit', {colonyId:state.colonyId, taskId:task.id, result}).then(refresh))(); }
      }));
    }
  }
  if (menu.length) actions.append(cardMenu(guardMenu(menu)));
  node.append(actions);
  if (!fold) return node;
  // 不需要你动手的任务折成一行，点开才是完整卡片，避免一条流被卡片撑满。
  head.remove();
  node.className = 'work-fold-body'; // 外框（details）才是卡片，避免边框和背景叠两层
  const folded = document.createElement('details');
  folded.className = 'msg msg-tool work-card work-fold';
  folded.dataset.taskId = task.id;
  const line = document.createElement('summary');
  line.className = 'work-head';
  line.innerHTML = headMarkup;
  const direct = line.querySelector('.work-title');
  direct.tabIndex = 0; direct.setAttribute('role', 'button');
  direct.onclick = event => { event.preventDefault(); event.stopPropagation(); ctx.openTask(task.id, task.title); };
  direct.onkeydown = event => { if (['Enter', ' '].includes(event.key)) { event.preventDefault(); event.stopPropagation(); ctx.openTask(task.id, task.title); } };
  folded.append(line, node);

  return folded;
}

const guard = (fn) => async () => { try { await fn(); } catch (error) { toast(error.message || '操作失败', true); } };
const guardMenu = (items) => items.map(([label, fn]) => [label, guard(fn)]);
async function control(task, command) {
  await rpc('colony.control', {colonyId:state.colonyId, scope:'work', targetId:task.id, action:command});
  await refresh();
  const fresh = (state.data?.tasks || []).find(t => t.id === task.id);
  const settled = fresh?.control_state === (command === 'resume' ? 'running' : 'paused');
  const message = command === 'pause'
    ? settled ? '已暂停这项工作（人仍可发言）' : '已请求暂停这项工作，等待执行器确认（人仍可发言）'
    : command === 'resume'
      ? settled ? '已恢复这项工作' : '已请求恢复这项工作，等待执行器确认'
      : settled ? '已中止这项工作' : '已请求中止这项工作，等待执行器确认';
  toast(message);
}
async function revise(task) {
  const result = await form('补充工作要求', [{name:'constraints', label:'约束（每行一条）', multiline:true, value:(task.constraints || []).join('\n')}, {name:'acceptance', label:'验收标准（每行一条）', multiline:true, value:(task.acceptance || []).join('\n')}]);
  if (!result) return;
  const changes = {revision:task.revision, constraints:result.constraints.split('\n').filter(Boolean), acceptance:result.acceptance.split('\n').filter(Boolean)};
  await rpc('colony.work.revise', {colonyId:state.colonyId, taskId:task.id, changes}); await refresh();
}
export async function collaborate(task) {
  const result = await form('请成员处理独立子工作', [{name:'title', label:'要交付什么', required:true}, {name:'assigned_bee_id', label:'负责人', options:(state.data?.members || []).map(b => ({value:b.id, label:b.display}))}, {name:'description', label:'边界、输入和集成方式', required:true, multiline:true}], '创建待授权子工作');
  if (result) { await rpc('colony.work.collaborate', {colonyId:state.colonyId, taskId:task.id, children:[result]}); await refresh(); }
}
function action(label, fn, ghost = false) {
  const button = document.createElement('button'); button.className = ghost ? 'btn-ghost' : 'btn-allow'; button.type = 'button'; button.textContent = label;
  button.onclick = async () => {button.disabled = true; try {await fn();} catch (error) {toast(error.message || '操作失败', true);} finally {button.disabled = false;}};
  return button;
}
// 归一化后比较：相同或一方包含另一方的前 40 字，视为「同一句话」。
function sameBrief(a, b) {
  const norm = (s) => String(s || '').replace(/\s+/g, '').replace(/[，。！？,.!?:：;；"“”'']/g, '');
  const x = norm(a), y = norm(b);
  if (!x || !y) return false;
  if (x === y) return true;
  const head = (s) => s.slice(0, 40);
  return x.length > 20 && y.length > 20 && (x.includes(head(y)) || y.includes(head(x)));
}

