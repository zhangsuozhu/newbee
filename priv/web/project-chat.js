/* Project chat: persistent representatives (agents and humans), topic threads,
   directed @mentions and evidence-based proposals. */
(() => {
  "use strict";
  let current = null;
  const statusText = {open: "待讨论", independent: "独立评估中", discussing: "交叉讨论中", summarizing: "整理决议中", mention: "定向邀请中", proposed: "待验证方案", unresolved: "尚未解决", stopped: "已停止"};
  const activeStates = ["independent", "discussing", "summarizing", "mention"];
  function el(tag, cls, text) {
    const n = document.createElement(tag);
    if (cls) n.className = cls;
    if (text != null) n.textContent = String(text);
    return n;
  }
  function button(text, fn, cls = "") {
    const b = el("button", "pc-button " + cls, text); b.type = "button"; b.onclick = fn; return b;
  }
  function field(form, label, name, tag = "input", value = "") {
    const wrapper = el("label", "pc-field", label);
    const input = el(tag); input.name = name; input.value = value; wrapper.append(input); form.append(wrapper); return input;
  }
  function humanTime(value) { return new Date(value).toLocaleTimeString([], {hour: "2-digit", minute: "2-digit"}); }
  function deviceName(s, did) {
    if (!did) return "系统";
    if (did === "local") return "群主本机";
    if (did.startsWith("human:")) return "人类";
    return (s.group.devices || {})[did]?.display || did;
  }
  function repById(s, id) { return ((s.room && s.room.representatives) || []).find(r => r.id === id); }
  function repName(s, id) { return repById(s, id)?.name || id; }
  async function command(s, action, params = {}) {
    return s.rpc("xgroup.chat", {groupId: s.gid, action, params});
  }
  function fail(s, error) { s.error.textContent = error?.message || String(error); }
  async function mutate(s, action, params, after) {
    if (s.busy) return;
    s.busy = true; s.error.textContent = ""; s.dialog.setAttribute("aria-busy", "true");
    try { const value = await command(s, action, params); if (after) after(value); await refresh(s, true); }
    catch (e) { fail(s, e); }
    finally { s.busy = false; s.dialog.removeAttribute("aria-busy"); }
  }
  function showForm(s, title, build, action, params) {
    s.formHost.replaceChildren();
    const form = el("form", "pc-form"); form.append(el("h3", "", title));
    build(form);
    const actions = el("div", "pc-actions");
    const submit = el("button", "pc-button pc-primary", "保存"); submit.type = "submit";
    actions.append(submit, button("取消", () => s.formHost.replaceChildren())); form.append(actions);
    form.onsubmit = (e) => {
      e.preventDefault(); if (!form.reportValidity()) return;
      const data = Object.fromEntries(new FormData(form));
      mutate(s, action, params(data), (value) => { s.formHost.replaceChildren(); if (action === "topic.open") s.topicId = value.id; });
    };
    s.formHost.append(form); form.querySelector("input,textarea,select")?.focus();
  }
  function newTopic(s) {
    showForm(s, "发起项目议题", (form) => {
      const title = field(form, "议题标题", "title"); title.required = true; title.maxLength = 160;
      const problem = field(form, "目标、已尝试的方法、证据和需要大家决定的事", "problem", "textarea"); problem.required = true; problem.maxLength = 8000; problem.rows = 5;
      const tasks = field(form, "关联执行任务（可选）", "task_id", "select"); tasks.append(new Option("暂不关联", ""));
      (s.tasks || []).forEach(t => tasks.append(new Option(t.title || t.id, t.id)));
      field(form, "代码基线（完整Git提交SHA；应用决议时需要）", "base_revision").maxLength = 160;
    }, "topic.open", (d) => ({...d, task_id: d.task_id || null, base_revision: d.base_revision || null, command_id: s.formKey}));
    s.formKey = "topic-" + crypto.randomUUID();
  }
  function editRepresentative(s, rep) {
    showForm(s, rep ? "编辑代表" : "添加常驻代表", (form) => {
      if (!rep) {
        const kind = field(form, "类型", "kind", "select");
        kind.append(new Option("智能体代表（由模型发言）", "agent"), new Option("人类代表（我自己发言，不消耗模型调用）", "human"));
        const devices = field(form, "所属主机（每台最多6位；人类代表固定在群主本机）", "device_id", "select");
        devices.append(new Option("群主本机（不占用其它主机）", ""));
        Object.entries(s.group.devices || {}).forEach(([did, d]) => devices.append(new Option(d.display || did, did)));
        kind.onchange = () => { const human = kind.value === "human"; devices.disabled = human; devices.parentElement.style.display = human ? "none" : ""; };
      }
      field(form, "名字（留空随机）", "name", "input", rep?.name || "").maxLength = 40;
      field(form, "关注方向（留空分配互补职责）", "focus", "input", rep?.focus || "").maxLength = 200;
      field(form, "聊天风格（留空随机）", "style", "input", rep?.style || "").maxLength = 120;
      if (!rep || rep.kind !== "human") {
        field(form, "模型提供方（所在主机已配置的名称，可选）", "provider", "input", rep?.provider || "").maxLength = 160;
        field(form, "模型名称（留空使用所在主机advisor配置）", "model", "input", rep?.model || "").maxLength = 200;
      }
    }, rep ? "representative.update" : "representative.create", (d) => {
      const value = Object.fromEntries(Object.entries(d).filter(([, v]) => v.trim() !== ""));
      if (!rep) { value.kind = d.kind || "agent"; if (value.kind === "human") delete value.device_id; }
      if (rep) {
        value.representative_id = rep.id;
        if (rep.kind !== "human") { value.provider = d.provider.trim() || null; value.model = d.model.trim() || null; }
      }
      return value;
    });
  }
  function selectTopic(s, id) { s.topicId = id; s.replyTo = null; s.replyLabel.textContent = ""; render(s); refresh(s, true).catch(e => fail(s, e)); }
  function insertMention(s, rep) {
    const token = "@" + rep.name;
    const text = s.composer.value;
    s.composer.value = text.includes(token) ? text : (text ? text.replace(/\s*$/, " ") : "") + token + " ";
    s.composer.focus();
  }
  function mentionsOf(s) {
    const body = s.composer.value;
    return ((s.room && s.room.representatives) || [])
      .filter(r => r.enabled && body.includes("@" + r.name))
      .map(r => r.id).slice(0, 5);
  }


  function render(s) {
    const room = s.room;
    if (!room) return;
    const topic = (room.topics || []).find(t => t.id === s.topicId);
    const selected = new Set([...s.members.querySelectorAll("input:checked")].map(n => n.value));
    s.topics.replaceChildren(button("群聊动态", () => selectTopic(s, null), !topic ? "pc-selected" : ""));
    (room.topics || []).forEach(t => {
      const b = button(t.title, () => selectTopic(s, t.id), t.id === s.topicId ? "pc-selected" : "");
      b.append(el("small", "", statusText[t.status] || t.status)); s.topics.append(b);
    });
    s.members.replaceChildren();
    (room.representatives || []).forEach(rep => {
      const row = el("div", "pc-member");
      const label = el("label"); const check = el("input"); check.type = "checkbox"; check.value = rep.id;
      check.checked = selected.has(rep.id); check.disabled = !rep.available;
      label.append(check, document.createTextNode(rep.name + " · " + (rep.kind === "human" ? "人类代表" : deviceName(s, rep.device_id))));
      row.append(label, el("small", "", `${rep.available ? "● 可参与" : "○ 不可用"} · ${rep.focus} · ${rep.style}${rep.kind === "human" ? "" : " · " + (rep.model || "主机默认模型")}`));
      const controls = el("div", "pc-actions");
      controls.append(button("编辑", () => editRepresentative(s, rep)), button(rep.enabled ? "休息" : "启用", () => mutate(s, "representative.update", {representative_id: rep.id, enabled: !rep.enabled})));
      row.append(controls); s.members.append(row);
    });
    if (!(room.representatives || []).length) s.members.append(el("p", "pc-muted", "先添加代表。一台主机可以有多位，人类代表不消耗模型调用。"));
    s.topicTitle.textContent = topic?.title || "群聊动态";
    s.status.textContent = topic ? `${statusText[topic.status] || topic.status} · 第${topic.round || 0}轮 · 模型${topic.calls}/${topic.max_calls}次 · 省下${topic.skips || 0}次 · 人类回合${topic.waits || 0}次${(topic.usage && topic.usage.total_tokens) ? ` · ${topic.usage.total_tokens} tokens` : ""}` : "运行动态与公共交流 · 按议题讨论";
    const nearBottom = s.messages.scrollHeight - s.messages.scrollTop - s.messages.clientHeight < 70;
    s.messages.replaceChildren();
    const messages = (room.messages || []).filter(m => !topic || m.topic_id === topic.id);
    messages.forEach(m => {
      const card = el("article", "pc-message pc-kind-" + m.kind);
      const name = m.name || (m.kind === "human" ? "人类 / 会话" : m.kind === "topic" ? "议题发起" : m.kind === "skipped" ? "未发言" : "系统");
      card.append(el("div", "pc-message-meta", `${name} · ${deviceName(s, m.device_id)} · ${humanTime(m.created_at)}`));
      if (m.reply_to) card.append(el("small", "pc-muted", "回复 " + m.reply_to));
      card.append(el("div", "pc-message-body", m.body));
      if (m.mentions && m.mentions.length) card.append(el("div", "pc-mentions", "定向邀请：" + m.mentions.map(id => "@" + repName(s, id)).join(" ")));
      if (m.mention_all) card.append(el("div", "pc-mentions", "已向相关代表发起定向邀请（有上限）"));
      if (!topic && m.topic_id) card.append(button("打开议题", () => selectTopic(s, m.topic_id)));
      card.append(button("回复", () => { if (m.topic_id !== (s.topicId || null)) selectTopic(s, m.topic_id || null); s.replyTo = m.id; s.replyLabel.textContent = "回复 " + name + " · " + String(m.body).slice(0, 60); s.composer.focus(); }));
      s.messages.append(card);
    });
    if (!messages.length) s.messages.append(el("p", "pc-muted", "还没有消息。可以先发起一个具体议题，或分享一条项目观察。"));
    if (topic?.status === "independent") s.messages.append(el("p", "pc-notice", "成员正在分别评估；初步意见收集完成或超时后统一公开。"));
    // Human wait windows are visible and skippable so a person never stalls the room.
    (topic?.open_waits || []).forEach(wait => {
      const box = el("div", "pc-wait");
      box.append(el("span", "", `等待 ${wait.name || repName(s, wait.representative_id)} 发言（约 ${Math.max(0, Math.round((wait.deadline - Date.now()) / 1000))} 秒，超时自动继续）`));
      const local = wait.device_id === "local" || !s.group.remote;
      const skip = button("本轮不发言", () => mutate(s, "job.skip", {job_id: wait.job_id}));
      skip.disabled = !local; if (local) box.append(skip);
      s.messages.append(box);
    });
    if (topic && topic.open_mentions && topic.open_mentions.length) {
      s.messages.append(el("p", "pc-notice", "等待回应：" + topic.open_mentions.map(m => "@" + (m.name || repName(s, m.representative_id))).join(" ")));
    }
    if (nearBottom || s.lastTopic !== s.topicId) s.messages.scrollTop = s.messages.scrollHeight;
    s.lastTopic = s.topicId;
    s.discuss.disabled = !topic || activeStates.includes(topic.status);
    s.stop.disabled = !topic || !activeStates.includes(topic.status);
    // Identity and mention pickers: a human speaks as a named representative and can wake others.
    const humans = (room.representatives || []).filter(r => r.kind === "human" && r.enabled);
    const previousIdentity = s.identity.value;
    s.identity.replaceChildren(new Option("匿名人类发言（不署代表名）", ""));
    humans.forEach(r => s.identity.append(new Option("以 " + r.name + " 的身份发言", r.id)));
    if (humans.some(r => r.id === previousIdentity)) s.identity.value = previousIdentity;
    else if (humans.length === 1) s.identity.value = humans[0].id;
    s.picker.replaceChildren(el("span", "pc-muted", "定向邀请："));
    (room.representatives || []).filter(r => r.enabled).forEach(rep => {
      s.picker.append(button("@" + rep.name, () => insertMention(s, rep)));
    });
    s.picker.append(button("@all（最多5位）", () => { s.mentionAll.checked = !s.mentionAll.checked; s.mentionAllLabel.textContent = s.mentionAll.checked ? "发送时邀请最多5位可用代表" : "不邀请全体"; }), s.mentionAllLabel);
    s.decision.replaceChildren();
    if (topic?.decision) {
      const d = topic.decision;
      s.decision.append(el("h3", "", "决议草案 · v" + d.version), el("p", "pc-notice", "待验证：讨论共识不会自动标记为测试通过。"), el("div", "pc-message-body", d.body));
      s.decision.append(el("small", "", "任务：" + (d.task_id || "未关联") + " · 基线：" + (d.base_revision || "未指定")));
      const applied = (topic.applications || []).some(a => a.decision_id === d.id);
      const apply = button(applied ? "已提供给任务上下文" : "提供给执行任务", () => mutate(s, "decision.apply", {topic_id: topic.id, version: d.version, base_revision: d.base_revision}), "pc-primary");
      apply.disabled = applied || !d.task_id || !d.base_revision; s.decision.append(apply);
      s.decision.append(el("small", "pc-muted", "执行代理会在后续规划时核对代码基线；这里只提供建议，不直接运行命令。"));
    } else s.decision.append(el("p", "pc-muted", "讨论结束后在这里显示建议、依据、分歧和验证条件。"));
    s.auto.checked = room.auto_discuss === true; s.auto.disabled = !!s.group.remote;
  }
  async function refresh(s, force = false) {
    const seq = s.refreshSeq = (s.refreshSeq || 0) + 1;
    const requestedTopic = s.topicId;
    const room = await command(s, "snapshot", {topic_id: requestedTopic});
    if (current !== s || !s.dialog.open || seq !== s.refreshSeq || requestedTopic !== s.topicId) return;
    if (s.connectionError) { s.error.textContent = ""; s.connectionError = false; }
    if (force || !s.room || room.revision !== s.room.revision) { s.room = room; render(s); }
  }
  async function poll(s) {
    try { await refresh(s); } catch (e) { if (current === s) { s.connectionError = true; fail(s, e); } }
    if (current === s && s.dialog.open) s.timer = setTimeout(() => poll(s), 2000);
  }
  async function open(rpc, groupId) {
    if (current) current.dialog.close();
    const dialog = el("dialog", "pc-dialog"); dialog.setAttribute("aria-label", "项目聊天室");
    const s = {rpc, gid: groupId, dialog, topicId: null, replyTo: null, room: null, group: {}, busy: false}; current = s;
    const header = el("header", "pc-header"); s.title = el("h2", "", "项目聊天室");
    header.append(s.title, button("发起议题", () => newTopic(s), "pc-primary"), button("添加代表", () => editRepresentative(s)), button("关闭", () => dialog.close()));
    s.error = el("div", "pc-error"); s.error.setAttribute("role", "alert");
    s.formHost = el("div", "pc-form-host");
    const layout = el("div", "pc-layout");
    const left = el("aside", "pc-topics"); left.append(el("h3", "", "议题")); s.topics = el("nav"); s.topics.setAttribute("aria-label", "议题列表"); left.append(s.topics);
    const center = el("section", "pc-conversation");
    s.topicTitle = el("h3"); s.status = el("p", "pc-muted");
    const controls = el("div", "pc-actions");
    s.discuss = button("召集讨论", () => {
      const participants = [...s.members.querySelectorAll("input:checked")].map(n => n.value);
      mutate(s, "discussion.start", {topic_id: s.topicId, participants, rounds: Number(s.rounds.value)});
    }, "pc-primary");
    s.stop = button("停止讨论", () => mutate(s, "discussion.stop", {topic_id: s.topicId}));
    s.rounds = el("select"); s.rounds.setAttribute("aria-label", "交叉讨论轮次"); s.rounds.append(new Option("2轮交叉讨论", "2"), new Option("1轮交叉讨论", "1"));
    controls.append(s.discuss, s.stop, s.rounds);
    s.messages = el("div", "pc-messages"); s.messages.setAttribute("role", "log"); s.messages.setAttribute("aria-label", "聊天记录");
    const compose = el("form", "pc-compose");
    s.identity = el("select"); s.identity.className = "pc-identity"; s.identity.setAttribute("aria-label", "发言身份");
    s.picker = el("div", "pc-picker");
    s.mentionAll = el("input"); s.mentionAll.type = "checkbox"; s.mentionAll.className = "pc-mention-all";
    s.mentionAllLabel = el("span", "pc-muted", "不邀请全体");
    s.replyLabel = el("div", "pc-muted");
    s.composer = el("textarea"); s.composer.rows = 3; s.composer.maxLength = 4000; s.composer.required = true; s.composer.placeholder = "补充证据、提出问题，或用 @名字 邀请某位代表…"; s.composer.setAttribute("aria-label", "聊天消息");
    const send = el("button", "pc-button pc-primary", "发送"); send.type = "submit";
    compose.append(s.identity, s.picker, s.replyLabel, s.composer, send);
    compose.onsubmit = (e) => {
      e.preventDefault();
      const body = s.composer.value.trim(); if (!body) return;
      const key = s.messageKey || (s.messageKey = "message-" + crypto.randomUUID());
      const params = {topic_id: s.topicId, body, reply_to: s.replyTo, command_id: key, mentions: mentionsOf(s), mention_all: s.mentionAll.checked};
      if (s.identity.value) params.representative_id = s.identity.value;
      mutate(s, "message.post", params, () => {
        s.composer.value = ""; s.replyTo = null; s.replyLabel.textContent = "";
        s.messageKey = null; s.mentionAll.checked = false; s.mentionAllLabel.textContent = "不邀请全体";
      });
    };
    center.append(s.topicTitle, s.status, controls, s.messages, compose);
    const right = el("aside", "pc-sidebar"); right.append(el("h3", "", "常驻代表"), el("p", "pc-muted", "勾选2—5位；不勾选时默认分散选择3位。对话里用 @名字 可以只叫某一位；@all 最多展开5位。"));
    s.members = el("div", "pc-members"); s.decision = el("section", "pc-decision");
    const autoLabel = el("label", "pc-auto"); s.auto = el("input"); s.auto.type = "checkbox";
    s.auto.onchange = () => mutate(s, "settings", {auto_discuss: s.auto.checked});
    autoLabel.append(s.auto, document.createTextNode("任务阻塞时自动会诊（每小时最多3个议题）"));
    right.append(s.members, autoLabel, s.decision); layout.append(left, center, right);
    dialog.append(header, s.error, s.formHost, layout); document.body.append(dialog);
    const previousFocus = document.activeElement;
    dialog.addEventListener("close", () => { clearTimeout(s.timer); if (current === s) current = null; dialog.remove(); previousFocus?.focus(); });
    dialog.showModal();
    try {
      const details = await rpc("xgroup.get", {groupId: groupId});
      s.group = details.group || {}; s.tasks = details.tasks || []; s.title.textContent = (s.group.name || "项目") + " · 聊天室";
      await refresh(s, true); s.timer = setTimeout(() => poll(s), 2000);
    } catch (e) { fail(s, e); }
  }
  window.NewbeeProjectChat = {open};
})();

