/* newbee WebUI 前端（移植 dsh client/web 会话 shell 语义，无构建依赖原生 JS）。
 * 信道：REST RPC（POST /api/<method>）+ WebSocket 事件下行（/ws?session=）。 */
(() => {
  const ICO_FOLDER = '<svg viewBox="0 0 24 24" width="12" height="12" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" style="vertical-align:-1px"><path d="M3 8V6a2 2 0 0 1 2-2h4l2 2h8a2 2 0 0 1 2 2v2"/><path d="M3 8l2.4 9.1A2 2 0 0 0 7.3 19h12.2a1 1 0 0 0 1-1.3L18 11H5L3 8z"/></svg>';
  const ICO_SIDEBAR_COLLAPSE = '<svg class="ico" viewBox="0 0 24 24" width="15" height="15" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><rect width="18" height="18" x="3" y="3" rx="3"/><path d="M9 3v18"/><path d="m16 15-3-3 3-3"/></svg>';
  const ICO_SIDEBAR_EXPAND = '<svg class="ico" viewBox="0 0 24 24" width="15" height="15" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><rect width="18" height="18" x="3" y="3" rx="3"/><path d="M9 3v18"/><path d="m14 9 3 3-3 3"/></svg>';
  // ── 工具结果解包：剥离 Trust Envelope（<<<data ...>>>），历史回放与实时共用 ──
  function unwrapToolContent(text) {
    if (!text) return "";
    const s = String(text);
    if (s.startsWith("<<<data")) {
      const start = s.indexOf(">\n");
      if (start !== -1) {
        const end = s.lastIndexOf("\n<<<end");
        if (end !== -1 && end > start) {
          return s.slice(start + 2, end).trimStart();
        }
      }
      const lines = s.split("\n");
      if (lines.length >= 3 && lines[0].startsWith("<<<data") && lines[lines.length - 1].startsWith("<<<end")) {
        return lines.slice(1, -1).join("\n").trimStart();
      }
    }
    return s;
  }
  function isToolError(text) {
    return unwrapToolContent(text).trimStart().startsWith("✗");
  }
  // ── Markdown 渲染器（零依赖，覆盖 newbee.Markdown 同语法集，输出安全 HTML）──
  // 语法：ATX 标题、围栏代码块、引用、无序/有序/任务列表、水平线、表格、
  // 行内 **bold** *italic* `code` [text](url) ~~del~~。全部经 escapeHtml 防注入。
  function renderMarkdown(text) {
    const lines = String(text || "").split(/\r?\n/);
    const out = [];
    let i = 0;
    let listStack = null; // {type:'ul'|'ol', html:[]}

    const closeList = () => {
      if (listStack) { out.push(`<${listStack.type}>${listStack.html.join("")}</${listStack.type}>`); listStack = null; }
    };

    while (i < lines.length) {
      const line = lines[i];

      // 围栏代码块
      const fence = line.match(/^\s*(`{3})([^\s`]*)\s*$/);
      if (fence) {
        closeList();
        const lang = fence[2] || "";
        const body = [];
        i++;
        while (i < lines.length && !/^\s*`{3}\s*$/.test(lines[i])) { body.push(lines[i]); i++; }
        i++; // 跳过闭合 ```
        out.push(
          `<pre class="md-code"><div class="md-code-head"><span>${escapeHtml(lang || "code")}</span>` +
          `<button class="md-copy" data-code="${escapeHtml(body.join("\n")).replace(/"/g, "&quot;")}">复制</button></div>` +
          `<code>${escapeHtml(body.join("\n"))}</code></pre>`
        );
        continue;
      }

      // 表格：当前行含 | 且下一行是分隔行
      if (line.includes("|") && i + 1 < lines.length && /^\s*\|?[\s:\-|]+\|?\s*$/.test(lines[i + 1]) && lines[i + 1].includes("-")) {
        closeList();
        const header = splitRow(line);
        i += 2;
        const rows = [];
        while (i < lines.length && lines[i].includes("|") && lines[i].trim() !== "") { rows.push(splitRow(lines[i])); i++; }
        const th = header.map(c => `<th>${inline(c)}</th>`).join("");
        const trs = rows.map(r => `<tr>${r.map(c => `<td>${inline(c)}</td>`).join("")}</tr>`).join("");
        out.push(`<table class="md-table"><thead><tr>${th}</tr></thead><tbody>${trs}</tbody></table>`);
        continue;
      }

      // 标题
      const h = line.match(/^(\#{1,6})\s+(.*)$/);
      if (h) { closeList(); const lv = h[1].length; out.push(`<h${lv} class="md-h">${inline(h[2])}</h${lv}>`); i++; continue; }

      // 水平线
      if (/^\s*-{3,}\s*$/.test(line)) { closeList(); out.push('<hr class="md-hr" />'); i++; continue; }

      // 引用
      const q = line.match(/^>\s?(.*)$/);
      if (q) { closeList(); out.push(`<blockquote class="md-quote">${inline(q[1])}</blockquote>`); i++; continue; }

      // 任务列表
      const task = line.match(/^(\s*)[-*+]\s+\[([ xX])\]\s+(.*)$/);
      if (task) {
        if (!listStack || listStack.type !== "ul") { closeList(); listStack = { type: "ul", html: [] }; }
        const checked = task[2].toLowerCase() === "x" ? "checked" : "";
        listStack.html.push(`<li class="md-task"><input type="checkbox" disabled ${checked} /> ${inline(task[3])}</li>`);
        i++; continue;
      }

      // 无序列表
      const ul = line.match(/^\s*[-*+]\s+(.*)$/);
      if (ul) {
        // 空列表项（如 "- " 或 "* "）不产出 <li></li>——避免 done 摘要出现孤立空 bullet
        if (ul[1].trim() === "") { i++; continue; }
        if (!listStack || listStack.type !== "ul") { closeList(); listStack = { type: "ul", html: [] }; }
        listStack.html.push(`<li>${inline(ul[1])}</li>`);
        i++; continue;
      }

      // 有序列表
      const ol = line.match(/^\s*(\d+)[.)]\s+(.*)$/);
      if (ol) {
        if (!listStack || listStack.type !== "ol") { closeList(); listStack = { type: "ol", html: [] }; }
        listStack.html.push(`<li>${inline(ol[2])}</li>`);
        i++; continue;
      }

      // 空行
      if (line.trim() === "") { closeList(); i++; continue; }

      // 普通段落
      closeList();
      out.push(`<p class="md-p">${inline(line)}</p>`);
      i++;
    }
    closeList();
    return out.join("\n");
  }

  function splitRow(line) {
    return line.replace(/^\s*\|/, "").replace(/\|\s*$/, "").split("|").map(c => c.trim());
  }

  // 行内渲染：**bold** *italic* `code` [text](url) ~~del~~，先转义再标记
  function inline(text) {
    let t = escapeHtml(text);
    t = t.replace(/`([^`\n]+)`/g, '<code class="md-inline">$1</code>');
    t = t.replace(/\*\*([^*]+)\*\*/g, "<strong>$1</strong>");
    t = t.replace(/\*([^*\s][^*]*)\*/g, "<em>$1</em>");
    t = t.replace(/~~([^~\n]+)~~/g, "<del>$1</del>");
    // 图片：![alt](url) —— 渲染为可点击放大的缩略图
    t = t.replace(/!\[([^\]\n]*)\]\(([^)\n]*)\)/g, '<img class="md-img" src="$2" alt="$1" loading="lazy" />');
    t = t.replace(/\[([^\]\n]*)\]\(([^)\n]*)\)/g, '<a class="md-link" href="$2" target="_blank" rel="noopener">$1</a>');
    // 文件路径可点击（lib/xxx.ex 等）
    t = t.replace(/\b((?:lib|test|config|docs|priv|bench)\/[\w\/.\-]+\.(?:ex|exs|js|css|html|md|json|toml|yml|yaml))\b/g, '<span class="file-ref" data-path="$1" title="点击查看 diff">$1</span>');
    return t;
  }

  const elixirKeywords = new Set([
    "after", "and", "case", "catch", "cond", "def", "defdelegate", "defexception",
    "defguard", "defguardp", "defimpl", "defmacro", "defmacrop", "defmodule", "defp",
    "defprotocol", "defstruct", "do", "else", "end", "fn", "for", "if", "import",
    "in", "not", "or", "quote", "raise", "receive", "require", "rescue", "super",
    "throw", "try", "unless", "unquote", "use", "when", "with"
  ]);
  const elixirLiterals = new Set(["false", "nil", "true"]);
  const elixirDefinitionKeywords = new Set([
    "def", "defdelegate", "defguard", "defguardp", "defmacro", "defmacrop", "defmodule",
    "defp", "defprotocol"
  ]);

  // 小型 Elixir 词法高亮器。逐 token 转义，避免工具代码被当作 HTML 执行。
  function highlightElixir(code) {
    let rest = String(code || "");
    let html = "";
    let previousWord = "";
    const token = (cls, value) => {
      html += cls ? `<span class="ex-${cls}">${escapeHtml(value)}</span>` : escapeHtml(value);
      rest = rest.slice(value.length);
    };

    while (rest) {
      let match;
      if ((match = rest.match(/^\s+/))) { token("", match[0]); continue; }
      if ((match = rest.match(/^#[^\n]*/))) { token("comment", match[0]); previousWord = ""; continue; }
      if ((match = rest.match(/^(?:"""[\s\S]*?(?:"""|$)|'''[\s\S]*?(?:'''|$))/))) {
        token("string", match[0]); previousWord = ""; continue;
      }
      if ((match = rest.match(/^~[A-Za-z](?:\/(?:\\.|[^\/\\])*\/|\|(?:\\.|[^|\\])*\||"(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*')[A-Za-z]*/))) {
        token("sigil", match[0]); previousWord = ""; continue;
      }
      if ((match = rest.match(/^(?:"(?:\\[\s\S]|[^"\\])*"|'(?:\\[\s\S]|[^'\\])*')/))) {
        token("string", match[0]); previousWord = ""; continue;
      }
      if ((match = rest.match(/^:(?:"(?:\\.|[^"\\])*"|[A-Za-z_][\w@!?]*)/))) {
        token("atom", match[0]); previousWord = ""; continue;
      }
      if ((match = rest.match(/^@[A-Za-z_][\w!?]*/))) { token("attribute", match[0]); previousWord = ""; continue; }
      if ((match = rest.match(/^(?:0[xob][0-9A-Fa-f_]+|\d[\d_]*(?:\.\d[\d_]*)?(?:e[+-]?\d+)?)/i))) {
        token("number", match[0]); previousWord = ""; continue;
      }
      if ((match = rest.match(/^[A-Za-z_][\w!?]*(?:\.[A-Za-z_][\w!?]*)*/))) {
        const word = match[0];
        let cls = "";
        if (elixirKeywords.has(word)) cls = "keyword";
        else if (elixirLiterals.has(word)) cls = "literal";
        else if (/^[A-Z]/.test(word) || word.includes(".")) cls = "module";
        else if (elixirDefinitionKeywords.has(previousWord) || /^\s*\(/.test(rest.slice(word.length))) cls = "function";
        token(cls, word);
        previousWord = word;
        continue;
      }
      if ((match = rest.match(/^(?:===|!==|==|!=|<=|>=|->|<-|=>|\|>|<>|\+\+|--|&&|\|\||\\\\|[+\-*\/=<>|&!^~:.%])/))) {
        token("operator", match[0]); previousWord = ""; continue;
      }
      token("", rest[0]);
      previousWord = "";
    }
    return html;
  }

// highlight.js 薄封装：未加载或语言未知时回退纯转义
  function highlightSource(code, language) {
    if (window.hljs) {
      const alias = HIGHLIGHT_ALIASES[language] || language;
      if (window.hljs.getLanguage(alias)) {
        try {
          return window.hljs.highlight(code, {language: alias, ignoreIllegals: true}).value;
        } catch (e) {}
      }
    }
    return escapeHtml(code);
  }

  const HIGHLIGHT_ALIASES = {
    elixir: "elixir", javascript: "javascript", typescript: "typescript",
    jsx: "javascript", tsx: "typescript", json: "json", css: "css", html: "xml",
    yaml: "yaml", toml: "ini", shell: "bash", python: "python",
    rust: "rust", go: "go", markdown: "markdown"
  };


  const $ = (id) => document.getElementById(id);
const transcript = $("transcript");
const flow = $("flow");
  const input = $("input");
  // ── 主题（黑/白切换，持久 localStorage，默认跟随系统）──
  function applyTheme(t, persist) {
    document.documentElement.setAttribute("data-theme", t);
    const btn = $("theme-toggle");
    if (btn) { btn.innerHTML = t === "light" ? "<svg class=\"ico\" viewBox=\"0 0 24 24\" width=\"15\" height=\"15\" fill=\"none\" stroke=\"currentColor\" stroke-width=\"2\" stroke-linecap=\"round\" stroke-linejoin=\"round\"><path d=\"M21 12.8A9 9 0 1 1 11.2 3 7 7 0 0 0 21 12.8z\"/></svg>" : "<svg class=\"ico\" viewBox=\"0 0 24 24\" width=\"15\" height=\"15\" fill=\"none\" stroke=\"currentColor\" stroke-width=\"2\" stroke-linecap=\"round\" stroke-linejoin=\"round\"><circle cx=\"12\" cy=\"12\" r=\"4\"/><path d=\"M12 2v2m0 16v2M4.9 4.9l1.4 1.4m11.4 11.4l1.4 1.4M2 12h2m16 0h2M4.9 19.1l1.4-1.4M17.7 6.3l1.4-1.4\"/></svg>"; btn.title = t === "light" ? "切换到暗色" : "切换到亮色"; }
    if (persist) localStorage.setItem("newbee.theme", t);
  }
  function initTheme() {
    const saved = localStorage.getItem("newbee.theme");
    const sys = window.matchMedia && window.matchMedia("(prefers-color-scheme: light)").matches ? "light" : "dark";
    applyTheme(saved || sys, false);
  }

  const state = {
    sid: localStorage.getItem("newbee.sid") || null,
    token: localStorage.getItem("newbee.token") || null,
    ws: null,
    busy: false,
    creatingSession: false,
    hasPrompted: false,
    titleDirty: false,
    currentAssistant: null,
    currentReasoning: null,
    currentTool: null,
    timing: { llmMs: 0, toolMs: 0, llmStart: null, toolStart: null,
              ftSum: 0, ftCount: 0, ftRecorded: false, outTok: 0 },
    attachments: [],
    uploading: 0,
    stickBottom: true,
    turnUsage: null,
    turnUsageDetails: [],
    _pendingUsage: null,
    lastLLMUsage: null,
    lastUsageSeq: 0,
    lastAttachedSeq: 0,
    groups: [],
    activeGroupId: null,
    activeGroup: null,
    groupMessages: [],
    groupActivity: [],
    groupTasks: [],
    taskReviews: {},
    taskFilter: "all",
    activityExpanded: false,
    collabUnread: {},
    collabSeen: loadCollabSeen(),
    fileAttribution: {},
    groupBySession: {},
    selectedSessions: new Set(),
    queue: [],
    queueSeq: 0,
    queueCurrent: null,
  };

  // ── 会话统计持久化（按 sessionId 存 localStorage，刷新/重连后保留）──
  const statsKey = (sid) => "newbee.stats." + sid;
  function saveTiming() {
    if (!state.sid) return;
    try { localStorage.setItem(statsKey(state.sid), JSON.stringify(state.timing)); } catch (e) {}
  }
  function resetTimingToZero() {
    // 新会话/同 sid 清空后统计归零，并同步清掉持久化档（防旧值经刷新/切会话复活）
    state.timing = { llmMs: 0, toolMs: 0, llmStart: null, toolStart: null,
                     ftSum: 0, ftCount: 0, ftRecorded: false, outTok: 0 };
    if (state.sid) {
      try { localStorage.removeItem(statsKey(state.sid)); } catch (e) {}
    }
  }
  function loadTiming(sid) {
    try {
      const raw = localStorage.getItem(statsKey(sid));
      if (!raw) return;
      const saved = JSON.parse(raw);
      if (saved && typeof saved === "object") {
        state.timing = { llmMs: 0, toolMs: 0, llmStart: null, toolStart: null,
                         ftSum: 0, ftCount: 0, ftRecorded: false, outTok: 0, ...saved };
        // 活动计时器跨刷新无意义，置空（旧档无需再兜底缓存字段）
        state.timing.llmStart = null; state.timing.toolStart = null;
      }
    } catch (e) {}
  }
  function clearTiming(sid) { try { localStorage.removeItem(statsKey(sid)); } catch (e) {} }

  // ── RPC ──
  let rpcSeq = 0;
  async function rpc(method, payload) {
    const rpcId = `web-${Date.now()}-${rpcSeq++}`;
    const headers = { "content-type": "application/json" };
    if (state.token) headers["authorization"] = "Bearer " + state.token;
    const res = await fetch(`/api/${method}`, {
      method: "POST",
      headers,
      body: JSON.stringify({ rpcId, method, payload }),
    });
    if (res.status === 401) {
      // 未登录/会话过期：清 token，弹登录遮罩，后续由登录流程接管
      setToken(null);
      showLogin();
      throw new Error("未登录或会话已过期");
    }
    const text = await res.text();
    if (!text) throw new Error(`服务返回空响应 (HTTP ${res.status})`);
    let body;
    try {
      body = JSON.parse(text);
    } catch (e) {
      throw new Error(`服务返回非 JSON (HTTP ${res.status}): ${text.slice(0, 120)}`);
    }
    if (body.result && "ok" in body.result) return body.result.ok;
    const err = body.result && body.result.error;
    throw new Error(err ? err.message : `rpc ${method} failed (HTTP ${res.status})`);
  }

  function genSessionId() {
    const d = new Date();
    const p2 = (n) => String(n).padStart(2, "0");
    const ts = `${d.getFullYear()}${p2(d.getMonth() + 1)}${p2(d.getDate())}-${p2(d.getHours())}${p2(d.getMinutes())}${p2(d.getSeconds())}`;
    const rand = Math.floor(Math.random() * 0xffff).toString(16).padStart(4, "0");
    return `${ts}-${rand}`;
  }

  // ── WebSocket ──
  // 防重复连接：同一时间只保留一条活跃连接。重连定时器可取消，
  // 且 onclose 只在“这条 ws 仍是当前连接”时才排重连——避免 resume()
  // 主动 close 旧连接后，旧 onclose 又排一个 connect() 造成多连接并存、
  // 同一事件被多条连接各推一份而在前端重复渲染。
  let reconnectTimer = 0;
  let lastUserPrompt = ""; // 错误重试用
  function connect() {
    if (!state.sid) return;
    if (reconnectTimer) { clearTimeout(reconnectTimer); reconnectTimer = 0; }
    if (state.ws) {
      // 让旧连接的 onclose 失效，避免它再排重连
      state.ws.onclose = null;
      try { state.ws.close(); } catch (e) {}
      state.ws = null;
    }
    const proto = location.protocol === "https:" ? "wss" : "ws";
    const boundSid = state.sid;          // 本连接绑定的会话（闭包固定，防切换后旧帧串入）
    let wsUrl = `${proto}://${location.host}/ws?session=${encodeURIComponent(state.sid)}`;
    if (state.token) wsUrl += `&token=${encodeURIComponent(state.token)}`;
    const ws = new WebSocket(wsUrl);
    state.ws = ws;
    ws.onmessage = (e) => {
      if (ws !== state.ws) return; // 过期连接的事件直接丢
      const frame = JSON.parse(e.data);
      if (frame.type === "event") {
        // 多会话并存：只渲染当前会话的事件；frame.sessionId 由后端 socket 下行携带
        if (frame.sessionId && frame.sessionId !== state.sid) return;
        if (boundSid !== state.sid) return; // 连接建立后用户已切到别的会话
        onEvent(frame.kind, frame.payload || {});
      }
      else if (frame.type === "system") pushEvoEvent(frame.topic, frame.payload);
      else if (frame.type === "group_event") onGroupEvent(frame);
    };
    ws.onopen = () => {
      if (reconnectTimer) { clearTimeout(reconnectTimer); reconnectTimer = 0; }
      line("notice", "✓ 已连接");
    };
    ws.onclose = () => {
      if (ws !== state.ws) return; // 过期连接不重连
      if (state.ws === ws) state.ws = null;
      line("notice", "⚠ 连接断开，正在重连…");
      reconnectTimer = setTimeout(connect, 1500);
    };
  }

  // 耗时统计（对齐 TUI）：LLM 段 / 工具段 / 首 token / 速率
  // 口径：tok/s = 会话累计输出 token ÷ 累计 LLM 段耗时（含排队与 prefill 的首 token
  // 等待，不含工具段）——是"会话平均吞吐"而非当前回复的瞬时生成速度；长回复流式
  // 途中分子只按已完成的请求累加，显示值会阶段性偏低，属预期口径而非 bug。
  function trackTiming(kind, p) {
    const t = state.timing, now = Date.now();
    switch (kind) {
      case "text":
      case "reasoning":
        if (t.llmStart === null) t.llmStart = now;
        // 首 token：从请求发起（发送方/上一工具段置位）到首个流式 delta
        if (t.llmStart !== null && !t.ftRecorded) { t.ftSum += now - t.llmStart; t.ftCount++; t.ftRecorded = true; }
        break;
      case "tool_start":
        if (t.llmStart !== null) { t.llmMs += now - t.llmStart; t.llmStart = null; }
        t.toolStart = now; t.ftRecorded = false;
        break;
      case "tool_result":
      case "tool_error":
        if (t.toolStart !== null) { t.toolMs += now - t.toolStart; t.toolStart = null; }
        t.llmStart = now;
        break;
      case "usage":
        const u = p.usage || {};
        t.outTok += u.completion_tokens || 0;
        break;
      case "turn_end":
      case "done": case "ask": case "error": case "interrupted":
        if (t.llmStart !== null) { t.llmMs += now - t.llmStart; t.llmStart = null; }
        if (t.toolStart !== null) { t.toolMs += now - t.toolStart; t.toolStart = null; }
        break;
    }
    saveTiming();
  }
  function fmtDur(ms) {
    const s = ms / 1000;
    if (ms < 1000) return Math.max(1, Math.round(ms)) + "ms";
    if (s < 10) return s.toFixed(2) + "s";
    if (s < 60) return (Math.round(s * 10) / 10) + "s";
    const w = Math.round(s);
    return Math.floor(w / 60) + "m" + (w % 60) + "s";
  }

  // 服务端时间带 offset；显示转换到手机/浏览器本地时区。
  function setBubbleTime(d, value) {
    const parsed = value ? new Date(value) : new Date();
    const date = Number.isNaN(parsed.getTime()) ? new Date() : parsed;
    d.dataset.createdAt = value || d.dataset.createdAt || date.toISOString();
    let time = d.querySelector(".msg-time");
    if (!time) {
      time = document.createElement("time");
      time.className = "msg-time";
      d.appendChild(time);
    }
    time.textContent = date.toLocaleString(undefined, { year: "numeric", month: "2-digit", day: "2-digit", hour: "2-digit", minute: "2-digit", timeZoneName: "short" });
    time.dateTime = date.toISOString();
    time.title = date.toISOString();
    return d;
  }

  // ── 事件 → 渲染 ──
  function onEvent(kind, p) {
    state.eventCreatedAt = p && p.created_at;
    trackTiming(kind, p);
    switch (kind) {
      case "text": appendStream(p.delta, p.created_at); break;
      case "reasoning": appendReasoning(p.delta, p.created_at); break;
      case "tool_start": toolStart(p); break;
      case "tool_result": toolResult(p.text, !isToolError(p.text), p.duration_ms); break;
      case "tool_error": toolResult(p.text, false); break;
      case "done": {
        finishTurn();
        const doneCard = line("done", p.summary, true, p.created_at);
        // done 总结卡补挂本轮用量（与刷新回放视图一致），避免底部空白
        try {
          if (doneCard && doneCard.dataset.hasUsage !== "1") {
            const u = state.turnUsage && state.turnUsage.count > 0
              ? { prompt_tokens: state.turnUsage.prompt, completion_tokens: state.turnUsage.completion, cache_read_tokens: state.turnUsage.hasUnknown ? null : state.turnUsage.cached, model: state.turnUsage.model }
              : state.lastLLMUsage;
            if (u) attachUsageToBubble(doneCard, u);
          }
        } catch (e) {}
        // 下一步工作建议：done 携带 next_steps 时就地渲染可选卡片（单选/多选/按钮）
        try {
          const ns = p.next_steps || (p.question || p.options ? p : null);
          if (ns && (ns.question || (ns.options && ns.options.length))) {
            renderAskCard(ns.question || "下一步做什么？", ns.options || [], ns.kind || "single", p.created_at);
          }
        } catch (e) {}
        break;
      }

      case "ask": finishTurn(); renderAskCard(p.question, p.options || [], p.kind || "text", p.created_at); break;
      case "text_end": finishTurn(); break;
      case "error": {
        finishTurn();
        const m = String(p.message || "");
        // 模型配置类错误：给出可操作提示（点模型选择器 / 改 model.json）
        if (/ModelError|not supported|not-a-model|未配置|无效|api.?key|401/i.test(m)) {
          line("error", m + "\n→ 修复方式: 右上角模型选择器换一个模型，或修改 ~/.newbee/model.json 后重试");
        } else {
          line("error", m);
        }
        break;
      }
      case "interrupted": finishTurn(); line("notice", "已中断"); break;
      case "session_cleared": {
        finishTurn();
        try { localStorage.removeItem("newbee.draft." + state.sid); } catch (e) {}
        resetStreamState();
        flow.innerHTML = "";
        renderWelcome();
        state.hasPrompted = false;
        state.titleDirty = false;
        hidePermission();
        clearAttachments();
        setBusy(false);
        state.queue = [];
        state.queueCurrent = null;
        renderQueue();
        resetTimingToZero();
        if (p.text) line("notice", p.text);
        break;
      }
      case "session_renewed": {
        finishTurn();
        const newSid = p.sessionId;
        // 后端新实现同 sid 清空：直接清面板；旧实现子 sid：resume 到新 transcript
        if (newSid && newSid === state.sid && !state.creatingSession) {
          try { localStorage.removeItem("newbee.draft." + state.sid); } catch (e) {}
          resetStreamState();
          flow.innerHTML = "";
          renderWelcome();
          state.hasPrompted = false;
          state.titleDirty = false;
          hidePermission();
          clearAttachments();
          setBusy(false);
          resetTimingToZero();
          line("notice", p.text || "已开启新会话");
        } else if (newSid && newSid !== state.sid && !state.creatingSession) {
          try { localStorage.removeItem("newbee.draft." + state.sid); } catch (e) {}
          (async () => {
            try {
              await resume(newSid);
              line("notice", "已开启新会话");
            } catch (e) {
              line("error", "切换新会话失败: " + e.message);
            }
          })();
        }
        break;
      }
      case "permission_ask": showPermission(p.preview); break;
      case "usage": setUsage(p.usage); handleBubbleUsage(p.usage); break;
      case "compacted": line("notice", `历史已压缩 ${p.count} 条`); break;
      case "model_switched": $("model-label").textContent = p.model; break;
      case "workspace_changed":
        state.cwd = p.cwd || state.cwd;
        updateCwdLabel(state.cwd);
        loadSessions();
        line("notice", `当前会话工作目录已切换为 ${state.cwd}`);
        break;
      // 上下文窗口覆盖热更新（当前会话模型匹配时服务端推送）：顶栏用量标签立即反映新值
      case "context_window_changed": refreshStats(); break;
      case "goal_start": line("notice", `目标开始: ${p.text}`); break;
      case "goal_done": line("notice", `目标达成: ${p.summary || ""}`); break;
      case "goal_cancelled": line("notice", `目标取消 (${p.reason || ""})`); break;
      case "rule_hit":
        (p.hits || []).forEach(h => line("notice", `⚑ 沉睡规则命中 [${h.id}] ${h.injection}`));
        break;
      case "prompt_injection": promptInjection(p); break;
case "advisor_note": line("notice", `◉ advisor: ${p.text}`); break;
case "queued": line("notice", `已排队（第 ${p.queued || 1} 位），当前任务完成后自动执行`); break;
case "collab_task_queued": line("notice", `协作任务已排队（${p.queued || 1} 位）`); break;
case "collab_result_queued": line("notice", `协作结果已排队（${p.queued || 1} 位）`); break;
case "collab_message_queued": line("notice", `协作消息已排队（${p.queued || 1} 位）`); break;
case "queue_updated": {
  state.queue = Array.isArray(p.queue) ? p.queue : [];
  if (typeof p.seq === "number") state.queueSeq = p.seq;
  state.queueCurrent = p.current || null;
  renderQueue();
  const ev = p.event || {};
  if (ev.type === "cancelled") line("notice", `已取消排队：${ev.preview || ev.id || ""}`);
  else if (ev.type === "cleared" && (ev.count || 0) > 0) line("notice", `已清空 ${ev.count} 条排队`);
  else if (ev.type === "discarded" && (ev.count || 0) > 0) line("notice", `排队已丢弃 ${ev.count} 条（内核启动失败）`);
  break;
}
case "queue_cancelled": {
  const id = p.id;
  if (id) state.queue = (state.queue || []).filter((it) => it && it.id !== id);
  renderQueue();
  line("notice", `已取消排队：${p.preview || id || ""}`);
  break;
}
case "notice": line("notice", p.text); break;
case "shell_result": shellResult(p); break;
case "file_diff": fileDiff(p); break;
case "media_show": renderMediaShow(p); break;

case "turn_long": line("notice", `本轮较长：${p.step || ""} 步`); break;
case "tool_warnings": line("notice", `工具警告: ${(p.warnings || []).join("; ")}`); break;
case "final_check": line("notice", `最终检查: ${p.score ?? ""}`); break;
case "final_check_low": line("notice", `质量分偏低: ${p.score ?? ""}`); break;
case "progress": break;
case "progress_stall": line("notice", "进度停滞，模型在重试"); break;
case "goal_retry": line("notice", `目标重试 (${p.retries || 0})`); break;
case "goal_limit": line("notice", `目标达轮数上限 (${p.max || ""})`); break;
case "goal_round": break;
      case "turn_end": finishTurn(); break;
      default: break;
    }
    scrollBottom();
  }

  function finishTurn() {
    state.busy = false;
    if (state.currentAssistant) {
      const _savedBar = state.currentAssistant.querySelector(":scope > .msg-usage");
      state.currentAssistant.innerHTML = renderMarkdown(streamAcc);
      addAssistantChrome(state.currentAssistant);
      bindCopyButtons(state.currentAssistant);
      if (_savedBar && !_savedBar.dataset.reattached) { state.currentAssistant.appendChild(_savedBar); }
      if (state._pendingUsage) { attachUsageToBubble(state.currentAssistant, state._pendingUsage); state._pendingUsage = null; }
      if (state.currentAssistant.dataset.hasUsage !== "1" && state.turnUsage && state.turnUsage.count > 0) {
        attachUsageToBubble(state.currentAssistant, { prompt_tokens: state.turnUsage.prompt, completion_tokens: state.turnUsage.completion, cache_read_tokens: state.turnUsage.hasUnknown ? null : state.turnUsage.cached, model: state.turnUsage.model });
      }
    }
    if (state.currentAssistant && state.turnUsage && state.turnUsage.count > 1) {
      const bar = state.currentAssistant.querySelector(":scope > .msg-usage");
        const cacheSum = state.turnUsage.hasUnknown ? fmtTokShort(state.turnUsage.cached) + "+?" : fmtTokShort(state.turnUsage.cached);
        if (bar) bar.title = `本轮累计 ${state.turnUsage.count} 次请求 · 输入 ${fmtTokShort(state.turnUsage.prompt)} · 输出 ${fmtTokShort(state.turnUsage.completion)} · 缓存 ${cacheSum}`;
    }
    // 兜底：纯工具 turn 的 usage 悬空时挂到最后一个无用量气泡，避免丢弃/串轮
    if (state._pendingUsage && !state.currentAssistant) {
      const boxed = flow.querySelectorAll(".msg-assistant.msg-boxed");
      let target = null;
      for (let i = boxed.length - 1; i >= 0; i--) { if (boxed[i].dataset.hasUsage !== "1") { target = boxed[i]; break; } }
      if (target) { attachUsageToBubble(target, state._pendingUsage); }
      state._pendingUsage = null;
    }
    archiveReasoning();
    state.currentAssistant = null;
    state.currentTool = null;
    setBusy(false);
    hidePermission();
    clearTurnStatus();
    streamAcc = "";
    if (state.titleDirty) {
      state.titleDirty = false;
      loadSessions().catch(() => {});
    }
  }
  function resetTurnUsage() {
    state.turnUsage = null;
    state.turnUsageDetails = [];
    state._pendingUsage = null;
    state.lastLLMUsage = null;
    // 保留序号用于“同上次请求”判断，跨轮清附着标记
    state.lastAttachedSeq = 0;
  }

  function el(cls, text, md, createdAt) {
    const d = document.createElement("div");
    d.className = `msg ${cls}`;
    if (text) { if (md) d.innerHTML = renderMarkdown(text); else d.textContent = text; }
    flow.appendChild(d);
    setBubbleTime(d, createdAt || state.eventCreatedAt);
    return d;
  }

  // ── assistant 输出框：包边框 + 右上角"复制"按钮 ──
  // 复制内容优先原始 markdown（dataset.raw），否则取 innerText。
  function addAssistantChrome(d) {
    d.classList.add("msg-boxed");
    if (d.querySelector(".msg-copy")) return d;
    const btn = document.createElement("button");
    btn.type = "button";
    btn.className = "msg-copy";
    btn.title = "复制整条回复";
    btn.textContent = "⧉";
    btn.onclick = () => {
      const raw = d.dataset.raw || d.innerText || "";
      navigator.clipboard.writeText(raw).then(() => {
        btn.textContent = "已复制";
        setTimeout(() => (btn.textContent = "⧉"), 1500);
      });
    };
    d.appendChild(btn);
    return d;
  }

  function line(kind, text, md) {
    const d = el(`msg-${kind}`, text || "", md);
    scrollBottom();
    return d;
  }

  function promptInjection(p) {
    const d = document.createElement("details");
    d.className = "msg msg-prompt-injection";

    const summary = document.createElement("summary");
    const source = p.source || "unknown";
    const role = p.role || "system";
    const timing = p.timing || "next_request";
    summary.textContent = `Prompt 注入 · ${source} · ${role} · ${timing}`;
    d.appendChild(summary);

    const meta = document.createElement("div");
    meta.className = "prompt-injection-meta";
    meta.textContent = `原因: ${p.reason || "未说明"}`;
    d.appendChild(meta);

    if (p.trigger) {
      const trigger = document.createElement("pre");
      trigger.className = "prompt-injection-trigger";
      trigger.textContent = `触发内容:\n${p.trigger}`;
      d.appendChild(trigger);
    }

    if (Array.isArray(p.rules) && p.rules.length) {
      const rules = document.createElement("pre");
      rules.className = "prompt-injection-rules";
      rules.textContent = "规则:\n" + p.rules.map(r =>
        `[${r.id}] scope=${r.scope || "all"} source=${r.source || "unknown"}\n/${r.pattern || ""}/`
      ).join("\n");
      d.appendChild(rules);
    }

    const content = document.createElement("pre");
    content.className = "prompt-injection-content";
    content.textContent = `实际注入 (${role}):\n${p.content || ""}`;
    d.appendChild(content);
    flow.appendChild(d);
  }


    // 文本块边界定稿：reasoning/tool/shell/diff 等非 text 事件到来时，
    // 把当前流式文本块渲染定稿并清空 residue，避免下一段 text 到来时
    // 把上一段残留的 streamAcc 连同新 delta 一起渲染（旧文本重复出现）。
    function flushTextBlock() {
      if (!state.currentAssistant) { streamAcc = ""; return; }
      const _savedBar = state.currentAssistant.querySelector(":scope > .msg-usage");
      state.currentAssistant.innerHTML = renderMarkdown(streamAcc);
      addAssistantChrome(state.currentAssistant);
      bindCopyButtons(state.currentAssistant);
      if (_savedBar) state.currentAssistant.appendChild(_savedBar);
      state.currentAssistant = null;
      streamAcc = "";
    }
  let replayToolCards = {}; // 回放：tool_call_id → 工具卡，tool 结果按 id 回填（对齐实时流视觉）
  let replayPendingUsage = null; // 回放时 usage 行先于 assistant 行到达，暂存等下个气泡
  let streamAcc = "";
  let streamRaf = 0;
  function appendStream(delta, createdAt) {
    archiveReasoning();
    const d = typeof delta === "string" ? delta : "";
    // Some OpenAI-compatible providers emit empty text events between tool calls.
    // Keep leading whitespace, but do not create an assistant bubble until the
    // accumulated block contains visible text.
    if (d === "") return;
    if (d.length >= 5 && streamAcc.endsWith(d)) return;
    streamAcc += d;
    if (!state.currentAssistant && streamAcc.trim() === "") return;
    if (!state.currentAssistant) {
      state.busy = true; setBusy(true);
      clearTurnStatus();
      state.currentAssistant = addAssistantChrome(el("msg-assistant", "", false, createdAt));
      if (state._pendingUsage) { attachUsageToBubble(state.currentAssistant, state._pendingUsage); state._pendingUsage = null; }
    }
    state.currentAssistant.dataset.raw = streamAcc;
    if (!streamRaf) {
      streamRaf = requestAnimationFrame(() => {
        streamRaf = 0;
        if (state.currentAssistant) {
          const _savedBar = state.currentAssistant.querySelector(":scope > .msg-usage");
          state.currentAssistant.innerHTML = renderMarkdown(streamAcc);
          addAssistantChrome(state.currentAssistant);
          bindCopyButtons(state.currentAssistant);
          if (_savedBar) state.currentAssistant.appendChild(_savedBar);
          scrollBottom();
        }
      });
    }
  }

  // reasoning 渲染对齐 dsh ReasoningRow：默认折叠的 disclosure。
  // 标题行 ▸/▾ Think + 摘要；流式时摘要跟随最新一行，完成后收敛到首行；点击展开全文。
  function firstLine(t) { const i = t.indexOf("\n"); return i === -1 ? t : t.slice(0, i); }
  function latestLine(t) { const v = t.replace(/\s+$/, ""); const i = v.lastIndexOf("\n"); return i === -1 ? v : v.slice(i + 1); }
  // Think 块：自包含 disclosure。数据存在元素 dataset 上（thinkText 全文、open 0/1），
  // 每个块独立展开/收缩，互不影响；归档后留在页面原位。
  function renderReasoningBody(el) {
    const text = el.dataset.thinkText || "";
    const open = el.dataset.open === "1";
    const running = el.classList.contains("running");
    const previousBody = el.querySelector(".think-body");
    const previousScrollTop = previousBody ? previousBody.scrollTop : 0;
    el.innerHTML = "";
    const head = document.createElement("div");
    head.className = "think-head";
    head.title = open ? "收起 Think" : "展开 Think";
    const trimmed = text.replace(/\s+$/, "");
    const summary = trimmed === "" ? "…" : (running ? latestLine(trimmed) : firstLine(trimmed));
    head.innerHTML = `<span class="think-chev">${open ? "▾" : "▸"}</span><span class="think-title">Think</span><span class="think-sep"></span><span class="think-summary">${escapeHtml(summary)}</span>`;
    head.addEventListener("click", () => {
      el.dataset.open = open ? "0" : "1";
      renderReasoningBody(el);
      if (!open) scrollBottom();
    });
    el.appendChild(head);
    if (open && trimmed !== "") {
      const body = document.createElement("div");
      body.className = "think-body";
      body.innerHTML = renderMarkdown(text);
      el.appendChild(body);
      bindCopyButtons(body);
      if (previousScrollTop > 0) body.scrollTop = previousScrollTop;
    }
  }
  let reasoningRaf = 0;
  function appendReasoning(delta) {
    if (!state.currentReasoning) {
      state.currentReasoning = el("msg-reasoning running", "");
      state.currentReasoning.dataset.thinkText = "";
      state.currentReasoning.dataset.open = "0";
    flushTextBlock();
    }
    state.currentReasoning.dataset.thinkText += delta || "";
    if (!reasoningRaf) {
      reasoningRaf = requestAnimationFrame(() => {
        reasoningRaf = 0;
        if (state.currentReasoning) {
          renderReasoningBody(state.currentReasoning);
          scrollBottom();
        }
      });
    }
  }
  function archiveReasoning() {
    const r = state.currentReasoning;
    if (!r) return;
    r.classList.remove("running");
    r.dataset.open = "0";
    renderReasoningBody(r);
    state.currentReasoning = null;
  }

  function toolStart(p) {
    archiveReasoning();
    mcToolStart(p);
    // 回放历史：usage 行先到，暂存值在此贴到本次工具卡（若有）
    if (replayPendingUsage) { p._replayUsage = replayPendingUsage; }
    const card = document.createElement("div");
    card.className = "msg msg-tool";
    const head = document.createElement("div");
    head.className = "tool-head";
    head.innerHTML = `<b>${escapeHtml(p.name || "tool")}</b> <span class="diffstat">${escapeHtml(p.title || "")}</span><span class="tool-dur"></span>`;
    const code = document.createElement("pre");
    const source = (p.code || "").split("\n").slice(0, 12).join("\n");
    const isElixir = p.name === "run_elixir";
    code.className = `tool-code${isElixir ? " tool-code-elixir" : ""} hidden`;
    if (isElixir) {
      code.dataset.language = "elixir";
      code.innerHTML = highlightElixir(source);
    } else {
      code.textContent = source;
    }
    const result = document.createElement("div");
    result.className = "tool-result hidden";
    card.append(head, code, result);
    setBubbleTime(card, p.created_at || state.eventCreatedAt);
    // 默认折叠，点 head 展开 code + result
    head.style.cursor = "pointer";
    head.addEventListener("click", () => {
      const open = code.classList.contains("hidden");
      code.classList.toggle("hidden", !open);
      result.classList.toggle("hidden", !open);
      head.querySelector(".tool-chev")?.remove();
      if (!open) return;
      const chev = document.createElement("span");
      chev.className = "tool-chev";
      chev.textContent = " ▾";
      chev.style.color = "var(--nb-label-caption)";
      head.appendChild(chev);
    });
    flow.appendChild(card);
    card.dataset.startedAt = Date.now();
    state.currentTool = result;
    state.currentToolCard = card;
    try {
      if (p._replayUsage) { attachToolUsageToCard(card, p._replayUsage); if (replayPendingUsage === p._replayUsage) replayPendingUsage = null; }
      else if (state._pendingUsage) { attachToolUsageToCard(card, state._pendingUsage); state._pendingUsage = null; }
      else if (state.lastLLMUsage) attachToolUsageToCard(card);
    } catch (e) {}
    flushTextBlock();
  }

  function toolResult(text, ok, durationMs) {
    const card = state.currentToolCard;
    if (!state.currentTool || !card) return;
    const inner = unwrapToolContent(text);
    // 若调用方误传 ok=true 但内容实为错误，以内容为准（防重复 tool_result 覆盖）
    const finalOk = isToolError(inner) ? false : ok;
    state.currentTool.classList.remove("ok", "err");
    state.currentTool.classList.add(finalOk ? "ok" : "err");
    addToolStatus(card, finalOk);
    state.currentTool.textContent = inner.split("\n").slice(0, 30).join("\n");
    if (!finalOk && lastUserPrompt) {
      addRetryButton(card);
    }
    stampDuration(card, durationMs);
    const srcCode = card.querySelector(".tool-code")?.textContent || "";
    addToolCopyButton(card, inner, srcCode);
    mcToolResult(finalOk, durationMs);
    state.currentTool = null;
    state.currentToolCard = null;
  }
  function addRetryButton(toolCard) {
    if (!toolCard || !lastUserPrompt) return;
    const btn = document.createElement("button");
    btn.className = "btn-retry";
    btn.innerHTML = "↻ 重试";
    btn.addEventListener("click", () => {
      btn.remove();
      input.value = lastUserPrompt;
      send();
    });
    toolCard.appendChild(btn);
  }

  // 工具用时（对齐 TUI ⏱ format_duration）：<60s → X.Xs，否则 Xm Y.Ys
  function formatDur(ms) {
    const secs = ms / 1000;
    if (ms < 1000) return Math.max(1, Math.round(ms)) + "ms";
    if (secs < 10) return secs.toFixed(2) + "s";
    if (secs < 60) return (Math.round(secs * 10) / 10) + "s";
    const m = Math.floor(secs / 60);
    const s = Math.round((secs - m * 60) * 10) / 10;
    return m + "m " + s + "s";
  }
  function stampDuration(card, durationMs) {
    const slot = card && card.querySelector(".tool-dur");
    if (!slot) return;
    let ms = durationMs;
    if (ms == null && card.dataset.startedAt) ms = Date.now() - Number(card.dataset.startedAt);
    if (ms == null) return;
    slot.textContent = " ⏱ " + formatDur(ms);
  }

  // 工具卡：⏱ 旁的成功/失败标识 + 输出复制按钮（live 与回放共用）
  function addToolStatus(card, ok) {
    if (!card) return;
    card.querySelectorAll(".tool-status").forEach((n) => n.remove());
    const sp = document.createElement("span");
    sp.className = "tool-status " + (ok ? "tool-ok" : "tool-bad");
    sp.textContent = ok ? "✓" : "✗";
    const dur = card.querySelector(".tool-dur");
    if (dur && dur.parentNode) dur.parentNode.insertBefore(sp, dur.nextSibling);
    else card.querySelector(".tool-head")?.appendChild(sp);
  }
  function makeToolCopyBtn() {
    const btn = document.createElement("button");
    btn.className = "tool-copy btn-tool-copy";
    btn.title = "复制输出";
    btn.textContent = "⧉";
    btn.addEventListener("click", (ev) => {
      ev.stopPropagation();
      navigator.clipboard.writeText(btn.dataset.text || "").then(() => {
        btn.textContent = "已复制";
        setTimeout(() => (btn.textContent = "⧉"), 1200);
      });
    });
    return btn;
  }
  function addToolCopyButton(card, output, cmd) {
    if (!card) return;
    const head = card.querySelector(".tool-head");
    if (!head) return;
    let btn = head.querySelector(".btn-tool-copy");
    if (!btn) { btn = makeToolCopyBtn(); head.appendChild(btn); }
    const c = (cmd || "").trim();
    const o = output || "";
    btn.dataset.text = c ? `$ ${c}\n\n${o}` : o;
  }
  function shellResult(p) {
    const card = document.createElement("div");
    card.className = "msg msg-tool";
    const head = document.createElement("div");
    head.className = "tool-head";
    head.innerHTML = `<b>$</b> ${escapeHtml(p.cmd || "")}<span class="tool-dur">${p.duration_ms != null ? " ⏱ " + formatDur(p.duration_ms) : ""}</span>`;
    const out = document.createElement("div");
    out.className = "tool-result " + (p.exit === 0 ? "ok" : "err");
    out.textContent = (p.output || "").split("\n").slice(0, 40).join("\n");
    addToolStatus(card, p.exit === 0);
    addToolCopyButton(card, p.output, p.cmd);
    card.append(head, out);
    setBubbleTime(card, p.created_at || state.eventCreatedAt);
    flow.appendChild(card);
    flushTextBlock();
  }
  // dsh 文件 diff 卡片：+/- 行内联着色
  function fileDiff(p) {
    const card = document.createElement("div");
    card.className = "msg msg-tool";
    const head = document.createElement("div");
    head.className = "tool-head";
    const actor = p.session_id ? sessionDisplayName(p.session_id) : "当前会话";
    const st = p.stats || {};
    if (p.path && p.session_id) state.fileAttribution[p.path] = { sessionId: p.session_id, name: actor };
    head.innerHTML = `<b>✎</b> ${escapeHtml(p.path || "")} <span class="diffstat">+${st.added ?? 0} −${st.removed ?? 0}</span><span class="diff-owner">${escapeHtml(actor)}</span>`;
    const body = document.createElement("div");
    body.className = "tool-code";
    (p.diff || []).slice(0, 60).forEach((ln) => {
      const row = document.createElement("div");
      const t = typeof ln === "string" ? ln : (ln.text || "");
      if (t.startsWith("+")) row.style.color = "var(--nb-green)";
      else if (t.startsWith("-")) row.style.color = "var(--nb-red)";
      row.textContent = t;
      body.appendChild(row);
    });
    card.append(head, body);
    setBubbleTime(card, p.created_at || state.eventCreatedAt);
    flow.appendChild(card);
    flushTextBlock();
    mcOnFileChange(p.path);
  }




  // ── 会话协作：分组留在左侧，当前会话过程保持在中间，协作信息进入 Mission Control ──
  // 组请求与会话切换共享代次，旧点击的响应不能覆盖当前会话。
  let groupLoadSeq = 0;

  function rebuildGroupIndex() {
    state.groupBySession = {};
    (state.groups || []).forEach((group) => {
      (group.members || []).forEach((member) => {
        state.groupBySession[member.session_id] = { group, member };
      });
    });
  }

  function currentGroupRef() {
    return state.sid ? state.groupBySession[state.sid] || null : null;
  }

  function sessionDisplayName(sessionId) {
    const session = (state.allSessions || []).find((s) => s.id === sessionId);
    if (session) return session.title || session.id;
    const ref = state.groupBySession[sessionId];
    return ref && ref.member && ref.member.role ? `${ref.member.role} · ${sessionId.slice(-6)}` : sessionId;
  }

  async function loadGroups() {
    const sid = state.sid;
    const seq = ++groupLoadSeq;
    if (!sid) {
      state.groups = [];
      rebuildGroupIndex();
      renderSessionList();
      return;
    }
    try {
      const result = await rpc("group.list", { sessionId: sid });
      if (seq !== groupLoadSeq || state.sid !== sid) return;
      state.groups = result.groups || [];
    } catch (e) {
      if (seq !== groupLoadSeq || state.sid !== sid) return;
      state.groups = [];
    }
    rebuildGroupIndex();
    renderSessionList();
    await loadActiveGroup(sid, seq);
  }

  async function loadActiveGroup(expectedSid = state.sid, expectedSeq = groupLoadSeq) {
    if (expectedSeq !== groupLoadSeq || state.sid !== expectedSid) return;
    const ref = state.groupBySession[expectedSid] || null;
    const delegate = $("delegate-session");
    const paintDelegate = (visible, enabled, hint) => {
      if (!delegate) return;
      delegate.classList.toggle("hidden", !visible);
      delegate.disabled = !enabled;
      if (hint) delegate.title = hint;
    };
    if (!ref) {
      state.activeGroupId = null;
      state.activeGroup = null;
      state.groupMessages = [];
      state.groupActivity = [];
      state.groupTasks = [];
      state.taskReviews = {};
      paintDelegate(false, false, "让另一个 AI 分担当前工作");
      renderCollaborationPane();
      renderCollaborationTasks();
      return;
    }
    const groupId = ref.group.group_id;
    if (state.activeGroupId !== groupId) state.taskReviews = {};
    state.activeGroupId = groupId;
    if (ref.group.coordinator_session_id === expectedSid) {
      paintDelegate(true, true, "让另一个 AI 分担当前工作");
    } else {
      paintDelegate(true, false, "仅工作组协调者可派生子会话（你是成员，可发协作消息向协调者申请）");
    }

    if (delegate) delegate.classList.toggle("hidden", ref.group.coordinator_session_id !== expectedSid);
    try {
      const [group, messages, activity, tasks] = await Promise.all([
        rpc("group.get", { groupId, sessionId: expectedSid }),
        rpc("collab.message.list", { groupId, sessionId: expectedSid, limit: 200 }),
        rpc("group.activity.list", { groupId, sessionId: expectedSid, limit: 100 }),
        rpc("group.task.list", { groupId, sessionId: expectedSid }),
      ]);
      if (expectedSeq !== groupLoadSeq || state.sid !== expectedSid || state.activeGroupId !== groupId) return;
      state.activeGroup = group;
      state.groupMessages = messages.messages || [];
      state.groupActivity = activity.activity || [];
      state.groupTasks = tasks.tasks || [];
    } catch (e) {
      if (expectedSeq !== groupLoadSeq || state.sid !== expectedSid || state.activeGroupId !== groupId) return;
      state.activeGroup = null;
      state.groupMessages = [];
      state.groupActivity = [];
      state.groupTasks = [];
      state.taskReviews = {};
    }
    if (expectedSeq !== groupLoadSeq || state.sid !== expectedSid) return;
    renderCollaborationPane();
    renderCollaborationTasks();
  }

  // ── 协作未读：按组记忆已读事件水位（localStorage 持久），MC 未展开或页签不在协作时计未读 ──
  function loadCollabSeen() {
    try { return JSON.parse(localStorage.getItem("newbee.collab.seen") || "{}") || {}; }
    catch (e) { return {}; }
  }
  function saveCollabSeen() {
    try { localStorage.setItem("newbee.collab.seen", JSON.stringify(state.collabSeen || {})); } catch (e) {}
  }
  function collabUnreadCount(groupId) {
    return (state.collabUnread && state.collabUnread[groupId]) || 0;
  }
  function maxEventId(events) {
    let max = 0;
    (events || []).forEach((e) => { const id = Number(e.event_id || 0); if (id > max) max = id; });
    return max;
  }
  function viewingCollabNow() {
    return typeof MC !== "undefined" && MC.open && (MC.tab === "collaboration" || MC.tab === "tasks");
  }
  function markCollabSeen(groupId) {
    if (!groupId) return;
    const seen = Math.max(maxEventId(state.groupActivity), Number((state.collabSeen || {})[groupId] || 0));
    state.collabSeen[groupId] = seen;
    if (state.collabUnread) delete state.collabUnread[groupId];
    saveCollabSeen();
    updateCollabBadges();
  }
  function bumpCollabUnread(groupId, eventId) {
    if (!groupId) return;
    const seen = Number((state.collabSeen || {})[groupId] || 0);
    if (Number(eventId || 0) <= seen) return;
    if (groupId === state.activeGroupId && viewingCollabNow()) {
      state.collabSeen[groupId] = Math.max(seen, Number(eventId || 0));
      saveCollabSeen();
      return;
    }
    state.collabUnread[groupId] = (state.collabUnread[groupId] || 0) + 1;
    updateCollabBadges();
    if (typeof renderSessionList === "function") renderSessionList();
  }
  function updateCollabBadges() {
    const badge = $("mc-collab-unread");
    if (badge) {
      const n = state.activeGroupId ? collabUnreadCount(state.activeGroupId) : 0;
      badge.classList.toggle("hidden", !n);
      if (n) badge.textContent = n > 99 ? "99+" : String(n);
    }
    const attention = $("mc-task-attention");
    if (attention) {
      const n = (state.groupTasks || []).filter((t) => taskAttentionKind(t)).length;
      attention.classList.toggle("hidden", !n);
      if (n) attention.textContent = n > 99 ? "99+" : String(n);
    }
    const expand = $("mc-expand");
    if (expand) {
      const total = Object.values(state.collabUnread || {}).reduce((a, b) => a + (Number(b) || 0), 0);
      expand.classList.toggle("has-unread", total > 0);
      expand.title = total > 0 ? `打开 Mission Control（${total} 条未读协作动态）` : "打开 Mission Control";
    }
  }

  // ── 协作标签与真状态：kind 徽标 / 验证 / 群状态 / 成员 presence（以后端运行时为准，不再恒绿） ──
  function messageKindLabel(kind) {
    return ({ chat: "闲聊", question: "提问", task_assign: "分派", task_progress: "进展", task_result: "结果", artifact: "附件", system: "系统", error: "错误" })[kind] || kind || "闲聊";
  }
  function verificationLabel(v) {
    const s = v && v.status;
    return s === "passed" ? "验证通过" : s === "failed" ? "验证未通过" : s === "pending" ? "待验证" : (s || "");
  }
  function groupStatusLabel(status) {
    return ({ running: "进行中", paused: "已暂停", cancelled: "已取消", draft: "草稿", completed: "已完成", failed: "失败" })[status] || status || "";
  }
  function sessionRuntime(sessionId) {
    return (state.allSessions || []).find((s) => s.id === sessionId) || null;
  }
  function memberPresence(sessionId) {
    const s = sessionRuntime(sessionId);
    if (!s) return { cls: "offline", label: "离线" };
    if (s.busy) return { cls: "busy", label: "工作中" };
    return s.running ? { cls: "online", label: "在线" } : { cls: "offline", label: "离线" };
  }
  function memberCurrentTask(sessionId) {
    const open = (state.groupTasks || []).filter((t) => t.assigned_session_id === sessionId);
    const live = open.filter((t) => ["succeeded", "failed", "cancelled"].indexOf(t.status || "") < 0);
    live.sort((a, b) => String(a.updated_at || a.created_at || "") < String(b.updated_at || b.created_at || "") ? 1 : -1);
    return live[0] || null;
  }

  // ── 任务筛选排序与卡片增强：风险置顶 / 验收展示 / 依赖链 / 验证徽标 ──
  function taskAttentionKind(task) {
    const status = task.status || "";
    if (status === "blocked" || status === "failed") return "risk";
    const ws = task.workspace && task.workspace.review_status;
    if (ws === "pending") return "review";
    return null;
  }
  function taskMatchesFilter(task) {
    const f = state.taskFilter || "all";
    if (f === "mine") return task.assigned_session_id === state.sid || task.created_by_session_id === state.sid;
    if (f === "attention") return !!taskAttentionKind(task);
    if (f === "review") return task.workspace && task.workspace.review_status === "pending";
    return true;
  }
  function taskSortRank(task) {
    const k = taskAttentionKind(task);
    if (k === "risk") return 0;
    if (k === "review") return 1;
    if (["succeeded", "failed", "cancelled"].indexOf(task.status || "") < 0) return 2;
    return 3;
  }
  function compareTasks(a, b) {
    const r = taskSortRank(a) - taskSortRank(b);
    if (r) return r;
    const au = a.updated_at || a.created_at || "";
    const bu = b.updated_at || b.created_at || "";
    return au < bu ? 1 : au > bu ? -1 : 0;
  }
  function renderAcceptance(task) {
    const acc = task.acceptance;
    if (Array.isArray(acc)) {
      if (!acc.length) return '<div class="collab-accept-empty">未设成功标准</div>';
      const rows = acc.map((c) => {
        if (!c || typeof c !== "object") return "";
        if (c.kind === "command") return '<div class="collab-accept-item"><span class="collab-accept-kind">命令</span><code>' + escapeHtml(c.program || "") + " " + escapeHtml((c.args || []).join(" ")) + "</code></div>";
        if (c.kind === "file_exists") return '<div class="collab-accept-item"><span class="collab-accept-kind">文件存在</span><code>' + escapeHtml(c.path || "") + "</code></div>";
        if (c.kind === "file_sha256") return '<div class="collab-accept-item"><span class="collab-accept-kind">文件哈希</span><code>' + escapeHtml(c.path || "") + "</code></div>";
        return '<div class="collab-accept-item"><span class="collab-accept-kind">' + escapeHtml(c.kind || "标准") + "</span></div>";
      }).join("");
      return '<div class="collab-accept-list">' + rows + "</div>";
    }
    if (typeof acc === "string" && acc.trim()) return '<div class="collab-accept-verbal">' + escapeHtml(acc) + '<span class="collab-accept-note">口头约定·需人工核对</span></div>';
    return '<div class="collab-accept-empty">未设成功标准</div>';
  }
  function renderDepends(task) {
    const deps = task.depends_on || [];
    if (!deps.length) return "";
    const byId = {};
    (state.groupTasks || []).forEach((t) => { byId[t.task_id] = t; });
    const chips = deps.map((id) => {
      const t = byId[id];
      const label = t ? ((t.title || "工作项") + "·" + taskStatusLabel(t.status)) : ("未知 " + String(id).slice(-6));
      return '<button class="collab-dep-chip" data-dep-task="' + escapeHtml(id) + '" title="前置工作项">' + escapeHtml(label) + "</button>";
    }).join("");
    return '<div class="collab-depends">前置：' + chips + "</div>";
  }

  function renderCollaborationPane() {
    const list = $("mc-collab-list");


    const members = $("mc-collab-members");
    const recipient = $("mc-collab-recipient");
    if (!list || !members || !recipient) return;

    const group = state.activeGroup;
    if (!group) {
      $("mc-collab-title").textContent = "协作消息";
      members.innerHTML = "";
      recipient.innerHTML = "";
      list.innerHTML = '<div class="collab-empty">当前是普通会话。勾选多个会话可组成工作组。</div>';
      $("mc-collab-input").disabled = true;
      $("mc-collab-send").disabled = true;
      return;
    }

    $("mc-collab-title").textContent = group.title || "协作消息";
    $("mc-collab-input").disabled = false;
    $("mc-collab-send").disabled = false;
    renderGroupStatus(group);
    const keepRecipient = recipient.value;
    members.innerHTML = (group.members || []).map((member) => {
      const active = member.session_id === state.sid ? " active" : "";
      const presence = memberPresence(member.session_id);
      const current = memberCurrentTask(member.session_id);
      const doing = current ? ` · ${current.title || "工作项"}` : "";
      const title = `${sessionDisplayName(member.session_id)}（${member.role || "worker"}）· ${presence.label}${doing}`;
      return '<button class="collab-member' + active + '" data-session="' + escapeHtml(member.session_id) + '" title="' + escapeHtml(title) + '"><span class="sess-dot ' + presence.cls + '"></span><b>' + escapeHtml(sessionDisplayName(member.session_id)) + "</b><small>" + escapeHtml(member.role || "worker") + " · " + presence.label + doing + "</small></button>";
    }).join("");
    members.querySelectorAll("[data-session]").forEach((button) => {
      button.onclick = () => resume(button.dataset.session);
    });

    recipient.innerHTML = '<option value="">发给所有协作会话</option>' +
      (group.members || []).filter((m) => m.session_id !== state.sid).map((m) =>
        `<option value="${escapeHtml(m.session_id)}">发给：${escapeHtml(sessionDisplayName(m.session_id))}</option>`
      ).join("");
    if (keepRecipient && recipient.querySelector(`option[value="${CSS.escape(keepRecipient)}"]`)) recipient.value = keepRecipient;

    renderCollaborationActivity();

    const messages = state.groupMessages || [];
    list.innerHTML = messages.length ? messages.map((message) => {
      const target = message.to_session_id ? sessionDisplayName(message.to_session_id) : "所有协作会话";
      const mine = message.sender_session_id === state.sid ? " mine" : "";
      const kindBadge = message.kind && message.kind !== "chat" ? ' <em class="collab-kbadge">' + escapeHtml(messageKindLabel(message.kind)) + "</em>" : "";
      const deliveryBadge = message.delivery && message.delivery !== "notify" ? ' <em class="collab-dbadge">' + escapeHtml(deliveryLabel(message.delivery)) + "</em>" : "";
      const when = message.created_at ? new Date(message.created_at) : null;
      const at = when ? when.toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" }) : "";
      const full = when ? when.toLocaleString() : "";
      return '<article class="collab-message' + mine + '"><div class="collab-message-head"><b>' + escapeHtml(sessionDisplayName(message.sender_session_id)) + "</b><span>→ " + escapeHtml(target) + "</span>" + kindBadge + deliveryBadge + '<time title="' + escapeHtml(full) + '">' + escapeHtml(at) + "</time></div><div>" + escapeHtml(message.body || "") + "</div></article>";
    }).join("") : '<div class="collab-empty">还没有协作消息</div>';
    list.scrollTop = list.scrollHeight;
    markCollabSeen(group.group_id);

  }

  function collaborationActivitySummary(event) {
    const payload = event.payload || {};
    const topic = event.topic || "";
    const task = payload.task || {};
    const member = payload.member || {};
    const message = payload.message || {};
    if (topic === "collab_group_created") return { kind: "工作组", text: "工作组已建立" };
    if (topic === "collab_delegated") return { kind: "派生", text: `${sessionDisplayName(member.session_id)} · ${task.title || "工作项"}`, sessionId: member.session_id, tab: "tasks" };
    if (topic === "collab_member_added") return { kind: "成员", text: `${sessionDisplayName(member.session_id)} 已加入`, sessionId: member.session_id };
    if (topic === "collab_member_removed") return { kind: "成员", text: `${sessionDisplayName(member.session_id)} 已移出` };
    if (topic === "collab_task_created") return { kind: "工作项", text: task.title || "已创建", tab: "tasks" };
    if (topic === "collab_task_updated") return { kind: "工作项", text: `${task.title || "工作项"} · ${taskStatusLabel(task.status)}`, tab: "tasks" };
    if (topic === "collab_task_claimed") return { kind: "工作项", text: `${sessionDisplayName(task.assigned_session_id)} 已领取`, tab: "tasks" };
    if (topic === "collab_workspace_updated") return { kind: "变更", text: `${task.title || "工作项"} · ${workspaceStatusLabel(task.workspace && task.workspace.review_status)}`, tab: "tasks" };
    if (topic === "collab_message_created") return { kind: "消息", text: `${sessionDisplayName(message.sender_session_id)} → ${message.to_session_id ? sessionDisplayName(message.to_session_id) : "所有成员"}` };
    if (topic === "collab_group_status_changed") return { kind: "状态", text: payload.status || "已更新" };
    return null;
  }

  // ── 群生命周期入口：状态徽标 + 协调者专属暂停/恢复/取消（后端仅 running/paused/cancelled） ──
  function renderGroupStatus(group) {
    const badge = $("mc-group-status");
    const lifecycle = $("mc-group-lifecycle");
    const status = group.status || "running";
    if (badge) {
      badge.textContent = groupStatusLabel(status);
      badge.className = "collab-group-status " + status;
    }
    if (!lifecycle) return;
    const isCoord = group.coordinator_session_id === state.sid;
    if (!isCoord) { lifecycle.innerHTML = ""; return; }
    const buttons = [];
    if (status === "running") buttons.push('<button class="btn-ghost" data-group-pause title="暂停：保留消息和任务，不再启动新的模型工作">暂停</button>');
    if (status === "paused") buttons.push('<button class="btn-ghost" data-group-resume title="恢复模型工作">恢复</button>');
    if (status === "running" || status === "paused") buttons.push('<button class="btn-danger" data-group-cancel title="取消整个工作组（事件保留，可审计）">取消</button>');
    lifecycle.innerHTML = buttons.join("");
    const pause = lifecycle.querySelector("[data-group-pause]");
    const resume = lifecycle.querySelector("[data-group-resume]");
    const cancel = lifecycle.querySelector("[data-group-cancel]");
    if (pause) pause.onclick = () => setGroupStatusAction("paused");
    if (resume) resume.onclick = () => setGroupStatusAction("running");
    if (cancel) cancel.onclick = () => setGroupStatusAction("cancelled");
  }
  async function setGroupStatusAction(status) {
    const group = state.activeGroup;
    if (!group) return;
    const label = groupStatusLabel(status);
    const go = async () => {
      try {
        await rpc("group.setStatus", { groupId: group.group_id, sessionId: state.sid, status });
        await loadActiveGroup();
        line("notice", "工作组已" + label);
      } catch (e) { line("error", "工作组" + label + "失败: " + e.message); }
    };
    if (status === "cancelled") {
      confirmDialog("取消工作组「" + (group.title || "") + "」？消息和任务事件保留，可审计。", go, { confirmLabel: "取消工作组", confirmClass: "btn-deny" });
    } else {
      go();
    }
  }

  function renderCollaborationActivity() {
    const host = $("mc-collab-activity");
    if (!host) return;
    const more = $("mc-collab-activity-more");
    const all = (state.groupActivity || []).map((event) => ({ event, summary: collaborationActivitySummary(event) })).filter((row) => row.summary);
    const expanded = !!state.activityExpanded;
    const rows = (expanded ? all : all.slice(-8)).reverse();
    if (more) {
      more.classList.toggle("hidden", all.length <= 8);
      more.textContent = expanded ? "只看最近" : `展开全部（${all.length}）`;
    }
    host.innerHTML = rows.length ? rows.map(({ event, summary }) => {
      const at = event.at ? new Date(event.at).toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" }) : "";
      const session = summary.sessionId ? ` data-activity-session="${escapeHtml(summary.sessionId)}"` : "";
      const tab = summary.tab ? ` data-activity-tab="${escapeHtml(summary.tab)}"` : "";
      return `<button class="collab-activity"${session}${tab}><span>${escapeHtml(summary.kind)}</span><b>${escapeHtml(summary.text)}</b><time>${escapeHtml(at)}</time></button>`;
    }).join("") : "";
    host.querySelectorAll("[data-activity-session]").forEach((button) => { button.onclick = () => resume(button.dataset.activitySession); });
    host.querySelectorAll("[data-activity-tab]").forEach((button) => { if (!button.dataset.activitySession) button.onclick = () => switchMCTab(button.dataset.activityTab); });
  }

  function deliveryLabel(d) {
    return ({ notify: "仅通知", queue: "排队处理", wake: "立即处理" })[d] || "仅通知";
  }

  function formatTaskResult(result) {

    if (result == null) return "";
    if (typeof result === "string") return result;
    try { return JSON.stringify(result, null, 2); } catch (_) { return String(result); }
  }

  function taskStatusLabel(status) {
    return ({ pending: "未开始", assigned: "已分派", accepted: "已接受", running: "进行中", blocked: "受阻", submitted: "已提交待验", succeeded: "已完成", failed: "失败", cancelled: "已取消" })[status] || status || "未开始";
  }


  function workspaceStatusLabel(status) {
    return ({ waiting: "等待任务完成", pending: "待审查", applied: "已应用", rejected: "已拒绝", cleaned: "已释放", not_applicable: "共享目录" })[status] || status || "";
  }

  function workspaceControls(task, group) {
    const workspace = task.workspace;
    if (!workspace) return "";
    const status = workspace.review_status || "waiting";
    const coordinator = group.coordinator_session_id === state.sid;
    const review = state.taskReviews[task.task_id];
    const reviewable = workspace.kind === "git_worktree" && ["pending", "applied", "rejected"].includes(status);
    const reviewButton = reviewable ? `<button class="btn-ghost" data-review-task="${escapeHtml(task.task_id)}">${review ? "刷新变更" : "查看变更"}</button>` : "";
    const decisionButtons = coordinator && status === "pending" && review ? `<button class="btn-primary" data-apply-task="${escapeHtml(task.task_id)}" data-sha="${escapeHtml(review.patch_sha256 || "")}">${review.dirty ? "应用变更" : "确认无变更"}</button><button class="btn-danger" data-reject-task="${escapeHtml(task.task_id)}">拒绝</button>` : "";
    const cleanupButton = coordinator && ["applied", "rejected"].includes(status) ? `<button class="btn-ghost" data-cleanup-task="${escapeHtml(task.task_id)}">释放隔离目录</button>` : "";
    const badge = `<span class="collab-workspace-badge ${escapeHtml(status)}">${escapeHtml(workspaceStatusLabel(status))}</span>`;
    return `<div class="collab-workspace"><div class="collab-workspace-head"><span>独立工作区</span>${badge}</div><div class="collab-task-actions">${reviewButton}${decisionButtons}${cleanupButton}</div>${review ? renderWorkspaceReview(review) : ""}</div>`;
  }

  function renderWorkspaceReview(review) {
    const files = review.files || [];
    const totals = files.reduce((acc, file) => ({ added: acc.added + (file.added || 0), deleted: acc.deleted + (file.deleted || 0) }), { added: 0, deleted: 0 });
    const summary = review.dirty ? `${files.length} 个文件 · +${totals.added} −${totals.deleted}` : "无文件变更";
    const fileRows = files.map((file) => `<div class="collab-review-file"><span>${escapeHtml(file.status || "M")}</span><b>${escapeHtml(file.path || "")}</b><small>+${file.added || 0} −${file.deleted || 0}</small></div>`).join("");
    const warning = review.patch_truncated ? '<div class="collab-review-warning">Diff 较大，界面仅显示前 600 KB；应用时仍校验完整补丁。</div>' : "";
    const diff = review.display_patch ? `<div class="collab-review-diff">${renderDiffHtml(review.display_patch)}</div>` : '<div class="collab-empty">该任务没有产生文件变更</div>';
    return `<div class="collab-review"><div class="collab-review-summary">${escapeHtml(summary)}</div>${fileRows}${warning}${diff}</div>`;
  }

  function renderDiffHtml(diffText) {
    return String(diffText || "").split("\n").map((lineText) => {
      let cls = "";
      if (lineText.startsWith("diff --git") || lineText.startsWith("index ") || lineText.startsWith("---") || lineText.startsWith("+++")) cls = "diff-header";
      else if (lineText.startsWith("@@")) cls = "diff-hunk";
      else if (lineText.startsWith("+")) cls = "diff-add";
      else if (lineText.startsWith("-")) cls = "diff-del";
      return `<div class="${cls}">${escapeHtml(lineText)}</div>`;
    }).join("");
  }

  function renderCollaborationTasks() {
    const list = $("mc-task-list");
    const create = $("mc-task-new");
    if (!list || !create) return;
    const group = state.activeGroup;
    create.disabled = !group;
    document.querySelectorAll("#mc-task-filters [data-task-filter]").forEach((b) => {
      b.classList.toggle("active", (b.dataset.taskFilter || "all") === (state.taskFilter || "all"));
    });
    if (!group) {
      $("mc-task-title").textContent = "工作项";
      list.innerHTML = '<div class="collab-empty">当前会话没有工作组</div>';
      updateCollabBadges();
      return;
    }

    $("mc-task-title").textContent = `${group.title || "工作组"} · 工作项`;
    const tasks = (state.groupTasks || []).slice().sort(compareTasks);
      return `<article class="collab-task ${escapeHtml(status)}${attention ? " attention-" + attention : ""}" data-task-anchor="${escapeHtml(task.task_id)}"><div class="collab-task-title">${escapeHtml(task.title || "未命名工作项")}${proto}${verify}</div><div class="collab-task-meta">${escapeHtml(owner)} · ${escapeHtml(taskStatusLabel(status))} · ${updated}</div>${progress}${result}${renderAcceptance(task)}${renderDepends(task)}${claim}${actions}${workspaceControls(task, group)}</article>`;

    const hiddenCount = tasks.length - visible.length;
    list.innerHTML = tasks.length ? (visible.map((task) => {
      const owner = task.assigned_session_id ? sessionDisplayName(task.assigned_session_id) : "未分配";
      const status = task.status || "pending";
      const attention = taskAttentionKind(task);
      const progress = task.progress ? `<div class="collab-task-progress">进度：${escapeHtml(String(task.progress))}</div>` : "";
      const result = task.result != null && status !== "pending" && status !== "assigned" ? `<div class="collab-task-result"><strong>${status === "succeeded" ? "结果" : "失败信息"}</strong><div>${escapeHtml(formatTaskResult(task.result))}</div></div>` : "";
      const claim = !task.assigned_session_id && status === "pending" ? `<button class="btn-ghost" data-claim="${escapeHtml(task.task_id)}">领取</button>` : "";
      const actions = task.assigned_session_id ? `<div class="collab-task-actions"><button class="btn-ghost" data-open-session="${escapeHtml(task.assigned_session_id)}">查看会话</button><button class="btn-ghost" data-message-session="${escapeHtml(task.assigned_session_id)}">发消息</button></div>` : "";
      const verify = task.verification && task.verification.status ? `<span class="collab-verify-badge ${escapeHtml(task.verification.status)}">${escapeHtml(verificationLabel(task.verification))}</span>` : "";
      const proto = task.protocol_version === 2 ? '<span class="collab-proto-badge" title="结构化验收 · 机器可验证">v2</span>' : "";
      const updated = task.updated_at ? `<span class="collab-task-updated" title="${escapeHtml(task.updated_at)}">更新 ${escapeHtml(task.updated_at.slice(0, 16).replace("T", " "))}</span>` : "";
      return `<article class="collab-task ${escapeHtml(status)}${attention ? " attention-" + attention : ""}"><div class="collab-task-title">${escapeHtml(task.title || "未命名工作项")}${proto}${verify}</div><div class="collab-task-meta">${escapeHtml(owner)} · ${escapeHtml(taskStatusLabel(status))} · ${updated}</div>${progress}${result}${renderAcceptance(task)}${renderDepends(task)}${claim}${actions}${workspaceControls(task, group)}</article>`;
    }).join("") + (hiddenCount ? `<div class="collab-empty">已按筛选隐藏 ${hiddenCount} 项（点“全部”查看）</div>` : "")) : '<div class="collab-empty">暂无工作项</div>';
    bindTaskActions(group, list);
    updateCollabBadges();
  }


  function bindTaskActions(group, list) {
    list.querySelectorAll("[data-open-session]").forEach((button) => { button.onclick = () => resume(button.dataset.openSession); });
    list.querySelectorAll("[data-message-session]").forEach((button) => {
      button.onclick = () => {
        const recipient = $("mc-collab-recipient");
        if (recipient) recipient.value = button.dataset.messageSession;
        switchMCTab("collaboration");
        $("mc-collab-input").focus();
      };
    });
    list.querySelectorAll("[data-claim]").forEach((button) => {
      button.onclick = async () => {
        try {
          await rpc("group.task.claim", { groupId: group.group_id, taskId: button.dataset.claim, sessionId: state.sid });
          await loadActiveGroup();
        } catch (e) { line("error", "领取工作项失败: " + e.message); }
      };
    });
    list.querySelectorAll("[data-review-task]").forEach((button) => { button.onclick = () => reviewTaskWorkspace(button.dataset.reviewTask); });
    list.querySelectorAll("[data-apply-task]").forEach((button) => { button.onclick = () => applyTaskWorkspace(button.dataset.applyTask, button.dataset.sha); });
    list.querySelectorAll("[data-reject-task]").forEach((button) => { button.onclick = () => rejectTaskWorkspace(button.dataset.rejectTask); });
    list.querySelectorAll("[data-cleanup-task]").forEach((button) => { button.onclick = () => cleanupTaskWorkspace(button.dataset.cleanupTask); });
    list.querySelectorAll("[data-dep-task]").forEach((button) => {
      button.onclick = () => {
        const el = list.querySelector(`[data-task-anchor="${CSS.escape(button.dataset.depTask)}"]`);
        if (el) { el.scrollIntoView({ block: "center" }); el.classList.add("flash"); setTimeout(() => el.classList.remove("flash"), 1600); }
        else line("notice", "前置工作项不在当前筛选或分组中");
      };
    });

  }

  async function reviewTaskWorkspace(taskId) {
    try {
      const review = await rpc("group.workspace.review", { groupId: state.activeGroup.group_id, taskId, sessionId: state.sid });
      state.taskReviews[taskId] = review;
      renderCollaborationTasks();
    } catch (e) { line("error", "读取子代理变更失败: " + e.message); }
  }

  async function applyTaskWorkspace(taskId, patchSha256) {
    if (!patchSha256 || !window.confirm("将已审查的子代理变更应用到当前工作区？应用后仍需检查并提交。")) return;
    try {
      await rpc("group.workspace.apply", { groupId: state.activeGroup.group_id, taskId, sessionId: state.sid, patchSha256, commandId: `workspace-apply-${Date.now()}` });
      delete state.taskReviews[taskId];
      line("notice", "已应用子代理变更到当前工作区，仍需检查并提交");
      await loadActiveGroup();
      refreshMCFiles();
    } catch (e) { line("error", "应用子代理变更失败: " + e.message); }
  }

  async function rejectTaskWorkspace(taskId) {
    if (!window.confirm("拒绝这批子代理变更？隔离目录会暂时保留，之后仍可查看。")) return;
    try {
      await rpc("group.workspace.reject", { groupId: state.activeGroup.group_id, taskId, sessionId: state.sid, commandId: `workspace-reject-${Date.now()}` });
      line("notice", "已拒绝子代理变更；会话历史和隔离目录仍保留");
      await loadActiveGroup();
    } catch (e) { line("error", "拒绝子代理变更失败: " + e.message); }
  }

  async function cleanupTaskWorkspace(taskId) {
    if (!window.confirm("释放隔离目录？子代理会话历史会保留，但该目录中的文件将被删除。")) return;
    try {
      await rpc("group.workspace.cleanup", { groupId: state.activeGroup.group_id, taskId, sessionId: state.sid, commandId: `workspace-cleanup-${Date.now()}` });
      delete state.taskReviews[taskId];
      line("notice", "已释放隔离目录；子代理会话历史仍可查看");
      await loadActiveGroup();
    } catch (e) { line("error", "释放隔离目录失败: " + e.message); }
  }

  function openGroupModal() {
    const ids = Array.from(state.selectedSessions || []);
    if (!ids.length) {
      line("error", "请先勾选要一起工作的会话");
      return;
    }
    if (state.sid && !ids.includes(state.sid)) ids.unshift(state.sid);
    state.pendingGroupMembers = ids;
    $("group-name-input").value = "";
    $("group-goal-input").value = "";
    $("group-member-chips").innerHTML = ids.map((id) => `<span>${escapeHtml(sessionDisplayName(id))}</span>`).join("");
    $("group-modal").classList.remove("hidden");
    window.setTimeout(() => $("group-name-input").focus(), 0);
  }

  async function createGroup() {
    if (!state.sid) return;
    const ids = state.pendingGroupMembers || [];
    const title = $("group-name-input").value.trim();
    const goal = $("group-goal-input").value.trim();
    if (!title && !goal) { $("group-goal-input").focus(); return; }
    const button = $("group-modal-confirm");
    button.disabled = true;
    try {
      const group = await rpc("group.create", { sessionId: state.sid, title, goal, commandId: `group-create-${Date.now()}` });
      for (const sid of ids.filter((id) => id !== state.sid)) {
        await rpc("group.member.add", { groupId: group.group_id, actorSessionId: state.sid, parentSessionId: state.sid, sessionId: sid, role: "worker", commandId: `group-add-${group.group_id}-${sid}` });
      }
      state.selectedSessions.clear();
      $("group-modal").classList.add("hidden");
      await Promise.all([loadSessions(), loadGroups()]);
      switchMCTab("collaboration");
      setMCOpen(true);
    } catch (e) {
      line("error", "组成工作组失败: " + e.message);
    } finally {
      button.disabled = false;
    }
  }

  function openDelegateModal() {
    const ref = currentGroupRef();
    if (!ref || ref.group.coordinator_session_id !== state.sid) return;
    $("delegate-name").value = "";
    $("delegate-task").value = "";
    $("delegate-acceptance").value = "";
    $("delegate-modal").classList.remove("hidden");
    window.setTimeout(() => $("delegate-task").focus(), 0);
  }

  async function delegateSession() {
    const ref = currentGroupRef();
    const title = $("delegate-task").value.trim();
    if (!ref || !title) { $("delegate-task").focus(); return; }
    const button = $("delegate-confirm");
    button.disabled = true;
    try {
      const result = await rpc("group.member.delegate", {
        groupId: ref.group.group_id,
        parentSessionId: state.sid,
        name: $("delegate-name").value.trim() || title.slice(0, 40),
        title,
        description: title,
        acceptance: $("delegate-acceptance").value.trim(),
        role: "worker",
        commandId: `delegate-${Date.now()}`,
      });
      $("delegate-modal").classList.add("hidden");
      await Promise.all([loadSessions(), loadGroups()]);
      line("notice", `已在当前协作组派生子会话：${sessionDisplayName(result.sessionId)}；当前会话保持不变`);
    } catch (e) {
      line("error", "启动协作会话失败: " + e.message);
    } finally {
      button.disabled = false;
    }
  }


  // ── 成功标准编辑器：command / file_exists / file_sha256 三类（与后端 Verification 合同对齐） ──
  // 说明：界面建任务走老协议透存（v1），此处是“写下来的约定，需人工核对”，不是机器验收。
  function addAcceptanceRow(kind, main, extra) {
    const host = $("task-acceptance-list");
    if (!host) return;
    const row = document.createElement("div");
    row.className = "task-accept-row";
    row.innerHTML = '<select class="task-accept-kind" title="标准类型">'
      + '<option value="command">命令</option>'
      + '<option value="file_exists">文件存在</option>'
      + '<option value="file_sha256">文件哈希</option>'
      + '</select>'
      + '<input class="task-accept-main" type="text" placeholder="程序（如 mix test）或路径" maxlength="500" />'
      + '<input class="task-accept-extra" type="text" placeholder="参数（空格分隔）或 sha256" maxlength="500" />'
      + '<button class="btn-ghost task-accept-remove" type="button" title="删除这条">×</button>';
    row.querySelector(".task-accept-kind").value = kind || "command";
    row.querySelector(".task-accept-main").value = main || "";
    row.querySelector(".task-accept-extra").value = extra || "";
    row.querySelector(".task-accept-remove").onclick = () => row.remove();
    host.appendChild(row);
  }
  function buildTaskAcceptance() {
    const rows = Array.from(document.querySelectorAll("#task-acceptance-list .task-accept-row"));
    const out = [];
    for (const row of rows) {
      const kind = row.querySelector(".task-accept-kind").value;
      const main = row.querySelector(".task-accept-main").value.trim();
      const extra = row.querySelector(".task-accept-extra").value.trim();
      if (!main) return { error: "成功标准有一行未填（程序或路径不能为空）" };
      if (kind === "command") {
        out.push({ kind: "command", program: main.split(/\s+/)[0], args: (main.split(/\s+/).slice(1).join(" ") + " " + extra).trim().split(/\s+/).filter(Boolean) });
      } else if (kind === "file_exists") {
        out.push({ kind: "file_exists", path: main });
      } else {
        if (!/^[0-9a-fA-F]{64}$/.test(extra)) return { error: "文件哈希需要 64 位十六进制 sha256（填在第二格）" };
        out.push({ kind: "file_sha256", path: main, sha256: extra.toLowerCase() });
      }
    }
    return { criteria: out };
  }
  function openTaskModal() {
    if (!state.activeGroup) return;
    $("task-name").value = "";
    $("task-description").value = "";
    $("task-owner").innerHTML = '<option value="">暂不分配</option>' + (state.activeGroup.members || []).map((member) => `<option value="${escapeHtml(member.session_id)}">${escapeHtml(sessionDisplayName(member.session_id))}</option>`).join("");
    $("task-acceptance-list").innerHTML = "";
    $("task-modal").classList.remove("hidden");
    $("task-name").focus();
  }

  async function createCollaborationTask() {
    const title = $("task-name").value.trim();

    if (!state.activeGroup || !title) { $("task-name").focus(); return; }
    const built = buildTaskAcceptance();
    if (built.error) { line("error", "创建工作项失败: " + built.error); return; }
    const button = $("task-confirm");
    button.disabled = true;
    try {
      await rpc("group.task.create", {
        groupId: state.activeGroup.group_id,
        sessionId: state.sid,
        assignedSessionId: $("task-owner").value || null,
        title,
        description: $("task-description").value.trim(),
        acceptance: built.criteria,
        commandId: `task-create-${Date.now()}`,
      });
      $("task-modal").classList.add("hidden");
      await loadActiveGroup();
    } catch (e) { line("error", "创建工作项失败: " + e.message); }
    finally { button.disabled = false; }
  }
  async function sendCollaborationMessage() {

    const inputEl = $("mc-collab-input");
    const body = inputEl.value.trim();
    if (!body || !state.activeGroup) return;
    try {
      await rpc("collab.message.send", {
        groupId: state.activeGroup.group_id,
        senderSessionId: state.sid,
        toSessionId: $("mc-collab-recipient").value || null,
        kind: "chat",
        delivery: ($("mc-collab-delivery") || {}).value || "notify",
        body,
        commandId: `collab-message-${Date.now()}`,
      });
      inputEl.value = "";
      await loadActiveGroup();
    } catch (e) { line("error", "发送协作消息失败: " + e.message); }
  }

  async function removeSessionFromGroup(session) {
    const ref = state.groupBySession[session.id];
    if (!ref) return;
    try {
      await rpc("group.member.remove", {
        groupId: ref.group.group_id,
        actorSessionId: ref.group.coordinator_session_id,
        sessionId: session.id,
        commandId: `group-remove-${Date.now()}`,
      });
      await loadGroups();
    } catch (e) { line("error", "移出工作组失败: " + e.message); }
  }

  async function onGroupEvent(frame) {
    const topic = frame && frame.topic;
    const payload = (frame && frame.payload) || {};
    if (frame && frame.groupId) bumpCollabUnread(frame.groupId, frame.eventId);
    if (topic === "collab_permission_ask" && payload.request_session_id !== state.sid && (payload.approver_session_ids || []).includes(state.sid)) {

      showPermission(payload.preview, payload.request_session_id);
      line("notice", `协作会话 ${sessionDisplayName(payload.request_session_id)} 请求权限，请审批`);
    } else if (topic === "collab_delegated" && payload.member && payload.task) {
      line("notice", `模型已派生子代理：${sessionDisplayName(payload.member.session_id)} · ${payload.task.title || "工作项"}`);
    } else if (topic === "collab_member_added" && payload.member) {
      const member = payload.member;
      if (member.session_id !== state.sid) {
        line("notice", `模型已派生子代理：${sessionDisplayName(member.session_id)}（${member.role || "worker"}）`);
      }
    } else if (topic === "collab_task_created" && payload.task) {
      const task = payload.task;
      line("notice", `模型已分派工作项：${task.title || "未命名工作项"}`);
    } else if (topic === "collab_task_updated" && payload.task && payload.task.status === "succeeded") {
      line("done", `子代理完成：${payload.task.title || "工作项"}`, true);
    } else if (topic === "collab_workspace_updated" && payload.task) {
      delete state.taskReviews[payload.task.task_id];
      const wsStatus = payload.task.workspace && payload.task.workspace.review_status;
      line("notice", `子代理变更：${workspaceStatusLabel(wsStatus)}`);
    }
    await Promise.all([loadSessions(), loadGroups()]);
  }

  function exitGroupMode() {
    // 兼容旧调用：协作不再切换成独立页面。
  }

  function initGroups() {
    $("new-group").onclick = openGroupModal;
    $("group-modal-cancel").onclick = () => $("group-modal").classList.add("hidden");
    $("group-modal-confirm").onclick = createGroup;
    $("delegate-session").onclick = openDelegateModal;
    $("delegate-cancel").onclick = () => $("delegate-modal").classList.add("hidden");
    $("delegate-confirm").onclick = delegateSession;
    $("task-cancel").onclick = () => $("task-modal").classList.add("hidden");
    $("task-confirm").onclick = createCollaborationTask;
    $("task-acceptance-add").onclick = () => addAcceptanceRow("command", "", "");
    $("mc-task-new").onclick = openTaskModal;
    $("mc-collab-refresh").onclick = loadActiveGroup;
    $("mc-collab-send").onclick = sendCollaborationMessage;
    document.querySelectorAll("#mc-task-filters [data-task-filter]").forEach((b) => {
      b.onclick = () => { state.taskFilter = b.dataset.taskFilter || "all"; renderCollaborationTasks(); };
    });
    const more = $("mc-collab-activity-more");
    if (more) more.onclick = () => { state.activityExpanded = !state.activityExpanded; renderCollaborationActivity(); };
    $("mc-collab-input").addEventListener("keydown", (e) => {
      if (e.key === "Enter" && !e.shiftKey) { e.preventDefault(); sendCollaborationMessage(); }
    });
    document.addEventListener("keydown", (e) => {
      if (e.key !== "Escape") return;
      ["group-modal", "delegate-modal", "task-modal"].forEach((id) => {
        const m = $(id);
        if (m) m.classList.add("hidden");
      });
    });
  }


  function showPermission(preview, requestSessionId) {
    state.permissionSessionId = requestSessionId || state.sid;
    $("perm-preview").textContent = preview || "";
    $("permission-bar").classList.remove("hidden");
  }
  function hidePermission() {
    $("permission-bar").classList.add("hidden");
    state.permissionSessionId = null;
  }

  function permission(ok) {
    const target = state.permissionSessionId || state.sid;
    if (state.ws && state.ws.readyState === 1) {
      state.ws.send(JSON.stringify({ type: "permission", ok, sessionId: target }));
      hidePermission();
    } else if (target === state.sid) {
      rpc("respond", { sessionId: target, actorSessionId: state.sid, permission: ok }).catch(() => {});
      hidePermission();
    } else {
      line("error", "连接已断开，跨会话权限审批需等待 WebSocket 恢复");
    }
  }

  // ── 会话管理 ──
  // 搜索关键字（"" 表示不过滤）；state.allSessions 缓存最近一次 session.list 响应
  let sessionFilter = "";
  let sessionListSeq = 0;
  async function loadSessions() {
    const seq = ++sessionListSeq;
    const sid = state.sid;
    const list = await rpc("session.list", { limit: 50, offset: 0 });
    if (seq !== sessionListSeq || state.sid !== sid) return;
    let sessions = list.sessions || [];
    // 懒落盘：刚建好还没发消息的会话尚未写盘，服务端列表里没有——
    // 保留本地注入的当前会话条目在顶部，首条消息落盘后由服务端列表接管
    if (sid && !sessions.some((s) => s.id === sid)) {
      const local = (state.allSessions || []).find((s) => s.id === sid);
      if (local && (local.messages || 0) === 0) sessions = [local].concat(sessions);
    }
    state.allSessions = sessions;
    state.sessionsTotal = (typeof list.total === "number") ? list.total : sessions.length;
    renderSessionList();
  }
  // 分页加载下一页（服务端按 mtime 倒序）：按已加载条数作 offset，按 id 去重
  async function loadMoreSessions() {
    if (state.loadingMoreSessions) return;
    state.loadingMoreSessions = true;
    renderSessionList();
    try {
      const offset = (state.allSessions || []).length;
      const list = await rpc("session.list", { limit: 50, offset });
      const more = (list.sessions || []).filter((s) => !(state.allSessions || []).some((x) => x.id === s.id));
      state.allSessions = (state.allSessions || []).concat(more);
      if (typeof list.total === "number") state.sessionsTotal = list.total;
    } catch (e) {
      line("error", "加载更多会话失败: " + e.message);
    } finally {
      state.loadingMoreSessions = false;
      renderSessionList();
    }
  }

  // 组成员必须只出现一次；没有在当前组索引中的会话才属于其他会话。
  function groupedSessionIds() {
    return new Set(Object.keys(state.groupBySession || {}));
  }
  // ── 会话组折叠状态（localStorage 持久化）──
  function loadGroupCollapsed() {
    try {
      const raw = localStorage.getItem("newbee.groupCollapsed");
      return raw ? JSON.parse(raw) : {};
    } catch (e) { return {}; }
  }
  function saveGroupCollapsed() {
    try { localStorage.setItem("newbee.groupCollapsed", JSON.stringify(state.groupCollapsed || {})); } catch (e) {}
  }
  function isGroupCollapsed(groupId) {
    return !!(state.groupCollapsed && state.groupCollapsed[groupId]);
  }
  function toggleGroupCollapse(groupId) {
    if (!state.groupCollapsed) state.groupCollapsed = loadGroupCollapsed();
    state.groupCollapsed[groupId] = !state.groupCollapsed[groupId];
    if (!state.groupCollapsed[groupId]) delete state.groupCollapsed[groupId];
    saveGroupCollapsed();
    renderSessionList();
  }
  async function deleteGroup(group) {
    const groupId = group.group_id;
    const title = group.title || group.goal || groupId;
    // 前端运行态预检：busy 则直接提示
    const busyMember = (group.members || []).find((m) => {
      const s = (state.allSessions || []).find((x) => x.id === m.session_id);
      return s && s.busy;
    });
    if (busyMember) {
      line("error", "无法删除：组内会话「" + sessionDisplayName(busyMember.session_id) + "」正在运行中");
      return;
    }
    confirmDialog("删除工作组「" + title + "」？将同时删除组内全部会话（" + (group.members || []).length + " 个），此操作不可恢复。", async () => {
      try {
        const res = await rpc("group.delete", { groupId, sessionId: state.sid });
        // 若当前会话在被删组内，切到新会话
        const deletedIds = (res && res.members_deleted) || (group.members || []).map((m) => m.session_id);
        if (deletedIds.includes(state.sid)) {
          state.sid = null;
          localStorage.removeItem("newbee.sid");
          deletedIds.forEach(clearTiming);
          await newSession();
        } else {
          deletedIds.forEach(clearTiming);
        }
        if (state.groupCollapsed && state.groupCollapsed[groupId]) { delete state.groupCollapsed[groupId]; saveGroupCollapsed(); }
        await Promise.all([loadSessions(), loadGroups()]);
        line("notice", "已删除工作组「" + title + "」");
      } catch (e) {
        const msg = e && e.message ? e.message : String(e);
        line("error", "删除工作组失败: " + msg);
      }
    }, { confirmLabel: "删除整组", confirmClass: "btn-deny" });
  }


  function renderSessionList() {
    const box = $("session-list");
    box.innerHTML = "";
    const kw = sessionFilter.trim().toLowerCase();
    const all = state.allSessions || [];
    const visible = (s) => !kw || String(s.title || "").toLowerCase().includes(kw) || String(s.id).toLowerCase().includes(kw);
    const rendered = new Set();
    const addItem = (s, child, ref) => {
      if (!visible(s) || rendered.has(s.id)) return null;
      rendered.add(s.id);
      const item = document.createElement("div");
      item.className = "session-item" + (child ? " session-child" : "") + (s.id === state.sid ? " active" : "");
      const title = String(s.title || ((s.messages || 0) === 0 ? "新会话" : s.id)).replace(/\\s+/g, " " ).trim().slice(0, 40) || "(未命名)";
      const stCls = s.busy ? "busy" : (s.running ? "online" : "offline");
      const role = ref && ref.role ? ref.role : "会话";
      const selected = state.selectedSessions && state.selectedSessions.has(s.id) ? " checked" : "";
      const cwdShort = s.cwd ? (() => { const p = String(s.cwd).replace(/\\$/, ""); return p.split("/").filter(Boolean).pop() || p; })() : null;
      item.innerHTML = `<label class="session-select"><input type="checkbox" data-select-session="${escapeHtml(s.id)}"${selected}><span class="session-select-mark"></span></label><span class="t"><span class="sess-dot ${stCls}"></span>${escapeHtml(title)}${child ? `<span class="session-role">${escapeHtml(role)}</span>` : ""}</span><span class="meta">${escapeHtml(s.when_str || "")} · ${s.messages || 0} 条${cwdShort ? " · " + ICO_FOLDER + " " + escapeHtml(cwdShort) : ""}</span>`;
      item.dataset.sid = s.id;
      item.onclick = (e) => { if (e.target.closest(".session-select") || e.target.classList.contains("menu-btn")) return; if (!state.creatingSession && state.sid !== s.id) resume(s.id); };
      const checkbox = item.querySelector("[data-select-session]");
      checkbox.onchange = () => { if (!state.selectedSessions) state.selectedSessions = new Set(); checkbox.checked ? state.selectedSessions.add(s.id) : state.selectedSessions.delete(s.id); updateSelectedSessionCount(); };
      const btn = document.createElement("button"); btn.className = "menu-btn"; btn.textContent = "⋯"; btn.title = "更多操作";
      btn.onclick = (e) => { e.stopPropagation(); openSessionMenu(e, s); };
      item.appendChild(btn);
      return item;
    };
    const findSession = (id) => all.find((s) => s.id === id) || { id, title: id, messages: 0, running: false, busy: false };
    (state.groups || []).forEach((group) => {
      const members = group.members || [];
      if (!members.length) return;
      const head = members.find((m) => m.session_id === group.coordinator_session_id) || members[0];
      const groupVisible = members.some((m) => visible(findSession(m.session_id)));
      if (!groupVisible) return;
      const collapsed = isGroupCollapsed(group.group_id);
      const groupWrap = document.createElement("div");
      groupWrap.className = "session-group" + (collapsed ? " collapsed" : "");
      groupWrap.dataset.groupId = group.group_id;
      const header = document.createElement("div");
      header.className = "session-group-header" + (group.current_session_member ? " current" : "");
      const toggleIcon = collapsed ? "▸" : "▾";
      const busyCount = members.filter((m) => { const s = findSession(m.session_id); return s.busy; }).length;
      const busyHint = busyCount ? ` <span class="session-group-busy">● ${busyCount} 运行中</span>` : "";
      const canDelete = group.coordinator_session_id === state.sid;
      const unread = collabUnreadCount(group.group_id);
      const unreadHint = unread ? `<span class="session-group-unread" title="${unread} 条未读协作动态">${unread > 99 ? "99+" : unread} 未读</span>` : "";
      header.innerHTML = `<button class="session-group-toggle" title="${collapsed ? "展开" : "收起"}">${toggleIcon}</button><span class="session-group-title">${escapeHtml(group.title || group.goal || "会话组")}</span><span class="session-group-count">${members.length} 成员</span>${busyHint}${unreadHint}${group.current_session_member ? '<span class="group-current-badge">当前</span>' : ""}<button class="session-group-delete ${canDelete ? "" : "hidden"}" title="${busyCount ? "组内有运行中会话，无法删除整组" : "删除整组及组内全部会话（不可恢复）"}">🗑 删除整组</button>`;

      header.onclick = (e) => {
        if (e.target.closest(".session-group-delete")) return;
        toggleGroupCollapse(group.group_id);
      };
      const delBtn = header.querySelector(".session-group-delete");
      if (delBtn) {
        if (busyCount) delBtn.disabled = true;
        delBtn.onclick = (e) => { e.stopPropagation(); deleteGroup(group); };
      }
      const toggleBtn = header.querySelector(".session-group-toggle");
      if (toggleBtn) toggleBtn.onclick = (e) => { e.stopPropagation(); toggleGroupCollapse(group.group_id); };
      groupWrap.appendChild(header);
      const body = document.createElement("div");
      body.className = "session-group-body";
      const headItem = addItem(findSession(head.session_id), false, head);
      if (headItem) body.appendChild(headItem);
      members.filter((m) => m.session_id !== head.session_id).forEach((m) => {
        const it = addItem(findSession(m.session_id), true, m);
        if (it) body.appendChild(it);
      });
      groupWrap.appendChild(body);
      box.appendChild(groupWrap);
    });
    const grouped = groupedSessionIds();
    const others = all.filter((s) => !grouped.has(s.id) && !rendered.has(s.id) && visible(s));
    if (others.length) { const label = document.createElement("div"); label.className = "session-group-label other"; label.textContent = "其他会话"; box.appendChild(label); others.forEach((s) => { const it = addItem(s, false, null); if (it) box.appendChild(it); }); }
    if (!box.children.length) { const empty = document.createElement("div"); empty.className = "session-empty"; empty.textContent = kw ? "没有匹配「" + kw + "」的会话" : "暂无会话"; box.appendChild(empty); }
    const cur = all.find((s) => s.id === state.sid); if (cur && typeof updateCwdLabel === "function") updateCwdLabel(cur.cwd || null);
    updateSelectedSessionCount();
    const loaded = all.length, total = state.sessionsTotal || loaded;
    if (loaded < total) { const more = document.createElement("button"); more.className = "session-more"; more.textContent = state.loadingMoreSessions ? "加载中…" : `加载更多（已加载 ${loaded}/${total}）`; more.disabled = !!state.loadingMoreSessions; more.onclick = loadMoreSessions; box.appendChild(more); }
  }
  function updateSelectedSessionCount() {
    const n = state.selectedSessions ? state.selectedSessions.size : 0;
    const label = $("selected-session-count");
    if (label) label.textContent = n ? `${n} 个已选` : "选择会话组成工作组";
    const button = $("new-group");
    if (button) button.disabled = n === 0;
  }

  // 轻量刷新会话运行状态：只更新已渲染列表项的状态点，不重建 DOM（避免闪烁）。
  // 会新增/删除的会话（如另一个 tab 新建）不处理，由 loadSessions 全量刷新负责。
  function refreshSessionStatus() {
    const box = $("session-list");
    if (!box || box.children.length === 0) return;
    rpc("session.status", {}).then((list) => {
      const all = list.status || list.sessions || [];
      const byId = {};
      all.forEach((s) => { byId[s.id] = s; });
      box.querySelectorAll(".session-item").forEach((item) => {
        const s = byId[item.dataset.sid];
        if (!s) return;
        const dot = item.querySelector(".sess-dot");
        if (!dot) return;
        const cls = s.busy ? "busy" : (s.running ? "online" : "offline");
        if (dot.className !== "sess-dot " + cls) dot.className = "sess-dot " + cls;
      });
    }).catch(() => {});
  }

  // ── 会话右键菜单（重命名 / 删除）──
  let menuSession = null;
  function openSessionMenu(e, s) {
    menuSession = s;
    const menu = $("session-menu");
    const remove = $("session-menu-remove-group");
    const ref = state.groupBySession && state.groupBySession[s.id];
    const canRemove = !!ref && ref.group.coordinator_session_id !== s.id;
    if (remove) remove.classList.toggle("hidden", !canRemove);
    menu.classList.remove("hidden");
    const rect = e.currentTarget.getBoundingClientRect();
    const mw = 150, mh = canRemove ? 112 : 80;
    let x = rect.right + 4, y = rect.top;
    if (x + mw > window.innerWidth) x = rect.left - mw - 4;
    if (y + mh > window.innerHeight) y = window.innerHeight - mh - 8;
    menu.style.left = x + "px";
    menu.style.top = y + "px";
  }

  function closeSessionMenu() {
    $("session-menu").classList.add("hidden");
    menuSession = null;
  }
  document.addEventListener("click", (e) => {
    if (!e.target.closest("#session-menu") && !e.target.classList.contains("menu-btn")) closeSessionMenu();
  });

  $("session-menu").addEventListener("click", async (e) => {
    const action = e.target.closest("[data-act]");
    const act = action && action.dataset.act;
    if (!act || !menuSession) return;
    const s = menuSession;
    closeSessionMenu();
    if (act === "rename") {
      const t = prompt("重命名会话：", s.title || s.id);
      if (t === null) return;
      const title = t.trim();
      if (!title) return;
      try {
        await rpc("session.rename", { sessionId: s.id, title });
        if (s.id === state.sid) $("session-title").textContent = title;
        await loadSessions();
      } catch (err) { line("error", "重命名失败: " + err.message); }
    } else if (act === "remove-group") {
      await removeSessionFromGroup(s);
    } else if (act === "delete") {
      const title = String(s.title || s.id).slice(0, 40);
      confirmDialog("删除会话「" + title + "」？此操作不可恢复。", async () => {
        try {
          const res = await rpc("session.delete", { sessionId: s.id });
          clearTiming(s.id);
          if (s.id === state.sid) {
            state.sid = null;
            localStorage.removeItem("newbee.sid");
            await newSession();
          }
          await loadSessions();
          // 删除时若自动移出了工作组，给一条提示
          if (res && Array.isArray(res.notices)) {
            for (const n of res.notices) line("notice", n);
          }
        } catch (err) {
          const msg = err && err.message ? err.message : String(err);
          line("error", "删除失败: " + msg);
        }
      }, { confirmLabel: "删除", confirmClass: "btn-deny" });
    }
  });

  // ── 确认弹窗 ──
  let confirmCb = null;
  function confirmDialog(text, cb, options = {}) {
    const ok = $("confirm-ok");
    const cancel = $("confirm-cancel");
    const confirmClass = ["btn-primary", "btn-allow", "btn-deny"].includes(options.confirmClass)
      ? options.confirmClass
      : "btn-primary";
    $("confirm-body").textContent = text;
    ok.textContent = options.confirmLabel || "确认";
    if (cancel) cancel.textContent = options.cancelLabel || "取消";
    ok.className = confirmClass;
    $("confirm-modal").classList.remove("hidden");
    confirmCb = cb;
  }
  $("confirm-ok").onclick = () => {
    $("confirm-modal").classList.add("hidden");
    if (confirmCb) { const cb = confirmCb; confirmCb = null; cb(); }
  };
  $("confirm-cancel").onclick = () => {
    $("confirm-modal").classList.add("hidden");
    confirmCb = null;
  };

  // ── 顶栏标题双击重命名 ──
  function attachTitleRename(el) {
    el.addEventListener("dblclick", () => {
      if (!state.sid) return;
      const cur = el.textContent;
      const inp = document.createElement("input");
      inp.className = "session-title-input";
      inp.value = cur;
      inp.maxLength = 60;
      const finish = async (commit) => {
        const v = inp.value.trim();
        const span = document.createElement("span");
        span.id = "session-title";
        span.className = "session-title";
        span.title = "双击重命名";
        span.textContent = commit && v ? v : cur;
        inp.replaceWith(span);
        attachTitleRename(span);
        if (commit && v && v !== cur) {
          try {
            await rpc("session.rename", { sessionId: state.sid, title: v });
            await loadSessions();
          } catch (err) { line("error", "重命名失败: " + err.message); }
        }
      };
      inp.addEventListener("keydown", (e) => {
        if (e.key === "Enter") { e.preventDefault(); finish(true); }
        else if (e.key === "Escape") { e.preventDefault(); finish(false); }
      });
      inp.addEventListener("blur", () => finish(true));
      el.replaceWith(inp);
      inp.focus();
      inp.select();
    });
  }
  attachTitleRename($("session-title"));
  // ── 项目工作目录选择（学习 dsh harness 左侧栏 workspace 语义）──
  // 打开目录浏览器（Miller 式一层目录 + 面包屑 + 路径编辑 + 新建子目录 + 隐藏开关），
  // 确认后修改当前会话的工作目录：保留该会话的历史、绑定和统计。
  const DIR_ICO = {
    dir: "<svg class=\"ico\" viewBox=\"0 0 24 24\" width=\"15\" height=\"15\" fill=\"none\" stroke=\"currentColor\" stroke-width=\"2\" stroke-linecap=\"round\" stroke-linejoin=\"round\"><path d=\"M22 19a2 2 0 0 1-2 2H4a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h5l2 3h9a2 2 0 0 1 2 2z\"/></svg>",
    file: "<svg class=\"ico\" viewBox=\"0 0 24 24\" width=\"13\" height=\"13\" fill=\"none\" stroke=\"currentColor\" stroke-width=\"2\" stroke-linecap=\"round\" stroke-linejoin=\"round\"><path d=\"M21 16V8a2 2 0 0 0-1-1.73l-7-4a2 2 0 0 0-2 0l-7 4A2 2 0 0 0 3 8v8a2 2 0 0 0 1 1.73l7 4a2 2 0 0 0 2 0l7-4A2 2 0 0 0 21 16z\"/><polyline points=\"3.27 6.96 12 12.01 20.73 6.96\"/><line x1=\"12\" y1=\"22.08\" x2=\"12\" y2=\"12\"/></svg>"
  };
  const dirState = { cur: null, hidden: false };
  async function openDirPicker() {
    const modal = $("dir-modal");
    modal.classList.remove("hidden");
    dirState.cur = null;
    dirState.hidden = false;
    $("dir-hidden-toggle").checked = false;
    $("dir-new-name").value = "";
    try {
      const home = await rpc("workspace.home", {});
      dirState.cur = home.home || "/";
      try {
        const listing = await rpc("workspace.listDir", { path: dirState.cur });
        renderDirPicker(listing);
      } catch (lstErr) {
        renderDirPicker();
        line("error", "浏览目录失败: " + lstErr.message);
      }
    } catch (err) {
      line("error", "读取工作目录失败: " + err.message);
      closeDirPicker();
    }
  }
  function closeDirPicker() {
    $("dir-modal").classList.add("hidden");
  }
  async function dirGo(path) {
    if (!path) return;
    try {
      const listing = await rpc("workspace.listDir", { path });
      dirState.cur = listing.path;
      dirState.hidden = $("dir-hidden-toggle").checked;
      renderDirPicker(listing);
    } catch (err) {
      line("error", "浏览目录失败: " + err.message);
    }
  }
  function dirCrumb(listing) {
    // 面包屑：从根到当前逐段可点
    const parts = String(listing.path).split(/[\\/]/).filter(Boolean);
    const home = listing.name === "~" ? listing.path : null;
    const crumbs = document.createElement("span");
    crumbs.className = "dir-crumb-space";
    const mk = (label, path) => {
      const s = document.createElement("span");
      s.className = "dir-crumb";
      s.textContent = label;
      s.onclick = () => dirGo(path);
      crumbs.appendChild(s);
    };
    if (home) mk("~", listing.path);
    else {
      let acc = "";
      parts.forEach((p, i) => {
        acc = acc ? acc + "/" + p : "/" + p;
        mk(i === 0 ? "/" : p, acc);
      });
    }
    return crumbs;
  }
  function renderDirPicker(listing) {
    const box = $("dir-entries");
    box.innerHTML = "";
    const showHidden = $("dir-hidden-toggle").checked;
    const entries = (listing && listing.entries) || [];
    const parent = listing ? listing.parent : null;
    if (parent) {
      const up = document.createElement("div");
      up.className = "dir-entry dir-up";
      up.textContent = "…";
      up.title = parent;
      up.onclick = () => dirGo(parent);
      box.appendChild(up);
    }
    // 目录优先，文件次之
    const sorted = entries.slice().sort((a, b) => {
      if (a.kind !== b.kind) return a.kind === "dir" ? -1 : 1;
      return a.name.localeCompare(b.name);
    });
    sorted.forEach((e) => {
      if (e.hidden && !showHidden) return;
      const row = document.createElement("div");
      row.className = "dir-entry" + (e.kind === "dir" ? " dir-dir" : " dir-file");
      row.innerHTML = `<span class="dir-ico">${e.kind === "dir" ? DIR_ICO.dir : DIR_ICO.file}</span><span class="dir-name">${escapeHtml(e.name)}</span>`;
      row.title = e.name;
      if (e.kind === "dir") {
        row.onclick = () => dirGo(e.path || (dirState.cur + (dirState.cur.endsWith("/") ? "" : "/") + e.name));
      } else {
        row.onclick = () => { /* 文件不可作为工作目录，仅提示 */ };
      }
      box.appendChild(row);
    });
    // 面包屑 + 路径
    if (listing) {
      const crumbs = $("dir-crumbs");
      crumbs.innerHTML = "";
      crumbs.appendChild(dirCrumb(listing));
      const pathInput = $("dir-path");
      if (pathInput) { pathInput.value = listing.path; pathInput.dataset.cur = listing.path; }
    }
  }
  // 防御式绑定：目录选择器 DOM 缺失时跳过（不拖垮整个 UI 启动块）
  if ($("dir-modal") && $("cwd-label")) {
  $("cwd-label").addEventListener("click", () => openDirPicker());
  $("dir-cancel").addEventListener("click", () => closeDirPicker());
  $("dir-confirm").addEventListener("click", async () => {
    const picked = dirState.cur;
    if (!picked) return;
    closeDirPicker();
    try {
      const updated = await rpc("session.cwd", { sessionId: state.sid, cwd: picked });
      state.cwd = updated.cwd || picked;
      updateCwdLabel(state.cwd);
      await loadSessions();
      line("notice", "当前会话工作目录已切换为 " + state.cwd);
    } catch (err) {
      line("error", "切换工作目录失败: " + err.message);
    }
  });
  $("dir-hidden-toggle").addEventListener("change", () => dirGo(dirState.cur));
  $("dir-path").addEventListener("keydown", (e) => {
    if (e.key === "Enter") {
      const v = $("dir-path").value.trim();
      if (v) dirGo(v);
    }
  });
  $("dir-new-name").addEventListener("keydown", (e) => {
    if (e.key === "Enter") $("dir-new-btn").click();
  });
  $("dir-new-btn").addEventListener("click", async () => {
    const name = $("dir-new-name").value.trim();
    const parent = dirState.cur;
    if (!name || !parent) return;
    try {
      const res = await rpc("workspace.mkdir", { path: parent, name });
      $("dir-new-name").value = "";
      await dirGo(res.path || parent);
    } catch (err) {
      line("error", "新建目录失败: " + err.message);
    }
  });
  // 点遮罩关闭
  $("dir-modal").addEventListener("mousedown", (e) => {
    if (e.target === $("dir-modal")) closeDirPicker();
  });
  }
  function updateCwdLabel(cwd) {
    const label = $("cwd-label");
    if (!label) return;
     label.innerHTML = cwd ? ICO_FOLDER + " " + escapeHtml(cwd) : "";
     label.title = cwd ? "点击修改工作目录: " + cwd : "";
  }

  // ── 侧栏折叠 ──
  function applySidebar(collapsed, persist) {
    document.getElementById("app").classList.toggle("sidebar-collapsed", collapsed);
    $("sidebar-expand").classList.toggle("hidden", !collapsed);
    const tog = $("sidebar-toggle");
    if (tog) tog.innerHTML = collapsed ? ICO_SIDEBAR_EXPAND : ICO_SIDEBAR_COLLAPSE;
    if (persist) localStorage.setItem("newbee.sidebar", collapsed ? "1" : "0");
  }
  function initSidebar() {
    applySidebar(localStorage.getItem("newbee.sidebar") === "1", false);
  }
  const sidebarToggleBtn = $("sidebar-toggle");
  if (sidebarToggleBtn) sidebarToggleBtn.onclick = () => applySidebar(true, true);
  const sidebarExpandBtn = $("sidebar-expand");
  if (sidebarExpandBtn) sidebarExpandBtn.onclick = () => applySidebar(false, true);

  // ── 会话搜索 ──
  const searchInput = $("session-search");
  if (searchInput) searchInput.addEventListener("input", (e) => {
    sessionFilter = e.target.value || "";
    renderSessionList();
  });

  // 流式渲染状态（streamAcc / currentAssistant / currentReasoning / currentTool）
  // 是全局单份、挂在「当前屏幕」上的：切会话只清 flow.innerHTML 而不重置它们，
  // 旧会话流式途中切走，新会话的 delta 会接着写进旧会话遗留的 buffer/节点，
  // 两个会话的输出混在一起。切会话前必须整体复位。
  function resetStreamState() {
    streamAcc = "";
    if (streamRaf) { cancelAnimationFrame(streamRaf); streamRaf = 0; }
    if (reasoningRaf) { cancelAnimationFrame(reasoningRaf); reasoningRaf = 0; }
    state.currentAssistant = null;
    state.currentReasoning = null;
    state.currentTool = null;
    state.currentToolCard = null;
  }

  // resume 代次守卫：快速连切会话时多个 resume() 并发交错，
  // 晚返回的旧 resume 会把上一个会话的历史/状态渲染进新会话的 flow。
  // 每次 resume 递增序号，await 返回后序号或 sid 已变则直接丢弃后续渲染。
  let resumeSeq = 0;

  async function resume(sid) {
    const seq = ++resumeSeq;
    const stale = () => seq !== resumeSeq || state.sid !== sid;
    exitGroupMode();
    if (state.sid && state.sid !== sid) discardAttachments(state.sid);

    state.sid = sid;
    groupLoadSeq++;
    // 组视图是全局的：切会话不清空 state.groups，避免点到未分组会话时侧栏组瞬间消失。
    state.activeGroupId = null;
    state.activeGroup = null;
    localStorage.setItem("newbee.sid", sid);
    loadTiming(sid);
    resetStreamState();
    // 恢复该会话的输入草稿（未发送文字刷新/切会话不丢）
    restoreDraft();
    // 权限条是 flow 之外的独立 DOM：切会话必须先收起，否则 A 的确认请求
    // 挂在 B 的界面上，用户一点就把回复发给了错误的会话
    hidePermission();
    flow.innerHTML = "";
    await rpc("session.resume", { sessionId: sid });
    if (stale()) return;
    const [hist, sessionState] = await Promise.all([
      rpc("session.history", { sessionId: sid }),
      rpc("session.state", { sessionId: sid }),
    ]);
    if (stale()) return;
    renderHistory(hist.messages || []);
    const hasUserMessage = (hist.messages || []).some(m => m && m.role === "user");
    state.hasPrompted = hasUserMessage;
    state.titleDirty = false;
    if (!hasUserMessage && flow.children.length === 0) renderWelcome();
    const curModel = sessionState.model || "";
    const curProvider = sessionState.provider || "";
    $("model-label").textContent = (curProvider && curModel) ? curProvider + "/" + curModel : (curModel || "(no model)");
    if (typeof window.__restoreEffort === "function") window.__restoreEffort(sessionState.effort);
    // 同步会话工作目录：切会话后立即反映到侧栏标签 + 底部状态栏
    updateCwdLabel(sessionState.cwd || null);
    state.cwd = sessionState.cwd || null;
      // 同步会话忙碌状态：切到正在跑任务的会话时，UI 立即反映（中断/排队按钮、busy 圆点）
    setBusy(sessionState.busy === true);
    // 等待队列重建（方案A）：刷新后按 state.queue/current 恢复排队条与执行中提示。
    state.queue = Array.isArray(sessionState.queue) ? sessionState.queue : [];
    state.queueSeq = sessionState.queue_seq || sessionState.queueSeq || sessionState.seq || 0;
    state.queueCurrent = sessionState.current || null;
    renderQueue();
    if (state.queueCurrent && state.queueCurrent.preview) line("notice", "正在执行：" + state.queueCurrent.preview);
    if (state.queue.length > 0) line("notice", "已恢复等待队列 " + state.queue.length + " 条，可单条取消");
    const recent = Array.isArray(sessionState.queue_events) ? sessionState.queue_events : (Array.isArray(sessionState.queueEvents) ? sessionState.queueEvents : []);
    recent.slice(0, 3).forEach((ev) => {
      if (!ev || !ev.type) return;
      if (ev.type === "cancelled") line("notice", "最近已取消排队：" + (ev.preview || ev.id || ""));
      else if (ev.type === "cleared" && (ev.count || 0) > 0) line("notice", "最近已清空排队 " + ev.count + " 条");
      else if (ev.type === "discarded" && (ev.count || 0) > 0) line("notice", "最近排队已丢弃 " + ev.count + " 条（内核启动失败）");
    });
    // 切回正在等待权限确认的会话时恢复确认条（permission_ask 事件在切走期间已错过）
    if (sessionState.awaiting_permission === true) showPermission("该会话正在等待权限确认（代码执行请求）");
    connect();
    loadSessions();
    loadGroups();
    const firstUser = (hist.messages || []).find(m => m && m.role === "user");
    const title = firstUser ? String(firstUser.content || "").replace(/\s+/g, " ").trim().slice(0, 48) : "";
    $("session-title").textContent = title || (hasUserMessage ? sid : "新会话");
  }

  function renderWelcome() {
    const flowEl = $("flow");
    const card = document.createElement("div");
    card.className = "welcome-card";
    card.innerHTML = `
      <div class="wc-title">🐝 欢迎使用 newbee</div>
      <div class="wc-desc">在一个持久化的 Elixir 环境中与 AI 协作编程</div>
      <div class="wc-grid">
        <div class="wc-item"><b>@文件</b><span>引用项目文件内容</span></div>
        <div class="wc-item"><b>/命令</b><span>输入 / 打开命令面板</span></div>
        <div class="wc-item"><b>Ctrl+K</b><span>快速命令</span></div>
        <div class="wc-item"><b>Ctrl+M</b><span>Mission Control 面板</span></div>
        <div class="wc-item"><b>Esc</b><span>中断 AI 执行</span></div>
          <div class="wc-item"><b>排队</b><span>AI 忙时发消息自动排队执行</span></div>
      </div>
    `;
    flowEl.appendChild(card);
  }

  // 点击“新会话”先把 UI 切到空白会话（断掉旧 ws、清屏、显示欢迎卡），
  // RPC/求值器 boot 在后台完成；不再让用户点完干等 1-3s。
  function prepareNewSessionUI(cwd, sid) {
    if (state.sid && state.sid !== sid) discardAttachments(state.sid);

    // 新建会话：不恢复任何草稿（避免旧会话残留文字串台）
    try { localStorage.removeItem("newbee.draft." + sid); } catch (e) {}
    if (reconnectTimer) { clearTimeout(reconnectTimer); reconnectTimer = 0; }
    if (state.ws) {
      state.ws.onclose = null;
      try { state.ws.close(); } catch (e) {}
      state.ws = null;
    }
    resumeSeq++; // 作废旧会话可能仍在途的 resume()，防止其晚到后覆盖新会话 UI
    state.sid = sid;
    localStorage.setItem("newbee.sid", sid);
    state.busy = false;
    state.hasPrompted = false;
    state.titleDirty = false;
    resetTimingToZero();
    resetStreamState();
    flow.innerHTML = "";
    renderWelcome();
    $("session-title").textContent = "新会话";
    // 侧栏也立即出现新会话条目（服务端 init 已写空 transcript + index，随后 loadSessions 会校正）。
    if (sid && !(state.allSessions || []).some(x => x.id === sid)) {
      state.allSessions = [{ id: sid, title: "", messages: 0, when_str: "刚刚", running: true, busy: false, cwd: cwd || null }].concat(state.allSessions || []);
      renderSessionList();
    }
    hidePermission();
    clearAttachments();
    updateCwdLabel(cwd || null);
    setBusy(false);
    input.focus();
  }

  async function newSession(cwd) {
    if (state.creatingSession) return;
    const btn = $("new-session");
    const prevSid = state.sid;
    state.creatingSession = true;
    btn.disabled = true;
    btn.textContent = "⏳ 创建中…";

    // 前端先生成 sessionId 并立即落本地 + 连 ws（socket init 会在后端幂等 ensure）。
    // 即使 HTTP 应答被热加载/网络打断，重试同一个 id 也不会造出重复会话。
    const sid = genSessionId();
    prepareNewSessionUI(cwd || null, sid);
    // 指定 cwd 时让带 cwd 的 session.create 先行，避免 ws ensure 抢先建出无 cwd 会话。
    if (!cwd) connect();

    const payload = cwd ? { sessionId: sid, cwd } : { sessionId: sid };
    try {
      let created;
      try {
        created = await rpc("session.create", payload);
      } catch (firstErr) {
        await new Promise((r) => setTimeout(r, 250));
        created = await rpc("session.create", payload);
      }
      state.cwd = created.cwd || cwd || null;
      updateCwdLabel(state.cwd);
      try {
        await resume(created.sessionId || sid);
      } catch (firstResumeErr) {
        await new Promise((r) => setTimeout(r, 250));
        await resume(created.sessionId || sid);
      }
    } catch (err) {
      if (prevSid) {
        try {
          await resume(prevSid);
          line("error", "新建会话失败: " + err.message);
        } catch (restoreErr) {
          line("error", "新建会话失败: " + err.message);
          line("error", "恢复原会话失败: " + restoreErr.message);
        }
      } else {
        line("error", "新建会话失败: " + err.message);
      }
    } finally {
      state.creatingSession = false;
      btn.disabled = false;
      btn.textContent = "+ 新会话";
    }
  }

  // 分页加载常量
  const HISTORY_PAGE = 50;
  let historyOffset = 0;   // 已跳过的消息数（从头算起）
  let allHistoryMsgs = []; // 全量历史缓存

  function renderHistory(msgs) {
    MC._replaying = true;
    replayToolCards = {}; // 新一轮回放前重置，避免跨会话/翻页串卡
    allHistoryMsgs = msgs.filter(Boolean);

    if (allHistoryMsgs.length > HISTORY_PAGE) {
      // 只渲染最近 HISTORY_PAGE 条
      const skip = allHistoryMsgs.length - HISTORY_PAGE;
      historyOffset = skip;
      renderLoadMoreBtn(skip);
      allHistoryMsgs.slice(skip).forEach(renderOneMsg);
    } else {
      allHistoryMsgs.forEach(renderOneMsg);
    }

    MC._replaying = false;
    MC.steps = [];
    renderMCSteps();
    initInfiniteHistory();
    scrollBottom(true);
  }

  // 回放专用静态工具卡（不走 toolStart/toolResult 状态机，避免顺序错乱）
  function renderReplayTool(name, title, code, result, ok) {
    const card = document.createElement("div");
    card.className = "msg msg-tool";
    const head = document.createElement("div");
    head.className = "tool-head";
    head.innerHTML = `<b>${escapeHtml(name || "tool")}</b> <span class="diffstat">${escapeHtml(title || "")}</span>`;
    const codeEl = document.createElement("pre");
    const src = (code || "").split("\n").slice(0, 12).join("\n");
    const isElixir = name === "run_elixir";
    codeEl.className = `tool-code${isElixir ? " tool-code-elixir" : ""} hidden`;
    if (isElixir) { codeEl.dataset.language = "elixir"; codeEl.innerHTML = highlightElixir(src); }
    else codeEl.textContent = src;
    const res = document.createElement("div");
    res.className = "tool-result " + (ok ? "ok" : "err") + " hidden";
    res.textContent = (result || "").split("\n").slice(0, 30).join("\n");
    card.append(head, codeEl, res);
    setBubbleTime(card, state.eventCreatedAt);
    head.style.cursor = "pointer";
    head.addEventListener("click", () => {
      const open = codeEl.classList.contains("hidden");
      codeEl.classList.toggle("hidden", !open);
      res.classList.toggle("hidden", !open);
      head.querySelector(".tool-chev")?.remove();
      if (!open) return;
      const chev = document.createElement("span");
      chev.className = "tool-chev";
      chev.textContent = " ▾";
      chev.style.color = "var(--nb-label-caption)";
      head.appendChild(chev);
    });
    flow.appendChild(card);
    return card;
  }

  // 提问卡片：text / single（单选）/ multi（多选）/ buttons（按钮组）
  function renderAskCard(question, options, kind, createdAt) {
    const d = el("msg-ask", "");
    d.classList.add("ask-card");
    const qWrap = document.createElement("div");
    qWrap.className = "ask-question";
    qWrap.textContent = question || "（问题为空）";
    d.appendChild(qWrap);

    const opts = Array.isArray(options) ? options.filter(o => o && (o.label || o.value)) : [];
    const k = kind === "single" || kind === "multi" || kind === "buttons" ? kind : (opts.length ? "buttons" : "text");

    if (opts.length && k !== "text") {
      const box = document.createElement("div");
      box.className = "ask-options " + k;

      if (k === "single" || k === "multi") {
        opts.forEach((o) => {
          const lab = document.createElement("label");
          lab.className = "ask-opt";
          const cb = document.createElement("input");
          cb.type = k === "multi" ? "checkbox" : "radio";
          cb.name = k === "multi" ? "askm_" + (createdAt || "x") : "asks_" + (createdAt || "x");
          cb.value = o.value || o.label || "";
          lab.appendChild(cb);
          const span = document.createElement("span");
          span.textContent = o.label || o.value;
          lab.appendChild(span);
          box.appendChild(lab);
        });
        const send = document.createElement("button");
        send.className = "ask-send";
        send.type = "button";
        send.textContent = k === "multi" ? "提交选择" : "确认";
        send.addEventListener("click", () => {
          const picked = Array.from(box.querySelectorAll("input:checked")).map(i => i.value);
          answerAsk(picked.length ? (k === "multi" ? picked : picked[0]) : null);
        });
        box.appendChild(send);
      } else { // buttons
        opts.forEach((o) => {
          const b = document.createElement("button");
          b.type = "button";
          b.className = "ask-btn";
          b.textContent = o.label || o.value;
          b.addEventListener("click", () => answerAsk(o.value != null ? o.value : o.label));
          box.appendChild(b);
        });
      }
      d.appendChild(box);
    } else {
      const box = document.createElement("div");
      box.className = "ask-options text";
      const inp = document.createElement("input");
      inp.type = "text";
      inp.className = "ask-input";
      inp.placeholder = "输入回答…";
      const send = document.createElement("button");
      send.type = "button";
      send.className = "ask-send";
      send.textContent = "回答";
      send.addEventListener("click", () => {
        const v = inp.value.trim();
        if (v) answerAsk(v);
      });
      inp.addEventListener("keydown", (e) => {
        if (e.key === "Enter" && inp.value.trim()) answerAsk(inp.value.trim());
      });
      box.append(inp, send);
      d.appendChild(box);
    }
    return d;
  }

  // 把提问卡片变为"已回答"态：移除输入控件，显示用户回答
  function markAskAnswered(d, answer) {
    if (!d) return;
    d.querySelectorAll(".ask-options, .ask-input, .ask-send, .ask-btn, .ask-opt").forEach(el => el.remove());
    const ans = document.createElement("div");
    ans.className = "ask-answer";
    const label = document.createElement("b");
    label.textContent = "已回答: ";
    ans.appendChild(label);
    ans.appendChild(document.createTextNode(answer == null ? "（已跳过）" : String(answer)));
    d.appendChild(ans);
  }

  // 提交回答：塞入输入框并直接发送（复用 send() 发送链路），并标记卡片已回答
  function answerAsk(value) {
    const inp = document.getElementById("input");
    const text = typeof value === "string" ? value : (value == null ? "" : JSON.stringify(value));
    if (inp) {
      inp.value = text;
      autoGrow();
    }
    document.querySelectorAll(".msg-ask").forEach((el) => markAskAnswered(el, value));
    if (text.trim()) send();
    else line("notice", "已跳过问题");
  }


  // 媒体上屏：渲染图片/音频/视频卡片（实时事件与历史回放共用）
  function renderMediaShow(p) {
    // 去重：实时 media_show 事件与历史回放（session.history 的 media 行）是两条渲染路径，
    // 同 media_id 已在流里则跳过，避免刷新/切会话后出现两张卡。
    if (p.media_id) {
      const dup = flow.querySelector(`.msg-media[data-media-id="${p.media_id}"]`);
      if (dup) return;
    }
    const d = el("msg-media", "");
    d.dataset.mediaId = p.media_id || "";
    // 修复运算符优先级：原式 `p.kind || match ? "image" : "other"` 等价于
    // `(p.kind || match) ? "image" : "other"`——任何非空 kind（含 "other"）都被
    // 判成 image 渲成破图。改为：已知 kind 直用，未知非空 kind 归 other，
    // 仅 kind 缺失时按 URL 后缀兜底。
    const urlIsImage = (p.url || "").match(/\.(png|jpe?g|gif|webp|svg)/i);
    const kind = p.kind === "image" || p.kind === "audio" || p.kind === "video" ? p.kind
      : (p.kind ? "other" : (urlIsImage ? "image" : "other"));
    const head = document.createElement("div");
    head.className = "media-head";
    head.innerHTML = `<span class="media-kind">${escapeHtml(kind)}</span><span class="media-name">${escapeHtml(p.name || "")}</span><span class="media-size">${escapeHtml(p.size ? fmtBytes(p.size) : "")}</span>`;
    d.appendChild(head);
    const body = document.createElement("div");
    body.className = "media-body";
    if (p.caption) {
      const cap = document.createElement("div");
      cap.className = "media-caption";
      cap.textContent = p.caption;
      d.appendChild(cap);
    }
    if (kind === "image") {
      const img = document.createElement("img");
      img.src = p.url + (p.url.includes("?") ? "&" : "?") + "_t=" + Date.now();
      img.alt = p.caption || p.name || "媒体";
      img.className = "nb-zoomable";
      img.addEventListener("click", (e) => { e.stopPropagation(); openLightbox(img.src, img.alt); });
      body.appendChild(img);
    } else if (kind === "audio") {
      const au = document.createElement("audio");
      au.controls = true;
      au.preload = "metadata";
      au.src = p.url + "?_t=" + Date.now();
      body.appendChild(au);
    } else if (kind === "video") {
      const vd = document.createElement("video");
      vd.controls = true;
      vd.preload = "metadata";
      vd.src = p.url + "?_t=" + Date.now();
      body.appendChild(vd);
    } else {
      const a = document.createElement("a");
      a.href = p.url;
      a.download = p.name || "file";
      a.className = "media-download";
      a.textContent = "下载 " + (p.name || "文件");
      body.appendChild(a);

    }
    d.appendChild(body);
    flow.appendChild(d);
    scrollBottom();
  }

  function fmtBytes(n) {
    if (n == null || isNaN(n)) return "";
    if (n >= 1048576) return (n/1048576).toFixed(1) + "MB";
    if (n >= 1024) return (n/1024).toFixed(1) + "KB";
    return n + "B";
  }


  function renderOneMsg(m) {
    state.eventCreatedAt = m.created_at || null;
    if (m.role === "user") {
      if (m.images && m.images.length) renderUserLine(m.content, m.images);
      else line("user", m.content);
    } else if (m.role === "done") {
      const doneCard = line("done", m.content, true);
      if (replayPendingUsage) { attachUsageToBubble(doneCard, replayPendingUsage); replayPendingUsage = null; }
      // 回放时若 done 携带下一步选项，同样渲染选择卡片
      try {
        const ns = m.next_steps || m.nextSteps;
        if (ns && (ns.question || (ns.options && ns.options.length))) {
          renderAskCard(ns.question || "下一步做什么？", ns.options || [], ns.kind || "single", m.created_at || null);
        }
      } catch (e) {}
    } else if (m.role === "assistant") {
      if (m.reasoning) {
        const d = el("msg-reasoning", "");
        d.dataset.thinkText = m.reasoning;
        d.dataset.open = "0";
        renderReasoningBody(d);
      }
      if (m.content) {
        const d = addAssistantChrome(el("msg-assistant", m.content, true));
        bindCopyButtons(d);
        if (replayPendingUsage && !(m.toolCalls || []).length) {
          attachUsageToBubble(d, replayPendingUsage);
          replayPendingUsage = null;
        }
      }
      (m.toolCalls || []).forEach((tc) => {
        const card = renderReplayTool(tc.name, tc.title, tc.code, "", true);
        if (replayPendingUsage) attachToolUsageToCard(card, replayPendingUsage);
        if (tc.id) replayToolCards[tc.id] = card;
      });
      if ((m.toolCalls || []).length && replayPendingUsage) replayPendingUsage = null;
    } else if (m.role === "ask") {
      const c = m.content || {};
      renderAskCard(c.question || "", c.options || [], c.kind || "text", c.created_at || null);
    } else if (m.role === "media") {
      renderMediaShow(m.content || {});
    } else if (m.role === "usage") {
      if (m.usage) {
        replayPendingUsage = typeof m.usage === "string" ? JSON.parse(m.usage) : m.usage;
        const cards = Object.values(replayToolCards);
        if (cards.length) {
          cards.forEach((card) => attachToolUsageToCard(card, replayPendingUsage));
          replayPendingUsage = null;
        }
      }
    } else if (m.role === "tool") {
      const inner = unwrapToolContent(m.content || "");
      const ok = !isToolError(m.content || "");
      const host = (m.toolCallId && replayToolCards[m.toolCallId]) || null;
      if (host) {
        const resEl = host.querySelector(".tool-result");
        if (resEl) {
          resEl.classList.remove("ok", "err");
          resEl.classList.add(ok ? "ok" : "err");
          resEl.textContent = inner.split("\n").slice(0, 30).join("\n");
        }
        addToolStatus(host, ok);
        addToolCopyButton(host, inner, host.querySelector(".tool-code")?.textContent || "");
        delete replayToolCards[m.toolCallId];
      } else {
        const _c = renderReplayTool("tool", "", "", inner, ok);
        addToolStatus(_c, ok);
        addToolCopyButton(_c, inner, "");
      }
    } else if (m.role === "archive") {
      const d = el("msg-archive", "");
      const segs = m.segments || [];
      const head = document.createElement("div");
      head.className = "archive-head";
      head.textContent = "⌸ " + (m.content || "已压缩的早期对话");
      d.appendChild(head);
      if (segs.length) {
        const list = document.createElement("div");
        list.className = "archive-segs";
        segs.forEach((seg) => {
          const row = document.createElement("div");
          row.className = "archive-seg";
          row.textContent = `[${seg.id}] ${seg.messages} 条` + (seg.intent ? ` · ${seg.intent}` : "");
          list.appendChild(row);
        });
        d.appendChild(list);
      }
    }
  }

  function renderLoadMoreBtn(remaining) {
    const flowEl = $("flow");
    const btn = document.createElement("div");
    btn.className = "load-more-btn";
    btn.id = "load-more";
    btn.innerHTML = `<button class="btn-ghost" style="margin:8px auto;display:block;font-size:12px">↑ 加载更早 ${remaining} 条消息</button>`;
    btn.addEventListener("click", () => loadEarlier());
    flowEl.insertBefore(btn, flowEl.firstChild);
  }

  let loadingEarlier = false; // 防重入
  async function loadEarlier() {
    if (loadingEarlier || historyOffset <= 0) return;
    loadingEarlier = true;
    try {
      const flowEl = $("flow");
      const transcriptEl = $("transcript");
      const oldHeight = transcriptEl.scrollHeight;

      // 先摘走旧按钮（避免被当旧内容一起摘走）
      const oldBtn = $("load-more");
      if (oldBtn) oldBtn.remove();

      // 把当前已显示的内容整体摘下来（顺序保持）
      const oldNodes = Array.from(flowEl.childNodes);
      flowEl.innerHTML = ""; // 清空 flow 本身保留

      const newSkip = Math.max(0, historyOffset - HISTORY_PAGE);
      const start = newSkip;
      const end = historyOffset;
      historyOffset = newSkip;

      // 更早消息渲染进空 flow：appendChild 天然从头到尾顺序正确
      MC._replaying = true;
      allHistoryMsgs.slice(start, end).forEach((m) => { renderOneMsg(m); });
      MC._replaying = false;

      // 把原有内容整体挂回末尾（更早的在顶部，旧内容在下方）
      oldNodes.forEach((n) => flowEl.appendChild(n));

      // 补偿高度差，视觉上当前内容不动
      requestAnimationFrame(() => {
        transcriptEl.scrollTop = transcriptEl.scrollHeight - oldHeight;
      });

      // 仍有更早消息则在最前放按钮
      if (historyOffset > 0) renderLoadMoreBtn(historyOffset);
    } finally {
      loadingEarlier = false;
    }
  }

  // 触顶自动加载（窗口式渐进：向上滚到顶自动加载更早对话）
  function initInfiniteHistory() {
    const t = $("transcript");
    if (!t || t.dataset.infinityBound) return;
    t.dataset.infinityBound = "1";
    t.addEventListener("scroll", () => {
      if (historyOffset <= 0 || loadingEarlier || state.busy) return;
      if (t.scrollTop <= 40) loadEarlier();
    });
  }

  // ── 文件附件（上传 / 粘贴 / 预览）──
  const MAX_ATTACH = 8;
  const MAX_FILE = 20 * 1024 * 1024;
  const MAX_IMAGE = 8 * 1024 * 1024;

  function fileAsDataUrl(file) {
    return new Promise((resolve, reject) => {
      const reader = new FileReader();
      reader.onload = () => resolve(reader.result);
      reader.onerror = () => reject(new Error("读取图片预览失败"));
      reader.readAsDataURL(file);
    });
  }

  async function uploadAttachment(file, sid) {
    const headers = { "content-type": file.type || "application/octet-stream" };
    if (state.token) headers.authorization = "Bearer " + state.token;
    const url = `/api/upload/${encodeURIComponent(sid)}?name=${encodeURIComponent(file.name || "file")}`;
    const res = await fetch(url, { method: "POST", headers, body: file });
    if (res.status === 401) {
      setToken(null);
      showLogin();
      throw new Error("未登录或会话已过期");
    }
    let body = null;
    try { body = await res.json(); } catch (e) { /* handled below */ }
    if (!res.ok || !body || !body.ok) {
      throw new Error(body && body.error ? body.error.message : `上传失败 (HTTP ${res.status})`);
    }
    return body.ok;
  }

  async function deleteAttachment(a, sid = state.sid) {
    if (!a || !a.id || !sid) return;
    const headers = {};
    if (state.token) headers.authorization = "Bearer " + state.token;
    await fetch(`/api/upload/${encodeURIComponent(sid)}/${encodeURIComponent(a.id)}`, {
      method: "DELETE", headers,
    });
  }

  async function addAttachment(file) {
    if (state.busy) { line("notice", "忙碌中，稍后再添加文件"); return; }
    if (!state.sid || !file) return;
    if (file.size === 0) { line("notice", "不能上传空文件：" + (file.name || "file")); return; }
    if (file.size > MAX_FILE) { line("notice", "文件过大（>20 MiB）：" + file.name); return; }
    if (state.attachments.length + state.uploading >= MAX_ATTACH) {
      line("notice", "每条消息最多 " + MAX_ATTACH + " 个附件"); return;
    }

    const sid = state.sid;
    state.uploading += 1;
    renderAttachPreview();
    try {
      const uploaded = await uploadAttachment(file, sid);
      if (state.sid !== sid) {
        await deleteAttachment(uploaded, sid).catch(() => {});
        return;
      }
      const isImage = !!uploaded.image && file.size <= MAX_IMAGE;
      const dataUrl = isImage ? await fileAsDataUrl(file) : null;
      state.attachments.push({
        id: uploaded.id,
        name: uploaded.name,
        type: uploaded.content_type,
        size: uploaded.size,
        isImage,
        dataUrl,
      });
    } catch (e) {
      line("error", "上传失败：" + e.message);
    } finally {
      state.uploading -= 1;
      renderAttachPreview();
    }
  }

  function renderAttachPreview() {
    const box = $("attach-preview");
    if (!box) return;
    if (state.attachments.length === 0 && state.uploading === 0) {
      box.classList.add("hidden"); box.innerHTML = ""; return;
    }
    box.classList.remove("hidden");
    box.innerHTML = "";
    state.attachments.forEach((a, i) => {
      const item = document.createElement("div");
      item.className = "attach-item";
      if (a.isImage && a.dataUrl) {
        const img = document.createElement("img");
        img.src = a.dataUrl; img.alt = a.name;
        item.appendChild(img);
      } else {
        const icon = document.createElement("div");
        icon.className = "attach-file-icon";
        icon.textContent = (a.name.split(".").pop() || "FILE").slice(0, 5).toUpperCase();
        item.appendChild(icon);
      }
      const cap = document.createElement("span");
      cap.className = "attach-name"; cap.textContent = a.name;
      cap.title = `${a.name} (${fmtBytes(a.size)})`;
      const rm = document.createElement("button");
      rm.className = "attach-remove"; rm.textContent = "×"; rm.title = "移除";
      rm.onclick = () => {
        const removed = state.attachments.splice(i, 1)[0];
        renderAttachPreview();
        deleteAttachment(removed).catch(() => {});
      };
      item.appendChild(cap); item.appendChild(rm);
      box.appendChild(item);
    });
    if (state.uploading > 0) {
      const pending = document.createElement("div");
      pending.className = "attach-item attach-uploading";
      pending.textContent = `正在上传 ${state.uploading} 个文件`;
      box.appendChild(pending);
    }
  }

  function clearAttachments() {
    state.attachments = [];
    renderAttachPreview();
  }


  function discardAttachments(sid = state.sid) {
    const pending = state.attachments.slice();
    clearAttachments();
    pending.forEach(a => deleteAttachment(a, sid).catch(() => {}));
  }

  // 用户行回显：文本 + 图片缩略图 + 普通文件
  function renderUserLine(text, attachments) {
    const d = el("msg-user", "");
    if (text) {
      const span = document.createElement("div");
      span.textContent = text;
      d.appendChild(span);
    }
    const images = (attachments || []).filter(a => a.isImage && a.dataUrl);
    if (images.length) {
      const wrap = document.createElement("div");
      wrap.className = "msg-user-images";
      images.forEach(a => {
        const img = document.createElement("img");
        img.src = a.dataUrl;
        img.alt = a.name;
        img.className = "nb-zoomable";
        img.addEventListener("click", (e) => { e.stopPropagation(); openLightbox(img.src, img.alt || "图片"); });
        wrap.appendChild(img);
      });
      d.appendChild(wrap);
    }
    const files = (attachments || []).filter(a => !a.isImage);
    if (files.length) {
      const wrap = document.createElement("div");
      wrap.className = "msg-user-files";
      files.forEach(a => {
        const chip = document.createElement("span");
        chip.className = "msg-user-file";
        chip.textContent = `${a.name} · ${fmtBytes(a.size)}`;
        wrap.appendChild(chip);
      });
      d.appendChild(wrap);
    }
    if (text) {
      const cBtn = document.createElement("button");
      cBtn.type = "button";
      cBtn.className = "msg-copy";
      cBtn.title = "复制消息";
      cBtn.textContent = "\u29C9";
      cBtn.onclick = () => { navigator.clipboard.writeText(text).then(() => { cBtn.textContent = "已复制"; setTimeout(() => cBtn.textContent = "\u29C9", 1500); }); };
      d.appendChild(cBtn);
    }
    scrollBottom();
  }

  // 首条提示词即时顶栏取题；服务端 session.list 也会用首条 user 消息自动取题。
  function applyPromptTitle(text, attachments) {
    const raw = String(text || "") || (attachments && attachments.length ? `[附件] ${attachments[0].name}` : "");
    const title = raw.replace(/\s+/g, " ").trim().slice(0, 48);
    const el = $("session-title");
    if (!title || !state.sid) return;
    if (el.textContent === "新会话" || el.textContent === state.sid) el.textContent = title;

    const sess = (state.allSessions || []).find(x => x.id === state.sid);
    if (sess && (!sess.title || sess.title === sess.id || sess.title === "新会话")) {
      sess.title = title;
      renderSessionList();
    }
  }

  // 等待队列（方案A）：前端生成 queueId，后端按 id 追踪，刷新后按 session.state 重建。
  function genQueueId() {
    return "q" + Date.now().toString(36) + Math.random().toString(36).slice(2, 8);
  }
  function queueKindLabel(kind) {
    if (kind === "images") return "图片";
    if (kind === "collab_task") return "协作任务";
    if (kind === "collab_result") return "协作结果";
    if (kind === "collab_message") return "协作消息";
    return "文本";
  }
  function renderQueue() {
    const bar = $("queue-bar");
    const list = $("queue-list");
    const count = $("queue-count");
    const cur = $("queue-current");
    if (!bar || !list) return;
    const q = Array.isArray(state.queue) ? state.queue : [];
    if (q.length === 0) { bar.classList.add("hidden"); list.innerHTML = ""; if (count) count.textContent = ""; if (cur) cur.textContent = ""; return; }
    bar.classList.remove("hidden");
    if (count) count.textContent = "等待队列 " + q.length + " 条";
    if (cur) cur.textContent = state.queueCurrent && state.queueCurrent.preview ? ("执行中: " + state.queueCurrent.preview) : "";
    q.forEach((item, idx) => {
      const row = document.createElement("div");
      row.className = "queue-item";
      row.dataset.queueId = item.id || "";
      const pos = document.createElement("span");
      pos.className = "queue-pos";
      pos.textContent = String(idx + 1);
      const prev = document.createElement("span");
      prev.className = "queue-preview";
      prev.textContent = item.preview || item.text || "(空)";
      prev.title = (item.text || item.preview || "");
      const kind = document.createElement("span");
      kind.className = "queue-kind";
      kind.textContent = queueKindLabel(item.kind);
      const btn = document.createElement("button");
      btn.className = "btn-ghost queue-cancel";
      btn.textContent = "取消";
      btn.title = "取消这条排队";
      btn.onclick = () => cancelQueueItem(item.id, prev.textContent);
      row.append(pos, prev, kind, btn);
      list.appendChild(row);
    });
  }
  async function cancelQueueItem(queueId, preview) {
    if (!queueId || !state.sid) return;
    const sid = state.sid;
    state.queue = (state.queue || []).filter((it) => it && it.id !== queueId);
    renderQueue();
    try {
      if (state.ws && state.ws.readyState === 1) {
        state.ws.send(JSON.stringify({ type: "cancelQueued", queueId }));
      }
      await rpc("session.cancelQueued", { sessionId: sid, queueId });
    } catch (e) {
      line("error", "取消排队失败: " + e.message);
      try {
        const st = await rpc("session.state", { sessionId: sid });
        if (sid === state.sid) { state.queue = st.queue || []; state.queueSeq = st.queue_seq || st.seq || 0; state.queueCurrent = st.current || null; renderQueue(); }
      } catch (_) {}
    }
  }
  async function clearQueueOnly() {
    if (!state.sid) return;
    const sid = state.sid;
    try {
      if (state.ws && state.ws.readyState === 1) state.ws.send(JSON.stringify({ type: "clearQueue" }));
      await rpc("session.clearQueue", { sessionId: sid });
    } catch (e) {
      line("error", "清空队列失败: " + e.message);
    }
  }
  // 发送
  async function send() {
    state.eventCreatedAt = new Date().toISOString();
    const text = input.value.trim();
    if (text === "/new" || text.startsWith("/new ")) {
      input.value = "";
      autoGrow();
      saveDraft("");
      if (typeof newSession === "function") {
        try { await newSession(); } catch (e) { line("error", e.message); }
      }
      return;
    }
    const attachments = state.attachments.slice();
    if (state.uploading > 0) { line("notice", "请等待文件上传完成"); return; }
    if ((!text && attachments.length === 0) || !state.sid) return;
    const queueId = genQueueId();
    const wasBusy = state.busy === true;
    if (wasBusy) {
      line("notice", "已加入队列：当前任务完成后自动执行");
      const prev = text || (attachments.length > 0 ? ("[图片 x" + attachments.length + "]") : "");
      state.queue = [...(state.queue || []), { id: queueId, kind: attachments.length > 0 ? "images" : "text", preview: prev.slice(0, 80), text: text, createdAt: state.eventCreatedAt, origin: "user" }];
      renderQueue();
    } else if (text) {
      lastUserPrompt = text;
    }
    input.value = "";
    autoGrow();
    saveDraft("");
    scrollBottom(true);
    renderUserLine(text, attachments);
    if (!state.hasPrompted) {
      state.hasPrompted = true;
      state.titleDirty = true;
      applyPromptTitle(text, attachments);
    }
    state.busy = true; setBusy(true);
    // TTFT 锚点：从请求发起计时（排队项不置位，避免排队等待计入首 token）
    if (!wasBusy) { state.timing.llmStart = Date.now(); state.timing.ftRecorded = false; }
    resetTurnUsage();
    try {
      if (attachments.length > 0) {
        await rpc("session.promptAttachments", {
          sessionId: state.sid,
          uploadIds: attachments.map(a => a.id),
          text,
          queueId,
        });
      } else if (state.ws && state.ws.readyState === 1) {
        state.ws.send(JSON.stringify({ type: "prompt", text, queueId }));
      } else {
        await rpc("session.prompt", { sessionId: state.sid, text, queueId });
      }
      clearAttachments();
    } catch (e) {
      line("error", e.message);
      state.queue = (state.queue || []).filter((it) => it && it.id !== queueId);
      renderQueue();
      state.busy = false; setBusy(false);
    }
  }
  function interrupt() {
    if (state.ws && state.ws.readyState === 1) {
      state.ws.send(JSON.stringify({ type: "interrupt" }));
    } else if (state.sid) {
      rpc("session.cancel", { sessionId: state.sid }).catch(() => {});
    }
  }

  // ── 模型 ──
  async function openModels() {
    const data = await rpc("llm.models", { sessionId: state.sid });
    const providers = data.providers || [];
    const current = data.current || {};
    const curProvider = current.provider || "";
    const curModel = current.model || "";

    const pbox = $("model-providers");
    const mbox = $("model-options");
    pbox.innerHTML = "";
    mbox.innerHTML = "";

    // 待确认的选择（确定按钮点击时生效）
    let pending = { provider: curProvider, model: curModel };
    let currentProvider = curProvider;
    let providerData = new Map(); // name -> provider 数据

    providers.forEach((p) => {
      if (!p || !p.name || !(p.models || []).length) return;
      const po = document.createElement("div");
      po.className = "model-provider" + (p.name === curProvider ? " current" : "");
      po.textContent = p.name;
      po.onclick = () => {
        pbox.querySelectorAll(".model-provider").forEach((x) => x.classList.remove("current"));
        po.classList.add("current");
        currentProvider = p.name;
        providerData.set(p.name, p);
        renderModels(p);
      };
      pbox.appendChild(po);
    });

    // 上下文窗口显示文案：单模型覆盖 > provider 级默认 > auto（自动探测）
    const ctxLabel = (p, m) => {
      const ov = (p.contextWindows || {})[m];
      if (ov) return fmtContext(ov);
      if (p.contextWindow) return fmtContext(p.contextWindow);
      return "auto";
    };

    function renderModels(p, filter) {
      mbox.innerHTML = "";
      const q = (filter == null ? "" : String(filter)).trim().toLowerCase();
      const list = (p.models || []).filter((m) => {
        if (!q) return true;
        return String(m).toLowerCase().includes(q);
      });
      if (!list.length) {
        const empty = document.createElement("div");
        empty.className = "model-empty";
        empty.textContent = q ? ("没有匹配 \"" + q + "\" 的模型") : "暂无可用模型";
        mbox.appendChild(empty);
        return;
      }
      list.forEach((m) => {
        const o = document.createElement("div");
        const isSel = (p.name === pending.provider) && (m === pending.model);
        o.className = "model-opt" + (isSel ? " current" : "");
        const nameEl = document.createElement("span");
        nameEl.className = "model-name";
        nameEl.textContent = m;
        o.appendChild(nameEl);
        // 上下文窗口 chip：点击就地编辑（不触发选中）；覆盖过的高亮
        const ov = (p.contextWindows || {})[m];
        const chip = document.createElement("button");
        chip.type = "button";
        chip.className = "ctx-chip" + (ov ? " set" : "");
        chip.title = "上下文窗口：" + ctxLabel(p, m) + "（点击修改，实时生效）";
        chip.textContent = "⬡ " + ctxLabel(p, m);
        chip.onclick = (e) => { e.stopPropagation(); openCtxEditor(p, m, o); };
        o.appendChild(chip);
        o.onclick = () => {
          mbox.querySelectorAll(".model-opt").forEach((x) => x.classList.remove("current"));
          o.classList.add("current");
          pending = { provider: p.name, model: m };
        };
        mbox.appendChild(o);
      });
    }

    // 行内上下文编辑器：输入 128000 / 128K / 1M；Enter 保存，Esc 取消；留空/「自动」= 清除覆盖
    function openCtxEditor(p, m, rowEl) {
      mbox.querySelectorAll(".ctx-editor").forEach((x) => x.remove());
      const ed = document.createElement("div");
      ed.className = "ctx-editor";
      const inp = document.createElement("input");
      inp.type = "text";
      inp.spellcheck = false;
      inp.placeholder = "如 128000 / 128K / 1M，留空=自动";
      const cur = (p.contextWindows || {})[m];
      if (cur) inp.value = String(cur);
      const okBtn = document.createElement("button");
      okBtn.type = "button"; okBtn.className = "ctx-save"; okBtn.textContent = "保存";
      const autoBtn = document.createElement("button");
      autoBtn.type = "button"; autoBtn.className = "ctx-auto"; autoBtn.textContent = "自动";
      ed.appendChild(inp); ed.appendChild(okBtn); ed.appendChild(autoBtn);
      rowEl.after(ed);
      inp.focus(); inp.select();

      const close = () => ed.remove();
      const save = async (raw) => {
        const val = String(raw == null ? "" : raw).trim();
        const n = parseCtx(val);
        if (val !== "" && !n) { line("error", "上下文大小无效: " + val); return; }
        try {
          await rpc("llm.setContextWindow", { sessionId: state.sid, provider: p.name, model: m, contextWindow: n });
        } catch (e) { line("error", "设置上下文失败: " + e.message); return; }
        p.contextWindows = p.contextWindows || {};
        if (n) p.contextWindows[m] = n; else delete p.contextWindows[m];
        // 就地更新 chip（不重建列表，保留滚动位置与选中态）
        const chip = rowEl.querySelector(".ctx-chip");
        if (chip) {
          chip.textContent = "⬡ " + ctxLabel(p, m);
          chip.classList.toggle("set", !!n);
          chip.title = "上下文窗口：" + ctxLabel(p, m) + "（点击修改，实时生效）";
        }
        close();
        line("notice", `${p.name}/${m} 上下文窗口 ${n ? "→ " + fmtContext(n) : "恢复自动"}（实时生效）`);
      };
      okBtn.onclick = () => save(inp.value);
      autoBtn.onclick = () => save("");
      inp.onkeydown = (e) => {
        if (e.key === "Enter") { e.preventDefault(); save(inp.value); }
        if (e.key === "Escape") { e.preventDefault(); close(); }
      };
    }

    // ── 模型模糊搜索：本地过滤，不请求后端 ──
    const searchInput = $("model-search");
    if (searchInput) {
      searchInput.value = "";
      // 输入即过滤当前厂商的模型列表
      searchInput.oninput = () => {
        const p = providerData.get(currentProvider)
          || providers.find((x) => x && x.name === currentProvider);
        if (p) renderModels(p, searchInput.value);
      };
      // Esc 清空并失焦；Enter 选中第一个高亮
      searchInput.onkeydown = (e) => {
        if (e.key === "Escape") { searchInput.value = ""; searchInput.blur(); const p = providerData.get(currentProvider) || providers.find((x) => x && x.name === currentProvider); if (p) renderModels(p); }
        if (e.key === "Enter") { const first = mbox.querySelector(".model-opt"); if (first) first.click(); }
      };
    }

    const def = providers.find((p) => p.name === curProvider) || providers[0];
    if (def) renderModels(def);

    // 确定：应用待选
    $("model-confirm").onclick = async () => {
      if (!pending.provider || !pending.model) return;
      try {
        await rpc("session.selectModel", { sessionId: state.sid, provider: pending.provider, model: pending.model });
        $("model-label").textContent = pending.provider + "/" + pending.model;
        $("model-modal").classList.add("hidden");
      } catch (e) {
        line("error", "切模型失败: " + e.message);
      }
    };

    // 刷新：只对当前选中的厂商重新拉取模型列表
    const refreshBtn = $("model-refresh");
    if (refreshBtn) {
      refreshBtn.onclick = async () => {
        if (!currentProvider) return;
        refreshBtn.textContent = "↻ 刷新中…";
        refreshBtn.disabled = true;
        try {
          const r = await rpc("llm.providerModels", { sessionId: state.sid, provider: currentProvider, refresh: true });
          // 优先复用目录里的 provider 对象（保留 contextWindows/contextWindow 覆盖数据）
          const updated = providerData.get(currentProvider)
            || providers.find((x) => x && x.name === currentProvider)
            || { name: currentProvider };
          updated.models = r.models || [];
          providerData.set(currentProvider, updated);
          const p = providerData.get(currentProvider);
          renderModels(p);
          if (!(r.models || []).length) line("warn", currentProvider + " 暂无可用模型");
        } catch (e) {
          line("error", "刷新模型失败: " + e.message);
        } finally {
          refreshBtn.textContent = "🔄 刷新";
          refreshBtn.disabled = false;
        }
      };
    }


    $("model-modal").classList.remove("hidden");
  }



  // ── utils ──
  function setBusy(b) {
    $("status-dot").className = `dot ${b ? "busy" : "idle"}`;
    $("interrupt").classList.toggle("hidden", !b);
    const sendBtn = $("send");
    sendBtn.disabled = false;
    // 图标按钮：不动 innerHTML，只用 class/title 表达状态
    sendBtn.classList.toggle("queuing", b);
    sendBtn.title = b ? "加入队列：当前任务完成后自动执行" : "发送";
    sendBtn.setAttribute("aria-label", sendBtn.title);
    if (b) {
      showTurnStatus();
      // 修复抢焦点：AI 起止不再强制 switchMCTab。用户停留在哪个 tab 就留在哪个 tab，
      // 新步骤只亮徽标（updateMCBadges），把控制权还给用户。
      if (MC.open && MC.tab !== "steps") { MC.stepsUnread++; updateMCBadges(); }
    } else {
      clearTurnStatus();
      // 完成时静默刷新文件列表，不切换 tab；若用户不在文件 tab则亮徽标。
      if (MC.open) {
        refreshMCFiles();
        if (MC.tab !== "files") { MC.filesUnread++; updateMCBadges(); }
      }
    }
  }
  // dsh turn 状态行：shimmer 文字，turn 进行中显示
  let turnStatusEl = null;
  function showTurnStatus() {
    if (turnStatusEl) return;
    turnStatusEl = document.createElement("div");
    turnStatusEl.className = "msg turn-status";
    turnStatusEl.textContent = "正在思考…";
    flow.appendChild(turnStatusEl);
    scrollBottom();
  }
  function clearTurnStatus() {
    if (turnStatusEl) { turnStatusEl.remove(); turnStatusEl = null; }
  }
  function fmtContext(n) {
    if (!Number.isFinite(n) || n <= 0) return "-";
    if (n < 1000) return String(Math.round(n));
    if (n < 1000000) return (n / 1000).toFixed(2).replace(/\.?0+$/, "") + "K";
    return (n / 1000000).toFixed(2).replace(/\.?0+$/, "") + "M";
  }

  // 解析用户输入的上下文大小："128000" / "128K" / "1.5M"（K/M 按 1000 计，与 fmtContext 显示互逆）
  // 返回正整数或 null（无效输入）；空串 → null（调用方按「恢复自动」处理）
  function parseCtx(s) {
    const m = /^\s*(\d+(?:\.\d+)?)\s*([kKmM])?\s*$/.exec(String(s || ""));
    if (!m) return null;
    let n = parseFloat(m[1]);
    const u = (m[2] || "").toUpperCase();
    if (u === "K") n *= 1000;
    if (u === "M") n *= 1000000;
    n = Math.round(n);
    return n > 0 ? n : null;
  }

  function setUsage(u) {
    if (!u) return;
    if (u.context_tokens > 0 && u.context_window > 0) {
      $("usage-label").textContent = `${fmtContext(u.context_tokens)}/${fmtContext(u.context_window)}`;
    }
  }
  function usageFields(u) {
    if (!u || typeof u !== "object") return null;
    const prompt = u.prompt_tokens ?? u.input_tokens ?? 0;
    const completion = u.completion_tokens ?? u.output_tokens ?? 0;
    const total = u.total_tokens ?? (prompt + completion);
    // 缓存字段缺失 = 网关未回报（如 guoyu 未命中时省略 prompt_tokens_details），
    // 与“真 0”（deepseek 显式回 0）区分：缺失 → cached=null → 显示“未统计”。
    // responses API 风格：input_tokens_details.cached_tokens / output_tokens_details.reasoning_tokens
    const cachedRaw = u.cache_read_tokens ?? u.cached_tokens ?? u.cache_read_input_tokens
      ?? (u.prompt_tokens_details && (u.prompt_tokens_details.cached_tokens ?? u.prompt_tokens_details.cache_read_tokens))
      ?? (u.input_tokens_details && u.input_tokens_details.cached_tokens);
    const hasCacheInfo = cachedRaw != null;
    const cached = hasCacheInfo ? cachedRaw : null;
    const hit = (prompt > 0 && hasCacheInfo) ? (cached / prompt) * 100 : null;
    const model = u.model || u.model_name || "";
    return { prompt, completion, total, cached, hit, model };
  }
  function fmtTokShort(n) {
    if (n == null || isNaN(n)) return "0";
    if (n < 1000) return String(n);
    if (n < 1e6) return (Math.round(n/100)/10).toFixed(1).replace(/\.0$/, "") + "K";
    return (Math.round(n/1e5)/10).toFixed(1).replace(/\.0$/, "") + "M";
  }
  function bubbleUsageLabel(f) {
    const pct = f.hit == null ? "未统计" : ((f.hit > 99.995 ? "100.00" : f.hit.toFixed(2)) + "%");
    const cacheTxt = f.cached == null ? "-" : fmtTokShort(f.cached);
    return `输入 ${fmtTokShort(f.prompt)} · 输出 ${fmtTokShort(f.completion)} · 缓存 ${cacheTxt} (${pct})`;
  }
  function ensureUsageBar(bubble) {
    if (!bubble) return null;
    let bar = bubble.querySelector(":scope > .msg-usage");
    if (bar) return bar;
    bar = document.createElement("div");
    bar.className = "msg-usage";
    bubble.appendChild(bar);
    return bar;
  }
  function attachUsageToBubble(bubble, u) {
    const f = usageFields(u);
    if (!bubble || !f) return;
    const bar = ensureUsageBar(bubble);
    const label = bubbleUsageLabel(f);
    bar.innerHTML = "";
    const left = document.createElement("span");
    left.className = "msg-usage-stats";
    left.textContent = label;
    left.title = `prompt=${f.prompt} completion=${f.completion} total=${f.total} cached=${f.cached} hit=${f.hit == null ? "-" : f.hit.toFixed(2)+"%"}`;
    bar.appendChild(left);
    setBubbleTime(bubble, bubble.dataset.createdAt);
    const tm = bubble.querySelector(":scope > .msg-time");
    if (tm) { tm.classList.add("msg-time-inline"); bar.appendChild(tm); }
    bubble.dataset.hasUsage = "1";
  }
  function handleBubbleUsage(u) {
    if (!u) return;
    try {
      if (!state.turnUsage) state.turnUsage = { prompt: 0, completion: 0, cached: 0, count: 0, model: "" };
      const f = usageFields(u);
      if (f) {
        state.turnUsage.prompt += f.prompt || 0;
        state.turnUsage.completion += f.completion || 0;
        state.turnUsage.cached += f.cached || 0;
        state.turnUsage.count += 1;
        if (f.cached == null) state.turnUsage.hasUnknown = true;
        if (f.model) state.turnUsage.model = f.model;
        state.turnUsageDetails.push({ ...f, raw: u });
        state.lastLLMUsage = u;
        state.lastUsageSeq = (state.lastUsageSeq || 0) + 1;
      }
    } catch (e) {}
    let target = state.currentAssistant;
    if (!target || !document.body.contains(target)) {
      const assistants = flow.querySelectorAll(".msg-assistant.msg-boxed");
      for (let i = assistants.length - 1; i >= 0; i--) {
        if (assistants[i].dataset.hasUsage !== "1") { target = assistants[i]; break; }
      }
      // 找不到未挂用的气泡就暂存 pending（等 toolStart/finishTurn 消费），
      // 严禁覆盖挂到最后一个旧气泡——那会把本轮用量写到历史消息上（muse 纯工具轮实测踩坑）。
    }
    if (target) {
      attachUsageToBubble(target, u);
      if (state.turnUsage && state.turnUsage.count > 1) {
        const bar = target.querySelector(":scope > .msg-usage");
        const cacheSum2 = state.turnUsage.hasUnknown ? fmtTokShort(state.turnUsage.cached) + "+?" : fmtTokShort(state.turnUsage.cached);
        if (bar) bar.title = `本轮累计 ${state.turnUsage.count} 次请求 · 输入 ${fmtTokShort(state.turnUsage.prompt)} · 输出 ${fmtTokShort(state.turnUsage.completion)} · 缓存 ${cacheSum2}`;
      }
    } else {
      state._pendingUsage = u;
    }
    // 若正有工具卡在等用量（乱序到达），也顺带补上
    try {
      if (state.currentToolCard && !state.currentToolCard.querySelector(":scope > .tool-usage") && state.lastLLMUsage) {
        attachToolUsageToCard(state.currentToolCard);
      }
    } catch (e) {}
  }
  function attachToolUsageToCard(card, u) {
    const f = usageFields(u || state.lastLLMUsage);
    if (!card || !f) return;
    if (card.querySelector(":scope > .tool-usage")) return;
    const labelPrefix = state.lastAttachedSeq === state.lastUsageSeq && state.lastUsageSeq !== 0 ? "同上次请求 · " : "";
    const bar = document.createElement("div");
    bar.className = "tool-usage";
    const left = document.createElement("span");
    left.className = "tool-usage-stats";
    const pct = f.hit == null ? "未统计" : ((f.hit > 99.995 ? "100.00" : f.hit.toFixed(2)) + "%");
    const cacheTxt = f.cached == null ? "-" : fmtTokShort(f.cached);
    left.textContent = labelPrefix + `输入 ${fmtTokShort(f.prompt)} · 输出 ${fmtTokShort(f.completion)} · 缓存 ${cacheTxt} (${pct})`;
    left.title = `prompt=${f.prompt} completion=${f.completion} total=${f.total} cached=${f.cached} hit=${f.hit == null ? "-" : f.hit.toFixed(2)+"%"}`;
    bar.appendChild(left);
    card.appendChild(bar);
    setBubbleTime(card, card.dataset.createdAt);
    const time = card.querySelector(".msg-time");
    if (time) { time.classList.add("msg-time-inline"); bar.appendChild(time); }
    state.lastAttachedSeq = state.lastUsageSeq;
  }
  function scrollBottom(force) {
    if (force) state.stickBottom = true;
    if (!state.stickBottom) {
      const far = transcript.scrollHeight - transcript.scrollTop - transcript.clientHeight > 200;
      $("to-bottom").classList.toggle("show", far);
      return;
    }
    transcript.scrollTop = transcript.scrollHeight;
    $("to-bottom").classList.remove("show");
  }
  // ── 输入草稿自动保存（localStorage）：刷新/切会话后恢复未发送的文字 ──
  function draftKey() { return "newbee.draft." + (state.sid || "none"); }
  function saveDraft(v) {
    try {
      if (state.sid && v) localStorage.setItem(draftKey(), v);
      else if (state.sid && !v) localStorage.removeItem(draftKey());
    } catch (e) {}
  }
  function restoreDraft() {
    try {
      const d = state.sid && localStorage.getItem(draftKey());
      if (d) {
        input.value = d;
        autoGrow();
      }
    } catch (e) {}
  }
  function autoGrow() { input.style.height = "auto"; input.style.height = Math.min(input.scrollHeight, 160) + "px"; }
  function escapeHtml(s) {
    return String(s).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
  }

  // ── 图片点击放大（lightbox）──
  let lightboxEl = null;
  function openLightbox(src, alt) {
    closeLightbox();
    const mask = document.createElement("div");
    mask.className = "nb-lightbox";
    const img = document.createElement("img");
    img.src = src; img.alt = alt || "";
    mask.appendChild(img);
    mask.addEventListener("click", closeLightbox);
    document.body.appendChild(mask);
    lightboxEl = mask;
  }
  function closeLightbox() {
    if (lightboxEl) { lightboxEl.remove(); lightboxEl = null; }
  }
  function bindZoomable(root) {
    if (!root) return;
    root.querySelectorAll("img").forEach((img) => {
      if (img.dataset.zoomBound) return;
      img.dataset.zoomBound = "1";
      img.classList.add("nb-zoomable");
      img.addEventListener("click", (e) => {
        e.stopPropagation();
        openLightbox(img.src, img.alt || "图片");
      });
    });
  }

  // 代码块复制按钮（dsh MarkdownText codeLabels: copy/copied）
  function bindCopyButtons(root) {
    bindZoomable(root);
    root.querySelectorAll(".md-copy").forEach((btn) => {
      if (btn.dataset.bound) return;
      btn.dataset.bound = "1";
      btn.onclick = () => {
        navigator.clipboard.writeText(btn.dataset.code || "").then(() => {
          btn.textContent = "已复制";
          setTimeout(() => (btn.textContent = "复制"), 1500);
        });
      };
    });
  }

  // ── 绑定 ──
  // 主题切换
  $("theme-toggle").onclick = () => {
    const cur = document.documentElement.getAttribute("data-theme") || "dark";
    applyTheme(cur === "light" ? "dark" : "light", true);
  };

  // ── 思考强度段选器（8 档，输入框旁，对齐 codex ReasoningEffort）──
   const EFFORT_LEVELS = ["none", "minimal", "low", "medium", "high", "xhigh", "max", "ultra"];
   const EFFORT_LABELS = {none:"None", minimal:"Minimal", low:"Low", medium:"Medium", high:"High", xhigh:"XHigh", max:"Max", ultra:"Ultra"};
   const effortWrap = $("effort-segments");
   if (effortWrap) {
     const renderSegs = (active) => {
       effortWrap.innerHTML = "";
       EFFORT_LEVELS.forEach((lv) => {
         const b = document.createElement("button");
         b.type = "button";
         b.className = "effort-seg" + (lv === active ? " active" : "");
         b.textContent = EFFORT_LABELS[lv] || lv;
         b.title = lv;
         b.dataset.level = lv;
         b.onclick = async () => {
           renderSegs(lv);
           if (!state.sid) return;
           try {
             await rpc("session.setEffort", { sessionId: state.sid, effort: lv });
           } catch (err) {
             line("error", "设置思考强度失败: " + err.message);
           }
         };
         effortWrap.appendChild(b);
       });
     };
     // resume 时按会话恢复选中档（nil → medium，兼容旧 auto/off）
     window.__restoreEffort = (effort) => renderSegs(effort === "off" ? "none" : (effort === "auto" ? "medium" : (effort || "medium")));
     renderSegs("medium");
    }

  $("send").onclick = send;
  $("attach-btn").onclick = () => $("file-input").click();
  $("file-input").addEventListener("change", (e) => {
    [...(e.target.files || [])].forEach(addAttachment);
    e.target.value = "";
  });
  input.addEventListener("paste", (e) => {
    const items = (e.clipboardData && e.clipboardData.items) || [];
    let hasImage = false;
    for (const it of items) {
      if (it.kind === "file" && it.type.startsWith("image/")) {
        const f = it.getAsFile();
        if (f) { addAttachment(f); hasImage = true; }
      }
    }
    if (hasImage) e.preventDefault();
  });
  $("interrupt").onclick = interrupt;
  if ($("queue-clear")) $("queue-clear").onclick = clearQueueOnly;
  $("new-session").onclick = () => newSession(); // 直接绑函数会把 MouseEvent 当 cwd 参数传入
  $("perm-yes").onclick = () => permission(true);
  $("perm-no").onclick = () => permission(false);
  $("model-label").onclick = openModels;
  $("model-cancel").onclick = () => $("model-modal").classList.add("hidden");
  // model-confirm 的 onclick 在 openModels 里动态绑定（每次打开重新捕获 pending）

  // ════════════════════════ 模型配置弹窗 ════════════════════════
  const MCFG = {
    providers: {}, roles: {}, path: "", current: null, dirty: false, origKey: "",
    ROLES: ["default", "worker", "adapter", "explorer", "plan", "advisor", "verifier"],
  };

  function mcfgEsc(s) {
    return String(s == null ? "" : s).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");
  }

  async function openModelConfig() {
    try {
      const data = await rpc("llm.providerConfig", {});
      MCFG.providers = data.providers || {};
      MCFG.roles = data.roles || {};
      MCFG.path = data.path || "";
      $("mcfg-path").textContent = MCFG.path;
      const def = MCFG.roles.default && MCFG.roles.default.provider;
      MCFG.current = def && MCFG.providers[def] ? def : Object.keys(MCFG.providers)[0] || null;
      MCFG.dirty = false;
      mcfgRenderList();
      mcfgFlush();
      $("mcfg-modal").classList.remove("hidden");
    } catch (e) {
      line("error", "加载模型配置失败: " + e.message);
    }
  }

  function mcfgRenderList() {
    const box = $("mcfg-providers");
    box.innerHTML = "";
    const names = Object.keys(MCFG.providers);
    if (!names.length) {
      box.innerHTML = '<div class="mcfg-empty-list">暂无厂家</div>';
      return;
    }
    for (const name of names) {
      const p = MCFG.providers[name];
      const n = (p.models || []).length;
      const el = document.createElement("div");
      el.className = "mcfg-pitem" + (name === MCFG.current ? " current" : "");
      el.innerHTML = '<div class="mcfg-pname mono">' + mcfgEsc(name) + "</div>" +
        '<div class="mcfg-pmeta">' + n + " 模型 · " + mcfgEsc(p.api || "openai-completions") + "</div>";
      el.onclick = () => mcfgSelect(name);
      box.appendChild(el);
    }
  }

  function mcfgSelect(name) {
    if (MCFG.current === name) return;
    MCFG.current = name;
    MCFG.dirty = false;
    mcfgRenderList();
    mcfgFlush();
    mcfgState("");
  }

  function mcfgCanonicalApi(api) {
    if (api === "responses") return "openai-responses";
    if (api === "chat") return "openai-completions";
    return ["openai-completions", "openai-responses", "auto"].includes(api) ? api : "openai-completions";
  }

  function mcfgFlush() {
    const p = MCFG.providers[MCFG.current];
    const empty = $("mcfg-empty"), form = $("mcfg-form");
    if (!p) { empty.style.display = "flex"; form.style.display = "none"; return; }
    empty.style.display = "none"; form.style.display = "block";
    $("mcfg-name").value = MCFG.current;
    $("mcfg-api").value = mcfgCanonicalApi(p.api);
    $("mcfg-baseurl").value = p.baseUrl || "";
    $("mcfg-apikey").value = p.apiKey || "";
    MCFG.origKey = p.apiKey || "";
    $("mcfg-ctxw").value = p.contextWindow || "";
    $("mcfg-respcont").checked = !!p.responsesContinuation;
    mcfgRenderModels();
    mcfgRenderRoles();
    mcfgRenderExtras();
    $("mcfg-adv").style.display = "none";
    $("mcfg-adv-toggle").querySelector(".mcfg-chev").textContent = "▶";
  }

  function mcfgRenderModels() {
    const p = MCFG.providers[MCFG.current];
    const box = $("mcfg-models");
    const models = p.models || [];
    box.innerHTML = "";
    $("mcfg-mcount").textContent = models.length ? "(" + models.length + ")" : "";
    for (const model of models) box.appendChild(mcfgModelRow(model, p));
  }

  function mcfgModelRow(model, p) {
    const row = document.createElement("div");
    row.className = "mcfg-model-row";
    row.dataset.model = model;
    row.innerHTML =
      '<div class="mcfg-model-id mono" title="' + mcfgEsc(model) + '">' + mcfgEsc(model) + '</div>' +
      '<select class="model-api" title="此模型使用的 API 协议">' +
        '<option value="">继承默认</option><option value="openai-completions">completions</option>' +
        '<option value="openai-responses">responses</option><option value="auto">auto</option></select>' +
      '<input type="number" class="model-ctx" min="1" placeholder="继承" title="上下文窗口 tokens；留空继承" />' +
      '<select class="model-cont" title="Responses 续写；其他协议下不生效">' +
        '<option value="">继承</option><option value="true">开启</option><option value="false">关闭</option></select>' +
      '<button class="mcfg-x" title="移除模型">✕</button>';

    const api = p.modelApis && p.modelApis[model];
    row.querySelector(".model-api").value = api ? mcfgCanonicalApi(api) : "";
    row.querySelector(".model-ctx").value = (p.contextWindows && p.contextWindows[model]) || "";
    if (p.modelResponsesContinuations && Object.prototype.hasOwnProperty.call(p.modelResponsesContinuations, model)) {
      row.querySelector(".model-cont").value = String(!!p.modelResponsesContinuations[model]);
    }
    row.querySelector(".mcfg-x").onclick = () => {
      const remaining = (p.models || []).filter((x) => x !== model);
      const defaultRole = MCFG.roles.default;
      if (defaultRole && defaultRole.provider === MCFG.current && defaultRole.model === model && !remaining.length) {
        line("warn", "不能移除 default 角色正在使用的最后一个模型");
        return;
      }
      p.models = remaining;
      for (const [role, binding] of Object.entries(MCFG.roles)) {
        if (binding.provider === MCFG.current && binding.model === model) {
          if (role === "default") MCFG.roles[role] = {provider: MCFG.current, model: remaining[0]};
          else delete MCFG.roles[role];
        }
      }
      for (const key of ["modelApis", "contextWindows", "modelResponsesContinuations"]) {
        if (p[key]) delete p[key][model];
      }
      mcfgRenderModels(); mcfgRenderRoles(); mcfgMark();
    };
    row.querySelectorAll("input, select").forEach((input) => {
      input.addEventListener(input.tagName === "SELECT" ? "change" : "input", mcfgMark);
    });
    return row;
  }

  function mcfgAddModel() {
    const input = $("mcfg-minput");
    const id = input.value.trim();
    if (!id) return;
    const p = MCFG.providers[MCFG.current];
    if (!p.models) p.models = [];
    if (p.models.includes(id)) { line("warn", "模型已存在: " + id); return; }
    p.models.push(id);
    input.value = "";
    mcfgRenderModels(); mcfgRenderRoles(); mcfgMark();
  }

  async function mcfgFetchModels() {
    const btn = $("mcfg-mfetch");
    btn.disabled = true; btn.textContent = "拉取中…";
    try {
      const baseUrl = $("mcfg-baseurl").value.trim();
      const apiKey = $("mcfg-apikey").value.trim();
      if (!baseUrl) { line("error", "Base URL 不能为空"); btn.disabled = false; btn.textContent = "拉取"; return; }
      if (!apiKey) { line("error", "API Key 不能为空"); btn.disabled = false; btn.textContent = "拉取"; return; }
      const r = await rpc("llm.providerModels", { provider: MCFG.current, baseUrl: baseUrl, apiKey: apiKey, refresh: true });
      const p = MCFG.providers[MCFG.current];
      if (!p.models) p.models = [];
      let added = 0;
      for (const m of (r.models || [])) if (!p.models.includes(m)) { p.models.push(m); added++; }
      mcfgRenderModels(); mcfgRenderRoles(); mcfgMark();
      line("notice", "已拉取 " + (r.models || []).length + " 个模型（新增 " + added + "）");
    } catch (e) {
      line("error", "拉取失败: " + e.message);
    } finally {
      btn.disabled = false; btn.textContent = "拉取";
    }
  }

  function mcfgRenderRoles() {
    const p = MCFG.providers[MCFG.current];
    const box = $("mcfg-roles");
    box.innerHTML = "";
    const models = p.models || [];
    for (const role of MCFG.ROLES) {
      const current = MCFG.roles[role];
      const row = document.createElement("label");
      row.className = "mcfg-role-row";
      row.innerHTML = '<span class="mono">' + mcfgEsc(role) + '</span><select><option value="">不绑定到此厂家</option></select>';
      const select = row.querySelector("select");
      for (const model of models) {
        const option = document.createElement("option");
        option.value = model; option.textContent = model; select.appendChild(option);
      }
      if (current && current.provider === MCFG.current) select.value = current.model;
      select.onchange = () => {
        if (select.value) {
          MCFG.roles[role] = {provider: MCFG.current, model: select.value};
        } else {
          const latest = MCFG.roles[role];
          if (latest && latest.provider === MCFG.current) {
            if (role === "default") {
              line("warn", "default 是聊天默认角色，请先绑定其他模型");
              select.value = latest.model;
              return;
            }
            delete MCFG.roles[role];
          }
        }
        mcfgMark();
      };
      box.appendChild(row);
    }
  }

  function mcfgRenderExtras() {
    const p = MCFG.providers[MCFG.current];
    const wrap = $("mcfg-exrows");
    wrap.innerHTML = "";
    const reserved = new Set(["baseUrl", "api", "apiKey", "models", "modelApis", "contextWindows", "contextWindow", "responsesContinuation", "modelResponsesContinuations"]);
    for (const [k, v] of Object.entries(p)) {
      if (reserved.has(k)) continue;
      wrap.appendChild(mcfgExRow(k, typeof v === "object" ? JSON.stringify(v) : String(v)));
    }
  }
  function mcfgExRow(k, v) {
    const row = document.createElement("div");
    row.className = "mcfg-kvrow";
    row.innerHTML =
      '<input type="text" class="ex-k mono" value="' + mcfgEsc(k) + '" placeholder="字段名" spellcheck="false" />' +
      '<input type="text" class="ex-v mono" value="' + mcfgEsc(v) + '" placeholder="JSON 值" spellcheck="false" />' +
      '<button class="mcfg-x" title="删除">✕</button>';
    row.querySelector(".mcfg-x").onclick = () => { row.remove(); mcfgMark(); };
    row.querySelectorAll("input").forEach((i) => (i.oninput = () => mcfgMark()));
    return row;
  }

  function mcfgToggleAdv() {
    const adv = $("mcfg-adv");
    const open = adv.style.display === "none";
    adv.style.display = open ? "block" : "none";
    $("mcfg-adv-toggle").querySelector(".mcfg-chev").textContent = open ? "▼" : "▶";
  }

  function mcfgMark() { MCFG.dirty = true; mcfgState("未保存", "dirty"); }
  function mcfgState(text, cls) {
    const s = $("mcfg-state");
    s.textContent = text || "";
    s.className = "mcfg-state" + (cls ? " " + cls : "");
  }

  function mcfgCollect() {
    const p = MCFG.providers[MCFG.current];
    if (!p) return null;
    const name = $("mcfg-name").value.trim();
    const baseUrl = $("mcfg-baseurl").value.trim();
    let apiKey = $("mcfg-apikey").value.trim();
    if (!name) { line("error", "厂家名称不能为空"); return null; }
    if (!baseUrl) { line("error", "Base URL 不能为空"); return null; }
    if (!apiKey) { line("error", "API Key 不能为空（可填 ${ENV_VAR}）"); return null; }
    if (apiKey === MCFG.origKey) apiKey = null;

    const models = [], modelApis = {}, ctxw = {}, modelRespCont = {};
    $("mcfg-models").querySelectorAll(".mcfg-model-row").forEach((row) => {
      const model = row.dataset.model;
      models.push(model);
      const api = row.querySelector(".model-api").value;
      const contextWindow = parseInt(row.querySelector(".model-ctx").value, 10);
      const continuation = row.querySelector(".model-cont").value;
      if (api) modelApis[model] = api;
      if (contextWindow > 0) ctxw[model] = contextWindow;
      if (continuation !== "") modelRespCont[model] = continuation === "true";
    });

    const extras = {};
    const reserved = new Set(["baseUrl", "api", "apiKey", "models", "modelApis", "contextWindows", "contextWindow", "responsesContinuation", "modelResponsesContinuations"]);
    $("mcfg-exrows").querySelectorAll(".mcfg-kvrow").forEach((row) => {
      const k = row.querySelector(".ex-k").value.trim();
      const raw = row.querySelector(".ex-v").value.trim();
      if (!k || reserved.has(k)) return;
      try { extras[k] = JSON.parse(raw); } catch (_) { extras[k] = raw; }
    });

    const roles = {};
    for (const role of MCFG.ROLES) {
      const r = MCFG.roles[role];
      if (r && r.provider === MCFG.current) roles[role] = r.model;
    }

    return {
      provider: MCFG.current,
      newName: name,
      baseUrl: baseUrl,
      api: mcfgCanonicalApi($("mcfg-api").value),
      apiKey: apiKey,
      models: models,
      modelApis: modelApis,
      contextWindow: parseInt($("mcfg-ctxw").value, 10) || null,
      contextWindows: ctxw,
      responsesContinuation: $("mcfg-respcont").checked,
      modelResponsesContinuations: modelRespCont,
      extras: extras,
      roles: roles,
    };
  }

  async function mcfgSave() {
    const attrs = mcfgCollect();
    if (!attrs) return;
    const btn = $("mcfg-save");
    btn.disabled = true; btn.textContent = "保存中…";
    try {
      const r = await rpc("llm.saveProvider", attrs);
      MCFG.dirty = false;
      MCFG.current = r.provider;
      const data = await rpc("llm.providerConfig", {});
      MCFG.providers = data.providers || {};
      MCFG.roles = data.roles || {};
      mcfgRenderList(); mcfgFlush();
      mcfgState("已保存", "saved");
      line("notice", "模型配置已保存");
      const def = MCFG.roles.default;
      if (def) $("model-label").textContent = def.provider + "/" + def.model;
    } catch (e) {
      line("error", "保存失败: " + e.message);
      mcfgState("保存失败", "dirty");
    } finally {
      btn.disabled = false; btn.textContent = "保存";
    }
  }

  async function mcfgDelete() {
    if (!MCFG.current) return;
    if (!confirm("确定删除厂家 " + MCFG.current + " ？引用它的角色将被解绑。")) return;
    try {
      await rpc("llm.deleteProvider", { provider: MCFG.current });
      delete MCFG.providers[MCFG.current];
      for (const [role, r] of Object.entries(MCFG.roles)) if (r.provider === MCFG.current) delete MCFG.roles[role];
      MCFG.current = Object.keys(MCFG.providers)[0] || null;
      MCFG.dirty = false;
      mcfgRenderList(); mcfgFlush();
      line("notice", "已删除厂家");
    } catch (e) {
      line("error", "删除失败: " + e.message);
    }
  }

  function mcfgAddProvider() {
    const name = prompt("新厂家名称（小写英文键名）：", "");
    if (!name || !name.trim()) return;
    const key = name.trim();
    if (MCFG.providers[key]) { line("warn", "厂家已存在: " + key); return; }
    MCFG.providers[key] = { baseUrl: "", api: "openai-completions", apiKey: "", models: [] };
    MCFG.current = key;
    MCFG.dirty = true;
    mcfgRenderList(); mcfgFlush();
    mcfgState("新厂家，待保存", "dirty");
    $("mcfg-baseurl").focus();
  }

  function mcfgClose() {
    if (MCFG.dirty && !confirm("有未保存的修改，确定关闭？")) return;
    $("mcfg-modal").classList.add("hidden");
  }

  $("model-config-btn").onclick = openModelConfig;
  $("mcfg-close").onclick = mcfgClose;
  $("mcfg-cancel").onclick = mcfgClose;
  $("mcfg-save").onclick = mcfgSave;
  $("mcfg-delete").onclick = mcfgDelete;
  $("mcfg-add").onclick = mcfgAddProvider;
  $("mcfg-madd").onclick = mcfgAddModel;
  $("mcfg-mfetch").onclick = mcfgFetchModels;
  $("mcfg-adv-toggle").onclick = mcfgToggleAdv;
  $("mcfg-exadd").onclick = () => { $("mcfg-exrows").appendChild(mcfgExRow("", "")); mcfgMark(); };
  $("mcfg-minput").addEventListener("keydown", (e) => { if (e.key === "Enter") { e.preventDefault(); mcfgAddModel(); } });
  $("mcfg-eye").onclick = () => {
    const i = $("mcfg-apikey");
    i.type = i.type === "password" ? "text" : "password";
  };
  $("mcfg-modal").addEventListener("mousedown", (e) => { if (e.target === $("mcfg-modal")) mcfgClose(); });
  ["mcfg-name", "mcfg-baseurl", "mcfg-apikey", "mcfg-ctxw"].forEach((id) => $(id).addEventListener("input", () => mcfgMark()));
  $("mcfg-api").addEventListener("change", () => mcfgMark());
  $("mcfg-respcont").addEventListener("change", () => mcfgMark());

  input.addEventListener("input", () => {
    autoGrow();
    saveDraft(input.value);
  });
  input.addEventListener("keydown", (e) => {
    if (e.key === "Enter" && !e.shiftKey) { e.preventDefault(); send(); }
  });
  // 回到底部：滚动远离底部时浮现（dsh to-bottom 悬浮钮）
  transcript.addEventListener("scroll", () => {
    const far = transcript.scrollHeight - transcript.scrollTop - transcript.clientHeight > 200;
    state.stickBottom = !far;
    $("to-bottom").classList.toggle("show", far);
  });
  $("to-bottom").onclick = () => scrollBottom(true);

  // ── 状态栏（对齐 dsh StatsLine）：轮询 session.state，拼 左统计 | 右状态 ──
  let statsTimer = null;
  function startStats() {
    if (statsTimer) clearInterval(statsTimer);
    refreshStats();
    statsTimer = setInterval(() => {
      refreshStats();
      refreshSessionStatus();
    }, 2000);
  }
  async function refreshStats() {
    if (!state.sid) return;
    try {
      const sid = state.sid;
      const st = await rpc("session.state", { sessionId: sid });
      if (state.sid !== sid) return; // 轮询途中切了会话，丢弃旧会话数据，避免渲染进新会话 UI
      renderStats(st);
    } catch (e) { /* 忽略轮询错误 */ }
  }
  function fmtTok(n) {
    if (n == null || isNaN(n)) return "0";
    const sc = (v) => v >= 100 ? String(Math.round(v)) : (Math.round(v * 10) / 10).toString();
    if (n < 1000) return String(n);
    if (n < 1e6) return sc(n / 1000) + "K";
    return sc(n / 1e6) + "M";
  }
  function renderStats(st) {
    // 同步左侧模型名（provider/model）；轮询每 2s 自愈一次
    if (st && st.model) {
      const m = (st.provider && st.provider !== "default") ? st.provider + "/" + st.model : st.model;
      const el = $("model-label");
      if (el && el.textContent !== m) el.textContent = m;
    }
    if (st.context_tokens > 0 && st.context_window > 0) {
      $("usage-label").textContent = `${fmtContext(st.context_tokens)}/${fmtContext(st.context_window)}`;
    }
    // 左侧：目录 + 进度 + 耗时 + token（口径：服务端 usage 为会话累计值）
    const u = st.usage || {};
    const promptTok = u.prompt_tokens || 0;
    // 会话累计口径：与气泡一致，区分“未回报”（缺失）与“真 0”。
    const cacheRaw = u.cache_read_tokens ?? u.cached_tokens
      ?? (u.prompt_tokens_details && u.prompt_tokens_details.cached_tokens);
    const hasCacheInfo = cacheRaw != null;
    const cacheRead = hasCacheInfo ? cacheRaw : 0;
    const outTok = u.completion_tokens || u.output_tokens || 0;
    const cacheHit = (promptTok > 0 && hasCacheInfo) ? Math.min(100, cacheRead * 100 / promptTok) : null;
    const cacheMissing = promptTok > 0 && !hasCacheInfo;
    if (st && st.cwd !== undefined) {
      state.cwd = st.cwd || null;
      updateCwdLabel(state.cwd);
    }
    const cwd0 = state.cwd || "";
    const left = [];
     if (cwd0) left.push(`<span title="newbee 当前工作目录">${ICO_FOLDER} ${escapeHtml(cwd0)}</span>`);
    else left.push('<span title="newbee 工作区">newbee</span>');
    const turns = st.turns || 0, steps = st.steps || 0;
    if (turns > 0 || steps > 0) left.push(`<span title="回合数（每发一条消息算 1 轮）· 步骤数（每次工具调用算 1 步）">${turns} 轮 · ${steps} 步</span>`);
    const tm = state.timing;
    const llmMs = tm.llmMs + (tm.llmStart !== null ? Date.now() - tm.llmStart : 0);
    const toolMs = tm.toolMs + (tm.toolStart !== null ? Date.now() - tm.toolStart : 0);
    if (llmMs > 0 || toolMs > 0) left.push(`<span title="模型生成累计耗时 · 工具执行累计耗时">LLM ${fmtDur(llmMs)} · 工具 ${fmtDur(toolMs)}</span>`);
    const spd = [];
    if (tm.ftCount > 0) spd.push(`<span title="平均首 token 耗时（多次请求平均）">首 token ${fmtDur(tm.ftSum / tm.ftCount)}</span>`);
    if (llmMs > 0 && tm.outTok > 0) spd.push(`<span title="会话平均吞吐：累计输出 token ÷ 累计 LLM 段耗时（含排队与 prefill 的首 token 等待，不含工具段；非当前回复的瞬时速度）">${(tm.outTok / (llmMs / 1000)).toFixed(1)} tok/s</span>`);
    if (spd.length) left.push(spd.join(" · "));
    // 缓存命中率:数据源为服务端 usage_snap(会话累计,按请求加权平均);
    // 前端不再另行累计,跨设备/进程重启口径一致。
    if (cacheHit !== null) left.push(`<span title="本会话平均缓存命中率 = Σ命中缓存 token ÷ Σ输入 token（服务端按每次请求累计；命中 token 读得更快、单价更低）">缓存 ${cacheHit.toFixed(1).replace(/\.0$/, "")}%</span>`);
    else if (cacheMissing) left.push(`<span title="供应商未回报缓存统计（该模型/网关未命中时不返回缓存字段）">缓存 未统计</span>`);
    if (promptTok > 0 || outTok > 0) left.push(`<span title="累计输入 token（prompt_tokens）· 累计输出 token（completion_tokens）">输入 ${fmtTok(promptTok)} · 输出 ${fmtTok(outTok)}</span>`);
    $("stats-left").innerHTML = left.join(" | ");
    // 右侧：状态 + bind + 策略
    const qn = st.queued || 0;
    const stTxt = st.busy
      ? `<span class="st-busy" title="Agent 正在运行">● 运行中${qn > 0 ? " · 排队 " + qn : ""}</span>`
      : '<span class="st-ok" title="Agent 空闲">● 空闲</span>';
    const bindTxt = st.bindings || 0;
    const policyTxt = escapeHtml(st.policy || "");
    $("stats-right").innerHTML = `${stTxt} <span title="会话绑定变量数">bind:${bindTxt}</span> <span title="权限策略：lenient=放行 / ask=询问 / deny=拒绝">${policyTxt}</span>`;
  }

  // ── 环境进化控制台 ──
  function initEvolution() {
    const refreshBtn = $("evo-refresh");
    if (refreshBtn) refreshBtn.onclick = () => refreshEvolution();

    const triggerBtn = $("evo-trigger");
    if (triggerBtn) {
      triggerBtn.onclick = async () => {
        const label = triggerBtn.querySelector("span");
        const original = label ? label.textContent : "运行一轮";
        triggerBtn.disabled = true;
        triggerBtn.classList.add("running");
        if (label) label.textContent = "已排队";
        try {
          await rpc("evolution.trigger", {});
          setTimeout(refreshEvolution, 1800);
        } catch (e) {
          if (label) label.textContent = "触发失败";
        } finally {
          triggerBtn.classList.remove("running");
          setTimeout(() => {
            triggerBtn.disabled = false;
            if (label) label.textContent = original;
          }, 2200);
        }
      };
    }

    setInterval(() => {
      if (MC.open && MC.tab === "evolution") refreshEvoStatus();
    }, 10_000);
  }

  async function refreshEvolution() {
    await Promise.all([refreshEvoStatus(), refreshEvoFeed()]);
    flushEvoBuffer();
  }

  async function refreshEvoStatus() {
    try {
      const st = await rpc("evolution.status", {});
      const coordinator = st.coordinator && typeof st.coordinator === "object" ? st.coordinator : null;
      const engine = st.engine || {};
      const engineEl = $("evo-engine-state");
      const online = !!engine.coordinator_online;
      engineEl.textContent = online
        ? (engine.daemon_online ? "Coordinator + Daemon 在线" : "Coordinator 在线 · Daemon 按需运行")
        : "Coordinator 离线";
      engineEl.className = "evo-engine-state " + (online ? "online" : "offline");

      const revision = coordinator && coordinator.active_revision != null ? coordinator.active_revision : null;
      $("evo-revision").textContent = revision == null ? "r-" : "r" + revision;
      $("evo-autonomy").textContent = st.autonomy_label || st.autonomy || "-";
      const axEl = $("evo-autonomy-explain");
      if (axEl) { axEl.textContent = st.autonomy_explain || ""; axEl.title = st.autonomy_explain || ""; }
      const decideCount = (st.changes || []).filter((c) => c.can_approve).length;
      $("evo-open-count").textContent = coordinator ? (decideCount || coordinator.open_count || 0) : "-";
      $("evo-release-count").textContent = coordinator ? coordinator.active_count || 0 : "-";
      $("evo-signal-count").textContent = (st.pending_signals || []).length;
      // 有待决策但用户不在进化 tab：亮徽标，不抢焦点。
      if (decideCount > 0 && !(MC.open && MC.tab === "evolution")) { MC.evoUnread = decideCount; updateMCBadges(); }

      const degraded = coordinator && (coordinator.degraded || []).length > 0;
      const health = $("evo-revision-health");
      health.textContent = !online ? "离线" : degraded ? "已退化" : "健康";
      health.className = "evo-health-pill " + (!online || degraded ? "degraded" : "healthy");

      renderEvoChanges(st.changes || []);
      renderEvoSignals(st.pending_signals || []);
      renderEvoReleases(st.active_releases || []);

      const bytes = engine.event_store_bytes || 0;
      $("evo-events-size").textContent = formatBytes(bytes) + " · project store";
    } catch (e) {
      const engineEl = $("evo-engine-state");
      if (engineEl) {
        engineEl.textContent = "状态读取失败";
        engineEl.className = "evo-engine-state offline";
      }
    }
  }

  // 人话翻译层（H2）：Ring/验证门/原因全部说人话，ID 降为副标题。
  function evoRingExplain(ring) {
    if (ring == null) return "影响范围未知 · 按最谨慎处理";
    if (ring === 3 || ring === "3") return "影响小 · 单个工具改进（最稳）";
    if (ring === 2 || ring === "2") return "影响中 · 规则/提示词改进";
    if (ring === 1 || ring === "1") return "影响大 · 底层能力变更";
    if (ring === 0 || ring === "0") return "不允许自动激活";
    return "影响范围 Ring " + ring;
  }
  function evoLayerExplain(key) {
    const m = { static: "格式与静态检查：语法/结构是否合法", deterministic: "确定性复测：同样输入是否稳定产出", counterfactual: "历史回放：过去失败用新方案能否过", usage: "真实使用观察：线上试用效果", longitudinal: "长期跟踪：长时间是否稳定" };
    return m[key] || key;
  }
  function evoStageOf(change) {
    const st = change.derived_status || change.status || "";
    if (change.can_approve) return 3;
    if (st === "canary" || st === "suggestion_ready") return 3;
    if (st === "evaluating" || st === "building") return 2;
    if (st === "requested" || st === "building") return 1;
    return 2;
  }
  function evoPipelineHtml(stage) {
    const names = ["信号", "候选", "验证", "门控", "版本"];
    // stage: 0-4 当前走到哪
    const idx = stage === 3 ? 3 : stage >= 4 ? 4 : stage;
    return '<div class="evo-pipeline">' + names.map((n, i) => {
      const cls = i < idx ? "done" : i === idx ? "now" : "todo";
      const dot = i < idx ? "●" : i === idx ? "◐" : "○";
      return `<span class="evo-pipe-${cls}" title="${i < idx ? "已完成" : i === idx ? "进行中" : "待进行"}">${dot} ${n}</span>${i < names.length - 1 ? "<i>→</i>" : ""}`;
    }).join("") + "</div>";
  }

  function renderEvoChanges(changes) {
    const decideBox = $("evo-decide-list");
    const progressBox = $("evo-progress-list");
    const compatBox = $("evo-changes-list");
    const decideSummary = $("evo-decide-summary");
    const progressSummary = $("evo-progress-summary");
    const legacySummary = $("evo-change-summary");
    const all = Array.isArray(changes) ? changes : [];
    const decide = all.filter((c) => c.can_approve);
    const reeval = all.filter((c) => c.can_reevaluate && !c.can_approve);
    const progress = all.filter((c) => !c.terminal && !c.can_approve && !c.can_reevaluate);
    const done = all.filter((c) => c.terminal).slice(0, 2);
    if (legacySummary) legacySummary.textContent = decide.length ? `${decide.length} 个待决策` : "无";
    if (decideSummary) decideSummary.textContent = decide.length ? `${decide.length} 个等你批准` : reeval.length ? `${reeval.length} 个需重新验证` : "暂无需要你决定的事项";
    if (progressSummary) progressSummary.textContent = progress.length ? `${progress.length} 个进行中` : done.length ? "暂无进行中（最近已完成见下）" : "暂无";

    if (decideBox) {
      if (!decide.length && !reeval.length) {
        decideBox.innerHTML = '<div class="evo-empty evo-celebrate">✓ 暂无需要你决定的改进，环境稳定运行中。<br>有新的验证通过的改进时，这里会出现“批准并激活”按钮。</div>';
      } else {
        decideBox.innerHTML = [...decide, ...reeval].map(renderEvoDecideCard).join("");
        decideBox.querySelectorAll(".evo-approve").forEach((b) => { b.onclick = () => approveEvolutionChange(b.dataset.changeId, b); });
        decideBox.querySelectorAll(".evo-explain").forEach((b) => { b.onclick = () => explainBrief(b.dataset.changeId, b); });
        decideBox.querySelectorAll(".evo-reevaluate").forEach((b) => { b.onclick = () => reevaluateEvolutionChange(b.dataset.changeId, b); });
      }
    }
    if (progressBox) {
      const list = [...progress, ...done];
      if (!list.length) {
        progressBox.innerHTML = '<div class="evo-empty">暂无进行中的改进。AI 发现重复问题后，这里会显示验证进度。</div>';
      } else {
        progressBox.innerHTML = list.map(renderEvoProgressCard).join("");
        progressBox.querySelectorAll(".evo-reevaluate").forEach((b) => { b.onclick = () => reevaluateEvolutionChange(b.dataset.changeId, b); });
      }
    }
    if (compatBox) compatBox.innerHTML = "";
  }

  function evoCardShell(change, inner) {
    const status = change.derived_status || change.status || "requested";
    return `<article class="evo-change ${escapeHtml(status)}">${inner}</article>`;
  }

  function renderEvoDecideCard(change) {
    const changeId = escapeHtml(change.change_id || "");
    const brief = (change.brief && typeof change.brief === "object") ? change.brief : null;
    const statusTag = escapeHtml(change.status_label || change.derived_status || "");
    const action = change.can_approve
      ? `<button class="evo-approve evo-approve-big" data-change-id="${changeId}">批准，用上这个改进</button>`
      : `<button class="evo-reevaluate" data-change-id="${changeId}">重新评测</button>`;
    if (!brief) {
      const t = escapeHtml(change.human_title || "环境改进");
      return evoCardShell(change, `
        <div class="evo-change-head"><div class="evo-change-title"><strong>${t}</strong><span>${changeId}</span></div><span class="evo-status-tag">${statusTag}</span></div>
        <div class="evo-change-foot"><span class="evo-change-next">${escapeHtml(change.next_action || "")}</span>${action}</div>`);
    }
    const sec = (label, text) => `<div class="evo-story"><b>${label}</b><span>${escapeHtml(text || "暂无")}</span></div>`;
    const again = brief.fallback
      ? `<button class="evo-explain" data-change-id="${changeId}" title="让 AI 换一种说法重新讲一遍">换一种说法</button>`
      : "";
    const layers = ((change.evaluation || {}).layers || []).map(renderEvoLayer).join("");
    const verify = escapeHtml(change.verification_summary || "");
    return evoCardShell(change, `
        <div class="evo-change-head"><div class="evo-change-title"><strong>${escapeHtml(brief.title || "环境改进")}</strong><span>${statusTag}</span></div>${again}</div>
        ${sec("发现", brief.found)}
        ${sec("改法", brief.change_to)}
        ${sec("依据", brief.why)}
        ${sec("风险", brief.risk_undo)}
        ${sec("决定", brief.ask)}
        <details class="evo-tech"><summary>验证细节（${verify}）</summary><div class="evo-layers evo-layers-detail">${layers || renderPendingLayers()}</div></details>
        <div class="evo-change-foot"><span class="evo-change-next">${escapeHtml(change.next_action || "")}</span>${action}</div>
        <details class="evo-tech"><summary>技术详情</summary><pre>${escapeHtml(JSON.stringify({ change_id: change.change_id, candidate_release: change.candidate_release, plugin_id: change.plugin_id, ring: change.ring, base_revision: change.base_revision }, null, 2))}</pre></details>
      `);
  }

  function renderEvoProgressCard(change) {
    const changeId = escapeHtml(change.change_id || "");
    const title = escapeHtml(change.human_title || change.reason_plain || shortRelease(change.candidate_release) || change.change_id || "改进");
    const statusTag = escapeHtml(change.status_label || change.derived_status || "");
    const layers = ((change.evaluation || {}).layers || []).map(renderEvoLayer).join("");
    const verify = escapeHtml(change.verification_summary || "");
    const stage = evoStageOf(change);
    const action = change.can_reevaluate ? `<button class="evo-reevaluate" data-change-id="${changeId}">重新评测</button>` : "";
    return evoCardShell(change, `
        <div class="evo-change-head"><div class="evo-change-title"><strong>${title}</strong><span>${changeId}</span></div><span class="evo-status-tag">${statusTag}</span></div>
        ${evoPipelineHtml(stage)}
        <div class="evo-layers">${layers || renderPendingLayers()}</div>
        <div class="evo-change-foot"><span class="evo-change-next">${verify || escapeHtml(change.next_action || "验证中")}</span>${action}</div>
      `);
  }

  function renderEvoLayer(layer) {
    const status = layer.status || "pending";
    const marks = { passed: "通过", failed: "未过", observing: "观察中", pending: "待运行", skipped: "跳过" };
    const marksShort = { passed: "PASS", failed: "FAIL", observing: "LIVE", pending: "WAIT", skipped: "N/A" };
    let detail = "";
    if (layer.samples != null && layer.samples !== "") detail = `${layer.samples} 次试用`;
    else if (layer.replayed != null && layer.replayed !== "") detail = `${layer.replayed} 次回放`;
    else detail = layer.label || layer.key || "验证";
    const tip = `${evoLayerExplain(layer.key)}${layer.reason ? "：" + layer.reason : ""}${(layer.samples != null && layer.samples !== "") ? "（" + layer.samples + " 次真实使用）" : ""}${(layer.replayed != null && layer.replayed !== "") ? "（回放 " + layer.replayed + " 条）" : ""}`;
    return `<div class="evo-layer ${escapeHtml(status)}" title="${escapeHtml(tip)}"><b>${marksShort[status] || "WAIT"}</b><span>${escapeHtml(detail)}</span><em class="evo-layer-cn">${escapeHtml(marks[status] || "待运行")}</em></div>`;
  }

  function renderPendingLayers() {
    return ["静态", "确定性", "回放", "使用", "长期"].map((label) =>
      `<div class="evo-layer pending"><b>WAIT</b><span>${label}</span></div>`
    ).join("");
  }

  function renderEvoSignals(signals) {
    const box = $("evo-signals");
    if (!box) return;
    if (!signals.length) {
      box.innerHTML = '<div class="evo-empty">暂无待看问题。AI 在任务中注意到重复失败时，这里会先冒出来，攒够证据才变成上面的改进提议。</div>';
      return;
    }
    const urgencyCn = (u) => u === "high" ? "紧急" : u === "low" ? "一般" : "待看";
    box.innerHTML = signals.slice(0, 5).map((signal) => `<div class="evo-signal">
      <div class="evo-signal-head"><strong>AI 注意到：${escapeHtml(signal.capability || "某个能力不稳定")}</strong><span>${escapeHtml(urgencyCn(signal.urgency))}</span></div>
      <p>${escapeHtml(signal.evidence || "正在诊断原因，稍后会给出改进提议")}</p>
    </div>`).join("");
  }

  function renderEvoReleases(releases) {
    const box = $("evo-releases");
    if (!box) return;
    if (!releases.length) {
      box.innerHTML = '<div class="evo-empty">当前版本还没有生效的能力。批准上面的改进后，这里会出现真实使用效果（用了几次、成功率）。</div>';
      return;
    }
    box.innerHTML = releases.map((release) => {
      const uses = release.uses || 0;
      const rate = release.success_rate == null ? "待观测" : Math.round(release.success_rate * 100) + "%";
      const rateClass = release.success_rate == null ? "" : release.success_rate >= 0.8 ? " good" : " warn";
      const cost = release.avg_tokens == null ? "-" : fmtTok(release.avg_tokens) + " tok";
      return `<div class="evo-release">
        <span class="evo-release-name" title="${escapeHtml(release.release || "")}">${escapeHtml(release.plugin || "?")}</span>
        <span class="evo-release-stats">${uses} 次 · <span class="evo-rate${rateClass}">${rate}</span> · ${cost}</span>
        <span class="evo-release-kind">${escapeHtml(release.kind || "release")}</span>
      </div>`;
    }).join("");
  }

  async function explainBrief(changeId, button) {
    if (!changeId || !button) return;
    const orig = button.textContent;
    button.disabled = true;
    button.textContent = "正在组织语言…";
    try {
      await rpc("evolution.explain", { changeId });
      await refreshEvolution();
    } catch (e) {
      line("error", "生成说明失败: " + e.message);
      button.disabled = false;
      button.textContent = orig;
    }
  }

  async function approveEvolutionChange(changeId, button) {
    if (!changeId) return;
    const card = button ? button.closest(".evo-change") : null;
    const title = card ? (card.querySelector(".evo-change-title strong") || {}).textContent || changeId : changeId;
    const facts = card ? Array.from(card.querySelectorAll(".evo-story span, .evo-facts span")).map((el) => "• " + el.textContent).join("\n") : "";
    const msg = `让环境记住这个改进吗？\n\n【${title}】(${changeId})\n${facts}\n\n批准后会生成新版本并立即生效，旧版本保留，可一键回退。不批准则维持现状，什么都不变。`;
    confirmDialog(msg, async () => {
      button.disabled = true;
      button.textContent = "激活中";
      try {
        await rpc("evolution.approve", { changeId });
        await refreshEvolution();
      } catch (e) {
        line("error", "批准 Change 失败: " + e.message);
        button.disabled = false;
        button.textContent = "重试批准";
      }
    }, { confirmLabel: "批准，用上这个改进", cancelLabel: "再想想", confirmClass: "btn-allow" });
  }

  async function reevaluateEvolutionChange(changeId, button) {
    if (!changeId) return;
    button.disabled = true;
    button.textContent = "评测中";
    try {
      await rpc("evolution.reevaluate", { changeId });
      await refreshEvolution();
    } catch (e) {
      if (String(e.message || e).includes("already_active")) {
        await refreshEvolution();
        return;
      }
      line("error", "重新评测 Change 失败: " + e.message);
      button.disabled = false;
      button.textContent = "重试评测";
    }
  }


  function formatBytes(bytes) {
    if (bytes >= 1024 * 1024) return (bytes / 1024 / 1024).toFixed(1) + " MB";
    if (bytes >= 1024) return Math.round(bytes / 1024) + " KB";
    return bytes + " B";
  }

  function shortRelease(value) {
    if (!value) return "";
    return String(value).split("@")[0];
  }

  function cleanEvolutionReason(value) {
    return String(value || "").replace(/^adapter:\s*/, "Adapter 提案：");
  }

  async function refreshEvoFeed() {
    try {
      const feed = await rpc("evolution.feed", { n: 100 });
      renderEvoFeed(feed.events || []);
    } catch (e) {
      const box = $("evo-feed");
      if (box) box.innerHTML = '<div class="evo-empty">事件证据暂时不可读。</div>';
    }
  }

  function renderEvoFeed(events) {
    const box = $("evo-feed");
    if (!box) return;
    if (!events.length) {
      box.innerHTML = '<div class="evo-empty">暂无历史。每次提议、验证、批准、回退都会记在这里，可审计、可追溯。</div>';
      return;
    }
    box.innerHTML = "";
    events.forEach((event) => box.appendChild(evoEventEl(event)));
  }

  function evoEventEl(event) {
    const row = document.createElement("details");
    const kind = event.topic || "event";
    const payload = event.event || {};
    row.className = "evo-event kind-" + evoKindClass(kind);
    const time = formatEvolutionTime(event.at);
    const title = evoEventTitle(kind, payload);
    const summary = evoEventSummary(kind, payload);
    const identity = evoEventIdentity(payload);
    row.innerHTML = `<summary><span class="evo-event-dot"></span><div class="evo-event-main"><span class="evo-kind" title="${escapeHtml(kind)}">${escapeHtml(title)}</span><div class="evo-body">${escapeHtml(summary)}</div></div><span class="evo-time">${escapeHtml(time)}</span></summary><pre class="evo-event-raw">${escapeHtml(JSON.stringify({ topic: kind, id: event.id, identity, payload }, null, 2))}</pre>`;
    return row;
  }

  function evoKindClass(kind) {
    if (/reject|error|fail|degraded|rolled_back/.test(kind)) return "rejected";
    if (/activated|approved|promoted|healthy|advanced|evaluated/.test(kind)) return "activated";
    return "info";
  }

  function evoEventTitle(kind, payload) {
    const passed = payload && (payload.passed === true || payload.passed === "true");
    const labels = {
      change_requested: "收到变更信号",
      change_building: "候选已构建",
      change_evaluated: passed ? "验证通过" : "验证失败",
      change_canary: "进入门控",
      change_approved: "人工已批准",
      change_activated: "变更已激活",
      change_rejected: "候选已拒绝",
      change_rolled_back: "变更已回退",
      revision_advanced: "Revision 已推进",
      revision_degraded: "Revision 已退化",
      revision_healthy: "Revision 健康",
      release_observation: "Release 使用观测"
    };
    return labels[kind] || kind.replaceAll("_", " ");
  }

  function evoEventIdentity(payload) {
    if (!payload) return "";
    return payload.change_id || shortRelease(payload.release_id) || (payload.revision && `r${payload.revision.rev}`) || "";
  }

  function evoEventSummary(kind, payload) {
    const p = payload || {};
    const identity = evoEventIdentity(p);
    switch (kind) {
      case "change_requested": return `${identity} · ${cleanEvolutionReason(p.reason || "等待 Adapter 诊断")}`;
      case "change_building": return `${identity} · ${shortRelease(p.release_id)}`;
      case "change_evaluated": return `${identity} · 静态、确定性与回放门已完成`;
      case "change_canary": return `${identity} · 等待 canary 或人工批准`;
      case "change_approved": return `${identity} · 批准者 ${p.approver || "user"}`;
      case "change_activated": return `${identity} · active 环境已切换`;
      case "change_rejected": return `${identity} · ${p.reason || "未越过验证门"}`;
      case "change_rolled_back": return `${identity} · ${p.reason || "已恢复 known-good"}`;
      case "revision_advanced": return `${identity || "新 revision"} · active release 图已更新`;
      case "revision_degraded": return `${identity || "revision"} · 等待回退处理`;
      case "revision_healthy": return `${identity || "revision"} · 健康检查通过`;
      case "release_observation": return `${identity} · ${p.success ? "成功" : "失败"} · ${p.tokens || 0} tok`;
      default: return identity || "展开查看原始事件";
    }
  }


  function formatEvolutionTime(value) {
    if (!value) return "-";
    const date = new Date(value);
    if (Number.isNaN(date.getTime())) return String(value).replace("T", " ").slice(5, 16);
    return date.toLocaleString([], { month: "2-digit", day: "2-digit", hour: "2-digit", minute: "2-digit", hour12: false });
  }

  let evoBuffer = [];
  function pushEvoEvent(topic, payload) {
    evoBuffer.unshift({ topic, event: payload, at: new Date().toISOString(), source: "websocket" });
    if (evoBuffer.length > 100) evoBuffer.length = 100;
    flushEvoBuffer();
    if (MC.open && MC.tab === "evolution" && /^change_|^revision_/.test(topic)) {
      setTimeout(refreshEvoStatus, 150);
    }
  }

  function flushEvoBuffer() {
    const box = $("evo-feed");
    const pane = $("mc-evolution");
    if (!box || !pane || pane.classList.contains("hidden") || !evoBuffer.length) return;
    const empty = box.querySelector(".evo-empty");
    if (empty) empty.remove();
    evoBuffer.reverse().forEach((event) => box.prepend(evoEventEl(event)));
    evoBuffer = [];
    while (box.children.length > 100) box.removeChild(box.lastChild);
  }

  // ── @ 文件引用自动补全 ──
  let atDropdown = null;
  let atSelected = 0;
  let atItems = [];

  function initAtComplete() {
    const input = $("input");
    let atDebounce = null;

    input.addEventListener("input", () => {
      const v = input.value;
      const cursor = input.selectionStart;
      const before = v.slice(0, cursor);
      const atMatch = before.match(/@([\w\/.\-]*)$/);

      if (atMatch) {
        clearTimeout(atDebounce);
        atDebounce = setTimeout(() => showAtDropdown(atMatch[1], cursor), 200);
      } else {
        hideAtDropdown();
      }
    });

    input.addEventListener("keydown", (e) => {
      if (!atDropdown) return;
      if (e.key === "ArrowDown") { e.preventDefault(); atSelected = Math.min(atSelected + 1, atItems.length - 1); renderAtDropdown(); }
      if (e.key === "ArrowUp") { e.preventDefault(); atSelected = Math.max(atSelected - 1, 0); renderAtDropdown(); }
      if (e.key === "Tab" || e.key === "Enter") {
        if (atItems.length > 0) { e.preventDefault(); selectAtItem(atItems[atSelected]); }
      }
      if (e.key === "Escape") { hideAtDropdown(); }
    });

    // 点击其他区域关闭
    document.addEventListener("click", (e) => {
      if (atDropdown && !atDropdown.contains(e.target) && e.target !== input) hideAtDropdown();
    });
  }

  async function showAtDropdown(query, cursor) {
    try {
      const res = await rpc("files.search", { q: query });
      atItems = (res && res.files) || [];
      if (atItems.length === 0) { hideAtDropdown(); return; }
      atSelected = 0;

      if (!atDropdown) {
        atDropdown = document.createElement("div");
        atDropdown.className = "at-dropdown";
        const composer = $("composer");
        composer.style.position = "relative";
        composer.appendChild(atDropdown);
      }
      atDropdown.classList.remove("hidden");
      renderAtDropdown();
    } catch (e) { hideAtDropdown(); }
  }

  function renderAtDropdown() {
    if (!atDropdown) return;
    atDropdown.innerHTML = atItems.map((f, i) =>
      `<div class="at-item ${i === atSelected ? "selected" : ""}" data-idx="${i}">
        <span class="at-icon">${f.ext === "ex" || f.ext === "exs" ? "💧" : f.ext === "js" ? "📜" : f.ext === "md" ? "📝" : "📄"}</span>
        <span class="at-path">${escapeHtml(f.path)}</span>
      </div>`
    ).join("");
    atDropdown.querySelectorAll(".at-item").forEach((el) => {
      el.addEventListener("mousedown", (e) => { e.preventDefault(); selectAtItem(atItems[+el.dataset.idx]); });
    });
  }

  function selectAtItem(item) {
    const input = $("input");
    const v = input.value;
    const cursor = input.selectionStart;
    const before = v.slice(0, cursor);
    const after = v.slice(cursor);
    const newBefore = before.replace(/@[\w\/.\-]*$/, "@" + item.path + " ");
    input.value = newBefore + after;
    input.focus();
    input.selectionStart = input.selectionEnd = newBefore.length;
    hideAtDropdown();
  }

  function hideAtDropdown() {
    if (atDropdown) { atDropdown.classList.add("hidden"); }
    atItems = [];
  }

  // ── Mission Control 面板 ──
  const MC = {
    open: false,
    tab: "files",
    files: [],
    steps: [],
    stepCounter: 0,
    refreshTimer: null,
    stepsUnread: 0,
    filesUnread: 0,
    evoUnread: 0,
    debugOn: false,
    debugItems: [],
    debugSince: 0,
    debugTimer: 0,
    debugSelected: 0,
  };

  // 未读徽标：系统有更新时亮点，不抢焦点；用户点开对应 tab 才清除（H3 用户掌控 + 注意力瓶颈）。
  function updateMCBadges() {
    const map = { steps: MC.stepsUnread, files: MC.filesUnread, evolution: MC.evoUnread };
    Object.entries(map).forEach(([tab, n]) => {
      const el = document.getElementById("mc-badge-" + tab);
      if (!el) return;
      if (n > 0) { el.textContent = n > 99 ? "99+" : String(n); el.classList.remove("hidden"); }
      else { el.textContent = ""; el.classList.add("hidden"); }
    });
  }
  function bumpMCBadge(tab) {
    if (MC.tab === tab) return;
    if (tab === "steps") MC.stepsUnread++;
    else if (tab === "files") MC.filesUnread++;
    else if (tab === "evolution") MC.evoUnread++;
    updateMCBadges();
  }

  function initMissionControl() {
    const panel = $("mission-control");
    const expandBtn = $("mc-expand");
    const collapseBtn = $("mc-collapse");

    expandBtn.addEventListener("click", () => setMCOpen(true));
    collapseBtn.addEventListener("click", () => setMCOpen(false));

    // Tab 切换
    document.querySelectorAll(".mc-tab").forEach((btn) => {
      btn.addEventListener("click", () => switchMCTab(btn.dataset.tab));
    });

    // 文件刷新
    $("mc-files-refresh").addEventListener("click", () => refreshMCFiles());
    // 步骤清空
    $("mc-steps-clear").addEventListener("click", () => { MC.steps = []; renderMCSteps(); });
    // Diff 刷新
    $("mc-diff-refresh").addEventListener("click", () => refreshMCDiff());
    $("mc-overview-refresh").addEventListener("click", () => refreshMCOverview());
    $("mc-run-test").addEventListener("click", () => mcRunTest());
    $("mc-commit").addEventListener("click", () => mcCommit());
    $("mc-debug-toggle").addEventListener("click", () => toggleDebug());
    $("mc-debug-refresh").addEventListener("click", () => refreshDebugList(true));
    $("mc-debug-clear").addEventListener("click", () => clearDebug());
    debugStatus();

    // 恢复面板状态（含 sticky tab：用户上次停留在哪个 tab，下次还停在那）
    try {
      const savedTab = localStorage.getItem("newbee-mc-tab");
      if (savedTab && document.getElementById("mc-" + savedTab)) {
        MC.tab = savedTab;
        document.querySelectorAll(".mc-tab").forEach((b) => b.classList.toggle("active", b.dataset.tab === savedTab));
        document.querySelectorAll(".mc-pane").forEach((p) => p.classList.add("hidden"));
        document.getElementById("mc-" + savedTab).classList.remove("hidden");
      }
    } catch (e) {}
    updateMCBadges();
    const howBtn = document.getElementById("evo-how");
    if (howBtn) howBtn.addEventListener("click", () => {
      const g = document.getElementById("evo-guide");
      if (g) g.classList.toggle("hidden");
    });
    // 恢复面板状态
    try {
      const saved = localStorage.getItem("newbee-mc-open");
      if (saved === "1") setMCOpen(true);
    } catch (e) {}
  }

  function setMCOpen(open) {
    MC.open = open;
    const panel = $("mission-control");
    const expandBtn = $("mc-expand");
    if (open) {
      panel.classList.remove("hidden");
      expandBtn.classList.add("hidden");
      refreshMCFiles();
      if (MC.tab === "evolution") refreshEvolution();
      if (MC.tab === "overview") refreshMCOverview();
      if (MC.tab === "diff") refreshMCDiff();
      if (MC.tab === "debug") refreshDebugList(true);
      if ((MC.tab === "collaboration" || MC.tab === "tasks") && state.activeGroupId) markCollabSeen(state.activeGroupId);
    } else {
      panel.classList.add("hidden");
      expandBtn.classList.remove("hidden");
      stopDebugPolling();
    }
    try { localStorage.setItem("newbee-mc-open", open ? "1" : "0"); } catch (e) {}
  }

  function switchMCTab(tab) {
    MC.tab = tab;
    // sticky tab：记住用户显式选择，刷新/重进不丢失；进入即清该 tab 徽标。
    try { localStorage.setItem("newbee-mc-tab", tab); } catch (e) {}
    if (tab === "steps") MC.stepsUnread = 0;
    if (tab === "files") MC.filesUnread = 0;
    if (tab === "evolution") MC.evoUnread = 0;
    updateMCBadges();
    document.querySelectorAll(".mc-tab").forEach((b) => b.classList.toggle("active", b.dataset.tab === tab));
    document.querySelectorAll(".mc-pane").forEach((p) => p.classList.add("hidden"));
    const pane = $("mc-" + tab);
    if (pane) pane.classList.remove("hidden");
    if ((tab === "collaboration" || tab === "tasks") && state.activeGroupId) markCollabSeen(state.activeGroupId);
    if (tab === "diff") refreshMCDiff();
    if (tab === "overview") refreshMCOverview();
    if (tab === "evolution") refreshEvolution();
    if (tab === "debug") { refreshDebugList(true); if (MC.debugOn) startDebugPolling(); }
    else stopDebugPolling();
  }

  // ── Debug Tab：大模型 HTTP 往返 ──
  // 点开始：后端开始记录 + 前端每 1.5s 轮询；点停止：两边都停，省带宽与算力。
  async function debugStatus() {
    try {
      const st = await rpc("debug.status", {});
      MC.debugOn = !!(st && st.enabled);
    } catch (e) {
      MC.debugOn = false;
    }
    renderDebugStatus();
    if (MC.debugOn && MC.tab === "debug") startDebugPolling();
  }

  function renderDebugStatus() {
    const btn = $("mc-debug-toggle");
    const tip = $("mc-debug-status");
    if (btn) btn.textContent = MC.debugOn ? "停止" : "开始";
    if (tip) {
      tip.textContent = MC.debugOn
        ? "记录中，每 1.5s 自动刷新；点停止可省带宽与算力"
        : "未开始（点开始后实时记录，停止后零开销）";
      tip.classList.toggle("on", MC.debugOn);
    }
  }

  async function toggleDebug() {
    const next = !MC.debugOn;
    try {
      const r = await rpc("debug.setEnabled", { enabled: next });
      MC.debugOn = !!(r && r.enabled);
    } catch (e) {
      line("error", "切换 Debug 记录失败: " + e.message);
      return;
    }
    renderDebugStatus();
    if (MC.debugOn) {
      MC.debugSince = 0;
      MC.debugItems = [];
      MC.debugSelected = 0;
      refreshDebugList(true);
      startDebugPolling();
    } else {
      stopDebugPolling();
    }
  }

  function startDebugPolling() {
    stopDebugPolling();
    MC.debugTimer = setInterval(() => {
      if (MC.tab === "debug" && MC.debugOn) refreshDebugList(false);
    }, 1500);
  }

  function stopDebugPolling() {
    if (MC.debugTimer) { clearInterval(MC.debugTimer); MC.debugTimer = 0; }
  }

  async function refreshDebugList(reset) {
    if (reset) { MC.debugSince = 0; MC.debugItems = []; MC.debugSelected = 0; hideDebugDetail(); }
    try {
      const res = await rpc("debug.list", { limit: 30, since: MC.debugSince });
      const items = (res && res.entries) || [];
      if (items.length) {
        MC.debugItems = MC.debugItems.concat(items);
        const ids = MC.debugItems.map((x) => x.id);
        MC.debugSince = Math.max.apply(null, ids);
        if (MC.debugItems.length > 100) MC.debugItems = MC.debugItems.slice(-100);
      }
      renderDebugList();
    } catch (e) {
      if (MC.debugItems.length === 0) {
        const list = $("mc-debug-list");
        if (list) list.innerHTML = "<div style=\"color:var(--fg2);font-size:12px;padding:16px;text-align:center\">加载失败: " + escapeHtml(e.message) + "</div>";
      }
    }
  }

  function debugPhaseName(p) {
    if (p === "inflight") return "进行中";
    if (p === "done") return "完成";
    if (p === "error") return "出错";
    if (p === "interrupted") return "中断";
    return p || "-";
  }

  function fmtBytes(n) {
    if (!n && n !== 0) return "-";
    if (n < 1024) return n + "B";
    if (n < 1024 * 1024) return (Math.round(n / 102.4) / 10) + "KB";
    return (Math.round(n / 104857.6) / 10) + "MB";
  }

  function fmtMs(ms) {
    if (ms === null || ms === undefined) return "-";
    if (ms < 1000) return ms + "ms";
    return (Math.round(ms / 100) / 10) + "s";
  }

  function renderDebugList() {
    const list = $("mc-debug-list");
    if (!list) return;
    if (!MC.debugOn && MC.debugItems.length === 0) {
      list.innerHTML = "<div style=\"color:var(--fg2);font-size:12px;padding:16px;text-align:center\">未开始<br>点上面的开始按钮后，这里实时显示与大模型的 HTTP 交互</div>";
      return;
    }
    if (MC.debugItems.length === 0) {
      list.innerHTML = "<div style=\"color:var(--fg2);font-size:12px;padding:16px;text-align:center\">暂无记录<br>发一条消息后自动出现</div>";
      return;
    }
    const rows = MC.debugItems.slice().reverse().map((it) => {
      const t = it.started_at ? new Date(it.started_at).toLocaleString() : "";
      const st = it.status !== null && it.status !== undefined ? it.status : "-";
      const err = it.error ? "<div class=\"debug-item-err\">" + escapeHtml(it.error) + "</div>" : "";
      return "<div class=\"debug-item" + (MC.debugSelected === it.id ? " active" : "") + "\" data-id=\"" + it.id + "\">"
        + "<div class=\"debug-item-head\"><span class=\"debug-item-id\">#" + it.id + "</span>"
        + "<span class=\"debug-item-phase " + escapeHtml(it.phase || "") + "\">" + escapeHtml(debugPhaseName(it.phase)) + "</span>"
        + "<span class=\"debug-item-meta\">" + st + "</span>"
        + "<span class=\"debug-item-meta\">" + escapeHtml(it.endpoint || "") + "</span></div>"
        + "<div class=\"debug-item-meta\">" + escapeHtml(t) + " · " + escapeHtml(it.model || "") + " · "
        + fmtMs(it.duration_ms) + " · 上行 " + fmtBytes(it.req_bytes) + " / 下行 " + fmtBytes(it.resp_bytes) + "</div>"
        + err + "</div>";
    });
    list.innerHTML = rows.join("");
    list.querySelectorAll(".debug-item").forEach((el) => {
      el.addEventListener("click", () => showDebugDetail(parseInt(el.dataset.id, 10)));
    });
  }

  async function showDebugDetail(id) {
    MC.debugSelected = id;
    renderDebugList();
    const box = $("mc-debug-detail");
    if (!box) return;
    box.classList.remove("hidden");
    box.innerHTML = "<div class=\"debug-kv\">加载 #" + id + " …</div>";
    try {
      const res = await rpc("debug.get", { id: id });
      renderDebugDetail(res && res.entry);
    } catch (e) {
      box.innerHTML = "<div class=\"debug-kv\">加载失败: " + escapeHtml(e.message) + "</div>";
    }
  }

  function debugHeadersHtml(hs) {
    if (!hs || !hs.length) return "<div class=\"debug-kv\">（无）</div>";
    return "<div class=\"debug-kv\">" + hs.map((h) => escapeHtml(h[0]) + ": " + escapeHtml(h[1])).join("<br>") + "</div>";
  }

  function renderDebugDetail(e) {
    const box = $("mc-debug-detail");
    if (!box || !e) return;
    const t = e.started_at ? new Date(e.started_at).toLocaleString() : "";
    let h = "<div><button id=\"mc-debug-back\" class=\"btn-ghost\">← 返回列表</button></div>";
    h += "<h4>概要 #" + e.id + "</h4><div class=\"debug-kv\">"
      + escapeHtml(t) + "<br>模型 " + escapeHtml(e.model || "-") + "<br>"
      + escapeHtml(e.method || "POST") + " " + escapeHtml(e.url || e.endpoint || "") + "<br>"
      + "状态 " + escapeHtml(debugPhaseName(e.phase)) + " · HTTP " + (e.resp_status !== null && e.resp_status !== undefined ? e.resp_status : "-")
      + " · 耗时 " + fmtMs(e.duration_ms) + "<br>"
      + "上行 " + fmtBytes(e.req_bytes) + (e.req_truncated ? "（已截断）" : "")
      + " / 下行 " + fmtBytes(e.resp_bytes) + (e.resp_truncated ? "（已截断）" : "");
    if (e.session_id) h += "<br>会话 " + escapeHtml(e.session_id);
    if (e.error) h += "<br>错误 " + escapeHtml(e.error);
    h += "</div>";
    h += "<h4>请求头</h4>" + debugHeadersHtml(e.req_headers);
    h += "<h4>请求体</h4><pre>" + escapeHtml(e.req_body || "") + "</pre>";
    h += "<h4>回包头</h4>" + debugHeadersHtml(e.resp_headers);
    h += "<h4>回包体</h4><pre>" + escapeHtml(e.resp_body || "") + "</pre>";
    if (e.sse_raw) h += "<h4>SSE 原始流" + (e.sse_truncated ? "（已截断）" : "") + "</h4><pre>" + escapeHtml(e.sse_raw) + "</pre>";
    box.innerHTML = h;
    const back = $("mc-debug-back");
    if (back) back.addEventListener("click", () => hideDebugDetail());
    box.scrollIntoView({ block: "nearest" });
  }

  function hideDebugDetail() {
    MC.debugSelected = 0;
    const box = $("mc-debug-detail");
    if (box) { box.classList.add("hidden"); box.innerHTML = ""; }
  }

  async function clearDebug() {
    try {
      await rpc("debug.clear", {});
      MC.debugItems = [];
      MC.debugSince = 0;
      hideDebugDetail();
      renderDebugList();
    } catch (e) {
      line("error", "清空 Debug 记录失败: " + e.message);
    }
  }




  // ── 文件变更追踪 ──
  async function refreshMCFiles() {
    try {
      const res = await rpc("git.diffStat", {});
      MC.files = (res && res.files) || [];
      renderMCFiles();
    } catch (e) {
      // git 不可用（非 git 项目等）
      MC.files = [];
      renderMCFiles();
    }
  }

  function renderMCFiles() {
    const list = $("mc-files-list");
    const count = $("mc-files-count");
    const n = MC.files.length;
    count.textContent = n === 0 ? "无文件变更" : `${n} 个文件变更`;

    if (n === 0) {
      list.innerHTML = '<div style="color:var(--fg2);font-size:12px;padding:20px;text-align:center">工作区干净<br>暂无变更</div>';
      return;
    }

    list.innerHTML = MC.files.map((f) => {
      const cls = f.status === "new" ? "mc-file new" : "mc-file";
      const stats = f.status === "new"
        ? `<span class="mc-file-added">+${f.added}</span> <span class="mc-file-status">新文件</span>`
        : `<span class="mc-file-added">+${f.added}</span> <span class="mc-file-deleted">-${f.deleted}</span>`;
      const attribution = state.fileAttribution && state.fileAttribution[f.path];
      const owner = attribution ? `<span class="mc-file-owner">${escapeHtml(attribution.name)}</span>` : "";
      return `<div class="${cls}" data-path="${escapeHtml(f.path)}" title="点击查看 diff">
        <div class="mc-file-path">${escapeHtml(f.path)}${owner}</div>
        <div class="mc-file-stats">${stats}</div>
      </div>`;
    }).join("");

    // 点击展开 diff
    list.querySelectorAll(".mc-file").forEach((el) => {
      el.addEventListener("click", () => showFileDiff(el.dataset.path));
    });
  }

  async function showFileDiff(path) {
    switchMCTab("diff");
    const content = $("mc-diff-content");
    content.innerHTML = '<div style="color:var(--fg2);padding:20px;text-align:center">加载中…</div>';
    try {
      const res = await rpc("git.diff", { path });
      renderDiff(content, res.diff || "(无 diff)");
    } catch (e) {
      content.innerHTML = `<div style="color:#f44336;padding:20px">加载失败: ${escapeHtml(e.message)}</div>`;
    }
  }

  // ── 执行步骤时间线 ──
  function mcToolStart(p) {
    if (MC._replaying) return;
    MC.stepCounter++;
    const step = {
      id: MC.stepCounter,
      title: p.title || "run_elixir",
      code: p.code || "",
      status: "running",
      startTime: Date.now(),
      duration: null,
    };
    MC.steps.push(step);
    // 只保留最近 200 步
    if (MC.steps.length > 200) MC.steps = MC.steps.slice(-200);
    renderMCSteps();
    if (MC.open && MC.tab !== "steps") bumpMCBadge("steps");
  }

  function mcToolResult(ok, durationMs) {
    if (MC._replaying) return;
    // 更新最后一个 running 步骤
    for (let i = MC.steps.length - 1; i >= 0; i--) {
      if (MC.steps[i].status === "running") {
        MC.steps[i].status = ok ? "ok" : "err";
        MC.steps[i].duration = durationMs || (Date.now() - MC.steps[i].startTime);
        break;
      }
    }
    renderMCSteps();
    if (MC.open && MC.tab !== "steps") bumpMCBadge("steps");
    // 有文件操作时刷新文件列表（防抖）；不在文件 tab 时只亮徽标，不抢焦点。
    if (MC.open && MC.tab === "files") {
      clearTimeout(MC.refreshTimer);
      MC.refreshTimer = setTimeout(() => refreshMCFiles(), 800);
    } else if (MC.open) {
      bumpMCBadge("files");
    }
  }
  function mcOnFileChange(path) {
    // 文件变更事件 → 防抖刷新文件列表（静默，不切换 tab）
    if (MC.open) {
      clearTimeout(MC.refreshTimer);
      MC.refreshTimer = setTimeout(() => refreshMCFiles(), 600);
      if (MC.tab !== "files") bumpMCBadge("files");
    }
  }


  function renderMCSteps() {
    const list = $("mc-steps-list");
    const count = $("mc-steps-count");
    const n = MC.steps.length;
    count.textContent = n === 0 ? "无步骤" : `${n} 个步骤`;

    if (n === 0) {
      list.innerHTML = '<div style="color:var(--fg2);font-size:12px;padding:20px;text-align:center">等待 AI 执行…</div>';
      return;
    }

    // 倒序显示（最新在前）
    const reversed = [...MC.steps].reverse();
    list.innerHTML = reversed.map((s) => {
      const statusCls = s.status === "running" ? "running" : s.status === "ok" ? "ok" : "err";
      const statusIcon = s.status === "running" ? "⏳" : s.status === "ok" ? "✓" : "✗";
      const dur = s.duration ? fmtDur(s.duration) : "…";
      const codePreview = s.code ? escapeHtml(s.code.slice(0, 500)) : "";
      return `<div class="mc-step ${statusCls}" data-id="${s.id}">
        <div class="mc-step-title">${statusIcon} #${s.id} ${escapeHtml(s.title)}</div>
        <div class="mc-step-meta">${dur}</div>
        ${codePreview ? `<div class="mc-step-detail">${codePreview}</div>` : ""}
      </div>`;
    }).join("");

    // 点击展开/折叠
    list.querySelectorAll(".mc-step").forEach((el) => {
      el.addEventListener("click", () => el.classList.toggle("expanded"));
    });
  }

  // ── 全量 Diff ──
  async function refreshMCDiff() {
    const content = $("mc-diff-content");
    content.innerHTML = '<div style="color:var(--fg2);padding:20px;text-align:center">加载中…</div>';
    try {
      // 先取影响分析
      const impact = await rpc("git.impact", {}).catch(() => null);
      let impactHtml = "";
      if (impact && impact.summary) {
        const s = impact.summary;
        const riskColor = s.overall_risk === "high" ? "#f44336" : s.overall_risk === "medium" ? "#ff9800" : "#4caf50";
        const riskLabel = s.overall_risk === "high" ? "⚠ 高风险" : s.overall_risk === "medium" ? "◆ 中风险" : "● 低风险";
        impactHtml = `<div class="mc-impact">
          <div class="mc-impact-summary" style="border-left:3px solid ${riskColor}">
            <b>${riskLabel}</b> · ${s.total_files} 文件 · <span class="diff-add">+${s.total_added}</span> <span class="diff-del">-${s.total_deleted}</span>
            ${s.has_tests ? ' · ✓ 含测试' : ' · ⚠ 无测试'}
          </div>
          ${(impact.files || []).slice(0, 10).map(f => {
            const rc = f.risk === "high" ? "#f44336" : f.risk === "medium" ? "#ff9800" : "var(--fg2)";
            return `<div class="mc-impact-file" title="${f.dependent_files ? '被依赖: ' + escapeHtml(f.dependent_files.join(", ")) : ''}">
              <span style="color:${rc}">●</span> ${escapeHtml(f.path)}
              <span class="mc-impact-meta">+${f.added} -${f.deleted}${f.dependents > 0 ? ' · ' + f.dependents + ' 依赖' : ''}${f.is_test ? ' 🧪' : ''}</span>
            </div>`;
          }).join("")}
        </div><hr style="border-color:var(--border);margin:8px 0">`;
      }
      // 再取 diff
      const res = await rpc("git.diff", {});
      if (!res.diff || res.diff.trim() === "") {
        content.innerHTML = impactHtml || '<div style="color:var(--fg2);padding:20px;text-align:center">工作区干净<br>无 diff</div>';
      } else {
        renderDiff(content, res.diff);
        if (impactHtml) content.innerHTML = impactHtml + content.innerHTML;
      }
    } catch (e) {
      content.innerHTML = `<div style="color:#f44336;padding:20px">加载失败: ${escapeHtml(e.message)}</div>`;
    }
  }

  function renderDiff(container, diffText) {
    const lines = diffText.split("\n");
    const html = lines.map((line) => {
      let cls = "";
      let escaped = escapeHtml(line);
      if (line.startsWith("diff --git") || line.startsWith("index ") || line.startsWith("---") || line.startsWith("+++")) {
        cls = ' class="diff-header"';
      } else if (line.startsWith("@@")) {
        cls = ' class="diff-hunk"';
      } else if (line.startsWith("+")) {
        cls = ' class="diff-add"';
      } else if (line.startsWith("-")) {
        cls = ' class="diff-del"';
      }
      return `<div${cls}>${escaped}</div>`;
    }).join("");
    container.innerHTML = html;
  }
  // ── 会话概览 ──
  async function refreshMCOverview() {
    const content = $("mc-overview-content");
    if (!state.sid) { content.innerHTML = '<div style="color:var(--fg2);padding:20px;text-align:center">无活跃会话</div>'; return; }
    try {
      const sid = state.sid;
      const st = await rpc("session.state", { sessionId: sid });
      if (state.sid !== sid) return; // 轮询途中切了会话，丢弃旧会话数据
      const u = st.usage || {};
      const rows = [
        ["模型", (st.provider ? st.provider + "/" : "") + (st.model || "-")],
        ["状态", st.busy ? "🔴 运行中" : "🟢 空闲"],
        ["轮数 / 步数", (st.turns || 0) + " 轮 · " + (st.steps || 0) + " 步"],
        ["Bindings", st.bindings || 0],
        ["队列", st.queued || 0],
        ["输入 tokens", fmtTok(u.prompt_tokens || 0)],
        ["输出 tokens", fmtTok(u.completion_tokens || 0)],
        ["缓存命中", (() => {
          const cr = u.cache_read_tokens ?? u.cached_tokens ?? (u.prompt_tokens_details && u.prompt_tokens_details.cached_tokens);
          if (u.prompt_tokens > 0 && cr == null) return "未统计";
          return u.prompt_tokens > 0 ? ((cr || 0) / u.prompt_tokens * 100).toFixed(1) + "%" : "-";
        })()],
        ["自治档位", st.policy || "-"],
      ];
      let bindingsHtml = "";
      try {
        const bd = await rpc("session.bindings", { sessionId: sid });
        if (state.sid !== sid) return; // 同上：切会话后丢弃
        const items = (bd && bd.bindings) || [];
        if (items.length > 0) {
          bindingsHtml = '<div class="mc-bindings-title">Bindings</div>' + items.map((b) =>
            `<div class="mc-ov-row"><span class="k">${escapeHtml(b.name)}</span><span class="v">${b.type} · ${fmtTok(b.size || 0)}B</span></div>`
          ).join("");
        }
      } catch (e) { /* bindings RPC 不可用 */ }

      content.innerHTML = rows.map(([k, v]) =>
        `<div class="mc-ov-row"><span class="k">${k}</span><span class="v">${v}</span></div>`
      ).join("") + bindingsHtml;
    } catch (e) {
      content.innerHTML = `<div style="color:#f44336;padding:20px">加载失败</div>`;
    }
  }


  // ── 工作流闭环：测试 + 提交 ──
  async function mcRunTest() {
    const btn = $("mc-run-test");
    const diffContent = $("mc-diff-content");
    btn.classList.add("running");
    btn.textContent = "⏳ 运行中";
    try {
      const res = await rpc("project.test", {});
      const cls = res.passed ? "pass" : "fail";
      const icon = res.passed ? "✓ 通过" : "✗ 失败";
      diffContent.innerHTML = `<div class="mc-test-result ${cls}">
        <b>${icon}</b> · ${escapeHtml(res.cmd || "")}
        \n\n${escapeHtml(res.output || "")}
      </div>` + diffContent.innerHTML;
    } catch (e) {
      line("error", "测试运行失败: " + e.message);
    }
    btn.classList.remove("running");
    btn.textContent = "🧪 测试";
  }

  async function mcCommit() {
    const msg = prompt("提交信息:", "wip");
    if (!msg) return;
    try {
      const res = await rpc("git.commit", { message: msg });
      line("done", `已提交: ${msg}`);
      refreshMCFiles();
      refreshMCDiff();
    } catch (e) {
      line("error", "提交失败: " + e.message);
    }
  }



  // ── 全局键盘快捷键 ──
  function initGlobalKeys() {
    document.addEventListener("keydown", (e) => {
      // 不在输入框中时的快捷键
      const inInput = document.activeElement === $("input") || document.activeElement === $("cmd-input");
      const mod = e.ctrlKey || e.metaKey;

      // Escape: 中断（全局）
      if (e.key === "Escape" && state.busy && !inInput) {
        e.preventDefault();
        interrupt();
      }

      // Ctrl+M: 打开/关闭 Mission Control
      if (mod && e.key === "m" && !e.shiftKey) {
        e.preventDefault();
        setMCOpen(!MC.open);
      }

      // Ctrl+Shift+M: 打开 Mission Control 并切到进化 tab
      if (mod && e.key === "M" && e.shiftKey) {
        e.preventDefault();
        setMCOpen(true);
        switchMCTab("evolution");
      }

      // Ctrl+N: 新会话
      if (mod && e.key === "n") {
        e.preventDefault();
        newSession();
      }

      // Ctrl+1/2/3/4: 切换 MC tab（MC 打开时）
      if (mod && ["1", "2", "3", "4"].includes(e.key) && MC.open) {
        e.preventDefault();
        const tabs = ["files", "steps", "diff", "overview"];
        const tab = tabs[parseInt(e.key) - 1];
        if (tab) switchMCTab(tab);
      }

      // Ctrl+Enter: 发送（输入框中）
      if (mod && e.key === "Enter" && inInput) {
        e.preventDefault();
        send();
      }
    });
  }


  // 文件路径点击 → 当前会话工作区内只读查看
  const fileViewer = { path: null, content: "", markdown: false, mode: "source" };

  async function openFileViewer(path) {
    const modal = $("file-viewer");
    fileViewer.path = path;
    fileViewer.content = "";
    fileViewer.markdown = false;
    $("file-viewer-name").textContent = path;
    $("file-viewer-meta").textContent = "正在读取…";
    $("file-viewer-body").innerHTML = '<div class="file-viewer-state">正在读取…</div>';
    $("file-viewer-modes").classList.add("hidden");
    modal.classList.remove("hidden");

    try {
      const file = await rpc("files.read", { sessionId: state.sid, path });
      fileViewer.path = file.path;
      fileViewer.content = file.content || "";
      fileViewer.language = file.language || "text";
      fileViewer.markdown = !!file.markdown;
      fileViewer.mode = fileViewer.markdown ? "preview" : "source";
      $("file-viewer-name").textContent = file.path;
      $("file-viewer-meta").textContent = `${fileViewer.language} · ${fmtBytes(file.bytes || 0)}`;
      $("file-viewer-modes").classList.toggle("hidden", !fileViewer.markdown);
      renderFileViewer();
    } catch (error) {
      $("file-viewer-meta").textContent = "读取失败";
      $("file-viewer-body").innerHTML = `<div class="file-viewer-state error">${escapeHtml(error.message)}</div>`;
    }
  }

  function renderFileViewer() {
    const body = $("file-viewer-body");
    $("file-viewer-modes").querySelectorAll(".file-viewer-mode").forEach((button) => {
      button.classList.toggle("current", button.dataset.mode === fileViewer.mode);
    });

    if (fileViewer.markdown && fileViewer.mode === "preview") {
      body.className = "file-viewer-body file-viewer-markdown";
      body.innerHTML = renderMarkdown(fileViewer.content);
      bindCopyButtons(body);
    } else {
      body.className = "file-viewer-body file-viewer-source";
      renderSourceView(body, fileViewer.content, fileViewer.language);
    }
  }

// 源码视图：整段 hljs 高亮 + 独立行号栏（同步滚动，避免多行 token 被逐行截断）
  function renderSourceView(container, code, language) {
    container.innerHTML = "";
    const gutter = document.createElement("div");
    gutter.className = "file-source-gutter";
    const scroller = document.createElement("pre");
    scroller.className = "file-source-pre";
    const codeEl = document.createElement("code");
    codeEl.innerHTML = highlightSource(code, language);
    scroller.appendChild(codeEl);
    const lineCount = code.split("\n").length;
    for (let n = 1; n <= lineCount; n++) {
      const no = document.createElement("span");
      no.textContent = n;
      gutter.appendChild(no);
    }
    container.appendChild(gutter);
    container.appendChild(scroller);
  }


  function closeFileViewer() { $("file-viewer").classList.add("hidden"); }

  $("file-viewer-close").addEventListener("click", closeFileViewer);
  $("file-viewer").addEventListener("mousedown", (e) => { if (e.target === $("file-viewer")) closeFileViewer(); });
  $("file-viewer-modes").addEventListener("click", (e) => {
    const button = e.target.closest(".file-viewer-mode");
    if (!button) return;
    fileViewer.mode = button.dataset.mode;
    renderFileViewer();
  });
  $("file-viewer-copy").addEventListener("click", () => {
    navigator.clipboard.writeText(fileViewer.content).then(() => {
      const button = $("file-viewer-copy");
      button.textContent = "已复制";
      setTimeout(() => { button.textContent = "复制"; }, 1200);
    });
  });
  $("file-viewer-diff").addEventListener("click", () => {
    if (!fileViewer.path) return;
    closeFileViewer();
    if (!MC.open) setMCOpen(true);
    showFileDiff(fileViewer.path);
  });

  document.addEventListener("click", (e) => {
    const ref = e.target.closest(".file-ref");
    if (ref && ref.dataset.path) openFileViewer(ref.dataset.path);
  });


  // ── 命令面板 (Command Palette) ──
  const CMD_LIST = [
    { icon: "▣", name: "/compact", desc: "压缩对话历史", needsArg: false },
    { icon: "±", name: "/diff", desc: "查看当前变更", needsArg: false },
    { icon: "◈", name: "/model", desc: "切换模型 (provider/model-id)", needsArg: true },
    { icon: "↩", name: "/undo", desc: "回滚到上一快照", needsArg: false },
    { icon: "#", name: "/tokens", desc: "Token 用量详情", needsArg: false },
    { icon: "⛓", name: "/bindings", desc: "查看绑定变量", needsArg: false },
    { icon: "≡", name: "/status", desc: "环境状态", needsArg: false },
    { icon: "◎", name: "/goal", desc: "设置自主目标", needsArg: true },
    { icon: "↻", name: "/evolve", desc: "投递进化需求", needsArg: true },
    { icon: "⚙", name: "/tools", desc: "查看工具库", needsArg: false },
    { icon: "⌂", name: "/environment", desc: "环境版本图", needsArg: true },
    { icon: "◉", name: "/snapshot", desc: "环境快照", needsArg: false },
    { icon: "⏪", name: "/rollback", desc: "环境回退", needsArg: true },
    { icon: "⚿", name: "/permissions", desc: "权限档位", needsArg: true },
    { icon: "⚖", name: "/autonomy", desc: "自治档位", needsArg: true },
    { icon: "▤", name: "/dump", desc: "环境自画像", needsArg: false },
    { icon: "☰", name: "/log", desc: "事件日志", needsArg: false },
    { icon: "✓", name: "/approve", desc: "批准待审变更", needsArg: true },
    { icon: "✗", name: "/reject", desc: "拒绝待审变更", needsArg: true },
    { icon: "⟳", name: "/reset", desc: "重置 evaluator", needsArg: false },
    { icon: "▣", name: "/session", desc: "会话管理", needsArg: true },
    { icon: "⊕", name: "/attach", desc: "接回 daemon", needsArg: false },
    { icon: "🆕", name: "/new", desc: "新会话", needsArg: false },
    { icon: "⌂", name: "/init", desc: "初始化项目", needsArg: false },
  ];

  let cmdSelected = 0;

  function initCmdPalette() {
    const palette = $("cmd-palette");
    const input = $("cmd-input");
    const list = $("cmd-list");

    // Ctrl+K 或 Ctrl+P 打开
    document.addEventListener("keydown", (e) => {
      if ((e.ctrlKey || e.metaKey) && (e.key === "k" || e.key === "p")) {
        e.preventDefault();
        openCmdPalette();
      }
      if (e.key === "Escape" && !palette.classList.contains("hidden")) {
        closeCmdPalette();
      }
    });

    // 输入框中输入 "/" 开头时提示
    $("input").addEventListener("input", () => {
      const v = $("input").value;
      if (v === "/") openCmdPalette();
    });

    input.addEventListener("input", () => renderCmdList(input.value));
    input.addEventListener("keydown", (e) => {
      if (e.key === "ArrowDown") { e.preventDefault(); cmdSelected = Math.min(cmdSelected + 1, filteredCmds().length - 1); renderCmdList(input.value); }
      if (e.key === "ArrowUp") { e.preventDefault(); cmdSelected = Math.max(cmdSelected - 1, 0); renderCmdList(input.value); }
      if (e.key === "Enter") {
        e.preventDefault();
        const cmds = filteredCmds();
        if (cmds[cmdSelected]) selectCmd(cmds[cmdSelected]);
      }
    });

    // 点击空白关闭
    palette.addEventListener("click", (e) => {
      if (e.target === palette) closeCmdPalette();
    });
  }

  function openCmdPalette() {
    const palette = $("cmd-palette");
    const input = $("cmd-input");
    palette.classList.remove("hidden");
    input.value = "";
    cmdSelected = 0;
    renderCmdList("");
    input.focus();
  }

  function closeCmdPalette() {
    $("cmd-palette").classList.add("hidden");
  }

  function filteredCmds() {
    const q = $("cmd-input").value.toLowerCase().replace(/^\//, "");
    if (!q) return CMD_LIST;
    return CMD_LIST.filter((c) => c.name.toLowerCase().includes(q) || c.desc.toLowerCase().includes(q));
  }

  function renderCmdList(query) {
    const list = $("cmd-list");
    const cmds = filteredCmds();
    if (cmds.length === 0) {
      list.innerHTML = '<div style="padding:20px;text-align:center;color:var(--fg2)">无匹配命令</div>';
      return;
    }
    list.innerHTML = cmds.map((c, i) =>
      `<div class="cmd-item ${i === cmdSelected ? "selected" : ""}" data-idx="${i}">
        <span class="cmd-icon">${c.icon}</span>
        <span class="cmd-name">${c.name}</span>
        <span class="cmd-desc">${c.desc}</span>
      </div>`
    ).join("");
    list.querySelectorAll(".cmd-item").forEach((el) => {
      el.addEventListener("click", () => selectCmd(cmds[+el.dataset.idx]));
    });
  }

  function selectCmd(cmd) {
    closeCmdPalette();
    const input = $("input");
    if (cmd.needsArg) {
      input.value = cmd.name + " ";
      input.focus();
    } else {
      input.value = cmd.name;
      input.focus();
      // 无参数命令直接发送
      send();
    }
  }


  // ── 登录认证（远程模式）──
  function setToken(tok) {
    state.token = tok;
    try {
      if (tok) localStorage.setItem("newbee.token", tok);
      else localStorage.removeItem("newbee.token");
    } catch (e) {}
    updateLogoutBtn();
  }
  // 已登录（有 token）时显示登出按钮；登出/未登录时隐藏
  function updateLogoutBtn() {
    const b = $("logout-btn");
    if (b) b.classList.toggle("hidden", !state.token);
  }
  async function doLogout() {
    try { await rpc("auth.logout", {}); } catch (e) { /* 即使失败也本地登出 */ }
    if (state.ws) { try { state.ws.close(); } catch (e) {} state.ws = null; }
    setToken(null);
    updateLogoutBtn();
    showLogin();
  }

  function showLogin() {
    const ov = $("login-overlay");
    if (ov) ov.classList.remove("hidden");
    refreshCaptcha();
    const pw = $("login-password");
    if (pw) setTimeout(() => pw.focus(), 50);
  }
  function hideLogin() {
    const ov = $("login-overlay");
    if (ov) ov.classList.add("hidden");
    loginError("");
  }
  function loginError(msg) {
    const el = $("login-error");
    if (!el) return;
    if (msg) { el.textContent = msg; el.classList.remove("hidden"); }
    else { el.textContent = ""; el.classList.add("hidden"); }
  }
  let captchaLastRefresh = 0;
  const CAPTCHA_MIN_INTERVAL_MS = 30_000; // 验证码最短展示 30s，避免频繁换图
  async function refreshCaptcha(force) {
    const now = Date.now();
    if (!force && captchaLastRefresh && now - captchaLastRefresh < CAPTCHA_MIN_INTERVAL_MS) return;
    try {
      const r = await rpc("auth.captcha", {});
      const img = $("login-captcha-img");
      if (img && r.svg) {
        captchaLastRefresh = now;
        img.dataset.captchaId = r.captchaId;
        img.src = "data:image/svg+xml;base64," + btoa(unescape(encodeURIComponent(r.svg)));
      }
    } catch (e) { /* 后端可能未要求认证 */ }
  }
  async function submitLogin() {
    const pw = ($("login-password") || {}).value || "";
    const cap = ($("login-captcha") || {}).value || "";
    const capId = (($("login-captcha-img") || {}).dataset || {}).captchaId || "";
    loginError("");
    if (!pw) { loginError("请输入密码"); return; }
    try {
      const st = await rpc("auth.status", {});
      let r;
      if (!st.password_set) {
        r = await rpc("auth.setup", { password: pw });
      } else {
        r = await rpc("auth.login", { password: pw, captchaId: capId, captcha: cap });
      }
      setToken(r.token);
      hideLogin();
      bootApp();
      maybePromptWebAuthnRegister();
    } catch (e) {
      loginError(e.message || "登录失败");
      refreshCaptcha(true); // 旧验证码提交一次即焚，失败必须强制换新
      const capEl = $("login-captcha");
      if (capEl) capEl.value = "";
    }
  }

  // 密码登录成功后：设备支持且无凭据 → 主动提示注册通行密钥
  async function maybePromptWebAuthnRegister() {
    if (!webAuthnSupported()) return;
    try {
      const r = await rpc("webauthn.has_credentials", {});
      if (r.has_credentials) return;
      setTimeout(() => {
        if (confirm("🎉 登录成功！\n\n这台设备支持指纹/面容登录。是否现在注册通行密钥？\n注册后下次可一键登录，无需密码。")) {
          const name = prompt("给这台设备起个名字：", "我的设备");
          if (name !== null) doWebAuthnRegister(name || "我的设备");
        }
      }, 800);
    } catch (e) { /* 忽略 */ }
  }
  function initLogin() {
    const sub = $("login-submit");
    if (sub) sub.addEventListener("click", submitLogin);
    const capImg = $("login-captcha-img");
    if (capImg) capImg.addEventListener("click", refreshCaptcha);
    for (const id of ["login-password", "login-captcha"]) {
      const el = $(id);
      if (el) el.addEventListener("keydown", (e) => { if (e.key === "Enter") submitLogin(); });
    }
    const lo = $("logout-btn");
    if (lo) lo.addEventListener("click", doLogout);
    initWebAuthn();
    initPairLogin();
    initQuickAccess();
  }

  // ── 扫码授权登录（手机替电脑"盖章"）──
  // 二维码只含服务器基址+配对码；配对码由服务端从 ETS 核对、一次性消费，不经 RPC 回传。
  var pairPollTimer = 0;
  var pairCurrentId = null;

  function pairIsMobile() {
    return window.matchMedia("(max-width: 768px)").matches ||
      /Android|iPhone|iPad|Mobile/i.test(navigator.userAgent || "");
  }
  function pairQRSupported() { return typeof window.qrcode === "function"; }
  function pairOrigin() { return location.origin; }

  function initPairLogin() {
    if (pairIsMobile()) return; // 手机端是"盖章的人"，不显示扫码块
    var sec = $("pair-section");
    if (!sec) return;
    sec.classList.remove("hidden");
    var btn = $("pair-show");
    var loginBox = $("login-box");
    if (btn) btn.addEventListener("click", function() {
      var box = $("pair-box");
      if (box.classList.contains("hidden")) {
        startPairLogin();
        if (loginBox) loginBox.classList.add("pair-open");
      } else {
        stopPairLogin();
        box.classList.add("hidden");
        if (loginBox) loginBox.classList.remove("pair-open");
      }
    });
    var refresh = $("pair-refresh");
    if (refresh) refresh.addEventListener("click", function(){ startPairLogin(); });
    // 点二维码本体也可刷新（重新生成新码）
    var qrBox = document.querySelector(".pair-qr");
    if (qrBox) qrBox.addEventListener("click", function(){ startPairLogin(); });
  }

  var pairAutoTimer = 0;   // 到期自动换新码
  var pairAutoArmed = false;

  async function startPairLogin() {
    stopPairLogin();
    pairAutoArmed = true;
    await newPairCode();          // 初始手动：立即出一张
  }

  // 生成一张新二维码；manual=false 表示"到期自动续"
  async function newPairCode(manual) {
    if (pairPollTimer) { clearInterval(pairPollTimer); pairPollTimer = 0; }
    var box = $("pair-box");
    var qrEl = document.querySelector(".pair-qr");
    var refreshBtn = $("pair-refresh");
    box.classList.remove("hidden");
    refreshBtn.classList.add("hidden");
    qrEl.innerHTML = "";
    pairSetStatus(manual === false ? "二维码已过期，正在自动刷新…" : "正在生成二维码…");
    try {
      var r = await rpc("pair.create", {});
      var pairingId = r.pairing_id;
      pairCurrentId = pairingId;
      // 二维码塞配对码 code（一次性、仅服务端核对），绝不能塞 pairing_id
      var url = pairOrigin() + "/pair?c=" + encodeURIComponent(r.code);
      renderPairQR(qrEl, url);
      pairSetStatus("用已登录的手机扫码，确认后这台电脑即可登录（点击二维码可刷新）");
      var ttl = r.ttl_ms || 150000;
      var deadline = Date.now() + ttl;
      pairPollTimer = setInterval(function(){ pollPair(pairingId, deadline); }, 1500);
      // 到期自动换新码（提前 2s，避开边界）；只排一次，生成后再排下一次
      schedulePairAuto(ttl);
    } catch (e) {
      pairSetStatus("生成失败: " + (e.message || e));
      refreshBtn.classList.remove("hidden");
    }
  }

  function schedulePairAuto(ttl) {
    if (pairAutoTimer) clearTimeout(pairAutoTimer);
    pairAutoTimer = setTimeout(function(){
      // 扫码块仍开着且未被拒绝/授权时，自动续一张新码
      if (pairAutoArmed && pairCurrentId) { newPairCode(false); }
    }, Math.max((ttl || 150000) - 2000, 10000));
  }

  function renderPairQR(el, text) {
    if (!pairQRSupported()) {
      el.innerHTML = "";
      var a = document.createElement("a");
      a.href = text; a.textContent = text; a.style.wordBreak = "break-all";
      el.appendChild(a);
      return;
    }
    try {
      var qr = window.qrcode(0, "M");
      qr.addData(text);
      qr.make();
      el.innerHTML = qr.createSvgTag({ cellSize: 5, margin: 2, scalable: true });
      var svg = el.querySelector("svg");
      if (svg) { svg.removeAttribute("width"); svg.removeAttribute("height"); }
    } catch (e) { el.textContent = text; }
  }

  async function pollPair(pairingId, deadline) {
    if (pairingId !== pairCurrentId) { stopPairLogin(); return; }
    if (Date.now() > deadline) {
      // 交给自动刷新；仅提示，不清会话
      pairSetStatus("二维码已过期，正在自动刷新…");
      return;
    }
    try {
      var r = await rpc("pair.status", { pairing_id: pairingId });
      if (pairingId !== pairCurrentId) return;
      if (r.status === "approved" && r.token) {
        stopPairLogin();
        pairSetStatus("✓ 已授权，正在登录…");
        setToken(r.token);
        hideLogin();
        bootApp();
      } else if (r.status === "scanned") {
        pairSetStatus("手机已扫码，请在手机上确认…");
      } else if (r.status === "denied") {
        stopPairLogin();
        pairSetStatus("手机已拒绝，请重新生成");
        $("pair-refresh").classList.remove("hidden");
      } else if (r.status === "expired") {
        // 自动刷新接管：schedulePairAuto 会很快换上新码，这里只提示
        pairSetStatus("二维码已过期，正在自动刷新…");
      }
    } catch (e) {
      stopPairLogin();
      pairSetStatus("配对已失效，请刷新");
      $("pair-refresh").classList.remove("hidden");
    }
  }

  function pairSetStatus(msg) {
    var el = $("pair-status");
    if (el) el.textContent = msg;
  }
  function stopPairLogin() {
    if (pairPollTimer) { clearInterval(pairPollTimer); pairPollTimer = 0; }
    if (pairAutoTimer) { clearTimeout(pairAutoTimer); pairAutoTimer = 0; }
    pairAutoArmed = false;
    pairCurrentId = null;
  }


  // ── WebAuthn 指纹/面容登录 ──

  function webAuthnSupported() {
    return window.PublicKeyCredential !== undefined && typeof window.PublicKeyCredential === "function";
  }

  // ArrayBuffer → base64url（无 padding），用于 WebAuthn 字段回传服务端
  function b64urlEncode(buf) {
    return btoa(String.fromCharCode(...new Uint8Array(buf)))
      .replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
  }

  async function initWebAuthn() {
    if (!webAuthnSupported()) return;

    try {
      const r = await rpc("webauthn.has_credentials", {});
      if (r.has_credentials) {
        $("webauthn-section").classList.remove("hidden");
        $("webauthn-login").addEventListener("click", doWebAuthnLogin);
        $("webauthn-manage-link").addEventListener("click", (e) => { e.preventDefault(); showWebAuthnManage(); });
      } else {
        // 没有凭据：检查是否已登录（有 token），已登录则显示"注册通行密钥"入口
        if (state.token) {
          showWebAuthnRegisterHint();
        }
      }
    } catch (e) {
      console.warn("WebAuthn 初始化失败:", e);
    }
  }

  function showWebAuthnRegisterHint() {
    // 已登录但无凭据：在登录界面显示注册提示（不遮挡主流程，仅提示）
    console.log("[WebAuthn] 已登录但无凭据，可在设置中注册通行密钥");
  }

  async function doWebAuthnLogin() {
    try {
      loginError("");
      const ch = await rpc("webauthn.login_challenge", {});

      const publicKey = {
        challenge: Uint8Array.from(atob(ch.challenge.replace(/-/g, "+").replace(/_/g, "/")), c => c.charCodeAt(0)),
        timeout: ch.timeout,
        rpId: ch.rp_id,
        allowCredentials: ch.allow_credentials.map(c => ({
          type: c.type,
          id: Uint8Array.from(atob(c.id.replace(/-/g, "+").replace(/_/g, "/")), c => c.charCodeAt(0))
        })),
        userVerification: ch.user_verification
      };

      const assertion = await navigator.credentials.get({ publicKey });

      const r = await rpc("webauthn.login", {
        challenge_id: ch.challenge_id,
        credential_id: b64urlEncode(assertion.rawId),
        authenticator_data: b64urlEncode(assertion.response.authenticatorData),
        signature: b64urlEncode(assertion.response.signature),
        client_data_json: b64urlEncode(assertion.response.clientDataJSON)
      });

      setToken(r.token);
      hideLogin();
      bootApp();
    } catch (e) {
      if (e.name === "NotAllowedError") {
        loginError("指纹/面容验证未完成：可能是用户取消，或浏览器因证书不受信任/域名不匹配直接拒绝了请求（详见浏览器控制台）");
      } else {
        loginError((e.name || "Error") + ": " + (e.message || "指纹/面容登录失败"));
      }
    }
  }

  async function showWebAuthnManage() {
    // 简单弹窗：列出凭据 + 删除 + 注册新凭据
    const modal = document.createElement("div");
    modal.className = "webauthn-modal-overlay";
    modal.innerHTML = `
      <div class="webauthn-modal">
        <div class="webauthn-modal-header">
          <h3>通行密钥管理</h3>
          <button class="webauthn-modal-close">×</button>
        </div>
        <div class="webauthn-modal-body">
          <div id="webauthn-cred-list" class="webauthn-cred-list">加载中...</div>
          <button id="webauthn-register-new" class="btn-primary" style="width:100%;margin-top:16px;">注册新设备</button>
        </div>
      </div>
    `;
    document.body.appendChild(modal);

    // 加载凭据列表
    loadWebAuthnCredentials();

    // 关闭
    modal.querySelector(".webauthn-modal-close").addEventListener("click", () => modal.remove());
    modal.addEventListener("click", (e) => { if (e.target === modal) modal.remove(); });

    // 注册新设备
    modal.querySelector("#webauthn-register-new").addEventListener("click", async () => {
      const name = prompt("给这台设备起个名字（如：我的 iPhone）:", "未命名设备");
      if (!name) return;
      await doWebAuthnRegister(name);
      modal.remove();
    });
  }

  async function loadWebAuthnCredentials() {
    try {
      const r = await rpc("webauthn.list", {});
      const listEl = document.getElementById("webauthn-cred-list");
      if (r.credentials.length === 0) {
        listEl.innerHTML = "<div class='webauthn-empty'>暂无已注册的设备</div>";
        return;
      }
      listEl.innerHTML = r.credentials.map(c => `
        <div class="webauthn-cred-item">
          <div class="webauthn-cred-info">
            <div class="webauthn-cred-name">${c.name}</div>
            <div class="webauthn-cred-meta">
              注册于 ${new Date(c.created_at).toLocaleDateString()}
              ${c.last_used_at ? " · 最近使用 " + new Date(c.last_used_at).toLocaleDateString() : ""}
            </div>
          </div>
          <button class="btn-ghost webauthn-cred-delete" data-cred-id="${c.credential_id}">删除</button>
        </div>
      `).join("");

      // 绑定删除按钮
      listEl.querySelectorAll(".webauthn-cred-delete").forEach(btn => {
        btn.addEventListener("click", async () => {
          if (!confirm("确定删除这台设备的通行密钥吗？删除后该设备将无法用指纹/面容登录。")) return;
          await rpc("webauthn.delete", { credential_id: btn.dataset.credId });
          loadWebAuthnCredentials();
        });
      });
    } catch (e) {
      console.error("加载凭据列表失败:", e);
      const listEl = document.getElementById("webauthn-cred-list");
      if (listEl) {
        listEl.innerHTML = "<div class='webauthn-empty'>加载失败: " + (e.message || "未知错误") + "</div>";
        if (String(e.message).includes("\u672a\u767b\u5f55")) {
          const overlay = listEl.closest(".webauthn-modal-overlay");
          if (overlay) overlay.remove();
        }
      }
    }
  }

  async function doWebAuthnRegister(name) {
    try {
      const ch = await rpc("webauthn.register_challenge", { name });

      const publicKey = {
        challenge: Uint8Array.from(atob(ch.challenge.replace(/-/g, "+").replace(/_/g, "/")), c => c.charCodeAt(0)),
        rp: ch.rp,
        user: {
          id: Uint8Array.from(atob(ch.user.id.replace(/-/g, "+").replace(/_/g, "/")), c => c.charCodeAt(0)),
          name: ch.user.name,
          displayName: ch.user.display_name
        },
        pubKeyCredParams: ch.pub_key_cred_params,
        timeout: ch.timeout,
        attestation: ch.attestation,
        authenticatorSelection: ch.authenticator_selection
      };

      const credential = await navigator.credentials.create({ publicKey });

      await rpc("webauthn.register", {
        challenge_id: ch.challenge_id,
        credential_id: b64urlEncode(credential.rawId),
        attestation_object: b64urlEncode(credential.response.attestationObject),
        client_data_json: b64urlEncode(credential.response.clientDataJSON)
      });

      alert("✅ 通行密钥注册成功！下次登录可使用指纹/面容。");
    } catch (e) {
      if (e.name === "NotAllowedError") {
        // NotAllowedError 不一定是用户取消：浏览器在证书不受信任（自签/告警页放行）、
        // RP ID 与站点不匹配、或用户超时未操作时都抛这个错。给出可操作的信息而不是误导。
        const hint = "浏览器没有弹出指纹/面容验证就拒绝了通行密钥。\n\n" +
          "常见原因：\n" +
          "1. 当前站点证书不受信任（自签名证书，浏览器地址栏有⚠警告）；\n" +
          "2. 访问域名与证书/RP ID 不匹配（如 nip.io 直连内网 IP）；\n" +
          "3. 验证弹窗超时未操作。\n\n" +
          "请改用受信任的证书（或反向代理）访问本服务后再注册。\n" +
          "浏览器详情: " + (e.message || "NotAllowedError");
        alert("通行密钥注册被浏览器拒绝\n\n" + hint);
      } else if (e.name === "InvalidStateError") {
        alert("这台设备已注册过通行密钥，无需重复注册。");
      } else {
        alert("注册失败: " + (e.name || "Error") + ": " + (e.message || e));
      }
    }
  }

  // 实际启动逻辑（登录成功后或免认证时调用）
  async function bootApp() {
    initTheme();
    initSidebar();
    initEvolution();
    initMissionControl();
    initCmdPalette();
    initGlobalKeys();
    initAtComplete();
    initGroups();
    await loadGroups();
    const host = await rpc("host.describe", {});
    $("model-label").textContent = host.model || "(no model)";
    if (!state.sid) {
      await newSession();
    } else {
      await resume(state.sid);
    }
    loadSessions();
    startStats();
  }

  // ── 启动 ──
  (async () => {
    initLogin();
    updateLogoutBtn();
    await redeemQuickAccess();

    try {
      const auth = await rpc("auth.status", {});

      if (auth.auth_required && !auth.authenticated) {
        if (state.token) setToken(null);
        showLogin();
        return;
      }

      hideLogin();
      await bootApp();
    } catch (e) {
      showLogin();
      loginError(`无法确认登录状态: ${e.message}`);
    }
  })();
  // ── 手机扫码免登录进入（Quick Access）──
  // 电脑端已登录 → 生成一次性邀请码 → 二维码 URL 带 ?qk=CODE；
  // 手机扫码打开后本函数把码换成正式 token，免登录直接进入。
  function qaQRSupported() { return typeof window.qrcode === "function"; }

  async function redeemQuickAccess() {
    try {
      const qk = new URLSearchParams(location.search).get("qk");
      if (!qk) return;
      // 清掉 URL 里的码，避免 token 换好后刷新页面又兑一次（码已焚，会报错）
      const cleanUrl = location.origin + location.pathname;
      history.replaceState(null, "", cleanUrl);
      const r = await rpc("quick_access.redeem", { code: qk });
      if (r && r.token) {
        setToken(r.token);
        // 只完成登录态：外层启动块检测到 needAuth && state.token 后会自动 bootApp
        hideLogin();
        updateLogoutBtn();
        return;
      }
    } catch (e) {
      // 码无效/过期：不阻塞，走正常登录流程
    }
  }

  function qaIsMobile() {
    return window.matchMedia("(max-width: 768px)").matches ||
      /Android|iPhone|iPad|Mobile/i.test(navigator.userAgent || "");
  }
  function initQuickAccess() {
    // 手机端不展示"手机扫码"按钮（手机本身就是扫码方）
    if (qaIsMobile()) return;
    document.querySelectorAll("#qa-show, .qa-topbar, .qa-top-text").forEach((el) => {
      el.addEventListener("click", () => openQuickAccess());
    });
  }

  // 弹窗状态
  var qaTimer = 0;
  var qaCurrent = null;
  var qaDeadline = 0;

  function openQuickAccess() {
    const ov = $("qa-overlay");
    if (!ov) return;
    ov.classList.remove("hidden");
    qaGenerate(false);
    const close = $("qa-close");
    if (close) close.addEventListener("click", closeQuickAccess);
    const refresh = $("qa-refresh");
    if (refresh) refresh.addEventListener("click", () => qaGenerate(true));
    ov.addEventListener("click", function(e) {
      if (e.target === ov) closeQuickAccess();
    });
  }

  function closeQuickAccess() {
    const ov = $("qa-overlay");
    if (ov) ov.classList.add("hidden");
    if (qaTimer) { clearInterval(qaTimer); qaTimer = 0; }
    qaCurrent = null;
    qaDeadline = 0;
    const refresh = $("qa-refresh");
    if (refresh) refresh.classList.add("hidden");
  }

  async function qaGenerate(manual) {
    if (qaTimer) { clearInterval(qaTimer); qaTimer = 0; }
    const qrEl = document.querySelector(".qa-qr");
    const status = $("qa-status");
    const refresh = $("qa-refresh");
    const expire = $("qa-expire");
    if (!qrEl) return;
    qaSetStatus("正在生成二维码…");
    if (refresh) refresh.classList.add("hidden");
    if (expire) expire.textContent = "";
    try {
      const r = await rpc("quick_access.create", {});
      qaCurrent = r.code;
      var url = location.origin + "/?qk=" + encodeURIComponent(r.code);
      if (!qaQRSupported()) {
        qrEl.innerHTML = "";
        const a = document.createElement("a");
        a.href = url; a.textContent = url; a.style.wordBreak = "break-all";
        qrEl.appendChild(a);
      } else {
        try {
          const qr = window.qrcode(0, "M");
          qr.addData(url);
          qr.make();
          qrEl.innerHTML = qr.createSvgTag({ cellSize: 5, margin: 2, scalable: true });
          const svg = qrEl.querySelector("svg");
          if (svg) { svg.removeAttribute("width"); svg.removeAttribute("height"); }
        } catch (e) { qrEl.textContent = url; }
      }
      qaDeadline = Date.now() + (r.ttl_ms || 600000);
      qaSetStatus("用手机扫码，即可免登录打开 newbee");
      var ttl = r.ttl_ms || 600000;
      var mm = Math.floor(ttl / 60000), ss = Math.floor(ttl % 60000 / 1000);
      if (expire) expire.textContent = "有效期 " + mm + " 分 " + ss + " 秒";
      qaTimer = setInterval(() => {
        if (Date.now() > qaDeadline) {
          clearInterval(qaTimer); qaTimer = 0;
          qaSetStatus("二维码已失效，请点击下方按钮重新生成");
          if (refresh) refresh.classList.remove("hidden");
        }
      }, 1000);
    } catch (e) {
      qaSetStatus("生成失败: " + (e.message || e));
      if (refresh) refresh.classList.remove("hidden");
    }
  }

  function qaSetStatus(msg) {
    const el = $("qa-status");
    if (el) el.textContent = msg;
  }

})();


// ── 手机端适配增强 ──
(function() {
  function isMobile() { return window.matchMedia("(max-width: 768px)").matches; }

  // 手机端每次加载都强制收起侧栏：
  // 避免延续桌面/上次的"展开态"，否则全屏遮罩(z-index:35)会常驻盖住 composer，
  // 导致按钮可见但点不了（点击全被遮罩拦截）。
  if (isMobile()) {
    document.getElementById("app").classList.add("sidebar-collapsed");
    var ex = document.getElementById("sidebar-expand");
    if (ex) ex.classList.remove("hidden");
  }

  // 遮罩/侧栏外点击关闭（手机端）：
  // 点在任何 #sidebar 外的内容区时收起；但排除侧栏内 toggle 触发（它本来就会收起）
  document.addEventListener("click", function(e) {
    var app = document.getElementById("app");
    if (!isMobile() || app.classList.contains("sidebar-collapsed")) return;
    var t = e.target;
    if (!t.closest || t.closest("#sidebar") || t.closest("#sidebar-expand")) return;
    // 输入区/思考强度等是操作区，点击不应收起侧栏
    if (t.closest("#composer") || t.closest(".composer-effort")) return;
    applySidebar(true, true);
  });

  // 播放时旋转到横屏提醒（可选，轻量）
  window.addEventListener("resize", function() {
    if (isMobile()) {
      // no-op: 保持 CSS 响应
    }
  });
})();
