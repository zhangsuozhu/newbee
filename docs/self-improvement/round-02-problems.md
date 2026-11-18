# 第 2 轮 · 发现产品不足（pm）—— 问题清单

- 角色：产品经理（pm）　阶段：发现产品不足　轮次：2
- 被测版本：`5ed39a6e8feece2cbfe3c1d309768769eb265c98` = `origin/main`（#229）
- 测量位置：会话独占工作树 `.worktrees/pm-r2`（detached；`deps -> ../../deps`）
- 提交状态：**未 commit / 未 push / 未合并**；主仓库 10 个在途文件全程未被触碰
- 输入资料：R2 基线（main）`round-02-baseline.md`、R1 的 pm/arch/dev/qa 四份交付
- 原始证据：`.worktrees/pm-r2/pm-evidence/`（**42 个文件 / 236 KB**：探针 29（含 `.out` 4 个与定位过程）、日志 7、`repro.sh`、`SHA256SUMS` 14 条全通过、`README.txt`；逐项见其 `README.txt`）

## 0. 结论与归属（先说清哪些是新的、哪些是复核）

**复核结果**：R1 的 8 条红线、基线的 U1–U5，在 `#229` 上**逐条仍可复现**——因为 R1 的补丁
从未进入 `origin/main`（`git log 5ac87bad..5ed39a6` 只有 #229 一个提交，且不含任何 R1 文件）。

**本轮新挖出的 2 条**（上游四份交付与基线都没有）：
- **R2P-03**（P0 安全）：Markdown 渲染的属性位不转义引号 + 链接不过滤 `javascript:` →
  模型/协作者文本可在 WebUI 执行脚本。命中面是 15 处 `="\${escapeHtml(...)}"`。
- **R2P-05**（P1 可用性）：`team-panel.js` 顶层 `JSON.parse(localStorage…)` 无保护 →
  一处坏值让 `window.NewbeeTeamPanel` 未导出，团队工作室**永久点不开且无提示**。

**本轮补上根因/可执行证明的 3 条**（现象上游已见，但不是"已知根因已修"）：
- **R2P-01**（P0）基线已点名 `runtime.ex:521` 用旧快照；本轮新增的是**可执行对照证明**
  （同一进程内"旧快照 → `:ignored`、旧 `stage_index`" vs "最新快照 → accept、3→4"）
  **以及 `team_test.exs:213` 把该缺陷写成预期断言**这一事实（所以 15/15 全绿会掩盖它）。
- **R2P-02**（P0）QA-D5 只报了"全局回退误中断"；本轮给出**根因行**
  （`client.ex:1086` 用 `:proplists.get_value/2`，缺键返回 `:undefined` 而非 `nil`），
  并补上另外两半：**深层 Task 丢失真实 scope**（Esc 停不住子树）、**`:undefined` 键清不掉**（永久污染）。
- **R2P-09**（P1）基线从线上数据看到"删了还在、点开复活"；本轮给出机制
  （`engine.ex:1272` 显式跳过 `visibility="work"` 的 conversations 清理 +
  `team.ex:402` 的 `session_map/0` 只按 `colony_id` 过滤、不看该会话是否还被某个 bee 持有）。

**其余 7 条**（R2P-04/06/07/08/10/11/12）是复核 + 补齐验收标准，**不算新发现**，
不重复下发给 dev，避免与 R1 已验收项产生第三份补丁。

**本轮入选 5 条：R2P-01、R2P-02、R2P-03、R2P-04、R2P-05**（理由见 §3）。

## 1. 方法与可复现性

```bash
cd .worktrees/pm-r2
ln -sfn ../../deps deps
bash pm-evidence/repro.sh            # 全部 12 条，实测 75.75 s，exit=0
ONLY="R2P-01 R2P-03" bash pm-evidence/repro.sh   # 只跑指定条目
```

实测记录（`pm-evidence/repro.log`，2026-11-17T16:01:50+08:00，`HEAD=5ed39a6`，
`loadavg 3.10`，`nproc=20`，`TMPDIR=/tmp/pm-r2-tmp`）：**exit=0，墙钟 75.75 s，15 个小节、204 行**。
脚本里每条都会打印 `EXIT=`，门禁外的命令一律有日志。

证据类型分三层，避免"只看代码就下结论"：

| 层 | 手段 | 用于 |
|---|---|---|
| 静态 | `grep`/行号定位 + `Path.wildcard` 复算 | 覆盖面、入口缺失、代码事实 |
| 进程内 | `mix run --no-start` 探针（真 Store / 真 Team / 真 Client） | 状态机、并发语义、删除闭环 |
| DOM | Node 渲染 + **jsdom**（计时器真实走秒、真解析 HTML） | 输入清空、注入、脚本可见性 |

> 注：真实浏览器（Playwright/Chromium）本轮**不可用**——Chromium 在本机启动后 20–60 s 内不返回
> （`Failed to send GetTerminationStatus message to zygote`，`--headless --dump-dom about:blank` 亦超时）。
> 因此 DOM 结论改用 jsdom（它执行真实的 HTML 解析与定时器），并在 §5 如实声明降级。

## 2. 问题清单

优先级：**P0** = 产品语义错误/安全/主流程阻断；**P1** = 确定性功能缺陷、用户可感知；**P2** = 证据与流程债。

### R2P-01（P0）auto 闸门永不推进：`stage_complete` 收到的是提交前的旧任务快照

- **现象**：`lib/newbee/colony/runtime.ex:521` 在 `Work.submit/4` **之后**调用
  `Team.stage_complete(task)`，但 `task` 是 `Work.submit` **之前**取的那份（`status=claimed`、
  `result=nil`）。`Team.stage_complete/1` 的第一道判定是
  `task["status"] in ["pending_review","done"] and is_binary(task["result"])`
  （`lib/newbee/colony/team.ex:494`），于是**必然**走 `{:ok, :ignored}`。
- **影响**：所有 `gate: "auto"` 的阶段（内置产研模板的 `develop`）完成后阶段号**永不前进**；
  上层看到的是"任务已 done 有成果、`stage_index` 4 天不动、详情区没有按钮"——这正是基线 U2
  的"项目不闭环"。它不是偶发，是**每次必现**。
- **证据**：
  - 探针 `pm-evidence/probe_auto_gate.exs`（真 Store/Team/Work）：
    ```
    现在阶段=develop gate=auto stage_index=3
    旧快照 status=claimed result=nil
    提交后最新 status=pending_review result="hon_l_s_69R_zyNhcT"
    用【旧快照】驱动 stage_complete -> {:ok, :ignored} ; stage_index=3 (期望前进)
    用【最新快照】驱动 stage_complete -> {:ok, %{...}} ; stage_index=4
    ```
  - 现有测试把这条件写入预期：`test/newbee/colony/team_test.exs:213`
    `{:ok, :ignored} = Team.stage_complete(dev_task)`，紧接 215 行注释自认"用旧快照会 ignored"，
    217 行再手动取新快照重试并通过 → 于是 `mix test test/newbee/colony/team_test.exs`
    **15/15 全绿**（`pm-evidence/team-auto-gate.log`），缺陷被测试合法化。
- **验收标准**（可判定）：
  1. `runtime.ex` 改为在 `Work.submit/4` 返回后重新读任务再调 `stage_complete/1`（禁改
     `stage_complete` 的判定语义去迁就旧快照）。
  2. `team_test.exs:213` 那条 `{:ok, :ignored}` 断言**删除**；改为"auto 阶段提交后
     `stage_index` 从 3 → 4"。
  3. 反向验证：把调用点改回旧快照 → 该新用例必须红。
  4. 端到端判据（改后必须成立）：`mix run --no-start pm-evidence/probe_auto_gate.exs`
     的两行结果必须都是 **`stage_index=4`**——即「用旧快照驱动」这一分支修复后**不再被走到**
     （调用点已改成读最新任务）。当前实测是 `stage_index=3`（见上）。
  5. 端到端体验：新建 2 阶段 auto 模板、跑完第一阶段 → 无需人工点击即进入第 2 阶段。

### R2P-02（P0）中断隔离双向失效：伪 scope `:undefined` 造成"误中断 + 停不住 + 永久污染"

- **现象**：`lib/newbee/llm/client.ex:1086` 用
  `:proplists.get_value(@interrupt_scope_key, dict)` 判断"祖先进程有没有注册 scope"。
  `:proplists.get_value/2` 在**键不存在**时返回 `:undefined`（不是 `nil`），于是
  `case ... do nil -> 继续向上找; scope -> {:ok, scope} end` 的 `nil` 分支**永远不进**，
  第一个没有 scope 的祖先就被当成"找到了"——scope 直接是 `:undefined`。
- **影响**（三种，全部实测）：
  1. **跨会话误中断**：任何 Task 里调用 `Client.interrupt()` 会写 VM 级键
     `{{Client, {:interrupt, :undefined}}, true}`；此后**所有** nil-scope 客户端在子进程里都读到"已中断"。
  2. **Esc 停不住子树**：真实 scope 在 `$callers` 的 depth≥2 丢失（实测 `{true,false,false}`），
     三层 Task 内的流不会被 Esc 取消 → 连接泄漏。
  3. **永久污染**：该键一旦写入，`clear_interrupt/0` 与 `clear_interrupt(client)` 都清不掉它
     （它们清的是 legacy 键或真实 scope 键），直到 VM 重启。
- **证据**：`pm-evidence/probe_interrupt_final.exs`
  ```
  [child interrupt/0] persistent=[{"{Newbee.LLM.Client, {:interrupt, :undefined}}", true}]
     -> B 在子进程看到 interrupted? = true（期望 false）
  main scope=#Reference<...> interrupted?=true
     depth1/2/3 = {true, false, false}（期望全 true）
  ```
  与 R1 QA-D5 的关系：QA-D5 只报了"全局回退误中断"这**一半**；本轮补上"深层丢失"与
  "`:undefined` 键清不掉"两半，并给出**根因行号**（1086），把它从"偶发抖动"变成"可推导的确定缺陷"。
- **验收标准**：
  1. `find_scope_in_callers/1` 必须显式区分"键不存在"与"值为 nil"（用
     `:proplists.lookup/2` / `Keyword.fetch` / `:undefined -> 继续`）。
  2. 无 scope 时**不再**写共享全局位：要么就地生成 scope，要么返回明确错误。
  3. 新增三条用例：① 子进程 `interrupt()` 后另一 nil-scope client 仍为 `false`；
     ② 三层 `Task` 内仍能读到真实 scope（`{true,true,true}`）；
     ③ 任一路径置位后 `clear_interrupt/0` 必须能把所有 `{Client, _}` persistent 键清干净。
  4. 反向验证：把判定改回 `get_value` + `nil` 匹配 → 三条用例全红。
  5. 附：现有 `test/newbee/llm/clienttest_test.exs:80`、`test/newbee/dee/kerneltest_test.exs:390`
     使用无 scope 的 `interrupt/0`，须改成显式 scope（否则新规则会把它们判红）。

### R2P-03（P0）Markdown 渲染可注入：属性位不转义引号 + 链接不过滤 `javascript:`

- **现象**（两处独立缺陷，都有一条"最短攻击串"）：
  1. `priv/web/app.js:6809` 的 `escapeHtml` **只**转 `& < >`，**不转 `"` 和 `'`**；
     而 `inline()` 把它用在**属性位置**（共 **15 处** `="\${escapeHtml(...)}"`）。
     `![a"onerror="alert(1)](x.png)` 渲染出
     `<img ... alt="a"onerror="alert(1)" ...>` → jsdom 解析出 `onerror` 属性（真浏览器会执行）。
  2. `inline()` 的链接/图片正则对 URL 无 scheme 白名单：
     `[点我](javascript:...)` 直接产出 `href="javascript:..."`。
- **影响**：`app.js` 把这些 HTML 通过 `innerHTML` 注入会话区，渲染的是**模型输出**与**远端蜂群回传文本**
  （含他人会话标题、群名、工具 payload）。即：只要模型/协作者/被抓取的网页内容里带上这段字符串，
  就能在本地 WebUI 里执行脚本、读走本地 Store（API key、会话、蜂群状态）。
  **这是本轮唯一"攻击者在产品边界之外"的缺陷**，其余问题都需要用户本地误操作。
- **证据**：
  - `pm-evidence/probe_markdown_xss.js`（Node，直接抽 `escapeHtml`/`inline`/`renderMarkdown` 求值）：
    ```
    img_attr_break: <img class="md-img" src="x.png" alt="a"onerror="alert(1)" loading="lazy" />
    link_js_scheme: <a class="md-link" href="javascript:alert(document.domain" ...>点我</a>)
    ```
  - `pm-evidence/probe_dom_jsdom.js`（jsdom 真实解析）：
    ```
    img_parsed_attributes: ["class=\"md-img\"","src=\"x.png\"","alt=\"a\"","onerror=\"window.__pwned=1\"","loading=\"lazy\""]
    img_has_inline_handler_attr: true
    anchor_js_scheme: true
    ```
  - 15 处属性位 sink 的行号已复核：2451 / 2554 / 2555 / 2600 / 2607 / 2608 / 2678 / 2683 /
    3121 / 4677 / 4729 / 7463 / 7499 / 7666 / 8204。
- **验收标准**：
  1. 新增 `escapeAttr`（转 `& < > " '`），**全部 15 处属性位**改用 `escapeAttr`；
     `escapeHtml` 保留给文本位（不得为了省事把 `escapeHtml` 改成超集后不动调用点——
     那会让纯文本位出现 `&quot;` 可见字符）。
  2. `inline()` 对 `href`/`src` 加 scheme 白名单：只允许 `http:`/`https:`/`mailto:`/相对路径；
     其余（`javascript:`、`data:`、`vbscript:`）降级为纯文本。
  3. 契约测试（放 `test/newbee/web/` 的源码契约或 `test/web/*.test.js`）：
     喂 `![a"onerror="x](y.png)`、`[t](javascript:alert(1))`，断言输出**不含** `onerror=` 与
     `href="javascript:`。
  4. 反向验证：把任一属性位改回 `escapeHtml`、或删掉 scheme 白名单 → 对应用例必须红。
  5. 不得用"全局禁 Markdown"或"所有内容走 `textContent`"达标（会破坏现有渲染功能）。

### R2P-04（P1）团队工作室 8 s 轮询仍会吃掉正在输入的草稿（U1 在 #229 复现）

- **现象**：`priv/web/team-panel.js:721` 每 8 s 调 `load(false)` → `render()` →
  `team-panel.js:155` **无条件** `body.innerHTML = ""` 后重建整棵树。
  面板里所有输入（组建页目标框、验收/打回意见、追加轮次）都在 `.tp-body` 内，因此必被替换。
- **影响**：用户输入到一半，8 s 后文字清空、焦点丢失。基线 U1 已用真实浏览器截图证实；
  本轮在 `#229` 上用 jsdom（计时器真实走秒）复现，且能给出**发生时刻**。
- **证据**：`pm-evidence/probe_panel_poll_wipe2.js`
  ```
  {t: 7513, present: true,  same: true,  value: "ABC", focus: true,  timerFired: 0}
  {t: 9015, present: false, same: false, value: null,  focus: false, timerFired: 1}   ← 8s 轮询首次触发
  {t: 10517,present: false, same: false, value: null,  focus: false, timerFired: 1}
  ```
  jsdom 下 `present=false, same=false` 即"节点被整块替换、内容丢失"。
- **验收标准**：
  1. 轮询重绘必须"保留正在编辑的输入"：新增守卫——当 `state.action`（内联表单打开）
     或 `document.activeElement` 位于 `.tp-body` 内时，`load(false)` **只更新数据不重绘**；
     或改为按 key diff 更新（不 `innerHTML=""`）。
  2. 回归用例（jsdom，真实等待 ≥9 s）：输入文字 → 等一次轮询 → 断言
     `same_node === true && value === 原文 && focused === true`。
  3. 反向验证：删掉守卫 → 该用例必须红（当前实现用它跑就是红）。
  4. 真实浏览器验收（有环境时）：打开工作室「组建」→ 输入 20 字 → 静置 10 min → 文字与焦点都在。

### R2P-05（P1）`localStorage` 一处坏值 → 团队工作室永久不可用（无自愈出口）

- **现象**：`priv/web/team-panel.js:745` 在**模块顶层**执行
  `new Set(JSON.parse(localStorage.getItem("newbee.teamCollapsed") || "[]"))`，无 try/catch。
  一旦该键被写成非 JSON（旧版本格式、手改、磁盘/隐私模式异常、其他脚本写入），
  整个 IIFE 抛错 → `window.NewbeeTeamPanel` **未定义** → `app.js:9316` 的
  `if (!inspectionMode && window.NewbeeTeamPanel)` 直接跳过 → 顶栏团队按钮**永远点不开**，
  且用户无任何提示、无恢复入口（只能手动清 localStorage）。
- **影响**：团队工作室是主界面唯一入口；坏一次就"功能消失"，且**不报错**（控制台之外无感知）。
- **证据**：`pm-evidence/probe_panel_corrupt_ls.js`
  ```
  threw: "SyntaxError: Unterminated string in JSON at position 8"
  panel_exported: "undefined"
  consequence: window.NewbeeTeamPanel === undefined → 顶栏团队按钮在 app.js:9316 的 if 判定为假，面板永久不可用
  ```
- **验收标准**：
  1. 顶层持久化读取必须容错：`try { ... } catch { 用默认值 + 清掉坏键 }`；
     `saveCollapsed` 已有 try，读取侧补齐。
  2. 用例：注入坏值 → `window.NewbeeTeamPanel` 必须存在且 `open()` 可用；坏键被修复。
  3. 反向验证：去掉 try → 用例必须红。
  4. 同类排查：`priv/web/*.js` 里所有 `JSON.parse(localStorage...)` 都要满足"坏值不致命"
     （本轮只发现这 1 处，dev 需顺带确认）。

### R2P-06（P1，流程）"绿"不可信：`#229` 上四项既有红线原样存在，且无任何 CI 兜底

- **现象**（全部在 `#229` 复测，非引用 R1 数字）：
  | 项 | 实测 | 命令 |
  |---|---|---|
  | 格式 | `exit=1`，**31 个文件**（lib 15 / test 16） | `mix format --check-formatted` |
  | 能力索引契约 | **1941 B > 1800**，`2/3 passed` | `mix test test/newbee/tools/tool_documentation_contract_test.exs` |
  | 前端套件 | **32 tests / 0 pass** | `node --test test/web/conversation-work.test.js` |
  | 分区覆盖 | **254 文件 / 覆盖 222 / 漏 32（283 例）** | 见 `pm-evidence/partition-coverage.txt` |
  | 统一门禁 | `mix newbee.gate` **不存在**（`ls lib/newbee/gate*` 无） | — |
  | CI | **无 `.github/`** | `ls .github` |
- **影响**：R1 的 8 条入选改动没有一条进入 `origin/main`，因此"测试通过"这句话在主干上仍不成立；
  任何后续轮次若不自带门禁，都会重复"改完是绿的、主干是红的"。
- **证据**：`pm-evidence/repro.log` 中 R2P-06 段落；`format-violations.txt`；`partition-coverage.txt`。
- **验收标准**（保证与 R1 不重复劳动）：
  1. 由 main 决定基线策略：**把 R1 的 `dev-r1.patch` 重定到 `5ed39a6`** 再继续，还是放弃重做；
     决定前后都要在 `mix newbee.gate` 上给出"改前 exit=1 / 改后 exit=0"的对照（同一 commit、同一 TMPDIR）。
  2. `mix newbee.gate` 落地后，`README` 不再把 `mix test.all` 描述成完整入口。
  3. 分区表覆盖 **254/254**，并有元测试（删任一行 → 红）。
  4. 前端 32 例必须并入 gate（不允许"不在任何 mix 门里"）。
- **本轮不入选**（它属于"重建验证基座"，与 R1 已验收的 R1P-01/05/09 是同一批工作，
  重复下发给 dev 只会产生第三份补丁）。**但它是 R3 的硬前置**。

### R2P-07（P1，协作）R1 的补丁已无法应用到当前主干

- **现象**：`git apply --check dev-r1.patch` 在 `5ed39a6` 上失败 3 处：
  `lib/newbee/commands.ex:23`、`lib/newbee/goal.ex:32`、`lib/newbee/goal/steering.ex:7`。
  根因是 `#229` 自身改动了这三个文件（`commands.ex` +108/−42、`goal.ex` +267/−21、`goal/steering.ex` +28/−8）。
- **影响**：R1 的 72 文件成果不能直接落地；若 dev 直接 `git apply` 会半途中断，
  若强行 `-3` 合并会在 goal 相关逻辑里产生语义冲突（`#229` 正是 goal 记账那次改动）。
- **证据**：`pm-evidence/patch-conflict.log`、`pm-evidence/repro.log` R2P-07 段。
- **验收标准**：由 main 裁决后，重定基线版本必须满足
  ① `git apply --check` 对目标 commit 通过；② 打完后 `mix newbee.gate`（或等价 6 步）exit=0；
  ③ 变更清单里**不包含** `lib/newbee/goal*.ex`、`lib/newbee/commands.ex` 的"顺带重排版"
  （那会掩盖真实冲突）。
- **本轮不入选**：需 main 决策（见 §4 待决事项）。

### R2P-08（P2）`archive_test` 仍然红：24/25（R1P-06 未落地）

- **现象**：`test/newbee/archive_test.exs` 唯一失败 `二次压缩回放含旧摘要的 envelope（旧摘要前缀）`
  （`archive_test.exs:384`），`Result: 24/25`。
- **影响**：R1 已定性"产品对、测试断言的是 #215 已废弃契约"，但**未落地**；主干上仍是红的，
  且"摘要前缀 == 路由 wire 投影"这条不变量**零守护**。
- **证据**：`pm-evidence/repro.log` R2P-08 段。
- **验收标准**：同 R1P-06（断言改为 wire 投影 + 新增守护用例 + 反向删 `project_chat_messages` → 恰好 2 条红）。

### R2P-09（P1）删除团队子会话后"幽灵会话"仍在：`conversations` 记录从未清理

- **现象**：`colony.bee.conversation.delete` 只把 sid 从 `bee["conversations"]` 摘掉；
  `conversations` 表里 `visibility="work"` 的记录被**显式跳过**
  （`lib/newbee/colony/engine.ex:1272` 的 `{:ok, %{"visibility" => "work"}} -> :ok`）。
  而 `Team.session_map/0`（`team.ex:402`）只按 `colony_id` 过滤，**不看该会话是否还被任何 bee 持有**，
  于是侧栏分组仍列出这个"已删除"的会话。
- **影响**：删了还在、点开重新生成空会话（基线 U3b 的机制），用户以为删除失败。
- **证据**：`pm-evidence/probe_ghost_session.exs`（真 Store/Engine，App 完整启动）
  ```
  删除前 session_map = ["sess_probe_work"]
  delete -> {:ok, %{"bee" => %{..., "conversations" => []}, "sessionId" => "sess_probe_work"}}
  删除后 session_map = ["sess_probe_work"]      ← 仍在
  conversations 仍存在 = :ok
  bee.conversations = []
  ```
- **验收标准**：
  1. `session_map/0` 需过滤"该 task 的会话已不在任何 bee 的 conversations 里"的记录；
     或删除路径同步清 `conversations`（二者取一，必须在方案里写明取舍与理由）。
  2. 用例：建 work 会话 → `delete_conversation` → `Team.session_map()` 不含该 sid；反向改回 → 红。
  3. 不许用"删除时把 run 一起删掉"达标（越权且破坏历史）。

### R2P-10（P2，功能缺口）团队层仍无删除入口（U3 复测）

- **证据**：`pm-evidence/probe_team_delete.exs`
  ```
  colony.team.template.delete -> {:error, "unknown_method", "未知蜂群方法"}
  colony.team.run.delete      -> {:error, "unknown_method", "未知蜂群方法"}
  colony.team.proposal.delete -> {:error, "unknown_method", "未知蜂群方法"}
  ```
- **影响**：模板/项目/提案只能建不能删，长期使用后列表不可管理。
- **验收标准**：三条 RPC 返回 `ok`；删除后 `colony.team.{templates,runs,proposals}` 不含该 id；
  删除 run 时子会话与工作项的策略（级联或拒绝）必须在方案中明确；含审计留痕。
- **本轮不入选**：工作量最大（3 RPC + 级联 + UI），且依赖 R2P-09 的会话归属口径。

### R2P-11（P2，环境）worktree 注册 421 条 / 11 G，清理需授权

- **实测**：`git worktree list | wc -l` = **422**（含主仓库）；`.git/worktrees` 注册 **421** 条，
  路径全部**存在**（`prunable=0`）→ `git worktree prune` 无法回收。
  分布：`.worktrees/` 下 290 条（**11 G**）、`.newbee/workspaces` 下 102 条（**2.7 G**）、仓库外 29 条。
  本轮自身新增 1 条（`pm-r2`）。
- **影响**：`/home` 91% 满；每次 `git worktree list` 输出 9 KB，工具输出被截断（本轮已发生 2 次）。
- **验收标准**：先给"停止泄漏"（测试结束删目录时同步 `git worktree remove`），再由 main 授权一次性清理；
  **授权前不得删除任何条目**（属破坏性操作）。

### R2P-12（P2，文档）两处文档事实错误（会误导后续轮次）

- `docs/conversation-work-operations.md:115` 写"前端行为 26 项通过"，引用
  `.newbee-tmp/conversation-final-node.log` —— 该文件**不存在**；套件真实是 **32 例、0 通过**。
- `README.md:349` 仍把 `mix test.all` 描述为"快速分区回归 + acceptance 的完整入口"，
  而它**不含格式检查、不含前端**（`mix.exs:43`）。
- **验收标准**：文档里的每个数字都能对应到仓库内**存在的**文件；README 指向唯一门禁入口。

## 3. 优先级与本轮入选范围

| ID | 优先级 | 类型 | 本轮入选 | 理由 |
|---|---|---|---|---|
| R2P-01 | P0 | 主流程阻断 | **是** | 每次必现；U2"不闭环"的根因；改动 1 行 + 测试改 1 处 |
| R2P-02 | P0 | 并发/正确性 | **是** | 根因已定位到行；影响跨会话数据流；R1 只报了一半 |
| R2P-03 | P0 | 安全 | **是** | 注入面来自模型/他人文本；15 处 sink 已枚举 |
| R2P-04 | P1 | 用户痛点 | **是** | U1 复发；守卫 + 1 条 jsdom 用例即可 |
| R2P-05 | P1 | 可用性 | **是** | 10 行内修复；失败模式是"功能静默消失" |
| R2P-09 | P1 | 数据一致性 | 否（R3） | 需先定"会话归属"口径，且与 R2P-10 联动 |
| R2P-06 | P1 | 验证基座 | 否（R3 前置） | 与 R1 已验收项重复，需 main 先定基座策略 |
| R2P-07 | P1 | 协作 | 否 | 需 main 裁决，见 §4 |
| R2P-08 | P2 | 测试债 | 否（R3） | R1P-06 顺延，验收标准已就绪 |
| R2P-10 | P2 | 功能缺口 | 否 | 工作量最大 |
| R2P-11 | P2 | 环境 | 否 | 需授权 |
| R2P-12 | P2 | 文档 | 否 | 低成本，随 R2P-06 一起做 |

**本轮入选 5 条：R2P-01、R2P-02、R2P-03、R2P-04、R2P-05。**
建议 arch 的方案顺序：R2P-01（1 行）→ R2P-05（10 行）→ R2P-04（1 守卫）→
R2P-02（`find_scope_in_callers` 重写 + 3 用例）→ R2P-03（`escapeAttr` + scheme 白名单 + 契约）。

**给 arch 的硬边界**（防止"改绿但不改对"）：
1. R2P-01 **不许**改 `Team.stage_complete/1` 的判定去迁就旧快照；只改调用点。
2. R2P-02 **不许**用"删掉 `interrupt/0` 公开函数"达标（TUI/CLI 依赖无参调用路径）。
3. R2P-03 **不许**全局关闭 Markdown 渲染，也**不许**只改 `escapeHtml` 一个函数而不动 15 处调用点。
4. R2P-04 **不许**把轮询间隔从 8 s 改成很长（治症状不治病根，且会破坏"待办及时性"）。
5. R2P-05 **不许**把 `localStorage` 整个弃用（折叠状态需要持久化）。

## 4. 需要 main 决策的两项（不阻塞本轮交付）

1. **基座策略**：R1 的 `dev-r1.patch` 已与 `#229` 冲突（R2P-07），R3 是
   "re-base 后继续"还是"放弃重做"？两者都要重新给出"改前 exit=1 / 改后 exit=0"的对照。
2. **授权**：R2P-11 的清理属破坏性操作（删 421 条注册 + 11 G 目录），**本轮未动**，需明确授权。

## 5. 未覆盖范围（如实声明）

1. **真实浏览器验证降级为 jsdom**：本机 Chromium 启动后不返回（`zygote` 通信失败，
   `--headless --dump-dom about:blank` 亦 60 s 超时），Playwright 全路径不可用。
   因此 R2P-03/R2P-04/R2P-05 的"DOM 层"结论来自 jsdom（真实 HTML 解析 + 真实定时器），
   **不是**像素级渲染证据；"剪贴板、真实事件循环下 8 s 抖动、CSP 生效"未验证。
2. **未跑全量门禁**：本轮只跑了单文件/单目录级命令（`team_test` 15 passed、`archive_test` 24/25、
   能力索引 2/3、前端 32/0、格式 31 文件、分区覆盖复算）。`mix newbee.test_fast` /
   全量单进程套件**未跑**（基线已测 1407 s/三次全红，本轮不重复烧机）。
3. **R2P-02 的真实 HTTP 流未复现**：探针在进程内验证了标志位语义（置位/读取/清理/跨进程可见性），
   没有起真实 SSE 连接验证"两路流一死一活"。QA-D5 已用 30 s 探针做过等价证明，本轮未重做。
4. **未定位**：`Newbee.Web.TerminalRegistry` 在 `--no-start` 下缺失导致
   `delete_conversation` 抛 `ArgumentError`（探针已绕过，应用启动后正常）；
   这说明**删除路径对运行时依赖是硬依赖**，若 Web 运行时未启动会 500 —— 未单独列为条目，
   建议 dev 在改 R2P-09 时顺手确认错误形态。
5. **否证记录（避免虚报）**：本轮曾怀疑 `Team.session_map/0` 会让同一蜂群的两个项目
   共享会话。实测**否证**：`start_run` 会给每个 run 建独立 colony，
   `probe_session_map6.exs` 输出 `{"项目A",["sess_probe_A"]}, {"项目B",["sess_probe_B"]}` —— 隔离正确。
   因此**未**列为缺陷。
6. **未做**：行覆盖率、跨主机、TUI 真机、真实模型调用（需计费授权）、移动端/其他浏览器内核。
7. **jsdom 不是仓库内依赖**：`probe_dom_jsdom.js` / `probe_panel_poll_wipe2.js` 借用
   `/home/alanx/data/git/anxin-combine/node_modules`（jsdom 30.0.1，`NODE_PATH` 注入）。
   仓库 `test/web/` 无 `package.json`、无 node_modules。因此这两条 DOM 结论**可复现但不可移植**：
   换机器若无 jsdom 会直接报 `Cannot find module 'jsdom'`。dev 若要固化成回归用例，
   需先决定是否把 jsdom 纳入仓库依赖（或改用 Playwright/bun 自带 DOM），
   **不得**把"本机有 jsdom"当成已有能力。


## 6. 证据索引

| 声明 | 证据文件（`pm-evidence/`） |
|---|---|
| R2P-01 auto 闸门恒 ignored | `probe_auto_gate.exs`、`team-auto-gate.log`（15 passed）、`repro.log` |
| R2P-02 伪 scope 三后果 | `probe_interrupt_final.exs`、`repro.log` |
| R2P-03 注入（渲染 + DOM） | `probe_markdown_xss.js` / `.out`、`probe_dom_jsdom.js`、`rendered.json` |
| R2P-04 8 s 轮询清空 | `probe_panel_poll_wipe2.js` |
| R2P-05 坏 localStorage | `probe_panel_corrupt_ls.js` / `.out` |
| R2P-06 四项红线 + 无 gate/CI | `format.log`、`format-violations.txt`、`doc-contract.log`、`partition-coverage.txt`、`repro.log` |
| R2P-07 补丁冲突 | `patch-conflict.log`、`repro.log` |
| R2P-08 archive 24/25 | `repro.log` |
| R2P-09 幽灵会话 | `probe_ghost_session.exs` |
| R2P-10 删除入口缺失 | `probe_team_delete.exs` |
| R2P-11 worktree 421/11G | 本文 §2 的实测命令（`git worktree list \| wc -l` = 422；逐个读 `.git/worktrees/*/gitdir` 复核 421 条路径全部存在；`du -sh .worktrees` = 11 G、`.newbee/workspaces` = 2.7 G） |
| 构建零警告 | `compile-dev.log`（`mix compile --warnings-as-errors` exit=0，68.77 s） |
| 全量可复现 | `repro.sh`（`bash -n` 通过 + 真实跑通 exit=0，75.75 s，12 条全覆盖）、`SHA256SUMS` 14 条全通过 |
