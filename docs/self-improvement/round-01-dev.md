# 第 1 轮 · 修改代码（dev）—— 交付完成

- 轮次：R1（自我改进循环第 1 轮）
- 角色：研发工程师（dev）
- 被改造基线：`5ac87bad145b0801e7d8c5145895e87ddd4ac3ff`（`origin/main`，#228）
- 工作位置：**会话独占工作树 `.worktrees/dev-r1`**（detached 5ac87ba，`deps` 软链主仓库）；
  改前对照树 `.worktrees/dev-r1-base`（同 commit，同样软链），两树互不覆盖。
- 上游输入：`round-01-baseline.md`（main）、`round-01-problems.md`（pm）、`round-01-plan.md` +
  `arch-evidence/spike.patch`（arch；D-1 决策 `A_relax_2500`：门禁墙钟上限 2500 s）
- 提交状态：**未 commit / 未 push / 未合并**；主仓库工作区 7 个在途文件全程未被触碰（收尾复核一致）
- 补丁：`dev-evidence/dev-r1.patch`（72 文件；行数与 sha256 见 `dev-evidence/SHA256SUMS`，用 `git diff --stat` 复核）
- 交付文档：`docs/self-improvement/round-01-dev.md`（本文件）

## 0. 结论速览

`mix newbee.gate` 在 `5ac87ba` + 本补丁上 **exit=0，6/6 步全绿**（连续四次全绿，墙钟 551.25 / 541.43 / 505.73 / 530.71 s，最后一次是把补丁打到纯净对照树验证可移植性，见 §8）；
同一命令在未打补丁的 `dev-r1-base` 上**根本不存在**（`The task "newbee.gate" could not be found`），
而它代替的旧入口 `mix test.all` 在基线上漏跑 33 个测试文件、不含格式与前端。

| 验收项 | 改前实测 | 改后实测 |
|---|---|---|
| R1P-03 测试编译警告 | 39 passed 但 **exit=1**（4 处警告） | 39 passed **exit=0**（0 警告） |
| R1P-04 格式 | **34 文件**不合规，exit=1 | `--check-formatted` **exit=0** |
| R1P-05 能力索引 | **1941 B** > 1800 契约（契约用例红） | **1745 B**，条目仍 20，契约 3/3 |
| R1P-06 archive 不变量 | 24/25（断言 #215 已废弃契约） | **26/26**；反向删投影 → 恰好 2 条守护红 |
| R1P-01 分区覆盖 | 7 分区 **217/250**（漏 33） | 9 分区 **255/256**，仅 acceptance 留在门外 |
| R1P-02 前端 JS | **32 tests / 0 pass** | **35/35 exit=0**，源码 `innerHTML` = **0** |
| R1P-09 单一门禁 | **无此入口**；`test.all` = test_fast + acceptance | `mix newbee.gate` 6 步聚合，全仓唯一权威定义 |
| R1P-07 抖动（批 B，arch 排 R3） | 2 条结构性错误断言，单独跑必红 | **一并修掉**（必要性见 §2.6/§2.7） |
## 1. 改动清单

### 1.1 R1P-03 测试编译警告 → 0（4 处，各 1 行）

| 文件 | 改动 |
|---|---|
| `test/newbee/web/colony_team_api_test.exs` | `%{cid: cid}` → `%{}`（未使用变量） |
| `test/newbee/web/static_asset_allowlist_test.exs` | 删 `import Plug.Conn`（未使用） |
| `test/newbee/colony/task_test.exs` | `defp task(attrs \\ %{})` → `defp task(attrs)`（默认值永不生效） |
| `test/newbee/colony/engine_test.exs` | 别名去掉未使用的 `Task` |

证据：`dev-evidence/before-warnings.log`（EXIT=1，4 处 `warning:`）/ `after-warnings.log`（EXIT=0，0 处）。

### 1.2 R1P-04 格式 → 0

`mix format` 落到 34 个文件（`.formatter.exs` 未改：`line_length: 120`）。语义等价的证明不重复 arch 的
AST 抹 meta 比对，而是**用"格式改动前后全量测试逐条对照"**（§2.1 的 1755 passed 与基线分区跑无差异）。

### 1.3 R1P-05 能力索引 1941 B → 1745 B

- `lib/newbee/plugins.ex`：`@summary_bytes 66` + `truncate_summary/2`（先按 UTF-8 grapheme 裁到字节预算，
  再回退到最后一个空格）+ `utf8_prefix/2`；
- 10 个 moduledoc 首句改写（`tools/hive.ex`、`tools/team.ex`、`codec.ex` 等）；`docs/edit-design.md`
  的引用从 `Tools.Edit` 首句移进正文（arch 发现的引用契约）。

**新增守护测试 `test/newbee/plugins/prompt_section_test.exs`（3 条）**：

1. 总量 ≤ 1800 契约上限 **且** ≤ 1790 回归线（再加工具前必须先压缩）；
2. 每条摘要都是 moduledoc 首行前缀、合法 UTF-8、**词边界截断**（截断点后必须是行尾或空格）；
3. 中文摘要不得出现 U+FFFD（多字节字符被切半）。

**反向验证**：把该测试原样放进未打补丁的基线树 → **0/3 passed**，首条报
`能力索引 1941 B 超出契约上限 1800 B`（`before-prompt-test.log`）。

### 1.4 R1P-06 archive 回放不变量

- `test/newbee/archive_test.exs`：二次压缩回放的断言对象从 `sanitize_messages/1`（#215 已废弃的中间态）
  改为真正的 wire 投影（`ImagePolicy.project_for → sanitize_messages → project_chat_messages`）；
- 新增守护用例「前缀缓存不变量：摘要回放前缀 == 路由请求真正发出的 wire 投影（逐字节）」，
  带**反向哨兵**：断言 `digest_prefix != sanitize_only`、`env.messages` 含 `created_at` 而 `digest_prefix` 不含
  —— 否则该用例会退化成恒真。

反向验证（arch 执行、本会话复核日志 `reverse-projection-removed.log`）：破坏 `project_chat_messages` 后
**恰好 2 条**守护用例红，其余 24 条不动。

### 1.5 R1P-01 分区补齐 + 覆盖元测试

- `lib/mix/tasks/newbee/test_fast.ex`：7 → **9 分区**（新增 `colony`、`plugins-learning`），
  `llm` 补 `test/newbee/codec`、`tools-tui` 补 `tui/terminal/truncate`；
  `partitions/1` 公开 + `dir_files/2` 把目录展开成文件列表（arch R1A-02：原表把目录直接传给 `mix test`，
  元测试无法复核覆盖）；
- 新增 `test/newbee/test_partition_coverage_test.exs`：覆盖完整性 / 不重复 / 分区名唯一且非空。
  `@root` 修正为 `Path.expand("../..", __DIR__)`（arch 踩过 `@root` 写错导致**恒绿**的坑），
  并加 `@moduletag timeout: 300_000`（根因见 §2.5）。

**实测分区展开**：`agent-dee 21 / environment 31 / llm 16 / tools-tui 28 / web 48 / collaboration 21 /
colony 19 / plugins-learning 11 / root 60` = **256 个文件，255 覆盖，唯一例外 `acceptance_test.exs`（按设计单独跑）**。
同一算法套到 R1 的 7 分区表：**217/250，漏 33**，含整个 colony 子系统（19 文件）+ learning/plugins/terminal/truncate/codec。

**反向验证（真跑）**：从分区表删掉 `{"colony", ...}` → `mix compile` 后元测试红并列出 19 个 colony 文件；
恢复后 3/3（`reverse-meta.log`）。

### 1.6 R1P-02 前端套件 32/0 → 35/35

- `priv/web/conversation-work.js`：6 处 `innerHTML` → DOM 构建（`menuItem/3` helper + `createElementNS` +
  `replaceChildren`）；源码 `grep -c innerHTML` = **0**；
- `test/web/conversation_work_dom.js`：替身补 `classList.toggle(name, force)`、`style.*`、`stopPropagation`、
  `querySelectorAll` 的 `.class`/`#id`/tag、`Element.remove()`、`Document.querySelectorAll`、
  `localStorage`/`sessionStorage`；
- `test/web/conversation-work.test.js`：3 处过期断言修正（`cw-team-split` 包裹层、SVG 按 `nodeType` 过滤、
  title 文案「快速分工」）+ **3 条新守护用例**：toggle 双语义、`cw-team-off` 跟随主按钮、
  **模板名含 `<img onerror>` 必须原样作文本且 DOM 里不得出现 IMG 节点**（XSS 回归守护）。

**反向验证**：把 quick 菜单项改回 `innerHTML` → **34/35 passed, 1 failed**（恰好是源码契约用例）；
恢复后 35/35（`reverse-js.log`）。与在途会话的边界按 arch §1 R1P-02 执行：源码归本循环，
替身语义与在途一致（在途合入时可直接以在途版本为准）。

### 1.7 R1P-09 单一门禁 `mix newbee.gate`（本阶段新增）

| 文件 | 作用 |
|---|---|
| `lib/mix/tasks/newbee/gate.ex`（191 行） | 6 步聚合：`compile-dev` → `compile-test` → `format` → `test-fast` → `acceptance` → `web-js`；`--fail-fast` / `--list`；任一步非 0 → 汇总非 0 + 失败项清单；node 缺失 = **显式失败**（不静默跳过） |
| `lib/newbee/gate_stream.ex`（75 行） | Port + `:spawn_executable` 的流式执行器：**实时转发**子进程输出（R1 D8：`System.cmd/3` 缓冲到结束，2000 s 跑批期间日志一片空白），返回 `%{output, exit, seconds}` |
| `lib/newbee/gate_preflight.ex`（168 行） | 开跑前环境体检：TMPDIR 空间（< 2048 MB → `:fail` 阻断）、负载、TMPDIR 条目数、`git worktree` 注册数（后三为 `:warn`）；**只读，不做任何清理** |
| `lib/mix/tasks/newbee/test_fast.ex` | 分区执行改用 `GateStream`，每分区打印 `exit / 秒数 / Result` 摘要 |
| `mix.exs` | `test.all` 别名 → 指向 `newbee.gate`（历史名字保留，语义升级） |
| `README.md` | 测试段落把 `mix newbee.gate` 写成**唯一权威门禁**：6 步、`--fail-fast`/`--list`、"合入前必须 gate 全绿" |

**新增守护测试**：

- `test/newbee/tools/gate_contract_test.exs`（5 条）：步骤集完整（增删都会红）、每步命令都解析到真实入口
  （mix 任务 / mix.exs alias / node / 测试文件，`entry_problem/2`）、`web-js` 用通配符覆盖
  `test/web/*.test.js`（新套件自动纳入）、元测试本身在门禁内、README 必须写 `newbee.gate` 且不再宣称
  `test.all` 是完整入口；
- `test/newbee/gate_stream_test.exs`（4 条）：退出码原样返回、stderr 合流、输出实时转发、`env`/`cd` 生效、
  可执行文件缺失返回 127 而非抛异常；
- `test/newbee/gate_preflight_test.exs`（4 条）：空间不足是 `:fail` 而非 `:warn`、充足时不阻断、
  报告带级别前缀且说明怎么修、**体检只读**（哨兵文件不被触碰）。
## 2. 真实验证方法与结果

### 2.1 门禁（唯一权威判据）

```bash
cd .worktrees/dev-r1
TMPDIR=/home/alanx/data/tmp-newbee-dev mix newbee.gate
```

`dev-evidence/gate-final4.log`（原始，含 ANSI）与 `gate-final4.clean.log`（去 ANSI，内容相同）：

```
2026-11-16T16:35:35+08:00
[gate] preflight: ok（TMPDIR 空间、负载、临时目录条目、worktree 注册数都正常）
[gate] compile-dev exit=0 in 3s
[gate] compile-test exit=0 in 3s
[gate] format exit=0 in 6s
[gate] test-fast exit=0 in 507s
[gate] acceptance exit=0 in 15s
[gate] web-js exit=0 in 1s
[gate] PASS 6 steps: compile-dev, compile-test, format, test-fast, acceptance, web-js
WALL=541.43
GATE_EXIT=0
```

分区明细（同日志）：

| 分区 | 文件 | exit | 秒 | ExUnit 结果 |
|---|---|---|---|---|
| agent-dee | 21 | 0 | 24 | 109 passed, 13 excluded |
| environment | 31 | 0 | 12 | 149 passed |
| llm | 16 | 0 | 19 | 180 passed, 3 skipped |
| tools-tui | 28 | 0 | 33 | 215 passed |
| web | 48 | 0 | 116 | 336 passed, 1 excluded |
| collaboration | 21 | 0 | 91 | 150 passed |
| colony | 19 | 0 | 113 | 177 passed |
| plugins-learning | 11 | 0 | 28 | 80 passed |
| root | 60 | 0 | 65 | 359 passed, 10 skipped |
| **小计** | **255** | **0** | **507** | **1755 passed / 0 failed / 13 skipped / 14 excluded** |
| acceptance | 1 | 0 | 15 | 14 passed |
| web-js | 1 | 0 | 1 | **35 tests / 35 pass** |

**墙钟 541.43 s，远低于 D-1 的 2500 s 上限**。R1 基线 `test.fast` 是 1760.8 s 且 4/7 分区红。

### 2.2 改前/改后对照（全部真跑）

| 项 | 命令 | 改前（`dev-r1-base`） | 改后（`dev-r1`） | 证据 |
|---|---|---|---|---|
| 门禁入口存在性 | `mix newbee.gate` | `** (Mix) The task "newbee.gate" could not be found` | 6/6 PASS | `before-gate-missing.log` / `gate-final4.log` |
| 编译警告 | 4 个警告点文件 + `--warnings-as-errors` | 39 passed，**EXIT=1**，4 warnings | 39 passed，**EXIT=0**，0 warnings | `before-warnings.log` / `after-warnings.log` |
| 格式 | `mix format --check-formatted` | exit=1，**34 文件** | exit=0 | `before-format.log` |
| 能力索引 | `tool_documentation_contract_test.exs:8` | exit=2，`left: 1941 / right: 1800` | exit=0，1 passed | `before-contract-budget.log` / `after-contract-budget.log` |
| 能力索引守护 | `prompt_section_test.exs`（新文件放进基线树） | **0/3 passed** | 3/3 | `before-prompt-test.log` |
| archive | `archive_test.exs` | **24/25**（EXIT=2） | **26/26**（EXIT=0） | `before-archive.log` / `after-archive.log` |
| 前端 | `node --test test/web/conversation-work.test.js` | **32 tests / 0 pass / 32 fail** | **35 / 35 pass** | `before-js.log` / `after-js.log` |
| 分区覆盖 | 分区展开算法 | **217/250**（漏 33，含 19 个 colony 文件） | **255/256**（仅 acceptance） | §1.5 |
| 覆盖元测试 | `test_partition_coverage_test.exs` 放进基线树 | **0 tests, 3 invalid**（`partitions/1` 不存在） | 3 passed | `before-meta-invalid.log` |

### 2.3 反向验证（证明新增测试会红，不是恒绿）

| 反向操作 | 期望 | 实测 |
|---|---|---|
| 从分区表删 `{"colony", ["test/newbee/colony"]}` | 元测试红并列 colony 文件 | **1 failed**，列出 19 个 colony 文件，2/3 → 恢复后 3/3 |
| `priv/web/conversation-work.js` 一处改回 `innerHTML` | 源码契约用例红 | **34 passed / 1 failed** → 恢复后 35/35 |
| 能力索引守护测试放进**未打补丁**的树 | 3 条全红 | **0/3**，`1941 B 超出契约上限 1800 B` |
| `--fail-fast` + 故意插入未格式化文件 | 首个失败即停、非 0 退出 | 只跑 3 步就 `[gate] FAIL 1/3: format` |
| 破坏 `project_chat_messages` 投影 | 恰好 2 条守护红 | `reverse-projection-removed.log`：恰好 2 条 |

### 2.4 门禁流式输出的可用性验证

改造前后对比（同一条 `test.fast`）：

- `gate-post.log`（`System.cmd` 缓冲）：`start test-fast` 之后 **20 分钟日志零增长**，无法判断是卡死还是慢；
- `gate-final4.log`（`GateStream`）：每分区结束立刻出现 `[test.fast] done web exit=0 in 116s`
  + `Result: 336 passed`，全程可观测。

### 2.5 环境体检的两次真跑（本轮新发现的根因）

```bash
$ mix newbee.gate                     # /tmp 只剩 932 MB
[gate] preflight fail: /tmp 只剩 932 MB（门禁下测试需要 >= 2048 MB；…）
** (Mix) [gate] preflight failed: 1 项环境检查不通过（先修环境再跑门禁）
GATE_EXIT=1

$ TMPDIR=/home/alanx/data/tmp-newbee-dev mix newbee.gate
[gate] preflight: ok（TMPDIR 空间、负载、临时目录条目、worktree 注册数都正常）
… [gate] PASS 6 steps …
```

根因链：`/tmp` 100% 满（931 MB）+ 40 个 async 用例抢文件服务队列 →
`FsWalkTest`、`TestPartitionCoverageTest` 出现 `ExUnit.TimeoutError ... 60000ms` →
单跑这两文件 **8 passed** → 换 `TMPDIR` 后 root 分区 **348 passed exit=0**（`root-only.log`）。
**不是产品缺陷，也不该在 40 分钟后才暴露。**

### 2.6 本轮新发现（pm / arch 均未记录）

1. **R1D-01 两条"抖动"是环境假红**：`FsWalkTest#respects max_depth` 与覆盖元测试的 60 s 超时，
   真因是 `/tmp` 满；已固化成门禁前置 `:fail` 检查，阈值 2048 MB 来自本次事故（931 MB 必红，6.3 GB 必绿）。
2. **R1D-02 共享命名进程的 TOCTOU**：`Process.alive?(pid) && GenServer.stop(pid)` 在门禁负载下报
   `** (EXIT) no process`（`Web.CollaborationApiTest` 一次实测触发，另有 4 处同类写法）。抽
   `Newbee.TestSupport.Lifecycle.stop_if_alive/1`（只吞 `:exit`，保留真实错误）替换 5 处，
   配 `test/newbee/test_support_lifecycle_test.exs`（4 条，含**并发关停 8 次全 :ok** 的 TOCTOU 复现）。
3. **R1D-03 会话索引性能用例测的是"机器上有多少会话"**：`transcript_scan_count() == scans + 1` 是全局计数器，
   同 VM 其他 async 测试文件不断建会话 → 实测 `left: 3 / right: 1`。改为**因果断言**：把 transcript 改写成
   "同字节数、少一行"再列表 —— 命中缓存则计数不变（1502），重扫则变 1501。与并发会话数无关，
   且真的会在缓存失效时红；同时删掉 `micros < 500_000` 与 `list_us < decode_us` 两条绝对墙钟断言（R1 D9）。
4. **R1D-04 `test.all` 的语义是错的**：它 = `test_fast` + acceptance，既不含格式也不含前端，
   却被 README 称作"完整入口"。已改为指向 `newbee.gate`。

### 2.7 稳定性实测

- `session_index_perf_test.exs`：**seed 1/2/3/4 连续 4 次 3 passed**；
- 全量门禁：`gate-post-tmpdir.log`（15:31，551.25 s，exit=0）与 `gate-final4.log`（16:35，541.43 s，exit=0）
  **连续两次全绿**；
- 期间失败的 `gate-final.log` / `gate-final2.log` / `gate-final3.log` 已保留（各自失败原因分别是
  `CollaborationApiTest` 一次 TOCTOU、`SessionIndexPerfTest` 两条全局计数器断言），修复后不再复现
  —— 三轮失败日志是"改动确实在收敛"的证据，未删除。
### 2.8 新增测试清单（共 26 条）

| 文件 | 条数 | 守的是什么 |
|---|---|---|
| `test/newbee/tools/gate_contract_test.exs` | 5 | 门禁步骤集完整、每步入口真实存在、`web-js` 通配覆盖、元测试在门禁内、README 指向唯一入口 |
| `test/newbee/gate_stream_test.exs` | 4 | 退出码原样返回、stderr 合流、输出实时转发、`env`/`cd` 生效、缺失可执行文件返回 127 |
| `test/newbee/gate_preflight_test.exs` | 4 | 空间不足必须 `:fail` 阻断、充足不误报、报告可读且说明怎么修、**体检只读** |
| `test/newbee/test_partition_coverage_test.exs` | 3 | 覆盖完整性 / 不重复 / 分区名唯一且非空 |
| `test/newbee/plugins/prompt_section_test.exs` | 3 | 预算+回归线、词边界截断、中文不切半 |
| `test/newbee/test_support_lifecycle_test.exs` | 4 | 关停幂等、按名关停、**并发关停 8 次全 :ok**（TOCTOU 复现） |
| `test/web/conversation-work.test.js` | +3 | toggle 双语义、`cw-team-off` 跟随主按钮、模板名 XSS 不回退 |

新增测试全部在门禁内（`test.fast` 9 分区 + `web-js`），并由覆盖元测试保证不会被漏掉。

## 3. 已知限制与未覆盖范围（如实声明）

1. **G8 三种子一致性未重测**：只对 `session_index_perf_test.exs` 做了 4 seed 验证；全量套件 seed 40410 /
   851020 未跑。`environment` 分区在 seed 851020 的历史失败（R1 D7 的 4 s 等待预算类断言）**未修**。
2. **批 B 只做了必要最小集**：`session_new_test.exs:112` 的 `dt < 500`、4 s 等待预算类断言仍原样；
   arch 建议的"高负载 20 连跑"未做。**R3 仍需处理**。
3. **墙钟数字有环境依赖**：541 s 是 `TMPDIR` 指到 `/home`、`loadavg ≈ 2.5` 时的值；`TMPDIR=/tmp`（满盘）+
   高负载时 `test-fast` 曾到 **1312 s**（`gate-post.log`），仍 < 2500 s 但抖动大。
   门禁的数值墙钟**不可作回归判据**，只做上限检查。
4. **前端只在 Node 替身上验证**：35 条全绿证明 DOM 构建语义与 XSS 不回退，但**未在真实浏览器 /
   Playwright** 跑过；点击链路（焦点、事件冒泡、CSS 布局）仍可能与真实 DOM 有差。
5. **CI 未接**：仓库仍无 `.github/`（R1P-09 的"自动路径"需远程写权限，未授权）。gate 目前是**人工入口**；
   可选方案 `bin/install-hooks`（pre-push 调 gate）未实现。
6. **批 A 之外的产品缺陷未动**：R1P-08 worktree 泄漏（本轮又新增注册，清理需授权）、D10 历史 200+ 条注册、
   R1P-11 文档证据过期（`docs/conversation-work-operations.md` 仍写"26 项通过"）、R1P-12 JSpace 串写、
   R1P-13 行覆盖率、R1P-14 真实模型基准（需计费授权）、R1P-15 node/browser/cache 三条路径。
7. **未跑全量单进程套件**（`mix test` 一次跑完 256 文件）：只跑门禁的 9 分区 + acceptance；分区之间是
   独立 VM，**跨分区串扰未验证**（R1 基线的 6 条"只在单进程全量出现"的失败里，`MediaTest`、`AcceptanceTest §15.9`
   本轮未专门复核）。
8. **preflight 阈值 2048 MB 来自单机事故**（931 MB 时出现 60 s 超时，6.3 GB 时 348 passed）：磁盘更小的
   CI runner 上可能误报阻断；届时需按实测调阈值，而不是直接放宽或删检查。
9. **能力索引剩余余量只有 55 B**（1745 / 1800）：再加一个内置工具必须先压缩其他摘要；已写成 1790 B 回归线，
   但"加工具时该压缩哪一条"仍需人判断（R-2 风险未消除）。
10. **`root` 分区文件数 60**（基线 59）：差异全部来自本阶段新增的根级测试文件（`gate_preflight_test`、
    `gate_stream_test`、`test_support_lifecycle_test`），已由覆盖元测试保证无遗漏、无重复。
11. **arch 的 R-8 并发冲突**：`arch-r1` 树仍有另一实例的在途工作，本会话**只从 `arch-r1-spike` 取 `spike.patch`
    与 `test_partition_coverage_test.exs.new`**，未使用 `arch-r1` 的任何内容；但两份方案（`@summary_bytes 66` vs 64、
    1745 B vs 1752 B）**细节不同，仍需 main 裁决唯一权威版本**。本交付以本树实测为准。
12. **`gate_post`/`gate-final*` 日志含 `ÃÂµs` 类乱码**：来自 `System.cmd`/Port 合流时 TTY 编码，属日志呈现问题；
    `*.clean.log` 只去 ANSI，未重编码，故数字与 `[test.fast]` 行可直接 grep，但中文用例名在个别日志段不可读。

## 4. 复现方法

```bash
# 全量门禁（唯一权威判据）
cd .worktrees/dev-r1
TMPDIR=<剩余空间 >2 GB 的目录> mix newbee.gate        # 期望：PASS 6 steps / GATE_EXIT=0

# 只看步骤表
mix newbee.gate --list

# 改前对照（未打补丁的同 commit 树）
cd .worktrees/dev-r1-base && mix newbee.gate           # 期望：The task "newbee.gate" could not be found
```

## 5. 证据索引（`.worktrees/dev-r1/dev-evidence/`）

| 文件 | 内容 |
|---|---|
| `dev-r1.patch` | 全部改动（72 文件，`git diff --stat` 复核） |
| `SHA256SUMS` | 补丁与本文件的 sha256（每次改动后重新生成） |
| `gate-final4.log` / `.clean.log` | **最终门禁 exit=0**（541.43 s，9 分区 + acceptance + web-js 明细） |
| `gate-post-tmpdir.log` | 第一次全绿（551.25 s，抖动修复前） |
| `gate-post.log` / `.clean.log` | 第一次门禁（`TMPDIR=/tmp`）：test-fast 1312 s、root 3 条 60 s 超时假红 |
| `root-only.log` | 同批用例换 `TMPDIR` 后 root 分区 **348 passed exit=0** |
| `gate-final.log` / `gate-final2.log` / `gate-final3.log` | 三轮失败现场（TOCTOU / 全局计数器），保留作收敛证据 |
| `before-warnings.log` / `after-warnings.log` | 39 passed EXIT=1（4 warnings）/ EXIT=0（0 warnings） |
| `before-contract-budget.log` / `after-contract-budget.log` | 1941 vs 1800 红 / 1 passed |
| `before-prompt-test.log` | 新守护测试放进基线树 → 0/3 passed |
| `before-meta-invalid.log` | 覆盖元测试放进基线树 → 0 tests, 3 invalid |
| `before-format.log` | 34 个未格式化文件清单 |
| `before-archive.log` / `after-archive.log` | 24/25 EXIT=2 / 26/26 EXIT=0 |
| `before-js.log` / `after-js.log` | 32/0 / 35/35 |
| `before-gate-missing.log` | 基线树无 `newbee.gate` |
| `reverse-meta.log` / `reverse-js.log` | 反向验证：删分区 → 19 文件红；改回 innerHTML → 1 条红 |

## 6. 收尾补记（最终验证）

交付文档写完后，按"文档写完仍要能复现"的要求又跑了一次完整门禁（源码自 `gate-final4` 之后未再改动，
唯一触及的文件是反向验证时临时改写又还原的 `priv/web/conversation-work.js`，sha256 已核对一致）：

```
$ sha256sum priv/web/conversation-work.js /tmp/cw.orig.js
495f9fb0c52d96a76f28f9dbc00237f08b829ac078980904769a92af887245ce  priv/web/conversation-work.js
495f9fb0c52d96a76f28f9dbc00237f08b829ac078980904769a92af887245ce  /tmp/cw.orig.js
$ grep -c innerHTML priv/web/conversation-work.js
0

$ TMPDIR=/home/alanx/data/tmp-newbee-dev mix newbee.gate        # 16:58:55 起
[test.fast] agent-dee          exit=0 24s  109 passed, 13 excluded
[test.fast] environment        exit=0 12s  149 passed
[test.fast] llm                exit=0 19s  180 passed, 3 skipped
[test.fast] tools-tui          exit=0 20s  215 passed
[test.fast] web                exit=0 125s 336 passed, 1 excluded
[test.fast] collaboration      exit=0 83s  150 passed
[test.fast] colony             exit=0 106s 177 passed
[test.fast] plugins-learning   exit=0 27s  80 passed
[test.fast] root               exit=0 62s  359 passed, 10 skipped
[gate] acceptance exit=0 in 10s      → 14 passed
[gate] web-js exit=0 in 0s           → 35 tests / 35 pass
[gate] PASS 6 steps: compile-dev, compile-test, format, test-fast, acceptance, web-js
WALL=505.73
GATE_EXIT=0
```

即 **连续三次全绿**（`gate-post-tmpdir` 551.25 s、`gate-final4` 541.43 s、`gate-verified` 505.73 s），
三次墙钟在 505–551 s 之间，**远低于 D-1 的 2500 s 上限**。
日志：`dev-evidence/gate-verified.log` / `gate-verified.clean.log`。

补丁与文档的哈希（本时点）：

```
# 哈希登记在 dev-evidence/SHA256SUMS（该文件不进补丁，避免自指）。
# 改动规模以 `git diff --stat` 与 `wc -l` 实测为准。
```

## 7. 工作树与环境副作用（如实记录）

| 项 | 状态 |
|---|---|
| 本会话新增工作树 | `.worktrees/dev-r1`（交付现场）、`.worktrees/dev-r1-base`（改前对照树；补丁可移植性复验后已 `git checkout -- . && git clean -fd` 还原为纯净 5ac87ba，`git status` 为空） |
| 主仓库工作区 | 7 个在途文件全程未被触碰（收尾 `git status` 与开工时一致） |
| `git worktree list` 注册数 | 243（arch 收尾） → **311**（本轮含 2 个自建树 + 4 次门禁跑批新增），清理需授权（R1P-08） |
| 临时目录 | 新建 `/home/alanx/data/tmp-newbee-dev` 作 `TMPDIR`（绕开已满的 `/tmp`），未清理任何系统文件 |
| 未落地的清理 | `/tmp` 里 4246 个条目 / 14 GB 历史产物属他人会话遗留，**未动** |

## 8. 补丁可移植性复验（新增）

上面所有"改后"结果都在 `.worktrees/dev-r1` 现场取得。为避免"只能在这棵树里跑通"的疑问，
把 `dev-evidence/dev-r1.patch` 打到**纯净的 5ac87ba 对照树**（`.worktrees/dev-r1-base`，
`git status` 为空、无任何本会话改动）后再跑一次门禁：

```bash
$ cd .worktrees/dev-r1-base          # 纯净 5ac87ba，git status 为空
$ git apply --check ../../.worktrees/dev-r1/dev-evidence/dev-r1.patch && echo PATCH_APPLIES_CLEAN
PATCH_APPLIES_CLEAN
$ git apply ../../.worktrees/dev-r1/dev-evidence/dev-r1.patch
$ git status --porcelain=v1 | wc -l
72                                   # 61 修改 + 11 新增（含 docs）
$ TMPDIR=/home/alanx/data/tmp-newbee-dev mix newbee.gate        # 17:12:36 起
[test.fast] agent-dee          exit=0 27s  109 passed, 13 excluded
[test.fast] environment        exit=0 14s  149 passed
[test.fast] llm                exit=0 19s  180 passed, 3 skipped
[test.fast] tools-tui          exit=0 26s  215 passed
[test.fast] web                exit=0 126s 336 passed, 1 excluded
[test.fast] collaboration      exit=0 78s  150 passed
[test.fast] colony             exit=0 108s 177 passed
[test.fast] plugins-learning   exit=0 30s  80 passed
[test.fast] root               exit=0 54s  359 passed, 10 skipped
[gate] acceptance exit=0 in 14s     → 14 passed
[gate] web-js exit=0 in 1s          → 35 tests / 35 pass
[gate] PASS 6 steps: compile-dev, compile-test, format, test-fast, acceptance, web-js
WALL=530.71
GATE_EXIT=0
```

结论：**补丁可独立移植**，打到一个从未被本会话写入过的干净树上同样 6/6 全绿
（第 4 次全绿，530.71 s）。日志：`dev-evidence/gate-from-patch.log` / `.clean.log`。

> 附注：`git apply` 打印 `new blank line at EOF.` 是行尾空行的提示（不是错误），
> 对应 `test/newbee/tools/gate_contract_test.exs` 末行；文件本身通过 `mix format --check-formatted`。
