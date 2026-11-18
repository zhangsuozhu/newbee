// 定向测试：localStorage 坏值不得让前端模块整体失效（R2P-05 的"同类排查"验收项 4）。
// 运行：node --test test/web/localstorage-safety.test.js
//
// pm 的验收标准第 4 条要求：`priv/web/*.js` 里所有 `JSON.parse(localStorage...)`
// 都要满足"坏值不致命"，且已发现 team-panel.js 那处是模块顶层无保护。
// 这里做两件事：
//   ① 真跑：把每个读取点所在的函数从源码里切出来，喂坏 localStorage，断言"不抛错 + 退回默认值"；
//   ② 站点清单：把当前所有 JSON.parse(localStorage...) 站点钉住，新增站点会让本用例红，
//      逼作者确认它同样容错（而不是靠人肉搜索）。

const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");

const ROOT = path.resolve(__dirname, "..", "..");
const read = (rel) => fs.readFileSync(path.join(ROOT, rel), "utf8");

// 按函数名切出 `function name(...) { ... }`（花括号配平，跳过字符串里的括号足够用）。
function extractFunction(source, name) {
  const lines = source.split("\n");
  const start = lines.findIndex((l) => new RegExp("function " + name + "\\s*\\(").test(l));
  if (start < 0) throw new Error("function not found: " + name);
  let depth = 0, started = false, out = [];
  for (let i = start; i < lines.length; i++) {
    out.push(lines[i]);
    for (const ch of lines[i]) {
      if (ch === "{") { depth++; started = true; }
      else if (ch === "}") depth--;
    }
    if (started && depth === 0) return out.join("\n");
  }
  throw new Error("unbalanced braces while extracting: " + name);
}

const APP = read("priv/web/app.js");

// 被测函数可能依赖 app.js 的统一读取出口 readStoredJson：把它一并注入沙箱，
// 否则用例测的是"复制品"而不是真实实现。
function withHelper(fnSource, helperOwner) {
  if (helperOwner !== "priv/web/app.js") return fnSource;
  return extractFunction(APP, "readStoredJson") + "\n" + fnSource;
}

function runWith(fnSource, { raw, expose }) {
  const store = new Map();
  if (raw !== undefined) store.set("k", raw);
  const localStorage = {
    getItem: (k) => (store.has(k) || k === "k" ? store.get(k) ?? null : null),
    setItem: (k, v) => store.set(k, String(v)),
    removeItem: (k) => store.delete(k),
  };
  const sandbox = { localStorage, Set, Object, Array, JSON, String, console };
  vm.createContext(sandbox);
  vm.runInContext(fnSource + "\nthis.__fn = " + expose + ";", sandbox);
  return { fn: sandbox.__fn, store };
}

// 各种"坏值"：非 JSON、类型不对、被截断、privacy 模式抛错
const BAD_VALUES = ["{\"unterminated", "not json at all", "12345", "null", "[1,2,3]extra", "\u0000"];

test("team-panel.js：坏值下 readCollapsedRuns 退回空集合且清掉坏键", () => {
  const src = extractFunction(read("priv/web/team-panel.js"), "readCollapsedRuns");
  for (const bad of BAD_VALUES) {
    // 让 getItem 命中固定的键：把实现里的字面量换成本测的键名
    const shaped = src.replace(/newbee\.teamCollapsed/g, "k");
    const { fn, store } = runWith(shaped, { raw: bad, expose: "readCollapsedRuns" });
    const out = fn();
    assert.ok(out && typeof out.has === "function", "坏值必须返回 Set: " + bad);
    assert.equal(out.size, 0, "坏值必须退回空集合: " + bad + " => size=" + out.size);
    assert.equal(store.has("k"), false, "坏键必须被清掉，否则每次加载都再抛一次: " + bad);
  }
});

test("team-panel.js：privacy 模式（getItem 直接抛）也不致命", () => {
  const src = extractFunction(read("priv/web/team-panel.js"), "readCollapsedRuns").replace(/newbee\.teamCollapsed/g, "k");
  const sandbox = {
    localStorage: { getItem: () => { throw new Error("SecurityError"); }, setItem: () => {}, removeItem: () => {} },
    Set, Object, Array, JSON, String, console,
  };
  vm.createContext(sandbox);
  vm.runInContext(src + "\nthis.__fn = readCollapsedRuns;", sandbox);
  assert.doesNotThrow(() => sandbox.__fn());
  assert.equal(sandbox.__fn().size, 0);
});

test("app.js：loadGroupCollapsed 坏值退回 {}", () => {
  const src = withHelper(extractFunction(APP, "loadGroupCollapsed"), "priv/web/app.js").replace(/newbee\.groupCollapsed/g, "k");
  for (const bad of BAD_VALUES) {
    const { fn } = runWith(src, { raw: bad, expose: "loadGroupCollapsed" });
    const out = fn();
    assert.equal(typeof out, "object", bad);
    assert.notEqual(out, null, bad);
    assert.doesNotThrow(() => Object.keys(out), "坏值必须返回可枚举对象: " + bad);
  }
});

test("app.js：xMy 坏值退回 null（JSON.parse 结果被直接使用）", () => {
  const src = withHelper(extractFunction(APP, "xMy"), "priv/web/app.js").replace(/"xgroup\.me\." \+ gid/g, '"k"');
  for (const bad of BAD_VALUES) {
    const { fn } = runWith(src, { raw: bad, expose: "xMy" });
    assert.equal(fn(), null, "坏值必须退回 null: " + bad);
  }
});

test("project-chat.js：loadSelection 坏值退回空集合", () => {
  const src = extractFunction(read("priv/web/project-chat.js"), "loadSelection").replace(/"xgroup\.reps\." \+ gid/g, '"k"');
  for (const bad of BAD_VALUES) {
    const { fn } = runWith(src, { raw: bad, expose: "loadSelection" });
    const out = fn("g1");
    assert.ok(out instanceof Set || typeof out.has === "function", "坏值必须返回 Set: " + bad);
    assert.equal(out.size, 0, "坏值必须退回空集合: " + bad);
  }
});

test("站点清单：priv/web 下 JSON.parse(localStorage...) 的每一处都必须在册", () => {
  // 不是"看起来都对"的启发式：把站点逐条钉住。新增一处 → 本用例红，
  // 作者必须来确认它同样容错，然后把它加进 EXPECTED（并在上面补行为用例）。
  // 收敛后仍在函数内直接 JSON.parse(localStorage...) 的只剩这一处（自带 try/catch）。
  // 其余读取点已改走 readStoredJson（app.js 内 3 处）或在 team-panel.js 的 readCollapsedRuns 里
  // 用 try/catch 包住 —— 它们由下面的独立断言守护，不再出现在本清单里。
  const EXPECTED = ["priv/web/project-chat.js::loadSelection"];
  const found = [];
  const files = fs
    .readdirSync(path.join(ROOT, "priv/web"), { withFileTypes: true })
    .flatMap((d) => (d.isFile() && d.name.endsWith(".js") ? ["priv/web/" + d.name] : []))
    .concat(["priv/web/colony/md.js", "priv/web/colony/api.js", "priv/web/colony/store.js", "priv/web/colony/shell.js"])
    .filter((rel) => fs.existsSync(path.join(ROOT, rel)));

  for (const rel of files) {
    const lines = read(rel).split("\n");
    lines.forEach((line) => {
      if (!/JSON\.parse\(\s*(?:globalThis\.)?localStorage/.test(line)) return;
      // 找到该行所属的函数名（向上找最近的 function 定义）
      let owner = "<module-top-level>";
      for (let i = 0; i < lines.length; i++) {
        if (!new RegExp("function\\s+([A-Za-z0-9_$]+)").test(lines[i])) continue;
        // 简单判定：函数名行在目标行之前且该行之后（此简化足够定位唯一 4 处）
        if (i <= lines.indexOf(line)) {
          const m = lines[i].match(/function\s+([A-Za-z0-9_$]+)/);
          if (m) owner = m[1];
        }
      }
      found.push(rel + "::" + owner);
    });
  }

  // 统一出口必须真的存在且被调用（3 处已收敛到它）。
  const app = read("priv/web/app.js");
  assert.ok(app.includes("function readStoredJson("), "app.js 必须有 readStoredJson 统一出口");
  const users = (app.match(/readStoredJson\(/g) || []).length;
  assert.ok(users >= 4, "readStoredJson 至少被 3 个读取点 + 定义本身使用，实际 " + users);
  const panel = read("priv/web/team-panel.js");
  assert.ok(panel.includes("function readCollapsedRuns("), "team-panel 折叠状态必须有容错读取");
  assert.ok(!/const collapsedRuns = new Set\(JSON\.parse/.test(panel), "不许回到模块顶层裸 parse");

  assert.deepEqual(
    found.sort(),
    EXPECTED.sort(),
    "JSON.parse(localStorage...) 站点清单变了：新增的读取点必须先证明坏值容错，再登记到 EXPECTED\n实际: " +
      found.sort().join(", ")
  );
});
