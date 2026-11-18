# 第 1 轮 · 发现产品不足 —— 问题清单（pm）

- 轮次：R1（自我改进循环第 1 轮，计划 ≥100 轮）
- 角色：产品经理（pm）
- 时间：2026-11-16 09:20–10:05 (+08:00)
- 被测版本：`5ac87bad145b0801e7d8c5145895e87ddd4ac3ff`（`origin/main`）
- 测量位置：会话独立工作树 `/home/alanx/data/git/newbee/.worktrees/pm-r1`（detached 5ac87ba，`deps` 软链主仓库）
- 原始证据：`.worktrees/pm-r1/pm-evidence/`（日志、探针脚本、清单）
- 上游输入：`docs/self-improvement/round-01-baseline.md`（main 的 R1 基线，10 条缺陷 D1–D10、8 门禁 G1–G8、12 指标 M1–M12）
- 提交状态：**未 commit / 未 push / 未合并**；主仓库工作区 7 个在途文件全程未被触碰（含另一会话正在修的 JS 测试替身）

## 0. 结论速览

1. 基线报告的 10 条缺陷里，**8 条在本会话独立复现**（D1 能力索引、D2 警告、D3 archive、D4 前端、D5 漏跑、D6 格式、D9 性能断言、D10 worktree）；**D7（抖动）在低负载下单跑不复现**——这本身就是它的定义，其"门禁下必现"由 R1 基线的 6 条失败记录承担，本会话不重复声称；**D8（可观测性）**改为代码走查（串行分区、逐用例不落盘、bench 只有 1 个任务）确认。没有一条是"另一会话环境特有"。
2. **本会话新发现 3 条基线与主协调人都没有记录的缺陷**：
   - **R1P-06**：`archive_test.exs:360` 的失败**不是产品 bug，是测试在断言一个 2026-10-20 已被 #215 废弃的契约**。真实产品行为是对的（我实测：摘要回放前缀 == 真正发往上游的 wire 投影，逐条相等）；坏的是"缓存前缀逐字节一致"这条**核心不变量因此没有任何守护测试**——测试测错了对象，真回归会漏。
   - **R1P-09**：仓库**没有任何 CI**（无 `.github/`、无其它 CI 配置），README 宣称的 `mix test.all` 是"完整入口"却漏 JS 与 32 个测试文件，因此主干长期可以带 8 条红合并。
   - **R1P-11**：`docs/conversation-work-operations.md` 写着"前端 26 项通过"并引用 `.newbee-tmp/conversation-final-node.log`，该日志**已不存在**（被 gitignore），而套件真实用例数是 32（主仓库在途版本 44）——文档把"某个时刻的一次通过"当成可复核证据。
3. 另有 3 条基线未覆盖但同源的问题：R1P-10（门禁墙钟即将翻倍）、R1P-12（JSpace 台账跨会话串写）、R1P-13（"覆盖"只到文件级）。
4. **本轮入选 7 条**（R1P-01～07，其中 07 为第 2 批、允许顺延 R3）+ 1 项集成收口（R1P-09），目标是"让红=真缺陷成立"；其余按优先级排到 R3/R4，理由与验收标准都已写好，不会丢。

## 1. 本会话的证据口径（可复核）

环境：Elixir 1.20.3 / OTP 29、Node v22.23.3、20 逻辑核、测量时 `loadavg 2.36/2.91/2.95`（比 R1 基线测时的 6.33→17 低得多，因此**本轮的耗时数字比基线更乐观**，只用于同条对比）。

读基线报告时发现的、必须写清楚的差异：**`mix test_fast` 的 32 个漏跑文件，我用 `Path.wildcard` 独立算了一遍 = 32 文件 / 281 条静态 `test "` 声明**，与基线报告的 32/281 完全一致（交叉验证通过）。

复现入口（在 `.worktrees/pm-r1` 下）：

```bash
bash pm-evidence/repro.sh          # 逐条重跑本报告所有结论（约 4 分钟）
```

| 证据文件 | 内容 |
|---|---|
| `pm-evidence/summary.txt` | 6 条探针的 exit / 墙钟 |
| `pm-evidence/d1_capability_index.log` | 能力索引 1941 > 1800 |
| `pm-evidence/m1_budget.exs` | 1941 B = 头 66 + 条目 1856 + 换行 19（20 条，均值 92.8 B，Team 143 B） |
| `pm-evidence/d2_test_warnings.log` | web：10 passed 仍 exit=1 |
| `pm-evidence/d2b_flaky.log` | colony：29 passed 仍 exit=1；coordinator 3/3 通过；session_new 通过 |
| `pm-evidence/d3_archive.log` | 24/25，失败 = archive_test.exs:360 |
| `pm-evidence/d3_probe.exs` / `d3_probe2.exs` | **前缀一致性探针**：`sent_prefix==routed` 为 true、`sent==sanitize_only` 为 false |
| `pm-evidence/d9_session_perf.log` | list_us 10263 vs decode_us 4060 |
| `pm-evidence/list_perf.exs` / `perp_probe.exs` | list_page 随会话数/冷热的真实成本 |
| `pm-evidence/js_suite.log` | 32 tests / 0 pass；6 处 innerHTML；31 条崩在 classList.toggle |
| `pm-evidence/d6_format.log` + `unformatted-files.txt` | 34 个未格式化文件（清单） |
| `pm-evidence/uncovered-files.txt` | 32 个漏跑文件（清单） |
| `pm-evidence/wt_delta*.log` / `colony_suite.log` / `leak2*.log` / `leak3.log` | worktree 注册增量：首次 +7 / 全量 +18；重跑 +0（首跑才注册） |
| `pm-evidence/repro.sh` + `repro-summary.txt` | 一键重跑全部结论；真实运行 exit=0，逐行结果见下 |

`pm-evidence/repro.sh` 的**真实运行结果**（2026-11-16T10:05:51→10:07:11，`loadavg 2.18`，exit=0）：

```text
coverage: all=250 covered=218 uncovered=32 static_tests=281
m1           exit=0   prompt_section_bytes=1941 budget=1800
warn_web     exit=1   10 passed 但仍 aborted（2 处警告）
warn_colony  exit=1   29 passed 但仍 aborted（2 处警告）
format       exit=1   34 个文件未格式化
archive      exit=2   24/25（失败 = archive_test.exs:360）
archive_probe exit=0 sent_prefix==routed=true / sent_prefix==sanitize_only=false
perf_list    exit=2   list_us 10263 vs decode_us 4060
js           exit=1   32 tests / 0 pass
leak         首次 +7（脚本重跑时为 0，机制见 R1P-08）
```

> 脚本除 worktree 注册（首次才增长）外是**幂等**的：重复运行给出同样的 exit 码与数字。

## 2. 问题清单（按 影响 × 成本 排序）

优先级定义：**P0** 直接破坏"红=真缺陷"或核心路径正确性；**P1** 高影响但可绕行；**P2** 卫生/可观测性；**P3** 机会。

| ID | 现象（一句话） | 影响 | 优先级 | 本轮 |
|---|---|---|---|---|
| R1P-01 | 门禁漏跑 32/250 个测试文件（281 用例），整个 colony 子系统不在任何日常入口 | 团队协作这条最活跃产品线零门禁；漏跑用例全绿也无法证明主干健康 | **P0** | ✅ 入选 |
| R1P-02 | 前端 JS 套件 32/32 全红，且不属任何 mix 门禁 | 6 处 innerHTML 违约 + 测试替身缺 API；前端回归长期无人看守 | **P0** | ✅ 入选 |
| R1P-03 | 4 处测试文件编译警告使"全通过"分区仍 exit≠0 | 本会话实测：web 组合 10 passed→exit=1、colony 组合 29 passed→exit=1；R1 里 colony 281 全通过仍 exit=1。红信号被噪声污染，且违反 AGENTS.md | **P0** | ✅ 入选 |
| R1P-04 | 34 个文件未格式化（最早 2026-09-02） | `mix format --check-formatted` 常红；提交前只查改动文件 → 长期漏 | P1 | ✅ 入选 |
| R1P-05 | 常驻能力索引 1941 B > 契约上限 1800 B（超 141 B） | 每轮对话多带 141 B；预算防线已失效；Team 摘要截断在半个词 | P1 | ✅ 入选 |
| R1P-06 | `archive_test.exs:360` 断言的是 #215 已废弃的契约；真实"逐字节前缀"不变量无守护 | 一条 P0 级缓存正确性不变量**测错了对象**：现在红（假警报），把测试删掉就变成永久漏检 | **P0** | ✅ 入选 |
| R1P-07 | 4 类抖动断言（`dt<500`、4 s 等待预算、`list_us<decode_us`、`micros<500_000`） | 门禁随负载/顺序随机翻脸；G8 三种子不一致已定位到这类用例 | **P0** | ✅ 入选（第 2 批，允许顺延 R3） |
| R1P-09 | 无 CI、无单一门禁命令（README 的 `test.all` 既不绿也不全） | 8 条红可以合进 main，且没人被拦 | **P0（治理）** | ✅ 入选（收口项） |
| R1P-08 | 测试创建的 git worktree 注册只增不减：colony 全量首跑 +18，历史累积到 **223** 条（R1 基线 204） | `.git/worktrees` 18 MB、最长路径 372 字符、`prunable=0` 使 `prune` 永久无效 | P1 | ⏭ R3（清理属破坏性操作，需授权） |
| R1P-10 | 门禁分区串行（`max_concurrency: 1`），1760.8 s；补齐覆盖后预计 2500 s+ | 20 核机器只跑 1 个分区；门禁超过 40 分钟后没人愿意跑 | P1 | ⏭ R3（约束转交 arch，见 §4） |
| R1P-11 | 文档把一次性通过写成可复核证据（26 项 / 日志已不存在） | 交接与复盘依据不可验证；数字漂移无人发现 | P2 | ⏭ R3 |
| R1P-12 | JSpace 台账跨会话串写：一个 `20261113-181830-07A2.md` 同时含两个会话的 ✓01–✓15 | 并行会话互相污染"已验证"列表，可导致漏检（自改进循环依赖台账） | P1 | ⏭ R3（需会话身份语义变更） |
| R1P-13 | "覆盖"只统计"测试文件是否被执行"，代码行覆盖率从未测 | 87.2%→100% 修好也不代表代码被覆盖 | P2 | ⏭ R4 |
| R1P-14 | 真实模型基准/evals 空白（`bench/tasks` 1 个任务、`evals/compaction_recall` 只有 README） | 无质量/成本数据，压缩与召回策略无法判优劣 | P2 | ⏭ 待授权（计费调用） |
| R1P-15 | 13 skip + 14 excluded（分布式/浏览器/真实缓存三条路径零覆盖） | 跨节点求值、Playwright、provider 缓存命中全在门禁外 | P2 | ⏭ R4 |

## 3. 逐条：现象、证据、验收标准

> 每条验收标准都给"可判定的命令 + 期望输出"，并尽量带**反向验证**（故意把实现/阈值改坏，测试必须变红），防止修出"恒真测试"。

### R1P-01 · 门禁漏跑 32/250 文件（P0，入选）

**现象**：`lib/mix/tasks/newbee/test_fast.ex` 的分区表只列了 8 个目录 + root；`test/newbee/colony`（19 文件）、`plugins`（4）、`learning`（4）、`codec`/`evals`/`host`/`terminal`/`truncate`（各 1）不在其中。

**证据**（本会话独立计算，与基线一致）：

```text
all_test_files = 250
covered_by_partitions = 218   (87.2%)
uncovered = 32 files / 281 static `test "` declarations   → pm-evidence/uncovered-files.txt
```

漏跑的 32 个文件单独跑：**281 全通过**（R1 基线 849.6 s）——所以它不会被"红"暴露，只会被"没人跑"掩盖。这正是不足：**最活跃的 colony 子系统（177 passed / 224.3 s）不在门禁内**。

**影响**：任何 colony / plugins / learning 回归都能直接进 main；README 的"完整入口 `mix test.all`"是错的宣称（`mix.exs:43`：`test.all = test.fast + acceptance`）。

**验收标准**（全部可判定）：

1. 新增 `test/newbee/test_partition_coverage_test.exs`（root 分区自带 `test/newbee/*_test.exs`，能覆盖自身；需先让 `TestFast` 暴露 `partitions/1` 或 `@partition_specs` 为公开函数以便元测试读取），断言：
   `分区表展开后的文件集 == Path.wildcard("test/**/*_test.exs")`。
   - **改前必须红**：在 5ac87ba 上该断言给出 32 个缺失文件（附清单）。
   - **改后必须绿**：`MIX_ENV=test mix test --no-compile --seed 1 test/newbee/test_partition_coverage_test.exs` → 1 passed，exit=0。
2. `mix newbee.test_fast` 启动输出的各分区文件数之和 = **250**（脚本可断言，不接受人工目视）。
3. 反向验证：从分区表临时删掉 `test/newbee/colony` 一行 → 上述 meta 测试必须红。
4. 墙钟约束：`mix newbee.test_fast` 墙钟 ≤ **2100 s**（R1 基线 1760.8 s；全量用例 1477+281=1758 条）。

**不在本条范围**：把门禁压到 1200 s 以内（并行化）= R1P-10。

### R1P-02 · 前端 JS 套件全红且不在门禁（P0，入选）

**现象**：`node --test test/web/conversation-work.test.js` → **32 tests / 0 pass**。

**证据**（`pm-evidence/js_suite.log`）：

- 直接失败 1 条：源码契约"无 innerHTML"——`priv/web/conversation-work.js` 有 **6 处** `innerHTML`：**1784、1805、1820、1835、1841、1847** 行（都是 #224/#228 的"交给团队"按钮与模板菜单）。
- 连锁失败 31 条：崩在 `conversation-work.js:852` 的 `wrap.classList.toggle(...)`，而测试替身 `test/web/conversation_work_dom.js:34` 的 `classList` 只有 `add/remove/contains`，**没有 `toggle`**（`grep -c toggle` = 0）。
- 该套件不在 `mix test.fast` / `mix test.all` / `test.acceptance` 任何入口（`mix.exs` 无 node 调用）。

**影响**：前端（含后台工作卡、团队入口这类新增交互）回归无人看守；契约"展示只用 textContent 构建"已被 6 处绕过，而绕过的正是最新功能——说明这条约定正在被"新功能赶工"侵蚀。

**已知在途冲突（集成边界，必须写清）**：主仓库工作区有另一会话的 7 个在途文件，其中 `test/web/conversation-work.test.js`、`test/web/conversation_work_dom.js`、`test/web/conversation-work.md` 正在修这个洞（主仓库实测：**44 tests / 41 pass / 3 fail**），但 **`priv/web/conversation-work.js` 未被其修改**（源码契约仍红）。所以：替身与用例的修法**不要重写**，等其合入或以主干为基线独占改动；6 处 innerHTML 必须由本循环解决。

**验收标准**：

1. `node --test test/web/conversation-work.test.js` → **exit=0，0 失败**，用例数 ≥32（若并入在途版本则 ≥44）。
2. `grep -c 'innerHTML' priv/web/conversation-work.js` = **0**（不使用白名单例外；若确需 SVG，用 `createElementNS` 逐点构建，与文件中已有的 SVG 构造写法一致）。
3. DOM 替身实现 `classList.toggle(name, force)`（与真实 DOM 语义一致），并有 1 条用例直接断言 `toggle` 生效（`add`/`force=false` 两态）。
4. **进得了门禁**：`mix newbee.gate`（见 R1P-09）必须执行该套件；失败即非 0 退出。
5. 反向验证：把任意一处 `textContent` 改回 `innerHTML` → 契约用例必须红；删掉替身的 `toggle` → ≥1 条用例必须红。

### R1P-03 · 4 处测试编译警告让全通过分区判红（P0，入选）

**现象**：`--warnings-as-errors` 下，用例全通过仍 abort。

| 文件:行 | 警告 | 复现结果 |
|---|---|---|
| `test/newbee/web/colony_team_api_test.exs:25` | variable "cid" is unused（`test "...", %{cid: cid} do`） | web 两文件：**10 passed，exit=1** |
| `test/newbee/web/static_asset_allowlist_test.exs:12` | unused import Plug.Conn | 同上 |
| `test/newbee/colony/task_test.exs:10` | `defp task(attrs \\ %{})` 默认值未使用 | colony 两文件：**29 passed，exit=1** |
| `test/newbee/colony/engine_test.exs:4` | unused alias Task | 同上 |

证据：`pm-evidence/d2_test_warnings.log`、`pm-evidence/d2b_flaky.log`（均含 `ERROR! Test suite aborted after successful execution due to warnings`）。

**影响**：违反 AGENTS.md「test/ 不允许任何编译警告」；且**只要这 4 处存在，web 与 colony 两个分区永远是红**——修绿其它缺陷也拿不到 exit=0。这是"先把噪声关掉"的前置项。

**验收标准**：

1. `MIX_ENV=test mix test --no-compile --warnings-as-errors --seed 1 test/newbee/web/colony_team_api_test.exs test/newbee/web/static_asset_allowlist_test.exs` → **exit=0**（当前 exit=1）。
2. `MIX_ENV=test mix test --no-compile --warnings-as-errors --seed 1 test/newbee/colony/task_test.exs test/newbee/colony/engine_test.exs` → **exit=0**（当前 exit=1）。
3. 全仓 `MIX_ENV=test mix test --no-compile --warnings-as-errors --seed 1` 输出中 `warning:` 计数 = **0**，且不出现 `aborted ... due to warnings`。
4. 反向验证：随便加一个 `x = 1` 未使用变量 → 上述命令必须 exit≠0。

### R1P-04 · 34 个文件未格式化（P1，入选）

**现象**：`mix format --check-formatted` → exit=1，**34** 个文件（`pm-evidence/unformatted-files.txt`），包括 `lib/newbee/codec.ex`、`lib/newbee/commands.ex`、`lib/newbee/goal.ex`、`lib/newbee/tools/edit.ex`、`lib/newbee/collaboration/cross_host/*`、`test/newbee/collaboration/cross_host/*` 等。

**影响**：格式门 G2 常红 → 变成"反正红"的背景噪声；diff 噪声让 review 变慢。

**验收标准**：

1. `mix format --check-formatted` → **exit=0**，违规文件数 0（M10：34 → 0）。
2. **语义零改动**：格式化后 `git diff -w --stat` 对 `lib/` 无剩余行（即除空白/换行外无差异）；`mix compile --warnings-as-errors` 与 `MIX_ENV=test mix compile --warnings-as-errors` 仍 exit=0。
3. 不把 `deps/` 或 vendor 文件拉进格式化范围（`.formatter.exs` 不变，除非给出理由）。

### R1P-05 · 能力索引 1941 B > 1800 B（P1，入选）

**现象**：`byte_size(Newbee.Plugins.prompt_section())` = **1941 B**，契约上限 1800（`test/newbee/tools/tool_documentation_contract_test.exs:8`，2/3 passed，exit=2）。

**证据**（`pm-evidence/m1_budget.exs`）：总 **1941 B = 头部 66 B + 20 条条目 1856 B + 19 个换行 19 B**；条目均值 92.8 B，最长 **Team 143 B**：

```text
- Newbee.Tools.Team: Colony team templates: main proposes a team, a human approves, roles + operating loop become a reusable template; start 
```

**超预算 141 B**，且摘要被 `String.slice(0, 120)` 截在半个词（`start `），说明"预算检查"与"截断策略"两处都失效。

**影响**：每轮对话固定多 141 B；更重要的是**预算防线现在是红的**，下一个人加一行摘要不会有人拦。长期看这会把常驻提示变成垃圾桶。

**验收标准**：

1. `byte_size(Newbee.Plugins.prompt_section()) <= 1800`（建议留余量：≤1750），且 **条目数仍为 20**（不允许靠删工具达标；工具清单是产品能力面）。
2. `MIX_ENV=test mix test --no-compile --seed 1 test/newbee/tools/tool_documentation_contract_test.exs` → **3/3 passed，exit=0**。
3. 不再出现半词截断：任何一条摘要被截断时必须在词边界结束（可用"截断处前一个字符不为空格且后一个字符不为字母"的断言，或改成首句取整句）。
4. `Newbee.Tools.Team` 的 `@moduledoc` 首句仍完整表达"团队模板 + 人工批准"（不允许为省字节删掉语义），并有 `## Runnable example` 供文档契约测试通过。
5. 反向验证：临时把某条摘要加长 200 B → 契约测试必须红。

### R1P-06 · archive 回放断言测的是废弃契约，真实不变量无守护（P0，入选）

**现象**：`test/newbee/archive_test.exs:360`（"二次压缩回放含旧摘要的 envelope（旧摘要前缀）"）失败：

```elixir
assert Enum.drop(second, -1) == Newbee.LLM.Client.sanitize_messages(env2_msgs)
```

**根因（本会话实测，探针 `pm-evidence/d3_probe2.exs`）**：

```text
env_messages 含 created_at        = true          # Archive.view 的每条消息都带 created_at
摘要请求实际前缀 == stream_chat 的 wire 投影 = true
摘要请求实际前缀 == 仅 sanitize(env_msgs)     = false   # ← 测试断言的正是这一句
前缀与 wire 投影逐条 diff 数              = 0
```

即：#215（2026-10-20）给 chat/completions 加了 `project_chat_messages/3`，会把 `created_at` 等 UI 私有字段摘掉；`Archive.llm_digest_replay/3` 走的是 `Client.complete/3`，同样经过该投影并 `sanitize_messages`。所以"发出去的前缀"= `project(sanitize(env_msg))`，而**测试仍拿 `sanitize(env_msg)` 比较**——差的就是 `created_at`。

**这不是产品 bug**：我把三个对象摆在一起比对了（`d3_probe.exs`：`sent_prefix==routed` → true，`sent==routed` 12 条全等，`routed_has_created_at` false）。prefix cache 的真实前提"摘要请求是路由请求的严格前缀"**当前成立**。

**真正的不足**：这条 P0 级不变量**没有任何测试按正确对象断言**。
- 现在：测试红（假警报），会诱导后来者"把断言放松/删掉"。
- 删掉后：谁把 `llm_digest_replay` 改回 `prefix ++ instruction` 直发（不投影）→ 前缀不再逐字节相等 → prefix cache 静默失效（钱与延迟），**没有任何测试会红**。

**影响**：长会话的缓存命中与成本；假警报还会消耗每一轮的排查预算（R1 基线就把它当"确定性缺陷 D3"记了一笔）。

**验收标准**：

1. 该用例改为断言真实不变量，并**保留可读意图**：
   `摘要请求 == 路由请求 wire 投影 ++ [压缩指令]`，其中路由投影 = `Client.project_chat_messages(Client.sanitize_messages(env["messages"]), client)`。
   `MIX_ENV=test mix test --no-compile --seed 1 test/newbee/archive_test.exs` → **25/25 passed, exit=0**。
2. **新增一条守护用例**（比修红更重要）：对同一 session 分别取"`Archive` 摘要路径实际发出的前缀"与"`Agent.Loop` 路由路径实际发出的消息"，断言**逐字节相等**（本会话已用探针验证可通过）。该用例必须能在"把 digest 路径改成不投影"时变红——反向验证写入用例注释并在 QA 报告中执行一次。
3. 同类用例一并核对：`archive_test.exs:293`（"命中路径：摘要请求 == envelope 消息逐字回放"）用的是 `env_msgs` 原样比较，同样绕过了投影 → 必须一起改成同一套不变量（否则"逐字回放"仍是错的）。
4. `RequestEnvelope` 的文档与 `llm_digest_replay/3` 注释同步：明确"快照记的是路由消息（含 created_at），真正发出的前缀是 wire 投影；两者关系由测试守护"。

### R1P-07 · 4 类抖动断言（P0，入选第 2 批；本会话低负载未复现，按 R1 门禁记录受理）

**现象与证据**（本会话实测 + R1 基线）：

| 用例 | 断言 | 本会话 | 判定 |
|---|---|---|---|
| `session_new_test.exs:112` | `assert dt < 500`（毫秒墙钟） | 单独跑 3 passed | 违反"不断言紧的墙钟时间" |
| `coordinator_reevaluate_test.exs:58` | `wait_for_status` 200×20 ms = **4 s** | 单独跑 3/3 通过 | 门禁里在负载下耗尽 |
| `session_index_perf_test.exs:82` | `assert list_us < decode_us` | **10263 vs 4060**（失败）；R1 基线 9506–17356 vs 3422–6371 | 见下 |
| `session_index_perf_test.exs:30` | `assert micros < 500_000`（20 次 list_page） | 未单测复现 | 同源墙钟 |

`list_us < decode_us` 的**结构性错误**（我做了独立测量 `pm-evidence/list_perf.exs`）：

```text
200 个会话文件在盘：list_page(50) 冷 = 42400 µs，热 = 4400 µs，page=200 冷 = 59700 µs
单个 301 行文件 decode = 648 µs；全部 200 个文件 decode = 575779 µs
```

断言左边是"扫当前机器上**所有**会话的页脚"，右边是"固定 payload 的 decode"——两边量纲完全不同，**测的是"这台机器上有多少会话"**，不是产品不变量。会话越多越必红（R1 记录：整组跑偶尔通过=当时会话少）。

**影响**：G8（三种子失败集合一致）不达标已定位到这类；门禁红/绿取决于机器闲忙，等于把"红=真缺陷"这条最重要的信号毁掉。

**本会话的诚实说明**：这 4 条在 `loadavg 2.2`（20 核）下单独跑**全部通过**（`pm-evidence/d2b_flaky.log`：coordinator 3/3、session_new 通过），只有 `list_us<decode_us` **必红**（10263 vs 4060，结构性错误，与负载无关）。所以本条的优先级依据是"结构性不可判定 + R1 门禁下的 6 次实测失败"，不是"本会话又红了 6 次"。

**验收标准**：

1. `dt < 500` → 改为状态不变量（"请求返回时重启已在进行"：如新 pid 已存在/`Session.current_id` 已切换），断言中**不出现毫秒阈值**。
2. 等待预算 → 落真实状态且给足（≥120 s，与 `acceptance_test.exs` 同量级），超时信息必须含最后观察到的状态。
3. `list_us < decode_us` → 改为**两个可解释的量**：a) `transcript_scan_count()` 不增长（已有，保留）；b) 冷扫描成本相对会话页数**有上界**（如 `list_us <= 200_000` 且与 N=10/N=200 的比值 < 3），并把"会话数"作为显式自变量写进用例。
4. `micros < 500_000` → 改成"热路径不重扫（scan_count 不变）+ 单次 ≤ 25 ms（20 次 ≤ 500 ms 由该阈值推导）"，并在注释里写明这是**护栏不是基准**。
5. **验收方法**：人为制造负载（如并发起 6 个 `mix test` 或 `stress-ng --cpu 16`）下连续跑 **5 次全部通过**；再把这 4 条阈值收紧 50% → 必须至少红 1 次（证明不是恒真）。
6. 若某项无法在 R2 内完成，**允许顺延 R3**，但必须把该用例从"门禁红"降级为 `@tag :flaky_review` 并在报告中列出（不允许留着随机红）。

### R1P-08 · 测试 worktree 注册只增不减（P1，顺延 R3）

**现象**：`git worktree list --porcelain` = **223** 条（R1 基线 204，本会话跑测试后 205→223），`prunable` = **0**，`.git/worktrees` **18 MB**，最长路径 **372** 字符，含"工作树里再套工作树"。

**本会话增量证据**（同一 commit，同一工作树，逐次实测）：

| 跑的用例 | 用例数 | 注册增量 |
|---|---|---|
| `colony/workspace_review_test.exs` | 23 | **+0** |
| `colony/workflow_test.exs` | 17 | **+0** |
| `colony/conversation_lifecycle_test.exs`（连跑两次） | 7 | **+0 / +0** |
| `colony/conversation_decomposition_test.exs`（首次） | 8 | **+7** |
| 同上（再跑一次） | 8 | **+0** |
| `colony`（19 文件全量，首次） | 177 | **+18** |

**机制已查明（这是本条的关键）**：泄漏不是"每次跑都加"，而是**每个不同的工作区路径只注册一次、注册后永不移除**。
- 每个 colony 用例把工作区建在 `tmp/<Module>/<test-name+hash>/.newbee/workspaces/colony-<task_id>`；
  用例结束**不删目录** → `prunable=0` → `test_helper.exs` 的 `git worktree prune`（只清"目录已消失"的注册）**永久无效**。
- 重跑同一用例走同一路径 → 注册已存在 → 增量为 0（所以"跑一次没涨"不能证明没泄漏）。
- 增长来自三处：新用例/新 test 名（hash 变）、新的会话工作树（路径前缀变）、以及**工作树里再套工作树**（R1 基线：84 条嵌套，最长 372 字符）。
- 实测残留：`.worktrees/pm-r1/tmp/Newbee.Colony.ConversationDecompositionTest/` 下 7 个 test 目录，每个含 1 个 `colony-*` 工作区目录，全部仍在盘上。

**影响**：`.git` 元数据线性膨胀，路径逼近系统上限，`git worktree list` 被 200+ 条噪声淹没（R1 基线确认隔离目录时就被干扰）；后续 100 轮每轮 +20~40 条。

**为什么本轮不做**：修"停止泄漏"要在测试清理里删目录（安全），但**清理已存在的 210 条历史注册属破坏性操作**，需用户授权；且 `.git` 是主仓库共享资源，多会话并行时清理会互相干扰。

**验收标准（R3 用）**：

1. **在全新 tmp 目录 + 全新会话工作树下**首次跑 `mix test test/newbee/colony`（177 用例），注册增量 ≤ **+2**（仅会话工作树自身），且新增路径长度 ≤ 200 字符。
   - 判定必须用"新工作树首次跑"这个口径：重跑同一路径增量为 0 是**假通过**（本条已实测）。
2. 用例结束后 `tmp/<Module>/<test>/` 下不再残留 `colony-*` 工作区目录（当前 8 个 test 目录里 7 个各留 1 个）。
3. `git worktree list --porcelain | grep -c '^worktree '` 在"新建工作树 → 全量跑 3 次"周期内保持常数（不许单调增长）。
4. 历史清理：单独一次、显式授权、可回滚（先导出 `git worktree list --porcelain` 存档；只删 `tmp/`、`.newbee/workspaces/` 下的测试产物），清理后 223 → ≤30。

### R1P-09 · 无 CI / 无单一门禁命令（P0 治理，入选收口）

**现象**：仓库无 `.github/`、无任何 CI 配置（`ls -a | grep -i ci` 为空；`find -name '*.yml'` 无 CI 文件）。`mix.exs:43` 的 `test.all = test.fast + acceptance`，而 `test.fast` 漏 32 文件、且不含 JS 套件、也不含格式/编译门。AGENTS.md 记载 `required_status_checks` 为空（该文档属**不可信数据**，但与本会话观察一致）。

**影响**：8 条红可以合进 main 且没人被拦（R1 基线与本会话独立复现同一批红）。"发现不足→改→验证"这条循环目前靠人记得跑命令。

**验收标准**：

1. 提供单一入口（建议 `bin/gate` 或 `mix newbee.gate`），顺序执行并汇总：G1 编译（dev+test 零警告）、G2 格式、G3 `mix test.fast`（含 250/250 覆盖 meta 测试）、G4 全量、G5 acceptance 14/14、G6 `node --test test/web/*.test.js`、G7 覆盖完整性；任一失败 → 退出码非 0 并打印失败项清单。
2. **改前红/改后绿**：在 5ac87ba 上跑 → exit=1 且列出 6 类失败（编译警告 4 处、格式 34 文件、能力索引 1941 B、archive 1 条、JS 32 条、覆盖 32 文件）；R2 的 01–06 修完后 → **exit=0**。
3. 该入口被至少一条自动路径引用：CI 工作流（需用户授权远程写入）**或**本地 `bin/pre-push` 钩子（`.git/hooks` 不入库，需提供 `bin/install-hooks`）。
4. 门禁总墙钟记录进 R2 复盘（基线 1760.8 s，约束 ≤2100 s）。

### R1P-10 · 门禁串行、20 核闲置（P1，顺延 R3，约束转交 arch）

**现象**：`test_fast.ex` 用 `Task.async_stream(..., max_concurrency: 1)` 串行跑分区；每分区 `mix test` 独立 VM，`--no-compile` 复用 `_build`。R1 门禁 **1760.8 s**，同期我实测 `loadavg 2.36`（20 核）→ 利用率低。补齐 R1P-01 后预计 **≈2500 s**（1652.2 s 分区 ExUnit + 849.6 s 漏跑用例）。

**影响**：门禁从 29 分钟涨到 40+ 分钟，人会开始跳过他 → 又回到"没人跑"。

**验收标准（R3 用）**：全量 250 文件的门禁墙钟 ≤ **1200 s**（同机同负载），且失败集合与串行跑一致；单分区 ≥5 分钟的不均衡问题需给出分区耗时表（现在没有：D8）。

### R1P-11 · 文档把一次性通过写成可复核证据（P2，顺延 R3）

**现象**：`docs/conversation-work-operations.md:115`：`| 前端行为 | 26 项通过 | node --test ...；.newbee-tmp/conversation-final-node.log |`。实测：`.newbee-tmp/conversation-final-node.log` **不存在**（被 gitignore）；套件用例数是 **32**（主干）/ **44**（主仓库在途）。同文件 135 行也写"前端 26 项通过"。

**影响**：交接/复盘引用"可复核证据"却无法复核；数字随代码漂移无人更新，读者会把过期结论当真。

**验收标准（R3 用）**：文档中的每个数字都附"可重跑命令"而非"日志路径"；`grep -n '项通过' docs/*.md` 的条目要么删除，要么换成命令 + 当轮实测输出；新增一条 `docs` 校验（可选）在门禁里检查"引用的日志路径存在"（或明确标注为历史快照）。

### R1P-12 · JSpace 台账跨会话串写（P1，顺延 R3）

**现象**：`~/.newbee/jspace/20261113-181830-07A2.md`（单一台账文件）同时包含两个会话的验证条：第 15 行 `✓12 ... .worktrees/baseline-r1 ...`（main 会话）与第 17 行 `✓14 ... .worktrees/r1-baseline-coord ...`（另一会话，数字不同：108.0 s / 1744.6 s）。

**根因线索**：`Newbee.Tools.JSpace.ledger_path/1` 用 `session || Session.current_id() || "default"`；`Session.current_id/0` 是 `:persistent_term` 全局单值（`session.ex:164`），两个并发 DEE 任务落到同一个 Web 会话 id 时共写一文件。

**影响**：并行会话互相污染"已验证"列表 → 一方会误以为某项已验证（或反之），对"100 轮自我改进"这种长跑是**直接的正确性风险**；也会让用户看到不属于本次任务的记录。

**验收标准（R3 用）**：并发 2 个任务（不同 task_id）各自 `note`/`ship` 后，`~/.newbee/jspace` 下出现 **2 个互不包含**对方内容的台账（或同一文件按 task 分节且读取时隔离）；`JSpace.read/1` 在会话 A 中不含会话 B 的条目；有自动化测试覆盖（现在 `jspacetest_test.exs` 只测单会话）。

### R1P-13 · "覆盖"只到文件级（P2，R4）

**现象**：G7 的 87.2%→100% 指"测试文件是否被执行"；从未跑过 `--cover`。

**验收标准（R4 用）**：给出 `mix test --cover` 的模块行覆盖率基线（按分区），并对 `lib/newbee/colony/*`、`lib/newbee/llm/client.ex`、`lib/newbee/web/*` 列出 <60% 的模块清单；后续每轮只允许不降。

### R1P-14 · 真实模型基准与 evals 空白（P2，待授权）

**现象**：`bench/tasks/` 只有 `add_function_doc.json`；`evals/compaction_recall/` 只有 README；`mix newbee.bench` 需真实计费调用。

**影响**：压缩摘要、档案召回、工具选择这些**只有模型能判**的质量项当前没有任何数字，优化等于盲改。

**需要决策**：是否允许本轮/近轮产生真实模型调用（成本、用哪个 provider）。→ 见 §5 提问项。

### R1P-15 · 13 skip + 14 excluded 的三条路径（P2，R4）

**现象**：`test_helper.exs:9` `ExUnit.start(exclude: [:node])`，14 个 `@tag :node`；另 13 条 skip 依赖 `NEWBEE_CACHE_E2E` / `NEWBEE_BROWSER_INTEGRATION` / `NEWBEE_CAPTCHA_LIVE`。

**影响**：跨节点求值器、Playwright 浏览器、真实 provider 缓存命中——都属"出错代价高但没人跑"的路径。

**验收标准（R4 用）**：至少 `:node` 组在独立入口（`mix test.node`）可一键跑通并进 R4 门禁；skip 类给出"如何开启 + 一次真实通过日志"的文档，或明确降级为"本版不支持"。

## 4. 本轮入选范围（交给 arch）

**主题：把门禁修绿、修全，让"红=真缺陷"重新成立。**

| 批 | 条目 | 依赖 | 预估 |
|---|---|---|---|
| A（必须） | R1P-03 警告 4 处 → R1P-04 格式 34 文件 → R1P-05 能力索引 → R1P-06 archive 不变量 → R1P-01 分区补齐 + meta 测试 → R1P-02 JS 套件（等/并入在途） | 03/04 先行（噪声）；01 与 02 独立可并行 | 03/04/05 小；01 中（分区表 + meta + 墙钟）；02 中（6 处 innerHTML + 替身 toggle） |
| B（可顺延 R3） | R1P-07 抖动 4 条 | 需 A 的 archive/session 测试稳定后 | 中 |
| 收口 | R1P-09 单一门禁命令，改前红/改后绿 | A（+B 若在轮内） | 小 |

**排序理由**：先关噪声（03/04），再修"唯一一条测错对象的 P0 不变量"（06，成本极低但风险最高），再补覆盖（01）与前端（02），最后做门禁收口（09）。R1P-05 独立、改动面最小，可任意插队。

**交给 arch 的硬约束**：
1. 只允许改：`lib/mix/tasks/newbee/test_fast.ex`、`lib/newbee/plugins.ex`（或 `tools/team.ex` 首句）、`lib/newbee/archive.ex` 注释/断言相关测试、`test/newbee/{archive,test_partition_coverage}*`、`test/web/*`、`priv/web/conversation-work.js`、4 个警告点、34 个格式文件、门禁脚本。**不改** `lib/newbee/llm/client.ex` 的投影语义（那是 #215 的正确修复）。
2. 全量门禁墙钟 ≤2100 s；若 R1P-01 让它超，必须给出并行化方案（R1P-10）而不是砍覆盖。
3. 测试改动必须带"改前失败、改后通过"的真实输出（本报告 §3 的命令即基线命令）。
4. 不触碰主仓库工作区 7 个在途文件；JS 部分与在途会话先在方案里声明边界（谁改替身、谁改源码），避免重复修同一行。

## 5. 未覆盖范围与需决策项

**本会话未覆盖（如实声明）**：
1. 未跑官方 `mix newbee.test_fast` 全量（R1 测 29 分钟）与全量单进程套件。本会话实际跑了：`test/newbee/colony` 全目录（177 passed / 224.3 s）、`archive_test.exs`（24/25）、`session_index_perf_test.exs`（2/3）、web 两文件（10 passed）、colony 两文件（29 passed）、`node --test`（32/0）、格式检查、能力索引探针、覆盖率差集、worktree 增量、3 个自写前缀/性能探针。**8 条独立复现（D1/D2/D3/D4/D5/D6/D9/D10）由这些定向运行支撑；D7/D8 未在本会话复现，依据来自 R1 基线。**
2. 未做浏览器端到端/Playwright（`NEWBEE_BROWSER_INTEGRATION` 未开）；前端结论只来自 node 单测与静态走查。
3. 未测代码行覆盖率（R1P-13）。
4. 未验证跨主机部署、打包、TUI 真机交互。
5. 未改动任何产品代码，未 commit/push/merge；`docs/self-improvement/` 与 `pm-evidence/` 为未跟踪文件。
6. 本会话自身留下的痕迹：跑测试新增 **18** 条 worktree 注册（223 条，未清理，见 R1P-08）；`/tmp` 下有探针临时目录（已自删）。
7. 基线报告 §7.8 提到的"DEE 跨 cell 绑定被 JSON 信封包裹"**本会话未复现**（`binding()` 正常保留了 `tmpvar` 等变量）→ 该条记为"未复现，需另立探针"，不进入产品缺陷清单。

**需要用户决策（阻塞下一阶段节奏，不是阻塞 arch 开工）**：
1. R1P-02 的 JS 修复与主仓库在途会话（7 个脏文件）存在**同一文件碰撞面**：是否等其合入再动，还是由本循环以主干为基线独占（会在合并时冲突）？
2. R1P-08 的**历史清理**（223 → ≤30）属破坏性且触及共享 `.git`，需授权；否则只做"停止泄漏"。
3. R1P-14 真实模型基准是否允许产生计费调用（哪个 provider/预算）。
4. CI：是否授权写 `.github/workflows` 并 push（否则门禁只能落本地 `bin/gate` + pre-push）。

## 6. 一句话交接给 arch

先把 4 处编译警告和 34 个格式文件关掉，然后把 `archive_test.exs` 的断言改成"摘要前缀 == 路由 wire 投影"并补一条真正守护前缀一致性的用例（这是本轮唯一"测试测错对象"的 P0），接着把 32 个漏跑文件并进分区表并用 meta 测试锁死 250/250，最后让 JS 套件 32/32 全绿并进得了门禁；做完用 `bin/gate` 证明"改前 exit=1、改后 exit=0"。
