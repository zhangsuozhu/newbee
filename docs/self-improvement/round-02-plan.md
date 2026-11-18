# 第 2 轮 · 改进方案与风险（arch）—— 交付

- 角色：技术方案负责人（arch）　阶段：改进方案与风险　轮次：2
- 输入：pm 第 2 轮问题清单（`.worktrees/pm-r2/docs/self-improvement/round-02-problems.md`，sha256 `acbe3f59…f1e453`）
  + main 第 2 轮基线报告（`round-02-baseline.md`）、R1 四份交付
- 被测/改造基线：`5ed39a6e8feece2cbfe3c1d309768769eb265c98` = `origin/main`（#229）
- 工作位置：会话独占工作树 `.worktrees/arch-r2-spike`（detached；`deps -> ../../deps`）
- 提交状态：**未 commit / 未 push / 未合并**；主仓库在途 10 文件 + 4 未跟踪目录全程未触碰
- 本阶段方法：**方案不是纸面的**——五条入选项全部在 spike 里实现，并逐条做「改前红 / 改后绿」双向验证

## 0. 成果物清单

| 项 | 位置 | 说明 |
|---|---|---|
| 本方案 | `.worktrees/arch-r2-spike/docs/self-improvement/round-02-plan.md` | 本文件 |
| **可移植补丁** | `arch-evidence/spike.patch`（**10 文件 +799 / −55**，sha256 `8ee074a6…5fb03`） | 对纯净 `5ed39a6` `git apply --check` 通过，并在第二棵干净树 `arch-r2-verify` 实打实跑过 |
| 探针（Elixir） | `arch-evidence/probe_auto_gate_runtime.exs`、`arch-evidence/probe_interrupt_scope.exs` | 走真实调用点，非纸面推断 |
| 单向验证日志 | `arch-evidence/exunit-targeted.log`（72 passed, EXIT=0）、`arch-evidence/js-suites.log`（JS_EXIT=0） | 见 §4 |
| 新增测试（4 个文件） | `test/newbee/colony/team_auto_gate_test.exs`、`test/newbee/llm/interrupt_scope_test.exs`、`test/web/markdown-safety.test.js`、`test/web/team-panel.test.js` | 共 **26 条**用例 |

## 1. 入选范围与总体判断

pm 入选 5 条，本方案**全部给出并可落地**，建议按「风险最低 → 影响最大」的顺序：

| 序 | 条目 | 改动量 | 风险 | 兼容性 | spike 状态 |
|---|---|---|---|---|---|
| 1 | **R2P-01** auto 闸门不推进 | 1 行 + 10 行私有函数 | 低 | 纯内部调用点 | ✅ 已实现并双向验证 |
| 2 | **R2P-05** 坏 localStorage 冻结面板 | +20 行（替换 1 行） | 低 | 存储格式不变 | ✅ 已实现并双向验证 |
| 3 | **R2P-04** 8 s 轮询吃掉草稿 | +8 行守卫（2 处） | 低 | 无接口变化 | ✅ 已实现并双向验证 |
| 4 | **R2P-02** 中断隔离三处失效 | 净 +45 行（重写 1 个函数 + 回退语义） | 中 | 公开 API 签名不变；**两个既有测试需同步改** | ✅ 已实现并双向验证 |
| 5 | **R2P-03** Markdown 注入 | +30 行新函数 + 18 处调用点 | 中 | 渲染语义有可见变化（不安全链接降级） | ✅ 已实现并双向验证 |

**一句话结论**：五条都能在本轮以「单条可回滚的最小改动」落地；R2P-02 与 R2P-03 各有一个**必须由 main 决定的语义边界**（见 §6）。

---

## 2. 逐条方案

### 2.1 R2P-01（P0）auto 闸门永不推进 —— 「提交后重读一次任务」

**根因（复核过 `#229` 源码，非引用）**
`lib/newbee/colony/runtime.ex:507-521`：`task` 是 `Work.submit/4` **之前**取的那份
（`status=claimed`、`result=nil`），提交成功后仍拿它调 `Team.stage_complete/1`；
而 `team.ex:494` 的第一道判定是 `task["status"] in ["pending_review","done"] and is_binary(task["result"])`
→ **必然** `{:ok, :ignored}`。所有 `gate: "auto"` 的阶段（内置产研模板的 `develop`）完成后永不前进。

**最小改动（本次实测可行）**

```elixir
# runtime.ex:521 —— 只改调用点
if task["source"] == "team_run", do: Newbee.Colony.Team.stage_complete(stage_task(task["id"], task))

# 文件末尾新增私有函数（10 行）
defp stage_task(task_id, fallback) do
  case Store.get_task(task_id) do
    {:ok, fresh} -> fresh
    _ -> fallback          # 读不到就退回旧快照 = 与改动前行为一致
  end
end
```

**为什么这样改而不是别的**
- **不动 `Team.stage_complete/1` 的判定**（pm 硬边界 ①）：判定语义是"给我一份可验收的成果"，本身是对的；
  旧快照还能被外部复用（`team_test.exs` 的幂等用例），改判定会把幂等性弄坏。
- **不做 `Store.update` 后手动拼 map**：多一次写、且在 Store 事务外构造状态，容易和 revision 冲突。
- **读失败走 `fallback`**：Store 是 `GenServer`，`get_task` 超时/未启动时行为与今天完全一致（不新增崩溃面）。

**影响面**
| 面 | 影响 |
|---|---|
| 生产路径 | `Runtime.project_remote/3` 与 `project/3` 的 `kind in [:done, :text_end]` 分支（唯一调用点） |
| 行为变化 | `gate:"auto"` 阶段完成后 `stage_index+1`、写一条 `verdict: "accept"` 的历史、派发下一阶段任务 |
| 数据库 | 无 schema 变化；新增的是 `team_runs.history` 里本该有的那一条 |
| 其它 `source` | 非 `team_run` 任务不进该分支，零影响 |

**双向验证（实跑）**
```
改后：MIX_ENV=test mix run --no-start arch-evidence/probe_auto_gate_runtime.exs
  task.status=claimed source=team_run
  after Runtime 提交: stage_index=4 current_stage=test      ← PASS
改前：git checkout -- lib/newbee/colony/runtime.ex 后同一条探针
  after Runtime 提交: stage_index=3 current_stage=develop   ← FAIL（复现 pm 结论）
```
新增 `test/newbee/colony/team_auto_gate_test.exs`（4 条）：
1. 走 `Runtime.project_remote/3` → `stage_index` 3→4（**改前红**）；
2. review 闸门**不**自动推进（防过度推进；改前红，因为根本没走到下一步）；
3. `Team.stage_complete/1` 对旧快照仍 `{:ok, :ignored}`（**守判定语义不变**）；
4. 重复 `done` 事件只推进一次（幂等）。
改前基线跑该文件：**1/4 passed**（3 红）；改后 **4/4 passed**。

**兼容性 / 回滚**
- 删除 `stage_task/2` + 把 521 行改回 `stage_complete(task)` 即完全回滚（单行 + 私有函数，无外部引用）。
- **需同步改一个既有测试**：`test/newbee/colony/team_test.exs:210-222` 现在把缺陷写成了预期
  （`{:ok, :ignored} = Team.stage_complete(dev_task)` + 注释"用旧快照会 ignored"）。
  已改成走 `Runtime.project_remote/3` 并断言 3→4；旧快照契约的守护移到新文件的第 3 条。
  **不改这条测试，任何修复都会被它判红**——这是本轮必须一起下的改动。

---

### 2.2 R2P-02（P0）中断隔离双向失效 —— 「删掉伪 scope，改用进程树内的位」

**根因（三处，全部复核过）**
1. `client.ex:1086` 用 `:proplists.get_value(@interrupt_scope_key, dict)`：**缺键返回 `:undefined`**，
   而代码写的是 `nil -> 继续向上找` → `:undefined` 被当成"找到的 scope"，
   于是 depth≥2 的 `Task` 读到伪 scope `{:interrupt, :undefined}`（**Esc 停不住子树**）。
2. `interrupt(nil)` 在找不到 scope 时写 VM 级 `@interrupt_legacy_key`；
   任何进程按一次 Esc，**同一 VM 里所有 nil-scope 会话都读到"已中断"**（**跨会话误中断**）。
3. 该 legacy 键 `clear_interrupt/0` 只在 `:error` 分支清，而分支已因伪 scope 走不到 → **永久污染**。

**最小改动**

```elixir
# ① 区分"键不存在"与"值是 nil"
case :proplists.lookup(@interrupt_scope_key, dict) do
  {_key, scope} when not is_nil(scope) -> {:ok, scope}
  _ -> find_scope_in_callers(rest)        # :none / {_key, nil} 都继续向上
end

# ② 无 scope 时不再写共享键，只置本进程树内的位（pdict，子树经 $callers 继承）
def interrupt(_) do
  case find_interrupt_scope() do
    {:ok, scope} -> :persistent_term.put(scope_key(scope), true)
    :error -> Process.put(@interrupt_tree_key, true)     # ← 原来是 persistent_term legacy
  end
end

# ③ clear 清本树 + 该 scope；interrupted? 无 scope 时只看本树（绝不读全局）
```
`interrupted?/1` 变成 `tree_interrupted?() or (scope 位)`，其中 `tree_interrupted?/0`
读本进程 pdict，并沿 `$callers` 链查每个祖先的 pdict（`spawn/Task` 会记录调用树）。

**为什么不用"就地为当前进程申请 ref 再写 persistent_term"（我第一版这么写的，已废弃）**
两个实测理由：① 每棵树一个 ref 会让 `persistent_term` 常驻条目只增不减（`clear` 只在同进程树生效，
子进程 claim 出来的键无人回收）；② `clear_interrupt/0` 会**删掉本进程的 scope 注册**
（`Process.delete`），破坏"Loop 在本进程注册 scope"的既有约定。

**影响面**
| 面 | 影响 |
|---|---|
| 公开 API | `interrupt/0,1`、`clear_interrupt/0,1`、`interrupted?/0,1` **签名与返回类型不变** |
| 有 scope 的路径（生产主力） | 语义完全不变：仍写/读 `{Client, {:interrupt, scope}}` |
| 无 scope 的路径 | 语义**变严**：只影响本调用树，不再波及全 VM |
| 深层 Task | 语义**变好**：depth≥2 现在能读到真实 scope |
| `SessionEvaluators`/`Loop.interrupt` | 它们直接写 `{Client, {:interrupt, scope}}`，不受影响 |

**双向验证（实跑）**
```
改后 arch-evidence/probe_interrupt_scope.exs：
  a 树 interrupted?=false   b 树 interrupted?=false      ← 不再跨会话误中断
  main interrupted?=true
  depth1/2/3 = {true,true,true}                          ← Esc 停得住子树（改前 {true,false,false}）
  clear 后 main interrupted?=false
  persistent term 残留: []                               ← 不再泄漏
```
新增 `test/newbee/llm/interrupt_scope_test.exs`（4 条）：跨树隔离 / 三层 Task 可读 / 无 `:undefined` 伪 scope /
`clear_interrupt/0` 不清别的会话。**改前基线：3/4 passed（1 红，正是跨树隔离）**；改后 4/4。

**必须一起改的既有测试（2 处，否则新旧规则打架）**
1. `test/newbee/dee/kerneltest_test.exs:389`「中断标志：新一轮提交自动清除」
   用无 scope 的 `Client.interrupt()` 置位、再断言 `Loop.submit` 后 `interrupted?() == false`。
   新规则下 `interrupt/0` 置的是**本测试进程**的树位，`Loop` 在自己的进程里清自己的 scope，
   两者不再相关 → 该断言失去意义（改后必红）。**已改为用显式 scope 复刻"上一轮残留"**，
   断言 `Loop.submit` 清掉该 client 的 scope 位，且 `interrupted?()` 也不为真。
2. `test/newbee/llm/clienttest_test.exs:78` 的 `clear/interrupt/interrupted?` 往返：新规则下仍通过（已实测）。

**兼容性 / 回滚**
- 回滚 = 恢复 3 处 old 代码（`get_value` + `nil` 匹配、legacy 写、legacy 读清），单文件、无 migration。
- **行为可见变化**：以前"在任意子进程按 Esc 能把整机流掐断"（错误但曾被视为兜底）；
  现在只掐本树。**CLI/TUI 不受影响**（`cli.ex:8/268`、`tui.ex:79` 都显式注入 scope）。

---

### 2.3 R2P-03（P0，安全）Markdown 渲染可注入 —— 「属性位转义引号 + 链接白名单」

**根因（两处独立）**
1. `app.js:6809` 的 `escapeHtml` 只转 `& < >`，却被用在**属性位置**（共 15 处 `="${escapeHtml(...)}"`）
   → 一个 `"` 就能闭合属性并注入 `onerror=`。
2. `inline()` 的 `![alt](url)` / `[t](url)` 正则对 URL 无 scheme 校验 → `javascript:` 原样进 `href`。

**最小改动**

```js
// ① 新增属性位转义（escapeHtml 保持给文本位，避免纯文本里出现可见的 &quot;）
function escapeAttr(s) { /* & < > " ' 五字符全转 */ }

// ② 链接/图片 scheme 白名单：http(s)/mailto/相对路径；其余降级为纯文本
const SAFE_LINK_SCHEME = /^(?:https?:|mailto:)/i;
function safeUrl(raw) { /* 压紧控制字符后看 scheme；不合法返回 null */ }

// ③ 图片/链接改为函数式替换（原先是字符串模板，做不了判断）
t = t.replace(/!\[...\]\(...\)/g, (m, alt, url) => imgTag(m, alt, url));
t = t.replace(/\[...\]\(...\)/g,  (m, label, url) => linkTag(m, label, url));

// ④ 15 处属性位 → escapeAttr；4 处 class="…${...}" 位也一并转义（合计 18 处）
```

**关键实现细节（踩过的坑，写清给 dev）**
- 文本在 `inline()` 里**已经过 `escapeHtml`**，属性位只需要再补 `"`/`'`
  （`escapeQuote`）。直接上 `escapeAttr` 会把 `&` 二次转义成 `&amp;amp;`。
- 用函数式 `replace` 而不是 `$1/$2` 模板，才能"判断后返回不同结构"。
- 判断 scheme 前必须压紧 `\u0000-\u0020`：`java\tscript:` 浏览器会当成 `javascript:`。

**影响面**
| 面 | 影响 |
|---|---|
| 渲染语义 | **不安全链接/图片不再渲染成 `<a>`/`<img>`**，降级为 `<span class="md-blocked" title="已拦截…">原文</span>` |
| 安全链接 | `http/https/mailto/相对/锚点` 全部照常（已逐条断言） |
| 文本位 | 引号**原样保留**（不做超集转义，避免 `&quot;` 可见） |
| 样式 | `.md-blocked` 未加样式；不加也能用（继承段落字体） |

**双向验证（实跑）**
- pm 的 jsdom 探针在改后：`img_has_inline_handler_attr: false`、`anchor_js_scheme: false`。
- 新增 `test/web/markdown-safety.test.js`（**9 条**，含 1 条**源码契约**：属性位不得再出现 `escapeHtml(`）。
  **三条反向全部实跑**：
  | 反向操作 | 结果 |
  |---|---|
  | 18 处属性位改回 `escapeHtml` | **1 红**（源码契约） |
  | 删掉 `safeUrl` 的 scheme 判断 | **2 红** |
  | `escapeQuote` 退化成只转 `& < >` | **1 红** |
- 既有 Markdown 语法（粗体/行内代码/列表/表格/围栏块/标题/引用）在用例里逐项断言未被破坏。

**兼容性 / 回滚**
- 回滚：删 `escapeAttr/safeUrl/imgTag/linkTag/escapeQuote` 并把 18 处调用点改回 = 单文件、`git revert` 级。
- **风险点**：`data:image/...` 图片在 Markdown 里也会被拦（`app.js:8869` 的图片走 `img.src` 不走 Markdown，
  已确认不受影响）。若产品要求 Markdown 支持内联 data 图，可把 `data:image/` 加入白名单——
  但那就重新打开 `data:text/html` 的绕过面，**本方案不建议**（见 §6 决策点 2）。

---

### 2.4 R2P-04（P1）8 s 轮询吃掉草稿 —— 「编辑中只更新数据、不重绘」

**根因**：`team-panel.js:719` 每 8 s `load(false)` → `render()` → `body.innerHTML = ""`
无条件重建整棵 `.tp-body`；所有内联表单（组建目标、验收/打回意见、追加轮次、项目目标）都在里面。

**最小改动**

```js
function isEditing() {
  if (state.action) return true;                                  // 内联表单已打开
  const active = document.activeElement;
  return !!(els.body && active && els.body.contains(active) &&
            /^(INPUT|TEXTAREA|SELECT)$/.test(active.tagName));
}

async function load(showLoading) {
  ...
  if (showLoading || !isEditing()) render();                       // ← 只这一行守卫
  refreshBadge();
  if (state.detail) loadDetail(state.detail);
}
// loadDetail 里的 render() 同样加 !isEditing()（否则展开详情的轮询仍会重绘）
```
- **不拉长轮询间隔**（pm 硬边界 ④）：8 s 不变，徽标/数据仍按时刷新，只是不重绘。
- **不是"按 key diff"**：diff 重写要动整个 render 层，风险远大于收益；守卫是 8 行。

**影响面**：仅面板视觉刷新节奏；`state.action`/焦点两种触发条件覆盖了全部输入入口
（`actionForm` 一定设 `state.action`；组建页的 `goal` 是 `textarea`，聚焦即命中）。
数据更新、徽标、详情请求都不受影响（守卫只跳过 `render()`）。

**双向验证（实跑）**
- pm 的 jsdom 探针（真实 8 s 定时器）改后：`t=9049 present=true same=true value=ABC focus=true`（改前 `present=false value=null`）。
- 新增 `test/web/team-panel.test.js` 4 条（自带 DOM 替身 + 手动触发 8 s 定时器）：
  编辑中不重绘 / 焦点与草稿保留 / **无编辑时照常重绘**（防"守卫把面板冻住"）/ 坏 localStorage 场景 `open()` 可用。
  反向：把守卫拆成 `render();` → 1 红。

**兼容性 / 回滚**：删 `isEditing` 与 2 处守卫即回滚。

---

### 2.5 R2P-05（P1）坏 localStorage 让面板永久失效 —— 「顶层读取容错 + 清坏键」

**根因**：`team-panel.js:758` 模块顶层 `new Set(JSON.parse(localStorage.getItem(...) || "[]"))`，
无 try/catch；抛错 → IIFE 中止 → `window.NewbeeTeamPanel === undefined` →
`app.js:9316` 的 `if (... && window.NewbeeTeamPanel)` 恒假 → 团队按钮**永久点不开且无提示**。

**最小改动**

```js
function readCollapsedRuns() {
  let raw = null;
  try { raw = localStorage.getItem("newbee.teamCollapsed"); } catch (e) { return new Set(); }
  if (!raw) return new Set();
  try {
    const parsed = JSON.parse(raw);
    if (!Array.isArray(parsed)) throw new Error("not an array");
    return new Set(parsed.filter(x => typeof x === "string"));   // 顺带丢弃非字符串
  } catch (e) {
    try { localStorage.removeItem("newbee.teamCollapsed"); } catch (_) {}   // 自愈：清掉坏键
    return new Set();
  }
}
const collapsedRuns = readCollapsedRuns();
```
- **不弃用 localStorage**（pm 硬边界 ⑤）：折叠状态仍然持久化，只是坏值不会致命。
- 顺带覆盖"值是合法 JSON 但不是数组"（`{"a":1}`、`"x"`、`null`）：旧实现会得到 `Set("x")` 这类怪值。

**影响面**：折叠状态在坏值下**被重置**（可接受：这是坏值的唯一出口）；正常值行为完全不变。

**双向验证（实跑）**：pm 的 `probe_panel_corrupt_ls.js` —— 改前 `threw: SyntaxError / panel_exported: "undefined"`，
改后 `threw: null / panel_exported: "object"`。新增 `team-panel.test.js` 2 条（坏值可导出 + `open()` 不抛错），
反向：换回裸 `JSON.parse` → **2 红**。

**兼容性 / 回滚**：单函数替换，回滚无副作用。
**同类排查（pm 要求）**：`priv/web/*.js` 里 `JSON.parse(localStorage…)` 共 6 处——
`app.js:2164/2229/2233/3828`、`project-chat.js:539` 都已包 try/catch；
**只有 `team-panel.js:745` 这 1 处裸的**，本次已修，其它不动。

---

## 3. 影响面与兼容性汇总

| 维度 | 结论 |
|---|---|
| 对外 API / RPC | **零变化**。没有改任何 `colony.team.*`、`session.*` 的方法签名或返回结构 |
| 持久化数据 | **零 schema 变化**。R2P-01 只多写一条本该存在的 `history` 记录 |
| 行为语义变化 | ① auto 阶段会真的推进（这就是修复目标）；② 无 scope 的中断只作用于本调用树；③ 不安全 Markdown 链接降级为文本；④ 阻断期间轮询不重绘；⑤ 坏折叠键被重置 |
| 需要同步修改的既有测试 | **2 个文件**：`team_test.exs:210-222`（缺陷被写成预期）、`kerneltest_test.exs:389-398`（无 scope 用法） |
| 格式 / 编译 | 改动文件 `mix format --check-formatted` **exit=0**；`--warnings-as-errors` 编译 **exit=0** |
| 手工验证依赖 | 无新增依赖。JS 测试只用 `node:test` + 自写 DOM 替身（**不引入 jsdom**） |

## 4. 真实验证汇总（全部实跑，无推断）

| 验证 | 命令 | 结果 |
|---|---|---|
| 补丁可移植 | 干净树 `arch-r2-verify`（`5ed39a6`）+ `git apply` | apply-check **OK**，应用后 `mix compile` 通过 |
| R2P-01 单元 | `mix test test/newbee/colony/team_auto_gate_test.exs` | 改后 **4/4**；改前 **1/4**（3 红） |
| R2P-01 探针 | `mix run --no-start arch-evidence/probe_auto_gate_runtime.exs` | 改后 `stage_index=4`（PASS）；改前 `3`（FAIL） |
| R2P-02 单元 | `mix test test/newbee/llm/interrupt_scope_test.exs` | 改后 **4/4**；改前 **3/4**（跨树隔离红） |
| R2P-02 探针 | `mix run --no-start arch-evidence/probe_interrupt_scope.exs` | 见 §2.2；`persistent_term` 无残留 |
| 定向 Elixir 回归 | `team_auto_gate + team + interrupt_scope + clienttest + kerneltest`（`arch-evidence/exunit-targeted.log`） | **72 passed, EXIT=0** |
| R2P-03 | `node --test test/web/markdown-safety.test.js` | **9/9**；三条反向各 1–2 红 |
| R2P-04/05 | `node --test test/web/team-panel.test.js` | **4/4**；两条反向各 1–2 红 |
| 前端合计 | `arch-evidence/js-suites.log` | **13 passed / 0 failed, JS_EXIT=0** |
| 分区回归 | `mix test test/newbee/colony test/newbee/llm` | **361 passed, 3 skipped, exit=0** |
| 分区回归 | `mix test test/newbee/web` | **358 passed, 1 excluded, exit=0** |
| 分区回归 | `mix test test/newbee/dee` | **94 passed, 13 excluded, exit=0** |
| 分区回归 | `mix test test/newbee/tools` | **122/123**，唯一失败是**改动前就红**的能力索引契约（1941 B > 1800，属 R2P-06，与本批无关） |

**没有做反向验证的地方（如实声明）**：R2P-04/05 的"改前"证据用的是 pm 的 jsdom 探针 + 本方案的
替身用例（把守卫/容错拆掉即红），没有在真实浏览器上复现 8 s 抖动；R2P-02 没有起真实 SSE 双流。

## 5. 风险与回滚

| # | 风险 | 触发条件 | 缓解 | 回滚 |
|---|---|---|---|---|
| R2-1 | R2P-01 让"以前一直不推进"的项目突然开始推进，下游阶段被批量派发 | 线上已有 4 天未推进的 run | 派发走既有幂等检查（`dispatch_current` 比对 `team_stage`/`team_round`）；建议合并前先看线上 run 数量 | 单行回滚 |
| R2-2 | R2P-02 让"任意子进程按 Esc 掐断全机"这个**错误兜底**消失，若有第三方代码依赖它会失效 | 未在 `lib/` 找到此类调用（grep 过） | 已确认 CLI/TUI/Web 三条真实入口都显式注入 scope | 恢复 3 处旧代码 |
| R2-3 | R2P-03 让不安全链接不再可点，可能影响个别"本地文件链接"用法 | 用户贴 `file:///…` | 产品上更安全；如确有需要，白名单可加特定 scheme | 改回 `escapeHtml` + 删 `safeUrl` |
| R2-4 | R2P-04 守卫在"用户点着输入框但已经不想输入"时也会延迟重绘 | 焦点停留在 textarea | 仅延迟到失焦；徽标与数据仍实时更新 | 删守卫 |
| R2-5 | 两个既有测试必须同步改，若 dev 只改产品代码会红 | — | 本方案已给出改法（§2.1、§2.2） | 与代码同 commit |
| R2-6 | 五条改动混在一个补丁里，回滚粒度粗 | — | **建议 dev 按 §1 顺序拆 5 个独立 commit**（`spike.patch` 只为证明可落地，不是交付单位） | 逐 commit revert |
| R2-7 | R2P-06/07 的基座问题（R1 补丁冲突）仍未解，本批改动**无法**顺带修复格式/能力索引/前端旧套件 | 合并前 | 本批刻意不碰这些文件，避免与 R1 补丁产生第三份冲突 | — |

## 6. 需要 main 决策（不阻塞本交付，但阻塞 dev 开工）

1. **基座策略（承 R2P-06/07）**：本方案基于 `5ed39a6`（当前 `origin/main`）。
   R1 的 `dev-r1.patch` 与 `#229` 冲突 3 处。请裁决：
   **A) 本轮五条直接在 `5ed39a6` 上独立落地（推荐：互不依赖、单条可回滚）**；
   B) 先 rebase R1 补丁再叠加（会带来 goal 相关文件的语义冲突）。
2. **R2P-03 的 data URL 边界**：产品是否需要 Markdown 渲染 `data:image/*`？
   当前方案一律拦截（更安全）；若要放行，需要在白名单里**只**放 `data:image/`，且仍不能放 `data:text/html`。
3. **R2P-02 的行为变化确认**：接受"无 scope 的中断只作用于当前调用树"这一收紧了吗？
   （这是修好跨会话误中断的必然结果，没有第二种解法能不删 legacy 键。）

## 7. 未覆盖范围（如实声明）

1. **没跑完整门禁**（`mix newbee.test_fast` / `newbee.gate`）：基线实测 1407 s 且三次全红，
   本阶段只跑 5 个分区（colony/llm/web/dee/tools）+ 定向文件。**跨分区串扰未验证**。
2. **R2P-06/07/08/09/10/11/12 未动**：格式 31 文件、能力索引 1941>1800、前端旧套件 32/0、
   分区漏跑 32 文件、R1 补丁冲突、worktree 泄漏等，全部**保持原状**（本批刻意不碰）。
3. **R2P-03 未在真实浏览器验证**：本机 Chromium 不可用（基线已记录），只用 jsdom 探针 + 字符串断言。
4. **R2P-04 未验证"AI 流式生成 + 面板同时"**：只验证了轮询与编辑的交互。
5. **R2P-02 未起真实 SSE 双流**：只验证标志位的置位/读取/清理与进程树可见性。
6. **spike 工作树未提交**：`.worktrees/arch-r2-spike`（未 commit/push/merge），
   另建了 `.worktrees/arch-r2-verify`（纯净树打补丁验证用，含 `_build`，未清理）。
   worktree 注册数本轮 **+2**，清理需授权。
## 8. 证据目录索引（`.worktrees/arch-r2-spike/arch-evidence/`）

| 文件 | 内容 |
|---|---|
| `spike.patch` | 10 文件 +799/−55，sha256 `8ee074a6…5fb03`；对纯净 `5ed39a6` `git apply --check` 通过，并在 `.worktrees/arch-r2-verify` 实际应用后跑通（23 Elixir 用例 + 13 JS 用例） |
| `probe_auto_gate_runtime.exs` | R2P-01 探针（走真实 `Runtime.project_remote/3`） |
| `probe_interrupt_scope.exs` | R2P-02 探针（跨树隔离 / 三层 Task / 清理残留） |
| `exunit-targeted.log` | 72 passed, `EXIT=0` |
| `js-suites.log` | 13 passed, `JS_EXIT=0` |
| `reverse-verification.txt` | 全部反向验证实跑记录 |
| `README.txt` / `SHA256SUMS` | 复现入口与校验和（`sha256sum -c` 全通过） |

（正文 24,531 B / sha256 `dcefa7cc…143b1d0`；加本节后 25,398 B——以文件实际 sha256 为准。）
