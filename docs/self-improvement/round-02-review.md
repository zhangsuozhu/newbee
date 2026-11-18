# 第 2 轮 · 复盘与下一轮目标（main）

- 角色：项目总协调人（main），阶段 6「复盘与下一轮目标」
- 基线版本：`5ed39a6e8feece2cbfe3c1d309768769eb265c98`（= `origin/main`，#229）
- 主仓库现状：`HEAD=845229327b3a8c9c220b557e9abab33d9d961532`（`fix/jspace-open-section`），在途 10 改 + 4 未跟踪目录
- 本轮复审工作树（新建，detached，`deps -> ../../deps`）
  - `.worktrees/main-r2-review` = `5ed39a6` + `dev-r2.patch` → 记为 **P**
  - `.worktrees/main-r2-review-base` = 纯 `5ed39a6` → **B**
  - `.worktrees/main-r2-headcheck` = `8452293` + 在途 10 文件 + `dev-r2.patch` → **I**（集成树）
  - `.worktrees/main-r2-inflight-ctl` = `8452293` + 在途 10 文件 → **C**（在途对照）
- 复审时间：2026-11-18 09:00–10:45（`nproc=20`，loadavg 2.0–15.6）
- 提交状态：**未 commit / 未 push / 未合并**（复盘是判定，不是发布）

数字全部来自本轮独立重跑，日志在 `r2-review-evidence/`（26 个文件，含 `SHA256SUMS` 与 `README.txt`，`sha256sum -c` **25/25 通过**）。沿用上游的结论都标注「沿用」；未复核的写进 §8。

---

## 一、结论

**未达目标；不能结束，不能合并；建议进 R3，且 R3 重点从「找新 bug」切到「把已修好的东西真正合入 + 让门禁说真话」。**

1. 增量是真的：5 条修复在独立干净树上 100% 复现（新用例 Elixir 4/8→8/8，JS 2/27→27/27；三处主判据分区失败集合逐条一致，改前绿改后红 = 0）。
2. 不能合并的原因不是「改动有错」，而是「交付物还不是可合并形态」：4 条阻断，其中 2 条是门禁本身不可信（G4 漏跑、G8 误杀），2 条是修复/入口不完整（U1 只修一半、R2P-01 的唯一回归用例不在任何门禁）。
3. 项目目标（100 轮以上自我改进）远未达成：2 轮下来**产品代码零合并**，R1/R2 补丁都还挂在工作树上，主仓库在途改动持续变长。

---

## 二、本轮收益（按可验证行为变化列）

### 2.1 五条入选修复的改前/改后（全部实跑）

| 条目 | 改前（B） | 改后（P） | 复核手段 |
|---|---|---|---|
| R2P-01 auto 闸门不推进 | `team_auto_gate_test` **1/4** | **4/4** | 两树跑同一份用例文件 `--no-compile --seed 1` |
| R2P-02 中断隔离 | `interrupt_scope_test` **3/4**；无 scope 主进程 `PLAIN_SPAWN_SEES=true`、`SPAWN_MONITOR_FROM_MAIN_SEES=true` | **4/4**；同两读数 **false/false**；有 scope 的跨进程仍 `true`（未误伤） | `mix run` 探针 + 用例，两树对跑 |
| R2P-03 Markdown 注入 | 真 Chrome：`img` 属性 `[class,src,alt,**onerror**,loading]`；`a[href]` 为 `javascript:` / `data:text/html…` / `vbscript:`（含 `java\\tscript:` 绕过） | `img` 属性 `[class,src,alt,loading]`；三种危险 scheme 降级为 `span.md-blocked`；正常 `https:` 图文不受影响 | **真浏览器** `google-chrome --headless --dump-dom`（非 jsdom） |
| R2P-04 8s 轮询吃草稿 | 焦点在场用例红 | 用例绿 | 上游 jsdom 用例（沿用） |
| R2P-05 坏 localStorage 冻结面板 | 4 个 JS 套件 **12 条只 2 条通过**（两套件加载期抛错） | **27/27** | `node --test` 四文件 |

R2P-03 必须改两份渲染器这点已用代码证据复核成立：`priv/web/app.js:163` 与 `priv/web/colony/md.js:80` 是两套独立实现，后者被 `colony/chat.js`、`taskcard.js`、`workflow.js` 引用（群聊/成果/任务卡全走它）。dev 追加修 `md.js` 是必要改动，不是扩范围。

### 2.2 可合并性的真实证据（本轮最值钱的产出）

- 补丁纯净：`dev-r2.patch`（15 文件 +1168/−80，sha256 `83b75e41…0cf16`）对 `5ed39a6` `git apply --check` 通过；应用后 `MIX_ENV=test mix compile --warnings-as-errors` = **exit 0**。
- 与主仓库在途改动不冲突（独立复核 dev/qa 结论）：
  - I 树：`git apply --check` **0**、编译 **0**、定向 **101 passed**、4 个新 JS 套件 **27/27**。
  - 语义面无交集：在途改动没有新增 `innerHTML`/`href=`/`src=`，也没触碰 `interrupt`/`persistent_term`/`proplists`。
  - 在途自带的 `conversation-work.test.js` 在 C 与 I 上都是 **41/44**，失败集合完全相同 → 不是本补丁引入。
- 主判据三分区同口径（各自树 TMPDIR、串行、`--seed 1`、`--warnings-as-errors`）：

| 分区 | B | P | 失败集合差异 |
|---|---|---|---|
| root（`test/newbee/*_test.exs` 去 acceptance） | 346/350，**4 红** | 346/350，**4 红** | `only_base=[]`、`only_patched=[]` |
| web（`test/newbee/web`） | 356/358，**2 红**，exit=3 | 356/358，**2 红**，exit=3 | 同上，逐条一致 |
| tools-tui | 185/188，**3 红** | 185/188，**3 红** | 同上，逐条一致 |

→ 「改前绿改后红 = 0」在三处主判据成立。

### 2.3 官方门禁在 P 上的首次完整运行

| 分区 | exit | 结果 |
|---|---|---|
| agent-dee | 0 | 116 passed, 13 excluded |
| environment | 0 | 149 passed |
| llm | 0 | 179 passed, 3 skipped |
| tools-tui | **2** | 186/188（`tool_documentation_contract` 1941>1800、`command_job_test` 超时断言） |
| web | **1** | **358 passed / 1 excluded 却 exit=1**（`--warnings-as-errors` 跑完后 abort） |
| collaboration | 0 | 160 passed |
| root | **2** | 316/350（34 红，绝大多数 60 s 超时） |

注：web 分区在门禁里是「0 条用例失败但被 `--warnings-as-errors` abort」（G8），而单独跑是 356/358 两红
（`colony_api_test` 的 `workspace.kind` 断言，B/P 同有，受同机 workspace 状态污染）——两个读数不矛盾，
前者是 G8，后者是既有脆弱断言。

墙钟 09:13:35 → 09:43:20 ≈ **1785 s**；期间 loadavg 峰值 15.6。
另：`mix test.acceptance` 在 P 上 **14/14，186.9 s，exit=0**。

---

## 三、复核后推翻/校正的上游结论

| # | 上游说法 | 我的复核 | 影响 |
|---|---|---|---|
| 1 | 「G4 漏跑 34（恶化 1）」 | 成立且更严重：`test/newbee/colony/team_auto_gate_test.exs` **不在任何分区**——R2P-01 的唯一回归保护不被门禁执行。基线 254 文件漏 33；改后 256 文件漏 34 | R2P-01 在门禁眼里等于没修 |
| 2 | 「G8 仍红，dev 只清 2/5 类警告」 | 根因已定位：**两个测试文件自身的警告**——`test/newbee/web/colony_team_api_test.exs:25`（`cid` 未使用）、`static_asset_allowlist_test.exs:12`（`import Plug.Conn` 未使用）；B/P 完全同两条 | 从「机制不明阻断」降级为「2 行可修阻断」 |
| 3 | 「G9 deprecation 6 条」 | 成立，来源仅 **2 个调用点**：`lib/newbee/event_log.ex:66`、`lib/newbee/collaboration/verification.ex:270`（`File.stream!/2,3` 参数序）；**不在补丁范围**，基线同有 | G9 是纯遗留项，不应记到 R2 |
| 4 | 「root 34 红多为负载抖动」 | 更明确：root **单独跑**（无并发）B/P 都是 **346/350，4 红，同一组 4 条**（2 条 `SessionIndexPerfTest` 计数断言、`goal_steering_test:64` 落盘位置断言、`archive_test:360`）。`archive_test:360` 单跑也红 → 不是纯抖动 | 门禁「34 红」不能当产品质量信号 |
| 5 | 「QA2-D3：6 个新测试文件不在分区」 | 数量校正：Elixir 新文件 2 个，`interrupt_scope_test` **在** llm 分区（`test/newbee/llm` 整目录覆盖），只有 `team_auto_gate_test` 漏；JS 4 套件**全部**不在任何 mix 门里（含既有的 `conversation-work.test.js`） | 阻断项：Elixir 1 个 + JS 4 个 |
| 6 | 「QA2-D2 无 scope + spawn_monitor 的 Esc 失效，需架构定性」 | 机制复现了（有 scope 的父 + `spawn_monitor` 子 → 子读不到 scope），但**产品路径不受影响**：`lib/` 内**没有任何** `Client.interrupt()` 无参调用；生产中断只走 `Loop.interrupt/1`（`SessionEvaluators` → `persistent_term` 置 scope + `send(kernel, :interrupt_llm)`），`stream_chat` 的 `spawn_monitor` worker 只是执行体，中断判定在父进程 `await_stream_chat/4`（持有 client） | 从 P1 阻断降级为记录项，**不进 R3 阻断** |
| 7 | 「U1 已修：34 s / 8 次轮询全存活」 | **只修了一半**。独立失焦探针：`KEEP_NODE=false`、`INNERHTML_WRITES_DELTA=1`——输入后点别处/切窗口，8 s 内节点仍被整块替换（`ta.value` 只在游离对象上，DOM 里读不到）。提案页 goal `textarea`（整块 `render()`）同病 | QA2-D1 成立，**R3 首项** |
| 8 | 「U3 删除缺失 / U3b 删除不闭环 / U4 无终止出口」 | 全部未触碰：`colony_api.ex:14` `@methods` 的 `colony.team.*` 只有 templates/save/seed/proposals/proposal.*/sessions/runs/run.{start,view,review,finish,extend}，**无 delete**；`Team` 模块无 `delete`；`finish`/`extend` 有但无归档 | 用户 P0 需求 3 条未动 |
| 9 | 「R1 补丁仍冲突 3 处（goal/commands）」 | 成立，且集成树上更糟：`dev-r1.patch` 在 `8452293`+在途上额外冲突 `test/newbee/colony/engine_test.exs:1`、`task_test.exs:7`、`test/web/conversation-work.test.js:815` | R1 已实质报废，需要重定基座的决定 |
| 10 | 「worktree 泄漏 422 行 / 注册 421」 | 现状 **`.git/worktrees` 624 注册**、`.worktrees` **14 GB**、`.git/worktrees` **54 MB**。实测可复现增长：跑一次 `conversation_decomposition_test.exs` → 614→621（**+7/次**），其中 **550** 个注册路径在测试 `tmp` 下。根因在产品代码 `lib/newbee/colony/workspace.ex:53`（`git worktree add --detach --no-checkout` 建完不 prune） | **本轮新定位的产品缺陷**（不是环境脏） |

---

## 四、残留阻断项（4 条，决定能不能合并）

| ID | 内容 | 证据 | 修它要多少 |
|---|---|---|---|
| **B1** | U1 只修一半：失焦后 8 s 内草稿仍被清空（QA2-D1） | 我的失焦探针 + 上游 jsdom 探针，两处输入面都复现 | 小：给 `isEditing()` 加「面板内存在非空 textarea 且未提交」态，或 `state.drafts` + `render()` 后回填 |
| **B2** | 新用例不进任何门禁（QA2-D3/G4）：`team_auto_gate_test.exs` 漏跑；4 个 JS 套件无入口 | 覆盖脚本：BASE 221/254 漏 33 → PATCHED 222/256 漏 34，`new_this_round_unmapped=[team_auto_gate_test.exs]`；`grep 'node --test'` 在仓库 **0 命中** | 小：`test_fast.ex` 分区表加 `colony`，`mix.exs` 加 `test.js` alias |
| **B3** | G8 误杀：web 358 全绿仍 exit=1 | 门禁日志原文 `ERROR! Test suite aborted after successful execution due to warnings while using the --warnings-as-errors option`；两条警告 B/P 同有 | 极小：2 行（删 import、`cid`→`_cid`） |
| **B4** | 门禁整体不可信：G2 31 文件 + G3 exit=1 + G9 2 调用点 | 格式集合 B/P `diff` 为空（31=lib 15+test 16）；G3 见 §2.3；G9 见 §3#3 | 中：G2 需一次全仓 `mix format`（31 文件皆既存），G9 2 行 |

**非阻断记录项**：QA2-D2（§3#6）；`mailto:` 新窗口；13 处未转义但不可利用的属性位；`clienttest_test.exs` 旧语义；R2P-03 未放行 `data:image/*`（更安全，建议保持）；`archive_test:360` 单跑也红，产品对/测试错仍未定性。

---

## 五、目标达成判断

| 目标 | 状态 | 依据 |
|---|---|---|
| 每轮产出可验证的产品增量 | **达成** | §2.1 五条改前/改后 + §2.2 三分区失败集合零新增 |
| 增量可独立落地（技术层面） | **达成** | §2.2 集成树 apply 0 / 编译 0 / 定向 101 / JS 27 |
| 增量已落地（提交或合并） | **未达成** | 主仓库 `HEAD=8452293`，R1/R2 补丁均未 commit，产品代码零合入 |
| 门禁把「绿」变成可信信号 | **未达成** | G3 红、G4 漏、G8 误杀、G9 遗留；`mix newbee.gate` 不存在、无 `.github/` |
| 用户 P0 反馈闭环（U1/U2/U3/U4） | **1.5 / 4** | U2 已修并有真用例；U1 半修；U3 删除、U4 归档未动 |
| 累计 100 轮以上 | 2 / 100+ | — |

**判定：本轮达「有真实增量」，未达「可结束」。继续 R3。**

---

## 六、R3 改进优先级

### P0（不做则 R3 无法收口）

1. **B2 门禁入口**：`test_fast.ex` 分区表加 `colony`；新增 `mix test.js` 跑 `test/web/*.test.js` 并进 `test.fast`。
   验收：G4 漏跑 34 → ≤ 既有遗留；`team_auto_gate_test` 出现在门禁输出；4 个 JS 套件 27/27 被门禁执行。
2. **B1 草稿守卫补全**：失焦场景必须保草稿。验收：失焦探针 `KEEP_NODE=true` 且 `INNERHTML_WRITES_DELTA=0`（两处输入面）。
3. **B3 G8 两行**：`cid`→`_cid`、删 `import Plug.Conn`。验收：web 分区 358 全绿时 exit=0。
4. **合并决策与执行**：R2 补丁（15 文件）已在集成树证明无冲突。建议 **R2 先落、R1 重定基座**（R1 在 `5ed39a6` 冲突 3 文件、在 `8452293`+在途 再冲突 3 个测试文件；QA-D1/D2/D3 的代码只存在于 R1 补丁，主干 `grep` 无结果）。此条**需人确认**，见 §9。

### P1（本轮新发现，值得下一轮做）

5. **worktree 泄漏（§3#10）**：`colony/workspace.ex` 建 worktree 不清理。验收：跑一次 `conversation_decomposition_test` 后注册数不变；`.git/worktrees` 不再单调增长。
6. **U3/U4 缺失能力**：`colony.team.{template,run,proposal}.delete` + 项目归档/终止出口；连带 U3b（删团队子会话后 `colony.team.sessions` 仍返回、点一下复活空会话、`colonies/conversations` 记录不清）。这是用户 P0 原话里完全没动的部分。
7. **G2/G9 一次收口**：全仓 `mix format`（31 文件，与补丁无关）+ 2 处 `File.stream!` 参数序。验收：G2 exit=0、G9 计数 0。
8. **`archive_test:360` 定性**：单独跑也红（B/P 同），必须给「产品错 / 测试错」结论——它是门禁 3 红里最持久的一条。

### P2（可选）

9. 门禁对负载敏感（同 commit 同 seed：门禁里 root 34 红 vs 单跑 4 红）：`test_fast` 固定 `max_cases`、关键用例加 `@tag timeout`，并把「分区单跑」写进判据。
10. R2P-03 是否放行 `data:image/*`（当前一律拦截更安全，建议保持并写进设计文档）。

---

## 七、本轮验证方法（可复跑）

```bash
# 0) 建对照树（已存在可跳过）
git -C /home/alanx/data/git/newbee worktree add --detach .worktrees/main-r2-review      5ed39a6
git -C /home/alanx/data/git/newbee worktree add --detach .worktrees/main-r2-review-base 5ed39a6
cd .worktrees/main-r2-review && git apply ../dev-r2/dev-evidence/dev-r2.patch

# 1) 改前/改后（逐文件；base 树需先拷入两个新用例文件）
MIX_ENV=test mix test --no-compile --seed 1 test/newbee/colony/team_auto_gate_test.exs   # B: 1/4  P: 4/4
MIX_ENV=test mix test --no-compile --seed 1 test/newbee/llm/interrupt_scope_test.exs     # B: 3/4  P: 4/4
node --test test/web/markdown-safety.test.js test/web/colony-markdown-safety.test.js \
             test/web/localstorage-safety.test.js test/web/team-panel.test.js            # B: 2/12 P: 27/27

# 2) 三分区同口径（各自 TMPDIR、串行、seed=1）
MIX_ENV=test mix test --no-compile --warnings-as-errors --seed 1 test/newbee/*_test.exs
MIX_ENV=test mix test --no-compile --warnings-as-errors --seed 1 test/newbee/web
MIX_ENV=test mix test --no-compile --warnings-as-errors --seed 1 test/newbee/tools test/newbee/tui

# 3) 门禁全跑（P 上已跑通，约 30 min）
MIX_ENV=test mix newbee.test_fast
MIX_ENV=test mix test.acceptance

# 4) 真浏览器 Markdown 注入（不依赖 jsdom；需要 /usr/bin/google-chrome）
bash r2-review-evidence/run-md-probe.sh      # 生成两树最小页面 → chrome --headless --dump-dom

# 5) G4 门禁覆盖率
python3 r2-review-evidence/cov-g4.py

# 6) worktree 泄漏复现
ls .git/worktrees | wc -l                                       # 624
cd .worktrees/main-r2-review && MIX_ENV=test mix test --no-compile test/newbee/colony/conversation_decomposition_test.exs
ls .git/worktrees | wc -l                                       # +7
```

证据文件（`r2-review-evidence/`，26 项：24 个日志/脚本/页面 + `README.txt` + `SHA256SUMS`；结构化摘要 `round-02-review.json`）：`test_fast-patched.log`、`root-only-{baseline,patched}.log`、`web-full-compare.log`、`web-warn-aserterr-compare.log`、`acceptance-patched.log`、`md-injection-real-browser.log`、`cov-g4.py`、`qa2d1-blur-probe.js`、`qa2d2-*.exs`、`md-probe-{patched,baseline}.html`、`run-*.sh`。

---

## 八、未覆盖范围（如实声明）

1. **没有做 base/patched 全 7 分区同窗口对照**：P 侧跑完整 `test_fast`；B 侧只对 root / web / tools-tui 三分区做单独同口径对照（base 的 `test_fast` 整跑被我中途停下——那次 base agent-dee 有 1 条 `DEE.RulesTest` GenServer 超时属负载抖动，继续跑无收益）。agent-dee / llm / environment / collaboration 的 base 对照**缺**。
2. **`mix test.acceptance` 只有 P 侧**（14/14 已跑），B 侧未对照。
3. **未在真实产品服务上验证 U1/U2**：只做了「渲染函数 + 定时器」级浏览器验证（Markdown 注入）和 jsdom 探针（草稿/中断），**没有**起真实 web 服务用 Playwright 走完整「开项目→推进→输入」链路。
4. **Markdown 注入只证到「结构上可注入」**：真浏览器确认 `onerror` 属性被解析、`href` 确为 `javascript:`；但探针里 `src=x.png` 在 dump-dom 时尚未触发 error，`pwned_after=0`——**没有**证明任意代码执行。
5. **只测 Chromium/Blink**（无 Firefox/WebKit/移动端），`document.hidden` 恒 false，「切后台暂停轮询」豁免未真正触发。
6. **worktree 泄漏只证「会涨 + 每次 +7 + 550 条落在 tmp 下」**：未验证 `git worktree prune` 的副作用与安全回收方案。
7. **未验证 R2P-02 在真实 SSE 双流下的表现**（沿用上游未覆盖声明），仅进程树/进程字典级探针。
8. **本轮未改任何产品代码**：只在复盘层面定性；新建 4 棵工作树 + 1 个证据目录，**清理需授权**。
9. `qa2d1/qa2d2` 探针是**我写的**最小复刻（不是 qa 的原探针），结论方向与 qa 一致但数值不可逐位对比。

---

## 九、需要决策者拍板的三件事

1. **基座策略**：R2 先在 `5ed39a6`/`8452293` 上独立落地、R1 重定基座后再评估（我的建议）——还是等 R1 一起走？
2. **是否授权清理工作树/注册表**：`.worktrees` 14 GB、`.git/worktrees` 624 注册（550 在测试 tmp 下）。清理**不可逆**，不擅自做。
3. **R3 范围**：只做 P0 四项（合入 + 门禁可信化），还是同时塞 U3/U4 功能缺失（P1 第 6 项）？
