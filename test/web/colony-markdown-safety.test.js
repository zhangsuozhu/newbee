// 定向测试：priv/web/colony/md.js 的 Markdown 渲染安全边界（R2P-03 的第二份渲染器）。
// 运行：node --test test/web/colony-markdown-safety.test.js
//
// 背景：仓库里有两份 Markdown 渲染器——priv/web/app.js 的 renderMarkdown（主界面）
// 与 priv/web/colony/md.js（蜂群群聊 / 成果报告 / 工作卡）。R2P-03 的注入面在**两份**里都存在：
// 只改 app.js 时，群聊里的 ![a"]onerror="alert(1)](x.png) 仍然能产出真属性。
// 这里用 vm 求值 md.js：只去掉 import / export 关键字，其余按原样跑。

const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");

const ROOT = path.resolve(__dirname, "..", "..");
const SOURCE = fs.readFileSync(path.join(ROOT, "priv/web/colony/md.js"), "utf8");

function loadModule() {
  const body = SOURCE
    .split("\n")
    .filter((l) => !/^import\s/.test(l))
    .map((l) => l.replace(/^export\s+/, ""))
    .join("\n");
  const sandbox = {
    copyToClipboard: async () => true,
    toast: () => {},
    console,
    setTimeout,
  };
  vm.createContext(sandbox);
  vm.runInContext(
    body +
      "\nthis.renderMarkdown = renderMarkdown; this.renderInline = renderInline;" +
      " this.escapeHtml = escapeHtml; this.escapeAttr = escapeAttr; this.safeUrl = safeUrl; this.inline = inline;",
    sandbox
  );
  return sandbox;
}

const M = loadModule();
const render = (s) => M.renderMarkdown(s);

function attributesOf(html, tagName) {
  const tag = (html.match(new RegExp("<" + tagName + "\\b[^>]*>", "i")) || [null])[0];
  if (!tag) return null;
  const attrs = [];
  const re = /([a-zA-Z_:][-a-zA-Z0-9_:.]*)\s*=\s*"([^"]*)"/g;
  let m;
  while ((m = re.exec(tag))) attrs.push([m[1].toLowerCase(), m[2]]);
  return attrs;
}

test("colony/md.js：图片 alt 里的引号不能闭合属性", () => {
  const html = render('![a"onerror="alert(1)](x.png)');
  const attrs = attributesOf(html, "img");
  assert.ok(attrs, "应当渲染出 img: " + html);
  assert.deepEqual(
    attrs.map(([n]) => n).sort(),
    ["alt", "class", "loading", "src"],
    "img 上只允许我们写的四个属性: " + html
  );
});

test("colony/md.js：href/src 里的引号不能闭合属性", () => {
  const html = render('[x" onmouseover="alert(1)](https://e.com/a)');
  const attrs = attributesOf(html, "a");
  assert.ok(attrs, html);
  assert.deepEqual(attrs.map(([n]) => n).sort(), ["class", "href", "rel", "target"], html);

  const img = render('![t](https://e.com/a.png" onerror="alert(1))');
  const iattrs = attributesOf(img, "img");
  assert.ok(iattrs, img);
  assert.deepEqual(iattrs.map(([n]) => n).sort(), ["alt", "class", "loading", "src"], img);
});

test("colony/md.js：javascript:/data:/vbscript: 一律降级为纯文本", () => {
  const urls = [
    "javascript:alert(1)",
    "JavaScript:alert(1)",
    "java\tscript:alert(1)",
    " javascript:alert(1)",
    "vbscript:msgbox(1)",
    "data:text/html,<b>x</b>",
  ];
  for (const url of urls) {
    const html = render("[点我](" + url + ")");
    assert.ok(!html.includes("<a "), "不该产出可点击链接: " + JSON.stringify(url) + " => " + html);
    assert.ok(html.includes("点我"), "标签文字仍要显示: " + html);
  }
});

test("colony/md.js：安全链接/图片照常渲染", () => {
  assert.ok(render("[文档](https://example.com/a?b=1)").includes('href="https://example.com/a?b=1"'));
  assert.ok(render("[相对](./docs/a.md)").includes('href="./docs/a.md"'));
  assert.ok(render("[锚点](#sec)").includes('href="#sec"'));
  assert.ok(render("[邮件](mailto:a@b.c)").includes('href="mailto:a@b.c"'));
  assert.ok(render("![图](https://example.com/a.png)").includes('src="https://example.com/a.png"'));
});

test("colony/md.js：file-ref 只产生白名单属性，且属性位走 escapeAttr", () => {
  // file-ref 的路径正则只允许 [\w./-]，引号进不来；这里断言两件事：
  //  ① 正规路径渲染出的 span 只有 3 个属性；
  //  ② 属性位用的转义函数确实会转引号（源码契约另有守护）。
  const html = render("priv/web/colony/md.js");
  assert.ok(html.includes("file-ref"), "应识别为文件引用: " + html);
  const attrs = attributesOf(html, "span");
  assert.ok(attrs, html);
  assert.deepEqual(attrs.map(([n]) => n).sort(), ["class", "data-path", "title"], html);
  assert.equal(M.escapeAttr('a" onerror="x'), "a&quot; onerror=&quot;x");
  assert.equal(M.escapeAttr("a' b"), "a&#39; b");
});

test("colony/md.js：文本位仍是 escapeHtml 语义（引号不变成可见实体）", () => {
  const html = render('普通段落 "引号" 保留');
  assert.ok(html.includes('"引号"'), html);
  assert.ok(!html.includes("&quot;"), html);
});

test("colony/md.js 源码契约：属性位不得再用 escapeHtml(", () => {
  const lines = SOURCE.split("\n");
  const offenders = [];
  lines.forEach((line, i) => {
    if (/=\s*["'`]\s*\$\{escapeHtml\(/.test(line)) offenders.push(i + 1 + ": " + line.trim().slice(0, 120));
  });
  assert.deepEqual(offenders, [], "属性位必须用 escapeAttr/escapeQuote:\n" + offenders.join("\n"));
});

test("两份渲染器都必须保留 scheme 白名单（反向守护）", () => {
  assert.equal(typeof M.safeUrl, "function");
  assert.equal(M.safeUrl("javascript:alert(1)"), null);
  assert.equal(M.safeUrl("https://ok"), "https://ok");
  const app = fs.readFileSync(path.join(ROOT, "priv/web/app.js"), "utf8");
  assert.ok(app.includes("function safeUrl("), "app.js 也必须保留 safeUrl");
});
