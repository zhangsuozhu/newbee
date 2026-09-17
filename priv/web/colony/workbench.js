// Work stays in the main region; execution inspection has its own explicit input scope.
import { state, memberById, currentTaskId, closeInspector, openConversation, openHome, attentionTasks } from './store.js';
import { statusLabel } from './util.js';
import { buildTaskCard } from './taskcard.js';
import { honeyNode } from './chat.js';
import { prefill } from './composer.js';
import { toast } from './api.js';

export function renderAttention(flow, ctx) {
  const heading = document.createElement('h2'); heading.textContent = '需要处理'; flow.append(heading);
  const tasks = attentionTasks();
  const pending = (state.data?.honey?.recent || []).filter(h => ['pending_review', 'auto_verified'].includes(h.review_state) && !(state.data?.tasks || []).some(t => t.integration_required && t.id === h.task_id));
  for (const honey of pending) flow.append(honeyNode({type: 'honey', text: honey.title, ts: honey.created_at, data: {honey_id: honey.id}}, ctx));
  if (!tasks.length && !pending.length) {
    const empty = document.createElement('p'); empty.className = 'work-summary';
    empty.textContent = '暂时没有需要处理的工作。普通执行进展不会占用这里。'; flow.append(empty);
  }
  for (const task of tasks) flow.append(buildTaskCard(task, ctx, {full: true}));
}

let ctxRef, inspector, frame, previousFocus, activeSession = null, activeInspection = null, readyTimer;
const positions = new Map();
let mainLocation = null;
function mainKey() { return JSON.stringify([state.colonyId, state.view, state.groupTab, state.stack]); }
export function rememberReadingPosition() {
  const key = mainKey(), transcript = document.getElementById('transcript');
  if (mainLocation && mainLocation !== key && transcript) positions.set(mainLocation, transcript.scrollTop);
  const changed = mainLocation !== key;
  mainLocation = key;
  return changed ? positions.get(key) : undefined;
}
function post(command, payload = {}) {
  if (!state.inspector || activeSession !== state.inspector.sessionId) return;
  frame?.contentWindow?.postMessage({newbeeCommand: command, sessionId: activeSession, inspectionId: activeInspection, ...payload}, location.origin);
}
function button(label, action) {
  const node = document.createElement('button'); node.type = 'button'; node.className = 'btn-ghost';
  node.textContent = label; node.onclick = action; return node;
}
function guide() {
  if (state.inspector?.status !== 'ready') return;
  state.inspector.guiding = true;
  post('guide');
  renderInspector();
}
function close() {
  // 关闭检查只收起辅助面板，工作路由、当前详情分区和阅读位置都由 store 保留。
  closeInspector();
  setTimeout(() => {
    const saved = previousFocus && previousFocus !== document.body && previousFocus !== document.documentElement && previousFocus.isConnected
      ? previousFocus : null;
    const target = saved || document.querySelector('.drill-tabs button[aria-selected="true"]') || document.getElementById('transcript') || document.getElementById('main');

    target?.focus({preventScroll: true});
  }, 0);

}

export function initWorkbench(ctx) {
  ctxRef = ctx;
  const main = document.getElementById('main');
  const body = document.createElement('div'); body.id = 'work-body';
  const primary = document.createElement('section'); primary.id = 'work-primary'; primary.setAttribute('aria-label', '当前工作');
  const transcript = document.getElementById('transcript');
  main.insertBefore(body, transcript);
  body.append(primary);
  for (const id of ['review-bar', 'transcript', 'composer']) {
    const node = document.getElementById(id); if (node) primary.append(node);
  }
  inspector = document.getElementById('embed-host');
  inspector.classList.remove('embed-host'); inspector.classList.add('execution-inspector');
  inspector.setAttribute('role', 'region'); inspector.setAttribute('aria-label', '执行检查');
  body.append(inspector);
  frame = document.getElementById('embed-frame');
  frame.title = '执行记录与指导';
  const head = document.createElement('div'); head.className = 'inspector-head';
  head.innerHTML = '<div class="inspector-kicker">执行会话</div><h2 id="inspector-title" tabindex="-1"></h2><p id="inspector-owner"></p>';
  const actions = document.createElement('div'); actions.className = 'inspector-actions';
  const guideButton = button('指导这只 Bee', guide); guideButton.id = 'inspector-guide';
  const quote = button('引用选中内容到本工作', () => post('quote')); quote.id = 'inspector-quote';
  const expand = button('展开', () => {
    const expanded = body.classList.toggle('inspector-expanded');
    primary.inert = expanded;
    expand.textContent = expanded ? '恢复分栏' : '展开'; expand.setAttribute('aria-expanded', String(expanded));
  });
  expand.id = 'inspector-expand';
  actions.append(guideButton, quote, button('复制链接', async () => {
    try { await navigator.clipboard.writeText(location.href); toast('已复制执行链接'); }
    catch (_) { toast('复制失败，可以复制浏览器地址栏中的链接', true); }
  }), expand, button('关闭检查', close));
  head.append(actions);
  const status = document.createElement('div'); status.id = 'inspector-status'; status.setAttribute('role', 'status');
  inspector.prepend(head, status);
  const banner = document.createElement('div'); banner.id = 'route-notice'; banner.hidden = true;
  banner.setAttribute('role', 'status'); main.insertBefore(banner, body);
  document.addEventListener('keydown', event => {
    if (event.key === 'Escape' && !event.defaultPrevented && !document.querySelector('dialog[open]') && state.inspector) {
      if (event.target.closest('textarea, input, [contenteditable=true]')) return;
      event.preventDefault(); close();
    }
    if ((event.ctrlKey || event.metaKey) && event.key.toLowerCase() === 'k') {
      event.preventDefault(); showQuickOpen();
    }
  });
  window.addEventListener('message', event => {
    if (event.origin !== location.origin || event.source !== frame.contentWindow) return;
    const message = event.data || {}, current = state.inspector;
    if (!current || message.sessionId !== current.sessionId || message.inspectionId !== current.inspectionId) return;
    if (message.newbeeWorkspace === 'session-ready') {
      clearTimeout(readyTimer); current.status = 'ready'; current.error = null;
      renderInspector();
    } else if (message.newbeeWorkspace === 'guidance') {
      current.guiding = !!message.enabled; renderInspector();
    } else if (message.newbeeWorkspace === 'session-error') {
      clearTimeout(readyTimer);
      const attempts = current.restoreAttempts || 0;
      if (attempts < 2 && !['unauthorized', 'forbidden', 'not_found'].includes(message.code)) {
        current.restoreAttempts = attempts + 1;
        current.status = 'connecting'; current.error = null;
        current.inspectionId = crypto.randomUUID();
        activeSession = null; activeInspection = null; frame.src = 'about:blank';
        renderInspector();
      } else {
        current.status = 'error'; current.error = message.message || '无法恢复执行会话';
        renderInspector();
      }
    } else if (message.newbeeWorkspace === 'close-inspector') {
      close();
    } else if (message.newbeeWorkspace === 'quote') {
      if (!message.text?.trim()) { toast('请先在执行记录中选择要引用的内容'); return; }
      if (!currentTaskId()) { toast('请先从一项工作打开执行会话，再引用到该工作'); return; }
      const text = String(message.text).slice(0, 8000);
      prefill(`引用「${current.title}」· ${memberById(current.beeId)?.display || 'Bee'}\n会话 ${current.sessionId}${message.recordId ? ' · 记录 ' + message.recordId : ''}\n> ${text.replace(/\n/g, '\n> ')}\n\n`);
      document.getElementById('work-body').classList.remove('inspector-expanded');
      document.getElementById('work-primary').inert = false;
      if (matchMedia('(max-width: 1000px)').matches) closeInspector();
      document.getElementById('input')?.focus();
    }
  });
  frame.addEventListener('load', () => {
    if (state.inspector?.sessionId === activeSession) post('inspect-status');
  });
}
export function renderInspector() {
  if (!inspector) return;
  const notice = document.getElementById('route-notice');
  if (notice.dataset.message !== (state.routeNotice || '')) {
    notice.dataset.message = state.routeNotice || ''; notice.replaceChildren();
    notice.hidden = !state.routeNotice;
    if (state.routeNotice) notice.append(document.createTextNode(state.routeNotice), button('关闭提示', () => { state.routeNotice = ''; renderInspector(); }));
  }
  const current = state.inspector, body = document.getElementById('work-body');
  inspector.classList.toggle('hidden', !current);
  body.classList.toggle('has-inspector', !!current);
  const primary = document.getElementById('work-primary');
  primary.inert = !!current && (body.classList.contains('inspector-expanded') || matchMedia('(max-width: 1000px)').matches);
  if (!current) {
    clearTimeout(readyTimer);
    body.classList.remove('inspector-expanded');
    const expand = document.getElementById('inspector-expand');
    if (expand) { expand.textContent = '展开'; expand.setAttribute('aria-expanded', 'false'); }
    if (activeSession) { activeSession = null; activeInspection = null; frame.src = 'about:blank'; delete frame.dataset.src; }
    return;
  }
  const title = document.getElementById('inspector-title'); title.textContent = current.title;
  const bee = memberById(current.beeId);
  document.getElementById('inspector-owner').textContent = `${current.guiding ? '发给' : '正在查看'}：${bee?.display || 'Bee'} · ${current.taskId ? '关联工作：' + ((state.data?.tasks || []).find(t => t.id === current.taskId)?.title || current.title) : '独立会话'}${current.guiding ? ' · 此处输入只指导该会话' : ' · 不改变主输入区的发送对象'}`;
  document.getElementById('inspector-guide').disabled = current.status !== 'ready';
  document.getElementById('inspector-guide').textContent = current.guiding ? '继续指导这只 Bee' : '指导这只 Bee';
  document.getElementById('inspector-quote').disabled = current.status !== 'ready' || !currentTaskId();
  const status = document.getElementById('inspector-status');
  const message = current.status === 'ready' ? '' : current.status === 'error' ? current.error : current.status === 'loading' ? `正在确认「${current.title}」的归属…` : `正在恢复「${current.title}」的消息与连接…`;
  if (status.dataset.message !== message) {
    status.dataset.message = message; status.replaceChildren(document.createTextNode(message || ''));
    if (current.status === 'error') status.append(button('重试', () => {
      current.restoreAttempts = 0;
      activeSession = null; activeInspection = null; frame.src = 'about:blank'; openConversation(current.sessionId, current.beeId);
    }));
  }
  status.hidden = !message;
  frame.hidden = current.status === 'loading' || current.status === 'error';
  if (current.status === 'connecting' && activeInspection !== current.inspectionId) {
    if (!inspector.contains(document.activeElement)) previousFocus = document.activeElement;
    activeSession = current.sessionId; activeInspection = current.inspectionId;
    frame.src = `/workspace.html?session=${encodeURIComponent(current.sessionId)}&embed=1&inspect=1&inspectionId=${encodeURIComponent(activeInspection)}`;
    clearTimeout(readyTimer);
    const sid = activeSession, inspectionId = activeInspection;
    readyTimer = setTimeout(() => {
      const current = state.inspector;
      if (!current || current.sessionId !== sid || current.inspectionId !== inspectionId || current.status !== 'connecting') return;
      const attempts = current.restoreAttempts || 0;
      if (attempts < 2) {
        current.restoreAttempts = attempts + 1; current.inspectionId = crypto.randomUUID();
        activeSession = null; activeInspection = null; frame.src = 'about:blank'; renderInspector();
      } else {
        current.status = 'error'; current.error = '恢复尚未完成，请重试；原工作与草稿已保留。'; renderInspector();
      }
    }, 20000);
    title.focus({preventScroll: true});
  }
}
export function showQuickOpen() {
  if (document.getElementById('work-quick-open')) return;
  const previous = document.activeElement, dialog = document.createElement('dialog');
  dialog.id = 'work-quick-open'; dialog.className = 'colony-dialog';
  const input = document.createElement('input'); input.placeholder = '查找工作或成员…'; input.setAttribute('aria-label', '查找工作或成员');
  const list = document.createElement('div'); list.className = 'work-quick-results';
  const render = () => {
    const query = input.value.trim().toLowerCase(); list.replaceChildren();
    const items = [
      {title: '需要处理', action: () => openHome('attention')},
      {title: '群聊', action: () => openHome('messages')},
      ...(state.data?.tasks || []).map(t => ({title: t.title, detail: statusLabel(t.status), action: () => ctxRef.openTask(t.id, t.title)})),
      ...(state.data?.members || []).map(b => ({title: b.display, detail: '成员', action: () => ctxRef.enterBeeMode(b.id)})),
    ].filter(x => (x.title || '').toLowerCase().includes(query)).slice(0, 30);
    for (const item of items) list.append(button(`${item.title} ${item.detail || ''}`, () => { dialog.close(); item.action(); }));
    if (!items.length) list.textContent = '没有匹配的工作或成员';
  };
  input.oninput = render;
  input.onkeydown = event => { if (event.key === 'Enter' && !event.isComposing) { event.preventDefault(); list.querySelector('button')?.click(); } };
  dialog.append(input, list, button('关闭', () => dialog.close()));
  dialog.onclose = () => { dialog.remove(); if (previous?.isConnected) previous.focus({preventScroll: true}); };
  document.body.append(dialog); render(); dialog.showModal(); input.focus();
}
