// Pure presentation policy; execution and authorization remain on the server.
const terminal = task => ['done', 'cancelled'].includes(task.status);
export function attentionAction(task, viewer = {}) {
  if (terminal(task)) return null;
  const mine = task.owner_kind === 'human' && task.assigned_bee_id === viewer.actorId;
  if (task.status === 'pending_review') {
    return viewer.canManage && !task.integration_required
      ? {reason: '等待你验收', label: '查看成果', section: 'results'} : null;
  }
  if (task.approval_required) return viewer.canManage
    ? {reason: '等待授权', label: '查看授权请求', section: 'execution'} : null;
  if (task.workflow?.phase === 'choosing') return viewer.canManage
    ? {reason: '等待你选择方案', label: '查看方案', section: 'overview'} : null;
  if (task.owner_kind === 'human' && !mine) return null;
  if (!viewer.canManage && !mine) return null;
  if (task.status === 'failed' || /心跳|无法确认/.test(task.next_step || '')) {
    return {reason: '执行状态待确认', label: '检查执行', section: 'execution'};
  }
  if (task.waiting_for === 'user') return {reason: '等待你答复', label: '查看问题', section: 'overview'};
  if (task.status === 'blocked') return {reason: '工作受阻', label: '查看阻塞', section: 'overview'};
  if (mine) return {reason: '由你负责', label: '处理工作', section: 'overview'};
  return null;
}

export function attentionWorks(tasks, viewer) {
  const byId = new Map(tasks.map(task => [task.id, task]));
  const result = new Map();
  for (const task of tasks) {
    if (!attentionAction(task, viewer)) continue;
    const parent = byId.get(task.parent_task_id || task.workflow_root);
    const visible = parent && !terminal(parent) ? parent : task;
    result.set(visible.id, visible);
  }
  return [...result.values()];
}

export function workAttention(task, tasks, viewer) {
  const direct = attentionAction(task, viewer);
  if (direct) return direct;
  const child = tasks.find(item => (item.parent_task_id === task.id || item.workflow_root === task.id) && attentionAction(item, viewer));
  return child ? {reason: '分工需要处理', label: '查看协作阻塞', section: 'collaboration'} : null;
}

export function pendingReviewHoney(tasks, honeys, attention, viewer) {
  if (!viewer.canManage) return [];
  const attentionIds = new Set(attention.map(task => task.id));
  return honeys.filter(honey => {
    const task = tasks.find(item => item.id === honey.task_id);
    return task && !terminal(task) && !task.integration_required && ['pending_review', 'auto_verified'].includes(honey.review_state) &&
      (!task.result || task.result === honey.id) && !attentionIds.has(task.id) &&
      !attentionIds.has(task.parent_task_id || task.workflow_root);
  });
}

const list = value => Array.isArray(value) ? value : [];
const text = value => typeof value === 'string' ? value : value?.text || value?.title || value?.description || '';
export function reviewModel(task, honey) {
  const current = Number.isInteger(task?.context_revision) ? task.context_revision : task ? 0 : null;
  const submitted = Number.isInteger(honey.work_revision) ? honey.work_revision : null;
  const revision = current == null || submitted == null ? 'unknown' : current === submitted ? 'matching' : 'changed';
  const checks = list(honey.review?.auto_checks ?? honey.checks).filter(check => check && typeof check === 'object');
  const criteria = list(task?.acceptance).map(text).filter(Boolean).map(criterion => {
    const related = checks.filter(check => (check.criterion || check.check) === criterion);
    const status = related.some(check => check.ok === false) ? 'failed'
      : related.length && related.every(check => check.ok === true) ? 'passed' : 'unverified';
    return {criterion, status, checks: related};
  });
  const used = new Set(criteria.flatMap(row => row.checks));
  const otherChecks = checks.filter(check => !used.has(check));
  const seen = new Set();
  const records = list(honey.evidence).filter(record => {
    const key = record?.id || (record?.seq != null ? `seq:${record.seq}` : null);
    if (!key) return true;
    if (seen.has(key)) return false;
    seen.add(key); return true;
  });
  return {revision, current, submitted, criteria, otherChecks, records,
    limitations: list(honey.limitations).map(text).filter(Boolean),
    gitRevision: typeof honey.git_revision === 'string' ? honey.git_revision : null};
}
