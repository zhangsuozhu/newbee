/* Team Workbench uses the durable sources and their existing write commands. */
(() => {
  "use strict";
  const labels = {
    review: "待验收", confirm: "待确认交付", answer: "待答复", approval: "待审批",
    blocked: "需处理阻塞", queued: "排队中", working: "推进中", delivered: "已交付", finished: "已完成", stopped: "已结束"
  };
  const kinds = {conversation: "会话任务", team: "模板项目", proposal: "组建提案", colony: "蜂群任务", hive: "协作看板", remote_task: "跨机任务"};
  const queues = {attention: "待处理", active: "推进中", history: "历史"};
  function element(tag, cls, text) {
    const el = document.createElement(tag);
    if (cls) el.className = cls;
    if (text != null) el.textContent = text;
    return el;
  }
  function button(text, action, cls = "tp-btn tp-btn-sm") {
    const el = element("button", cls, text);
    el.type = "button";
    el.onclick = action;
    return el;
  }
  function build({rpc, session, navigate, create, join, joinProject, createGroup, renderAgain, report, templates}) {
    let snapshot = null, request = null, bucket = "attention", query = "", error = "";
    let goal = "", mode = "project", template = "", pending = false;
    const templatesFirst = templates;
    async function refresh() {
      if (request) return request;
      request = (async () => {
        try { snapshot = await rpc("team.workbench", {}); error = ""; }
        catch (e) { error = e?.message || "工作台暂时不可用"; }
      })().finally(() => { request = null; });
      return request;
    }
    function drawForm(body) {
      const form = element("form", "tp-inline-form tw-start");
      const title = element("label", "tp-label", "新工作目标");
      const input = element("textarea", "tp-textarea");
      input.id = "team-workbench-goal";
      title.htmlFor = input.id;
      input.value = goal;
      input.required = true;
      input.placeholder = "写下目标、交付物和验收要求";
      input.oninput = () => { goal = input.value; };
      const toolbar = element("div", "tp-actions tw-actions");
      const chooser = element("select", "tp-input");
      chooser.setAttribute("aria-label", "执行方式");
      for (const [value, label] of Object.entries({project:"项目分工", single:"单项委托", project_remote:"跨设备分工", template:"阶段模板"})) {
        const option = element("option", "", label);
        option.value = value;
        chooser.append(option);
      }
      chooser.value = mode;
      const pairs = element("select", "tp-input");
      pairs.setAttribute("aria-label", "团队模板");
      for (const item of templatesFirst()) {
        const option = element("option", "", item.name);
        option.value = item.id;
        pairs.append(option);
      }
      if (template) pairs.value = template;
      pairs.onchange = () => { template = pairs.value; };
      pairs.hidden = mode !== "template";
      chooser.onchange = () => { mode = chooser.value; pairs.hidden = mode !== "template"; };
      const submit = element("button", "tp-btn tp-btn-primary", "开工");
      submit.type = "submit";
      submit.disabled = pending;
      const feedback = element("div", "tw-feedback");
      feedback.setAttribute("role", "status");
      toolbar.append(chooser, pairs, submit);
      form.append(title, input, toolbar, feedback);
      form.onsubmit = async event => {
        event.preventDefault();
        if (pending) return;
        const value = goal.trim();
        const context = session();
        if (!value || !context.id) { feedback.textContent = "请先打开会话并填写工作目标。"; return; }
        if (mode === "template" && !pairs.value) { feedback.textContent = "请先到模板页添加团队模板。"; return; }
        pending = submit.disabled = true;
        feedback.textContent = "正在受理…";
        try {
          await create({goal: value, mode, template: pairs.value, context});
          if (goal.trim() === value) goal = "";
          bucket = "active";
          await refresh();
          renderAgain();
          report("工作已受理", "ok");
        } catch (e) {
          feedback.textContent = e?.message || "工作未受理，请重试";
        } finally { pending = submit.disabled = false; }
      };
      body.append(form);
    }
    async function open(item) {
      try { await navigate(item); }
      catch (e) { report(e?.message || "无法打开这项工作", "err"); }
    }
    function drawQueue(body) {
      drawForm(body);
      if (error) body.append(element("p", "tw-feedback", error));
      const toolbar = element("div", "tp-actions tw-actions");
      for (const [key, label] of Object.entries(queues)) {
        const count = snapshot?.counts?.[key] || 0;
        const control = button(`${label} · ${count}`, () => { bucket = key; renderAgain(); });
        control.setAttribute("aria-pressed", String(bucket === key));
        toolbar.append(control);
      }
      const search = element("input", "tp-input");
      search.placeholder = "搜索当前队列";
      search.setAttribute("aria-label", "搜索当前队列");
      search.value = query;
      const rows = element("div", "tw-rows");
      function fill() {
        const items = (snapshot?.queues?.[bucket] || []).filter(item =>
          String(item.title || "").toLowerCase().includes(query.toLowerCase().trim()));
        rows.replaceChildren();
        for (const item of items) {
          const action = button("", () => open(item), "tp-card tw-row");
          action.append(element("strong", "", item.title), element("span", "tw-meta", `${kinds[item.kind] || "工作"} · ${labels[item.state] || "推进中"}`));
          rows.append(action);
        }
        if (!items.length) rows.append(element("p", "tp-empty", snapshot ? "当前队列没有匹配的工作" : "正在加载工作"));
        if ((snapshot?.counts?.[bucket] || 0) > (snapshot?.queues?.[bucket]?.length || 0)) {
          rows.append(element("p", "tw-meta", "显示最近 100 项，完整记录可在原工作区查阅。"));
        }
      }
      search.oninput = () => { query = search.value; fill(); };
      fill();
      body.append(toolbar, search, rows);
    }
    function drawConnections(body) {
      const toolbar = element("div", "tp-actions tw-actions");
      toolbar.append(button("建立跨机群", createGroup), button("加入协作群", join), button("加入项目执行", joinProject));
      body.append(toolbar);
      if (error) body.append(element("p", "tw-feedback", error));
      const sections = [
        ["会话协作看板", snapshot?.groups, group => ({kind:"hive", id:group.group_id, target:{session_id:group.coordinator_session_id, group_id:group.group_id}}), group => `${group.member_count || 0} 个成员 · ${group.task_count || 0} 个工作项`],
        ["跨机协作群", snapshot?.remote, group => ({kind:"remote", id:group.id}), group => `${group.device_count || 0} 台设备`],
        ["蜂群工作区", snapshot?.colonies, colony => ({kind:"colony", target:{colony_id:colony.id}}), () => "成员、任务与成果"]
      ];
      for (const [title, entries, target, meta] of sections) {
        body.append(element("h3", "tp-section-title tw-section", title));
        if (!entries?.length) { body.append(element("p", "tw-meta", "暂无记录")); continue; }
        for (const entry of entries) {
          const action = button("", () => open(target(entry)), "tp-card tw-row");
          action.append(element("strong", "", entry.name || entry.title || "未命名"), element("span", "tw-meta", meta(entry)));
          body.append(action);
        }
      }
    }
    return {refresh, drawQueue, drawConnections, isPending: () => pending,
            attention: () => snapshot ? (snapshot.counts.attention || 0) : null};
  }
  window.NewbeeTeamWorkbench = {build};
})();

