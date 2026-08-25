/* newbee WebUI 前端（移植 dsh client/web 会话 shell 语义，无构建依赖原生 JS）。
 * 信道：REST RPC（POST /api/<method>）+ WebSocket 事件下行（/ws?session=）。 */
(() => {
  const ICO_FOLDER = '<svg viewBox="0 0 24 24" width="12" height="12" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" style="vertical-align:-1px"><path d="M3 8V6a2 2 0 0 1 2-2h4l2 2h8a2 2 0 0 1 2 2v2"/><path d="M3 8l2.4 9.1A2 2 0 0 0 7.3 19h12.2a1 1 0 0 0 1-1.3L18 11H5L3 8z"/></svg>';
  const ICO_SIDEBAR_COLLAPSE = '<svg class="ico" viewBox="0 0 24 24" width="15" height="15" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><rect width="18" height="18" x="3" y="3" rx="3"/><path d="M9 3v18"/><path d="m16 15-3-3 3-3"/></svg>';
  const ICO_SIDEBAR_EXPAND = '<svg class="ico" viewBox="0 0 24 24" width="15" height="15" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><rect width="18" height="18" x="3" y="3" rx="3"/><path d="M9 3v18"/><path d="m14 9 3 3-3 3"/></svg>';
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
    creatingSession: false,  // 新建会话防重入：点击后立即切换 UI，后台完成 RPC
    hasPrompted: false,      // 当前会话是否已有用户消息（用于首条消息自动标题）
    titleDirty: false,       // 本轮结束后刷新侧栏标题（首条消息自动命名）
    currentAssistant: null,   // 流式 assistant 行
    currentReasoning: null,   // 流式 reasoning disclosure 元素
    currentTool: null,        // 进行中的 tool 卡片
    timing: { llmMs: 0, toolMs: 0, llmStart: null, toolStart: null,
              ftSum: 0, ftCount: 0, ftRecorded: false, outTok: 0 },
    attachments: [],   // [{name, type, dataUrl, size}]
    stickBottom: true,
  };

  // ── 会话统计持久化（按 sessionId 存 localStorage，刷新/重连后保留）──
  const statsKey = (sid) => "newbee.stats." + sid;
  function saveTiming() {
    if (!state.sid) return;
    try { localStorage.setItem(statsKey(state.sid), JSON.stringify(state.timing)); } catch (e) {}
  }
  function loadTiming(sid) {
    try {
      const raw = localStorage.getItem(statsKey(sid));
      if (!raw) return;
      const saved = JSON.parse(raw);
      if (saved && typeof saved === "object") {
        state.timing = { llmMs: 0, toolMs: 0, llmStart: null, toolStart: null,
                         ftSum: 0, ftCount: 0, ftRecorded: false, outTok: 0, ...saved };
        // 活动计时器跨刷新无意义，置空
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
  function trackTiming(kind, p) {
    const t = state.timing, now = Date.now();
    switch (kind) {
      case "text":
      case "reasoning":
        if (t.llmStart === null) t.llmStart = now;
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
    if (ms > 0 && s < 0.05) return "<0.1s";
    if (s < 60) return (Math.round(s * 10) / 10) + "s";
    const w = Math.round(s);
    return Math.floor(w / 60) + "m" + (w % 60) + "s";
  }

  // ── 事件 → 渲染 ──
  function onEvent(kind, p) {
    trackTiming(kind, p);
    switch (kind) {
      case "text": appendStream(p.delta); break;
      case "reasoning": appendReasoning(p.delta); break;
      case "tool_start": toolStart(p); break;
      case "tool_result": toolResult(p.text, true, p.duration_ms); break;
      case "tool_error": toolResult(p.text, false); break;
case "done": finishTurn(); line("done", p.summary, true); break;
      case "ask": finishTurn(); line("ask", p.question); break;
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
      case "permission_ask": showPermission(p.preview); break;
      case "usage": setUsage(p.usage); break;
      case "compacted": line("notice", `历史已压缩 ${p.count} 条`); break;
      case "model_switched": $("model-label").textContent = p.model; break;
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
case "notice": line("notice", p.text); break;
case "shell_result": shellResult(p); break;
case "file_diff": fileDiff(p); break;
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
      state.currentAssistant.innerHTML = renderMarkdown(streamAcc);
      bindCopyButtons(state.currentAssistant);
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
      // 首条用户消息后同步侧栏标题（服务端 list 用首条 user 消息自动取题）
      loadSessions().catch(() => {});
    }
  }

  function el(cls, text, md) {
    const d = document.createElement("div");
    d.className = `msg ${cls}`;
    if (text) { if (md) d.innerHTML = renderMarkdown(text); else d.textContent = text; }
    flow.appendChild(d);
    return d;
  }

  function line(kind, text, md) {
    el(`msg-${kind}`, text || "", md);
    scrollBottom();
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
      state.currentAssistant.innerHTML = renderMarkdown(streamAcc);
      bindCopyButtons(state.currentAssistant);
      state.currentAssistant = null;
      streamAcc = "";
    }
  let streamAcc = "";
  let streamRaf = 0;
  function appendStream(delta) {
    // 文本到来时归档 reasoning（去 running，下次 reasoning 开新块）
    archiveReasoning();
    if (!state.currentAssistant) {
      state.busy = true; setBusy(true);
      clearTurnStatus();
      state.currentAssistant = el("msg-assistant", "");
    }
    const d = delta || "";
    // 流式去重：同一回合若 delta 已连续出现在 streamAcc 尾部（网络/服务端偶发双发），
    // 跳过第二次，避免“对话进行中同一段文字逐字重复”。
    // 仅对较长 delta（≥5 字符）做整段尾部去重，短增量（标点/单个字符）正常追加，
    // 避免把模型合理输出的连续相同符号（如 **、--、代码缩进）误判为重复。
    if (d.length >= 5 && streamAcc.endsWith(d)) return;
    streamAcc += d;
    state.currentAssistant.dataset.raw = streamAcc;
    if (!streamRaf) {
      streamRaf = requestAnimationFrame(() => {
        streamRaf = 0;
        if (state.currentAssistant) {
          state.currentAssistant.innerHTML = renderMarkdown(streamAcc);
          bindCopyButtons(state.currentAssistant);
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
    // 工具开始时归档当前 reasoning 块（去 running，下次 reasoning 开新块）
    archiveReasoning();
    mcToolStart(p);
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
    flushTextBlock();
  }

  function toolResult(text, ok, durationMs) {
    if (!state.currentTool) return;
    state.currentTool.classList.add(ok ? "ok" : "err");
    state.currentTool.textContent = (text || "").split("\n").slice(0, 30).join("\n");
    if (!ok && lastUserPrompt) {
      addRetryButton(state.currentToolCard);
    }
    stampDuration(state.currentToolCard, durationMs);
    mcToolResult(ok, durationMs);
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
    if (ms > 0 && secs < 0.05) return "<0.1s";
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

  function shellResult(p) {
    const card = document.createElement("div");
    card.className = "msg msg-tool";
    const head = document.createElement("div");
    head.className = "tool-head";
    head.innerHTML = `<b>$</b> ${escapeHtml(p.cmd || "")}`;
    const out = document.createElement("div");
    out.className = "tool-result " + (p.exit === 0 ? "ok" : "err");
    out.textContent = (p.output || "").split("\n").slice(0, 40).join("\n");
    card.append(head, out);
    flow.appendChild(card);
    flushTextBlock();
  }
  // dsh 文件 diff 卡片：+/- 行内联着色
  function fileDiff(p) {
    const card = document.createElement("div");
    card.className = "msg msg-tool";
    const head = document.createElement("div");
    head.className = "tool-head";
    const st = p.stats || {};
    head.innerHTML = `<b>✎</b> ${escapeHtml(p.path || "")} <span class="diffstat">+${st.added ?? 0} −${st.removed ?? 0}</span>`;
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
    flow.appendChild(card);
    flushTextBlock();
    mcOnFileChange(p.path);
  }



  function showPermission(preview) {
    $("perm-preview").textContent = preview || "";
    $("permission-bar").classList.remove("hidden");
  }
  function hidePermission() { $("permission-bar").classList.add("hidden"); }

  function permission(ok) {
    if (state.ws && state.ws.readyState === 1) {
      state.ws.send(JSON.stringify({ type: "permission", ok }));
    } else {
      rpc("respond", { sessionId: state.sid, permission: ok }).catch(() => {});
    }
    hidePermission();
  }

  // ── 会话管理 ──
  // 搜索关键字（"" 表示不过滤）；state.allSessions 缓存最近一次 session.list 响应
  let sessionFilter = "";

  async function loadSessions() {
    const list = await rpc("session.list", { limit: 50, offset: 0 });
    let sessions = list.sessions || [];
    // 懒落盘：刚建好还没发消息的会话尚未写盘，服务端列表里没有——
    // 保留本地注入的当前会话条目在顶部，首条消息落盘后由服务端列表接管
    if (state.sid && !sessions.some((s) => s.id === state.sid)) {
      const local = (state.allSessions || []).find((s) => s.id === state.sid);
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

  function renderSessionList() {
    const box = $("session-list");
    box.innerHTML = "";
    const kw = sessionFilter.trim().toLowerCase();
    const all = state.allSessions || [];
    // 过滤：仅按关键字（title/id）。服务端已懒落盘——磁盘会话都有首条消息，
    // 0 消息的只可能是刚建好未落盘的当前会话（本地条目），正常显示
    const items = all.filter((s) => {
      if (kw && !String(s.title || "").toLowerCase().includes(kw) && !String(s.id).toLowerCase().includes(kw)) return false;
      return true;
    });
    if (items.length === 0) {
      const empty = document.createElement("div");
      empty.className = "session-empty";
      empty.textContent = kw ? "没有匹配「" + kw + "」的会话" : "暂无会话";
      box.appendChild(empty);
      return;
    }
    // 同步侧栏当前工作目录标签（renderSessionList 由 loadSessions 全量刷新时调用）
    const cur = (state.allSessions || []).find((s) => s.id === state.sid);
    if (cur && typeof updateCwdLabel === "function") updateCwdLabel(cur.cwd || null);
    items.forEach((s) => {
      const item = document.createElement("div");
      item.className = "session-item" + (s.id === state.sid ? " active" : "");
      const fallback = (s.messages || 0) === 0 ? "新会话" : s.id;
      const title = String(s.title || fallback).replace(/\s+/g, " ").trim().slice(0, 40) || "(未命名)";
      const stCls = s.busy ? "busy" : (s.running ? "online" : "offline");
      const cwdShort = s.cwd ? (() => { const p = String(s.cwd).replace(/\\$/, ""); return p.split("/").filter(Boolean).pop() || p; })() : null;
       item.innerHTML = `<span class="t"><span class="sess-dot ${stCls}"></span>${escapeHtml(title)}</span><span class="meta">${escapeHtml(s.when_str || "")} · ${s.messages || 0} 条${cwdShort ? " · " + ICO_FOLDER + " " + escapeHtml(cwdShort) : ""}</span>`;
      item.dataset.sid = s.id;
      item.onclick = (e) => {
        if (e.target.classList.contains("menu-btn")) return; // 点 ⋯ 不切换会话
        if (state.creatingSession) return; // 新会话创建中，避免并发切换覆盖
        resume(s.id);
      };
      // ⋯ 菜单钮
      const btn = document.createElement("button");
      btn.className = "menu-btn";
      btn.textContent = "⋯";
      btn.title = "更多操作";
      btn.onclick = (e) => { e.stopPropagation(); openSessionMenu(e, s); };
      item.appendChild(btn);
      box.appendChild(item);
    });
    // 分页：还有未加载的会话时显示“加载更多”
    const loaded = (state.allSessions || []).length;
    const total = state.sessionsTotal || loaded;
    if (loaded < total) {
      const more = document.createElement("button");
      more.className = "session-more";
      more.textContent = state.loadingMoreSessions ? "加载中…" : `加载更多（已加载 ${loaded}/${total}）`;
      more.disabled = !!state.loadingMoreSessions;
      more.onclick = loadMoreSessions;
      box.appendChild(more);
    }
  }

  // 轻量刷新会话运行状态：只更新已渲染列表项的状态点，不重建 DOM（避免闪烁）。
  // 会新增/删除的会话（如另一个 tab 新建）不处理，由 loadSessions 全量刷新负责。
  function refreshSessionStatus() {
    const box = $("session-list");
    if (!box || box.children.length === 0) return;
    rpc("session.list", {}).then((list) => {
      const all = list.sessions || [];
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
    menu.classList.remove("hidden");
    const rect = e.currentTarget.getBoundingClientRect();
    const mw = 150, mh = 80;
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
    const act = e.target.dataset.act;
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
    } else if (act === "delete") {
      const title = String(s.title || s.id).slice(0, 40);
      confirmDialog("删除会话「" + title + "」？此操作不可恢复。", async () => {
        try {
          await rpc("session.delete", { sessionId: s.id });
          clearTiming(s.id); // 清理本地 timing 缓存
          if (s.id === state.sid) {
            state.sid = null;
            localStorage.removeItem("newbee.sid");
            await newSession();
          }
          await loadSessions();
        } catch (err) { line("error", "删除失败: " + err.message); }
      }, { confirmLabel: "删除", confirmClass: "btn-deny" });
    }
  });

  // ── 确认弹窗 ──
  let confirmCb = null;
  function confirmDialog(text, cb, options = {}) {
    const ok = $("confirm-ok");
    const confirmClass = ["btn-primary", "btn-allow", "btn-deny"].includes(options.confirmClass)
      ? options.confirmClass
      : "btn-primary";
    $("confirm-body").textContent = text;
    ok.textContent = options.confirmLabel || "确认";
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
  if ($("dir-modal") && $("new-session-dir")) {
  $("new-session-dir").addEventListener("click", () => openDirPicker());
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
     label.textContent = cwd ? ICO_FOLDER + " " + cwd : "";
    label.title = cwd ? "当前会话工作目录: " + cwd : "";
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
    state.sid = sid;
    localStorage.setItem("newbee.sid", sid);
    loadTiming(sid);
    resetStreamState();
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
    // 同步会话忙碌状态：切到正在跑任务的会话时，UI 立即反映（中断/转向按钮、busy 圆点）
    setBusy(sessionState.busy === true);
    // 切回正在等待权限确认的会话时恢复确认条（permission_ask 事件在切走期间已错过）
    if (sessionState.awaiting_permission === true) showPermission("该会话正在等待权限确认（代码执行请求）");
    connect();
    loadSessions();
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
        <div class="wc-item"><b>Steering</b><span>AI 工作时发消息可转向</span></div>
      </div>
    `;
    flowEl.appendChild(card);
  }

  // 点击“新会话”先把 UI 切到空白会话（断掉旧 ws、清屏、显示欢迎卡），
  // RPC/求值器 boot 在后台完成；不再让用户点完干等 1-3s。
  function prepareNewSessionUI(cwd, sid) {
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
    scrollBottom(true);
  }

  function renderOneMsg(m) {
    if (m.role === "user") {
      if (m.images && m.images.length) renderUserLine(m.content, m.images);
      else line("user", m.content);
    }
    else if (m.role === "done") {
      line("done", m.content, true);
    }
    else if (m.role === "assistant") {
      if (m.reasoning) {
        const d = el("msg-reasoning", "");
        d.dataset.thinkText = m.reasoning;
        d.dataset.open = "0";
        renderReasoningBody(d);
      }
      if (m.content) { const d = el("msg-assistant", m.content, true); bindCopyButtons(d); }
      (m.toolCalls || []).forEach((tc) => toolStart({ name: tc.name, title: tc.title, code: tc.code }));
    } else if (m.role === "tool") {
      const ok = !(m.content || "").startsWith("✗");
      toolResult(m.content, ok);
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
        segs.forEach((s) => {
          const row = document.createElement("div");
          row.className = "archive-seg";
          row.textContent = `[${s.id}] ${s.messages} 条` + (s.intent ? ` · ${s.intent}` : "");
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

  async function loadEarlier() {
    const btn = $("load-more");
    if (btn) btn.remove();
    const flowEl = $("flow");

    // 记录当前滚动位置
    const transcriptEl = $("transcript");
    const oldHeight = transcriptEl.scrollHeight;

    MC._replaying = true;
    const newSkip = Math.max(0, historyOffset - HISTORY_PAGE);
    const start = newSkip;
    const end = historyOffset;
    historyOffset = newSkip;

    // 在顶部插入旧消息（需要先收集 DOM 节点再插入）
    const fragment = document.createDocumentFragment();
    const tempFlow = document.createElement("div");
    
    // 暂存当前 flow 内容
    const existingNodes = Array.from(flowEl.childNodes);
    
    // 清空 flow，渲染旧消息到 fragment
    // 简化方案：直接在前面追加（DOM 顺序可能不完全对，但功能正确）
    allHistoryMsgs.slice(start, end).forEach((m) => { renderOneMsg(m); });

    MC._replaying = false;

    // 保持滚动位置（看到的是同一条消息）
    requestAnimationFrame(() => {
      transcriptEl.scrollTop = transcriptEl.scrollHeight - oldHeight;
    });

    // 如果还有更早的消息，重新显示按钮
    if (historyOffset > 0) {
      renderLoadMoreBtn(historyOffset);
    }
  }

  function renderOneMsg(m) {
    if (m.role === "user") {
      if (m.images && m.images.length) renderUserLine(m.content, m.images);
      else line("user", m.content);
    }
    else if (m.role === "assistant") {
      if (m.reasoning) {
        const d = el("msg-reasoning", "");
        d.dataset.thinkText = m.reasoning;
        d.dataset.open = "0";
        renderReasoningBody(d);
      }
      if (m.content) { const d = el("msg-assistant", m.content, true); bindCopyButtons(d); }
      (m.toolCalls || []).forEach((tc) => toolStart({ name: tc.name, title: tc.title, code: tc.code }));
    } else if (m.role === "tool") {
      const ok = !(m.content || "").startsWith("✗");
      toolResult(m.content, ok);
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

  async function loadEarlier() {
    const btn = $("load-more");
    if (btn) btn.remove();
    const flowEl = $("flow");

    // 记录当前滚动位置
    const transcriptEl = $("transcript");
    const oldHeight = transcriptEl.scrollHeight;

    MC._replaying = true;
    const newSkip = Math.max(0, historyOffset - HISTORY_PAGE);
    const start = newSkip;
    const end = historyOffset;
    historyOffset = newSkip;

    // 在顶部插入旧消息（需要先收集 DOM 节点再插入）
    const fragment = document.createDocumentFragment();
    const tempFlow = document.createElement("div");
    
    // 暂存当前 flow 内容
    const existingNodes = Array.from(flowEl.childNodes);
    
    // 清空 flow，渲染旧消息到 fragment
    // 简化方案：直接在前面追加（DOM 顺序可能不完全对，但功能正确）
    allHistoryMsgs.slice(start, end).forEach((m) => { renderOneMsg(m); });

    MC._replaying = false;

    // 保持滚动位置（看到的是同一条消息）
    requestAnimationFrame(() => {
      transcriptEl.scrollTop = transcriptEl.scrollHeight - oldHeight;
    });

    // 如果还有更早的消息，重新显示按钮
    if (historyOffset > 0) {
      renderLoadMoreBtn(historyOffset);
    }
  }

  // ── 图片附件（上传 / 粘贴 / 预览）──
  const MAX_ATTACH = 4;
  const MAX_FILE = 8 * 1024 * 1024; // 8 MiB，与服务端 @max_bytes 一致

  function addAttachment(file) {
    if (state.busy) { line("notice", "忙碌中，稍后再添加图片"); return; }
    if (!file) return;
    if (!file.type || !file.type.startsWith("image/")) { line("notice", "仅支持图片文件"); return; }
    if (file.size > MAX_FILE) { line("notice", "图片过大（>8MiB）：" + file.name); return; }
    if (state.attachments.length >= MAX_ATTACH) { line("notice", "最多同时 " + MAX_ATTACH + " 张图片"); return; }
    const reader = new FileReader();
    reader.onload = () => {
      if (state.attachments.length >= MAX_ATTACH) { line("notice", "最多同时 " + MAX_ATTACH + " 张图片"); return; }
      state.attachments.push({ name: file.name || "image.png", type: file.type, dataUrl: reader.result, size: file.size });
      renderAttachPreview();
    };
    reader.readAsDataURL(file);
  }

  function renderAttachPreview() {
    const box = $("attach-preview");
    if (!box) return;
    if (state.attachments.length === 0) { box.classList.add("hidden"); box.innerHTML = ""; return; }
    box.classList.remove("hidden");
    box.innerHTML = "";
    state.attachments.forEach((a, i) => {
      const item = document.createElement("div");
      item.className = "attach-item";
      const img = document.createElement("img");
      img.src = a.dataUrl; img.alt = a.name;
      const cap = document.createElement("span");
      cap.className = "attach-name"; cap.textContent = a.name;
      const rm = document.createElement("button");
      rm.className = "attach-remove"; rm.textContent = "×"; rm.title = "移除";
      rm.onclick = () => { state.attachments.splice(i, 1); renderAttachPreview(); };
      item.appendChild(img); item.appendChild(cap); item.appendChild(rm);
      box.appendChild(item);
    });
  }

  function clearAttachments() {
    state.attachments = [];
    renderAttachPreview();
  }

  // 用户行回显：文本 + 图片缩略图
  function renderUserLine(text, images) {
    const d = el("msg-user", "");
    if (text) {
      const span = document.createElement("div");
      span.textContent = text;
      d.appendChild(span);
    }
    if (images && images.length) {
      const wrap = document.createElement("div");
      wrap.className = "msg-user-images";
      images.forEach(url => {
        const img = document.createElement("img");
        img.src = url;
        wrap.appendChild(img);
      });
      d.appendChild(wrap);
    }
    scrollBottom();
  }


  // 首条提示词即时顶栏取题；服务端 session.list 也会用首条 user 消息自动取题。
  function applyPromptTitle(text, images) {
    const raw = String(text || "") || (images && images.length ? "[图片]" : "");
    const title = raw.replace(/\s+/g, " ").trim().slice(0, 48);
    const el = $("session-title");
    if (!title || !state.sid) return;
    if (el.textContent === "新会话" || el.textContent === state.sid) el.textContent = title;

    // 侧栏若已加载该会话，也立即换成首条提示词标题；否则等 turn 结束 loadSessions 兜底
    const sess = (state.allSessions || []).find(x => x.id === state.sid);
    if (sess && (!sess.title || sess.title === sess.id || sess.title === "新会话")) {
      sess.title = title;
      renderSessionList();
    }
  }

  // ── 发送 ──
  async function send() {
    const text = input.value.trim();
    const images = state.attachments.map(x => x.dataUrl);
    if ((!text && images.length === 0) || !state.sid) return;
    const wasSteering = state.busy;
    if (!wasSteering && text) lastUserPrompt = text;
    if (wasSteering) {
      // 转向模式：先中断当前 turn
      interrupt();
      line("notice", "⤳ 转向：中断当前操作，执行新指令");
    }
    input.value = "";
    autoGrow();
    // 回显：文本 + 图片
    scrollBottom(true);
    renderUserLine(text, images);
    if (!state.hasPrompted) {
      state.hasPrompted = true;
      state.titleDirty = true;
      applyPromptTitle(text, images);
    }
    state.busy = true; setBusy(true);
    clearAttachments();
    try {
      if (images.length > 0) {
        // 多模态：必须走 HTTP（data URL 大，走 ws 帧没问题但保持单一路径）
        await rpc("session.promptImage", { sessionId: state.sid, images, text });
      } else if (state.ws && state.ws.readyState === 1) {
        state.ws.send(JSON.stringify({ type: "prompt", text }));
      } else {
        await rpc("session.prompt", { sessionId: state.sid, text });
      }
    } catch (e) {
      line("error", e.message);
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

    function renderModels(p) {
      mbox.innerHTML = "";
      (p.models || []).forEach((m) => {
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
    sendBtn.textContent = b ? "转向" : "发送";
    sendBtn.title = b ? "中断当前 turn 并发送新指令" : "发送";
    sendBtn.classList.toggle("btn-steer", b);
    if (b) {
      showTurnStatus();
      // AI 开始工作时，自动展开 MC 步骤 tab（如果 MC 已打开）
      if (MC.open) switchMCTab("steps");
    } else {
      clearTurnStatus();
      // AI 完成时，自动切换到文件 tab
      if (MC.open) {
        switchMCTab("files");
        refreshMCFiles();
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
  function autoGrow() { input.style.height = "auto"; input.style.height = Math.min(input.scrollHeight, 160) + "px"; }
  function escapeHtml(s) {
    return String(s).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
  }

  // 代码块复制按钮（dsh MarkdownText codeLabels: copy/copied）
  function bindCopyButtons(root) {
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

  // ── 思考强度段选器（7 档，输入框旁）──
  const EFFORT_LEVELS = ["off", "auto", "low", "medium", "high", "xhigh", "max"];
  const effortWrap = $("effort-segments");
  if (effortWrap) {
    const renderSegs = (active) => {
      effortWrap.innerHTML = "";
      EFFORT_LEVELS.forEach((lv) => {
        const b = document.createElement("button");
        b.type = "button";
        b.className = "effort-seg" + (lv === active ? " active" : "");
        b.textContent = lv;
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
    // resume 时按会话恢复选中档（nil → auto）
    window.__restoreEffort = (effort) => renderSegs(effort || "auto");
    renderSegs("auto");
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
  $("new-session").onclick = () => newSession(); // 直接绑函数会把 MouseEvent 当 cwd 参数传入
  $("perm-yes").onclick = () => permission(true);
  $("perm-no").onclick = () => permission(false);
  $("model-label").onclick = openModels;
  $("model-cancel").onclick = () => $("model-modal").classList.add("hidden");
  // model-confirm 的 onclick 在 openModels 里动态绑定（每次打开重新捕获 pending）
  input.addEventListener("input", autoGrow);
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
    const u = st.usage || {};
    const cacheRead = u.cache_read_tokens || u.cached_tokens
      || (u.prompt_tokens_details && u.prompt_tokens_details.cached_tokens) || 0;
    const uncachedIn = u.uncached_prompt_tokens != null ? u.uncached_prompt_tokens
      : ((u.prompt_tokens || 0) - cacheRead > 0 ? (u.prompt_tokens || 0) - cacheRead : 0);
    const outTok = u.completion_tokens || u.output_tokens || 0;
    const inTok = cacheRead + uncachedIn + (u.cache_write_tokens || 0);
    // 缓存命中率：累计 cache_read ÷ 累计 prompt_tokens（与 TUI 口径一致；服务端 usage 按 key 累加，prompt 含 cached）
    const promptTok = u.prompt_tokens || 0;
    const cacheHit = promptTok > 0 ? Math.min(100, cacheRead * 100 / promptTok) : null;
    if (st && st.cwd !== undefined) {
      state.cwd = st.cwd || null;
      updateCwdLabel(state.cwd);
    }
    const cwd0 = state.cwd || "";
     const left = [cwd0 ? (ICO_FOLDER + " " + cwd0) : "newbee"];
    const turns = st.turns || 0, steps = st.steps || 0;
    if (turns > 0 || steps > 0) left.push(`${turns} 轮 · ${steps} 步`);
    // LLM/工具耗时（dsh: LLM Xs · 工具 Ys）
    const tm = state.timing;
    const llmMs = tm.llmMs + (tm.llmStart !== null ? Date.now() - tm.llmStart : 0);
    const toolMs = tm.toolMs + (tm.toolStart !== null ? Date.now() - tm.toolStart : 0);
    if (llmMs > 0 || toolMs > 0) left.push(`LLM ${fmtDur(llmMs)} · 工具 ${fmtDur(toolMs)}`);
    // 首 token · 速率（dsh: 首 token Zs · T tok/s）
    const spd = [];
    if (tm.ftCount > 0) spd.push(`首 token ${fmtDur(tm.ftSum / tm.ftCount)}`);
    if (llmMs > 0 && tm.outTok > 0) spd.push(`${(tm.outTok / (llmMs / 1000)).toFixed(1)} tok/s`);
    if (spd.length) left.push(spd.join(" · "));
    if (cacheHit !== null) left.push(`缓存 ${cacheHit.toFixed(1).replace(/\.0$/, "")}%`);
    if (inTok > 0 || outTok > 0) left.push(`入 ${fmtTok(inTok)} · 出 ${fmtTok(outTok)}`);
    $("stats-left").innerHTML = left.join(" | ");
    const stTxt = st.busy ? '<span class="st-busy">● 运行中</span>' : '<span class="st-ok">● 空闲</span>';
    $("stats-right").innerHTML = `${stTxt} bind:${st.bindings || 0} ${escapeHtml(st.policy || "")}`;
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
      $("evo-open-count").textContent = coordinator ? coordinator.open_count || 0 : "-";
      $("evo-release-count").textContent = coordinator ? coordinator.active_count || 0 : "-";
      $("evo-signal-count").textContent = (st.pending_signals || []).length;

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

  function renderEvoChanges(changes) {
    const box = $("evo-changes-list");
    if (!box) return;
    const open = changes.filter((c) => !c.terminal);
    const shown = open.length ? open : changes.slice(0, 3);
    $("evo-change-summary").textContent = open.length ? `${open.length} 个开放` : "无开放 Change";

    if (!shown.length) {
      box.innerHTML = '<div class="evo-empty">暂无 Change。输入信号后，Adapter 会生成最小候选并进入验证。</div>';
      return;
    }

    box.innerHTML = shown.map((change) => {
      const status = change.derived_status || change.status || "requested";
      const layers = ((change.evaluation || {}).layers || []).map(renderEvoLayer).join("");
      const release = change.plugin_id || shortRelease(change.candidate_release) || change.change_id;
      const changeId = escapeHtml(change.change_id || "");
      const action = change.can_approve
        ? `<button class="evo-approve" data-change-id="${changeId}">批准激活</button>`
        : change.can_reevaluate
          ? `<button class="evo-reevaluate" data-change-id="${changeId}">重新评测</button>`
          : "";
      return `<article class="evo-change ${escapeHtml(status)}">
          <div class="evo-change-title"><strong title="${escapeHtml(change.candidate_release || "")}">${escapeHtml(release || "change")}</strong><span>${changeId} · Ring ${escapeHtml(change.ring == null ? "-" : change.ring)}</span></div>
          <span class="evo-status-tag">${escapeHtml(change.status_label || status)}</span>
        </div>
        <div class="evo-change-reason">${escapeHtml(cleanEvolutionReason(change.reason || "未记录原因"))}</div>
        <div class="evo-layers">${layers || renderPendingLayers()}</div>
        <div class="evo-change-foot"><span class="evo-change-next" title="${escapeHtml(change.next_action || "")}">${escapeHtml(change.next_action || "等待下一步")}</span>${action}</div>
      </article>`;
    }).join("");

    box.querySelectorAll(".evo-approve").forEach((button) => {
      button.onclick = () => approveEvolutionChange(button.dataset.changeId, button);
    });
    box.querySelectorAll(".evo-reevaluate").forEach((button) => {
      button.onclick = () => reevaluateEvolutionChange(button.dataset.changeId, button);
    });

  }

  function renderEvoLayer(layer) {
    const status = layer.status || "pending";
    const marks = { passed: "PASS", failed: "FAIL", observing: "LIVE", pending: "WAIT", skipped: "N/A" };
    let detail = "";
    if (layer.samples != null) detail = `${layer.samples} samples`;
    else if (layer.replayed != null) detail = `${layer.replayed} replay`;
    else detail = layer.label || layer.key || "gate";
    return `<div class="evo-layer ${escapeHtml(status)}" title="${escapeHtml(layer.reason || layer.label || "")}"><b>${marks[status] || "WAIT"}</b><span>${escapeHtml(detail)}</span></div>`;
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
      box.innerHTML = '<div class="evo-empty">信号队列为空。Worker 的重复失败、规则命中和显式 need 会进入这里。</div>';
      return;
    }
    box.innerHTML = signals.slice(0, 5).map((signal) => `<div class="evo-signal">
      <div class="evo-signal-head"><strong>${escapeHtml(signal.capability || "未命名能力")}</strong><span>${escapeHtml(signal.urgency || "normal")}</span></div>
      <p>${escapeHtml(signal.evidence || "等待 Adapter 诊断")}</p>
    </div>`).join("");
  }

  function renderEvoReleases(releases) {
    const box = $("evo-releases");
    if (!box) return;
    if (!releases.length) {
      box.innerHTML = '<div class="evo-empty">当前 revision 没有激活的 Release。</div>';
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

  async function approveEvolutionChange(changeId, button) {
    if (!changeId) return;
    confirmDialog(`批准 ${changeId} 激活？验证通过的候选将生成新 revision。`, async () => {
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
    }, { confirmLabel: "批准激活", confirmClass: "btn-allow" });
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
      box.innerHTML = '<div class="evo-empty">项目 EventStore 尚无进化事件。</div>';
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
  };

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
    } else {
      panel.classList.add("hidden");
      expandBtn.classList.remove("hidden");
    }
    try { localStorage.setItem("newbee-mc-open", open ? "1" : "0"); } catch (e) {}
  }

  function switchMCTab(tab) {
    MC.tab = tab;
    document.querySelectorAll(".mc-tab").forEach((b) => b.classList.toggle("active", b.dataset.tab === tab));
    document.querySelectorAll(".mc-pane").forEach((p) => p.classList.add("hidden"));
    $("mc-" + tab).classList.remove("hidden");
    if (tab === "diff") refreshMCDiff();
    if (tab === "overview") refreshMCOverview();
    if (tab === "evolution") refreshEvolution();
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
      return `<div class="${cls}" data-path="${escapeHtml(f.path)}" title="点击查看 diff">
        <div class="mc-file-path">${escapeHtml(f.path)}</div>
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
    // 有文件操作时刷新文件列表（防抖）
    if (MC.open && MC.tab === "files") {
      clearTimeout(MC.refreshTimer);
      MC.refreshTimer = setTimeout(() => refreshMCFiles(), 800);
    }
  }
  function mcOnFileChange(path) {
    // 文件变更事件 → 防抖刷新文件列表
    if (MC.open) {
      clearTimeout(MC.refreshTimer);
      MC.refreshTimer = setTimeout(() => refreshMCFiles(), 600);
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
        ["缓存命中", u.prompt_tokens > 0 ? (((u.cache_read_tokens || 0) / u.prompt_tokens) * 100).toFixed(1) + "%" : "-"],
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


  // 文件路径点击 → 显示 diff
  document.addEventListener("click", (e) => {
    if (e.target.classList.contains("file-ref")) {
      const path = e.target.dataset.path;
      if (path) {
        if (!MC.open) setMCOpen(true);
        showFileDiff(path);
      }
    }
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
  async function refreshCaptcha() {
    try {
      const r = await rpc("auth.captcha", {});
      const img = $("login-captcha-img");
      if (img && r.svg) {
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
    } catch (e) {
      loginError(e.message || "登录失败");
      refreshCaptcha();
      const capEl = $("login-captcha");
      if (capEl) capEl.value = "";
    }
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
    let needAuth = false;
    try {
      const host = await rpc("host.describe", {});
      needAuth = !!host.auth_required;
      if (needAuth && state.token) {
        hideLogin();
        await bootApp();
        return;
      }
    } catch (e) {
      if (String(e.message).includes("未登录")) { needAuth = true; }
    }
    if (needAuth) {
      showLogin();
    } else {
      hideLogin();
      await bootApp();
    }
  })().catch((e) => line("error", `启动失败: ${e.message}`));
})();
