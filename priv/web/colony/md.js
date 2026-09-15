// 蜂群前端 · Markdown 渲染。
// 与主界面 app.js 的 renderMarkdown 同一套语法（标题/代码块/引用/列表/任务列表/表格/分割线/行内标记），
// 输出同一批 md-* 类名，直接复用 style.css 里的排版——群聊与成果报告不再是一坨纯文本。
export function escapeHtml(s) {
  return String(s == null ? "" : s).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
}

function inline(text) {
  let t = escapeHtml(text);
  t = t.replace(/`([^`\n]+)`/g, '<code class="md-inline">$1</code>');
  t = t.replace(/\*\*([^*]+)\*\*/g, "<strong>$1</strong>");
  t = t.replace(/\*([^*\s][^*]*)\*/g, "<em>$1</em>");
  t = t.replace(/~~([^~\n]+)~~/g, "<del>$1</del>");
  t = t.replace(/!\[([^\]\n]*)\]\(([^)\n]*)\)/g, '<img class="md-img" src="$2" alt="$1" loading="lazy" />');
  t = t.replace(/\[([^\]\n]*)\]\(([^)\n]*)\)/g, '<a class="md-link" href="$2" target="_blank" rel="noopener">$1</a>');
  t = t.replace(/<(a|code)\b[^>]*>.*?<\/\1>|<img\b[^>]*\/>|\b((?:lib|test|config|docs|priv|bench)\/[\w\.\/-]+\.(?:ex|exs|js|css|html|md|json|toml|yml|yaml))\b/g, (match, _tag, path) => {
    if (!path) return match;
    return `<span class="file-ref" data-path="${path}" title="${path}">${path}</span>`;
  });
  return t;
}

function splitRow(line) {
  return line.replace(/^\s*\|/, "").replace(/\|\s*$/, "").split("|").map((c) => c.trim());
}

// 单行内联渲染：给卡片里的「下一步」「最近执行」这类一行文本用。
// 去掉块级语法（标题/列表符号），保留 **粗体**、`代码`、链接，其余原样转义。
export function renderInline(text) {
  const raw = String(text == null ? "" : text).replace(/\s+/g, " ").trim();
  return inline(raw);
}

export function renderMarkdown(text) {
  const lines = String(text == null ? "" : text).split(/\r?\n/);
  const out = [];
  let i = 0;
  let listStack = null; // {type:'ul'|'ol', html:[]}

  const closeList = () => {
    if (listStack) { out.push(`<${listStack.type}>${listStack.html.join("")}</${listStack.type}>`); listStack = null; }
  };

  while (i < lines.length) {
    const line = lines[i];

    // 围栏代码块
    const fence = line.match(/^\s*(`{3,})([^\s`]*)\s*$/);
    if (fence) {
      closeList();
      const lang = fence[2] || "";
      const body = [];
      i++;
      while (i < lines.length && !/^\s*`{3,}\s*$/.test(lines[i])) { body.push(lines[i]); i++; }
      i++;
      out.push(
        `<pre class="md-code"><div class="md-code-head"><span>${escapeHtml(lang || "code")}</span>` +
        `<button class="md-copy" type="button" data-code="${escapeHtml(body.join("\n")).replace(/"/g, "&quot;")}">复制</button></div>` +
        `<code>${escapeHtml(body.join("\n"))}</code></pre>`
      );
      continue;
    }

    // 表格
    if (line.includes("|") && i + 1 < lines.length && /^\s*\|?[\s:\-|]+\|?\s*$/.test(lines[i + 1]) && lines[i + 1].includes("-")) {
      closeList();
      const header = splitRow(line);
      i += 2;
      const rows = [];
      while (i < lines.length && lines[i].includes("|") && lines[i].trim() !== "") { rows.push(splitRow(lines[i])); i++; }
      const th = header.map((c) => `<th>${inline(c)}</th>`).join("");
      const trs = rows.map((r) => `<tr>${r.map((c) => `<td>${inline(c)}</td>`).join("")}</tr>`).join("");
      out.push(`<div class="md-table-wrap"><table class="md-table"><thead><tr>${th}</tr></thead><tbody>${trs}</tbody></table></div>`);
      continue;
    }

    // 标题
    const h = line.match(/^(\#{1,6})\s+(.*)$/);
    if (h) { closeList(); const lv = h[1].length; out.push(`<h${lv} class="md-h md-h${lv}">${inline(h[2])}</h${lv}>`); i++; continue; }

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

// 代码块「复制」按钮：事件委托，整个页面只绑一次。
let copyBound = false;
export function bindMarkdownCopy() {
  if (copyBound) return;
  copyBound = true;
  document.addEventListener("click", (event) => {
    const btn = event.target.closest && event.target.closest(".md-copy");
    if (!btn) return;
    const code = btn.dataset.code || "";
    const done = () => { const old = btn.textContent; btn.textContent = "已复制"; setTimeout(() => { btn.textContent = old || "复制"; }, 1400); };
    if (navigator.clipboard && navigator.clipboard.writeText) navigator.clipboard.writeText(code).then(done, done);
    else done();
  });
}
