/* team-panel.js — 主界面内嵌「团队工作室」面板。
 *
 * 设计原则（docs/colony-team-templates-manual.md 的界面化）：
 *   - 不离开主对话界面：右侧滑出面板，顶栏六边形按钮进入，带待办徽标。
 *   - 三个页签：项目 / 模板 / 组建。默认落在「需要你处理」的项目。
 *   - 审批、验收、打回、迭代都是人的专属动作，面板内联完成，不弹原生 dialog。
 *   - 复用主界面 rpc（带登录态）与 notify；所有用户文本用 textContent，不当标记。
 *   - 面板打开时轮询刷新（8s），关闭即停；切后台暂停。
 *
 *   window.NewbeeTeamPanel.init({rpc, notify, openSession})
 *   window.NewbeeTeamPanel.open(tab?)  /  .close()  /  .refreshBadge()
 */
(() => {
  "use strict";

  let rpc = null, notify = null, openSession = null;
  let els = {};
  let state = {
    tab: "runs",
    templates: [], proposals: [], runs: [],
    detail: null,          // 展开的项目 run_id
    detailData: null,      // run_view 结果
    action: null,          // 内联表单 {type, runId}
    loading: false,
    opened: false,
    timer: 0,
    badge: 0,
    lastFetch: 0,
    busy: false
  };

  const ROLE_ICON = { pm: "📋", ui: "🎨", arch: "🏗️", dev: "💻", qa: "🧪", main: "👑" };
  const RUN_STATE = { active: "推进中", completed: "待你确认", halted: "已停下", closed: "已结束" };
  const GATE = { review: "需验收", auto: "自动" };

  function h(tag, cls, text) {
    const n = document.createElement(tag);
    if (cls) n.className = cls;
    if (text != null) n.textContent = text;
    return n;
  }
  function roleIcon(key) { return ROLE_ICON[key] || "🐝"; }
  function roleColor(key) { return `var(--tp-role-${key}, var(--tp-role-main))`; }

  // ── 数据 ──
  async function fetchAll() {
    const [t, p, r] = await Promise.all([
      rpc("colony.team.templates", {}),
      rpc("colony.team.proposals", {}),
      rpc("colony.team.runs", {})
    ]);
    state.templates = t.templates || [];
    state.proposals = p.proposals || [];
    state.runs = r.runs || [];
    state.lastFetch = Date.now();
  }
  function attentionRuns() { return state.runs.filter(r => r.needs_action); }
  function attentionProposals() { return state.proposals.filter(p => p.status === "draft_ready"); }
  function badgeCount() { return attentionRuns().length + attentionProposals().length; }

  async function refreshBadge() {
    if (!rpc) return;
    try {
      const [p, r] = await Promise.all([
        rpc("colony.team.proposals", {}),
        rpc("colony.team.runs", {})
      ]);
      state.proposals = p.proposals || [];
      state.runs = r.runs || [];
      const n = badgeCount();
      state.badge = n;
      const b = els.badge;
      if (b) {
        b.textContent = n > 99 ? "99+" : String(n);
        b.classList.toggle("hidden", n === 0);
        b.classList.toggle("tp-pulse", n > 0);
      }
    } catch (e) { /* 静默：徽标失败不打扰 */ }
  }

  // ── 面板骨架 ──
  function build() {
    const scrim = h("div", "tp-scrim");
    scrim.addEventListener("click", close);

    const panel = h("aside", "tp-panel");
    panel.setAttribute("role", "dialog");
    panel.setAttribute("aria-label", "团队工作室");

    const head = h("div", "tp-head");
    const mark = h("div", "tp-head-mark", "🐝");
    const titleWrap = h("div");
    titleWrap.append(h("div", "tp-head-title", "团队工作室"));
    titleWrap.append(h("div", "tp-head-sub", "组建团队 · 引用模板 · 闭环交付"));
    const refreshBtn = h("button", "tp-iconbtn", "⟳");
    refreshBtn.title = "刷新";
    refreshBtn.addEventListener("click", () => load(true));
    const closeBtn = h("button", "tp-iconbtn", "✕");
    closeBtn.title = "关闭（Esc）";
    closeBtn.addEventListener("click", close);
    head.append(mark, titleWrap, h("div", "tp-head-spacer"), refreshBtn, closeBtn);

    const tabs = h("div", "tp-tabs");
    els.tabs = {};
    [["runs", "项目"], ["templates", "模板"], ["proposals", "组建"]].forEach(([id, label]) => {
      const t = h("button", "tp-tab");
      t.append(h("span", null, label));
      const n = h("span", "tp-tab-n", "0");
      t.append(n);
      t.addEventListener("click", () => { state.tab = id; state.action = null; render(); });
      tabs.append(t);
      els.tabs[id] = { btn: t, n };
    });

    const body = h("div", "tp-body");
    const foot = h("div", "tp-foot");
    const dot = h("span", "tp-foot-dot");
    const footText = h("span", null, "审批 / 验收 / 打回 / 迭代由你决定，AI 只负责干活");
    foot.append(dot, footText);
    const toast = h("div", "tp-toast");

    panel.append(head, tabs, body, foot, toast);
    document.body.append(scrim, panel);
    els = { ...els, scrim, panel, body, dot, toast, footText };

    document.addEventListener("keydown", (e) => {
      if (e.key === "Escape" && state.opened) close();
    });
    document.addEventListener("visibilitychange", () => {
      if (document.hidden) stopPoll(); else if (state.opened) startPoll();
    });
  }

  function toast(msg, kind) {
    const t = els.toast;
    t.textContent = msg;
    t.className = "tp-toast tp-show" + (kind ? " tp-" + kind : "");
    clearTimeout(t._timer);
    t._timer = setTimeout(() => { t.className = "tp-toast"; }, 3200);
  }

  // ── 渲染 ──
  function render() {
    // tabs 计数与选中
    const counts = { runs: state.runs.length, templates: state.templates.length, proposals: attentionProposals().length };
    for (const id of ["runs", "templates", "proposals"]) {
      const { btn, n } = els.tabs[id];
      btn.classList.toggle("tp-on", state.tab === id);
      n.textContent = String(counts[id]);
      n.classList.toggle("hidden", counts[id] === 0 && id !== state.tab);
    }
    els.dot.classList.toggle("tp-stale", Date.now() - state.lastFetch > 20000);

    const body = els.body;
    body.innerHTML = "";
    if (state.loading && !state.runs.length && !state.templates.length) {
      body.append(h("div", "tp-empty", "加载中…"));
      return;
    }
    if (state.tab === "runs") renderRuns(body);
    else if (state.tab === "templates") renderTemplates(body);
    else renderProposals(body);
  }

  function emptyState(title, sub, ctas) {
    const box = h("div", "tp-empty");
    const comb = h("div", "tp-empty-comb");
    ["🐝", "🍯", "✨"].forEach(e => comb.append(h("div", "tp-empty-hex", e)));
    box.append(comb, h("div", "tp-empty-title", title), h("div", "tp-empty-sub", sub));
    if (ctas && ctas.length) {
      const row = h("div", "tp-empty-cta");
      ctas.forEach(([label, fn, primary]) => {
        const b = h("button", "tp-btn" + (primary ? " tp-btn-primary" : ""), label);
        b.addEventListener("click", fn);
        row.append(b);
      });
      box.append(row);
    }
    return box;
  }

  // ── 项目页 ──
  function renderRuns(body) {
    const attn = attentionRuns();
    if (!state.runs.length) {
      body.append(emptyState(
        "还没有团队项目",
        "引用一个团队模板就能开项目：系统自动建好角色、派发第一阶段，你只管验收。内置「产研团队」开箱即用。",
        [["⚡ 用产研团队开项目", quickStart, true], ["浏览模板", () => { state.tab = "templates"; render(); }]]
      ));
      return;
    }
    if (attn.length) {
      const head = h("div", "tp-section-head");
      head.append(h("span", "tp-section-title", `需要你处理 · ${attn.length}`));
      body.append(head);
      attn.forEach(r => body.append(runCard(r, true)));
      const rest = state.runs.filter(r => !r.needs_action);
      if (rest.length) {
        const head2 = h("div", "tp-section-head");
        head2.style.marginTop = "14px";
        head2.append(h("span", "tp-section-title", "其它项目"));
        body.append(head2);
        rest.forEach(r => body.append(runCard(r, false)));
      }
    } else {
      state.runs.forEach(r => body.append(runCard(r, false)));
    }
  }

  function runCard(run, hot) {
    const card = h("div", "tp-card" + (hot ? " tp-hot" : ""));
    const titleRow = h("div", "tp-card-title");
    titleRow.append(h("span", null, run.name));
    titleRow.append(h("div", "tp-spacer"));
    titleRow.append(statePill(run));
    card.append(titleRow);
    card.append(h("div", "tp-card-sub", `第 ${run.round} 轮 · ${run.template?.name || "团队"} · ${run.goal ? run.goal.slice(0, 60) : ""}`));

    // 迷你阶段轨道
    const stages = run.template?.stages || [];
    if (stages.length) {
      const rail = h("div", "tp-rail");
      stages.forEach((s, i) => {
        if (i > 0) {
          const link = h("div", "tp-rail-link" + (i <= run.stage_index ? " tp-done" : ""));
          rail.append(link);
        }
        const node = h("div", "tp-rail-node");
        node.title = s.name;
        const done = run.status === "completed" || run.status === "closed" || i < run.stage_index;
        const current = i === run.stage_index && run.status === "active";
        if (done) node.classList.add("tp-done");
        else if (current) node.classList.add(run.current_status === "pending_review" ? "tp-review" : "tp-current");
        rail.append(node);
      });
      card.append(rail);
    }

    const actions = h("div", "tp-actions");
    actions.style.marginTop = "10px";
    const openBtn = h("button", "tp-btn tp-btn-sm" + (hot ? " tp-btn-primary" : ""), state.detail === run.id ? "收起" : (hot ? "去处理 →" : "查看详情"));
    openBtn.addEventListener("click", () => toggleDetail(run.id));
    actions.append(openBtn);
    card.append(actions);

    if (state.detail === run.id) {
      card.append(detailBox(run));
    }
    return card;
  }

  function statePill(run) {
    if (run.status === "completed") return h("span", "tp-pill tp-pill-review", "待你确认");
    if (run.status === "halted") return h("span", "tp-pill tp-pill-warn", "轮次用尽");
    if (run.status === "closed") return h("span", "tp-pill tp-pill-stop", "已结束");
    if (run.current_status === "pending_review") return h("span", "tp-pill tp-pill-review", "待验收");
    if (run.current_status === "blocked") return h("span", "tp-pill tp-pill-warn", "受阻");
    return h("span", "tp-pill tp-pill-run", "推进中");
  }

  function detailBox(run) {
    const box = h("div", "tp-detail");
    if (!state.detailData || state.detailData.run?.id !== run.id) {
      box.append(h("div", "tp-card-sub", "加载项目详情…"));
      loadDetail(run.id);
      return box;
    }
    const d = state.detailData;
    const stages = d.stages || [];
    const cur = d.current_task;

    // 阶段流水线（纵向）
    const stageWrap = h("div", "tp-stages");
    stages.forEach(s => {
      const row = h("div", "tp-stage tp-s-" + (s.state === "done" ? "done" : s.state === "current" ? "current" : "pending"));
      const icon = h("div", "tp-stage-icon", s.state === "done" ? "✓" : roleIcon(s.role));
      const main = h("div", "tp-stage-main");
      const nameRow = h("div", "tp-stage-name");
      nameRow.append(h("span", null, s.name));
      nameRow.append(h("span", "tp-stage-gate", GATE[s.gate] || s.gate));
      if (s.attempts) nameRow.append(h("span", "tp-stage-meta", `${s.attempts} 次交付${s.last_verdict === "reject" ? " · 曾打回" : ""}`));
      main.append(nameRow);
      const roleName = (d.members || []).find(m => m.role === s.role)?.display || s.role;
      main.append(h("div", "tp-stage-meta", `负责：${roleName}`));
      row.append(icon, main);
      stageWrap.append(row);
    });
    box.append(stageWrap);

    // 最近反馈
    if (d.run.last_feedback) {
      box.append(h("div", "tp-feedback", "最近反馈：" + d.run.last_feedback));
    }

    // 当前任务 + 成果
    if (cur) {
      const tb = h("div", "tp-taskbox");
      tb.append(h("div", "tp-taskbox-title", cur.title));
      if (cur.next_step) tb.append(h("div", "tp-taskbox-next", cur.next_step));
      box.append(tb);
      if (cur.result_content) {
        box.append(h("div", "tp-label", "阶段成果"));
        box.append(h("div", "tp-honey", cur.result_content));
      }
    }

    // 操作区
    box.append(actionArea(d.run, cur));
    return box;
  }

  function actionArea(run, cur) {
    const wrap = h("div");
    const actions = h("div", "tp-actions");

    if (run.status === "active" && cur && cur.status === "pending_review" && cur.result) {
      const ok = h("button", "tp-btn tp-btn-ok", "✓ 验收通过");
      ok.addEventListener("click", () => showAction("accept", run.id));
      const no = h("button", "tp-btn tp-btn-danger", "↩ 打回重做");
      no.addEventListener("click", () => showAction("reject", run.id));
      actions.append(ok, no);
    }
    if (run.status === "completed") {
      const it = h("button", "tp-btn tp-btn-primary", "🔁 继续迭代");
      it.addEventListener("click", () => showAction("iterate", run.id));
      const done = h("button", "tp-btn", "✓ 满意，结束");
      done.addEventListener("click", () => showAction("complete", run.id));
      actions.append(it, done);
    }
    if (run.status === "halted") {
      const ext = h("button", "tp-btn tp-btn-primary", "⤴ 提高预算并继续");
      ext.addEventListener("click", () => showAction("extend", run.id));
      actions.append(ext);
    }
    if (cur && cur.session_id && openSession) {
      const view = h("button", "tp-btn tp-btn-ghost tp-btn-sm", "查看执行会话 →");
      view.addEventListener("click", () => openSession(cur.session_id));
      actions.append(view);
    }
    wrap.append(actions);

    if (state.action && state.action.runId === run.id) {
      wrap.append(actionForm(state.action.type, run));
    }
    return wrap;
  }

  function showAction(type, runId) {
    state.action = { type, runId };
    render();
  }

  function actionForm(type, run) {
    const form = h("div", "tp-inline-form");
    const cfg = {
      accept: { label: "验收意见（可选）", ph: "通过的理由 / 给下一阶段的提醒…", required: false, btn: "确认通过", cls: "tp-btn-ok" },
      reject: { label: "打回理由（必填，会交给重做的角色）", ph: "哪里不行、要改成什么样…", required: true, btn: "确认打回", cls: "tp-btn-danger" },
      iterate: { label: "下一轮要改进什么（交给产品经理）", ph: "例如：补编辑功能、优化报表…", required: true, btn: "开始新一轮", cls: "tp-btn-primary" },
      complete: { label: "结项说明（可选）", ph: "本轮交付总结…", required: false, btn: "结束项目", cls: "" },
      extend: { label: "追加轮次（1~5）", ph: "2", required: true, btn: "提高预算并继续", cls: "tp-btn-primary", number: true }
    }[type];
    form.append(h("label", "tp-label", cfg.label));
    const input = cfg.number ? h("input", "tp-input") : h("textarea", "tp-textarea");
    input.placeholder = cfg.ph;
    if (cfg.number) { input.type = "number"; input.min = "1"; input.max = "5"; input.value = "2"; }
    form.append(input);
    const row = h("div", "tp-actions");
    row.style.marginTop = "9px";
    const go = h("button", "tp-btn " + cfg.cls, cfg.btn);
    go.addEventListener("click", async () => {
      const val = input.value.trim();
      if (cfg.required && !val) { toast("请填写" + cfg.label.replace(/（.*）/, ""), "err"); input.focus(); return; }
      go.disabled = true;
      try {
        await doAction(type, run, val);
        state.action = null;
        await load(true);
        await loadDetail(run.id);
        render();
      } catch (e) {
        toast(e.message || "操作失败", "err");
        go.disabled = false;
      }
    });
    const cancel = h("button", "tp-btn tp-btn-ghost", "取消");
    cancel.addEventListener("click", () => { state.action = null; render(); });
    row.append(go, cancel);
    form.append(row);
    setTimeout(() => input.focus(), 30);
    return form;
  }

  async function doAction(type, run, val) {
    const cid = run.colony_id;
    if (type === "accept" || type === "reject") {
      const cur = state.detailData?.current_task;
      const r = await rpc("colony.team.run.review", { colonyId: cid, runId: run.id, honeyId: cur.result, verdict: type, note: val });
      toast(type === "accept" ? "已通过，流水线继续推进" : "已打回，对应环节开始重做", "ok");
      return r;
    }
    if (type === "iterate" || type === "complete") {
      const r = await rpc("colony.team.run.finish", { colonyId: cid, runId: run.id, decision: type, note: val });
      toast(type === "iterate" ? "新一轮迭代已开始" : "项目已结束", "ok");
      return r;
    }
    if (type === "extend") {
      const n = Math.max(1, Math.min(5, parseInt(val, 10) || 2));
      const r = await rpc("colony.team.run.extend", { colonyId: cid, runId: run.id, extraRounds: n });
      toast("预算已提高，项目继续", "ok");
      return r;
    }
  }

  async function loadDetail(runId) {
    try {
      const run = state.runs.find(r => r.id === runId);
      const d = await rpc("colony.team.run.view", { colonyId: run?.colony_id, runId });
      state.detailData = d;
      if (state.detail === runId) render();
    } catch (e) { /* 详情失败保留占位 */ }
  }

  function toggleDetail(runId) {
    state.action = null;
    if (state.detail === runId) { state.detail = null; state.detailData = null; render(); }
    else { state.detail = runId; state.detailData = null; render(); loadDetail(runId); }
  }

  // ── 模板页 ──
  function renderTemplates(body) {
    const head = h("div", "tp-section-head");
    head.append(h("span", "tp-section-title", "团队模板 · 全局可复用"));
    head.append(h("div", "tp-spacer"));
    const seed = h("button", "tp-btn tp-btn-sm", "⚡ 安装产研团队");
    seed.addEventListener("click", async () => {
      seed.disabled = true;
      try { await rpc("colony.team.template.seed", {}); toast("已安装内置产研团队模板", "ok"); await load(true); render(); }
      catch (e) { toast(e.message || "安装失败", "err"); seed.disabled = false; }
    });
    head.append(seed);
    body.append(head);

    if (!state.templates.length) {
      body.append(emptyState("还没有模板", "安装内置「产研团队」，或到「组建」页让 main 为你定制一支团队。", [["⚡ 安装产研团队", async () => { await rpc("colony.team.template.seed", {}); await load(true); render(); }, true]]));
      return;
    }
    state.templates.forEach(t => body.append(templateCard(t)));
  }

  function templateCard(t) {
    const card = h("div", "tp-card");
    const titleRow = h("div", "tp-card-title");
    titleRow.append(h("span", null, t.name));
    titleRow.append(h("div", "tp-spacer"));
    titleRow.append(h("span", "tp-pill tp-pill-stop", `${t.roles.length} 角色 · ${t.stages.length} 阶段`));
    card.append(titleRow);
    if (t.description) card.append(h("div", "tp-card-sub", t.description));

    const roles = h("div", "tp-roles");
    t.roles.forEach(r => {
      const chip = h("span", "tp-role");
      const dot = h("span", "tp-role-dot");
      dot.style.background = roleColor(r.key);
      chip.append(dot, h("span", null, `${roleIcon(r.key)} ${r.name}`));
      chip.title = r.duty;
      roles.append(chip);
    });
    card.append(roles);

    const flow = h("div", "tp-flowline");
    t.stages.forEach((s, i) => {
      if (i > 0) flow.append(h("span", "tp-flow-arrow", "→"));
      flow.append(h("span", "tp-flow-step", s.name));
    });
    card.append(flow);

    const actions = h("div", "tp-actions");
    actions.style.marginTop = "11px";
    const start = h("button", "tp-btn tp-btn-primary tp-btn-sm", "🚀 用此模板开项目");
    start.addEventListener("click", () => startProjectForm(t, card));
    actions.append(start);
    card.append(actions);
    return card;
  }

  function startProjectForm(t, card) {
    // 移除已有表单
    card.querySelectorAll(".tp-inline-form").forEach(n => n.remove());
    const form = h("div", "tp-inline-form");
    form.append(h("label", "tp-label", "项目目标（写清楚要做什么、技术约束、交付物）"));
    const goal = h("textarea", "tp-textarea");
    goal.placeholder = "例如：做一个纯前端记账小程序：收支记录、分类管理、月度报表，数据存 localStorage，纯 HTML/CSS/JS 无依赖。";
    form.append(goal);
    form.append(h("label", "tp-label", "项目名称（可选）"));
    const name = h("input", "tp-input");
    name.placeholder = t.name + " · 新项目";
    form.append(name);
    const row = h("div", "tp-actions");
    row.style.marginTop = "9px";
    const go = h("button", "tp-btn tp-btn-primary", "🚀 启动项目");
    go.addEventListener("click", async () => {
      const g = goal.value.trim();
      if (!g) { toast("请填写项目目标", "err"); goal.focus(); return; }
      go.disabled = true;
      try {
        const r = await rpc("colony.team.run.start", { templateId: t.id, goal: g, name: name.value.trim() || undefined });
        toast("项目已启动：角色已建立，第一阶段已派发", "ok");
        state.tab = "runs";
        state.detail = r.run.id;
        state.detailData = null;
        await load(true);
        render();
        loadDetail(r.run.id);
      } catch (e) { toast(e.message || "启动失败", "err"); go.disabled = false; }
    });
    const cancel = h("button", "tp-btn tp-btn-ghost", "取消");
    cancel.addEventListener("click", () => form.remove());
    row.append(go, cancel);
    form.append(row);
    card.append(form);
    goal.focus();
  }

  async function quickStart() {
    try {
      let t = state.templates.find(x => x.name === "产研团队");
      if (!t) { const r = await rpc("colony.team.template.seed", {}); t = r.template; await load(true); }
      state.tab = "templates";
      render();
      // 找到该模板卡片并展开表单
      const cards = els.body.querySelectorAll(".tp-card");
      for (const c of cards) {
        if (c.querySelector(".tp-card-title")?.textContent?.includes(t.name)) { startProjectForm(t, c); break; }
      }
    } catch (e) { toast(e.message || "操作失败", "err"); }
  }

  // ── 组建页 ──
  function renderProposals(body) {
    const head = h("div", "tp-section-head");
    head.append(h("span", "tp-section-title", "让 main 组建团队"));
    head.append(h("div", "tp-spacer"));
    body.append(head);

    const intro = h("div", "tp-card");
    intro.append(h("div", "tp-card-sub", "描述你要什么样的团队，main（团队主理人）会产出角色分工 + 运营流程草案，你审批后入库为模板。"));
    const form = h("div", "tp-inline-form");
    form.style.marginTop = "10px";
    form.append(h("label", "tp-label", "这个团队要做什么"));
    const goal = h("textarea", "tp-textarea");
    goal.placeholder = "例如：一支短视频内容团队：选题策划、脚本撰写、拍摄清单、剪辑规范、发布复盘，循环迭代。";
    form.append(goal);
    const row = h("div", "tp-actions");
    row.style.marginTop = "9px";
    const go = h("button", "tp-btn tp-btn-primary", "👑 发起提案");
    go.addEventListener("click", async () => {
      const g = goal.value.trim();
      if (!g) { toast("请描述团队要做什么", "err"); goal.focus(); return; }
      go.disabled = true;
      try {
        await rpc("colony.team.proposal.start", { goal: g });
        toast("已交给 main 规划，草案就绪后在这里审批", "ok");
        goal.value = "";
        await load(true);
        render();
      } catch (e) { toast(e.message || "发起失败", "err"); go.disabled = false; }
    });
    row.append(go);
    form.append(row);
    intro.append(form);
    body.append(intro);

    const active = state.proposals.filter(p => ["planning", "draft_ready", "draft_invalid"].includes(p.status));
    const decided = state.proposals.filter(p => ["approved", "rejected"].includes(p.status));
    if (active.length) {
      const h2 = h("div", "tp-section-head");
      h2.style.marginTop = "14px";
      h2.append(h("span", "tp-section-title", "进行中的提案"));
      body.append(h2);
      active.forEach(p => body.append(proposalCard(p)));
    }
    if (decided.length) {
      const h3 = h("div", "tp-section-head");
      h3.style.marginTop = "14px";
      h3.append(h("span", "tp-section-title", "已有结论"));
      body.append(h3);
      decided.slice(0, 5).forEach(p => body.append(proposalCard(p)));
    }
  }

  function proposalStatePill(p) {
    if (p.status === "draft_ready") return h("span", "tp-pill tp-pill-review", "草案待审批");
    if (p.status === "planning") return h("span", "tp-pill tp-pill-run", "main 规划中");
    if (p.status === "draft_invalid") return h("span", "tp-pill tp-pill-warn", "草案不合格");
    if (p.status === "approved") return h("span", "tp-pill tp-pill-done", "已批准");
    return h("span", "tp-pill tp-pill-stop", "已驳回");
  }

  function proposalCard(p) {
    const card = h("div", "tp-card" + (p.status === "draft_ready" ? " tp-hot" : ""));
    const titleRow = h("div", "tp-card-title");
    titleRow.append(h("span", null, (p.goal || "").slice(0, 40)));
    titleRow.append(h("div", "tp-spacer"));
    titleRow.append(proposalStatePill(p));
    card.append(titleRow);

    if (p.status === "draft_ready" && p.draft) {
      const d = p.draft;
      card.append(h("div", "tp-card-sub", `${d.name} · ${d.roles.length} 角色 · ${d.stages.length} 阶段 · 轮次上限 ${d.max_rounds}`));
      const roles = h("div", "tp-roles");
      d.roles.forEach(r => {
        const chip = h("span", "tp-role");
        const dot = h("span", "tp-role-dot"); dot.style.background = roleColor(r.key);
        chip.append(dot, h("span", null, `${roleIcon(r.key)} ${r.name}`));
        chip.title = r.duty;
        roles.append(chip);
      });
      card.append(roles);
      const flow = h("div", "tp-flowline");
      d.stages.forEach((s, i) => { if (i > 0) flow.append(h("span", "tp-flow-arrow", "→")); flow.append(h("span", "tp-flow-step", s.name)); });
      card.append(flow);

      const actions = h("div", "tp-actions");
      actions.style.marginTop = "11px";
      const approve = h("button", "tp-btn tp-btn-ok tp-btn-sm", "✓ 批准入库");
      approve.addEventListener("click", () => proposalAction(p, "approve", card));
      const retry = h("button", "tp-btn tp-btn-sm", "⟳ 重新规划");
      retry.addEventListener("click", () => proposalAction(p, "retry", card));
      const reject = h("button", "tp-btn tp-btn-danger tp-btn-sm", "✕ 驳回");
      reject.addEventListener("click", () => proposalAction(p, "reject", card));
      actions.append(approve, retry, reject);
      card.append(actions);
    } else if (p.status === "draft_invalid") {
      card.append(h("div", "tp-card-sub", "草案不合格：" + (p.note || "未说明")));
      const actions = h("div", "tp-actions");
      actions.style.marginTop = "9px";
      const retry = h("button", "tp-btn tp-btn-sm", "⟳ 让 main 重新规划");
      retry.addEventListener("click", () => proposalAction(p, "retry", card));
      actions.append(retry);
      card.append(actions);
    } else if (p.status === "planning") {
      card.append(h("div", "tp-card-sub", "main 正在规划角色与流程，稍后刷新查看草案。"));
    } else if (p.note) {
      card.append(h("div", "tp-card-sub", p.note));
    }
    return card;
  }

  function proposalAction(p, type, card) {
    card.querySelectorAll(".tp-inline-form").forEach(n => n.remove());
    if (type === "approve") {
      // 批准无需理由，直接执行
      (async () => {
        try {
          await rpc("colony.team.proposal.decide", { colonyId: p.colony_id, proposalId: p.id, decision: "approve" });
          toast("模板已批准入库，可到「模板」页引用开项目", "ok");
          await load(true); render(); refreshBadge();
        } catch (e) { toast(e.message || "批准失败", "err"); }
      })();
      return;
    }
    const form = h("div", "tp-inline-form");
    const label = type === "reject" ? "驳回理由" : "给 main 的补充意见（可选）";
    form.append(h("label", "tp-label", label));
    const note = h("textarea", "tp-textarea");
    note.placeholder = type === "reject" ? "为什么不要这个方案…" : "希望调整的地方…";
    form.append(note);
    const row = h("div", "tp-actions");
    row.style.marginTop = "9px";
    const go = h("button", "tp-btn " + (type === "reject" ? "tp-btn-danger" : ""), type === "reject" ? "确认驳回" : "重新规划");
    go.addEventListener("click", async () => {
      go.disabled = true;
      try {
        if (type === "reject") await rpc("colony.team.proposal.decide", { colonyId: p.colony_id, proposalId: p.id, decision: "reject", note: note.value.trim() || "未说明原因" });
        else await rpc("colony.team.proposal.retry", { colonyId: p.colony_id, proposalId: p.id, note: note.value.trim() || undefined });
        toast(type === "reject" ? "提案已驳回" : "已让 main 重新规划", "ok");
        await load(true); render(); refreshBadge();
      } catch (e) { toast(e.message || "操作失败", "err"); go.disabled = false; }
    });
    const cancel = h("button", "tp-btn tp-btn-ghost", "取消");
    cancel.addEventListener("click", () => form.remove());
    row.append(go, cancel);
    form.append(row);
    card.append(form);
    note.focus();
  }

  // ── 加载 / 轮询 / 开关 ──
  async function load(showLoading) {
    if (showLoading) { state.loading = true; render(); }
    try { await fetchAll(); }
    catch (e) { if (showLoading) toast(e.message || "加载失败", "err"); }
    state.loading = false;
    render();
    refreshBadge();
    if (state.detail) loadDetail(state.detail);
  }

  function startPoll() {
    stopPoll();
    state.timer = setInterval(() => { if (state.opened && !document.hidden) load(false); }, 8000);
  }
  function stopPoll() { if (state.timer) { clearInterval(state.timer); state.timer = 0; } }

  function open(tab) {
    if (!els.panel) build();
    if (tab) state.tab = tab;
    state.opened = true;
    els.scrim.classList.add("tp-show");
    els.panel.classList.add("tp-show");
    load(true);
    startPoll();
  }
  function close() {
    state.opened = false;
    state.action = null;
    if (els.scrim) els.scrim.classList.remove("tp-show");
    if (els.panel) els.panel.classList.remove("tp-show");
    stopPoll();
  }

  window.NewbeeTeamPanel = {
    init(opts) {
      rpc = opts.rpc; notify = opts.notify; openSession = opts.openSession;
      els.badge = document.getElementById("team-panel-badge");
      build();
      refreshBadge();
      setInterval(refreshBadge, 15000);
    },
    open, close, refreshBadge,
    isOpen: () => state.opened
  };
})();
