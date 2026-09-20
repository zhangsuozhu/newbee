// One navigation shell. Tools open as their own original surfaces, with no extra wrapper.
import { rpc, toast, forgetAuthToken } from './api.js';
import { state, closeInspector } from './store.js';

const $ = id => document.getElementById(id);
let hostOwner = false, contextKey, infoSeq = 0, audio, cwdSaveSeq = 0;
let layer, frame, authResolve, locked = false;
let previousTasks = new Map(), taskBaseline = false;

const workspaceCwdKey = 'newbee.workspace.cwd';
export function selectedWorkspaceCwd(taskIdOverride = null) {
  const taskId = taskIdOverride || state.inspector?.taskId || state.drill?.task?.id;
  const task = taskId && (state.drill?.task?.id === taskId ? state.drill.task : (state.data?.tasks || []).find(item => item.id === taskId));
  if (typeof task?.cwd === 'string' && task.cwd.trim()) return task.cwd.trim();
  if (!taskId && !sessionId() && typeof state.data?.colony?.cwd === 'string' && state.data.colony.cwd.trim()) return state.data.colony.cwd.trim();
  try {
    const cwd = localStorage.getItem(workspaceCwdKey);
    return typeof cwd === 'string' && cwd.trim() ? cwd.trim() : null;
  } catch (_) {
    return null;
  }
}
function rememberWorkspaceCwd(cwd) {
  if (typeof cwd !== 'string' || !cwd.trim()) return;
  try { localStorage.setItem(workspaceCwdKey, cwd.trim()); } catch (_) {}
}

const sessionId = () => state.inspector?.sessionId || null;

// 终端与右侧栏都长在「当前打开的对话」里：没有对话不显示，非私有对话不开终端。
const panels = { sid: null, terminal: false, monitor: false };
const conversationVisibility = () => {
  const id = sessionId();
  if (!id) return null;
  const entry = state.inspector?.conversation;
  return entry ? entry.visibility || 'private' : 'work';
};
function syncThemeFrames() {
  const theme = document.documentElement.dataset.theme;
  for (const target of [document.getElementById('workspace-frame'), document.getElementById('embed-frame')]) {
    try { if (target?.contentWindow) target.contentWindow.postMessage({newbeeTheme:theme}, location.origin); } catch (_) {}
  }
}

function bindThemeFrame(frame) {
  if (frame && frame.dataset.themeBound !== '1') {
    frame.dataset.themeBound = '1';
    frame.addEventListener('load', () => {
      syncThemeFrames();
      if (layer && !layer.hidden) frame.focus({preventScroll:true});
    });
  }
}

function postPanel(panel) {
  const frame = $('embed-frame');
  if (!frame || !frame.contentWindow) return toast('对话还没打开，稍后再试', true);
  frame.contentWindow.postMessage({newbeeCommand:'panel', panel, open: panels[panel], sessionId: sessionId(), inspectionId: state.inspector?.inspectionId}, location.origin);
}
// 成员层级里给 AI 成员打字：宿主把这句话转进它的内嵌对话。
// iframe 刚挂上时它可能还没绑定会话，postMessage 会被丢掉，所以带 commandId 重发直到它回执；
// 回执 + 幂等判断保证同一句话不会发两遍。
let pendingSend = null;
export function sendIntoConversation(text) {
  const sid = sessionId();
  if (!sid) return Promise.reject(new Error('请先打开目标执行会话'));
  if (pendingSend) return Promise.reject(new Error('上一条指导尚未确认，请稍后再发'));
  const commandId = crypto.randomUUID();
  return new Promise((resolve, reject) => {
    const entry = {commandId, sid, inspectionId: state.inspector.inspectionId, text, tries: 0, timer: null, resolve, reject};
    pendingSend = entry;
    const fail = message => {
      clearInterval(entry.timer); if (pendingSend === entry) pendingSend = null;
      reject(new Error(message));
    };
    const attempt = () => {
      if (sessionId() !== sid || state.inspector?.inspectionId !== entry.inspectionId) return fail('已切换执行会话，未确认的指导保留在原草稿中');
      if (++entry.tries > 80) return fail('未收到提交确认，请先检查执行记录，避免重复发送；草稿已保留');
      const win = $('embed-frame')?.contentWindow;
      if (win && state.inspector?.status === 'ready') {
        win.postMessage({newbeeCommand:'send', text, commandId, sessionId:sid, inspectionId: entry.inspectionId}, location.origin);
      }
    };
    entry.timer = setInterval(attempt, 350);
    attempt();
  });
}

function syncPanelButtons()
 {
  const sid = sessionId();
  const local = sid && conversationVisibility() === 'private';
  $('terminal-toggle').classList.toggle('hidden', !hostOwner || !local);
  $('mc-expand').classList.toggle('hidden', !hostOwner || !sid);
  const terminalOpen = !!panels.terminal, monitorOpen = !!panels.monitor;
  $('terminal-toggle').classList.toggle('is-active', terminalOpen);
  $('terminal-toggle').setAttribute('aria-expanded', String(terminalOpen));
  $('terminal-toggle').title = terminalOpen ? '关闭终端' : '打开终端';
  $('terminal-toggle').setAttribute('aria-label', $('terminal-toggle').title);
  $('mc-expand').classList.toggle('is-active', monitorOpen);
}
export function toggleConversationPanel(panel) {
  if (!sessionId()) return toast('请先打开一个 AI 对话', true);
  if (panel === 'terminal' && conversationVisibility() !== 'private') return toast('终端只在私有对话里可用', true);
  panels[panel] = !panels[panel];
  postPanel(panel);
  syncPanelButtons();
}

export function collapseSidebar(collapsed, persist = true) {
  const active = document.activeElement;
  const sidebar = $('sidebar');
  const focusExpand = collapsed && (active?.id === 'sidebar-toggle' || sidebar?.contains(active));
  const focusToggle = !collapsed && active?.id === 'sidebar-expand';
  $('app').classList.toggle('sidebar-collapsed', collapsed);
  $('sidebar-expand').classList.toggle('hidden', !collapsed);
  $('sidebar-toggle').setAttribute('aria-expanded', String(!collapsed));
  // 侧栏收起时整体在屏幕外：里面的控件如果还能 Tab 到，键盘用户会停在一个看不见的按钮上
  // （实测 #sidebar-toggle 在 left:-72、#model-config-btn 在 left:-110 时仍可聚焦）。
  // inert 会把整棵子树移出 Tab 顺序与无障碍树，展开时再恢复。
  if (sidebar) {
    sidebar.inert = collapsed;
    if (collapsed) sidebar.setAttribute('aria-hidden', 'true');
    else sidebar.removeAttribute('aria-hidden');
  }
  if (persist) localStorage.setItem('newbee.sidebar', collapsed ? '1' : '0');
  if (focusExpand) $('sidebar-expand')?.focus({preventScroll:true});
  if (focusToggle) $('sidebar-toggle')?.focus({preventScroll:true});
}

function ensureLayer() {
  if (layer) return;
  layer = document.createElement('div');
  layer.id = 'workspace-layer';
  layer.hidden = true;
  layer.innerHTML = '<iframe id="workspace-frame" title="newbee 功能"></iframe>';
  document.body.appendChild(layer);
  frame = layer.querySelector('#workspace-frame');
  bindThemeFrame(frame);
  window.addEventListener('keydown', event => {
    if (event.key === 'Escape' && !layer.hidden && !locked) closeWorkspace();
  });
}
function closeWorkspace() {
  if (!layer || layer.hidden || locked) return;
  layer.hidden = true;
  frame.src = 'about:blank';
  locked = false;
  refreshWorkspaceInfo();
}
export function openWorkspace(surface, taskIdOverride = null) {
  if (surface !== 'auth' && !hostOwner) return toast('成员身份不能管理宿主环境', true);
  ensureLayer();
  locked = surface === 'auth';
  const params = new URLSearchParams({embed:'1', surface});
  if (surface !== 'auth' && surface !== 'qr' && surface !== 'config' && sessionId()) params.set('session', sessionId());
  if (surface === 'directory') {
    const taskId = taskIdOverride || state.drill?.task?.id;
    const cwd = selectedWorkspaceCwd(taskId);
    if (cwd) params.set('cwd', cwd);
    if (taskId && !sessionId()) params.set('task', taskId);
  }
  const qk = new URLSearchParams(location.search).get('qk');
  if (surface === 'auth' && qk) params.set('qk', qk);
  frame.src = '/workspace.html?' + params;
  layer.hidden = false;
}
export async function ensureAuthenticated() {
  const qk = new URLSearchParams(location.search).has('qk');
  let auth;
  try { auth = qk ? null : await rpc('auth.status'); } catch (error) { if (error.code !== 'unauthorized') throw error; }
  if (!auth || (auth.auth_required && !auth.authenticated)) {
    await new Promise(resolve => { authResolve = resolve; openWorkspace('auth'); });
    const url = new URL(location.href); url.searchParams.delete('qk');
    history.replaceState(null, '', url.pathname + url.search + url.hash);
    auth = await rpc('auth.status');
  }
  hostOwner = auth.host_owner !== false;
  ['model-config-btn','qa-show'].forEach(id => $(id).classList.toggle('hidden', !hostOwner));
  syncPanelButtons();
  $('logout-btn').classList.toggle('hidden', !localStorage.getItem('newbee.token'));
  void refreshWorkspaceInfo();
}
export async function refreshWorkspaceInfo() {
  const request = ++infoSeq, sid = sessionId();
  contextKey = sid || '';
  if (!hostOwner) {
    $('cwd-label').textContent = '蜂群成员';
    $('model-label').textContent = '人和 AI，一起工作';
    return;
  }
  try {
    const [host, models, info] = await Promise.all([rpc('host.describe'), rpc('llm.models', {sessionId:sid}, {timeoutMs:10000}), sid ? rpc('session.state',{sessionId:sid}) : Promise.resolve(null)]);
    if (request !== infoSeq) return;
    const current = models.current || {};
    $('model-label').textContent = current.model ? [current.provider, current.model].filter(Boolean).join('/') : '选择模型';
    $('model-label').title = sid ? '点击切换当前 AI 对话的模型' : '点击选择环境默认模型（新 AI 使用）';
    const cwd = info?.cwd || (sid ? null : selectedWorkspaceCwd() || state.data?.colony?.cwd) || host.cwd || '';
    $('cwd-label').textContent = cwd;
    $('cwd-label').title = sid ? '当前执行会话工作目录：' + cwd : state.drill?.task?.cwd ? '当前工作目录：' + cwd : '当前蜂群默认工作目录：' + cwd;
  } catch (error) { toast(error.message, true); }
}
function soundUI() {
  const enabled = localStorage.getItem('newbee.sound') !== 'off';
  $('sound-toggle').title = enabled ? '关闭提示音' : '开启提示音';
  $('sound-toggle').setAttribute('aria-label', $('sound-toggle').title);
  $('sound-toggle').setAttribute('aria-pressed', String(enabled));
  $('sound-toggle').classList.toggle('is-muted', !enabled);
}
function beep() {
  if (localStorage.getItem('newbee.sound') === 'off') return;
  try {
    audio ||= new (window.AudioContext || window.webkitAudioContext)();
    audio.resume();
    const tone = audio.createOscillator(), gain = audio.createGain();
    tone.connect(gain); gain.connect(audio.destination);
    tone.frequency.value = 660; gain.gain.setValueAtTime(.035, audio.currentTime);
    gain.gain.exponentialRampToValueAtTime(.001, audio.currentTime + .18);
    tone.start(); tone.stop(audio.currentTime + .2);
  } catch (_) {}
}
export function updateWorkspaceContext() {
  const sid = sessionId();
  if (!sid) {
    const cwd = selectedWorkspaceCwd() || state.data?.colony?.cwd;
    if (cwd) {
      $('cwd-label').textContent = cwd;
      $('cwd-label').title = state.drill?.task?.cwd ? '当前工作目录：' + cwd : '当前蜂群默认工作目录：' + cwd;
    }
  }
  // 换对话 = 关掉上一个对话的面板，两个面板都属于那条对话。
  if (panels.sid !== sid) { panels.sid = sid; panels.terminal = false; panels.monitor = false; }
  if (contextKey !== (sid || '')) refreshWorkspaceInfo();
  syncPanelButtons();
  const tasks = new Map((state.data?.tasks || []).map(task => [task.id, task.status]));
  if (taskBaseline && [...tasks].some(([id,status]) => ['pending_review','done','failed','blocked'].includes(status) && previousTasks.get(id) !== status)) beep();
  previousTasks = tasks; taskBaseline = true;
}
export function initShell() {
  window.NewbeeTheme?.init();
  bindThemeFrame($('embed-frame'));
  window.addEventListener('newbee:theme', syncThemeFrames);
  syncThemeFrames();
  collapseSidebar(matchMedia('(max-width: 768px)').matches || localStorage.getItem('newbee.sidebar') === '1', false);
  $('sidebar-toggle').onclick = () => collapseSidebar(true);
  $('sidebar-expand').onclick = () => collapseSidebar(false);
  $('model-label').onclick = () => openWorkspace('models');
  $('model-config-btn').onclick = () => openWorkspace('config');
  $('cwd-label').onclick = () => openWorkspace('directory');
  $('qa-show').onclick = () => openWorkspace('qr');
  $('terminal-toggle').onclick = () => toggleConversationPanel('terminal');
  $('mc-expand').onclick = () => toggleConversationPanel('monitor');
  $('sound-toggle').onclick = () => { localStorage.setItem('newbee.sound', localStorage.getItem('newbee.sound') === 'off' ? 'on' : 'off'); soundUI(); beep(); };
  soundUI();
  $('logout-btn').onclick = async () => {
    try { await rpc('auth.logout'); } catch (_) {}
    forgetAuthToken(); location.assign('/');
  };
  document.addEventListener('click', event => {
    if (matchMedia('(max-width: 768px)').matches && event.target.closest('#main') && !$('app').classList.contains('sidebar-collapsed')) collapseSidebar(true, false);
  });
  const mobileMq = matchMedia('(max-width: 768px)');
  mobileMq.addEventListener('change', e => {
    if (e.matches) {
      if (!$('app').classList.contains('sidebar-collapsed')) collapseSidebar(true, false);
    } else if (localStorage.getItem('newbee.sidebar') !== '1') {
      collapseSidebar(false, false);
    }
  });
  window.addEventListener('keydown', event => {
    if (layer && !layer.hidden) return;
    const modalOpen = document.querySelector('dialog[open], .modal:not(.hidden), #qa-overlay:not(.hidden), #login-overlay:not(.hidden), #cmd-palette:not(.hidden)');
    if (event.key === 'Escape' && matchMedia('(max-width: 768px)').matches &&
        !$('app').classList.contains('sidebar-collapsed') && !modalOpen &&
        !event.target?.closest?.('dialog')) {
      event.preventDefault();
      event.stopImmediatePropagation();
      collapseSidebar(true);
      return;
    }
    if ((event.ctrlKey || event.metaKey) && event.key.toLowerCase() === 'm') { event.preventDefault(); toggleConversationPanel('monitor'); }
    if ((event.ctrlKey || event.metaKey) && event.key.toLowerCase() === 'n') { event.preventDefault(); $('new-colony').click(); }
  });
  window.addEventListener('message', event => {

    if (event.origin !== location.origin) return;
    const isTool = frame && event.source === frame.contentWindow;
    const isConversation = event.source === $('embed-frame')?.contentWindow;
    if (!isTool && !isConversation) return;
    const message = event.data || {};
    if (isConversation && message.sessionId && message.sessionId !== sessionId()) return;
    if (isConversation && message.inspectionId && message.inspectionId !== state.inspector?.inspectionId) return;

    if (message.newbeeWorkspace === 'changed') {
      if (!sessionId() && typeof message.cwd === 'string' && message.cwd.trim()) {
        const cwd = message.cwd.trim();
        const taskId = typeof message.taskId === 'string' ? message.taskId : null;
        const listedTask = taskId && (state.data?.tasks || []).find(item => item.id === taskId);
        const task = taskId && (state.drill?.task?.id === taskId ? state.drill.task : listedTask);
        if (task && state.colonyId && state.data?.can_manage && task.cwd !== cwd) {
          const previousTask = {...task};
          const previousListedTask = listedTask && listedTask !== task ? {...listedTask} : null;
          const saveSeq = ++cwdSaveSeq;
          const saveColonyId = state.colonyId;
          const restore = (target, snapshot) => {
            if (!target || !snapshot) return;
            Object.keys(target).forEach(key => { if (!(key in snapshot)) delete target[key]; });
            Object.assign(target, snapshot);
          };
          const applyTask = value => {
            Object.assign(task, value);
            if (listedTask) Object.assign(listedTask, value);
            $('cwd-label').textContent = value.cwd || '';
            $('cwd-label').title = value.cwd ? '当前工作目录：' + value.cwd : '当前工作目录';
          };
          const optimistic = {...task, cwd, revision: (task.revision || 0) + 1, context_revision: (task.context_revision || 0) + 1};
          if (typeof task.workspace_source === 'string') optimistic.workspace_source = cwd;
          applyTask(optimistic);
          void rpc('colony.work.cwd', {colonyId: saveColonyId, taskId, cwd}).then(result => {
            if (saveSeq !== cwdSaveSeq || state.colonyId !== saveColonyId) return;
            applyTask(result.task || {cwd});
            toast(`这项工作的工作目录已设为 ${result.task?.cwd || cwd}`);
          }).catch(error => {
            if (saveSeq !== cwdSaveSeq || state.colonyId !== saveColonyId) return;
            restore(task, previousTask);
            restore(listedTask, previousListedTask);
            refreshWorkspaceInfo();
            toast(error.message || '保存工作目录失败', true);
          });
        } else if (task && !state.data?.can_manage) {
          toast('当前工作目录需要蜂群管理权限', true);
        } else if (!task) {
          rememberWorkspaceCwd(cwd);
          const colony = state.data?.colony;
          if (state.colonyId && state.data?.can_manage && colony?.cwd !== cwd) {
            const previousCwd = colony?.cwd;
            const saveSeq = ++cwdSaveSeq;
            const saveColonyId = state.colonyId;
            if (colony?.id === saveColonyId) {
              colony.cwd = cwd;
              $('cwd-label').textContent = cwd;
              $('cwd-label').title = '当前蜂群默认工作目录：' + cwd;
            }
            void rpc('colony.cwd', {colonyId: saveColonyId, cwd}).then(result => {
              if (saveSeq !== cwdSaveSeq || state.colonyId !== saveColonyId) return;
              if (state.data?.colony?.id === saveColonyId) state.data.colony.cwd = result.colony.cwd;
              rememberWorkspaceCwd(result.colony.cwd);
              toast(`蜂群默认工作目录已设为 ${result.colony.cwd}`);
            }).catch(error => {
              if (saveSeq !== cwdSaveSeq || state.colonyId !== saveColonyId) return;
              if (state.data?.colony?.id === saveColonyId) {
                state.data.colony.cwd = previousCwd || '';
                try { previousCwd ? localStorage.setItem(workspaceCwdKey, previousCwd) : localStorage.removeItem(workspaceCwdKey); } catch (_) {}
              }
              refreshWorkspaceInfo();
              toast(error.message || '保存工作目录失败', true);
            });
          }
        }
        refreshWorkspaceInfo();
      }
    }
    if (isConversation && message.newbeeWorkspace === 'panel') {
      panels[message.panel] = !!message.open;
      syncPanelButtons();
    }
    if (isConversation && message.newbeeWorkspace === 'closed') {
      panels.terminal = false;
      panels.monitor = false;
      closeInspector();
      syncPanelButtons();
      return;
    }
    if (isConversation && message.newbeeWorkspace === 'ready' && (panels.terminal || panels.monitor)) {
      // 对话界面刚就绪：把宿主已打开的面板补发一次，避免点太快丢指令。
      if (panels.terminal) postPanel('terminal');
      if (panels.monitor) postPanel('monitor');
    }
    if (isConversation && message.newbeeWorkspace === 'sent') {
      // 对话已回执：停止重发，避免同一句话发两遍。
      if (pendingSend && pendingSend.commandId === message.commandId && pendingSend.inspectionId === message.inspectionId) {
        const entry = pendingSend;
        clearInterval(entry.timer);
        pendingSend = null;
        if (message.status === 'accepted') { entry.resolve(message); toast(message.message || '已收到，等待执行器处理'); }
        else entry.reject(new Error(message.message || '指导未提交，草稿已保留'));
      }
    }


    if (!isTool) return;
    if (message.newbeeWorkspace === 'authenticated') {
      locked = false;
      layer && (layer.hidden = true);
      frame.src = 'about:blank';
      if (authResolve) { const resolve = authResolve; authResolve = null; resolve(); }
      else location.reload();
    }
    if (message.newbeeWorkspace === 'closed') closeWorkspace();
    if (message.newbeeWorkspace === 'error') toast(message.message || '打开失败', true);
  });
}