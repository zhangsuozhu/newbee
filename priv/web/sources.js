(() => {
  'use strict';
  const $ = id => document.getElementById(id);
  const sid = new URLSearchParams(location.search).get('session') || '';
  const modeLabels = {observe: '仅观察', explicit: '明确交办', auto: '自动规则'};
  const dispositionLabels = {observed: '仅观察', owned: '已接办', context_only: '仅作上下文', filtered: '已过滤', self_event: '自身回帖', paused: '已暂停', budget_exhausted: '达到执行上限'};
  const replyLabels = {pending: '等待发送', sent: '已发送', failed: '发送失败', sending: '发送中'};
  let sources = [], selected = null, loading = true, saving = false, dirty = false, recordsVersion = 0;
  const split = value => value.split(/[,，]/).map(v => v.trim()).filter(Boolean);
  const node = (tag, className, text) => {
    const item = document.createElement(tag);
    if (className) item.className = className;
    if (text != null) item.textContent = text;
    return item;
  };

  function message(text, error = false) {
    const host = $('message');
    host.textContent = text;
    host.hidden = !text;
    host.dataset.error = String(error);
    host.setAttribute('role', error ? 'alert' : 'status');
  }

  async function rpc(method, payload = {}) {
    let token = '';
    try { token = localStorage.getItem('newbee.token') || ''; } catch (_) {}
    const response = await fetch('/api/' + method, {
      method: 'POST',
      headers: {'content-type': 'application/json', ...(token ? {authorization: 'Bearer ' + token} : {})},
      body: JSON.stringify({rpcId: 'source-' + Date.now(), payload: {...payload, sessionId: sid}})
    });
    if (!response.ok) throw Error(response.status === 401 ? '请先返回原对话登录，再打开来源设置。' : '请求失败：' + response.status);
    const body = await response.json();
    const result = body.result || body;
    if (result.error) throw Error(result.error.message || result.error.code);
    return result.ok || {};
  }

  function updateForm() {
    const kind = $('kind').value;
    const mode = $('mode').value;
    document.querySelectorAll('[data-source-kind]').forEach(section => {
      const active = section.dataset.sourceKind === kind;
      section.hidden = !active || (section.id === 'webhook' && !selected);
      section.querySelectorAll('input').forEach(input => { input.disabled = !active; });
    });
    $('auto-fields').hidden = mode !== 'auto';
    $('prefix').required = mode === 'auto';
    $('events').required = mode === 'auto';
    $('actors').required = mode !== 'observe';
    $('repository').required = kind === 'github';
    $('kind').disabled = !!selected || saving || loading;
    $('repository').readOnly = !!selected;
    $('source').disabled = saving || loading;
    $('save').disabled = !sid || saving || loading;
    $('save').textContent = saving ? '正在保存…' : selected && dirty ? '保存更改' : '保存配置';
    $('repository-help').textContent = selected ? '此仓库已与项目绑定；接入其他仓库请新建来源。' : '只接收这个仓库的 Issue 和评论。';
    $('refresh').disabled = !selected || loading;
    const hints = {
      observe: '只记录收到的请求，不创建或执行工作。确认接入正常后，再开启执行。',
      explicit: kind === 'github' ? '允许的用户以 @newbee 或 /newbee 明确交办时，才会执行；已绑定工作的真人跟进会继续原工作。' : '只处理允许用户的明确交办；普通讨论和机器人消息不会发起工作。',
      auto: '仅处理允许用户发来的请求，并同时匹配下方的正文前缀和事件类型。'
    };
    $('mode-help').textContent = hints[mode];
    $('source-state').textContent = (dirty ? '未保存 · ' : '') + ($('paused').checked ? '已暂停' : modeLabels[mode]) + (selected ? '' : ' · 新来源');
    $('save-hint').textContent = $('paused').checked ? '保存后暂停此来源；已有工作请在原对话中处理。' : mode === 'observe' ? '先保存为观察模式，确认接入后再开启执行。' : '保存后按当前规则接办，仍受允许用户和执行上限约束。';
    $('limits-summary').textContent = '每小时 ' + $('budget').value + ' 项 · 间隔 ' + $('cooldown').value + ' 秒';
  }

  function emptyRecords(text = '保存来源后，先发送一条测试请求来检查接入。') {
    const empty = node('div', 'source-empty');
    empty.append(node('span', 'source-empty-icon', '↳'), node('strong', '', '还没有接入记录'), node('p', '', text));
    empty.firstChild.setAttribute('aria-hidden', 'true');
    $('records').replaceChildren(empty);
  }

  function fill(source) {
    selected = source || null;
    dirty = false;
    recordsVersion++;
    const c = source || {};
    const fields = {kind: c.kind || 'github', label: c.label || '', repository: c.repository || '', actors: (c.allowed_actors || []).join(', '), mode: c.mode || 'observe', prefix: c.auto_prefix || '', events: (c.allowed_event_types || []).join(', '), budget: c.max_per_hour || 2, cooldown: (c.cooldown_ms == null ? 60000 : c.cooldown_ms) / 1000, secret: c.secret_env || '', token: c.token_env || ''};
    for (const [key, value] of Object.entries(fields)) $(key).value = value;
    $('paused').checked = c.paused === true;
    $('project').textContent = c.root ? '绑定项目 · ' + c.root : '使用原对话选择的项目目录；保存后保持绑定。';
    const webhook = $('webhook');
    webhook.replaceChildren();
    if (c.kind === 'github') {
      webhook.append(node('strong', '', 'Webhook 地址'), node('code', '', location.origin + '/hooks/github/' + encodeURIComponent(c.id)), node('p', '', 'Content type 选择 application/json；订阅 Issues 和 Issue comments。'));
    }
    $('credentials').open = false;
    emptyRecords();
    updateForm();
  }

  async function load(preferred) {
    const result = await rpc('conversation.source.list');
    sources = result.sources || [];
    $('source').replaceChildren(new Option('新建来源', ''));
    for (const c of sources) $('source').add(new Option((c.label || c.repository || c.id) + ' · ' + (c.paused ? '已暂停' : modeLabels[c.mode] || c.mode), c.id));
    $('source').value = preferred || '';
    fill(sources.find(c => c.id === preferred));
  }

  async function records() {
    if (!selected) { emptyRecords(); return; }
    const point = selected.id;
    const version = ++recordsVersion;
    const result = await rpc('conversation.source.events', {sourceId: point});
    if (!selected || point !== selected.id || version !== recordsVersion) return;
    const host = $('records');
    host.replaceChildren();
    for (const event of result.events || []) {
      const row = node('article', 'source-record record');
      const top = node('div', 'source-record-top');
      top.append(node('span', 'source-record-badge', dispositionLabels[event.disposition] || event.disposition), node('span', '', event.actor || '来源事件'), node('span', '', event.event_type || event.external_id || ''));
      row.append(top, node('pre', '', event.text || event.reason || ''));
      const actions = node('div', 'source-record-actions');
      if (event.origin_session_id) {
        const link = node('a', '', '查看原工作对话');
        link.href = '/?session=' + encodeURIComponent(event.origin_session_id);
        actions.append(link);
      }
      if (['observed', 'paused', 'budget_exhausted'].includes(event.disposition)) {
        const replay = node('button', 'source-button', '按当前策略重新处理');
        replay.type = 'button';
        replay.onclick = async () => {
          replay.disabled = true;
          try { await rpc('conversation.source.replay', {sourceId: point, eventId: event.id}); await records(); }
          catch (error) { message(error.message, true); }
          finally { replay.disabled = false; }
        };
        actions.append(replay);
      }
      if (actions.childNodes.length) row.append(actions);
      host.append(row);
    }
    for (const reply of result.replies || []) {
      const row = node('article', 'source-record');
      row.append(node('p', '', '回复 · ' + (replyLabels[reply.status] || reply.status) + ' · 已尝试 ' + reply.attempts + ' 次'));
      if (reply.last_error) row.append(node('pre', '', reply.last_error));
      host.append(row);
    }
    if (!host.childNodes.length) emptyRecords('此来源还没有收到请求。观察模式下也会保留记录。');
  }

  $('back').href = sid ? '/?session=' + encodeURIComponent(sid) : '/';
  $('source').addEventListener('change', () => {
    message('');
    fill(sources.find(c => c.id === $('source').value));
    records().catch(error => message(error.message, true));
  });
  $('config').addEventListener('input', () => { dirty = true; updateForm(); });
  $('refresh').addEventListener('click', () => records().catch(error => message(error.message, true)));
  $('config').addEventListener('submit', async event => {
    event.preventDefault();
    if (!sid || saving || loading) return;
    saving = true;
    updateForm();
    const github = $('kind').value === 'github';
    const config = {kind: $('kind').value, label: $('label').value.trim(), repository: github ? $('repository').value.trim() : null, allowed_actors: split($('actors').value), mode: $('mode').value, auto_prefix: $('prefix').value, allowed_event_types: split($('events').value), max_per_hour: Number($('budget').value), cooldown_ms: Number($('cooldown').value) * 1000, paused: $('paused').checked, secret_env: github ? $('secret').value.trim() || null : null, token_env: github ? $('token').value.trim() || null : null};
    if (selected) { config.id = selected.id; config.revision = selected.revision; }
    try {
      const result = await rpc('conversation.source.configure', {config});
      await load(result.source.id);
      message(result.source.paused ? '配置已保存，此来源已暂停。' : result.source.mode === 'observe' ? '配置已保存。当前只观察，不会创建或执行工作。' : '配置已保存，将按当前规则接办请求。');
      await records();
    } catch (error) { message(error.message, true); }
    finally { saving = false; updateForm(); }
  });
  fill();
  if (!sid) {
    loading = false;
    updateForm();
    message('请从原项目对话打开来源设置，先选择工作目录。', true);
  } else {
    load().catch(error => message(error.message, true)).finally(() => { loading = false; updateForm(); });
  }
})();
