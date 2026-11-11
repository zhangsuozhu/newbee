// 蜂群前端 · 团队模板与项目运行：组建提案（main）→ 人审批 → 模板入库 → 引用开项目 → 阶段闭环。
// 复用既有 form/dialog 与卡片样式；所有写操作走 colony.team.* RPC（服务端做权限与归属校验）。
import { esc } from './util.js';
import { form } from './forms.js';
import { rpc, toast } from './api.js';
import { state, refresh, loadColonies, selectColony } from './store.js';

const GATE = { review: '需验收', auto: '自动推进' };
const RUN_STATE = { active: '推进中', completed: '已完成待确认', halted: '已停下（轮次用尽）', closed: '已结束' };

export async function openTeams(ctx) {
  try {
    const [{ templates }, { proposals }, { runs }] = await Promise.all([
      rpc('colony.team.templates', {}),
      rpc('colony.team.proposals', { colonyId: state.colonyId }),
      rpc('colony.team.runs', { colonyId: state.colonyId })
    ]);
    await teamsDialog(ctx, templates || [], proposals || [], runs || []);
  } catch (error) { toast(error.message || '团队数据加载失败', true); }
}

async function teamsDialog(ctx, templates, proposals, runs) {
  const options = [
    { value: 'propose', label: '＋ 让 main 组建新团队（提案→审批）' },
    { value: 'seed', label: '＋ 安装内置「产研团队」模板' },
    ...templates.map(t => ({ value: 'tpl:' + t.id, label: `模板 · ${t.name}（${t.roles.length}角色/${t.stages.length}阶段）→ 开项目` })),
    ...proposals.filter(p => ['planning', 'draft_ready', 'draft_invalid'].includes(p.status)).map(p => ({ value: 'prop:' + p.id, label: `提案 · ${p.goal.slice(0, 30)}（${proposalState(p.status)}）` })),
    ...runs.map(r => ({ value: 'run:' + r.id, label: `项目 · ${r.name}（${RUN_STATE[r.status] || r.status}）` }))
  ];
  const choice = await form('团队模板与项目', [{ name: 'action', label: '选择要查看或操作的对象', options, help: '模板是全局资产：任何蜂群都能引用。提案与项目归属当前蜂群。' }], '打开');
  if (!choice) return;
  const [kind, id] = choice.action.split(':');
  try {
    if (choice.action === 'propose') return proposeTeam(ctx);
    if (choice.action === 'seed') {
      await rpc('colony.team.template.seed', {});
      toast('已安装内置产研团队模板');
      return openTeams(ctx);
    }
    if (kind === 'tpl') return templateDetail(ctx, templates.find(t => t.id === id));
    if (kind === 'prop') return proposalDetail(ctx, proposals.find(p => p.id === id));
    if (kind === 'run') return runDetail(ctx, id);
  } catch (error) { toast(error.message || '操作失败', true); }
}

function proposalState(status) {
  return { planning: 'main 规划中', draft_ready: '草案待审批', draft_invalid: '草案不合格', approved: '已批准', rejected: '已驳回' }[status] || status;
}

async function proposeTeam(ctx) {
  const value = await form('让 main 组建团队', [
    { name: 'goal', label: '这个团队要做什么', required: true, multiline: true, placeholder: '例如：一支产研团队，做记账小程序：产品经理调研设计、UI设计交互、架构师定方案、研发实现、测试验证，循环迭代。', help: 'main（团队主理人）会产出角色分工+运营流程草案；你审批后才建队入库。' }
  ], '发起提案');
  if (!value) return;
  const { proposal } = await rpc('colony.team.proposal.start', { colonyId: state.colonyId, goal: value.goal });
  toast('已交给 main 规划，草案就绪后在这里审批');
  await refresh();
  return proposalDetail(ctx, proposal);
}

async function templateDetail(ctx, template) {
  if (!template) return;
  const roles = template.roles.map(r => `· ${r.name}(${r.key})：${r.duty}`).join('\n');
  const stages = template.stages.map(s => `· ${s.name} @${s.role} [${GATE[s.gate] || s.gate}]${s.gate === 'review' ? ' 打回→' + s.rework_to : ''}\n  目标：${s.goal}`).join('\n');
  const value = await form(`模板 · ${template.name}`, [
    { name: 'info', label: '角色与运营流程（只读）', value: `${template.description || ''}\n\n【角色】\n${roles}\n\n【阶段流水线】\n${stages}\n\n回退轮次上限：${template.max_rounds}`, multiline: true, readonly: true },
    { name: 'goal', label: '用此模板开项目：项目目标', multiline: true, placeholder: '例如：记账小程序，支持收支记录、分类与月度报表。' },
    { name: 'name', label: '项目名称（可选）', placeholder: template.name + ' · 新项目' }
  ], '启动项目');
  if (!value || !value.goal.trim()) return;
  const { run } = await rpc('colony.team.run.start', { templateId: template.id, goal: value.goal, name: value.name || undefined });
  toast('项目已启动：角色已建立，第一阶段已派发');
  await loadColonies();
  await selectColony(run.colony_id);
  return runDetail(ctx, run.id);
}

async function proposalDetail(ctx, proposal) {
  if (!proposal) return;
  const draft = proposal.draft;
  const draftText = draft
    ? `${draft.name}\n${draft.description || ''}\n\n角色：\n${draft.roles.map(r => `· ${r.name}(${r.key})：${r.duty}`).join('\n')}\n\n阶段：\n${draft.stages.map(s => `· ${s.name} @${s.role} [${GATE[s.gate] || s.gate}] 打回→${s.rework_to}`).join('\n')}\n\n轮次上限：${draft.max_rounds}`
    : (proposal.status === 'planning' ? 'main 正在规划，稍后刷新查看草案。' : `草案不合格：${proposal.note || '未说明'}。可让 main 重新规划。`);
  const canDecide = proposal.status === 'draft_ready' && state.data?.can_manage;
  const fields = [
    { name: 'goal', label: '组建目标（只读）', value: proposal.goal, multiline: true, readonly: true },
    { name: 'draft', label: '团队草案（只读）', value: draftText, multiline: true, readonly: true }
  ];
  if (canDecide) fields.push({ name: 'note', label: '审批意见（打回/驳回时必填理由）', multiline: true });
  const value = await form(`组建提案 · ${proposalState(proposal.status)}`, fields, canDecide ? '批准并建模板' : '关闭');
  if (!value) return;
  if (canDecide) {
    const confirm = await form('确认批准', [{ name: 'ok', label: '批准后模板入库（全局可复用）', options: [{ value: 'approve', label: '批准入库' }, { value: 'reject', label: '驳回提案' }, { value: 'retry', label: '让 main 重新规划' }] }], '确定');
    if (!confirm) return;
    if (confirm.ok === 'approve') {
      await rpc('colony.team.proposal.decide', { colonyId: state.colonyId, proposalId: proposal.id, decision: 'approve', note: value.note || undefined });
      toast('模板已批准入库，可随时引用开项目');
    } else if (confirm.ok === 'reject') {
      await rpc('colony.team.proposal.decide', { colonyId: state.colonyId, proposalId: proposal.id, decision: 'reject', note: value.note || '未说明原因' });
      toast('提案已驳回');
    } else {
      await rpc('colony.team.proposal.retry', { colonyId: state.colonyId, proposalId: proposal.id, note: value.note || undefined });
      toast('已让 main 重新规划');
    }
    await refresh();
  }
}

export async function runDetail(ctx, runId) {
  let view;
  try { view = await rpc('colony.team.run.view', { colonyId: state.colonyId, runId }); }
  catch (error) { toast(error.message || '项目加载失败', true); return; }
  const { run, stages, current_task: current } = view;
  const stageText = stages.map(s => `${s.state === 'done' ? '✅' : s.state === 'current' ? '▶' : '·'} ${s.name} @${s.role} [${GATE[s.gate] || s.gate}]${s.attempts ? '（' + s.attempts + '次交付' + (s.last_verdict === 'reject' ? '，最近被打回' : '') + '）' : ''}`).join('\n');
  const fields = [
    { name: 'info', label: `项目 · ${RUN_STATE[run.status] || run.status} · 第${run.round}轮`, value: `目标：${run.goal}\n\n阶段流水线：\n${stageText}${run.last_feedback ? '\n\n最近反馈：' + run.last_feedback : ''}`, multiline: true, readonly: true }
  ];
  if (current) fields.push({ name: 'task', label: '当前阶段任务（只读）', value: `${current.title}\n状态：${current.status}${current.next_step ? '\n下一步：' + current.next_step : ''}`, multiline: true, readonly: true });
  const value = await form(`团队项目 · ${run.name}`, fields, '查看操作');
  if (!value) return;
  const actions = [];
  if (current && current.status === 'pending_review' && current.result && state.data?.can_manage) {
    actions.push({ value: 'accept', label: '验收通过当前阶段成果' }, { value: 'reject', label: '打回重做（回到对应环节）' });
  }
  if (run.status === 'completed' && state.data?.can_manage) {
    actions.push({ value: 'complete', label: '满意，结束项目' }, { value: 'iterate', label: '继续迭代（带反馈回到第一阶段）' });
  }
  if (run.status === 'halted' && state.data?.can_manage) actions.push({ value: 'extend', label: '提高轮次预算并继续' });
  actions.push({ value: 'openTask', label: '打开当前任务详情' }, { value: 'refresh', label: '刷新' });
  const choice = await form('项目操作', [{ name: 'action', label: '要做什么', options: actions }], '执行');
  if (!choice) return;
  try {
    if (choice.action === 'accept' || choice.action === 'reject') {
      const note = await form(choice.action === 'accept' ? '验收通过' : '打回重做', [{ name: 'note', label: choice.action === 'accept' ? '验收意见（可选）' : '打回理由（会进入下一轮上下文，必填）', required: choice.action === 'reject', multiline: true }], '确定');
      if (!note) return;
      await rpc('colony.team.run.review', { colonyId: state.colonyId, runId, honeyId: current.result, verdict: choice.action, note: note.note || '' });
      toast(choice.action === 'accept' ? '已通过，流水线继续推进' : '已打回，对应环节开始重做');
    } else if (choice.action === 'complete' || choice.action === 'iterate') {
      const note = await form(choice.action === 'complete' ? '结束项目' : '继续迭代', [{ name: 'note', label: choice.action === 'complete' ? '结项说明（可选）' : '下一轮要改进什么（会交给产品经理）', multiline: true, required: choice.action === 'iterate' }], '确定');
      if (!note) return;
      await rpc('colony.team.run.finish', { colonyId: state.colonyId, runId, decision: choice.action, note: note.note || undefined });
      toast(choice.action === 'complete' ? '项目已结束' : '新一轮迭代已开始');
    } else if (choice.action === 'extend') {
      const value = await form('提高轮次预算', [{ name: 'extra', label: '追加轮次（1..5）', value: '2', type: 'number' }], '继续');
      if (!value) return;
      await rpc('colony.team.run.extend', { colonyId: state.colonyId, runId, extraRounds: Number(value.extra) || 2 });
      toast('预算已提高，项目继续');
    } else if (choice.action === 'openTask' && current) {
      ctx.openTask(current.id, current.title);
      return;
    }
    await refresh();
    return runDetail(ctx, runId);
  } catch (error) { toast(error.message || '操作失败', true); }
}

// 工作台顶部的团队项目条：有运行中的项目时显示阶段进度与快捷入口。
export function renderTeamBanner(flow, ctx) {
  const runs = state.teamRuns || [];
  if (!runs.length) return;
  for (const run of runs) {
    const banner = document.createElement('div');
    banner.className = 'team-banner';
    const stages = (run.template?.stages || []);
    const dots = stages.map((s, i) => {
      const state_ = run.status === 'completed' || run.status === 'closed' ? 'done' : i < run.stage_index ? 'done' : i === run.stage_index ? 'current' : 'pending';
      return `<span class="team-dot ${state_}" title="${esc(s.name)}"></span>`;
    }).join('');
    banner.innerHTML = `<span class="team-banner-title">🧩 ${esc(run.name)}</span><span class="team-banner-meta">第${run.round}轮 · ${esc(RUN_STATE[run.status] || run.status)}</span><span class="team-dots">${dots}</span>`;
    const btn = document.createElement('button');
    btn.type = 'button'; btn.className = 'btn-ghost'; btn.textContent = '项目面板';
    btn.onclick = () => runDetail(ctx, run.id);
    banner.append(btn);
    flow.append(banner);
  }
}

export async function loadTeamRuns() {
  if (!state.colonyId) { state.teamRuns = []; return; }
  try {
    const { runs } = await rpc('colony.team.runs', { colonyId: state.colonyId });
    state.teamRuns = runs || [];
  } catch (_) { state.teamRuns = []; }
}
