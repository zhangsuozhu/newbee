// One navigation shell. Tools open as their own original surfaces, with no extra wrapper.
import { rpc, toast } from './api.js';
import { state } from './store.js';

const $ = id => document.getElementById(id);
let hostOwner = false, contextKey, infoSeq = 0, audio;
let layer, frame, authResolve, locked = false;
let previousTasks = new Map(), taskBaseline = false;

const sessionId = () => state.mode === 'bee' && state.view === 'conversation' ? state.conversationId : null;

// 终端与右侧栏都长在「当前打开的对话」里：没有对话不显示，非私有对话不开终端。
const panels = { sid: null, terminal: false, monitor: false };
const conversationVisibility = () => {
  const id = sessionId();
  if (!id) return null;
  const entry = ((state.trail && state.trail.conversations) || []).find(c => c.id === id);
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
    frame.addEventListener('load', syncThemeFrames);
  }
}

function postPanel(panel) {
  const frame = $('embed-frame');
  if (!frame || !frame.contentWindow) return toast('对话还没打开，稍后再试', true);
  frame.contentWindow.postMessage({newbeeCommand:'panel', panel, open: panels[panel], sessionId: sessionId()}, location.origin);
}
function syncPanelButtons() {
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
  $('app').classList.toggle('sidebar-collapsed', collapsed);
  $('sidebar-expand').classList.toggle('hidden', !collapsed);
  $('sidebar-toggle').setAttribute('aria-expanded', String(!collapsed));
  if (persist) localStorage.setItem('newbee.sidebar', collapsed ? '1' : '0');
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
export function openWorkspace(surface) {
  if (surface !== 'auth' && !hostOwner) return toast('成员身份不能管理宿主环境', true);
  ensureLayer();
  locked = surface === 'auth';
  const params = new URLSearchParams({embed:'1', surface});
  if (surface !== 'auth' && surface !== 'qr' && surface !== 'config' && sessionId()) params.set('session', sessionId());
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
    const cwd = info?.cwd || host.cwd || '';
    $('cwd-label').textContent = cwd;
    $('cwd-label').title = (sid ? '当前 AI 工作目录：' : '当前环境目录：') + cwd;
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
  // 换对话 = 关掉上一个对话的面板，两个面板都属于那条对话。
  if (panels.sid !== sid) { panels.sid = sid; panels.terminal = false; panels.monitor = false; }
  if (contextKey !== (sid || '')) refreshWorkspaceInfo();
  syncPanelButtons();
  const tasks = new Map((state.data?.tasks || []).map(task => [task.id, task.status]));
  if (taskBaseline && [...tasks].some(([id,status]) => ['awaiting_review','succeeded','failed','awaiting_input'].includes(status) && previousTasks.get(id) !== status)) beep();
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
    localStorage.removeItem('newbee.token'); location.assign('/');
  };
  document.addEventListener('click', event => {
    if (matchMedia('(max-width: 768px)').matches && event.target.closest('#main') && !$('app').classList.contains('sidebar-collapsed')) collapseSidebar(true, false);
  });
  window.addEventListener('keydown', event => {
    if (layer && !layer.hidden) return;
    if ((event.ctrlKey || event.metaKey) && event.key.toLowerCase() === 'm') { event.preventDefault(); toggleConversationPanel('monitor'); }
    if ((event.ctrlKey || event.metaKey) && event.key.toLowerCase() === 'n') { event.preventDefault(); $('new-colony').click(); }
  });
  window.addEventListener('message', event => {
    if (event.origin !== location.origin) return;
    const isTool = frame && event.source === frame.contentWindow;
    const isConversation = event.source === $('embed-frame')?.contentWindow;
    if (!isTool && !isConversation) return;
    const message = event.data || {};
    if (message.newbeeWorkspace === 'changed') refreshWorkspaceInfo();
    if (isConversation && message.newbeeWorkspace === 'panel') {
      panels[message.panel] = !!message.open;
      syncPanelButtons();
    }
    if (isConversation && message.newbeeWorkspace === 'ready' && (panels.terminal || panels.monitor)) {
      // 对话界面刚就绪：把宿主已打开的面板补发一次，避免点太快丢指令。
      if (panels.terminal) postPanel('terminal');
      if (panels.monitor) postPanel('monitor');
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