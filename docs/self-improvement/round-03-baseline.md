# 第 3 轮 · 基线与环境校准（main）

- 生成时间：2026-11-18 13:40 +08:00
- 被测版本：`5ed39a6e8feece2cbfe3c1d309768769eb265c98`（= `origin/main`，#229）
- 测量位置：会话独占工作树 `.worktrees/main-r3`（detached，`deps -> ../../deps`）
- 机器：20 核 / 32 GB / Elixir 1.20.3 / OTP 29 / Node v22.23.3；测量期间 loadavg 6–17（同一台机器上另有其他会话与浏览器在跑，已按下文口径标注）
- 提交状态：**未 commit / 未 push / 未合并**；主仓库在途 10 文件 + 4 未跟踪目录开工收工一致

---

## 一、一句话结论

基线跑通了，而且比第 2 轮更可信：**同版本、同 seed、单次独占运行**下，官方门禁 7 分区 1496 用例 **12 红**，门禁外 32 文件 283 用例 **4 红**，acceptance 4 次里 3 次全绿（1 次 60 s 超时），构建 0 警告，格式 31 文件红，前端 32 用例 **0 通过**。
本轮把「红」拆成了三类并给了判据：**确定性失败 4 条**（两次隔离复跑都红）、**抖动 3 条**（两次隔离复跑只红一次）、**门禁并发专属 6 条**（单独跑同 seed 全绿）。

同时本轮发现一条 **P0**，我自己认为它是当前最该先解决的问题（见第五节）：

> **当用户项目没有自己的 `.git`、但它所在目录的某个祖先目录是 git 仓时，`Newbee.Colony.Workspace` 会把隔离工作区注册到那个祖先仓上。**
> 沙箱里 `git log` 看到的是**别人的提交**、`git status` 显示的是**别人的文件被删**，而且**不报任何错**。
> 这条缺陷同时是本轮「644 条 worktree 注册」脏数据的**同一个根因**（缺 `--show-toplevel` 归属校验）。

---

## 二、成果位置与版本

| 项 | 值 |
|---|---|
| 本报告 | `baseline-r3/round-03-baseline.md` |
| 结构化基线 | `baseline-r3/metrics.json`（JSON 已 `json.load` 校验，19 个顶层键） |
| 一键复现 | `baseline-r3/repro.sh`（`bash -n` 通过 + **本轮真实跑通 quick 档 exit=0，4m02s**） |
| 原始证据 | `baseline-r3/logs/`（构建 4 + 格式 1 + 前端 1 + 门禁 1 + 覆盖率 3 + acceptance 4 + 汇总 1）、`baseline-r3/isolated/`（15 日志）、`baseline-r3/isolated2/`（7 日志）、`baseline-r3/poc/`（2 段可执行 PoC + 2 份输出） |
| 文件清单 | `baseline-r3/all-test-files.txt`、`covered-files.txt`、`uncovered-files.txt`、`gap-files.txt`、`failing-files.txt`、`unformatted.txt` |

复现入口：

```bash
cd .worktrees/main-r3
bash baseline-r3/repro.sh          # quick，约 4 分钟：构建/格式/前端/acceptance/覆盖率/PoC
bash baseline-r3/repro.sh --gate   # 追加官方门禁，约 47 分钟
bash baseline-r3/repro.sh --full   # 追加门禁 + 漏跑 32 文件 + 15 文件逐文件隔离，约 2 小时
```

---

## 三、基线数据（全部来自日志，无推断值）

### 3.1 构建（`mix compile --warnings-as-errors`）

| 场景 | 耗时 | exit | 警告 |
|---|---|---|---|
| dev 冷（`rm -rf _build`） | 95.2 s | 0 | 0 |
| test 冷 | 166.4 s | 0 | 0 |
| dev 热 | 8.4 s | 0 | 0 |
| test 热 | 13.3 s | 0 | 0 |

> 复现 quick 档第二次跑（`_build` 已在）为 8.3 / 12.9 / 11.6 / 8.1 s，说明冷/热口径必须显式声明，否则同一份脚本能差 19 倍。

### 3.2 格式

`MIX_ENV=dev mix format --check-formatted` → **exit=1，31 个文件未格式化**（`lib/newbee` 15 + `test/newbee` 16，清单见 `baseline-r3/unformatted.txt`）。
`AGENTS.md:105` 只要求「改动文件的」检查，所以这条从来不会在全仓层面被拦住——与 R2 结论一致，本轮只是补上精确清单。

### 3.3 前端

`node --test test/web/conversation-work.test.js` → **exit=1，32 用例 0 通过**。三类根因：

1. 测试替身缺 `classList.toggle`（`priv/web/conversation-work.js:852` 调用，替身没实现）→ 30 条 `TypeError`；
2. 源码契约用例的正则 `/innerHTML/` 命中的是**注释文字**（文件头规则说明里写了 "clusive innerHTML"），不是代码；
3. 替身违反 `textContent`-only 契约。

**而且它不在任何 mix 门里**：全仓 `grep 'node --test'` 只命中两处**文档**（`docs/conversation-work-operations.md:76`、`test/web/conversation-work.md:13`），无 CI（无 `.github/`、无 `.gitlab-ci.yml`）。所以「前端 32 个用例」对门禁而言等于不存在。

### 3.4 官方门禁 `mix newbee.test_fast`（单次独占，seed=1）

| 分区 | exit | 墙钟 | 收集 | 通过 | 失败 | 跳过/排除 |
|---|---|---|---|---|---|---|
| agent-dee | 2 | 376.7 s | 116 | 114 | **2** | 13 excluded |
| environment | 2 | 257.1 s | 149 | 148 | **1** | 0 |
| llm | 0 | 126.8 s | 175 | 175 | 0 | 3 skipped |
| tools-tui | 2 | 70.8 s | 188 | 187 | **1** | 0 |
| web | **3** | 612.1 s | 358 | 357 | **1** | 1 excluded |
| collaboration | 2 | 532.6 s | 160 | 159 | **1** | 0 |
| root | 2 | 531.7 s | 350 | 344 | **6** | 10 skipped |
| **合计** | **1** | **2599.1 s** | **1496** | **1484** | **12** | 27 |

分区串行耗时之和 2507.8 s，门禁总墙钟 2599.1 s（差 91.3 s = 7 次 `mix test` 启动 + 最终汇总）。

**`exit=3` 的语义本轮首次被实测确定**（在 `/tmp/exp` 里造的最小工程上逐项验证）：

| 场景 | exit |
|---|---|
| 0 失败、0 警告 | 0 |
| 0 失败、1 编译警告、不加 `--warnings-as-errors` | 0 |
| 0 失败、1 编译警告、加 `--warnings-as-errors` | **1** |
| 1 失败、0 警告 | **2** |
| 1 失败、1 警告、加 `--warnings-as-errors` | **3** |
| 3 失败、0 警告 | **2** |

所以 `web` 分区的 `exit=3` 不是「3 个失败」，而是 **1 个失败 + 2 条编译警告**。这两条警告本轮也定位到了行：

- `test/newbee/web/colony_team_api_test.exs:25` — `variable "cid" is unused`
- `test/newbee/web/static_asset_allowlist_test.exs:12` — `unused import Plug.Conn`

**含义**：即使产品代码一行不改，这两行测试文件的警告就能让整个 `web` 分区在门禁里判红。R2 报告的 G8「全绿不许被标志误杀」在本轮被落到 2 行具体代码上——这是可以直接修的。

### 3.5 门禁覆盖率（静态可判定，秒级）

```
all_files=254   covered_files=221   uncovered_files=33   gap_files=32
static_tests_total=1820   static_tests_in_gap=283
```

33 个未覆盖文件里 1 个是 `acceptance_test.exs`（有意单独跑），**其余 32 个文件 = 283 个用例完全不在门禁内**：

| 目录 | 文件 | 静态用例 | 在门禁内 |
|---|---|---|---|
| `test/newbee/colony/` | **19** | **179** | **否（0/19）** |
| `test/newbee/plugins/` | 4 | — | 否 |
| `test/newbee/learning/` | 4 | — | 否 |
| `codec` / `terminal` / `host` / `evals` / `truncate` | 各 1 | — | 否 |

`lib/mix/tasks/newbee/test_fast.ex` 的 `@partition_specs` 里**没有 `test/newbee/colony`** 这一项——`grep -n colony` 在该文件 0 命中。这意味着：

> **整个蜂群（colony）子系统 179 个用例，官方门禁一个都不跑。**

本轮补跑这 32 个文件：`mix test --warnings-as-errors --seed 1 <32 files>` → **exit=3，279/283 通过，4 失败**，墙钟 1650.4 s（27.5 分钟）。这 4 条失败**从来没在门禁里出现过**。

### 3.6 acceptance

`mix test.acceptance`（`--warnings-as-errors --seed 1`）跑了 4 次：

| 次 | exit | 结果 | 用例耗时 |
|---|---|---|---|
| 1（门禁会话中，loadavg ~11） | 0 | 14/14 | 142.3 s |
| 2（repro quick 内） | **2** | **13/14** | 178.4 s |
| 3 | 0 | 14/14 | 177.4 s |
| 4 | 0 | 14/14 | 178.5 s |

唯一失败是 `test/newbee/acceptance_test.exs:389`「§15.9 generation 启动失败恢复最近 known-good revision 并标 degraded」`ExUnit.TimeoutError after_seg 60000ms`。
→ **acceptance 抖动率 1/4 = 25%**（同 commit、同 seed、同机）。R2 只跑了一次 14/14 就记为绿，本轮把这条抖动暴露出来。

### 3.7 失败全集：16 条，按可复现性分类

**A. 确定性失败（两次逐文件隔离复跑都红，4 条）**

| ID | 用例 | 位置 | 观测 |
|---|---|---|---|
| F1 | stale candidate must be reevaluated on the current revision before approval | `environment/coordinator_reevaluate_test.exs:11` | `status: :evaluating` 从未到 `:canary`；隔离跑 0/1（两次都是） |
| F2 | 常驻工具提示短小且没有已删除 API | `tools/tool_documentation_contract_test.exs:8` | `byte_size 1941 > 1800`（两次都是同一对数字） |
| F3 | 二次压缩回放含旧摘要的 envelope（旧摘要前缀） | `archive_test.exs:360` | 24/25（两次都是同一处） |
| F4 | GoalAccountingTest（两次都红 3–4 条，子集不同） | `agent/goal_accounting_test.exs:101` 等 | RUN1 3/7、RUN2 4/7；「3 轮阻塞才置 :blocked」两次都红 |

**B. 抖动（两次隔离只红一次，3 条）**

| ID | 用例 | 位置 | RUN1 / RUN2 |
|---|---|---|---|
| F5 | 压缩后 transcript 字节不变；恢复的会话即压缩视图 | `dee/kernelcompact_test.exs:56` | 红（60 s 超时）/ 绿 |
| F6 | 手动上下文的句柄同样指向非空对象 | `web/terminal_spill_test.exs:121` | 红（`{:error, :timeout}`）/ 绿 |
| F7 | the real dispatcher, Session, Loop and model HTTP return a current result | `colony/conversation_execution_test.exs:144` | 红 / 绿（302 s） |

**C. 门禁并发专属（单独跑同 seed 全绿，6 条）**

`commandstest_test.exs`（`/resume`）、`event_store_tail_test.exs`、`fs_walk_test.exs`、`media_test.exs`、`truncate_test.exs`（长日志分页）、`collaboration/chat_test.exs` —— 这 6 条在 `root` / `collaboration` 分区里红（分区用 `max_cases: 40` 并发），单独跑 22 / 5 / 6 / 7 / 12 / 22 全绿。

**D. 门禁外才出现（本轮新增可见，2 条）**

`colony/conversation_work_test.exs:28`（并发只产出一份 durable work）、`colony/workspace_review_test.exs:65/104`（git worktree 接 deps / 保留可执行位）—— 单独跑 14 / 25 全绿，只在 32 文件一起跑时红。

**分类的判据**：同一文件、同 seed、`--no-compile`、串行、各自 `TMPDIR=/tmp/r3-tmp`，跑两轮（`baseline-r3/isolated/summary.txt`、`isolated2/summary.txt`）。

> 与 R2 的差异：R2 记「三次全红只有 2 条」（能力索引 1941>1800、archive:360）。本轮把确定性集合扩到 4 条（多出 environment 的 stale candidate 与 goal_accounting 的 blocked 判定），并把 acceptance 的 25% 抖动记进基线。R2 的「门禁结果对并发敏感」结论在本轮被量化：**12 条门禁红里 6 条是并发专属**。

---

## 四、环境与工具链本身的污染（本轮新增度量）

`git worktree list` 在本仓（`/home/alanx/data/git/newbee`）报告 **644 条**注册，磁盘上只有 **36 个** `.worktrees/*` 目录。拆解：

| 归属 | 条数 |
|---|---|
| 测试自有：路径含 `tmp/Newbee.<Module>.<Test>/…` | **572** |
| 其中直接位于 `<repo>/tmp/` | 23 |
| 其中**嵌套在其它 worktree 内部** | 533 |
| 会话工作树本体 | 36 |
| 产品 colony workspace | 18 + 11 |
| 其他 | 8 |

成本（同一台机器、交替重复 3–5 次取中位）：

| 指标 | 实仓（644 条） | 干净克隆（1 条） | 倍数 |
|---|---|---|---|
| `git worktree list --porcelain` | **324 ms** | 20 ms | **16.2×** |
| 输出体积 | **185,624 B** | 113 B | 1643× |
| `git worktree prune` | 30 ms | 21 ms | 1.4× |

合成曲线（`/tmp/wtcurve` 里从零造 N 棵 worktree，每点 3 次取均值）：

| N | `list --porcelain` | `prune` |
|---|---|---|
| 0 | 3 ms | 3 ms |
| 50 | 4 ms | — |
| 200 | 14 ms | 7 ms |
| 400 | 74 ms | — |
| 600 | **341 ms** | 135 ms |

→ **超线性**。644 条不是线性增长带来的 34 ms，而是 324 ms。任何走 `git worktree list` 的产品路径都会撞上它（`lib/newbee/collaboration/workspace.ex:745`、`lib/newbee/colony/workspace.ex:92`）。

**为什么 `after_seg_suite` 的 prune 收不掉**：`git worktree prune` 只删「目录已消失」的条目。测试 fixture 目录（`tmp/Newbee.X/test-y`）跑完仍然存在，所以 `prunable = 0`（本轮实测 `git worktree prune --dry-run -v` 输出 0 行），条目永久留着。

**增长速率**：`.git/worktrees/*/gitdir` 的 mtime 分布为 11-16 新增 154、11-17 新增 247、11-18（半天）24；本轮从 11:05 到 13:12 的**全部**运行（门禁 + acceptance×4 + 32 文件 + 22 次逐文件跑）累计 **+19 条，且一条都没被回收**。

**磁盘**：`.worktrees` 14 GB、`.newbee` 3.5 GB、`/home` 已用 **62 GB / 72 GB（92%）**，剩 6.1 GB。这不是美观问题，是下一次冷编译/整轮门禁可能因空间失败的风险。

---

## 五、本轮自选「最严重问题」：R3P-01 隔离工作区绑错仓（P0）

### 5.1 判定与证据

`lib/newbee/colony/workspace.ex:106` 的 `attach_git/2` 只问一件事：

```elixir
case git(source, ["rev-parse", "--verify", "HEAD"]) do
```

`git` 会**向上查找** `.git`。所以只要用户项目所在的**任一祖先目录**是 git 仓，这个调用就成功，接着 `git worktree add` 就把沙箱注册到那个**祖先仓**上。

可执行 PoC（`baseline-r3/poc/colony-workspace-wrong-repo.exs`，走真实产品函数 `Newbee.Colony.Workspace.ensure/2`），完整输出见 `baseline-r3/poc/colony-workspace-wrong-repo.log`：

```
proj_has_dot_git=false
proj_rev_parse_toplevel=/tmp/r3-final/outer
ensure_returned={:raised, CaseClauseError, "no case clause matching: {:error, :not_found}"}

--- 崩溃后残留（证明 R3P-02：rollback 被跳过）
workspace_exists=yes
workspace_dot_git=gitdir: /tmp/r3-final/outer/.git/worktrees/colony-task_poc_1
workspace_toplevel=/tmp/r3-final/outer/proj/.newbee/workspaces/colony-task_poc_1
workspace_log=23791e1 outer                                  <- 别人的提交
workspace_status= D other_project_secret.txt| D proj/main.txt|?? main.txt   <- 别人的文件被"删"
snapshot_term=1
outer_registrations=2
```

**两件事同时被证明**：

1. 沙箱的 git 身份绑定到 `/tmp/r3-final/outer`（祖先仓），不是用户项目 `outer/proj`；
2. `ensure/2` 抛 `CaseClauseError` 之后，沙箱目录、`.base_snapshot.term`、外层仓里的 1 条 live 注册**全部留下**（`rollback/2` 被跳过）。

对照组（项目自己有 `.git`）：`toplevel => /tmp/sem2/ws   log => c5290b8 own`——正确绑定到自己的仓。

### 5.2 为什么我认为它比门禁红更严重

1. **它不是「测试红」，是产品在正常输入下给出错误的世界模型。** 用户项目没有 `.git` 完全合法（稿纸目录、解压包、非版本化脚本集）；只要它恰好放在某个 git 仓里（把项目放在 `~/work/` 而 `~/work` 本身是仓，或放在本仓 `tmp/` 下），沙箱就变成别人的 worktree。
2. **无任何报错、无任何提示**（在 R3P-02 的崩溃路径上恰好会崩，但在 `workspace_source` 已持久化的正常路径上会静默成功）。
3. **它和「648 条注册」同一个根因。** 关掉这一个口子（校验 `--show-toplevel == source`），脏注册的主要来源一起消失——本轮 **574 条**测试自有注册的产生机制与它完全一致（fixture 目录没有 `.git`，祖先仓是主仓）。
4. **它把一个 P0 变成可判定的验收项**：给定「非 git 项目位于 git 仓内」，沙箱的 `git rev-parse --show-toplevel` 必须**失败**或等于自身，而**不能**等于祖先仓。一行断言即可判定，反向验证也简单。

### 5.3 顺带确认的第二个缺陷 R3P-02（P1）

同一个 PoC 暴露：`lib/newbee/colony/workspace.ex:54` 只匹配 3 元组：

```elixir
{:error, _code, _message} = error -> _ = rollback(source, name); error
```

而 `Store.update/4` 在任务未持久化时返回 `{:error, :not_found}`（2 元组）→ `CaseClauseError` 直接崩，**`rollback/2` 被跳过**。实测残留：

- `.newbee/workspaces/colony-task_poc_1/`（沙箱目录）
- `.newbee/workspaces/colony-task_poc_1.base_snapshot.term`（快照）
- 外层仓里 1 条 live 注册

生产可达性我**没有证实**（需要 `source == "team_run"` 但任务不在 store 里这个组合），所以标 P1 并注明「PoC 确认、生产待证实」，不冒充已证实。

---

## 六、门禁自身的可信度清单（G 系列本轮实测）

| ID | 项目 | 现状（实测） | 判据 |
|---|---|---|---|
| G1 | 构建零警告 | ✅ 4/4 exit=0 | `mix compile --warnings-as-errors` × dev/test |
| G2 | 全仓格式 | ❌ 31 文件 | `mix format --check-formatted` exit=0 |
| G3 | 门禁 | ❌ exit=1，12 红 | `mix newbee.test_fast` exit=0 |
| G4 | 覆盖率 | ❌ 32 文件 / 283 用例不在门禁内，**colony 19 文件 179 用例 0 覆盖** | `uncovered-files` 为空 |
| G5 | acceptance 稳定 | ⚠️ 3/4 绿 | 连跑 4 次全绿 |
| G6 | 前端 | ❌ 32/0，且无入口 | `node --test` 绿 + 有入口 |
| G7 | exit 语义可区分 | ❌ `2`/`3`/`1` 混用无文档 | 门禁输出报告「失败数 / 警告数」分开 |
| G8 | 全绿不被标志误杀 | ❌ `web` 分区被 2 行测试警告判红 | 警告归警告，失败归失败 |
| G9 | 注册表有界 | ❌ 644 条、16× 慢、+19/轮 | ≤ 50 且整轮门禁后不增长 |

---

## 七、本轮验收尺子（R3 尺子，供 pm/arch/dev/qa 直接引用）

### 7.1 数值尺（M）

| ID | 指标 | 基线值 | R3 目标 | 测量命令 |
|---|---|---|---|---|
| M1 | 冷构建 dev / test | 95.2 / 166.4 s | ≤ 1.15× | `rm -rf _build && mix compile` |
| M2 | 热构建 | 8.4 / 13.3 s | ≤ 1.15× | `mix compile` |
| M3 | 未格式化文件 | **31** | **0** | `mix format --check-formatted` |
| M4 | 门禁失败数 | **12** | **0** 或全部进「已知隔离名单」 | `mix newbee.test_fast` |
| M5 | 门禁收集用例 | 1496 | ≥ 1496 + 283（补齐后 ≥ 1779） | 各分区 `Result:` 求和 |
| M6 | 门禁外文件 | **32** | **0** | `all - covered` |
| M7 | colony 覆盖用例 | **0 / 179** | **179 / 179** | `uncovered-files.txt` |
| M8 | 前端用例 | **0 / 32 通过** | **32 / 32** | `node --test test/web/conversation-work.test.js` |
| M9 | acceptance | 3/4 绿 | **4/4** | 连跑 4 次 `mix test.acceptance` |
| M10 | 确定性失败 | **4** | **0** | 逐文件隔离两轮 |
| M11 | 抖动失败 | 3（隔离）+ 6（并发）= 9 | ≤ 3 | 隔离两轮 + 分区复跑 |
| M12 | worktree 注册数 | **644** | **≤ 50** | `ls .git/worktrees \| wc -l` |
| M13 | `worktree list` 耗时 | **324 ms** | **≤ 40 ms** | 5 次中位 |
| M14 | 每轮门禁新增注册 | +19 | **0** | 跑前/跑后差集 |
| M15 | 编译警告 | 2（测试文件） | **0** | 门禁各分区日志 `warning:` 计数 |
| M16 | 沙箱仓归属 | ❌ 绑到祖先仓 | 必须等于源项目或明确「非 git」 | 第五节 PoC |

### 7.2 门禁尺（G1–G9）

见第六节表；每条都有「现状值 → 目标值 → 命令」。

### 7.3 用户反馈尺（U，沿用 R2 并补条件）

| ID | 判定 | 已有证据 | R3 需补的条件 |
|---|---|---|---|
| U1 | 工作室面板输入 10 分钟不被吃 | R2 只到 34 s / 8 次轮询 | **失焦后**仍存活（QA2-D1 未解） |
| U2 | auto 闸门推进 `stage_index` | R2 探针 3→4 | `team_auto_gate_test` 必须进分区（当前不在，M6） |
| U2b | 项目闭环按钮存在 | 未修 | 详情区有操作按钮 |
| U3/U3b | 删除闭环 | 未修 | 删除后 `session_map`/侧栏不再返回 |
| U4/U5 | 项目终止/归档；分组管理 | 未修 | — |

### 7.4 判定即用的 T 项（命令 + 期望 + 反向验证）

| ID | 命令 | 期望 | 反向验证 |
|---|---|---|---|
| T1 | `mix format --check-formatted` | exit=0，`grep -c '^/home' 输出=0` | 任意文件加一个空行 → 必红 |
| T2 | `mix newbee.test_fast` | exit=0，7 分区全 0 | 还原一行修复 → 对应分区必红 |
| T3 | `bash baseline-r3/repro.sh` | exit=0，`uncovered_files=0` | 从 `@partition_specs` 删一项 → `uncovered_files>0` |
| T4 | `node --test test/web/conversation-work.test.js` | `# pass 32 / # fail 0` | 把 `classList.toggle` 调用改回 `innerHTML` 清空 → 必红 |
| T5 | `ls .git/worktrees \| wc -l` 于跑完 T2 之后 | ≤ 50 且与跑前相同 | 恢复 `attach_git` 原判定 → 每轮 +N |
| T6 | `MIX_ENV=dev mix run baseline-r3/poc/colony-workspace-wrong-repo.exs /tmp/x` | `ensure_returned` 为 `{:ok, path}` 或 `{:error, "workspace_needs_git", _}`，且 `sandbox_log` **不含**外层仓提交 | 去掉 toplevel 校验 → `sandbox_log=… outer` 复现 |

---

## 八、与第 2 轮的对比（增量，不是重跑）

| 维度 | R2 结论 | R3 实测 | 变化 |
|---|---|---|---|
| 门禁失败数 | 3（独占）/ 4 / 15 | **12**（单次独占） | 口径不同（R2 的 3 是「三次全红交集」，不是单次失败数）；R3 给的是单次全量 |
| 确定性失败 | 2 条 | **4 条** | +2（environment stale candidate、goal_accounting blocked） |
| acceptance | 1 次 14/14 | 4 次，3 绿 1 超时 | **新增 25% 抖动** |
| 门禁外用例 | 283（32 文件） | 283（32 文件），实测 279 通过 4 红 | 补跑数值化 |
| colony 覆盖 | 「colony 整子系统漏」 | **19 文件 / 179 用例 / 0 覆盖** | 精确化 |
| 前端 | 32/0，无入口 | 同，且根因定位到 3 类、2 个文件 2 行 | 可修 |
| worktree | 421 行 / 422 行（R1/R2 口径不一） | **644 条注册 / 36 磁盘 / 16.2× 慢 / +19 per 轮** | 精确化 + 成本曲线 |
| 新缺陷 | — | **R3P-01（P0 绑错仓）、R3P-02（P1 崩溃跳过回滚）、R3P-03（P1 注册表无界）** | 本轮新增 |

---

## 九、未覆盖范围（如实声明）

1. **没有改任何产品代码**。本轮只做基线；R3P-01/02/03 只到 PoC，没有补丁。
2. **门禁只跑了 1 次单次独占**（2599 s）。R2 的「对并发敏感」结论本轮用「隔离两轮」部分替代，但没有做「同 commit 三次门禁」的重复实验——成本约 2 小时/次。
3. **真实浏览器未复核**：本机 Chromium 正被其他会话占用（`ps` 见 `chrome` 198% CPU），U1 的失焦行为仍只有 R2 的 jsdom 证据。
4. **R3P-02 的生产可达性未证实**（只有 PoC 触发）。
5. **逐用例耗时 p50/p90/p99 仍无数据**（没有落逐用例 JSONL）；本轮的耗时口径是「分区级 + 文件级（隔离跑）」。
6. **`root` 分区的 6 条并发红没有做并发度扫描**（`max_cases` 固定 40，未测 20/10/1）。
7. **未测 R1 补丁**（`dev-r1.patch` 对 `5ed39a6` 仍冲突 3 处），也未做「R1 与 R2 补丁叠加」验证——这需要 main 层面的基座决策。
8. **磁盘 92% 占用未清理**（需授权）；本轮没有删除任何 worktree。

---

## 十、下一轮（R4）建议目标

按「可判定 + 一个根因多处收益」排序：

1. **R3P-01 绑错仓**（P0，1 处校验 + 3 条用例 + T6 反向验证）。同时把 M12/M14 一起带下去——这是同一根因的双收益。
2. **G4 覆盖率**：把 `test/newbee/colony`（19 文件 / 179 用例）接进 `@partition_specs`，接受它带来的 4 条已知红并逐条定性。没有这一步，R2 修好的 auto 闸门在门禁眼里依然等于没修。
3. **G8 的 2 行**：`colony_team_api_test.exs:25` 的 `cid`、`static_asset_allowlist_test.exs:12` 的 `import Plug.Conn`——2 行改动即可让 `web` 分区不再被标志误杀。
4. **G2 的 31 文件**：一次性 `mix format` 全仓，风险低但要独立 commit 便于回滚。
5. **G6 前端**：修替身的 `classList.toggle` 与源码契约正则（`innerHTML` 只查代码不查注释），并给它一个入口（`mix newbee.test_fast` 加一个 `js` 分区或 alias）。
6. **确定性失败 4 条**逐条定性（产品对/测试错），acceptance 25% 抖动单独归因（F1 与 acceptance:389 都是「异步状态等到点上」的问题，可能同一类）。

不建议在 R4 一并处理：U2/U3/U4（产品功能缺口，需要 pm 重新排序）、worktree 历史清理（需授权且不可逆）。

---

## 十一、复现步骤（最小集）

```bash
cd /home/alanx/data/git/newbee/.worktrees/main-r3
git rev-parse HEAD                       # 5ed39a6e8feece2cbfe3c1d309768769eb265c98
readlink -f deps                         # /home/alanx/data/git/newbee/deps

# 1) 4 分钟：构建/格式/前端/acceptance/覆盖率/PoC
bash baseline-r3/repro.sh | tee /tmp/r3-quick.out

# 2) 47 分钟：追加官方门禁
bash baseline-r3/repro.sh --gate | tee /tmp/r3-gate.out

# 3) 单独验证 P0（30 秒）
MIX_ENV=dev mix run baseline-r3/poc/colony-workspace-wrong-repo.exs /tmp/r3-poc
# 期望（当前版本）：sandbox_log 打印的是 outer 仓的提交 —— 这就是缺陷
```
