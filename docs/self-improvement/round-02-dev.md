# 第 2 轮 · 修改代码（dev）—— 交付

- 角色：研发工程师（dev）　阶段：修改代码　轮次：2
- 上游输入：arch 第 2 轮方案（`.worktrees/arch-r2-spike/docs/self-improvement/round-02-plan.md`，sha256 `c779cdf3…`）
  + pm 问题清单（`round-02-problems.md`）+ main 基线（`round-02-baseline.md`）+ R1 四份交付
- 改造基线：`5ed39a6e8feece2cbfe3c1d309768769eb265c98` = `origin/main`（#229）
- 会话独占工作树：`.worktrees/dev-r2`（分支 `dev-r2`，写入）
  - 对照树 `.worktrees/dev-r2-base`（同一 commit，纯净，未打补丁）
  - 移植验证树 `.worktrees/dev-r2-verify`（同一 commit，从 0 应用本补丁，跑完整套件）
  - 定稿复验树 `.worktrees/dev-r2-verify2`（同上，补丁最后定稿后再从 0 应用一次）
  - 集成验证树 `.worktrees/dev-r2-maincheck`（主仓库在途改动 + 本补丁）
- 提交状态：**未 commit / 未 push / 未合并**；主仓库在途 10 文件 + 4 未跟踪目录全程未触碰

## 0. 成果位置

| 项 | 位置 | 说明 |
|---|---|---|
| 本交付 | `.worktrees/dev-r2/docs/self-improvement/round-02-dev.md` | 本文件 |
| **可移植补丁** | `.worktrees/dev-r2/dev-evidence/dev-r2.patch`（**15 文件 +1168 / −80**，代码+测试；本交付文档不在补丁内） | sha256 `83b75e41d0de9403a2dbeb63c6faf46ec1f553f46d3fbd0ea39784cb9370cf16`；对纯净 `5ed39a6` `git apply --check` 通过，并在第二棵干净树**实际应用后跑通** |
| 原始证据 | `.worktrees/dev-r2/dev-evidence/` | 基线/补丁树的完整单进程套件日志、分区日志、JS 日志、定向日志 |

## 1. 本轮实现范围（arch 入选 5 条 → 全部落地）

| 条目 | 改动文件 | 改动实质 | 风险 |
|---|---|---|---|
| **R2P-01** auto 闸门不推进 | `lib/newbee/colony/runtime.ex`（+11/−1） | 提交成功后重读一次任务再交给 `Team.stage_complete/1`；读不到退回旧快照（`Store.get_task` 失败即与改动前等价）。**不动** `stage_complete` 判定 | 低 |
| **R2P-02** 中断隔离三处失效 | `lib/newbee/llm/client.ex`（+82/−24） | ① `:proplists.lookup/2` 区分"缺键"与"值为 nil"，消灭 `{:interrupt, :undefined}` 伪 scope；② 删 VM 级 legacy 键，改进程树内 `Process.put(@interrupt_tree_key, true)`；③ `clear_interrupt/0` 清本树位。公开 API 签名/返回类型不变 | 中（语义收紧，见 §6） |
| **R2P-03** Markdown 可注入 | `priv/web/app.js`（+83/−30）+ `priv/web/colony/md.js`（+47/−4） | 新增 `escapeAttr/escapeQuote/safeUrl/imgTag/linkTag`；`app.js` **18 处属性位**改用 `escapeAttr`；`colony/md.js` 同样改造（**这是 arch 方案未覆盖的第二份渲染器，本轮新发现并一并修复**） | 中 |
| **R2P-04** 8 s 轮询吃草稿 | `priv/web/team-panel.js`（+30/−8 中的一半） | `isEditing()` 守卫 2 处（`load` / `loadDetail`），8 s 间隔不变 | 低 |
| **R2P-05** 坏 localStorage 冻结面板 | `priv/web/team-panel.js` + `priv/web/app.js` | `readCollapsedRuns()` 容错 + 清坏键；`app.js` 新增统一出口 `readStoredJson/3`，把 `loadGroupCollapsed` / `xMy` / `loadCollabSeen` / `loadSessionUnread` / `loadSessionSeen` 全部收敛过去 | 低 |

**本轮 dev 追加的、方案之外但有实测证据的两处**：

1. **两份 Markdown 渲染器只修一份等于没修**：仓库里 `priv/web/app.js` 与 `priv/web/colony/md.js` 各有一份 `renderMarkdown`，
   蜂群群聊 / 成果报告 / 工作卡走后者。改动前实测：
   `![a"onerror="alert(1)](x.png)` → `alt="a"onerror="alert(1)"`（真属性注入）、
   `[点我](javascript:alert(1))` → 真 `href`。修复后 `alt="a&quot;onerror=&quot;alert(1)"`、仅剩 `<span class="md-blocked">`。
2. **编译警告是门禁硬阻断**：`test/newbee/colony/task_test.exs:10`（默认形参从未被 0 参调用）与
   `test/newbee/colony/engine_test.exs:4`（未用 alias `Task`）在 `--warnings-as-errors` 下让整个分区判红
   （改前实测 `Result: 455/456 passed` 但 `EXIT=2`/`ERROR! aborted`）。已各自一行修掉。

## 2. 增补的测试（6 个新文件 / 35 条用例）

| 文件 | 条数 | 守护什么 |
|---|---|---|
| `test/newbee/colony/team_auto_gate_test.exs` | 4 | 走真实 `Runtime.project_remote/3` 提交路径，`stage_index` 3→4；重复 done 幂等；review 闸门不越权推进；**旧快照仍 `:ignored`**（判定语义不许改的守护） |
| `test/newbee/llm/interrupt_scope_test.exs` | 4 | 跨会话树不误中断；三层 Task 都读得到真 scope；不存在 `{:interrupt, :undefined}` 伪 scope；`clear_interrupt/0` 只清自己树 |
| `test/web/markdown-safety.test.js` | 9 | `app.js` 属性位不可被引号闭合（引号感知属性解析，不误判 `alt="…&quot;…"`）；scheme 白名单含大小写/Tab/前导空白变体；文本位不出现可见 `&quot;`；既有语法不回归；**源码契约**：属性位不得再出现 `escapeHtml(` |
| `test/web/colony-markdown-safety.test.js` | 8 | 同上，针对 `colony/md.js`；另加"两份渲染器都必须保留 `safeUrl`"的反向守护 |
| `test/web/team-panel.test.js` | 4 | 坏 localStorage 下 `window.NewbeeTeamPanel` 仍导出、`open()` 不抛、坏键被清；8 s 轮询在编辑中不写 `body.innerHTML`、草稿/焦点存活；**反向**：无编辑时轮询照常重绘（守卫不能把面板冻死） |
| `test/web/localstorage-safety.test.js` | 6 | 6 类坏值（截断 JSON / 非 JSON / 数字 / `null` / 尾随字符 / NUL）下 4 个读取点都退回默认值；隐私模式（`getItem` 直接抛）不致命；**站点清单**：`JSON.parse(localStorage…)` 的剩余站点被钉死，新增站点会让用例红 |

合计新增用例 **35 条**（Elixir 8 + JS 27）。既有测试同步改 2 处（都是"把缺陷写成预期"的那种）：
`test/newbee/colony/team_test.exs:210`（原断言 `{:ok, :ignored}`，改为走真实 Runtime 路径）、
`test/newbee/dee/kerneltest_test.exs:389`（原用无 scope 的 `interrupt/0`，改为显式 scope 复刻残留位）。

## 3. 真实验证（全部有日志，无推断值）

### 3.1 构建

| 树 | 命令 | 结果 |
|---|---|---|
| `dev-r2` | `MIX_ENV=test mix compile --warnings-as-errors` | **exit=0**（0 warning） |
| `dev-r2-verify`（从 0 打补丁） | 同上 | **exit=0**（日志 `dev-evidence/verify-clean-tree-compile.log`，末行 `Generated newbee app`） |
| `dev-r2-maincheck`（主仓库在途 + 本补丁） | 同上 | **exit=0** |

格式：`mix format --check-formatted` 在本树报 **40 文件**未格式化，**均非本轮改动文件**（我改的 8 个 `.ex/.exs` 逐个用
`grep -qx` 对照清单全为 OK）；基线 `dev-r2-base` 同样报未格式化 → 属 R2P-06/R1P-04 的既有欠账，本批刻意不碰（避免与 R1 补丁产生第三份冲突）。

### 3.2 定向用例（改后）

`TMPDIR=<本树> mix test --no-compile --warnings-as-errors --seed 1 <7 文件>`
→ **101 passed / EXIT=0**（`dev-evidence/exunit-targeted.log`）。

### 3.3 JS 套件

| 文件 | 改后 | 改前（同一份用例跑基线树） |
|---|---|---|
| `markdown-safety.test.js` | 9/9 | 套件无法加载（`safeUrl` 缺失）→ 0 |
| `colony-markdown-safety.test.js` | 8/8 | 套件无法加载 → 0 |
| `team-panel.test.js` | 4/4 | **1/4**（R2P-04/05 两条红） |
| `localstorage-safety.test.js` | 6/6 | （新增；对应实现点改前 3 红） |
| `conversation-work.test.js`（既有） | **32 tests / 0 pass** | 同样 32/0 —— **改前就红，不属本轮范围**（R2P-06） |

### 3.4 同一口径全量单进程对照（这是本轮的主判据）

同一台机、同 seed=1、`TMPDIR` 各自树内（避开基线记录的 `/tmp` 满盘假红）、串行、`--no-compile`：

| | 基线 `dev-r2-base` | 改后 `dev-r2` | 改后 `dev-r2-verify`（从 0 打补丁） |
|---|---|---|---|
| 用例声明 | 1772/1793 | **1781/1801** | **1781/1801** |
| 失败数 | **21** | **20** | **20** |
| 墙钟 | 445.2 s | 537.4 s | 410.0 s |
| 新增用例 | — | +8 条全绿（另外 27 条 JS 不在 mix 里） | 同 |

**失败集合对比（逐条 diff，不是数量对比；键 = `文件:行 + 模块`）**：
- **基线 ∩ 改后（dev-r2，同 seed 同口径）= 20 条完全相同，新增失败 0 条**：
  `fstest:17`、`archive_test:360`、`goal_steering:64`、`error_contracts:49`、`repomap*`(10)、
  `repomap_budget*`(2)、`tool_documentation_contract:8`、`colony_api:252/328`。
- **只在基线红 1 条**：`web/project_chat_test:110`（抖动）。
- **只在改后红：0 条**。
- 从 0 打补丁的 `dev-r2-verify` 与基线：共同 19 条；只在基线 2 条（`learning/pipeline_test:52`、`project_chat:110`，抖动）；
  只在补丁树 1 条 `web/collaboration_api_test:365`（`queued_message` 时序）—— 该文件单跑 seed 1/2/3 三次全 20 passed，
  基线侧同类抖动上一轮已记录，不归因于本补丁。
- 结论：**没有一条「改前绿、改后红」的稳定失败**。
**带 `--warnings-as-errors` 的全量跑**（同一棵树 `dev-r2`，seed=1，`dev-evidence/full-suite-seed1-wae.log`）：
`Result: 1782/1801 passed, 13 skipped, 14 excluded / Failed: 19`，与基线 21 条相比
**是严格子集（新增失败 0 条）**。全量模式下 `--warnings-as-errors` 未触发 abort（`grep aborted` = 0），
但**单跑那两个含警告的文件就会 abort**（基线与改后一致，见 §6 第 4 条）。

### 3.4b 交付前的最终复验（补丁最后定稿后重跑，避免"文档与补丁不同步"）

| 动作 | 命令 | 结果 |
|---|---|---|
| 干净树打补丁（`.worktrees/dev-r2-verify2`，另起一棵从 0 应用） | `git apply --check` → `git apply` | **CHECK_OK / APPLIED**，无 fuzz |
| 该树编译 | `MIX_ENV=test mix compile --warnings-as-errors` | **exit=0** |
| 该树定向 5 文件 | `mix test --no-compile --warnings-as-errors --seed 1 …` | **72 passed** |
| 本树定向 7 文件（写交付文档后再跑） | 同上 | **101 passed / EXIT=0**（`dev-evidence/exunit-targeted.log`） |
| 本树 4 个新 JS 套件 | `node --test` | 9 + 8 + 4 + 6 = **27 passed / 0 failed**（`dev-evidence/js-suites.log`） |
| 证据目录完整性 | `sha256sum -c SHA256SUMS` | **11/11 成功** |

补丁在这轮复验前后 sha256 未变（`83b75e41…`），说明"文档改动不进补丁、补丁内容稳定"。

### 3.5 反向验证（证明新测试会红，不是恒绿）

| 反向操作 | 实跑结果 |
|---|---|
| 把 `runtime.ex` 还原成基线 | `team_auto_gate_test` **1/4 passed**（3 红，含"必须推进"那条） |
| 把 `client.ex` 还原成基线 | `interrupt_scope_test` **3/4 passed**（跨树误中断那条红） |
| 把 `team-panel.js` 还原成基线 | `team-panel.test.js` **1/4**（R2P-04/05 三条红，反向用例仍绿） |
| 把 `app.js` 还原成基线 | `localstorage-safety.test.js` **3/6**（3 红）；`markdown-safety` 套件无法加载 → 1 红 |
| 把 `colony/md.js` 还原成基线（`app.js` 保持修复） | `colony-markdown-safety.test.js` **0/8**，而 `app.js` 的 9 条**仍全绿** → 证明两份渲染器确实是两个独立注入面 |
| 删掉 `md.js` 里 `SAFE_LINK_SCHEME` 判断 | scheme 相关 3 条红（用例内断言） |

还原后均已复原并复跑确认回到全绿（补丁 sha256 在复原前后一致：`83b75e41…`）。

### 3.6 与主仓库在途改动的集成（QA-D4 / R2P-07 的 R2 侧回答）

- `dev-r2-maincheck` = 主仓库当前 HEAD `8452293` + 主仓库 **10 个在途文件**（`/tmp/main-inflight.patch`，`git apply` 成功）
  + 本补丁：`git apply --check` **exit=0**、`git apply` 成功、`mix compile --warnings-as-errors` **exit=0**、
  定向 5 文件 **72 passed**。
- 结论：**本补丁与主仓库在途改动不冲突**，可先落地（不依赖 R1 补丁）。
- R1 的 `dev-r1.patch`（72 文件）对 `5ed39a6` 仍冲突 3 处（`commands.ex` / `goal.ex` / `goal/steering.ex`），
  那是 R1 的重定基线问题，需 main 裁决；**本补丁刻意不碰 goal/commands 相关文件**。

## 4. QA 遗留必退项的逐条处置（R2 视角）

| QA 项 | 本轮处置 | 依据 |
|---|---|---|
| **QA-D5**（`Client.interrupt()` 无 scope 回退全局 → 一会话 Esc 掐断其它会话） | **已修**，即 R2P-02；新增 4 条用例 + 反向验证 | 改前跨树 `seen=true`，改后 `false`；`persistent_term` 残留 0 |
| **QA-D1**（`GateStream` 用 `IO.binwrite` 二次编码） | **不适用**：`GateStream` 只存在于 R1 补丁，主干上 `grep -rn GateStream lib test` 无结果 | 见 §7 未覆盖 1 |
| **QA-D2**（热路径缓存守卫恒真） | 同上，属 R1 补丁里的门禁代码 | 同上 |
| **QA-D3**（`@summary_bytes 66` 零触发） | 同上（`grep summary_bytes` 无结果） | 同上 |
| **QA-D4**（补丁与主仓库在途硬冲突） | **R2 侧已解**（§3.6 实测可共存）；R1 侧仍需 main 裁决 | — |

## 5. diff 摘要（按文件）

```
 lib/newbee/colony/runtime.ex                |  11 +-     提交后重读任务，修 auto 闸门
 lib/newbee/llm/client.ex                    |  82 +-     中断位按调用树隔离，消灭伪 scope
 priv/web/app.js                             | 122 +-     18 处属性位 + readStoredJson 统一读取出口
 priv/web/colony/md.js                       |  51 +-     第二份 Markdown 渲染器同样加固
 priv/web/team-panel.js                      |  38 +-     编辑守卫 + 折叠状态容错
 test/newbee/colony/engine_test.exs          |   3 +-     去掉未用 alias（门禁警告）
 test/newbee/colony/task_test.exs            |   3 +-     去掉未用默认形参（门禁警告）
 test/newbee/colony/team_test.exs            |  14 +-     原断言把缺陷写成预期 → 走真实路径
 test/newbee/dee/kerneltest_test.exs         |  11 +-     显式 scope 复刻残留位
 test/newbee/colony/team_auto_gate_test.exs  | 123 +      新
 test/newbee/llm/interrupt_scope_test.exs    |  97 +      新
 test/web/markdown-safety.test.js            | 181 +      新
 test/web/colony-markdown-safety.test.js     | 134 +      新
 test/web/team-panel.test.js                 | 214 +      新
 test/web/localstorage-safety.test.js        | 164 +      新
```

产品代码净增 **+227 / −57**；测试净增 **+831 / −23**。单条可回滚：每条都能独立 `git revert` 对应文件。

## 6. 已知限制 / 行为变化（必须让 main 与用户知悉）

1. **R2P-02 是语义收紧**：以前"任意子进程按 Esc 会把整机流掐断"（错误但曾是兜底）。现在无 scope 的中断**只作用于当前调用树**。
   CLI/TUI 不受影响（`cli.ex:8/268`、`tui.ex:79` 都显式注入 scope）；Web 会话走 `SessionEvaluators`（`{evaluator, scope}`）。
2. **R2P-03 有可见渲染变化**：不安全 scheme 的链接/图片不再渲染成 `<a>`/`<img>`，降级为
   `<span class="md-blocked" title="已拦截…">`。`data:image/*` 一律拦截（更安全，见 arch 决策点 2，未放行）。
3. **R2P-04 守卫的边界**：编辑中只跳过 `render()`，数据/徽标/详情请求照常；若用户在面板里"粘住"焦点超过一轮，
   视觉刷新会推迟到失焦/提交之后（这是有意的）。
4. **警告清理只做了 2/5 类**：剩余 `unused import Plug.Conn`（`static_asset_allowlist_test.exs:12`）与
   `variable "cid" is unused`（`colony_team_api_test.exs:25`）在基线上同样存在，**本轮未动**；
   `--warnings-as-errors` 跑全量套件仍会 `aborted after successful execution`（实测两个文件即可复现，基线与改后一致）。
   运行期 `File.stream!/3` deprecation（`event_log.ex:66`、`collaboration/verification.ex:270`）**仍未修**（QA-N3 / 基线 G9）。

## 7. 未覆盖范围（如实声明）

1. **QA-D1/D2/D3 无法在本轮修**：它们的代码（`GateStream`、`@summary_bytes`、热路径缓存守卫）只存在于 R1 补丁，
   主干 `grep` 无结果。若 main 决定先重定 R1 补丁，这三条在该补丁上再修；本轮不伪造"已修"。
2. **未跑 `mix newbee.test_fast` / `mix newbee.gate`**：`newbee.gate` 在 `5ed39a6` 上不存在（R2P-06）；
   `test_fast` 基线记录 "三次全红 + 对并发敏感"，本轮改用**同口径全量单进程 + 同 seed 对照**（§3.4），
   **跨分区串扰仍未验证**（单进程跑反而规避了它）。
3. **前端只在 Node 替身 / vm 沙箱验证**，**未在真实浏览器 / Playwright** 跑（本机 Chromium 不可用，基线已记录）。
4. **未做行覆盖率**（R1P-13）与性能指标（本轮无 perf 断言）。
5. **worktree 泄漏继续增长**：本轮新增 5 个（`dev-r2` / `dev-r2-base` / `dev-r2-verify` / `dev-r2-verify2` / `dev-r2-maincheck`），
   **清理属破坏性操作，需 main 授权**；四个树全部保留以便复核。
6. **R2P-06/08/09/10/11/12 全部未动**：格式 40 文件、能力索引契约、archive 24/25、分区覆盖、删除入口、文档错误。
7. **未起真实 SSE 双流**验证 R2P-02 的端到端行为；只用进程树探针 + 4 条用例。
8. **未验证"AI 流式生成 + 团队面板同时打开"** 的 R2P-04 场景。

## 8. 复现入口

```bash
# 1) 建树并打补丁（对纯净 5ed39a6）
git worktree add -b dev-r2 .worktrees/dev-r2 5ed39a6
cd .worktrees/dev-r2 && ln -s ../../deps deps
# 注意：dev-r2.patch 已包含 arch spike.patch 的全部内容（在其上继续修改），
# 因此只打这一个补丁即可；不要再叠加 spike.patch（会因上下文已改而失败）。
git apply ../dev-r2/dev-evidence/dev-r2.patch

# 2) 构建 + 定向 + JS
MIX_ENV=test mix compile --warnings-as-errors
TMPDIR=$PWD/.newbee-tmp MIX_ENV=test mix test --no-compile --warnings-as-errors --seed 1 \
  test/newbee/colony/team_auto_gate_test.exs test/newbee/llm/interrupt_scope_test.exs \
  test/newbee/colony/team_test.exs test/newbee/llm/clienttest_test.exs test/newbee/dee/kerneltest_test.exs
for f in test/web/markdown-safety.test.js test/web/colony-markdown-safety.test.js \
         test/web/team-panel.test.js test/web/localstorage-safety.test.js; do node --test $f; done

# 3) 同口径全量对照
TMPDIR=$PWD/.newbee-tmp MIX_ENV=test mix test --no-compile --seed 1     # 本树
cd ../dev-r2-base && TMPDIR=$PWD/.newbee-tmp MIX_ENV=test mix test --no-compile --seed 1  # 基线
```
