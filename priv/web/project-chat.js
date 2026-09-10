/* Project chat: persistent representatives (agents and humans), topic threads,
   directed @mentions and evidence-based proposals.
   Layout: 议题栏 / 对话区 / 代表与决议栏；窄屏折叠为单列 + 抽屉。
   只用 textContent 构建 DOM（契约测试要求：不使用原始 HTML 字符串）。 */
(() => {
  "use strict";
  let current = null;
  // ── 文案：把内部状态翻译成用户语言 ─────────────────────────────────────
  const STATUS = {
    open: { text: "待讨论", hint: "议题已建立，点「召集讨论」让代表们开始评估", cls: "idle" },
    independent: { text: "独立评估中", hint: "代表们在各自评估，意见收齐或超时后统一公开", cls: "run" },
    discussing: { text: "交叉讨论中", hint: "代表们在互相回应，通常 1—2 轮", cls: "run" },
    summarizing: { text: "整理决议中", hint: "有一位代表在把讨论整理成决议草案", cls: "run" },
    mention: { text: "定向邀请中", hint: "只有被点名的代表在回应", cls: "run" },
    proposed: { text: "已有决议草案", hint: "草案可提供给执行任务（需要关联任务与代码基线）", cls: "done" },
    unresolved: { text: "未形成结论", hint: "讨论结束但没有可用结论，可以重新开启", cls: "warn" },
    stopped: { text: "已停止", hint: "讨论被停止，已产生的消息和决议会保留", cls: "stop" }
  };
  const PHASES = [["independent", "独立评估"], ["discussing", "交叉讨论"], ["summarizing", "整理决议"]];
  const ACTIVE = ["independent", "discussing", "summarizing", "mention"];
  const KIND_LABEL = { human: "人类发言", topic: "议题发起", skipped: "未发言", notice: "通知", execution: "执行反馈", error: "出错", summary: "决议草案" };

  const el = (tag, cls, text) => {
    const n = document.createElement(tag);
    if (cls) n.className = cls;
    if (text != null) n.textContent = String(text);
    return n;
  };
  const button = (text, fn, cls = "", title = "") => {
    const b = el("button", "pc-button " + cls, text);
    b.type = "button"; b.onclick = fn; if (title) b.title = title;
    return b;
  };
  const field = (form, label, name, tag = "input", value = "") => {
    const wrapper = el("label", "pc-field", label);
    const input = el(tag); input.name = name; input.value = value; wrapper.append(input); form.append(wrapper); return input;
  };
  const humanTime = (value) => { try { return new Date(value).toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" }); } catch (e) { return ""; } };
  const shortBody = (text, n) => {
    const s = String(text == null ? "" : text).replace(/\s+/g, " ").trim();
    return s.length > n ? s.slice(0, n) + "…" : s;
  };
  const deviceName = (s, did) => {
    if (!did || did === "system") return "";
    if (did === "local") return "群主本机";
    if (String(did).startsWith("human:")) return "人类";
    return ((s.group.devices || {})[did] || {}).display || did;
  };
  const repById = (s, id) => ((s.room && s.room.representatives) || []).find((r) => r.id === id);
  const repName = (s, id) => (repById(s, id) || {}).name || id;
  const topicOf = (s) => ((s.room && s.room.topics) || []).find((t) => t.id === s.topicId) || null;
  const statusOf = (t) => STATUS[(t && t.status) || "open"] || STATUS.open;
  const kindOf = (m) => m.kind || "human";
  const authorName = (s, m) => m.name || KIND_LABEL[kindOf(m)] || "消息";

  async function command(s, action, params = {}) { return s.rpc("xgroup.chat", { groupId: s.gid, action, params }); }
  function fail(s, error) { s.error.textContent = (error && (error.message || error.hint)) || String(error); s.error.hidden = false; }
  function clearError(s) { s.error.textContent = ""; s.error.hidden = true; }
  async function mutate(s, action, params, after) {
    if (s.busy) return null;
    s.busy = true; clearError(s); s.dialog.setAttribute("aria-busy", "true");
    try {
      const value = await command(s, action, params);
      if (after) after(value);
      await refresh(s, true);
      return value;
    } catch (e) { fail(s, e); return null; }
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
    s.formHost.append(form);
    const first = form.querySelector("input,textarea,select");
    if (first) first.focus();
  }
  function newTopic(s) {
    showForm(s, "发起议题", (form) => {
      const title = field(form, "议题标题", "title"); title.required = true; title.maxLength = 160;
      title.placeholder = "一句话说清要决定什么，例如：订单状态机以哪一版为准";
      const problem = field(form, "背景：目标、已试过的方法、证据、需要大家决定的事", "problem", "textarea");
      problem.required = true; problem.maxLength = 8000; problem.rows = 5;
      problem.placeholder = "写清事实和证据，代表们才不会重复问；越具体，结论越可用。";
      const tasks = field(form, "关联执行任务（可选；决议要交给任务执行时再填）", "task_id", "select");
      tasks.append(new Option("暂不关联", ""));
      (s.tasks || []).forEach((t) => tasks.append(new Option(t.title || t.id, t.id)));
      const base = field(form, "代码基线（完整 Git 提交 SHA；应用决议时需要）", "base_revision");
      base.maxLength = 160; base.placeholder = "例如 50686be…";
    }, "topic.open", (d) => ({ ...d, task_id: d.task_id || null, base_revision: d.base_revision || null, command_id: s.formKey }));
    s.formKey = "topic-" + crypto.randomUUID();
  }
  function editRepresentative(s, rep) {
    showForm(s, rep ? "编辑代表" : "添加代表", (form) => {
      if (!rep) {
        const kind = field(form, "类型", "kind", "select");
        kind.append(new Option("智能体代表（由模型发言）", "agent"), new Option("人类代表（我自己发言，不消耗模型调用）", "human"));
        const devices = field(form, "所属主机（每台最多 6 位；人类代表固定在群主本机）", "device_id", "select");
        devices.append(new Option("群主本机（不占用其它主机）", ""));
        Object.entries(s.group.devices || {}).forEach(([did, d]) => devices.append(new Option(d.display || did, did)));
        kind.onchange = () => {
          const human = kind.value === "human";
          devices.disabled = human;
          devices.parentElement.hidden = human;
        };
      }
      field(form, "名字（留空随机）", "name", "input", (rep && rep.name) || "").maxLength = 40;
      field(form, "关注方向（留空自动分配互补职责）", "focus", "input", (rep && rep.focus) || "").maxLength = 200;
      field(form, "聊天风格（留空随机）", "style", "input", (rep && rep.style) || "").maxLength = 120;
      if (!rep || rep.kind !== "human") {
        field(form, "模型提供方（所在主机已配置的名称，可选）", "provider", "input", (rep && rep.provider) || "").maxLength = 160;
        field(form, "模型名称（留空用所在主机的 advisor 配置）", "model", "input", (rep && rep.model) || "").maxLength = 200;
      }
    }, rep ? "representative.update" : "representative.create", (d) => {
      const value = Object.fromEntries(Object.entries(d).filter(([, v]) => String(v).trim() !== ""));
      if (!rep) { value.kind = d.kind || "agent"; if (value.kind === "human") delete value.device_id; }
      if (rep) {
        value.representative_id = rep.id;
        if (rep.kind !== "human") { value.provider = String(d.provider || "").trim() || null; value.model = String(d.model || "").trim() || null; }
      }
      return value;
    });
  }
  async function quickRepresentatives(s) {
    if (s.busy) return;
    s.busy = true; clearError(s);
    try {
      for (let i = 0; i < 3; i += 1) await command(s, "representative.create", {});
      await refresh(s, true);
    } catch (e) { fail(s, e); }
    finally { s.busy = false; }
  }
  function selectTopic(s, id, repForReply) {
    s.topicId = id; s.replyTo = null;
    s.replyLabel.replaceChildren();
    if (repForReply && s.identity) s.identity.value = repForReply;
    render(s); refresh(s, true).catch((e) => fail(s, e));
  }
  function insertMention(s, rep) {
    const token = "@" + rep.name;
    const text = s.composer.value;
    s.composer.value = text.includes(token) ? text : (text ? text.replace(/\s*$/, " ") : "") + token + " ";
    s.composer.focus(); syncSend(s);
  }
  function mentionsOf(s) {
    const body = s.composer.value;
    return ((s.room && s.room.representatives) || [])
      .filter((r) => r.enabled && body.includes("@" + r.name))
      .map((r) => r.id).slice(0, 5);
  }
  function syncSend(s) {
    const empty = !s.composer.value.trim();
    s.send.disabled = empty;
    s.send.title = empty ? "先写点什么：补充证据、提问，或用 @名字 邀请某位代表" : "发送（Ctrl+Enter）";
  }
  function selectedReps(s) {
    return [...s.selected].filter((id) => { const r = repById(s, id); return r && r.enabled && r.available; });
  }

  // ── 头部 ─────────────────────────────────────────────────────────────
  function renderHeader(s, room, topic) {
    s.title.textContent = (s.group.name || "项目") + " · 聊天室";
    s.headerStatus.replaceChildren();
    if (!topic) {
      s.headerStatus.append(el("span", "pc-chip idle", "全部动态"));
      const n = (room.topics || []).length;
      s.headerStatus.append(el("span", "pc-header-hint", n ? n + " 个议题 · 选一个开始讨论" : "还没有议题，先发起一个"));
    } else {
      const st = statusOf(topic);
      const chip = el("span", "pc-chip " + st.cls, st.text);
      chip.title = st.hint;
      s.headerStatus.append(chip);
      const repCount = selectedReps(s).length;
      s.headerStatus.append(el("span", "pc-header-hint",
        "第 " + (topic.round || 0) + " 轮 · 参与 " + (repCount || "默认 3") + " 位"));
      s.headerStatus.append(el("span", "pc-header-hint", st.hint));
    }
    s.sideBtn.textContent = "代表 " + ((room.representatives || []).length || "0");
    s.sideBtn.setAttribute("aria-expanded", s.dialog.classList.contains("pc-show-side") ? "true" : "false");
  }
  function renderPhases(s, topic) {
    s.phases.replaceChildren();
    if (!topic) { s.phases.hidden = true; return; }
    s.phases.hidden = false;
    const key = topic.status === "mention" ? "discussing" : topic.status;
    const idx = PHASES.findIndex(([k]) => k === key);
    PHASES.forEach(([, label], i) => {
      const step = el("div", "pc-phase" + (idx < 0 ? (topic.status === "open" ? "" : " done") : (i < idx ? " done" : i === idx ? " current" : "")));
      step.append(el("i", "pc-phase-dot"), el("span", "", label));
      s.phases.append(step);
      if (i < PHASES.length - 1) s.phases.append(el("span", "pc-phase-line"));
    });
    const done = topic.status === "proposed" || topic.status === "unresolved";
    const final = el("div", "pc-phase" + (done ? " done" : (idx >= 0 && idx === PHASES.length - 1 ? " current" : "")));
    final.append(el("i", "pc-phase-dot"), el("span", "", "决议"));
    s.phases.append(el("span", "pc-phase-line"), final);
  }

  // ── 左栏：议题 ───────────────────────────────────────────────────────
  function renderTopics(s, room, topic) {
    s.topics.replaceChildren();
    const all = button("全部动态", () => selectTopic(s, null), !topic ? "pc-selected" : "");
    all.title = "按时间看所有议题的消息";
    s.topics.append(all);
    (room.topics || []).forEach((t) => {
      const st = statusOf(t);
      const b = button("", () => selectTopic(s, t.id), t.id === s.topicId ? "pc-selected" : "");
      b.append(el("span", "pc-topic-name", t.title), el("small", "pc-topic-state " + st.cls, st.text));
      b.title = t.title + " · " + st.text;
      if (t.id === s.topicId) b.setAttribute("aria-current", "true");
      s.topics.append(b);
    });

  }

  // ── 中栏：消息 ───────────────────────────────────────────────────────
  function topicTitle(room, id) {
    const t = (room.topics || []).find((x) => x.id === id);
    return t ? t.title : "议题";
  }
  function messageCard(s, m, opts) {
    const kind = kindOf(m);
    const card = el("article", "pc-message pc-kind-" + kind);
    card.dataset.messageId = m.id;
    const meta = el("div", "pc-message-meta");
    meta.append(el("span", "pc-message-who", authorName(s, m)));
    const dev = deviceName(s, m.device_id);
    if (dev && kind !== "notice" && kind !== "error") meta.append(el("span", "pc-message-dev", dev));
    meta.append(el("span", "pc-message-time", humanTime(m.created_at)));
    if (!opts.topicScoped && m.topic_id) {
      const chip = button(shortBody(topicTitle(s.room, m.topic_id), 18), () => selectTopic(s, m.topic_id), "pc-topic-chip");
      chip.title = "打开议题：" + topicTitle(s.room, m.topic_id);
      meta.append(chip);
    }
    if (kind === "error") meta.append(el("span", "pc-chip err", "调用失败"));
    card.append(meta);
    if (m.reply_to) {
      const src = (s.byId || {})[m.reply_to];
      const line = el("div", "pc-reply-line");
      line.append(el("span", "pc-reply-tag", "回复 " + (src ? authorName(s, src) : "某条消息")));
      if (src) {
        const quote = el("span", "pc-reply-quote", shortBody(src.body, 60));
        quote.title = "跳到这条消息";
        quote.onclick = () => {
          const node = s.messageList.querySelector('[data-message-id="' + src.id + '"]');
          if (node) {
            node.classList.add("pc-flash");
            node.scrollIntoView({ block: "center", behavior: "smooth" });
            setTimeout(() => node.classList.remove("pc-flash"), 1200);
          }
        };
        line.append(quote);
      }
      card.append(line);
    }
    card.append(el("div", "pc-message-body", m.body));
    if (m.mentions && m.mentions.length) card.append(el("div", "pc-mentions", "定向邀请：" + m.mentions.map((id) => "@" + repName(s, id)).join(" ")));
    if (m.mention_all) card.append(el("div", "pc-mentions", "已邀请全体可用代表（最多 5 位）"));
    if (kind === "error") {
      if (opts.canRetry) {
        const actions = el("div", "pc-actions");
        const retry = button("重新发起讨论", () => {
          if (m.topic_id && m.topic_id !== s.topicId) selectTopic(s, m.topic_id);
          setTimeout(() => { if (!s.discuss.disabled) s.discuss.click(); }, 80);
        }, "pc-primary", "用同样的代表再发起一次讨论");
        retry.disabled = !m.topic_id;
        actions.append(retry);
        card.append(el("div", "pc-hint", "失败通常来自本机模型配置或网络；修好后可以从这个议题重新开始。"), actions);
      } else {
        card.append(el("div", "pc-hint", "同类失败已经合并显示在上面那条。"));
      }
    } else {
      const actions = el("div", "pc-actions pc-msg-actions");
      actions.append(button("回复", () => {
        if (m.topic_id !== (s.topicId || null)) selectTopic(s, m.topic_id || null);
        s.replyTo = m.id;
        s.replyLabel.replaceChildren(
          el("span", "pc-reply-tag", "回复 " + authorName(s, m) + "：" + shortBody(m.body, 40)),
          button("取消", () => { s.replyTo = null; s.replyLabel.replaceChildren(); }, "pc-mini")
        );
        s.composer.focus();
      }, "pc-mini"));
      if (!opts.topicScoped && m.topic_id) actions.append(button("打开议题", () => selectTopic(s, m.topic_id), "pc-mini"));
      card.append(actions);
    }
    return card;
  }
  function waitCard(s, wait, topic) {
    const box = el("div", "pc-wait");
    const name = wait.name || repName(s, wait.representative_id);
    const left = el("span", "pc-wait-left");
    box.append(el("span", "pc-wait-icon", "✋"), el("span", "pc-wait-who", "等待 " + name + " 发言"));
    if (topic) box.append(el("span", "pc-wait-topic", shortBody(topic.title, 16)));
    box.append(left);
    const local = wait.device_id === "local" || !s.group.remote;
    if (local) {
      box.append(button("我来发言", () => {
        s.identity.value = wait.representative_id;
        s.composer.focus(); syncSend(s);
      }, "pc-primary", "以这位代表的身份写一条消息"), button("本轮不发言", () => {
        if (!window.confirm("跳过这一轮？议题会继续，之后仍可以补发消息。")) return;
        mutate(s, "job.skip", { job_id: wait.job_id });
      }, "", "标记为跳过并让讨论继续"));
    } else {
      box.append(el("span", "pc-muted", "在代表所在机器上回复"));
    }
    s.waitNodes.push({ node: left, deadline: wait.deadline });
    return box;
  }
  function emptyCard(s, topic) {
    const box = el("div", "pc-empty");
    if (!(s.room.representatives || []).length) {
      box.append(el("h4", "", "先请几位代表入席"),
        el("p", "pc-muted", "代表就是替你把问题想透的人：智能体由模型发言，人类代表是你自己。"));
      const actions = el("div", "pc-actions");
      actions.append(button("一键添加 3 位智能体代表", () => quickRepresentatives(s), "pc-primary", "按互补职责各来一位，之后可以改名或休息"));
      actions.append(button("我自己挑", () => editRepresentative(s)));
      box.append(actions);
    } else if (!(s.room.topics || []).length) {
      box.append(el("h4", "", "发起第一个议题"),
        el("p", "pc-muted", "把要决定的事写清楚：目标、已试过什么、有哪些证据。代表们会先各自评估，再交叉讨论，最后给一份带依据的草案。"));
      box.append(button("发起议题", () => newTopic(s), "pc-primary"));
    } else {
      box.append(el("h4", "", "这个议题还没有消息"),
        el("p", "pc-muted", "可以先补充事实，或点「召集讨论」让代表们开始。"));
    }
    return box;
  }
  function renderMessages(s, room, topic) {
    const messages = (room.messages || []).filter((m) => !topic || m.topic_id === topic.id);
    s.byId = {};
    messages.forEach((m) => { s.byId[m.id] = m; });
    const scoped = !!topic;
    const nearBottom = s.messages.scrollHeight - s.messages.scrollTop - s.messages.clientHeight < 80;
    const lastError = {};
    messages.forEach((m) => { if (kindOf(m) === "error" && m.topic_id) lastError[m.topic_id] = m.id; });
    const seenError = {};
    const shown = messages.filter((m) => {
      if (kindOf(m) !== "error") return true;
      const key = String(m.topic_id || "") + "|" + String(m.body || "").trim();
      if (seenError[key]) return false;
      seenError[key] = true;
      return true;
    });
    const ids = shown.map((m) => m.id);
    const isPrefix = s.renderedIds.length > 0 && s.renderedIds.length <= ids.length && s.renderedIds.every((id, i) => id === ids[i]);
    if (!isPrefix) { s.messageList.replaceChildren(); s.renderedIds = []; }
    if (!shown.length) {
      if (!s.messageList.firstElementChild || !s.messageList.firstElementChild.classList.contains("pc-empty")) {
        s.messageList.replaceChildren(emptyCard(s, topic));
      }
    } else {
      const empty = s.messageList.querySelector(".pc-empty");
      if (empty) empty.remove();
      shown.slice(s.renderedIds.length).forEach((m) =>
        s.messageList.append(messageCard(s, m, { topicScoped: scoped, canRetry: lastError[m.topic_id] === m.id })));
    }
    s.renderedIds = ids;
    // 等待回合单独放在消息流末尾，并标注所属议题
    s.waitHost.replaceChildren();
    s.waitNodes = [];
    const waits = [];
    (room.topics || []).forEach((t) => {
      if (topic && t.id !== topic.id) return;
      (t.open_waits || []).forEach((w) => waits.push([w, t]));
    });
    if (waits.length) {
      s.waitHost.append(el("div", "pc-section-line", "等待发言"));
      waits.forEach(([w, t]) => s.waitHost.append(waitCard(s, w, t)));
      s.waitHost.hidden = false;
    } else {
      s.waitHost.hidden = true;
    }
    if (topic && ACTIVE.includes(topic.status)) {
      const n = el("p", "pc-notice pc-run-notice");
      n.append(el("span", "pc-spin"), el("span", "", statusOf(topic).hint));
      s.waitHost.append(n);
      s.waitHost.hidden = false;
    }
    if (nearBottom || s.lastTopic !== s.topicId) s.messages.scrollTop = s.messages.scrollHeight;
    s.lastTopic = s.topicId;
  }

  // ── 右栏 ─────────────────────────────────────────────────────────────
  function renderMembers(s, room) {
    s.members.replaceChildren();
    const reps = room.representatives || [];
    if (!reps.length) {
      s.members.append(el("p", "pc-muted", "还没有代表。点下面的按钮，一键请 3 位智能体代表入席。"));
      s.members.append(button("一键添加 3 位代表", () => quickRepresentatives(s), "pc-primary"));
    }
    reps.forEach((rep) => {
      const row = el("div", "pc-member");
      const label = el("label");
      const check = el("input"); check.type = "checkbox"; check.value = rep.id;
      check.checked = s.selected.has(rep.id); check.disabled = !rep.available;
      if (!rep.available) check.title = rep.kind === "human" ? "已休息：启用后可参与" : "所在主机离线或已暂停";
      check.onchange = () => {
        if (check.checked) s.selected.add(rep.id); else s.selected.delete(rep.id);
        saveSelection(s);
        renderMembers(s, s.room);
        renderHeader(s, s.room, topicOf(s));
      };
      label.append(check, el("span", "pc-member-name", rep.name), el("span", "pc-member-kind", rep.kind === "human" ? "人类" : "智能体"));
      row.append(label);
      row.append(el("small", "pc-member-meta", (rep.available ? "" : "当前不可用 · ") + (rep.focus || "")));
      const actions = el("div", "pc-actions");
      actions.append(button("编辑", () => editRepresentative(s, rep), "pc-mini"),
        button(rep.enabled ? "休息" : "启用", () => mutate(s, "representative.update", { representative_id: rep.id, enabled: !rep.enabled }), "pc-mini",
          rep.enabled ? "暂时不让这位参与讨论" : "恢复参与"));
      row.append(actions);
      s.members.append(row);
    });
    s.members.append(el("p", "pc-muted pc-member-note", "勾选只影响下一次「召集讨论」；不勾选时默认从不同主机挑 3 位可用代表。"));
    const autoLabel = el("label", "pc-auto");
    s.auto.checked = room.auto_discuss === true;
    s.auto.disabled = !!s.group.remote;
    autoLabel.append(s.auto, document.createTextNode("任务卡住时自动开会诊（每小时最多 3 个议题）"));
    if (s.group.remote) autoLabel.title = "远端群的设置请在群主一侧修改";
    s.members.append(autoLabel);
  }
  function renderDecision(s, room, topic) {
    s.decision.replaceChildren();
    if (!topic || !topic.decision) {
      s.decision.append(el("h3", "", "决议草案"));
      s.decision.append(el("p", "pc-muted", topic ? "讨论结束后，这里会出现建议、依据、分歧和验证条件。" : "选中一个议题后，这里显示它的决议草案。"));
      return;
    }
    const d = topic.decision;
    s.decision.append(el("h3", "", "决议草案 · v" + d.version));
    s.decision.append(el("div", "pc-message-body pc-decision-body", d.body));
    s.decision.append(el("small", "pc-decision-facts", "任务：" + (d.task_id || "未关联") + " · 代码基线：" + (d.base_revision || "未指定")));
    if (!d.task_id || !d.base_revision) s.decision.append(el("p", "pc-hint", "要交给任务执行，需要在发起议题时关联任务并写清 Git 提交 SHA。"));
    const applied = (topic.applications || []).some((a) => a.decision_id === d.id);
    const apply = button(applied ? "已提供给执行任务 ✓" : "提供给执行任务", () => {
      const ok = window.confirm("把这份决议（v" + d.version + "）作为建议数据提供给任务：\n"
        + (d.task_id || "未关联") + "\n代码基线：" + (d.base_revision || "未指定")
        + "\n\n它只是建议数据，不会运行任何命令；执行时由代理按现有权限重新核对。");
      if (!ok) return;
      mutate(s, "decision.apply", { topic_id: topic.id, version: d.version, base_revision: d.base_revision });
    }, "pc-primary", "把建议数据交给关联的执行任务（不会直接运行命令）");
    apply.disabled = applied || !d.task_id || !d.base_revision;
    s.decision.append(apply);
    s.decision.append(el("small", "pc-muted", "执行代理会先核对代码基线是否仍然一致；不一致会要求重新验证。"));
  }

  // ── 输入区 ───────────────────────────────────────────────────────────
  function renderCompose(s, room, topic) {
    const humans = (room.representatives || []).filter((r) => r.kind === "human" && r.enabled);
    const previous = s.identity.value;
    s.identity.replaceChildren(new Option(humans.length ? "匿名发言（不署名代表）" : "我的发言", ""));
    humans.forEach((r) => s.identity.append(new Option("以 " + r.name + " 的身份发言", r.id)));
    if (humans.some((r) => r.id === previous)) s.identity.value = previous;
    s.identityRow.hidden = humans.length === 0;
    const author = s.identity.value;
    s.picker.replaceChildren(el("span", "pc-picker-label", "邀请发言："));
    (room.representatives || []).filter((r) => r.enabled && r.id !== author).forEach((rep) => {
      const b = button("@" + rep.name, () => insertMention(s, rep), "pc-mini");
      if (!rep.available) b.title = "该代表当前不可用，邀请仍会记录，但不一定马上回应";
      s.picker.append(b);
    });
    s.allBtn.setAttribute("aria-pressed", s.mentionAll.checked ? "true" : "false");
    s.allBtn.classList.toggle("pc-on", s.mentionAll.checked);
    s.allBtn.textContent = s.mentionAll.checked ? "@all 已开" : "@all";
    s.picker.append(s.allBtn, s.pickerToggle);
    s.picker.classList.toggle("pc-open", s.pickerOpen);
    syncSend(s);
  }

  function render(s) {
    const room = s.room;
    if (!room) return;
    const topic = topicOf(s);
    renderHeader(s, room, topic);
    renderPhases(s, topic);
    renderTopics(s, room, topic);
    renderMessages(s, room, topic);
    renderMembers(s, room);
    renderDecision(s, room, topic);
    renderCompose(s, room, topic);
    s.conversationTitle.textContent = topic ? topic.title : "全部动态";
    s.statusLine.replaceChildren();
    if (topic) {
      const calls = (topic.usage && topic.usage.calls) || topic.calls || 0;
      const max = topic.max_calls || (room.limits && room.limits.calls_per_topic) || 16;
      s.statusLine.append(el("span", "pc-stat", "模型调用 " + calls + "/" + max + " 次"));
      s.statusLine.append(el("span", "pc-stat", "跳过 " + (topic.skips || 0) + " 次"));
      s.statusLine.append(el("span", "pc-stat", "等待人类回复 " + ((topic.open_waits || []).length) + " 次"));
      if (topic.status === "stopped") s.statusLine.append(el("span", "pc-chip stop", "已停止"));
      if (topic.status === "unresolved") s.statusLine.append(el("span", "pc-chip warn", "未形成结论"));
      s.discuss.textContent = topic.status === "stopped" || topic.status === "unresolved" ? "重新开启讨论" : "召集讨论";
      s.discuss.disabled = ACTIVE.includes(topic.status);
      s.discuss.title = ACTIVE.includes(topic.status) ? "讨论正在进行中；先停止或等它结束" : "按勾选的代表开始评估与讨论";
      s.stop.disabled = !ACTIVE.includes(topic.status);
      s.stop.title = ACTIVE.includes(topic.status) ? "停止会取消还没开始的回合" : "当前没有进行中的讨论";
      s.actionsHint.hidden = true;
    } else {
      s.statusLine.append(el("span", "pc-stat", "共 " + (room.messages || []).length + " 条消息 · " + (room.topics || []).length + " 个议题"));
      s.discuss.disabled = true;
      s.discuss.title = "先选中一个议题";
      s.stop.disabled = true;
      s.stop.title = "当前没有进行中的讨论";
      s.actionsHint.hidden = false;
      s.actionsHint.textContent = "先在左边选一个议题（或发起新议题），再召集讨论。";
    }
  }
  async function refresh(s, force = false) {
    const seq = s.refreshSeq = (s.refreshSeq || 0) + 1;
    const requestedTopic = s.topicId;
    const room = await command(s, "snapshot", { topic_id: requestedTopic });
    if (current !== s || !s.dialog.open || seq !== s.refreshSeq || requestedTopic !== s.topicId) return;
    if (s.connectionError) { clearError(s); s.connectionError = false; }
    if (force || !s.room || room.revision !== s.room.revision) { s.room = room; render(s); }
  }
  async function poll(s) {
    try { await refresh(s); } catch (e) { if (current === s) { s.connectionError = true; fail(s, e); } }
    if (current === s && s.dialog.open) s.timer = setTimeout(() => poll(s), 2000);
  }
  function tickWaits(s) {
    const now = Date.now();
    s.waitNodes.forEach((w) => {
      const secs = Math.max(0, Math.round((w.deadline - now) / 1000));
      w.node.textContent = secs > 0 ? "还剩约 " + secs + " 秒（超时自动继续）" : "时间到：等待超时后议题会自动继续";
    });
  }
  function saveSelection(s) {
    try { localStorage.setItem("xgroup.reps." + s.gid, JSON.stringify([...s.selected])); } catch (e) {}
  }
  function loadSelection(gid) {
    try {
      const raw = JSON.parse(localStorage.getItem("xgroup.reps." + gid) || "[]");
      return new Set(Array.isArray(raw) ? raw : []);
    } catch (e) { return new Set(); }
  }

  async function open(rpc, groupId) {
    if (current) current.dialog.close();
    const dialog = el("dialog", "pc-dialog"); dialog.setAttribute("aria-label", "项目聊天室");
    const s = {
      rpc, gid: groupId, dialog, topicId: null, replyTo: null, room: null, group: {}, busy: false,
      selected: loadSelection(groupId), renderedIds: [], waitNodes: [], byId: {}, pickerOpen: false,
      lastTopic: undefined, formKey: null, messageKey: null
    };
    current = s;
    const header = el("header", "pc-header");
    const headMain = el("div", "pc-head-main");
    s.title = el("h2", "", "项目聊天室");
    s.headerStatus = el("div", "pc-header-status");
    headMain.append(s.title, s.headerStatus);
    const headActions = el("div", "pc-head-actions");
    s.newTopicBtn = button("发起议题", () => newTopic(s), "pc-primary");
    s.sideBtn = button("代表 0", () => {
      const on = dialog.classList.toggle("pc-show-side");
      s.sideBtn.setAttribute("aria-expanded", on ? "true" : "false");
    }, "pc-side-toggle", "查看 / 选择常驻代表");
    headActions.append(s.newTopicBtn,
      button("添加代表", () => editRepresentative(s), "", "给这个群增加一位发言代表"),
      s.sideBtn,
      button("关闭", () => dialog.close(), "", "关闭窗口；进行中的讨论不会停止"));
    header.append(headMain, headActions);
    s.error = el("div", "pc-error"); s.error.setAttribute("role", "alert"); s.error.hidden = true;
    s.formHost = el("div", "pc-form-host");
    const layout = el("div", "pc-layout");
    const left = el("aside", "pc-topics");
    s.topics = el("nav");
    s.topics.setAttribute("aria-label", "议题列表");
    left.append(el("h3", "", "议题"), s.topics, button("＋ 新议题", () => newTopic(s), "pc-primary pc-block"));
    const center = el("section", "pc-conversation");
    const centerTop = el("div", "pc-conv-top");
    s.conversationTitle = el("h3", "", "全部动态");
    s.phases = el("div", "pc-phases"); s.phases.setAttribute("aria-label", "讨论阶段");
    centerTop.append(s.conversationTitle, s.phases);
    s.statusLine = el("div", "pc-statusline");
    const controls = el("div", "pc-actions");
    s.discuss = button("召集讨论", () => {
      const participants = selectedReps(s);
      mutate(s, "discussion.start", { topic_id: s.topicId, participants, rounds: Number(s.rounds.value) });
    }, "pc-primary");
    s.stop = button("停止讨论", () => {
      const topic = topicOf(s);
      const pending = topic ? (topic.open_waits || []).length : 0;
      const ok = window.confirm("停止这个议题的讨论？\n\n进行中的回合会被取消"
        + (pending ? "（还有 " + pending + " 个人类回合在等待）" : "")
        + "，已经产生的消息和决议会保留。\n之后可以重新开启。");
      if (!ok) return;
      mutate(s, "discussion.stop", { topic_id: s.topicId });
    }, "pc-danger", "停止会取消还没开始的回合");
    s.rounds = el("select"); s.rounds.setAttribute("aria-label", "交叉讨论轮次");
    s.rounds.append(new Option("交叉讨论 2 轮", "2"), new Option("交叉讨论 1 轮", "1"));
    s.actionsHint = el("p", "pc-hint");
    controls.append(s.discuss, s.stop, s.rounds, s.actionsHint);
    s.messages = el("div", "pc-messages"); s.messages.setAttribute("role", "log"); s.messages.setAttribute("aria-label", "聊天记录");
    s.messageList = el("div", "pc-message-list");
    s.waitHost = el("div", "pc-wait-host"); s.waitHost.hidden = true;
    s.messages.append(s.messageList, s.waitHost);
    const compose = el("form", "pc-compose");
    s.replyLabel = el("div", "pc-reply-bar");
    s.picker = el("div", "pc-picker");
    s.mentionAll = el("input"); s.mentionAll.type = "checkbox"; s.mentionAll.hidden = true;
    s.allBtn = button("@all", () => {
      s.mentionAll.checked = !s.mentionAll.checked;
      renderCompose(s, s.room, topicOf(s));
    }, "pc-mini", "邀请最多 5 位可用代表（发送时生效）");
    s.pickerToggle = button("＠", (e) => {
      e.preventDefault();
      s.pickerOpen = !s.pickerOpen;
      s.picker.classList.toggle("pc-open", s.pickerOpen);
    }, "pc-mini pc-picker-toggle", "选择要邀请的代表");
    s.composer = el("textarea"); s.composer.rows = 3; s.composer.maxLength = 4000; s.composer.required = true;
    s.composer.placeholder = "补充证据、提出问题，或用 @名字 邀请某位代表…（Ctrl+Enter 发送）";
    s.composer.setAttribute("aria-label", "聊天消息");
    s.composer.oninput = () => syncSend(s);
    s.composer.onkeydown = (e) => {
      if (e.key === "Enter" && (e.ctrlKey || e.metaKey)) { e.preventDefault(); compose.requestSubmit(); }
    };
    s.send = el("button", "pc-button pc-primary pc-send", "发送"); s.send.type = "submit";
    const composeRow = el("div", "pc-compose-row");
    composeRow.append(s.composer, s.send);
    s.identity = el("select"); s.identity.className = "pc-identity"; s.identity.setAttribute("aria-label", "发言身份");
    s.identityRow = el("div", "pc-identity-row");
    s.identityRow.append(el("span", "pc-picker-label", "发言身份"), s.identity);
    compose.append(s.replyLabel, s.picker, composeRow, s.identityRow);
    s.auto = el("input"); s.auto.type = "checkbox"; s.auto.className = "pc-auto-box";
    s.auto.onchange = () => mutate(s, "settings", { auto_discuss: s.auto.checked });
    compose.onsubmit = (e) => {
      e.preventDefault();
      const body = s.composer.value.trim(); if (!body) return;
      const params = { topic_id: s.topicId, body, reply_to: s.replyTo, mentions: mentionsOf(s), mention_all: s.mentionAll.checked };
      if (s.identity.value) params.representative_id = s.identity.value;
      const key = s.messageKey || (s.messageKey = "message-" + crypto.randomUUID());
      params.command_id = key;
      mutate(s, "message.post", params, () => {
        s.composer.value = ""; s.replyTo = null; s.replyLabel.replaceChildren();
        s.messageKey = null; s.mentionAll.checked = false; syncSend(s);
      });
    };
    center.append(centerTop, s.statusLine, controls, s.messages, compose);
    const right = el("aside", "pc-sidebar");
    s.members = el("div", "pc-members");
    s.decision = el("section", "pc-decision");
    right.append(el("h3", "", "常驻代表"), s.members, s.decision);
    layout.append(left, center, right);
    dialog.append(header, s.error, s.formHost, layout);
    document.body.append(dialog);
    const previousFocus = document.activeElement;
    dialog.addEventListener("close", () => {
      clearTimeout(s.timer);
      clearInterval(s.waitTimer);
      if (current === s) current = null;
      dialog.remove();
      if (previousFocus && previousFocus.focus) previousFocus.focus();
    });
    s.waitTimer = setInterval(() => tickWaits(s), 1000);
    dialog.showModal();
    try {
      const details = await rpc("xgroup.get", { groupId: groupId });
      s.group = details.group || {}; s.tasks = details.tasks || [];
      await refresh(s, true);
      tickWaits(s);
      s.timer = setTimeout(() => poll(s), 2000);
    } catch (e) { fail(s, e); }
  }
  window.NewbeeProjectChat = { open };
})();
