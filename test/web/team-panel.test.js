// 定向测试：priv/web/team-panel.js 的两条回归（R2P-04 / R2P-05）。
// 运行：node --test test/web/team-panel.test.js
//
// 不用浏览器也不引入新依赖：这里给一份极简 DOM 替身 + 可控定时器，
// 把 team-panel.js 放进 vm 沙箱里跑。两条用例都做了反向验证
// （去掉守卫/去掉 try → 用例必须红），见 arch-evidence/README。

const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");

const ROOT = path.resolve(__dirname, "..", "..");
const SOURCE = fs.readFileSync(path.join(ROOT, "priv/web/team-panel.js"), "utf8");

class El {
  constructor(tag) {
    this.tagName = String(tag).toUpperCase();
    this.className = "";
    this.children = [];
    this.parentNode = null;
    this.style = {};
    this.dataset = {};
    this.attributes = new Map();
    this.listeners = new Map();
    this._text = "";
    this.value = "";
    this.disabled = false;
    this.id = "";
    this.ownerDocument = null;
    this.classList = {
      add: (...ns) => { ns.forEach((n) => { if (!this._classes().includes(n)) this.className = (this.className + " " + n).trim(); }); },
      remove: (...ns) => { this.className = this._classes().filter((c) => !ns.includes(c)).join(" "); },
      contains: (n) => this._classes().includes(n),
      toggle: (n, on) => { if (on === undefined) on = !this._classes().includes(n); if (on) this.classList.add(n); else this.classList.remove(n); }
    };
  }
  _classes() { return this.className.split(/\s+/).filter(Boolean); }
  get textContent() { return this.children.length ? this.children.map((c) => c.textContent).join("") : this._text; }
  set textContent(v) { this.children = []; this._text = String(v == null ? "" : v); }
  get innerHTML() { return this._html || ""; }
  set innerHTML(v) {
    // 记录"整体替换"次数：R2P-04 的缺陷就是无条件 body.innerHTML = ""
    this.innerHTMLWrites = (this.innerHTMLWrites || 0) + 1;
    this._html = v;
    if (v === "") { this.children.forEach((c) => (c.parentNode = null)); this.children = []; }
  }
  append(...nodes) { nodes.forEach((n) => this.appendChild(n)); }
  appendChild(n) {
    if (!n) return n;
    if (n.parentNode) n.parentNode.removeChild(n);
    n.parentNode = this;
    if (!n.ownerDocument) n.ownerDocument = this.ownerDocument;
    this.children.push(n);
    return n;
  }
  removeChild(n) { const i = this.children.indexOf(n); if (i >= 0) this.children.splice(i, 1); n.parentNode = null; return n; }
  remove() { if (this.parentNode) this.parentNode.removeChild(this); }
  contains(n) {
    if (n === this) return true;
    return this.children.some((c) => c.contains && c.contains(n));
  }
  setAttribute(k, v) { this.attributes.set(k, v); }
  addEventListener(t, f) { this.listeners.set(t, f); }
  focus() { if (this.ownerDocument) this.ownerDocument.activeElement = this; }
  querySelector() { return null; }
  querySelectorAll(sel) {
    const cls = sel.replace(/^\./, "");
    const out = [];
    const walk = (n) => n.children.forEach((c) => { if (c._classes().includes(cls)) out.push(c); walk(c); });
    walk(this);
    return out;
  }
}

function makeSandbox({ badLocalStorage } = {}) {
  const doc = {
    activeElement: null,
    hidden: false,
    listeners: new Map(),
    createElement: (t) => { const el = new El(t); el.ownerDocument = doc; return el; },
    addEventListener(t, f) { this.listeners.set(t, f); },
    getElementById: () => null
  };
  doc.body = new El("body");
  doc.body.ownerDocument = doc;
  doc.documentElement = new El("html");
  const store = new Map();
  if (badLocalStorage) store.set("newbee.teamCollapsed", '{"unterminated');
  const localStorage = {
    getItem: (k) => (store.has(k) ? store.get(k) : null),
    setItem: (k, v) => store.set(k, String(v)),
    removeItem: (k) => store.delete(k)
  };
  const timers = [];
  const sandbox = {
    document: doc,
    window: {},
    localStorage,
    console,
    setInterval: (fn, ms) => { timers.push({ fn, ms }); return timers.length; },
    clearInterval: () => {},
    setTimeout: (fn) => { return 0; }, // 不真的等：面板里的 30ms focus 之类不需要
    clearTimeout: () => {},
    __timers: timers,
    __store: store
  };
  sandbox.window = sandbox;
  sandbox.globalThis = sandbox;
  doc.defaultView = sandbox;
  return { sandbox, doc, timers, store };
}

function boot({ badLocalStorage } = {}) {
  const env = makeSandbox({ badLocalStorage });
  vm.createContext(env.sandbox);
  vm.runInContext(SOURCE, env.sandbox, { filename: "team-panel.js" });
  return env;
}

function fakeRpc() {
  const calls = [];
  const rpc = async (method) => {
    calls.push(method);
    if (method === "colony.team.runs") return { runs: [] };
    if (method === "colony.team.templates") return { templates: [] };
    if (method === "colony.team.proposals") return { proposals: [] };
    if (method === "colony.team.sessions") return { groups: [] };
    return {};
  };
  return { rpc, calls };
}

const flush = () => new Promise((r) => setImmediate(r));

// 递归按 class 找节点（面板挂在 document.body 下多层）
function findByClass(root, cls) {
  for (const c of root.children) {
    if (c._classes().includes(cls)) return c;
    const hit = findByClass(c, cls);
    if (hit) return hit;
  }
  return null;
}

test("R2P-05：localStorage 里的坏值不能让 window.NewbeeTeamPanel 消失", () => {
  const env = boot({ badLocalStorage: true });
  const panel = env.sandbox.NewbeeTeamPanel;
  assert.equal(typeof panel, "object", "坏值下团队面板必须仍然导出（改前是 undefined → 按钮永久点不开）");
  assert.equal(typeof panel.open, "function");
  // 坏键应当被清掉，避免每次加载都再抛一次
  assert.equal(env.store.has("newbee.teamCollapsed"), false, "坏键应被清掉");
});

test("R2P-05 反向：坏值下的导出与正常值一致（open() 可用不抛错）", async () => {
  const env = boot({ badLocalStorage: true });
  const { rpc } = fakeRpc();
  env.sandbox.NewbeeTeamPanel.init({ rpc, notify: () => {}, openSession: () => {} });
  assert.doesNotThrow(() => env.sandbox.NewbeeTeamPanel.open("runs"));
});

test("R2P-04：正在编辑时，8s 轮询不得重绘面板（草稿与焦点必须保住）", async () => {
  const env = boot();
  const { rpc } = fakeRpc();
  env.sandbox.NewbeeTeamPanel.init({ rpc, notify: () => {}, openSession: () => {} });
  env.sandbox.NewbeeTeamPanel.open("runs");
  await flush();

  const body = findByClass(env.doc.body, "tp-body");
  assert.ok(body, "面板应已渲染出 .tp-body");

  // 模拟用户打开内联表单并输入
  const form = new El("div");
  form.className = "tp-inline-form";
  form.ownerDocument = env.doc;
  const ta = new El("textarea");
  ta.ownerDocument = env.doc;
  ta.value = "ABC";
  form.appendChild(ta);
  body.appendChild(form);
  ta.focus();
  assert.equal(env.doc.activeElement, ta);

  const writesBefore = body.innerHTMLWrites || 0;

  // 找到 8s 轮询定时器并手动触发一次（不真的等 8 秒）
  const poll = env.timers.find((t) => t.ms === 8000);
  assert.ok(poll, "应注册 8s 轮询");
  await poll.fn();
  await flush();

  assert.ok(body.contains(ta), "正在编辑的输入节点必须仍然挂在面板里（不能被整块替换掉）");
  assert.equal(ta.value, "ABC", "草稿内容必须保留");
  assert.equal(env.doc.activeElement, ta, "焦点必须保留");
  assert.equal((body.innerHTMLWrites || 0), writesBefore, "编辑期间不得写 body.innerHTML");
});

test("R2P-04 反向：没有编辑时轮询照常刷新（守卫不能把面板冻住）", async () => {
  const env = boot();
  const { rpc } = fakeRpc();
  env.sandbox.NewbeeTeamPanel.init({ rpc, notify: () => {}, openSession: () => {} });
  env.sandbox.NewbeeTeamPanel.open("runs");
  await flush();

  const body = findByClass(env.doc.body, "tp-body");
  const writesBefore = body.innerHTMLWrites || 0;

  const poll = env.timers.find((t) => t.ms === 8000);
  await poll.fn();
  await flush();

  assert.ok((body.innerHTMLWrites || 0) > writesBefore, "无编辑时轮询必须真的重绘（否则待办就不再及时）");
});
