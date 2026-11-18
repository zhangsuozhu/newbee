# 第 1 轮 · 基线与环境校准报告

- 轮次：R1（自我改进循环第 1 轮，共 ≥100 轮计划）
- 角色：项目总协调人（main）
- 测量时间：2026-11-13 18:20–20:05 (+08:00)
- 被测版本：`5ac87bad145b0801e7d8c5145895e87ddd4ac3ff`（`origin/main`，"fix(ui): 交给团队按钮互斥/显示逻辑同步 (#228)"）
- 测量位置：会话独立工作树 `/home/alanx/data/git/newbee/.worktrees/baseline-r1`（detached HEAD，`deps` 软链到主仓库）
- 主仓库工作区当时在 `fix/jspace-open-section @8452293`，其 **tree 与 origin/main 完全一致**（`git diff origin/main HEAD` 为空），另有 7 个在途未提交文件；本轮**未改动主仓库任何源码**，在途改动不纳入基线。
- 原始证据目录：`.worktrees/baseline-r1/baseline/`（命令日志、逐用例 JSONL、计时 TSV、脚本）

## 0. 结论速览

| 维度 | 基线结论 |
|---|---|
| 严格编译（dev/test，`--warnings-as-errors`） | 通过，零警告 |
| `mix format --check-formatted`（全仓库） | **失败：34 个文件未格式化** |
| `mix newbee.test_fast`（README 的快速回归门） | **失败**：exit=1，1760.8s，1477 用例中 **8 失败**（2 确定性 + 6 抖动），4/7 分区红（另含测试文件编译警告中止） |
| `mix test.acceptance`（§15 架构验收） | 通过 14/14 |
| 全量 Elixir 用例（含 test.fast 漏掉的 32 个文件） | 1772 个用例：1741 通过 / 4 失败 / 13 跳过 / 14 排除 |
| `node --test test/web/conversation-work.test.js` | **失败：32 个用例 0 通过**（该套件不在任何 mix 门里） |
| 测试覆盖漏洞 | `mix newbee.test_fast` / `mix test.all` **漏跑 32/250 个测试文件**（含整个 colony 子系统） |

**一句话**：主干当前不是"绿"的。README 里的 `mix test.all` 既不绿也不全；这必须先成为第 2 轮的修复目标，否则后续 100 轮没有可信的对照物。

## 1. 环境与测量口径

| 项 | 值 |
|---|---|
| Elixir / OTP | 1.20.3 / OTP 29 (erts-17.0.5) |
| Node / Python | v22.23.3 / 3.14.2 |
| CPU / 内存 | 20 逻辑核 / 32008 MiB（测量时已用 ~18900 MiB） |
| 起始 load average | 6.33 / 9.00 / 8.44（测量中段升到 ~16） |
| 并发干扰 | 主仓库常驻 `mix newbee.web` BEAM（pid 311684，约 68% CPU）；另一会话工作树 `.worktrees/r1-baseline-coord` 同时在跑自己的 `mix test` |
| 代码规模 | lib 229 个 `.ex` / 87486 行；test 259 个文件 / 38263 行；priv/web 30 个 `.js` / 23087 行 + 7305 行 CSS；docs 45 项 |
| 测试规模 | 250 个 `*_test.exs` |
| 固定随机种子 | `--seed 1`（与仓库既有约定一致） |
| 用例计时口径 | 自定义 ExUnit formatter 逐用例记录 `time_us`（含 setup），与 CLI 汇总逐分区核对一致 |

> **计时可信度声明**：本轮所有墙钟数字都是**在上述并发负载下**测得的，不是空载基准。它们可用于同一台机器、同等负载下的相对比较，不能当作产品性能承诺。空载基线需要在无人使用时重跑（见 §7 未覆盖范围）。


## 2. 官方门禁的真实结果

### 2.1 `mix newbee.test_fast`（README 的快速回归门）

命令：`MIX_ENV=test mix newbee.test_fast`（内部固定 `--seed 1 --warnings-as-errors`，7 个分区串行）
**总耗时 1760.8 s（29.3 分钟），exit=1，失败分区：environment / tools-tui / web / root**

| 分区 | exit | ExUnit 秒 | 结果 |
|---|---|---|---|
| agent-dee | 0 | 199.8 | 109 passed, 13 excluded |
| environment | 2 | 87.2 | 148/149 passed（1 失败） |
| llm | 0 | 69.0 | 175 passed, 3 skipped |
| tools-tui | 2 | 118.6 | 186/188 passed（2 失败） |
| web | 3 | 505.8 | 334/336 passed, 1 excluded（2 失败 + 警告中止） |
| collaboration | 0 | 301.3 | 150 passed |
| root | 2 | 370.5 | 340/343 passed, 10 skipped（3 失败） |
| **合计** | **1** | **1652.2** | **1477 用例：1442 通过 / 8 失败 / 13 跳过 / 14 排除** |

8 条失败中：**2 条确定性**（能力索引预算、archive 回放），**6 条抖动**（等待/墙钟预算，见 D7）。
证据：`baseline/test-fast-gate.log`、`baseline/gate-summary.txt`。

### 2.2 `mix test.acceptance`（§15 架构验收）

`MIX_ENV=test mix test --no-compile --warnings-as-errors --seed 1 test/newbee/acceptance_test.exs`
→ **14/14 通过**，ExUnit 160.2 s，墙钟 168.8 s，exit=0。证据：`baseline/test-acceptance.log`。

### 2.3 逐分区独立测量（本轮基线主表，含 test.fast 漏掉的文件）

同一 commit、同一 seed，但每个分区单独一个 VM 顺序跑，并额外补测 acceptance 与 32 个漏跑文件：


#### 构建与静态检查（分区测量口径）

| 步骤 | MIX_ENV | exit | 墙钟秒 |
|---|---|---|---|
| `dev-cold-compile`（rm -rf _build 后） | dev | 0 | 81.9 |
| `dev-warm-compile` | dev | 0 | 9.7 |
| `test-cold-compile` | test | 0 | 101.1 |
| `test-warm-compile` | test | 0 | 17.6 |
| `format-check` | dev | 1 | 4.3 |

#### 分区结果明细

| 分区 | 用例 | 通过 | 失败 | 跳过 | 排除 | ExUnit 秒 | 墙钟秒 | exit |
|---|---|---|---|---|---|---|---|---|
| agent-dee | 122 | 109 | 0 | 0 | 13 | 202.0 | 212.4 | 0 |
| environment | 149 | 149 | 0 | 0 | 0 | 95.9 | 114.7 | 0 |
| llm | 178 | 175 | 0 | 3 | 0 | 127.0 | 131.0 | 0 |
| tools-tui | 188 | 187 | 1 | 0 | 0 | 163.3 | 156.5 | 2 |
| web | 337 | 336 | 0 | 0 | 1 | 378.7 | 416.9 | 1 |
| collaboration | 150 | 150 | 0 | 0 | 0 | 251.8 | 265.6 | 0 |
| root | 353 | 340 | 3 | 10 | 0 | 1110.1 | 404.3 | 2 |
| acceptance | 14 | 14 | 0 | 0 | 0 | 155.6 | 168.8 | 0 |
| uncovered | 281 | 281 | 0 | 0 | 0 | 850.7 | 856.1 | 1 |

| 汇总 | 用例 | 通过 | 失败 | 跳过 | 排除 | 用例耗时合计秒 |
|---|---|---|---|---|---|---|
| test.fast 覆盖范围（7 分区） | 1477 | 1446 | 4 | 13 | 14 | 2328.8 |
| 全部 Elixir 分区（含 acceptance + 未覆盖） | 1772 | 1741 | 4 | 13 | 14 | 3335.1 |

#### 本次分区跑中失败的用例

| 用例 | 位置 | 摘要 |
|---|---|---|
| Newbee.Tools.ToolDocumentationContractTest :: test 常驻工具提示短小且没有已删除 API | test/newbee/tools/tool_documentation_contract_test.exs:8 | error: ** (ExUnit.AssertionError)   Assertion with <= failed code:  assert byte_size(section) <= @plugin_section_budget left:  1941 right: 1800      test/newbee |
| Newbee.MediaTest :: test 文本和 Markdown 上屏时携带正文，持久化只保留元数据 | test/newbee/media_test.exs:75 | error: ** (ExUnit.TimeoutError) test timed out after 60000ms. You can change the timeout:    1. per test by setting "@tag timeout: x" (accepts :infinity)   2. p |
| Newbee.FsWalkTest :: test respects max_depth and max_entries | test/newbee/fs_walk_test.exs:34 | error: ** (ExUnit.TimeoutError) test timed out after 60000ms. You can change the timeout:    1. per test by setting "@tag timeout: x" (accepts :infinity)   2. p |
| Newbee.ArchiveTest :: test 二次压缩回放含旧摘要的 envelope（旧摘要前缀） | test/newbee/archive_test.exs:360 | error: ** (ExUnit.AssertionError)   Assertion with == failed code:  assert Enum.drop(second, -1) == Newbee.LLM.Client.sanitize_messages(env2_msgs) left:  [%{"co |

#### 最慢 25 个用例

| 秒 | 用例 | 位置 |
|---|---|---|
| 143.0 | Newbee.Colony.ConversationExecutionTest :: test the real dispatcher, Session, Loop and model HTTP return a current result in the original conversation | test/newbee/colony/conversation_execution_test.exs:144 |
| 43.37 | Newbee.Learning.PipelineTest :: test stub model passes reproduction and practice, evaluation runs both arms | test/newbee/learning/pipeline_test.exs:52 |
| 41.52 | Newbee.UploadTest :: test reports image preparation failures instead of silently sending text only | test/newbee/upload_test.exs:48 |
| 39.57 | Newbee.AcceptanceTest :: test §15.4 任意 active release 可回退到历史 revision（graph 级） | test/newbee/acceptance_test.exs:176 |
| 38.26 | Newbee.CommandsTest :: test /resume 精确 id 与前缀都返回 {:resume, id} | test/newbee/commandstest_test.exs:44 |
| 34.66 | Newbee.MediaTest :: test 过大的文本退化为下载媒体，不把正文放进 payload | test/newbee/media_test.exs:111 |
| 34.66 | Newbee.TruncateTest :: test 验收：长日志中段的错误行 预览看不到，但句柄能原样读回含错误行的全文 | test/newbee/truncate_test.exs:156 |
| 33.1 | Newbee.AcceptanceTest :: test §15.2 至少两类非工具插件（rule/prompt）经同一 Plugin Runtime 加载 | test/newbee/acceptance_test.exs:107 |
| 31.89 | Newbee.EventStoreTailTest :: test replay_tail 与全量等值（大文件，只读尾部窗口） | test/newbee/event_store_tail_test.exs:34 |
| 28.96 | Newbee.TruncateTest :: test 更外层句柄 句柄不可读时回退到本层句柄 | test/newbee/truncate_test.exs:123 |
| 28.89 | Newbee.Colony.SourceTest :: test budgets block new work but allow an explicitly addressed followup | test/newbee/colony/source_test.exs:103 |
| 28.63 | Newbee.Colony.ConversationDecompositionTest :: test child questions are answered from the root once, with real consumption receipts | test/newbee/colony/conversation_decomposition_test.exs:89 |
| 28.34 | Newbee.SpillTest :: test 流式写入 push 在超过上限后仍继续统计真实字节数 | test/newbee/spill_test.exs:120 |
| 27.83 | Newbee.UploadTest :: test prepares trusted local paths and clipboard images without a filename extension | test/newbee/upload_test.exs:29 |
| 26.02 | Newbee.Agent.LoopCompactTest :: test 档案召回：用户输入命中已压缩档案 → 注入指针提示（不推载荷） | test/newbee/dee/kernelcompact_test.exs:180 |
| 25.47 | Newbee.AcceptanceTest :: test §15.11 沉睡规则在 compaction（视图重建）后依然触发 | test/newbee/acceptance_test.exs:484 |
| 24.9 | Newbee.Colony.SourceTest :: test human followups update the same work; ending it never revives its record | test/newbee/colony/source_test.exs:89 |
| 24.28 | Newbee.Colony.WorkflowTest :: test Git worktrees include tracked dirt and untracked source without changing HEAD | test/newbee/colony/workflow_test.exs:245 |
| 23.96 | Newbee.Collaboration.CoordinatorTest :: test Board claim 后由 worker submitted，Lead verify 才能完成 | test/newbee/collaboration/coordinator_test.exs:607 |
| 23.9 | Newbee.MediaTest :: test delete 删除文件与 manifest 条目 | test/newbee/media_test.exs:59 |
| 23.66 | Newbee.Agent.LoopCompactTest :: test auto compact（token 压力）同样走档案且不炸 | test/newbee/dee/kernelcompact_test.exs:111 |
| 23.65 | Newbee.ReaderSchemeTest :: test conflict:// 在 git 仓库返回清单 | test/newbee/readerschemetest_test.exs:12 |
| 23.24 | Newbee.EventStoreTest :: test 崩溃半帧被识别并截断 | test/newbee/event_store_test.exs:36 |
| 22.5 | Newbee.EventStoreTailTest :: test 崩溃半帧（末尾无换行的坏行）按截断处理，与全量一致 | test/newbee/event_store_tail_test.exs:48 |
| 22.3 | Newbee.AcceptanceTest :: test §15.10 每个环境改变可回答：谁、何时、基于哪条证据、改了哪个 release、如何回退 | test/newbee/acceptance_test.exs:428 |

> 分区墙钟之和 = **2726.3 s**（9 个分区顺序跑）；`root` 分区 ExUnit 秒（1110.1）大于墙钟（404.3）是因为该分区 async 用例并行（max_cases 40）。
> `web` 与 `uncovered` 的 exit≠0 来自测试文件编译警告（D2），不是用例失败。

### 2.4 前端 JS 套件

`node --test test/web/conversation-work.test.js` → **32 用例 / 0 通过 / 32 失败**，墙钟 1.1 s，exit=1。
该命令**不在** `mix test` / `mix test.fast` / `mix test.all` 任何入口内。证据：`baseline/js-web.log`。

### 2.5 用例耗时分布（1741 个通过用例，逐用例 time_us）

| 分位 | 秒 |
|---|---|
| p50 | 0.023 |
| p90 | 4.99 |
| p95 | 8.85 |
| p99 | 24.28 |
| max | 143.0 |
| 合计 | 3333.0 |

| 阈值 | 用例数 |
|---|---|
| >1 s | 516 |
| >5 s | 174 |
| >10 s | 80 |
| >30 s | 9 |


## 3. 已知缺陷清单（全部在 `origin/main` 上复现）

编号规则：`R1-Dn`。每条都给出复现命令与证据文件，`阻断` 表示会让门禁判红。

### R1-D1 · 常驻能力索引超出预算（阻断，确定性）

- 现象：`Newbee.Tools.ToolDocumentationContractTest` "常驻工具提示短小且没有已删除 API" 失败。
- 数据：`Newbee.Plugins.prompt_section()` = **1941 字节**，契约上限 `@plugin_section_budget = 1800`（超 141 字节 / 7.8%）。20 个内置插件。
- 复现：`MIX_ENV=test mix test --no-compile --seed 1 test/newbee/tools/tool_documentation_contract_test.exs:8`
- 交叉验证：在主仓库工作区（含在途改动）同样失败 → 与在途改动无关。
- 影响：每一轮对话的系统提示都多带 141 字节；更重要的是**契约测试已经红了**，说明"提示词预算"这条防线当前失效。
- 归因线索：`Newbee.Tools.Team`（`afdac16`，2026-11-12，#224）新增一行摘要后越界；该行摘要 120 字符截断处停在半个词（"…become a reusable template; start "）。
- 证据：`baseline/test-tools-tui.log`、`baseline/results-tools-tui.jsonl`。

### R1-D2 · 测试文件编译警告让分区门禁判红（阻断，确定性，4 处）

`--warnings-as-errors` 下，即使全部用例通过，分区仍以非 0 退出：

| 文件:行 | 警告 |
|---|---|
| `test/newbee/web/colony_team_api_test.exs:25` | variable "cid" is unused |
| `test/newbee/web/static_asset_allowlist_test.exs:12` | unused import Plug.Conn |
| `test/newbee/colony/task_test.exs:10` | default values for the optional arguments in the private function task/1 are never used |
| `test/newbee/colony/engine_test.exs:4` | unused alias Task |

- 复现：`MIX_ENV=test mix test --no-compile --warnings-as-errors --seed 1 test/newbee/web/colony_team_api_test.exs test/newbee/web/static_asset_allowlist_test.exs` → `10 passed` 但 `ERROR! Test suite aborted … warnings`。
- 影响：`web` 分区 336 通过仍 exit=1；`colony` 281 通过仍 exit=1。违反 AGENTS.md "test/ 不允许任何编译警告"。
- 证据：`baseline/test-web.log`、`baseline/test-uncovered.log`。

### R1-D3 · 二次压缩回放 envelope 断言失败（阻断，确定性）

- 现象：`Newbee.ArchiveTest` "二次压缩回放含旧摘要的 envelope（旧摘要前缀）" 失败（`test/newbee/archive_test.exs:360`）。
- 断言：`Enum.drop(second, -1) == Newbee.LLM.Client.sanitize_messages(env2_msgs)` 不等。
- 复现：`MIX_ENV=test mix test --no-compile --seed 1 test/newbee/archive_test.exs:360`；seed 1/2/3 三次均失败；主仓库工作区同样失败 → 确定性缺陷，不是并发抖动。
- 影响：压缩/回放是长会话的核心路径，前缀不一致会直接影响 prefix cache 命中与模型 400 风险。
- 证据：`baseline/test-root.log`（第 3 条失败，含完整 left/right 消息列表）。

### R1-D4 · 前端工作卡 JS 套件全红（阻断，确定性）

- 现象：`node --test test/web/conversation-work.test.js` → **32 个用例 0 通过**。
- 两类根因：
  1. 源码契约用例：`priv/web/conversation-work.js` 出现 6 处 `innerHTML`（1784/1805/1820/1835/1841/1847 行），违反"所有展示用 textContent 构建"的约定；
  2. 其余 31 个用例在 `updateComposerStart`（`conversation-work.js:852`）抛 `wrap.classList.toggle is not a function` —— 组件新用到的 DOM API 在测试替身 `test/web/conversation_work_dom.js` 里没有实现，套件在初始化阶段即崩。
- 对照：主仓库工作区（含在途的 DOM 替身与用例更新）为 44 用例 / 41 通过 / 3 失败 → **在途改动正在修这个洞，但尚未提交**；主干仍是全红。
- 影响：该套件**不在 `mix test` / `mix test.all` / `mix newbee.test_fast` 任何入口里**，前端回归实际处于无人看守状态。
- 证据：`baseline/js-web.log`。

### R1-D5 · `mix newbee.test_fast` 漏跑 32/250 个测试文件（覆盖漏洞，非断言失败）

`lib/mix/tasks/newbee/test_fast.ex` 的分区表只列了 7 组路径，未包含：

| 目录 | 文件数 |
|---|---|
| `test/newbee/colony/` | 19 |
| `test/newbee/plugins/` | 4 |
| `test/newbee/learning/` | 4 |
| `test/newbee/codec/`、`evals/`、`host/`、`terminal/`、`truncate/` | 各 1 |

- 后果：README 宣称的"完整入口" `mix test.all` = `test.fast` + `acceptance`，实际漏掉 **281 个用例**（本轮补测：281 全通过，用时 849.6s）。蜂群/团队（colony）这条最活跃的产品线**完全没有进入日常门禁**。
- 复现：`baseline/uncovered-test-files.txt` 是脚本算出的差集；`MIX_ENV=test mix test --no-compile --seed 1 $(cat baseline/uncovered-test-files.txt)`。
- 证据：`baseline/test-uncovered.log`、`baseline/results-uncovered.jsonl`。

### R1-D6 · 全仓库格式检查失败（卫生问题，确定性）

- `mix format --check-formatted` → **34 个文件**不合规（清单见 `baseline/unformatted-files.txt`），最早可追溯到 2026-09-02 的提交，说明"提交前只检查改动文件"的约定长期漏掉了历史文件。
- 复现：`mix format --check-formatted`（工作树根目录）。
- 证据：`baseline/format-check.log`（66 KB，含逐文件 diff）。


### R1-D7 · 等待/时间预算过短，门禁随负载与用例顺序抖动（脆弱，已多次复现）

| 用例 | 断言/预算 | 观察 | 判定 |
|---|---|---|---|
| `Environment.CoordinatorReevaluateTest`（coordinator_reevaluate_test.exs:11） | `wait_for_status` 200×20ms = **4s** | 官方 gate 里 change 仍 `:evaluating` 即耗尽；独立分区跑通过 | 负载抖动 |
| `MediaTest`（media_test.exs:75）、`FsWalkTest`（fs_walk_test.exs:34） | ExUnit 默认 60s | 栈停在 `File.mkdir_p!`；单独重跑通过 | 负载抖动 |
| `Web.SessionNewTest` "/new async restart…"（session_new_test.exs:20） | **`assert dt < 500`（毫秒墙钟）** | gate 实测 **779ms** 失败；单独重跑通过 | 违反 AGENTS.md "不要断言紧的墙钟时间" |
| `Tools.CommandJobTest` "caller exit cancels an unbounded command tree"（command_job_test.exs:16） | `wait_until(..., 3000)` 等进程树消失 | 整模块跑 4 次中 2 次失败；**单独跑该用例通过**；主仓库整模块跑通过 | 用例间串扰/负载 |
| `Web.ProjectChatTest` "real LLM HTTP protocol…"（project_chat_test.exs:110） | Transport.rpc 轮询 | gate 里 `{:error, "network_unavailable", "连接超时"}`；单独重跑通过 | 负载抖动 |
| `LLM.ClientTest`（clienttest_test.exs:294）、`LLM.TlsTest`（tls_test.exs:189）、`AcceptanceTest §15.9`（acceptance_test.exs:389） | 60s / 握手 / 恢复等待 | 只在另一会话单进程全量里失败；本会话单独重跑通过 | 负载抖动 |

- 对照：`test/newbee/acceptance_test.exs` 的同类等待给 6000×20ms = **120s**，同仓库两套预算差 30 倍。
- 影响：在真实开发机（常驻 WebUI + 多会话并发）上，门禁会随机变红，"红=真缺陷"的信号被污染；本轮官方 gate 的失败集合与独立分区跑就不一致（见 §3.1）。
- 证据：`baseline/test-fast-gate.log`、`baseline/test-root.log`、上述单独重跑输出。


### R1-D8 · 测试与基准入口本身的可观测性不足（改进机会）

- `mix newbee.test_fast` 串行跑 7 个分区（`max_concurrency: 1`），分区内部 `max_cases: 40`；本轮官方门禁 **1760.8s**，20 核机器利用率低。
- 逐用例结果默认不落盘，失败只打印终端，无法做"上一轮 vs 这一轮"的用例级 diff。本轮为此临时写了一个 ExUnit formatter（`baseline/erl_libs/newbee_baseline/src/baseline_fmt.ex`）才拿到 1772 条逐用例记录。
- `bench/tasks/` 只有 1 个任务，`evals/compaction_recall/` 只有 README，`mix newbee.bench` 需要真实模型；本轮未跑（见 §7）。


### R1-D9 · 性能断言随会话数量翻脸（脆弱，已 5/5 复现）

- 现象：`Newbee.SessionIndexPerfTest` "cold transcript scan counts lines without decoding every object"（`test/newbee/session_index_perf_test.exs:49`）断言 `list_us < decode_us`。
- 数据：单独跑 5 次（seed 1..5）全部失败，`list_us` 9506–17356µs vs `decode_us` 3422–6371µs（差 2.5–3 倍）；整模块跑也失败；主仓库工作区同样失败。
- 反例：在 `root` 分区整组跑时**通过**，用例耗时仅 0.12s。
- 判断：`Session.list_page(50, 0)` 的成本随 GlobalStore 里已有会话数量增长，而对照的 `decode_us` 只跟固定 payload 有关。该断言实际测的是"当前机器上有多少会话"，不是产品不变量。
- 影响：这是**唯一一条会话列表性能护栏**，现在既会误报也会漏报；不能直接当性能回归门用。
- 证据：`baseline/results-root.jsonl`（整组通过）+ 上述 5 次单独运行输出。


### R1-D10 · 测试产生的 Git worktree 从不清理，注册数无限累积（环境/资源泄漏，本轮实测复现）

- 数据（`git worktree list --porcelain`，主仓库共享 `.git`）：**204 条注册**，按来源分类：

| 来源 | 条数 |
|---|---|
| 主仓库 `tmp/Newbee.*Test/...`（历史测试遗留） | 99 |
| 主仓库 `.newbee/workspaces/`（历史会话/测试） | 25 |
| **本轮会话工作树 `.worktrees/baseline-r1`（本轮新产生）** | **22** |
| 另一会话工作树 `.worktrees/r1-baseline-coord`（同轮新产生） | 22 |
| 其他 `.worktrees/`（人工会话树） | 28 |
| 其他仓库 | 8 |

- **本轮实测增量**：跑一次 colony/web 相关分区，就在自己的工作树里新建 **21 个**测试 worktree 注册（22 减去工作树本身），跑完**一个都没清**。两个会话合计 **+42**。
- 其中 **84 条是"工作树里再套工作树"**（路径含 >1 个 `.newbee/workspaces/` 段），最长路径 **372 字符 / 20 层**。
- `.git/worktrees/` 元数据 **17 MB / 203 条目**；主仓库 `.newbee/workspaces/` 磁盘 **2.2 GB**（排除 deps/_build）；测试 tmp 目录本身很小（本轮 320 KB），**代价主要在注册与元数据，不是文件体积**。
- `git worktree list --porcelain` 的 `prunable` = **0**：目录都还在，所以 `test/test_helper.exs` 里的 `git worktree prune` 永远清不掉。
- 根因线索：`after_suite` 只 `prune`（清"目录已消失"的注册），而 colony 用例把工作树建在**仓库内**被 gitignore 的 `tmp/`、`.newbee/workspaces/`，用例结束不删目录 → 注册只增不减；子任务还会在父工作树里再建工作树。
- 影响：`.git` 元数据持续膨胀、路径逼近系统上限、`git worktree list` 被 200+ 条噪声淹没（本轮确认隔离目录时就被干扰）；**后续 100 轮每轮跑测试都会 +20~40 条**，不修会线性恶化。
- 复现：`git worktree list --porcelain | grep -c '^worktree '`；跑一次 `mix test test/newbee/colony` 前后各数一次。
- 边界：本轮**未做任何清理**（删除历史工作树属破坏性操作，需授权）；只如实记录增量。

### 3.1 跨运行对照（同一 commit，两种跑法）

另一会话在**它自己的**工作树 `.worktrees/r1-baseline-coord`（同为 `5ac87ba`）用**单进程全量** `mix test --no-compile --warnings-as-errors --seed 1` 跑了一次，作为交叉对照（只读引用，未改动其目录）：

| 跑法 | 结果 | 墙钟 |
|---|---|---|
| 本会话：9 个分区顺序跑（每分区独立 VM） | 1772 用例 / 1741 通过 / **4 失败** / 13 跳过 / 14 排除 | 2726.3 s（分区之和） |
| 另一会话：单进程全量 `mix test` | 1745 用例 / 1737 通过 / **8 失败** / 13 跳过 / 14 排除 | 2083.5 s |

- 两种跑法**都失败**的确定性缺陷：R1-D1（能力索引预算）、R1-D3（archive 回放）。
- 只在单进程全量里出现的 6 条：`LLM.ClientTest`（clienttest_test.exs:294，60s 超时）、`LLM.TlsTest`（tls_test.exs:189）、`MediaTest`、`FsWalkTest`、`SessionIndexPerfTest`、`AcceptanceTest §15.9`（acceptance_test.exs:389）。本会话把这 4 条（clienttest/tls/perf/acceptance）单独重跑：clienttest、tls、acceptance **通过**，perf **失败**（见 D9）→ 前三条属负载/串扰诱发。
- 用例总数差异（1772 vs 1745，**恰好差 27 = 13 skipped + 14 excluded**）：本会话把 skip/exclude 的用例也逐条记进 JSONL（`--dry-run` 验证：默认过滤下正好产出 27 条 skip/exclude 记录），而 ExUnit 的 `Result:` 行把 skipped/excluded 单列、不计入 `1745`。**口径统一后完全一致**：1745 = 1737 通过 + 8 失败；本会话 1772 = 1741 通过 + 4 失败 + 13 跳过 + 14 排除。
- 已核对：本会话逐用例记录覆盖 **250/250** 个测试文件，无重复无遗漏；每个文件的执行用例数与源码里 `test "..."` 的静态条数**逐文件相等**（脚本核对，0 处不符）。

- **结论**：单进程全量比分区跑更容易被拖垮（2083s 里 async 只占 290s），且失败集合随跑法变化 → 这正是 G8（三种子一致性）要治的问题。


### 3.2 种子稳定性抽查（G8 的证据）

对最重的两个分区做三种子重跑（同一 commit、同一工作树、同一脚本）：

| 分区 | seed 1 | seed 40410 | seed 851020 | 逐用例结果一致性 |
|---|---|---|---|---|
| agent-dee（122 用例） | 109 通过 / 13 排除，212.4s，exit=0 | 109 通过 / 13 排除，257.6s，exit=0 | 109 通过 / 13 排除，216.4s，exit=0 | **三次逐用例完全一致** |
| environment（149 用例） | 149 通过，114.7s，exit=0 | 149 通过，103.9s，exit=0 | **148/149**，117.0s，exit=2 | **不一致**：`CoordinatorReevaluateTest` 在 851020 下失败 |

- 这条不一致与官方 gate 里 environment 分区的失败是**同一条用例、同一根因**（4s 等待预算），与随机种子无关、与当时机器负载有关。
- 结论：**G8 当前不达标**，且已定位到具体用例；agent-dee 分区则是稳定的（可作为"改动是否引入回归"的可信对照）。
- 证据：`baseline/results-agentdee-seed{40410,851020}.jsonl`、`baseline/results-env-seed{40410,851020}.jsonl`、`baseline/test-env-seed851020.log`。


## 4. 可量化验收尺子（后续每轮共用）

所有指标都用同一套脚本在**会话独立工作树**里测量，口径固定：`--seed 1`、`--warnings-as-errors`、逐用例 JSONL + 墙钟计时 + 记录 load average。

### 4.1 门禁（Gate）：必须为真才算"这一轮没把产品弄坏"

| 门 | 命令 | 判定 | R1 基线 | R2 目标 |
|---|---|---|---|---|
| G1 编译 | `mix compile --warnings-as-errors` + `MIX_ENV=test mix compile --warnings-as-errors` | 两条都 exit=0 且零警告 | ✅ 通过 | 保持 ✅ |
| G2 格式 | `mix format --check-formatted` | 未格式化文件数 = 0 | ❌ **34** | **0** |
| G3 快速回归 | `mix newbee.test_fast` | exit=0 | ❌ exit=1，8 失败，4/7 分区红，1760.8s | exit=0 |
| G4 全量回归 | `MIX_ENV=test mix test --warnings-as-errors --seed 1` | 失败用例 = 0 且无警告中止 | ❌ 单进程全量 8 失败（另一会话同 commit 实测）；分区跑 4 失败；4 处测试警告 | 0 失败 |
| G5 架构验收 | `mix test.acceptance` | 14/14 通过 | ✅ 14/14 | 保持 ✅ |
| G6 前端 | `node --test test/web/*.test.js` | 失败用例 = 0 | ❌ **32 失败 / 0 通过** | 0 失败 |
| G7 覆盖完整性 | 分区覆盖的测试文件数 / 全部测试文件数 | = 250/250 | ❌ **218/250（87.2%）** | 250/250 |
| G8 稳定性 | 同一套用例在 seed 1 / 40410 / 851020 三次运行 | 失败集合完全一致 | ⚠️ 未达标：agent-dee 三次一致；environment 在 851020 下多 1 失败（D7） | 三次一致 |

### 4.2 数值尺（Metric）：用于"这一轮到底变好了多少"

| 指标 | 定义与测法 | R1 基线 | 允许波动 | 改进方向 |
|---|---|---|---|---|
| M1 常驻能力索引字节 | `byte_size(Newbee.Plugins.prompt_section())` | **1941 B**（上限 1800） | 硬上限 1800 | ↓ 到 ≤1800 |
| M2 dev 冷编译 | `rm -rf _build` 后 `mix compile --warnings-as-errors` | 81.9 s | ±20% | ↓ |
| M3 dev 热编译 | 无改动再跑一次 | 9.7 s | ±20% | ↓ |
| M4 test 冷编译 | `rm -rf _build/test` 后编译 | 101.1 s | ±20% | ↓ |
| M5 test 热编译 | 无改动再跑一次 | 17.6 s | ±20% | ↓ |
| M6 全量用例墙钟 | 9 个分区顺序跑之和（同负载） | 2726.3 s | ±15% | ↓ |
| M7 用例耗时 p50 / p90 / p95 / p99 | 逐用例 `time_us` 分位（1741 个通过用例） | 0.023 / 4.99 / 8.85 / 24.28 s | ±15% | ↓ |
| M8 慢用例个数 | >1s / >5s / >10s / >30s | 516 / 174 / 80 / 9 | 只许减不许增 | ↓ |
| M9 最慢单例 | `ConversationExecutionTest`（conversation_execution_test.exs:144） | 143.0 s | ±15% | ↓ |
| M10 未格式化文件数 | `mix format --check-formatted` | 34 | 硬指标 | → 0 |
| M11 测试文件编译警告数 | 全量 `--warnings-as-errors` 输出中的 warning 条数 | 4 | 硬指标 | → 0 |
| M12 分区覆盖率 | 见 G7 | 87.2% | 硬指标 | → 100% |

> M2–M9 是**同机同负载相对量**。每轮测量必须同时记录 `nproc / loadavg / 是否有常驻服务`，负载差异超过 ±30% 时该轮性能数字只做参考、不作结论。

### 4.3 每轮通用验收规则（打回依据）

一轮改动被判"通过"，必须同时满足：

1. **不破坏**：本轮结束时 G1/G5 保持通过；已经修绿的门不许回红。
2. **有增量**：至少一条 §4.1/§4.2 的指标按预期方向移动，并给出**同一套脚本**测出的 before/after 两个数字。
3. **有证据**：新增或修改的自动化测试，必须能展示"改前失败、改后通过"的真实输出（不接受只贴改后通过）。
4. **可回滚**：改动落在会话独立工作树，给出 commit/分支与回滚方式；主仓库工作区不被污染。
5. **有边界**：明确写出本轮未覆盖的范围与已知限制。

任一条不满足 → 打回对应环节（方案问题回 arch，实现问题回 dev，验证不足回 qa），回退轮次上限 3。


## 5. 复现方法（任何人可重跑）

### 5.1 准备隔离工作树

```bash
cd /home/alanx/data/git/newbee
git worktree add .worktrees/baseline-rN 5ac87ba      # 或本轮要测的 commit
ln -sfn ../../deps .worktrees/baseline-rN/deps        # 深度按工作树位置调整
cd .worktrees/baseline-rN
```

> `deps` 必须软链到主仓库，否则 `mix` 报 "dependency is not available"。
> **不要**用 `ERL_LIBS` 给 `mix test` 注入模块：`mix` 会重建 code path 并丢掉 `ERL_LIBS`（本轮实测），逐用例采集器改用把 beam 编进 `_build/test/lib/newbee/ebin` 的方式。

### 5.2 一键重跑（本轮脚本）

```bash
bash baseline/repro.sh          # 依次跑：编译/格式/9 个分区/JS/官方 test.fast，最后汇总
```

脚本产物（全部落在 `baseline/`）：

| 文件 | 内容 |
|---|---|
| `env.txt` | commit、工具链、CPU/内存/load、并发干扰 |
| `timings.tsv` | 每步 `name / MIX_ENV / exit / 墙钟秒` |
| `<step>.log` | 该步完整原始输出（含失败堆栈） |
| `results-<partition>.jsonl` | **逐用例**：module / name / state / time_us / file:line / failure 摘要 |
| `metrics.json` | 分区汇总、总计、最慢 25、失败清单 |
| `tables.md` | 由 `metrics.json` 生成的本报告表格 |
| `unformatted-files.txt` / `uncovered-test-files.txt` | 格式违规清单 / 分区漏跑清单 |

采集器与汇总脚本：`baseline/erl_libs/newbee_baseline/src/baseline_fmt.ex`、`baseline/summarize.exs`、`baseline/report_tables.exs`。

### 5.3 单条缺陷的最小复现

```bash
# D1 能力索引预算
MIX_ENV=test mix test --no-compile --seed 1 test/newbee/tools/tool_documentation_contract_test.exs:8
# D2 测试编译警告（10 passed 仍 abort）
MIX_ENV=test mix test --no-compile --warnings-as-errors --seed 1 \
  test/newbee/web/colony_team_api_test.exs test/newbee/web/static_asset_allowlist_test.exs
# D3 archive 回放
MIX_ENV=test mix test --no-compile --seed 1 test/newbee/archive_test.exs:360
# D4 前端
node --test test/web/conversation-work.test.js
# D5 漏跑的 32 个文件
MIX_ENV=test mix test --no-compile --seed 1 $(cat baseline/uncovered-test-files.txt)
# D6 格式
mix format --check-formatted
# D9 性能断言
MIX_ENV=test mix test --no-compile --seed 1 test/newbee/session_index_perf_test.exs
```


## 6. 本轮结论与第 2 轮目标

### 6.1 R1 结论

1. **主干不绿**：`mix test.all`（README 的"完整入口"）在 `5ac87ba` 上既失败又不完整。
2. **确定性缺陷 4 类**（D1 能力索引预算、D2 测试编译警告×4、D3 archive 回放、D4 前端 JS 全红）+ **覆盖漏洞 1 个**（D5，漏 32 文件 / 281 用例）+ **卫生问题 1 个**（D6，34 文件未格式化）+ **脆弱断言 2 类**（D7 等待/墙钟预算、D9 性能断言随会话数翻脸）+ **资源泄漏 1 个**（D10，204 条 worktree 注册，本轮跑测试又新增 21 条且零清理）。
3. **可复现基线已建立**：250/250 测试文件全部跑过、逐用例结果落盘、脚本化一键重跑、跨会话交叉对照一致。

### 6.2 第 2 轮目标（交给 pm → arch → dev → qa）

**主题：把门禁修绿、修全，让"红=真缺陷"重新成立。**

按 影响×成本 排序的入选范围（建议 pm 采纳，最终由 pm 定稿）：

| 优先 | 目标 | 对应缺陷 | 验收（必须可量化） |
|---|---|---|---|
| P0 | 测试文件零编译警告 | D2 | 4 处警告清零；`web`、`colony` 分区 exit=0；G4 不再因警告中止 |
| P0 | 分区覆盖补全 | D5 | `test.fast` 覆盖 250/250 文件；新增 colony/plugins/learning/codec/evals/host/terminal/truncate 分区；`mix test.all` 用例数 ≥1772 |
| P0 | 能力索引回到预算内 | D1 | `byte_size(Plugins.prompt_section()) ≤ 1800`，且契约测试通过；不允许简单调高上限来"修绿" |
| P1 | archive 二次压缩回放前缀一致 | D3 | `archive_test.exs:360` 在 seed 1/40410/851020 三次均通过；补充"改前失败"的证据 |
| P1 | 前端 JS 套件进门禁并修绿 | D4 | `node --test test/web/*.test.js` 0 失败；把该命令接入 `mix test.all`（或新增 `mix newbee.test_web`）；innerHTML 契约恢复 |
| P2 | 等待/墙钟断言改为状态驱动 | D7、D9 | 去掉 `dt < 500` 类墙钟断言；等待预算统一（建议 ≥30s 且基于真实状态/事件）；同一套用例三种子失败集合一致（G8） |
| P2 | 全仓库格式化 | D6 | `mix format --check-formatted` 未格式化文件数 34 → 0 |
| P2 | 测试工作树用完即清 | D10 | 跑完 colony 分区后 `git worktree list` 增量 = 0（当前 +21）；历史 204 条注册的清理方案需人工授权后执行 |

**第 2 轮不做什么**（防止范围膨胀）：不动产品功能语义、不重构大文件、不引入新依赖、不跑真实模型基准。

### 6.3 交接给下一环节的输入

- pm：本报告 §3 缺陷清单（每条含复现命令）+ §4 尺子；请据此产出问题清单与本轮入选范围。
- arch：注意 D1 不能靠抬预算糊弄；D5 要决定"补分区"还是"改成自动发现全部测试文件"（后者更根治，但要评估分区隔离与耗时）。
- dev：所有改动落在**各自会话独立工作树**；本报告的工作树 `.worktrees/baseline-r1` 只读保留作对照物。
- qa：用 `baseline/repro.sh` 同一套脚本测 before/after；性能数字必须附 load average。

## 7. 未覆盖范围与已知限制（如实声明）

1. **未跑真实模型基准**：`mix newbee.bench`（需要真实 LLM 计费调用，且 `bench/tasks/` 只有 1 个任务）、`evals/compaction_recall`（目录只有 README）。本轮没有模型质量/成本数据。
2. **未跑被排除/跳过的用例**：14 个 `:node` 标签用例（跨节点求值器、节点崩溃恢复等）被 `test_helper.exs` 默认排除；13 个 skip（`NEWBEE_CACHE_E2E`、`NEWBEE_BROWSER_INTEGRATION`、`NEWBEE_CAPTCHA_LIVE` 未开）。**分布式/浏览器/真实缓存这三条路径本轮零覆盖。**
3. **未做浏览器端到端**：Playwright/X11 路径、WebUI 真实交互未验证；前端只有 node 单测（且全红）。
4. **未做空载性能基准**：所有耗时都在 load 6→17、常驻 WebUI + 另一会话并发的条件下测得；不能作为产品性能承诺。
5. **未做覆盖率（代码行覆盖）测量**：没有跑 `--cover`；"覆盖"在本报告里指**测试文件是否被执行**，不是代码覆盖率。
6. **未验证跨主机/多物理机部署**、Windows/AppImage 打包、TUI 真实终端交互。
7. **未改动任何产品代码**：本轮只做测量与记录；主仓库工作区的 7 个在途文件未被触碰，也未提交/推送/合并任何内容。
8. **环境缺陷（本轮亲历，影响后续所有轮次）**：DEE 的跨 cell 变量绑定会被套上多层 JSON 信封（`[{"name":...,"value":{"$t":"bin","v":...}}]`），下一次调用读到的是字符串而非原值，直接用会导致路径拼接错误。本轮改用"上下文写文件 + 每次 source"绕过。建议作为独立缺陷交给 pm（不属产品仓库代码，属运行时）。
9. **并发写入风险已澄清**：`.worktrees/baseline-r1` 是本会话独占目录；另一会话在 `.worktrees/r1-baseline-coord` 独立测量（本轮只读引用其日志做交叉对照）。曾出现一个引用本会话路径的孤儿 `mix newbee.test_fast` 进程（父进程被中断后残留），已终止；此后本目录的产物均由本会话脚本生成。
10. **本轮自身留下的痕迹**：跑测试在本会话工作树内新建了 21 个测试 worktree 注册（D10），未清理；`baseline/` 与 `docs/self-improvement/` 为未跟踪文件，未 `git add`/commit。工作树 `.worktrees/baseline-r1` 保留作对照物，删除需授权。
11. **G8 只抽查了 2 个分区**：三种子重跑覆盖 agent-dee 与 environment（271 用例），其余 7 个分区只跑了 seed 1；"三次一致"的全量结论尚未成立。
12. **JS 侧只测了一个组件**：`test/web/` 下只有 `conversation-work.test.js` 一个套件，其余 29 个 `priv/web/*.js` 无自动化测试。
13. **JSpace 台账跨会话共享（本轮实测）**：本会话的 `Newbee.Tools.JSpace` 台账里出现了另一会话写入的 ✓10/✓11（其编译/门禁数字与本轮不同：108.0s vs 81.9s、1744.6s vs 1760.8s）。说明当前 JSpace 台账未按会话隔离，多会话并行时会互相污染"已验证"列表。**本报告的数字一律以 `baseline/` 下的原始日志为准，不以台账为准。** 建议交给 pm 作为运行时缺陷。
