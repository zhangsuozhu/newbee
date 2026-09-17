import { state, currentTaskId, memberById, enterBeeMode, openHome, pushPath } from './store.js';
export function renderBreadcrumbs() {
  const title = document.getElementById('session-title'), sub = document.getElementById('session-sub');
  if (!title) return;
  title.tabIndex = -1;
  const taskId = currentTaskId();
  const task = state.drill?.task || (state.data?.tasks || []).find(t => t.id === taskId);
  const bee = state.beeModeId ? memberById(state.beeModeId) : null;
  const homeTitle = state.workFilter === 'attention' ? '待我处理' : state.workFilter === 'finished' ? '已完成' : '进行中';
  title.textContent = taskId ? task?.title || '正在打开工作…' : state.view === 'dm' ? bee?.display || '成员' : state.groupTab === 'messages' ? '群聊' : homeTitle;
  if (!sub) return;
  sub.replaceChildren();
  const add = (label, action) => {
    const node = document.createElement(action ? 'button' : 'span');
    node.className = action ? 'btn-ghost crumb' : 'crumb'; node.textContent = label;
    if (action) { node.type = 'button'; node.onclick = action; }
    sub.append(node);
  };
  add(state.data?.colony?.name || '蜂群', () => openHome('work'));
  add(' / ');
  if (taskId) {
    const parent = (state.data?.tasks || []).find(t => t.id === task?.parent_task_id);
    const sourceBeeId = state.stack.find(entry => entry.type === 'drill')?.fromBeeId;
    const sourceBee = sourceBeeId && memberById(sourceBeeId);
    if (parent) add(`返回工作「${parent.title}」`, () => pushPath({type: 'drill', taskId: parent.id, title: parent.title}));
    else if (sourceBee) add(`返回成员「${sourceBee.display}」`, () => enterBeeMode(sourceBee.id));
    else add('返回工作列表', () => openHome('work'));
    const owner = memberById(task?.assigned_bee_id);
    if (owner) add(` · 负责人：${owner.display}`);
  } else add(state.view === 'dm' ? '成员概览' : title.textContent);
}
