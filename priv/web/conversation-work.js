/* conversation-work.js — 原会话里的「当前工作」卡与后台操作（v0.4 前端组件）。
 *
 * 设计依据：docs/superagent-conversation-ux.md（§2 默认路径、§4 目录规则、§5 六条使用故事、§7 输入与可访问性）。
 * 本文件只提供组件能力，不接管普通对话：
 *
 *   window.NewbeeConversationWork.init({rpc, getSessionId, getDirectory, notify,
 *                                       readDraft, writeDraft, appendUser, getUploadIds})
 *   window.NewbeeConversationWork.refresh()                     -> Promise<work[]>
 *   window.NewbeeConversationWork.submit(text, uploadIds=[])    -> Promise<boolean>
 *   window.NewbeeConversationWork.start()                       -> Promise<boolean>
 *   window.NewbeeConversationWork.destroy()
 *
 * 规则：
 *   - RPC：conversation.work.list/start/input/answer/control/review/apply/complete；
 *     每个 payload 都带 sessionId。start/input/apply/complete 带稳定 requestId，
 *     同一次失败重试复用同一个 ID，不产生第二份工作或第二条补充。
 *   - list 返回 {works:[work]}；start/input/answer/control/apply/complete 返回 {work, receipt?}；
 *     review 返回 {review:{patch_sha256,files,target_root,summary,conflicts}}。
 *   - submit() 只在“当前有后台工作”时把补充交给 input 并返回 true；其余情况返回 false，
 *     由主 send 继续原来的普通发送。失败时不清理输入框，并抛出带可见提示的错误。
 *   - 没有可用 Session 不发请求；切换会话或离开页面后，旧响应一律作废（generation + session 双重核对）；
 *     页面隐藏时不轮询，回到前台立即刷新。轮询有上限并带退避，不接事件流。
 *   - 所有展示用 textContent 构建，用户文本不会被当成标记。
 *   - 采用（apply）前必须重新 review 取得 patch_sha256，并核对 revision / context_revision 未变；
 *     有冲突或哈希不一致时不覆盖目标文件。
 *   - work.inputs 是可选字段：服务端提供时展示真实“已收到/已采用”；未提供时只展示本端已发送记录与 RPC 回执，
 *     不把“已发送”写成“已采用”。
 */
(() => {
  "use strict";

  const RPC = Object.freeze({
    list: "conversation.work.list",
    start: "conversation.work.start",
    input: "conversation.work.input",
    answer: "conversation.work.answer",
    control: "conversation.work.control",
    review: "conversation.work.review",
    apply: "conversation.work.apply",
    complete: "conversation.work.complete"
  });

  const STATUS = {
    queued: {label: "排队中", tone: "wait"},
    running: {label: "进行中", tone: "run"},
    blocked: {label: "需要处理", tone: "warn"},
    pending_review: {label: "待查看结果", tone: "review"},
    done: {label: "已完成", tone: "done"},
    failed: {label: "未完成", tone: "err"},
    cancelled: {label: "已结束", tone: "stop"}
  };

  const STAGE = {
    queued: {label: "排队", hint: "已受理，等待开始。"},
    working: {label: "正在做", hint: "正在按当前目标推进；可以直接补充新的要求。"},
    pausing: {label: '正在暂停', hint: '暂停请求已保存，正在等待执行者停止；尚未确认已暂停。'},
    stopping: {label: '正在结束', hint: '结束请求已保存，正在等待执行者停止；已有修改会保留。'},
    paused: {label: "已暂停", hint: "推进已暂停。补充会保存，只有点「继续」才会恢复。"},
    needs_answer: {label: "等待答复", hint: "有一个会影响结果的问题需要你决定。"},
    needs_review: {label: "等待查看", hint: "结果已准备好，查看后再决定是否应用到项目。"},
    blocked: {label: "阻塞", hint: "推进遇到阻碍；已有改动会保留。"},
    unknown: {label: "状态待确认", hint: "暂时无法确认执行状态；不会自动再开第二个写入者。"},
    completed: {label: '已完成', hint: '成果已经完成，可在原对话查看和继续讨论。'},
    ended: {label: "已结束", hint: "不再推进；已有修改和历史保留，结束不等于撤回。"}
  };

  const ACTIVE_STATUS = new Set(["queued", "running", "blocked", "pending_review"]);
  const ACTIVE_STAGE = new Set(["queued", "working", "pausing", "paused", "needs_answer", "needs_review", "blocked", "unknown"]);
  const STAGE_PRIORITY = {needs_answer: 0, needs_review: 1, blocked: 2, unknown: 2, working: 3, paused: 4, queued: 5, ended: 6};
  const POLL_FAST = 4000;
  const POLL_IDLE = 15000;
  const TEXT_LIMIT = 4000;
  const ANSWER_LIMIT = 8000;
  const ADOPTED_WORDS = new Set(["adopted", "applied", "consumed", "used"]);
  const RECEIVED_WORDS = new Set(["received", "accepted", "queued", "stored"]);

  const state = {
    host: null,
    card: null,
    composerStart: null,
    noticeBox: null,
    works: [],
    sessionId: "",
    generation: 0,
    refreshing: null,
    timer: 0,
    delay: POLL_FAST,
    failed: 0,
    busy: new Set(),
    requestIds: new Map(),
    receipts: new Map(),
    sent: new Map(),
    reviewCache: new Map(),
    expanded: new Set(),
    coordinationOpen: new Map(),
    confirm: new Set(),
    answerDraft: "",
    composing: false,
    pendingRender: false,
    selectedWorkId: "",
    notice: null,
    noticeTimer: 0,
    sig: "",
    onVisibility: null
  };

  function el(tag, cls, text) {
    const node = document.createElement(tag);
    if (cls) node.className = cls;
    if (text != null) node.textContent = String(text);
    return node;
  }

  function clip(value, limit) {
    const text = String(value == null ? "" : value);
    const max = limit || TEXT_LIMIT;
    return text.length > max ? text.slice(0, max) + "…（已截断）" : text;
  }

  function messageOf(error) {
    if (!error) return "未知错误";
    return clip(error.message || error, 300);
  }

  function button(label, handler, cls, title) {
    const node = el("button", "cw-btn" + (cls ? " " + cls : ""), label);
    node.type = "button";
    if (title) node.title = title;
    node.addEventListener("click", (event) => {
      if (event && typeof event.preventDefault === "function") event.preventDefault();
      try {
        const result = handler();
        if (result && typeof result.catch === "function") {
          result.catch((err) => say("操作没有完成：" + messageOf(err), "err"));
        }
      } catch (err) {
        say("操作没有完成：" + messageOf(err), "err");
      }
    });
    return node;
  }

  function sessionId() {
    if (!state.host) return "";
    try {
      const value = state.host.getSessionId ? state.host.getSessionId() : "";
      const text = value == null ? "" : String(value);
      return text === "null" || text === "undefined" ? "" : text;
    } catch (err) {
      return "";
    }
  }

  function directoryFallback() {
    if (!state.host || typeof state.host.getDirectory !== "function") return "";
    try {
      const value = state.host.getDirectory();
      return typeof value === "string" ? value : "";
    } catch (err) {
      return "";
    }
  }

  function hostUploadIds() {
    if (!state.host || typeof state.host.getUploadIds !== "function") return [];
    try {
      const value = state.host.getUploadIds();
      return Array.isArray(value) ? value.filter((id) => typeof id === "string" && id !== "") : [];
    } catch (err) {
      return [];
    }
  }

  function say(text, kind) {
    const message = String(text == null ? "" : text);
    if (!message) return;
    state.notice = {text: message, kind: kind || "info"};
    renderNotice();
    if (state.host && typeof state.host.notify === "function") {
      try {
        state.host.notify(message, kind || "info");
      } catch (err) {
        /* 宿主提示失败不影响卡内可见回执 */
      }
    }
    if (state.noticeTimer) clearTimeout(state.noticeTimer);
    state.noticeTimer = setTimeout(() => {
      state.noticeTimer = 0;
      state.notice = null;
      renderNotice();
    }, 14000);
  }

  function renderNotice() {
    const box = state.noticeBox;
    if (!box) return;
    const notice = state.notice;
    if (state.card) state.card.hidden = !pickPrimary(state.works) && !notice;
    box.replaceChildren();
    box.hidden = !notice;
    if (!notice) return;
    box.dataset.kind = notice.kind || "info";
    box.appendChild(el("span", "cw-notice-text", notice.text));
    const close = button("知道了", () => {
      state.notice = null;
      if (state.noticeTimer) {
        clearTimeout(state.noticeTimer);
        state.noticeTimer = 0;
      }
      renderNotice();
    }, "cw-notice-close", "关闭提示");
    close.setAttribute("aria-label", "关闭提示");
    box.appendChild(close);
  }

  // ── 请求层：会话或页面切换后，旧响应一律作废 ──────────────────────────────
  function staleError() {
    const err = new Error("响应已过期：会话或页面已经切换");
    err.stale = true;
    return err;
  }

  function isStale(err) {
    return Boolean(err && err.stale);
  }

  function mark() {
    return {generation: state.generation, session: sessionId()};
  }

  function markStale(snapshot) {
    return !snapshot || snapshot.generation !== state.generation || !snapshot.session || snapshot.session !== sessionId();
  }

  async function call(method, payload, snapshot) {
    if (!state.host || typeof state.host.rpc !== "function") throw new Error("组件没有接到 RPC，无法读取工作状态");
    const point = snapshot || mark();
    if (!point.session) throw new Error("当前没有可用的会话，未发送请求");
    if (markStale(point)) throw staleError();
    // payload 不能覆盖 sessionId：会话身份只由宿主注入值决定。
    const body = Object.assign({}, payload || {}, {sessionId: point.session});
    const result = await state.host.rpc(method, body);
    if (markStale(point)) throw staleError();
    return result && typeof result === "object" ? result : {};
  }

  let idSeq = 0;

  // 稳定 requestId：同一件事（同一工作、同一段文字）失败重试复用同一个 ID。
  function requestStorageKey(key) { return JSON.stringify(['newbee.work.request', sessionId(), key]); }
  function requestIdFor(key) {
    let existing = state.requestIds.get(key);
    try { existing = existing || sessionStorage.getItem(requestStorageKey(key)); } catch (_) {}
    if (existing) { state.requestIds.set(key, existing); return existing; }
    idSeq += 1;
    const id = 'cw-' + Date.now().toString(36) + '-' + idSeq.toString(36) + '-' + Math.random().toString(36).slice(2, 10);
    state.requestIds.set(key, id);
    try { sessionStorage.setItem(requestStorageKey(key), id); } catch (_) {}
    return id;
  }
  function releaseRequestId(key) {
    state.requestIds.delete(key);
    try { sessionStorage.removeItem(requestStorageKey(key)); } catch (_) {}
  }


  // ── 数据整理：只读展示；字段缺失时用中性文案，不猜进度 ───────────────────
  function asText(value) {
    if (value == null) return "";
    if (typeof value === "string") return value;
    if (typeof value === "number" || typeof value === "boolean") return String(value);
    return "";
  }

  function asList(value) {
    if (value == null || value === "") return [];
    return Array.isArray(value) ? value : [value];
  }

  function textOf(value, limit) {
    const parts = asList(value)
      .map((item) => {
        if (item && typeof item === "object") {
          return asText(item.text || item.summary || item.content || item.path || item.label);
        }
        return asText(item);
      })
      .filter((text) => text.trim() !== "");
    return clip(parts.join("\n"), limit || TEXT_LIMIT);
  }

  function stageFromStatus(status) {
    if (status === "queued") return "queued";
    if (status === "running") return "working";
    if (status === "blocked") return "blocked";
    if (status === "pending_review") return "needs_review";
    if (status === "done" || status === "failed" || status === "cancelled") return "ended";
    return "unknown";
  }

  function normalizeQuestion(question) {
    if (!question || typeof question !== "object") return null;
    const id = asText(question.id);
    if (!id) return null;
    return {
      id: id,
      question: asText(question.question || question.text) || "需要你确认一个会影响结果的选项。",
      taskTitle: asText(question.task_title || question.taskTitle),
      kind: asText(question.kind),
      options: asList(question.options)
        .map((option) => {
          if (option && typeof option === "object") {
            const value = asText(option.value != null ? option.value : option.id);
            return {value: value, label: asText(option.label || option.text || option.value) || value};
          }
          return {value: asText(option), label: asText(option)};
        })
        .filter((option) => option.label !== "")
    };
  }

  function normalizeResult(result) {
    if (!result || typeof result !== "object") return {content: "", evidence: "", limitations: ""};
    return {
      content: textOf(result.content, TEXT_LIMIT),
      fullContent: asText(result.content),
      evidence: textOf(result.evidence || result.verification, TEXT_LIMIT),
      limitations: textOf(result.limitations || result.unverified, 1200)
    };
  }

  function normalizeInput(input) {
    if (input == null) return {text: "", adopted: false, received: false};
    if (typeof input !== "object") return {text: asText(input), adopted: false, received: true};
    const text = asText(input.text || input.content || input.summary);
    const word = asText(input.state || input.status || input.delivery).toLowerCase();
    const adopted = Number(input.consumed_at) > 0 || input.adopted === true || input.applied === true || ADOPTED_WORDS.has(word);
    const received = adopted || input.received === true || word === "" || RECEIVED_WORDS.has(word);
    return {text: text, adopted: adopted, received: received};
  }

  function normalizeCoordination(value) {
    if (!value || typeof value !== "object") return null;
    const children = asList(value.children).map((child) => {
      if (!child || typeof child !== "object") return null;
      return {
        id: asText(child.id),
        title: asText(child.title) || "未命名分工",
        status: asText(child.status) || "queued",
        waitingFor: asText(child.waiting_for),
        scope: asText(child.scope),
        dependsOn: asList(child.depends_on).map((id) => asText(id)).filter(Boolean),
        activity: textOf(child.activity, 400),
        nextStep: asText(child.next_step),
        summary: textOf(child.summary, 600),
        question: normalizeQuestion(child.question)
      };
    }).filter((child) => child && child.id);
    return {
      phase: asText(value.phase) || "planning",
      summary: textOf(value.summary, 800),
      concurrency: Number(value.concurrency) || 3,
      total: Number(value.total) || children.length,
      completed: Number(value.completed) || 0,
      children: children
    };
  }

  function normalizeWork(raw) {
    const work = raw && typeof raw === "object" ? raw : {};
    const status = asText(work.status) || "queued";
    return {
      id: asText(work.id),
      title: asText(work.title) || "当前工作",
      status: status,
      stage: asText(work.stage) || stageFromStatus(status),
      originSessionId: asText(work.origin_session_id),
      sourceRoot: asText(work.source_root),
      workspacePath: asText(work.workspace_path),
      isolated: work.isolated === true,
      question: normalizeQuestion(work.question),
      coordination: normalizeCoordination(work.coordination),
      summary: asText(work.summary),
      result: normalizeResult(work.result),
      applyState: asText(work.apply_state),
      activity: textOf(work.activity, 2400),
      nextStep: asText(work.next_step),
      revision: work.revision == null ? "" : String(work.revision),
      contextRevision: work.context_revision == null ? "" : String(work.context_revision),
      executionGeneration: work.execution_generation == null ? "" : String(work.execution_generation),
      updatedAt: asText(work.updated_at || work.updated),
      inputs: asList(work.inputs).map(normalizeInput).filter((input) => input.text !== "")
    };
  }

  function worksFrom(result) {
    if (!result) return [];
    const raw = Array.isArray(result) ? result : result.works;
    return asList(raw).map(normalizeWork).filter((work) => work.id !== "");
  }

  function statusOf(work) {
    return STATUS[work.status] || {label: work.status || "状态未知", tone: "wait"};
  }

  function stageInfo(work) {
    return STAGE[work.stage] || {label: work.stage || "状态未知", hint: "服务端没有给出这一阶段的说明；以实际回执为准。"};
  }

  function isActive(work) {
    if (!work) return false;
    if (!ACTIVE_STATUS.has(work.status)) return false;
    return ACTIVE_STAGE.has(work.stage);
  }

  function foreignWork(work) {
    return Boolean(work && work.originSessionId && work.originSessionId !== sessionId());
  }

  // ── 渲染：全部用 textContent 构建，任何用户文本都不会被当成标记 ───────────
  function pickPrimary(works) {
    if (!works.length) return null;
    if (state.selectedWorkId) {
      const chosen = works.find((work) => work.id === state.selectedWorkId);
      if (chosen) return chosen;
    }
    // 本会话自己的工作优先：不会因为别的工作卡在前面就错过本会话的补充。
    const own = works.filter((work) => !foreignWork(work));
    const scoped = own.length ? own : works;
    const active = scoped.filter(isActive);
    const pool = active.length ? active : scoped;
    return pool.slice().sort((a, b) => {
      const pa = STAGE_PRIORITY[a.stage] == null ? 7 : STAGE_PRIORITY[a.stage];
      const pb = STAGE_PRIORITY[b.stage] == null ? 7 : STAGE_PRIORITY[b.stage];
      if (pa !== pb) return pa - pb;
      return String(b.updatedAt || "").localeCompare(String(a.updatedAt || ""));
    })[0];
  }

  function pendingTexts(work) {
    const sent = state.sent.get(work.id) || [];
    const known = new Set(work.inputs.map((input) => input.text.trim()));
    return sent.filter((text) => !known.has(text.trim()));
  }

  function signature(primary, works, sid) {
    const review = primary ? state.reviewCache.get(primary.id) : null;
    return JSON.stringify({
      sid: sid,
      selected: state.selectedWorkId,
      list: works.map((work) => [work.id, work.status, work.stage, work.revision, pendingTexts(work).length]),
      primary: primary
        ? [
            primary.title, primary.status, primary.stage, primary.summary, primary.applyState,
            primary.nextStep, primary.workspacePath, primary.sourceRoot, primary.isolated,
            primary.revision, primary.contextRevision, primary.executionGeneration,
            primary.question ? [primary.question.id, primary.question.question, primary.question.options.map((o) => o.value)] : null,
            primary.activity.length, primary.result.content.length,
            primary.inputs.map((input) => (input.adopted ? "A" : input.received ? "R" : "-")).join("")
          ]
        : null,
      expanded: Array.from(state.expanded),
      busy: Array.from(state.busy),
      confirm: Array.from(state.confirm),
      receipts: Array.from(state.receipts.entries()),
      review: review ? [review.review ? review.review.patch_sha256 || "" : "", review.error || ""] : null,
      answer: state.answerDraft,
      notice: state.notice ? [state.notice.text, state.notice.kind] : null
    });
  }

  function captureFocus() {
    const node = typeof document !== "undefined" ? document.activeElement : null;
    if (!node || !state.card || !state.card.contains(node) || !node.dataset || !node.dataset.cwKey) return null;
    return {key: node.dataset.cwKey, start: node.selectionStart, end: node.selectionEnd};
  }

  function restoreFocus(snapshot) {
    if (!snapshot || !state.card) return;
    const nodes = state.card.querySelectorAll("[data-cw-key]");
    for (const node of nodes) {
      if (node.dataset && node.dataset.cwKey === snapshot.key) {
        try {
          node.focus({preventScroll: true});
          if (snapshot.start != null && typeof node.setSelectionRange === "function") {
            node.setSelectionRange(snapshot.start, snapshot.end == null ? snapshot.start : snapshot.end);
          }
        } catch (err) {
          /* 焦点恢复失败不影响内容 */
        }
        return;
      }
    }
  }

  function render(force) {
    if (!state.card) return;
    if (state.composing && !force) {
      state.pendingRender = true;
      return;
    }
    const sid = sessionId();
    const primary = pickPrimary(state.works);
    updateComposerStart(sid);
    const sig = signature(primary, state.works, sid);
    if (!force && sig === state.sig) {
      renderNotice();
      return;
    }
    const focus = captureFocus();
    state.sig = sig;
    const host = state.card;
    host.replaceChildren();
    if (primary) host.classList.remove('cw-empty-state'); else host.classList.add('cw-empty-state');
    host.dataset.session = sid;
    host.hidden = !primary && !state.notice;
    if (!primary) {
      state.noticeBox = el("div", "cw-notice");
      state.noticeBox.hidden = true;
      state.noticeBox.setAttribute("aria-live", "polite");
      host.appendChild(state.noticeBox);
      renderNotice();
      restoreFocus(focus);
      return;
    }

    const head = el("div", "cw-head");
    const heading = el("div", "cw-heading");
    heading.appendChild(el("span", "cw-kicker", "当前工作"));
    const titleWrap = el("div", "cw-title-wrap");
    titleWrap.appendChild(el("span", "cw-title", primary ? primary.title : "没有后台工作"));
    const directory = el("span", "cw-dir", primary && primary.coordination ? (primary.applyState === 'applied' ? '成果已应用到项目' : '独立执行 · 成果确认后应用到项目') : directoryLabel(primary));
    directory.title = directoryLabel(primary);
    titleWrap.appendChild(directory);
    heading.appendChild(titleWrap);

    const right = el("div", "cw-head-right");
    if (primary) {
      const status = statusOf(primary);
      const pill = el("span", "cw-status", status.label);
      pill.dataset.tone = status.tone;
      pill.setAttribute("role", "status");
      pill.setAttribute("aria-live", "polite");
      right.appendChild(pill);
      // 阶段与状态说的是同一件事时只显示一次，避免“已结束 · 已结束”。
      const stageLabel = stageInfo(primary).label;
      if (stageLabel !== status.label) right.appendChild(el("span", "cw-stage", stageLabel));
    }

    head.append(heading, right);
    host.appendChild(head);

    state.noticeBox = el("div", "cw-notice");
    state.noticeBox.hidden = true;
    state.noticeBox.setAttribute("aria-live", "polite");
    host.appendChild(state.noticeBox);
    renderNotice();

    if (!sid) {
      host.appendChild(el("p", "cw-empty", "还没有选中会话。选一个会话后，这里才显示当前工作和「分工执行」。"));
      restoreFocus(focus);
      return;
    }
    if (!primary) {
      host.appendChild(el("p", "cw-empty", "输入一个任务目标，点「分工执行」，系统会安排分工并汇总交付。普通聊天仍直接发送。"));
      restoreFocus(focus);
      return;
    }
    if (foreignWork(primary)) {
      const note = el("p", "cw-muted", "这条工作属于另一个会话（" + primary.originSessionId + "），这里只显示，不会接收本会话的补充。");
      host.appendChild(note);
    }
    const coordination = coordinationBlock(primary);
    if (coordination) host.appendChild(coordination);
    host.appendChild(workBody(primary));
    if (state.works.length > 1) host.appendChild(otherWorks(primary, state.works));
    restoreFocus(focus);
  }

  function directoryLabel(work) {
    if (!work) return sessionId() ? "目录由会话决定" : "未选择会话";
    if (work.isolated) {
      const dir = work.workspacePath || work.sourceRoot;
      const suffix = work.applyState === 'applied' ? ' · 已应用到项目' : ' · 结果需应用到项目';
      return dir ? '独立工作区 · ' + dir + suffix : '独立工作区' + suffix;
    }
    if (work.sourceRoot) return "实际目录 · " + work.sourceRoot;
    if (work.workspacePath) return "实际目录 · " + work.workspacePath;
    const fallback = directoryFallback();
    return fallback ? "会话目录（展示用）· " + fallback : "目录由服务端会话确定";
  }

  function updateComposerStart(sid) {
    const node = state.composerStart;
    if (!node) return;
    const busy = state.busy.has("start");
    const hasWork = state.works.some(isActive);
    const hint = hasWork
      ? "本对话正在处理一项工作；直接发送补充，独立工作请用新对话"
      : "自动拆分任务、独立执行并汇总结果；普通发送仍按原路径进行";
    node.dataset.state = busy ? 'starting' : hasWork ? 'working' : 'idle';
    node.setAttribute('aria-busy', String(busy));
    node.title = (busy ? '正在安排分工' : hasWork ? '分工执行中' : '分工执行') + '：' + hint;
    node.setAttribute('aria-label', hasWork ? '分工正在执行，请在当前输入框发送补充要求' : '将当前输入框的任务交给多个执行者分工完成');
    node.disabled = busy || !sid || hasWork;
    if (!sid) node.title = "先选择一个会话";
    node.dataset.cwKey = "start";
  }

  function coordinationStatus(child) {
    if (child.waitingFor === "dependencies") return "等待上游";
    if (child.waitingFor === "capacity") return "等待执行";
    const labels = {pending: "等待执行", claimed: "已安排", queued: "排队中", running: "进行中", blocked: "需要处理", pending_review: "已交付", done: "已交付", failed: "未完成", cancelled: "已结束"};
    return labels[child.status] || "状态未知";
  }

  function coordinationBlock(work) {
    const coordination = work.coordination;
    if (!coordination) return null;
    const box = el("details", "cw-coordination");
    box.open = state.coordinationOpen.has(work.id) ? state.coordinationOpen.get(work.id) : work.stage !== "needs_answer" && work.stage !== "needs_review";
    box.addEventListener("toggle", () => state.coordinationOpen.set(work.id, box.open));
    const heading = el("summary", "cw-coordination-summary");
    heading.appendChild(el("strong", null, "任务分工"));
    heading.appendChild(el("span", "cw-coordination-count", coordination.total ? coordination.completed + "/" + coordination.total + " 项 · " + coordinationPhaseLabel(coordination.phase) : "正在规划分工"));
    box.appendChild(heading);
    if (coordination.summary) box.appendChild(el("p", "cw-coordination-summary-text", coordination.summary));
    if (!coordination.children.length) box.appendChild(el("p", "cw-coordination-meta", "正在核对项目和任务边界，随后在这里显示分工。"));
    const list = el("ul", "cw-coordination-list");
    const byId = new Map(coordination.children.map((child) => [child.id, child]));
    coordination.children.forEach((child) => {
      const item = el("li", "cw-coordination-item");
      const line = el("div", "cw-coordination-item-head");
      const title = el("span", "cw-coordination-title", child.title);
      title.title = child.scope || child.title;
      line.appendChild(title);
      line.appendChild(el("span", "cw-coordination-status", coordinationStatus(child)));
      item.appendChild(line);
      const dependencies = child.dependsOn.map((id) => byId.get(id)).filter(Boolean).map((dep) => dep.title);
      if (dependencies.length) item.appendChild(el("p", "cw-coordination-meta", "依赖：" + dependencies.join("、")));
      const activity = child.activity || child.nextStep || child.summary;
      if (activity) item.appendChild(el("p", "cw-coordination-meta", activity));
      list.appendChild(item);
    });
    box.appendChild(list);
    return box;
  }

  function coordinationPhaseLabel(phase) {
    return {planning: "规划中", executing: "执行中", integrating: "集成验证", reviewing: "待验收", completed: "已完成", ended: "已结束"}[phase] || "处理中";
  }

  function workBody(work) {
    const box = el("div", "cw-body");
    box.dataset.work = work.id;
    const info = stageInfo(work);
    box.appendChild(el("p", "cw-hint", work.nextStep ? info.hint + " 下一步：" + work.nextStep : info.hint));
    if (work.inputs.length || pendingTexts(work).length) box.appendChild(supplementLine(work));
    const receipt = state.receipts.get(work.id);
    if (receipt) {
      const node = el("p", "cw-receipt", "回执：" + receipt.text);
      node.dataset.tone = receipt.kind || "info";
      node.dataset.cwKey = "receipt:" + work.id;
      box.appendChild(node);
    }
    if (work.stage === "needs_answer") box.appendChild(questionBlock(work));
    if (showsResult(work)) box.appendChild(resultBlock(work));
    box.appendChild(actionRow(work));
    return box;
  }

  function supplementLine(work) {
    const parts = [];
    if (work.inputs.length) {
      const adopted = work.inputs.filter((input) => input.adopted).length;
      const waiting = work.inputs.filter((input) => input.received && !input.adopted).length;
      parts.push("服务端已收到 " + work.inputs.length + " 条补充");
      parts.push(adopted ? "已采用 " + adopted + " 条" : "尚无可确认被采用的补充");
      if (waiting) parts.push("等待采用 " + waiting + " 条");
    }
    const pending = pendingTexts(work);
    if (pending.length) parts.push("本会话已送出 " + pending.length + " 条，服务端暂未回报状态");
    const node = el("p", "cw-supply", parts.join(" · "));
    node.dataset.cwKey = "supply:" + work.id;
    const last = work.inputs.length ? work.inputs[work.inputs.length - 1].text : pending[pending.length - 1];
    if (last) node.appendChild(el("span", "cw-supply-text", "最近一条：" + clip(last, 160)));
    return node;
  }

  function questionBlock(work) {
    const box = el("section", "cw-question");
    box.setAttribute("aria-label", "需要你答复的问题");
    const question = work.question;
    if (!question) {
      box.appendChild(el("p", "cw-question-missing", "工作正在等待答复，但服务端还没有返回问题内容。可以稍后刷新查看；问题不会因为没回答而被当成同意。"));
      return box;
    }
    box.appendChild(el("p", "cw-question-text", question.question));
    if (question.taskTitle) box.appendChild(el("p", "cw-question-source", "来自分工：" + question.taskTitle));
    const busy = state.busy.has("answer:" + work.id);
    if (question.options.length) {
      const options = el("div", "cw-options");
      question.options.forEach((option) => {
        const node = button(option.label, () => answer(work, question, option.value, "value"), "cw-option");
        node.disabled = busy;
        node.dataset.cwKey = "option:" + work.id + ":" + option.value;
        options.appendChild(node);
      });
      box.appendChild(options);
    }
    const form = el("div", "cw-answer");
    const input = el(question.options.length ? "input" : "textarea", "cw-answer-input");
    if (input.tagName === "TEXTAREA") input.rows = 2;
    input.value = state.answerDraft;
    input.placeholder = question.options.length ? "也可以直接写下你的决定…" : "写下你的决定…";
    input.setAttribute("aria-label", "回答这个问题");
    input.dataset.cwKey = "answer:" + work.id;
    input.addEventListener("compositionstart", () => {
      state.composing = true;
    });
    input.addEventListener("compositionend", () => {
      state.composing = false;
      if (state.pendingRender) {
        state.pendingRender = false;
        render(true);
      }
    });
    input.addEventListener("input", () => {
      state.answerDraft = input.value.slice(0, ANSWER_LIMIT);
    });
    input.addEventListener("keydown", (event) => {
      if (event.key !== "Enter" || event.shiftKey) return;
      // IM composing 中的 Enter 只用于选词，不能当成提交。
      if (event.isComposing || state.composing || event.keyCode === 229) return;
      const shortcut = event.ctrlKey === true || event.metaKey === true;
      if (input.tagName === "TEXTAREA" && !shortcut) return;
      event.preventDefault();
      answer(work, question, input.value, "text");
    });
    const send = button("答复", () => answer(work, question, input.value, "text"), "cw-primary");
    send.disabled = busy;
    send.dataset.cwKey = "answer-send:" + work.id;
    form.append(input, send);
    box.appendChild(form);
    return box;
  }

  function showsResult(work) {
    if (work.stage === "needs_review" || work.stage === "ended") return true;
    // 正在做的工作也可能已经有真实活动记录：可展开查看，但不显示“结果”。
    return work.result.content !== "" || work.result.evidence !== "" || work.applyState !== "" || work.activity !== "";
  }

  function resultBlock(work) {
    const box = el("section", "cw-result");
    box.setAttribute("aria-label", "过程与结果");
    const showsApply = work.isolated || work.applyState !== "" || work.result.content !== "" || work.result.evidence !== "";
    const expanded = state.expanded.has(work.id);
    const toggle = button(expanded ? "收起过程" : "查看过程", () => {
      if (state.expanded.has(work.id)) state.expanded.delete(work.id);
      else state.expanded.add(work.id);
      render(true);
      if (!expanded && work.isolated && work.stage === "needs_review" && !state.reviewCache.has(work.id)) review(work);
    }, "cw-ghost");
    toggle.setAttribute("aria-expanded", expanded ? "true" : "false");
    toggle.dataset.cwKey = "toggle:" + work.id;
    box.appendChild(toggle);
    if (showsApply) box.appendChild(applyStateLine(work));
    // 独立工作区的主要动作（比较改动 / 应用并完成）不要求先展开过程。
    if (work.isolated && work.applyState !== "applied") box.appendChild(reviewBlock(work));
    if (!expanded) return box;

    const details = el("div", "cw-details");
    if (work.summary) details.appendChild(labelled("摘要", work.summary));
    if (work.activity) details.appendChild(labelled("过程", work.activity, true));
    if (work.result.content) details.appendChild(labelled("结果", work.result.content, true));
    if (work.result.fullContent) {
      details.appendChild(button('下载完整成果', () => {
        const blob = new Blob([work.result.fullContent], {type:'text/markdown;charset=utf-8'});
        const url = URL.createObjectURL(blob);
        const link = document.createElement('a'); link.href = url; link.download = 'newbee-work-' + work.id + '.md';
        link.click(); setTimeout(() => URL.revokeObjectURL(url), 1000);
      }, 'cw-ghost'));
    }

    if (work.result.evidence) details.appendChild(labelled("验证", work.result.evidence, true));
    if (work.result.limitations) details.appendChild(labelled("未覆盖 / 限制", work.result.limitations, true));
    if (work.executionGeneration) details.appendChild(el("p", "cw-review-meta", "执行代次：" + work.executionGeneration + " · 版本：" + (work.revision || "未提供")));
    if (!work.summary && !work.activity && !work.result.content) {
      details.appendChild(el("p", "cw-muted", "服务端还没有返回过程或结果内容。"));
    }
    box.appendChild(details);

    return box;
  }

  function labelled(title, text, mono) {
    const wrap = el("div", "cw-detail");
    wrap.appendChild(el("span", "cw-detail-title", title));
    wrap.appendChild(el("pre", "cw-detail-text" + (mono ? " cw-mono" : ""), clip(text)));
    return wrap;
  }

  function applyStateLine(work) {
    const applied = work.applyState;
    if (applied === 'text_accepted') return el('p', 'cw-apply cw-applied', '文本成果已确认完成，无文件变更。');
    if (work.isolated) {
      if (applied === "applied") return el("p", "cw-apply cw-applied", "已应用到这个项目：结果已写入目标目录并完成核对。");
      if (applied === "applied_pending_check" || applied === "checking") {
        return el("p", "cw-apply cw-pending-check", "已应用，检查待完成：文件已写入，最终验证还没结束；重试只会做剩余步骤。");
      }
      if (applied === "conflict") return el("p", "cw-apply cw-conflict", "目标已变化，需要重新核对；现有文件保持原样，没有覆盖。");
      return el("p", "cw-apply cw-pending", "结果在独立工作区，尚未写入项目；确认后才应用。");
    }
    if (applied === "applied") return el("p", "cw-apply cw-applied", "改动已在当前会话目录，不需要再应用一次。");
    if (applied === 'text_accepted') return el('p', 'cw-apply cw-applied', '文本成果已确认完成，没有文件改动需要应用。');
    if (applied === "") return el("p", "cw-apply cw-current", "改动在当前会话目录（非隔离），这里不需要「应用」。");
    return el("p", "cw-apply cw-current", "采用状态：" + applied);
  }

  function kindLabel(kind) {
    if (kind === "add" || kind === "added" || kind === "create") return "新增";
    if (kind === "delete" || kind === "deleted" || kind === "remove") return "删除";
    if (kind === "rename" || kind === "move") return "移动";
    return "修改";
  }

  function shortHash(value) {
    const text = asText(value);
    return text ? text.slice(0, 12) : "（未提供）";
  }

  function reviewBlock(work) {
    const box = el("div", "cw-review");
    const cache = state.reviewCache.get(work.id);
    const busy = state.busy.has("review:" + work.id);
    const refreshBtn = button(busy ? "正在比较…" : cache ? "重新比较" : "比较改动", () => review(work), "cw-ghost");
    refreshBtn.disabled = busy;
    refreshBtn.dataset.cwKey = "review:" + work.id;
    box.appendChild(refreshBtn);

    if (!cache) {
      box.appendChild(el("p", "cw-muted", "还没拿到改动清单。点「比较改动」查看会写入哪些文件。"));
      return box;
    }
    if (cache.error) {
      box.appendChild(el("p", "cw-error", "比较没有完成：" + cache.error));
      return box;
    }
    const view = cache.review;
    const files = asList(view.files);
    const conflicts = asList(view.conflicts);
    if (asText(view.summary)) box.appendChild(labelled("改动摘要", asText(view.summary)));
    box.appendChild(el("p", "cw-review-meta", "目标目录：" + (asText(view.target_root) || "由服务端核对")));
    box.appendChild(el("p", "cw-review-meta", "待应用版本：" + shortHash(view.patch_sha256) + " · 变更 " + files.length + " 个文件"));

    if (files.length) {
      const list = el("ul", "cw-files");
      files.forEach((file) => {
        const item = el("li", "cw-file");
        item.appendChild(el("span", "cw-file-kind", kindLabel(asText(file && file.kind))));
        item.appendChild(el("span", "cw-file-path", asText(file && file.path) || "(未命名文件)"));
        if (file && (file.before != null || file.after != null)) {
          const details = el("details", "cw-diff");
          details.appendChild(el("summary", null, "查看前后内容"));
          if (file.before != null) details.appendChild(labelled("应用前", clip(asText(file.before), 1200), true));
          if (file.after != null) details.appendChild(labelled("应用后", clip(asText(file.after), 1600), true));
          item.appendChild(details);
        }
        list.appendChild(item);
      });
      box.appendChild(list);
    } else {
      box.appendChild(el("p", "cw-muted", view.no_changes === true ? '核对完成：本次没有文件变更，可以在下方确认完成。' : '服务端没有返回文件清单；核对不到具体改动前不会应用。'));
    }

    if (conflicts.length) {
      const box2 = el("div", "cw-conflict-box");
      box2.appendChild(el("p", "cw-error", "目标项目有新修改，不能直接覆盖："));
      const list = el("ul", "cw-files");
      conflicts.forEach((conflict) => {
        const item = el("li", "cw-file");
        const text = conflict && typeof conflict === "object"
          ? (asText(conflict.path || conflict.file) + (asText(conflict.reason) ? " · " + asText(conflict.reason) : ""))
          : asText(conflict);
        item.appendChild(el("span", "cw-file-path", text || "未知冲突"));
        list.appendChild(item);
      });
      box2.appendChild(list);
      box.appendChild(box2);
      return box;
    }

    const applyBusy = state.busy.has("apply:" + work.id);
    const applyBtn = button(applyBusy ? "正在核对并应用…" : "应用并完成", () => apply(work), "cw-primary");
    applyBtn.disabled = applyBusy || !asText(view.patch_sha256) || !files.length;
    if (!asText(view.patch_sha256)) applyBtn.title = "没有改动哈希，无法安全应用";
    applyBtn.dataset.cwKey = "apply:" + work.id;
    box.appendChild(applyBtn);
    box.appendChild(el("p", "cw-muted", "应用前会再核对一次版本与哈希；目标有变化就停止并保留原文件，不覆盖。"));
    return box;
  }

  function stopKey(work) {
    return "stop:" + work.id;
  }

  function actionRow(work) {
    const row = el("div", "cw-actions");
    const stage = work.stage;
    const canPause = isActive(work) && (stage === "working" || stage === "queued" || stage === "needs_review" || stage === "needs_answer");
    const canResume = stage === "paused";
    const canStop = stage !== "ended" && work.status !== "cancelled";
    const canRetry = work.status === "failed" || stage === "blocked" || stage === "unknown";

    if (canPause) row.appendChild(controlButton(work, "pause", "暂停", "暂停推进；已有修改保留"));
    if (canResume) row.appendChild(controlButton(work, "resume", "继续", "恢复推进"));
    if (canRetry) row.appendChild(controlButton(work, "retry", "重试", "复用同一工作与输入继续，不重放已发生的外部操作"));
    if (canStop) {
      if (state.confirm.has(stopKey(work))) {
        const box = el("span", "cw-confirm");
        box.appendChild(el("span", "cw-confirm-text", "结束工作？不再推进，已有修改和历史保留；结束不表示撤回。"));
        box.appendChild(controlButton(work, "stop", "确认结束", "停止推进", true));
        box.appendChild(button("取消", () => {
          state.confirm.delete(stopKey(work));
          render(true);
        }, "cw-ghost"));
        row.appendChild(box);
      } else {
        const node = button("结束工作", () => {
          state.confirm.add(stopKey(work));
          render(true);
        }, "cw-ghost", "结束工作；不撤回已有修改");
        node.dataset.cwKey = "stop-ask:" + work.id;
        row.appendChild(node);
      }
    }
    if (showsComplete(work)) {
      const busy = state.busy.has("complete:" + work.id);
      const node = button(busy ? "正在确认…" : "确认完成", () => complete(work), "cw-primary", "为纯文本成果关闭这条工作记录");
      node.disabled = busy;
      node.dataset.cwKey = "complete:" + work.id;
      row.appendChild(node);
    }
    if (!row.childNodes.length) {
      row.appendChild(el("span", "cw-muted", stage === "ended" ? "这条工作已结束；需要新任务时直接说新的要求。" : "这个阶段没有需要你操作的动作。"));
    }
    return row;
  }

  function showsComplete(work) {
    const review = state.reviewCache.get(work.id);
    if (work.isolated && !(review && review.review && review.review.no_changes === true)) return false;
    if (work.status !== "done" && work.status !== "pending_review") return false;
    return work.applyState !== "applied";
  }

  function controlButton(work, action, label, title, confirmed) {
    const busy = state.busy.has("control:" + work.id + ":" + action);
    const node = button(busy ? "处理中…" : label, () => control(work, action, confirmed), action === "stop" ? "cw-danger" : "cw-ghost", title);
    node.disabled = busy;
    node.dataset.cwKey = "control:" + work.id + ":" + action;
    return node;
  }

  function otherWorks(primary, works) {
    const box = el("div", "cw-others");
    const rest = works.filter((work) => work.id !== primary.id);
    box.appendChild(el("span", "cw-others-title", "其他工作（" + rest.length + "），点标题切换查看"));
    const list = el("ul", "cw-other-list");
    rest.forEach((work) => {
      const item = el("li", "cw-other");
      const node = button(work.title, () => {
        state.selectedWorkId = state.selectedWorkId === work.id ? "" : work.id;
        render(true);
        if (work.isolated && !state.reviewCache.has(work.id)) review(work);
      }, "cw-other-btn");
      node.dataset.cwKey = "other:" + work.id;
      item.appendChild(node);
      item.appendChild(el("span", "cw-other-status", statusOf(work).label));
      list.appendChild(item);
    });
    box.appendChild(list);
    return box;
  }

  // ── 刷新与轮询 ──────────────────────────────────────────────────────────
  function schedule() {
    if (state.timer) clearTimeout(state.timer);
    state.timer = 0;
    if (!state.host || !sessionId()) return;
    if (typeof document !== "undefined" && document.hidden) return;
    state.timer = setTimeout(() => {
      state.timer = 0;
      refresh();
    }, state.delay || POLL_FAST);
  }

  async function refresh() {
    const sid = sessionId();
    if (!sid) {
      resetSession("");
      render(true);
      return [];
    }
    if (state.sessionId !== sid) resetSession(sid);
    const point = mark();
    if (state.refreshing && state.refreshing.session === point.session && state.refreshing.generation === point.generation) {
      return state.refreshing.promise;
    }
    const runner = (async () => {
      try {
        const result = await call(RPC.list, {}, point);
        if (markStale(point)) return state.works;
        state.works = worksFrom(result);
        state.failed = 0;
        state.delay = state.works.some(isActive) ? POLL_FAST : POLL_IDLE;
        render();
      } catch (err) {
        if (isStale(err)) return state.works;
        if (String(err && err.message || "").indexOf("没有可用的会话") >= 0) return state.works;
        state.failed += 1;
        state.delay = Math.min(POLL_IDLE, POLL_FAST * Math.pow(2, Math.min(state.failed, 2)));
        if (state.failed === 1) say("读取工作状态失败：" + messageOf(err) + "（会自动重试）", "err");
        render();
      } finally {
        if (state.refreshing && state.refreshing.promise === runner) state.refreshing = null;
        schedule();
      }
      return state.works;
    })();
    state.refreshing = {promise: runner, session: point.session, generation: point.generation};
    return runner;
  }

  function resetSession(sid) {
    state.generation += 1;
    state.sessionId = sid;
    state.works = [];
    state.receipts.clear();
    state.sent.clear();
    state.reviewCache.clear();
    state.expanded.clear();
    state.coordinationOpen.clear();
    state.confirm.clear();
    state.busy.clear();
    state.requestIds.clear();
    state.answerDraft = "";
    state.selectedWorkId = "";
    state.sig = "";
    state.notice = null;
    if (state.noticeTimer) {
      clearTimeout(state.noticeTimer);
      state.noticeTimer = 0;
    }
    if (state.timer) clearTimeout(state.timer);
    state.timer = 0;
    state.refreshing = null;
  }

  function onVisibility() {
    if (typeof document === "undefined") return;
    if (document.hidden) {
      if (state.timer) clearTimeout(state.timer);
      state.timer = 0;
      return;
    }
    refresh();
  }

  // ── 动作 ────────────────────────────────────────────────────────────────
  function readDraft() {
    if (!state.host || typeof state.host.readDraft !== "function") return "";
    try {
      const value = state.host.readDraft();
      return typeof value === "string" ? value : "";
    } catch (err) {
      return "";
    }
  }

  function writeDraft(text) {
    if (!state.host || typeof state.host.writeDraft !== "function") return;
    try {
      state.host.writeDraft(text);
    } catch (err) {
      /* 宿主写草稿失败不影响工作请求 */
    }
  }

  function appendUser(text) {
    if (!state.host || typeof state.host.appendUser !== "function") return;
    try {
      state.host.appendUser(text);
      if (state.host && typeof state.host.clearAttachments === 'function') state.host.clearAttachments();
    } catch (err) {
      /* 会话回显失败不影响后台工作 */
    }
  }

  function recordSent(workId, text) {
    if (!workId) return;
    const list = state.sent.get(workId) || [];
    if (!list.some((item) => item === text)) list.push(clip(text, 400));
    state.sent.set(workId, list.slice(-20));
  }

  async function start() {
    const sid = sessionId();
    if (!sid) {
      say("先选择一个会话，才能把这件事交给后台。", "warn");
      return false;
    }
    const draft = readDraft();
    const text = String(draft || "").trim();
    if (!text) {
      say("输入框是空的：先写下要后台做什么。", "warn");
      return false;
    }
    if (state.host && typeof state.host.isUploading === 'function' && state.host.isUploading()) { say('请等待附件上传完成，草稿已保留。', 'warn'); return false; }
    if (state.busy.has("start")) return false;
    state.busy.add("start");
    render(true);
    const ids = hostUploadIds();
    const key = "start|" + text + "|" + ids.join(',');
    const requestId = requestIdFor(key);
    try {
      const payload = {text: text, requestId: requestId};
      if (ids.length) payload.uploadIds = ids;
      const result = await call(RPC.start, payload, mark());
      releaseRequestId(key);
      state.busy.delete("start");
      if (String(readDraft()).trim() === text) writeDraft("");
      appendUser(text);
      const work = result.work && typeof result.work === "object" ? normalizeWork(result.work) : null;
      if (work && work.id) {
        recordSent(work.id, text);
        state.selectedWorkId = work.id;
      }
      say(work && work.isolated ? "已在后台继续（独立工作区，结果需要应用到项目）。" : "已在后台继续；可以离开这个页面。", "ok");
      render(true);
      await refresh();
      return true;
    } catch (err) {
      state.busy.delete("start");
      render(true);
      if (isStale(err)) return false;
      say("没有交给后台：" + messageOf(err) + "（输入内容保留，可再点「后台做」重试）", "err");
      throw err;
    }
  }

  // 主 send 钩子：只有“当前有后台工作”时，才把补充交给 input 并返回 true。
  async function submit(text, uploadIds = []) {
    const value = String(text == null ? "" : text);
    const ids = Array.isArray(uploadIds) ? uploadIds.filter((id) => typeof id === 'string' && id !== '') : [];
    const trimmed = value.trim() || (ids.length ? '补充附件，请结合原工作目标查看。' : '');
    if (!trimmed) return false;
    if (!sessionId()) return false;
    const origin = sessionId();
    if (state.sessionId !== origin || state.refreshing) await refresh();
    if (sessionId() !== origin) throw staleError();
    const primary = state.works.find(work => isActive(work) && !foreignWork(work));
    if (!primary || !isActive(primary) || foreignWork(primary)) return false;
    // 补充自身不会清空主输入框：由主 send 在 submit 返回 true 后决定，失败时文字仍在。
    const key = "input|" + primary.id + "|" + trimmed + "|" + ids.join(",");
    const requestId = requestIdFor(key);
    const point = mark();
    try {
      const payload = {workId: primary.id, text: trimmed, requestId: requestId};
      if (ids.length) payload.uploadIds = ids;
      const answering = primary.stage === 'needs_answer' && primary.question;
      if (answering) payload.questionId = primary.question.id;
      const result = await call(answering ? RPC.answer : RPC.input, payload, point);

      releaseRequestId(key);
      const receipt = receiptText(result);
      state.receipts.set(primary.id, {text: receipt || "后台已收到这条补充，等待在下一安全步骤采用。", kind: receiptKind(result)});
      recordSent(primary.id, trimmed);
      if (state.host && typeof state.host.appendUser === 'function') state.host.appendUser(trimmed);
      if (receiptWord(result) === "adopted") {
        say(receipt ? "后台回执：" + receipt : "补充已被采用。", "ok");
      } else {
        say(receipt ? "后台回执：" + receipt : "后台已收到补充；采用后会显示在卡片上。", "ok");
      }
      render(true);
      await refresh();
      return true;
    } catch (err) {
      if (isStale(err)) throw err;
      say("补充没有送达后台：" + messageOf(err) + "（内容还在输入框里，可以再发一次）", "err");
      throw err;
    }
  }

  // receipt 的形状后端未固定：字符串、{text,state}、{status} 都接受，缺失时返回空串。
  function receiptText(result) {
    const receipt = result ? result.receipt : null;
    if (receipt == null) return "";
    if (typeof receipt === "string") return receipt;
    if (typeof receipt !== "object") return asText(receipt);
    return asText(receipt.text || receipt.message || receipt.state || receipt.status);
  }

  function receiptWord(result) {
    const receipt = result ? result.receipt : null;
    if (!receipt || typeof receipt !== "object") return "";
    return asText(receipt.state || receipt.status).toLowerCase();
  }

  function receiptKind(result) {
    const word = receiptWord(result);
    if (ADOPTED_WORDS.has(word)) return "ok";
    if (word === "conflict" || word === "rejected" || word === "error" || word === "failed") return "err";
    return "info";
  }

  async function answer(work, question, value, kind) {
    const text = String(value == null ? "" : value).trim();
    if (!text) {
      say("先写下你的决定再答复；空答复不会发送。", "warn");
      return false;
    }
    const busyKey = "answer:" + work.id;
    if (state.busy.has(busyKey)) return false;
    state.busy.add(busyKey);
    render(true);
    try {
      const key = 'answer|' + work.id + '|' + question.id + '|' + text;
      const payload = {workId: work.id, questionId: question.id, requestId: requestIdFor(key)};
      if (kind === "value") payload.value = clip(text, ANSWER_LIMIT);
      else payload.text = clip(text, ANSWER_LIMIT);
      const result = await call(RPC.answer, payload, mark());
      releaseRequestId(key);
      state.busy.delete(busyKey);
      state.answerDraft = "";
      const receipt = receiptText(result);
      state.receipts.set(work.id, {text: receipt || "答复已记录，工作会带着这个答案继续。", kind: "ok"});
      say(receipt ? "已记录：" + receipt : "答复已记录，工作继续。", "ok");
      render(true);
      await refresh();
      return true;
    } catch (err) {
      state.busy.delete(busyKey);
      render(true);
      if (isStale(err)) return false;
      say("答复没有记录成功：" + messageOf(err) + "（答案保留在卡片里，可重试）", "err");
      throw err;
    }
  }

  async function control(work, action, confirmed) {
    if (action === "stop" && confirmed !== true) {
      state.confirm.add(stopKey(work));
      render(true);
      return false;
    }
    const busyKey = "control:" + work.id + ":" + action;
    if (state.busy.has(busyKey)) return false;
    state.busy.add(busyKey);
    render(true);
    try {
      const result = await call(RPC.control, {workId: work.id, action: action}, mark());
      state.busy.delete(busyKey);
      state.confirm.delete(stopKey(work));
      const receipt = receiptText(result);
      const fallback = action === "stop"
        ? "已结束这条工作：不再推进，已有修改和历史保留（结束不表示撤回）。"
        : action === "pause" ? "已暂停。" : action === "resume" ? "已继续。" : "已重试。";
      state.receipts.set(work.id, {text: receipt || fallback, kind: action === "stop" ? "warn" : "ok"});
      say(receipt || fallback, action === "stop" ? "warn" : "ok");
      render(true);
      await refresh();
      return true;
    } catch (err) {
      state.busy.delete(busyKey);
      render(true);
      if (isStale(err)) return false;
      say("操作没有生效：" + messageOf(err), "err");
      throw err;
    }
  }

  async function review(work) {
    const busyKey = "review:" + work.id;
    if (state.busy.has(busyKey)) return null;
    state.busy.add(busyKey);
    render(true);
    try {
      const result = await call(RPC.review, {workId: work.id}, mark());
      state.busy.delete(busyKey);
      const view = result.review && typeof result.review === "object" ? result.review : null;
      if (!view) {
        state.reviewCache.set(work.id, {error: "服务端没有返回改动清单"});
        render(true);
        return null;
      }
      state.reviewCache.set(work.id, {review: view, at: {revision: work.revision, context: work.contextRevision}});
      render(true);
      return view;
    } catch (err) {
      state.busy.delete(busyKey);
      if (isStale(err)) {
        render(true);
        return null;
      }
      state.reviewCache.set(work.id, {error: messageOf(err)});
      render(true);
      say("比较改动失败：" + messageOf(err), "err");
      return null;
    }
  }

  function sameVersion(work, at) {
    if (!at) return true;
    return work.revision === at.revision && work.contextRevision === at.context;
  }

  async function apply(work) {
    const busyKey = "apply:" + work.id;
    if (state.busy.has(busyKey)) return false;
    const cached = state.reviewCache.get(work.id);
    if (!cached || !cached.review) {
      say("先比较改动：没有核对过的版本不会应用。", "warn");
      return false;
    }
    const sha = asText(cached.review.patch_sha256);
    if (!sha) {
      say("服务端没有给出改动哈希，不能安全应用。", "err");
      return false;
    }
    state.busy.add(busyKey);
    render(true);
    try {
      // 应用前重新核对版本：工作被推进过就要求重新比较，绝不用旧哈希写入。
      const fresh = await refresh();
      const current = (Array.isArray(fresh) ? fresh : state.works).find((item) => item.id === work.id) || work;
      if (!sameVersion(current, cached.at) || current.applyState === "conflict") {
        state.busy.delete(busyKey);
        state.reviewCache.delete(work.id);
        render(true);
        say("这条工作在你比较之后有变化，已停止应用并保留原文件；请重新比较。", "warn");
        return false;
      }
      const latest = await review(current);
      if (!latest) {
        state.busy.delete(busyKey);
        render(true);
        return false;
      }
      if (asList(latest.conflicts).length) {
        state.busy.delete(busyKey);
        render(true);
        say("目标项目有新改动，冲突未覆盖；请查看冲突文件后重新比较。", "err");
        return false;
      }
      const latestSha = asText(latest.patch_sha256);
      if (!latestSha || latestSha !== sha) {
        state.busy.delete(busyKey);
        render(true);
        say("改动在你查看后又变了（哈希不一致），没有写入；请重新比较后再应用。", "warn");
        return false;
      }
      const key = "apply|" + work.id + "|" + latestSha;
      const requestId = requestIdFor(key);
      const result = await call(RPC.apply, {workId: work.id, patchSha256: latestSha, requestId: requestId}, mark());
      releaseRequestId(key);
      state.busy.delete(busyKey);
      const receipt = receiptText(result);
      const work2 = result.work && typeof result.work === "object" ? normalizeWork(result.work) : null;
      const applied = work2 ? work2.applyState === "applied" : receiptWord(result) === "applied";
      state.receipts.set(work.id, {
        text: receipt || (applied ? "已应用到目标目录并完成核对。" : "应用请求已被服务端接收，等待核对回执。"),
        kind: applied ? "ok" : "info"
      });
      state.reviewCache.delete(work.id);
      say(receipt || (applied ? "已应用并完成：结果已写入这个项目。" : "应用请求已提交，等待回执。"), applied ? "ok" : "info");
      render(true);
      await refresh();
      return true;
    } catch (err) {
      state.busy.delete(busyKey);
      render(true);
      if (isStale(err)) return false;
      say("应用没有完成：" + messageOf(err) + "（原文件保留；请重新比较后再试）", "err");
      throw err;
    }
  }

  async function complete(work) {
    const busyKey = "complete:" + work.id;
    if (state.busy.has(busyKey)) return false;
    state.busy.add(busyKey);
    render(true);
    const key = "complete|" + work.id;
    const requestId = requestIdFor(key);
    try {
      const result = await call(RPC.complete, {workId: work.id, requestId: requestId}, mark());
      releaseRequestId(key);
      state.busy.delete(busyKey);
      const receipt = receiptText(result);
      state.receipts.set(work.id, {text: receipt || "已确认完成，这条工作记录关闭。", kind: "ok"});
      say(receipt || "已确认完成。", "ok");
      render(true);
      await refresh();
      return true;
    } catch (err) {
      state.busy.delete(busyKey);
      render(true);
      if (isStale(err)) return false;
      say("确认完成没有成功：" + messageOf(err), "err");
      throw err;
    }
  }

  // ── 挂载与生命周期 ──────────────────────────────────────────────────────
  function mount() {
    const host = el("section", "cw-card");
    host.id = "conversation-work";
    host.setAttribute("aria-label", "当前工作");
    const main = document.getElementById("main");
    const composer = document.getElementById("composer");
    if (main && composer && composer.parentNode === main) main.insertBefore(host, composer);
    else if (main) main.appendChild(host);
    else document.body.appendChild(host);
    state.card = host;
    const actions = document.getElementById("composer-actions");
    if (actions) {
      const start = button("", () => api.start(), "cw-composer-start", "分工执行：自动拆分、分派并汇总交付");
      start.className = 'btn-icon-round btn-send cw-composer-start';
      const svg = document.createElementNS("http://www.w3.org/2000/svg", "svg");
      for (const [key, value] of Object.entries({viewBox: "0 0 24 24", width: "18", height: "18", fill: "none", stroke: "currentColor", "stroke-width": "2", "stroke-linecap": "round", "stroke-linejoin": "round", "aria-hidden": "true", focusable: "false"})) svg.setAttribute(key, value);
      // A task branches into two tasks; use the same outline style as adjacent controls.
      for (const [tag, attrs] of [
        ["rect", {x: 9, y: 3, width: 6, height: 6, rx: 1.5}],
        ["path", {d: "M12 9v3M6 15v-3h12v3"}],
        ["rect", {x: 3, y: 15, width: 6, height: 6, rx: 1.5}],
        ["rect", {x: 15, y: 15, width: 6, height: 6, rx: 1.5}]
      ]) {
        const part = document.createElementNS("http://www.w3.org/2000/svg", tag);
        for (const [key, value] of Object.entries(attrs)) part.setAttribute(key, String(value));
        svg.appendChild(part);
      }
      start.appendChild(svg);
      start.id = "work-start";
      const send = document.getElementById("send");
      if (send && send.parentNode === actions) actions.insertBefore(start, send);
      else actions.appendChild(start);
      state.composerStart = start;
    }
  }

  function init(options) {
    if (!options || typeof options.rpc !== "function") throw new Error("NewbeeConversationWork.init 需要注入 rpc");
    destroy();
    state.host = options;
    state.generation += 1;
    state.sessionId = "";
    state.works = [];
    state.delay = POLL_FAST;
    state.failed = 0;
    mount();
    if (typeof document !== "undefined" && document.addEventListener) {
      state.onVisibility = onVisibility;
      document.addEventListener("visibilitychange", state.onVisibility);
    }
    render(true);
    refresh();
    return api;
  }

  function destroy() {
    if (state.timer) clearTimeout(state.timer);
    state.timer = 0;
    if (state.noticeTimer) clearTimeout(state.noticeTimer);
    state.noticeTimer = 0;
    if (state.onVisibility && typeof document !== "undefined" && document.removeEventListener) {
      document.removeEventListener("visibilitychange", state.onVisibility);
    }
    state.onVisibility = null;
    state.generation += 1;
    state.host = null;
    state.sig = "";
    state.works = [];
    state.sessionId = "";
    state.busy.clear();
    state.confirm.clear();
    state.requestIds.clear();
    if (state.card && state.card.parentNode) state.card.parentNode.removeChild(state.card);
    state.card = null;
    if (state.composerStart && state.composerStart.parentNode) state.composerStart.parentNode.removeChild(state.composerStart);
    state.composerStart = null;
    state.noticeBox = null;
  }

  const api = {
    init: init,
    refresh: refresh,
    submit: submit,
    start: start,
    destroy: destroy,
    // 只读诊断：给集成与定向测试用，不参与渲染。
    peek: function () {
      return {
        sessionId: sessionId(),
        works: state.works.map((work) => ({id: work.id, status: work.status, stage: work.stage})),
        review: Array.from(state.reviewCache.keys())
      };
    }
  };

  if (typeof window !== "undefined") window.NewbeeConversationWork = api;
  if (typeof module !== "undefined" && module.exports) module.exports = api;
})();
