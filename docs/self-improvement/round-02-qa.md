# 第 2 轮 · 测试验证（qa）—— 测试报告

- 角色：测试工程师（qa）　阶段：测试验证　轮次：2
- 被测补丁：`dev-r2.patch`，15 文件 +1168/−80，sha256 `83b75e41d0de9403a2dbeb63c6faf46ec1f553f46d3fbd0ea39784cb9370cf16`
- 被测基线：`5ed39a6e8feece2cbfe3c1d309768769eb265c98` = `origin/main`（#229）
- 工作位置（会话独占，互不共用写入目录）
  - `.worktrees/qa-r2` patched（写入）
  - `.worktrees/qa-r2-base` base（纯净对照）
  - `.worktrees/qa-r2-rev` 反向验证（逐文件还原/恢复）
  - `.worktrees/qa-r2-integ` / `-integ-base` 集成验证（主仓库 HEAD `8452293` + 在途 10 文件，有/无补丁）
  - `.worktrees/qa-r2-cold-base` / `-cold-patched` 冷编译计时
- 提交状态：**未 commit / 未 push / 未合并**；主仓库在途 10 文件开工收工一致（收尾已复核）

## 0.0 成果位置与版本

| 项 | 值 |
|---|---|
| 本报告（≈184 行 / ≈18 KB） | `.worktrees/qa-r2/docs/self-improvement/round-02-qa.md`（正文自引用会导致哈希自身变化，最终值见交付摘要） |
| 缺陷清单（127 行 / 9,402 B） | `.worktrees/qa-r2/docs/self-improvement/round-02-qa-defects.md`（sha256 `9563a34c…dd06a7`） |
| 原始证据（20 项 / 1.8 MB：15 探针 + repro.sh + reverse-verification.sh + README + SHA256SUMS + **56 份日志**） | `.worktrees/qa-r2/qa-evidence/`，`sha256sum -c SHA256SUMS` **74/74 成功、EXIT=0** |
| 一键复现 | `bash qa-evidence/repro.sh`（8 节，**端到端实跑一次 2026-11-17T23:56:17 → 00:08:20，约 12 分钟，8/8 节全部产出**） |
| 被测补丁 | `dev-r2.patch` sha256 `83b75e41…0cf16`，对 `git apply --check`（纯净 `5ed39a6`）通过 |
| 基线 | `5ed39a6e8feece2cbfe3c1d309768769eb265c98` = `origin/main`（#229） |
| 提交状态 | **未 commit / 未 push / 未合并**；主仓库在途 10 文件 + 4 未跟踪目录开工收工一致（14 项） |

## 0. 结论（先给判定）

**入选改动 5 条中 4 条完全通过验收标准（R2P-01/02/03/05），R2P-04 只达标一半（焦点在时保住、失焦后仍清空 → QA2-D1）；35 条新增用例（8 Elixir + 27 JS）在改前 **只 6 条通过**（Elixir 4/8、JS 2/27，其中 2 个 JS 套件直接加载失败），改后 **35/35 全绿**；两棵树的全量回归失败集合逐条一致（`only_base=[]`、`only_patched=[]`），无改前绿改后红。**

但**不整轮打回**的同时，有 4 条必须进 R3 首项：

| 编号 | 级别 | 一句话 | 判定 |
|---|---|---|---|
| QA2-D1 | P1 | R2P-04 的编辑守卫以 `activeElement` 为唯一判据：**输入后一失焦，下一次 8 s 轮询仍会清空草稿**（实测 `present=false value=null`） | 新发现，U1 的"静置 10 分钟"口径未达成 |
| QA2-D2 | P1 | R2P-02 语义收紧后，**无 scope 且不在同一 `$callers` 树的进程（`spawn_monitor`）里 Esc 不再生效**（改前 true → 改后 false） | 新发现，需 arch 定性是否可接受 |
| QA2-D3 | P1 | 6 个新测试文件（含 8 条 Elixir 用例）**不在任何分区表里**——`mix newbee.test_fast` 完全不跑；G4 漏跑 33→34 | 门禁口径缺口 |
| QA2-D4 | P1 | G8 未达标：`web` 分区仍 "356 绿 / exit=3"，既有测试警告未清完（只修了 2/5 类） | 未达标，R3 补 |

**打回判定**：**不整轮打回 dev**。理由：5 条入选改动中 4 条完全达标、R2P-04 半达标（缺口已单列 QA2-D1），7 条验收条目里 6 条满足、无「改前绿改后红」、补丁可独立落地且与主仓库在途改动无冲突（集成树实测）。但 QA2-D1/D3 必须在 R3 首项修，否则"用户输入不再被吃掉"与"新用例真的被门禁执行"这两句话不成立。

## 1. 验收标准逐条判定（pm §2 的 5 条 + dev 追加 2 条）

| 条目 | 验收标准（要点） | 实测 | 判定 |
|---|---|---|---|
| **R2P-01** auto 闸门 | ① 提交后重读任务 ② 删掉 `{:ok, :ignored}` 旧断言 ③ 反向：改回旧快照必须红 ④ 探针两行都 `stage_index=4` ⑤ 端到端自动进入下一阶段 | ①③④实跑：**区分力来自走真实调用路径的新用例**（`Runtime.project_remote/3`）——base **1/4**、patched **4/4**；反向还原 `runtime.ex` → **1/4**（3 红）。pm 的 `probe_auto_gate.exs` 两棵树输出**完全相同**，**不能**当修复证据（见 §6 注）② `team_test.exs:213` 已改为走 `Runtime.project_remote/3`；旧快照契约移入 `team_auto_gate_test.exs` 第 4 条 ⑤ 同一条用例走真实提交路径覆盖 | **通过** |
| **R2P-02** 中断隔离 | ① 显式区分"缺键/值为 nil" ② 无 scope 不写共享全局位 ③ 三条新用例 ④ 反向：改回 `get_value` 必须全红 ⑤ 既有用例改显式 scope | ①②代码核对+探针：跨树 `true→false`、depth1/2/3 `{true,false,false}→{true,true,true}`、`{:interrupt,:undefined}` 键消失 ③ 4 条新用例全绿 ④ 反向还原 `client.ex`→`3/4`（跨树那条红）⑤ `kerneltest_test.exs` 已改；`clienttest_test.exs` 仍用无 scope 的 `interrupt/0`（自洽，见 QA2-N2） | **通过**（附 QA2-D2/N2） |
| **R2P-03** Markdown 注入 | ① 属性位全改 `escapeAttr` ② scheme 白名单 ③ 契约测试 ④ 反向：改回任一处必须红 ⑤ 不得靠"禁 Markdown"达标 | ①`grep` 复核：`="${escapeHtml(` 在 app.js/md.js 均 **0** 处，`escapeAttr(` 18 处 ②③jsdom 真解析：改前 `img` 有 `onerror` 属性（真注入）、`href="javascript:…"`；改后只剩 `class/src/alt/loading`，链接降级 `<span class="md-blocked">` ④ 反向：还原 `app.js`→套件加载失败；**只还原 `colony/md.js`→8 条全红而 app.js 的 9 条仍全绿**（两个独立注入面）⑤ https/相对路径/正常图片仍渲染 | **通过** |
| **R2P-04** 轮询吃草稿 | ① 编辑守卫 ② jsdom 真实等待 ≥9 s 断言同节点/同值/同焦点 ③ 反向：删守卫必须红 ④ 真实浏览器静置 10 min | ①②`team-panel.test.js` 4/4；pm 探针 8 s：改前 `present=false`、改后 `present=true value=ABC focus=true`；**我方 34 s/8 次轮询长时探针：改后 `survived_all=true`** ③ 反向还原 `team-panel.js`→`1/4`（3 红）④ **未做**（无真实浏览器）→ 且实测出 **QA2-D1：失焦后仍被清空** | **部分通过** |
| **R2P-05** 坏 localStorage | ① 顶层读取容错+清坏键 ② 坏值下 `window.NewbeeTeamPanel` 仍在且 `open()` 可用 ③ 反向：去掉 try 必须红 ④ 同类排查 `priv/web/*.js` | ①②改前 `panel_exported: "undefined"`、改后 `"object"`，`open()` 不抛错、坏键已清 ③ 反向：还原 `team-panel.js`→该条红 ④ `app.js` 5 个读取点收敛到 `readStoredJson/3`；残留 `project-chat.js:539` 自带 try/catch（自洽） | **通过** |
| 追加① 两份渲染器 | dev 自查发现 `colony/md.js` 是第二个注入面 | 独立反向验证成立（见 R2P-03 ④） | **通过** |
| 追加② 编译警告 | 两处测试警告在 `--warnings-as-errors` 下让分区 abort | 改前 `tools-tui` `185/188` 但 `exit=2`；改后该两条警告消失（`default values…` / `unused alias Task` 计数 1→0） | **部分通过**（2/5 类） |

## 2. 门禁 G1–G9 实测（两棵树、同口径、串行）

| 门 | 定义 | base | patched | 判定 |
|---|---|---|---|---|
| **G1** 编译零警告 | `MIX_ENV=test mix compile --warnings-as-errors` | exit=0 | **exit=0** | 保持 |
| **G2** 格式 | `mix format --check-formatted` | exit=1，**31 文件** | exit=1，**31 文件（集合差集为空）** | **未达标**（R2P-06，本轮未碰） |
| **G3** 门禁主判据 | `mix newbee.test_fast` | exit=1（18 条记录 / **9 条唯一**） | exit=1（18 条 / **同 9 条**） | **未达标但零新增**（`only_base=[]`、`only_patched=[]`） |
| **G4** 覆盖完整 | 分区表 vs `Path.wildcard` | 254 文件 / 覆盖 221 / 漏 **33**（含 acceptance，单列会更少） | 256 文件 / 覆盖 **222** / 漏 **34** | **未达标且恶化 1**（QA2-D3） |
| **G5** acceptance | `mix test.acceptance` | **14 passed** | **14 passed** | 保持 |
| **G6** 前端 | `node --test test/web/conversation-work.test.js` | 32 tests / **0 pass** | 32 / **0 pass** | 未达标（改前就红，R2P-06） |
| **G7** 种子稳定 | 定向失败集合跑 seed 1/2/3 | — | 7 文件 seed 1/2/3 **各 101 passed** | 定向范围内**达标** |
| **G8** 全绿不被标志误杀 | 任一分区"用例全绿但 exit≠0" | 存在（`colony_team_api_test` 5 passed / exit=1） | **同样存在**（5 passed / exit=1） | **未达标**（QA2-D4） |
| **G9** 运行期 deprecation | 门禁日志 `is deprecated` 计数 | 6（test_fast） | 6 | 未达标（非本轮引入） |

**G3 分区明细（独占时段，两棵树串行，记录负载）**

| 分区 | base | patched |
|---|---|---|
| agent-dee | exit=0，116 passed | exit=0，116 passed |
| environment | exit=0，149 passed | exit=0，149 passed |
| llm | exit=0，175 passed，3 skipped | exit=0，**179 passed**，3 skipped（+4 新用例） |
| tools-tui | exit=2，185/188（3 失败） | exit=2，185/188（**同 3 条**） |
| web | exit=3，356/358（2 失败） | exit=3，356/358（**同 2 条**） |
| collaboration | exit=0，160 passed | exit=0，160 passed |
| root | exit=2，346/350（4 失败） | exit=2，346/350（**同 4 条**） |
| **墙钟** | **313 s**（load 0.74→3.99） | **284 s**（load 3.99→2.25，−9.3%） |

> 退出码口径：`mix test` 有失败是 2；`--warnings-as-errors` 且"用例全绿但有警告"时是 1（Elixir 源码 `lib/mix/tasks/test.ex:715-730`）。web 分区 `exit=3` = 失败(2) + 1，不是第三种错误。

**G3 第二轮独立复跑（`repro.sh` 端到端，另一时段，loadavg 0.66）**

| 分区 | base | patched |
|---|---|---|
| llm | 175 passed | **179 passed** |
| tools-tui | exit=2，185/188 | exit=2，185/188（同 3 条） |
| web | exit=3，356/358 | exit=3，356/358（同 2 条） |
| root | exit=2，**348/350（2 失败）** | exit=2，**346/350（4 失败）** |
| 其它四分区 | 全绿 | 全绿 |

第二轮 root 多出的 2 条是 `SessionIndexPerfTest`（`cold transcript scan` / `hot list`）。**这两条在 base 上单跑同样红**（`logs/colony-ab.txt`：`session_index_perf qa-r2-base exit=2 2/3 passed`、`qa-r2 exit=2 2/3 passed`），即 M14 已记录的「测绝对墙钟」脆弱断言。故两轮 root 的 2/4 差异**归因负载抖动**，非补丁引入；但这是门禁可复现性的持续缺口（R2P-06 / M14），R3 必须治。

## 3. 同口径全量回归（主判据）

同一台机、seed=1、各自树内 `TMPDIR`、串行、`--no-compile`：

| 树 | 用例 | 失败 | 墙钟 | 失败集合 |
|---|---|---|---|---|
| base `qa-r2-base` | 1786/1793 | **7** | 511.5 s | 见下 |
| patched `qa-r2` | 1794/1801（+8 新用例） | **7** | 405.4 s | **与 base 完全一致**（`only_base=[]`、`only_patched=[]`） |

7 条基线失败（全部改前既有，本轮未触碰）：
`fstest:17`、`archive_test:360`、`goal_steering:64`、`error_contracts:49`、`tool_documentation_contract:8`、`colony_api:252`、`colony_api:328`。

**集成树对照（主仓库 HEAD `8452293` + 在途 10 文件）**

| 树 | 用例 | 失败 |
|---|---|---|
| 无补丁 `qa-r2-integ-base` | 1743/1750 | 7 |
| 有补丁 `qa-r2-integ` | 1750/1758 | 8（`only_patched` = `session_index_perf:hot list`） |

该条为性能断言型用例（成本随负载变化），单跑两棵树均 `2/3 passed`（同一子用例红），不归因于补丁，记入抖动清单。

## 4. 新增用例：改前 vs 改后（全部实跑）

| 套件 | base（改前） | patched（改后） |
|---|---|---|
| `team_auto_gate_test.exs`（4） | **1/4**（3 红；唯一绿的是「旧快照仍 :ignored」守护） | **4/4** |
| `interrupt_scope_test.exs`（4） | **3/4**（跨树误中断那条红） | **4/4** |
| `markdown-safety.test.js`（9） | **加载失败（1 红）** | **9/9** |
| `colony-markdown-safety.test.js`（8） | **加载失败（1 红）** | **8/8** |
| `team-panel.test.js`（4） | **1/4**（3 红） | **4/4** |
| `localstorage-safety.test.js`（6） | **1/6**（5 红） | **6/6** |

> 与 dev 自报的差异：`localstorage-safety` 我方 base 为 1/6，dev 为 3/6。原因：dev 用"补丁树里还原 `app.js`"作反例，我用"纯净 5ed39a6"作 base。方向一致（改前红），我的口径更严格。

## 5. 反向验证（逐文件还原 → 显式重编译 → 用例必须红）

| 还原对象 | 结果 | 恢复后 |
|---|---|---|
| `lib/newbee/colony/runtime.ex` | `team_auto_gate_test` **1/4**（3 红） | 4/4 |
| `lib/newbee/llm/client.ex` | `interrupt_scope_test` **3/4**（跨树那条红） | 4/4 |
| `priv/web/team-panel.js` | `team-panel.test.js` **1/4**（3 红） | 4/4 |
| `priv/web/app.js` | `markdown-safety` 加载失败 1 红；`localstorage-safety` **3/6** | 9/9、6/6 |
| `priv/web/colony/md.js`（仅此一个） | `colony-markdown-safety` 加载失败 1 红，而 `markdown-safety` **仍 9/9** | 8/8、9/9 |

**方法论教训**：`git checkout -- <file>` 之后不显式 `mix compile`，`mix test --no-compile` 会复用旧 BEAM，得到"还原后仍全绿"的假结论（我第一次跑即踩到，`Result: 4 passed`）。已写进 `qa-evidence/README.txt`。

## 6. 行为/性能与基线对比

| 指标 | base | patched | 结论 |
|---|---|---|---|
| M1 能力索引字节 | 1941 | 1941 | 未变（R2P-06 未修） |
| M3 test 冷编译 | 58.1 s（交替顺序复测 51.0 s） | 58.9 s（交替顺序复测 61.4 s） | 噪声内 |
| M4 dev 冷编译 | 64.6 s | 59.2 s | 噪声内（顺序反转后差值反转） |
| M5 test 热编译 | 2.7 s | 2.7 s | 持平 |
| dev 热编译 | 2.1 s | 5.8 s | **判为噪声**（顺序反转后不成立），见 §7 |
| M6 test_fast 墙钟 | 313 s | **284 s（−9.3%）** | 变快（llm +4 用例仍更快；root 62.8→40.1 s） |
| M7 test_fast 声明用例数 | 1523（main 基线） | 同分区表 → **未变** | **未达标**（QA2-D3） |
| M11 worktree 注册数 | — | **558**（`.newbee/workspaces` 523 + 本轮新增 6） | 继续增长，**清理需授权** |
| M12 `.git/worktrees` 体积 | 36 MB（main 基线） | **48 MB** | 增长 |
| M15 面板输入存活窗口 | 8 s（首次轮询即清空） | **≥34 s / 8 次轮询（保持焦点）**；**失焦后 8 s 即清空** | 部分达标（QA2-D1） |
| 中断读取成本（µs/call） | scoped 0.449 / nil 0.876 / `%Client{}` 0.828 | scoped 0.544 / nil 0.983 / `%Client{}` **1.986** | scoped +21%（仍 <1 µs，50 ms 轮询下可忽略）；无 scope 的 `%Client{}` 路径 **2.4×** |

> 注：`probe_auto_gate.exs` 在 base/patched 输出**完全一致**（`stage_index` 依次 0/3/3/4），因为它自己手动分别调用旧/新快照。这类「实现无关探针」只能证明缺陷机制存在，**不能**证明修复生效；本轮所有「修复生效」结论一律以「走真实调用路径的用例 + 反向验证」为准。这是本轮对证据口径的第三条增量结论。

## 7. 抖动与不可复现项（如实记录）

1. **`EventStoreTailTest` 超时**：出现在 patched 的第一次 `test_fast`（60 s 超时）；第二次两棵树各跑一次均 `5 passed`；单文件跑两棵树 47.1 s / 12.5 s（顺序相反）。判为**负载敏感**，非补丁引入。
2. **`SessionIndexPerfTest: hot list`**：集成树补丁侧多红 1 条；单跑两棵树均 `2/3`（同一子用例红），属既有脆弱性能断言。
3. **dev 热编译 2.1 s vs 5.8 s**：交替顺序测量后差值反转，判为噪声，不作为回归依据。
4. **`colony_api:252/328`**（`workspace.kind` 期望 `filesystem_copy` 实得 `git_worktree`）：两棵树两次全量都红，与补丁无关，但需 R3 定性（产品对/测试错）。

## 8. 未覆盖范围（如实声明）

1. **未在真实浏览器/Playwright** 跑合成事件与真实焦点行为；QA2-D1 的"失焦"结论来自 jsdom + `activeElement` 覆写，**未在真实 Chromium 复核**（本机 Chromium 不可用，R1/R2 同）。
2. **未起真实 SSE/双流会话**验证 R2P-02 端到端（仅进程内探针 + 4 条用例）。
3. **未验证"AI 流式生成 + 团队面板同时打开"** 的组合场景。
4. **未做行覆盖率**（R1P-13 顺延）；未测 Firefox/WebKit/移动端。
5. **未跑"新建 2 阶段 auto 模板端到端"**（用产研模板 5 阶段走到 develop 验证，等价但非同一路径）。
6. R2P-06/08/09/10/11/12 与 U3/U3b/U4/U5 **全部未动**。
7. worktree 清理（558 条 / 12 G；`.newbee/workspaces` 2.7 G）属破坏性操作，**需 main 授权**。

## 9. R3 交接建议（按成本/收益排序，供 main 决策）

1. **QA2-D3（1 小时，最低成本）**：`lib/mix/tasks/newbee/test_fast.ex` 的 `@partition_specs` 补 `colony`/`codec`/`host`/`learning`/`plugins`/`terminal`/`truncate`/`evals` 八项，并加 meta 测试（删任一行 → 必须红）。做完 G4 漏跑 34→0，本轮的 8 条新 Elixir 用例才真正进门禁。
2. **QA2-D1（半天）**：`team-panel.js` `render()` 前做脏表单快照/回填（或用 `input` 事件置脏位）；配一条"失焦 + 轮询"的 jsdom 用例（本目录 `probe_poll_blur.js` 已可直接转成用例）。
3. **QA2-D4（半小时）**：`colony_team_api_test.exs:25` 的 `cid`、`static_asset_allowlist_test.exs:12` 的 `unused import`，各改一行，G8 清零。
4. **QA2-D2（需 arch 先定性）**：明确"无 scope 必须注入 scope"，把 7 处 `Config.client_for(...)` 补 scope；否则这类路径的 Esc 是静默失效。
5. **R2P-06 剩余项**（G2 格式 31 文件 / G6 前端 32→ 全绿 / M1 能力索引 1941→≤1800 / M14 性能断言去绝对墙钟）：与 R1/R2 基线已排定的顺序一致，本轮未动。

> 交付边界：本报告只负责**验收与证据**，不含产品代码改动；所有补丁与文档均未 commit / 未 push / 未合并，需要 main 决策后才能落主干。
