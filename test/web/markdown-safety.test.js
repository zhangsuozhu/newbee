// 定向测试：Markdown 渲染的安全边界（R2P-03）。
// 运行：node --test test/web/markdown-safety.test.js
//
// 被测对象是 priv/web/app.js 里的纯函数（escapeHtml / escapeAttr / escapeQuote /
// safeUrl / imgTag / linkTag / inline / renderMarkdown）。这里按函数名从源码切出
// 这几段在隔离作用域里求值——不启动 Elixir 服务，也不需要浏览器/jsdom。
//
// 断言口径：不解析 HTML，直接看生成的标记串里有没有越界内容
// （属性位被引号闭合 / javascript: 之类的 scheme）。

const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");

const ROOT = path.resolve(__dirname, "..", "..");
const SOURCE = fs.readFileSync(path.join(ROOT, "priv/web/app.js"), "utf8");
const LINES = SOURCE.split("\n");

// 按函数名切出 `function name(...) { ... }`（花括号配平）。
// 找不到就抛错，不静默跳过——否则测试会恒绿。
function extractFunction(name) {
  const start = LINES.findIndex((l) => l.includes("function " + name + "("));
  if (start < 0) throw new Error("function not found in priv/web/app.js: " + name);
  let depth = 0, started = false, out = [];
  for (let i = start; i < LINES.length; i++) {
    out.push(LINES[i]);
    for (const ch of LINES[i]) {
      if (ch === "{") { depth++; started = true; }
      else if (ch === "}") depth--;
    }
    if (started && depth === 0) return out.join("\n");
  }
  throw new Error("unbalanced braces while extracting: " + name);
}

function extractConst(name) {
  const idx = LINES.findIndex((l) => l.trim().startsWith("const " + name + " ="));
  if (idx < 0) throw new Error("const not found: " + name);
  return LINES[idx];
}

function loadRenderer() {
  const parts = [
    extractConst("SAFE_LINK_SCHEME"),
    extractFunction("escapeHtml"),
    extractFunction("escapeAttr"),
    extractFunction("escapeQuote"),
    extractFunction("safeUrl"),
    extractFunction("imgTag"),
    extractFunction("linkTag"),
    extractFunction("splitRow"),
    extractFunction("inline"),
    extractFunction("renderMarkdown")
  ];
  const sandbox = {};
  vm.createContext(sandbox);
  vm.runInContext(
    parts.join("\n") +
      "\nthis.renderMarkdown = renderMarkdown; this.inline = inline;" +
      " this.escapeAttr = escapeAttr; this.safeUrl = safeUrl;",
    sandbox
  );
  return sandbox;
}

const R = loadRenderer();
const render = (s) => R.renderMarkdown(s);
const hasAnchor = (html) => html.includes("<a ");
// 只看"真正的属性名"：alt 值里出现 onerror= 字样是安全的（引号已转义）。
const hasInlineHandler = (html) => {
  const tags = (html.match(/<[a-zA-Z][^>]*>/g) || []).join(" ").replace(/="[^"]*"/g, "");
  return /\son(?:error|load|click|mouseover)\s*=/i.test(" " + tags);
};

// 引号感知的属性解析：把标签里的 name="value" 按真实 HTML 规则切出来。
// 直接对整串跑 /onerror=/ 会误判——alt="a&quot;onerror=&quot;…" 是安全的
// （引号已转义，值仍然全在同一个 alt 属性里）。
function attributesOf(html, tagName) {
  const tag = (html.match(new RegExp("<" + tagName + "\\b[^>]*>", "i")) || [null])[0];
  if (!tag) return null;
  const attrs = [];
  const re = /([a-zA-Z_:][-a-zA-Z0-9_:.]*)\s*=\s*"([^"]*)"/g;
  let m;
  while ((m = re.exec(tag))) attrs.push([m[1].toLowerCase(), m[2]]);
  return attrs;
}

test("属性位不再被引号闭合：![a\"onerror=…](x.png)", () => {
  const html = render('![a"onerror="alert(1)](x.png)');
  assert.ok(html.includes("<img"), "仍应渲染图片: " + html);

  const attrs = attributesOf(html, "img");
  assert.ok(attrs, "应当有 img 标签: " + html);

  const names = attrs.map(([n]) => n);
  assert.deepEqual(
    names.sort(),
    ["alt", "class", "loading", "src"],
    "img 上只允许我们写的四个属性，多一个就是被注入了: " + html
  );
  const alt = attrs.find(([n]) => n === "alt")[1];
  assert.ok(alt.includes("onerror"), "恶意文本应原样留在 alt 的值里（已转义）: " + alt);
  assert.ok(!hasInlineHandler(html), "生成的标签串里不能出现 onerror= 属性: " + html);
});

test("单引号同样不能闭合属性", () => {
  const html = render("![a'onerror='alert(1)](x.png)");
  const attrs = attributesOf(html, "img");
  assert.ok(attrs, html);
  assert.deepEqual(attrs.map(([n]) => n).sort(), ["alt", "class", "loading", "src"], html);
  assert.ok(!hasInlineHandler(html), html);
});

test("javascript: 链接被降级为纯文本", () => {
  const html = render("[点我](javascript:alert(1))");
  assert.ok(!html.includes("javascript:"), "不能产出 javascript: 的 href: " + html);
  assert.ok(!hasAnchor(html), "不安全链接不应渲染成 <a>");
  assert.ok(html.includes("点我"), "标签文字仍要显示给用户");
});

test("大小写/空白/控制字符变体不能绕过 scheme 白名单", () => {
  const urls = [
    "JavaScript:alert(1)",
    "java\tscript:alert(1)",
    " javascript:alert(1)",
    "vbscript:msgbox(1)",
    "data:text/html,<b>x</b>"
  ];
  for (const url of urls) {
    const html = render("[x](" + url + ")");
    assert.ok(!hasAnchor(html), "scheme 白名单漏了: " + JSON.stringify(url) + " => " + html);
  }
});

test("安全的链接与图片照常渲染", () => {
  const ok1 = render("[文档](https://example.com/a?b=1)");
  assert.ok(ok1.includes('href="https://example.com/a?b=1"'), ok1);
  const ok2 = render("[相对](./docs/a.md)");
  assert.ok(ok2.includes('href="./docs/a.md"'), ok2);
  const ok3 = render("[锚点](#section)");
  assert.ok(ok3.includes('href="#section"'), ok3);
  const ok4 = render("![图](https://example.com/a.png)");
  assert.ok(ok4.includes('src="https://example.com/a.png"'), ok4);
  const ok5 = render("[邮件](mailto:a@b.c)");
  assert.ok(ok5.includes('href="mailto:a@b.c"'), ok5);
});

test("文本位保持 escapeHtml 语义（引号不应变成可见的 &quot;）", () => {
  const html = render('普通段落里有 "双引号"');
  assert.ok(html.includes('"双引号"'), "文本位的引号应原样保留: " + html);
  assert.ok(!html.includes("&quot;"), "不能把 escapeHtml 改成超集: " + html);
});

test("危险字符在文本位仍被转义（<script> 不生效）", () => {
  const html = render("<script>alert(1)</script>");
  assert.ok(!html.includes("<script"), html);
  assert.ok(html.includes("&lt;script&gt;"), html);
});

test("已有 markdown 语法没被破坏：粗体/行内代码/列表/表格/代码块/标题/引用", () => {
  assert.ok(render("**粗**").includes("<strong>粗</strong>"));
  assert.ok(render("`code`").includes('<code class="md-inline">code</code>'));
  assert.ok(render("- a\n- b").includes("<li>a</li>"));
  assert.ok(render("| a | b |\n|---|---|\n| 1 | 2 |").includes("<table"));
  const fence = render("```elixir\nIO.puts(1)\n```");
  assert.ok(fence.includes('<pre class="md-code">'), fence);
  assert.ok(render("# 标题").includes('<h1 class="md-h">'));
  assert.ok(render("> 引用").includes("md-quote"));
});

test("源码契约：属性位不得再出现 escapeHtml(", () => {
  // 守"以后新增的属性位又用回 escapeHtml"——它不转引号。
  const offenders = [];
  LINES.forEach((line, i) => {
    const m = line.match(/=\s*["'`]\s*\$\{escapeHtml\(/);
    if (m) offenders.push((i + 1) + ": " + line.trim().slice(0, 120));
  });
  assert.deepEqual(offenders, [], "属性位必须用 escapeAttr/escapeQuote:\n" + offenders.join("\n"));
});
