# 第 1 轮 · 改进方案与风险清单（arch）

- 轮次：R1（自我改进循环第 1 轮，计划 ≥100 轮）
- 角色：技术方案负责人（arch）
- 时间：2026-11-16 10:20–12:10 (+08:00)
- 被测版本：`5ac87bad145b0801e7d8c5145895e87ddd4ac3ff`（`origin/main`，#228）
- 工作位置：**本交付的全部验证都在 `.worktrees/arch-r1-spike`**（detached 5ac87ba，deps 软链主仓库，独占写入）。
- ⚠️ **并发冲突声明（R-8，收尾时发现）**：`.worktrees/arch-r1` 原为本会话证据复算树，收尾复核发现**另一 arch 工作者实例正在同一目录写入**（其 `docs/self-improvement/round-01-plan.md` 45.6 KB、`@summary_bytes 64` 版本补丁、12:01–12:11 持续更新）。本会话**未改动该树中对方的任何文件**；本会话早期在该树做过 `mix format`（34 文件，AST 等价）并启动过一次改前门禁重跑，发现冲突后已**主动终止自己的门禁进程**（日志存 `arch-evidence/gate-pre2-aborted.log`），该树后续状态归对方工作者。两份方案独立成文，结论高度一致（分区表 9 分区、字节预算+词边界、archive wire 投影断言、JS DOM 构建），**main 需裁决以哪份为准或合并**；本交付以 spike 树为唯一权威现场。
- 上游输入：`round-01-baseline.md`（main）、`round-01-problems.md`（pm，sha256 `78b39935…a3ff63`）
- 交付物：本方案 + **已在 spike 工作树真实跑通的最小改动补丁** `arch-evidence/spike.patch`（sha256 `6ecf7731c630665aedf1bf87c54ad3533aa09eac65c0cba76f0707b33aad8381`，53 文件 +722/−197，另含 1 个新文件）
- 提交状态：**未 commit / 未 push / 未合并**；主仓库 7 个在途文件全程未触碰（收尾 `git status` 复核一致）
- ✅ **决策记录 D-1（2026-11-16 13:40，main/用户）**：`A_relax_2500` —— **门禁墙钟上限由 2100 s 放宽到 2500 s**（R1P-01 验收标准 4 与 R1P-09 约束同步更新）。依据：漏跑 281 用例单 VM 实测 441.7 s（`missing32.log`），串行补齐后预计 ≈2200 s，落在 2500 s 内；R1P-10 并行化仍排 R3（目标 ≤1200 s 不变），但不再是 R2 的阻断项。本方案 §1 R1P-01、§2 R-3、§3 聚合验收已按此更新；改后全量门禁正在 spike 树实测（见 §4.2 与 `arch-evidence/gate-post*.{log,exit}`）。

## 0. 结论速览

pm 入选的 8 条（R1P-01～06 + 07 批 B + 09 收口）全部给出最小可行方案；其中 **批 A 六条 + JS 守护用例已在 spike 工作树实现并逐条验证通过**（不是纸面方案）。每条都附：改动点、影响面与兼容性、风险与回滚、需补测试点、真实验证输出。

| 条目 | 方案状态 | spike 验证结果 |
|---|---|---|
| R1P-03 编译警告 4 处 | ✅ 已实现 | 39 passed，exit=0（改前 exit=1） |
| R1P-04 格式 34 文件 | ✅ 已实现 | `mix format --check-formatted` exit=0；34 文件 AST 逐一等价 |
| R1P-05 能力索引 1941→1745 B | ✅ 已实现 | 契约 3/3 passed；条目仍 20；无半词截断 |
| R1P-06 archive 不变量 | ✅ 已实现 | 26/26 passed（改前 24/25）；反向破坏投影 → 恰好 2 条红 |
| R1P-01 分区补齐 + meta 测试 | ✅ 已实现 | 分区展开 250 文件（含 acceptance 由独立入口跑）；meta 2/2；删 colony 行 → meta 红 |
| R1P-02 JS 套件 | ✅ 已实现 | 35/35 passed（改前 32/0）；innerHTML=0；反向验证双向通过 |
| R1P-09 单一门禁 | 📐 方案（dev 落地） | 设计 + 验收命令已给出；依赖批 A 全绿 |
| R1P-07 抖动断言（批 B） | 📐 方案（可顺延 R3） | 根因复核 + 修法与测试点已给出 |

**新发现（pm 未记录，本轮实测）**：
1. **R1A-01**：JS 套件除 innerHTML/toggle 外还有 **4 类替身缺口**（`style.setProperty`、`stopPropagation`、类选择器 `querySelectorAll`、`Element.remove()`）与 **3 处过期断言**（分体按钮包裹层 `cw-team-split` 引入后 `parentNode.id` 不再是 `composer-actions`；SVG 子节点索引；按钮 title 文案）。只修 pm 列的两项无法全绿——spike 实测逐项暴露并修复。
2. **R1A-02**：`test_fast.ex` 的分区把**目录路径**直接传给 `mix test`，但 root 分区传**文件列表**；meta 测试要复核覆盖必须先把目录展开成文件（本方案已实现 `partitions/1` 公开 + `dir_files/2`）。
3. **R1A-03**：能力索引超预算的根因是 `String.slice(0, 120)` **按字符截断且无字节预算**；Team 首句 133 字符被截在 `start ` 半词。修法是"字节预算 + UTF-8 边界 + 词边界"三层，而不是简单调小 slice。
4. **R1A-04**：`documentation_contract_test.exs` 断言 `edit.ex` 源码含 `docs/edit-design.md`——缩短 Edit 首句时必须把该引用移到 moduledoc 正文，否则修 R1P-05 会打破另一条契约（spike 实测踩到并修复）。

## 1. 逐条方案

### R1P-03 · 4 处测试编译警告（P0，先行）

**最小改动**（4 行，全部在 test/）：
| 文件:行 | 改法 |
|---|---|
| `test/newbee/web/colony_team_api_test.exs:25` | `%{cid: cid}` → `%{}`（该用例不使用 cid） |
| `test/newbee/web/static_asset_allowlist_test.exs:12` | 删除 `import Plug.Conn`（未使用） |
| `test/newbee/colony/task_test.exs:10` | `defp task(attrs \\ %{})` → `defp task(attrs)`（所有调用都传参） |
| `test/newbee/colony/engine_test.exs:4` | `alias Newbee.Colony.{Engine, Store, Task}` → `{Engine, Store}` |

**影响面/兼容性**：纯测试文件，零产品行为变化；`task/1` 私有函数签名变化不影响外部。
**风险与回滚**：极低；`git checkout -- <4 files>` 即回滚。
**测试点**：pm 验收命令 1/2（两组文件 `--warnings-as-errors` exit=0）+ 反向（加一个未使用变量必须红）。
**spike 实测**：改前 web 组 10 passed→exit=1、colony 组 29 passed→exit=1（`arch-evidence/colonywarn.log`）；改后合并跑 **39 passed，exit=0**（`warnings-final.log`）。

### R1P-04 · 34 个文件未格式化（P1）

**最小改动**：`mix format`（`.formatter.exs` 不变，inputs 已覆盖 lib/test，不含 deps）。
**语义零改动的证明方法**（比 pm 的 `git diff -w` 更强——`-w` 不忽略换行重排，实测 34 文件仍有 diff）：
> 对每个文件取 `git show 5ac87ba:<f>` 与格式化后内容，`Code.string_to_quoted` 后 **prewalk 抹掉全部 meta（行号等）** 再比较 AST。spike 实测：**34/34 AST 等价，0 差异**。该探针可入库为 dev 的一次性验证脚本。

**影响面/兼容性**：lib 17 文件 + test 17 文件；AST 等价 ⇒ 行为不变。唯一可见影响是 `@moduledoc` 所在文件的行号漂移（错误栈行号变化），无接口变化。
**风险与回滚**：低；整批 `git checkout` 回滚。注意与在途会话的合并冲突面：34 文件中 `test/newbee/colony/decomposition_test.exs`、`test/newbee/llm/complete_error_test.exs` **不在**格式化清单里（已核对），与主仓库 7 个在途文件零交集。
**测试点**：`mix format --check-formatted` exit=0；dev/test 两环境 `--warnings-as-errors` 编译 exit=0；受格式化影响的测试目录回归。
**spike 实测**：FMT exit=0；cross_host 37 passed、human_brief/autonomy/commands/next_steps/codec/http_json 48 passed、goal_steering 4 passed、dee/rules+tool_contract 13 passed、chat/persona/shared_context 31 passed（`format-affected-*.log`）。

### R1P-05 · 能力索引 1941 B > 1800（P1）

**根因**：`Plugins.summary/1` 用 `String.slice(0, 120)`（字符数，非字节），无预算概念；Team 首句 133 字符 → 截半词且单条 143 B。
**最小改动**（两层，均已实现）：
1. `lib/newbee/plugins.ex`：新增 `@summary_bytes 66`；`truncate_summary/2` = UTF-8 合法边界裁剪（grapheme 累加）→ 回退到最后一个空格（词边界）。**不删任何工具**，条目仍 20。
2. 10 个工具的 `@moduledoc` **首句**改写为 ≤66 B 的完整句（Team/Browser/Hive/Edit/Git/Mcp/Media/JSpace/Run/Fs），语义保留：Team 首句仍表达"模板 + 人工批准 + 复用角色与流程"；`docs/edit-design.md` 引用移入 Edit moduledoc 正文（守住 R1A-04 的另一条契约）。

**预算数学**（spike 实测）：头部 65 B + 名称与缩进 512 B + 换行 19 B + 摘要合计 ≈1148 B = **1745 B ≤ 1750（pm 建议余量）**。
**影响面/兼容性**：`prompt_section/1` 输出变短——这是**常驻提示**，所有会话每轮少带 196 B；`tool://` 全文不变（首句改写不影响 `## Runnable example` 与函数文档契约）。`Plugins.builtins()` 的 `usage` 字段同步变短（同一 `summary/1`），环境投影/价签无结构变化。
**风险与回滚**：中低。风险=某条摘要语义被压缩后模型选错工具；缓解=首句保留"做什么+关键约束"，且 `tool://` 全文可查。回滚=还原 plugins.ex + 10 个 moduledoc 首句（单 commit 可逆）。
**测试点**：契约测试 3/3；条目数=20；四条必需子串仍在（Fs/Http/Run/Scaffold 的引导语）；**新增建议**：一条"任何摘要不得以半个词结尾"的守护断言（截断时末字符非空格且不含未闭合反引号）。
**反向验证（spike 实测）**：把 `@summary_bytes` 提到 400 且加长 Mcp 首句 → section=1866 B → 契约测试 **红**（2/3）；还原 → 1745 B 绿。单独加长首句但保留 66 B 上限 → 词边界截断生效（`…and keep`），仍绿——证明截断层独立兜底。

### R1P-06 · archive 回放断言测错对象（P0，本轮唯一"修它提升正确性"）

**根因复核**（与 pm 探针一致，spike 独立重跑）：`Client.complete/3` 走 `ImagePolicy.project_for → sanitize_messages → project_chat_messages`（#215 起摘 `created_at` 等私有字段）；旧断言只比 `sanitize_messages`，故恒红。**产品正确，测试错**。
**最小改动**（仅 `test/newbee/archive_test.exs`，+44 行）：
1. 原用例断言改为 `Enum.drop(second, -1) == routed_wire`，其中 `routed_wire = env2_msgs |> ImagePolicy.project_for |> sanitize_messages |> project_chat_messages`（与 `complete_chat` 同序）。
2. **新增守护用例**「前缀缓存不变量」：用真实 transcript 消息（带 `created_at`）记录 envelope → compact → 断言摘要前缀 == 路由 wire 投影，并带**反向哨兵**：`refute prefix == sanitize_only`、`created_at` 在 envelope 里存在而在前缀里不存在——防止用例退化成恒真。

**影响面/兼容性**：零产品代码改动；`client.ex` 投影语义未动（pm 硬边界遵守）。
**风险与回滚**：低。风险=投影管线未来加新层时守护用例需同步（这正是它的职责：管线漂移必须显式过测试）。回滚=还原单文件。
**测试点/反向验证（spike 实测）**：改后 **26/26 passed**（改前 24/25）。把 `complete_chat` 里的 `project_chat_messages` 删掉（模拟真实回归）→ **恰好这 2 条用例红**（`reverse-projection-removed.log`），其余 24 条不受影响——证明守护精准、无过度耦合。

### R1P-01 · 门禁漏跑 32/250 文件（P0）

**最小改动**（`lib/mix/tasks/newbee/test_fast.ex` +23 行；新文件 `test/newbee/test_partition_coverage_test.exs` 30 行）：
1. 分区表补 2 个分区、扩 2 个分区：`llm += codec`；`tools-tui += terminal, truncate`；新增 `colony`（19 文件）与 `plugins-learning`（plugins/learning/evals/host，10 文件）。
2. `partitions/1` 由 private 改 public（@doc 标注"元测试用"），目录分区经 `dir_files/2` 展开为**排序去重的相对文件列表**（root 分区原本就是文件列表，口径统一）。
3. meta 测试两条：覆盖差集为空（acceptance 显式豁免，仍走独立入口）+ 分区间无重复文件。**注意 `@root` 必须 `Path.expand("../..", __DIR__)`**（test/newbee 上两级）——spike 首版写成三级导致 wildcard 落空、测试恒绿，已修复并反向验证。

**影响面/兼容性**：`mix test` 接文件列表与接目录行为一致（ExUnit 按文件加载）；分区数 7→9，`test.fast` 输出多两行；`test.all` 别名不变。启动日志的文件数从"目录数"变为"真实文件数"（agent-dee 2→21 等），**这是修复不是回归**——原来打印的就是错的。
**风险与回滚**：中。风险①墙钟增加：漏跑 281 用例在 spike 单 VM 实测 **441.7 s**（基线 849.6 s 是多分区口径），串行门禁预计 1760→约 2200 s。**决策 D-1 已把上限放宽到 2500 s**，预计值落在限内（实测见 §4.2）；R1P-10 并行化仍排 R3（≤1200 s 目标不变），不再是 R2 阻断项，且任何情况下**不砍覆盖**。风险②新分区与旧分区共享 `/tmp/newbee-test-caps`（test_helper 每 VM 启动清空）——串行跑无冲突；并行化时必须先解决（R1P-10 的前置）。回滚=还原 test_fast.ex + 删 meta 测试文件。
**测试点/反向验证（spike 实测）**：分区展开合计 **250**（agent-dee 21 / environment 31 / llm 16 / tools-tui 27 / web 48 / collaboration 21 / colony 19 / plugins-learning 10 / root 57，acceptance 不在内）；meta 2/2 passed；**删掉 colony 行 → meta 红并列出 19 个缺失文件**；还原 → 绿。新分区独立跑 **104 passed exit=0**（plugins/learning/evals/host/codec/terminal/truncate）；32 个漏跑文件全量 **281 passed**（`missing32.log`，exit=1 仅因 R1P-03 的警告，修警告后该因素消失）。

### R1P-02 · 前端 JS 套件 32/0（P0）

**与在途会话的集成边界（必须先读）**：主仓库在途版本已把替身补到 44 tests/41 pass，其 `conversation_work_dom.js` 改动（toggle/style/storage/dispatch）与本方案**语义相同**。约定：
- **本循环只改 `priv/web/conversation-work.js`（6 处 innerHTML，在途未触碰）+ 新增 3 条守护用例**；
- 替身与既有用例的修复**以在途版本为准**：若在途先合入，dev 只需 cherry-pick 本方案的源码改动与 3 条新用例（spike 的替身改动丢弃）；若本循环先合入，在途会话 rebase 时其替身改动与本方案逐行兼容（toggle/style 实现一致）。
- spike 里替身改动只为**独立验证源码修复的正确性**，不代表要重复修同一行。

**最小改动（源码，6 处 + 1 个 helper）**：
| 行 | 改法 |
|---|---|
| 1784 caret SVG | `createElementNS` 逐属性构建（与同文件主按钮 SVG 写法一致） |
| 1805/1820/1841 菜单项 | 新增 `menuItem(icon, title, subtitle)` helper，`el()` + `append` 构建 |
| 1835/1847 清空列表 | `list.replaceChildren()`（真实 DOM 标准 API） |

**替身需补的 4 类缺口（spike 逐项实测暴露，pm 只列了 toggle）**：`classList.toggle(name, force)`（含返回最终态）、`style.setProperty/getPropertyValue/removeProperty`、事件 `stopPropagation`、`querySelectorAll` 支持 `.class`/`#id`/tag、`Element.remove()`、`Document.querySelectorAll`。**3 处过期断言**：`work-start.parentNode` 现在是 `cw-team-split` 包裹层（断言改为 `classList.contains` + 祖父节点 id）；SVG 是第 2 个子节点（第 1 个是空文本节点，按 nodeType 过滤）；title 文案已是「快速分工」。
**新增 3 条守护用例**：toggle 双语义直测；`cw-team-off` 随活跃工作上身/摘掉；**模板名含 `<img onerror>` 时必须原样作为文本、DOM 里不得出现 IMG 节点**（XSS 回归守护）。
**影响面/兼容性**：渲染结果 DOM 结构不变（类名/层级/文案一致），CSS 选择器 `.cw-team-menu-txt b/i` 不受影响；`replaceChildren` 需现代浏览器（项目已用 `append`/`classList` 同代 API，无新增兼容门槛）。
**风险与回滚**：中低。风险=菜单交互细节（焦点/事件冒泡）在真实浏览器与替身有差；缓解=守护用例覆盖点击开菜单全链路，R2 建议补一次 Playwright 手工核对（未覆盖，见 §4）。回滚=单文件还原。
**测试点/反向验证（spike 实测）**：**35/35 passed exit=0**（32 原有 + 3 新增）；`grep -c innerHTML` = **0**（连注释里的字面量都算违约——契约是源码级正则，helper 注释已避开该词）。反向①：把 quick 菜单项改回 innerHTML → 契约用例红（34/35）；反向②：删替身 toggle → **34 条红**（35 中仅 toggle 直测以外的全崩，证明 toggle 是真实依赖）。

### R1P-09 · 单一门禁命令（收口，dev 落地）

**方案**：新增 `mix newbee.gate`（或 `bin/gate`，二选一，推荐 mix task 与现有入口同构），顺序执行并聚合退出码：
1. `mix compile --warnings-as-errors`（dev）+ `MIX_ENV=test mix compile --warnings-as-errors`
2. `mix format --check-formatted`
3. `MIX_ENV=test mix newbee.test_fast`（批 A 后含 250 文件 + meta 测试）
4. `mix test.acceptance`
5. `node --test test/web/*.test.js`（**用通配符**，在途新增套件自动纳入；node 不存在时显式报错而非跳过）
任一失败 → 非 0 退出 + 打印失败项清单；全部通过 → exit=0。README 的 `test.all` 描述同步改为指向 gate（或把 `test.all` 别名直接升级为 gate 内容）。
**改前红/改后绿**：在 5ac87ba 上 gate 必须 exit=1 且列出 6 类失败（警告/格式/能力索引/archive/JS/覆盖）；批 A 合入后 exit=0。spike 已证明 6 类各自可绿，聚合命令本身由 dev 实现并跑一次全量留日志。
**自动路径引用**：CI 需用户授权远程写入（pm 决策项 4）；未授权前落 `bin/install-hooks` 安装 pre-push 调 gate（`.git/hooks` 不入库）。
**风险与回滚**：低（新增入口不动旧入口）；回滚=删 task/脚本。墙钟风险同 R-3。

### R1P-07 · 抖动断言（批 B，可顺延 R3）

复核确认 4 处（pm 清单一致）：`session_new_test.exs:112` `dt<500`、`session_index_perf_test.exs:30` `micros<500_000`、`:82` `list_us<decode_us`、以及 4 s 等待预算类。
**方案方向**（R3 实施，本轮不动）：
- `dt<500`：改为断言**异步契约本身**（`handle_cast` 返回时 `booting==true && kernel==nil` 已在断言里），墙钟上限放宽到 2000 ms 或改成"cast 返回早于 kernel 启动事件"的因果断言。
- `micros<500_000`：热缓存断言改为**相对基线**（同 VM 内先测冷路径再测热路径，热 < 冷/10），消除绝对墙钟。
- `list_us<decode_us`：**结构性错误**（spike 复测 list 10263 µs vs decode 4060 µs，单跑必红）——list_page 冷扫描本来就比纯 JSON decode 贵（含 IO+行数统计+标题提取）。改为断言 `transcript_scan_count` 增量 == 1（已有）+ 扫描不做全量 decode 的**行为断言**（如注入计数探针），删掉错误的性能比较。
- 4 s 等待：统一走 `assert_receive …, 5_000` 并给 CI 负载系数，或改事件驱动等待。
**测试点**：每条改法都要"高负载下 20 连跑 0 失败 + 反向破坏产品行为必须红"。

## 2. 风险清单（跨条目）

| # | 风险 | 等级 | 缓解 | 回滚 |
|---|---|---|---|---|
| R-1 | 与在途会话合并冲突（JS 替身/用例） | 中 | §1 R1P-02 边界：源码归本循环、替身归在途；spike 替身改动语义与在途一致，可丢弃 | 按文件粒度 cherry-pick |
| R-2 | 能力摘要压缩后模型工具选择质量下降 | 中 | 首句保留核心语义；`tool://` 全文不变；R2 起用真实会话观察（需 R1P-14 授权） | 还原 10 个首句 + plugins.ex |
| R-3 | 分区补齐后门禁墙钟超 **2500 s**（D-1 放宽后；原 2100 s） | 低（原中） | spike 实测漏跑部分单 VM 441.7 s，串行预计 ≈2200 s < 2500 s；改后全量门禁实测中（§4.2）。若仍超线 → R1P-10 并行化提前（前置：/tmp/newbee-test-caps 每 VM 隔离、固定端口 4576 的 tls_smoke 排查），**不砍覆盖** | 分区表可单独回滚 |
| R-4 | 格式化与未来在途改动冲突 | 低 | 34 文件与当前 7 个在途文件零交集（已核对）；AST 等价证明 | 整批 checkout |
| R-5 | meta 测试自身恒绿（root 路径错） | 已消除 | spike 踩过并修复；反向验证（删 colony 行必须红）已入库为验收步骤 | — |
| R-6 | 守护用例过度耦合投影管线 | 低 | 反向破坏实验证明只有 2 条相关用例红；管线变更时这 2 条必须显式更新（设计意图） | 单文件还原 |
| R-7 | worktree 泄漏继续累积（R1P-08 未入选） | 中 | 本轮 arch 两树 + 测试又新增注册（223→243）；**停止泄漏**的最小方案：测试创建的 worktree 在 on_exit 里 `git worktree remove --force`（产品 `Workspace.remove_git_worktree` 已有正确实现，测试路径没走它）；历史清理需授权（pm 决策项 2） | 清理操作不可逆，必须先授权 |
| R-8 | **同阶段双实例并发**：另一 arch 工作者在 `.worktrees/arch-r1` 独立实现并写方案（收尾时发现） | 中 | 本交付全部验证已迁到独占的 `arch-r1-spike`；未改对方文件；自己的门禁重跑已终止；两方案结论一致但细节不同（如 @summary_bytes 66 vs 64、1745 vs 1752 B），**main 必须裁决唯一权威版本**，dev 不得混用两树补丁 | 以 spike 树为准；对方树归对方 |

## 3. 给 dev 的执行顺序与验收命令

顺序：**03 → 04 → 05 → 06 → 01 → 02 → 09**（03/04 关噪声；05 独立可插队；06 在 01 前避免 archive 红干扰分区判断；02 与 01 可并行但须遵守 R-1 边界）。
spike 补丁 `arch-evidence/spike.patch` 已按此顺序叠加验证，dev 可直接 `git apply` 后按条拆 commit（建议 7 个 commit 对应 7 条，便于单条回滚）。**注意**：patch 不含新文件，`test/newbee/test_partition_coverage_test.exs` 全文在 `arch-evidence/test_partition_coverage_test.exs.new`。

每条的验收命令即 pm §3 原文（R1P-01 第 4 条墙钟上限按 **D-1 改为 ≤2500 s**）；聚合验收：
```bash
MIX_ENV=test mix compile --warnings-as-errors        # exit=0
mix format --check-formatted                          # exit=0
MIX_ENV=test mix newbee.test_fast                     # exit=0，分区文件数合计 250，墙钟 ≤2500 s（D-1）
mix test.acceptance                                   # 14/14
node --test test/web/conversation-work.test.js        # exit=0，≥32（在途合入后 ≥44+3）
```

## 4. 未覆盖范围（如实声明）

1. **改前全量门禁未跑完**：第一次在 arch-r1 跑到 web 分区被环境 SIGTERM 中断；第二次（setsid）跑到 collaboration 分区时发现该树被另一 arch 实例并发修改（R-8），结果失效，已主动终止（`arch-evidence/gate-pre2-aborted.log`）。**改前 8 失败清单沿用 R1 基线报告**（同 commit 同 seed，本轮已逐条定向复现 D1/D2/D3/D4/D5/D6）。改前全量门禁需由 main 在干净树上重跑一次作为 R2 对照。
2. **改后全量门禁**：D-1 决策后已于 13:41 在 spike 树启动（test_fast 250 文件 + acceptance + JS，setsid 脱离进程组），结果与墙钟见 `arch-evidence/gate-post*.{log,exit}`；本节在跑完后更新实测数字。此前 spike 只跑了受影响分区与用例（约 500 用例次）。
3. JS 修复未在真实浏览器/Playwright 验证（替身口径）；`NEWBEE_BROWSER_INTEGRATION` 未开。
4. 三种子稳定性（G8）未在改后重测；批 B 抖动未修，seed 851020 的 environment 失败预计仍在。
5. 未做行覆盖率、跨主机、TUI 真机、真实模型调用（R1P-13/14/15 范围）。
6. 未 commit/push/merge；**spike 树（arch-r1-spike）是本交付唯一权威现场**；arch-r1 树含另一实例的在途工作，本会话不再写入；主仓库在途 7 文件未触碰（收尾复核一致）。
7. 本轮 arch 活动使 worktree 注册 223→243（+20，含 2 个 arch 树与测试新增），未清理（R-7，清理需授权）。

## 5. 证据索引（`.worktrees/arch-r1-spike/arch-evidence/`）

| 文件 | 内容 |
|---|---|
| `spike.patch` | 全部最小改动（53 文件，sha256 见头部） |
| `test_partition_coverage_test.exs.new` | meta 测试新文件全文 |
| `warnings-final.log` / `colonywarn.log` | 警告修后 39 passed exit=0 / 修前 29 passed exit=1 |
| `format-final.log` / `fmtfiles.txt` | 格式 exit=0 / 34 文件清单 |
| `format-affected-crosshost.log` 等 3 份 | 格式化影响面回归（37+48+31 passed） |
| `contracts-warnings-final.log` | 契约+meta+警告点合并 48 passed exit=0 |
| `archive-final.log` / `spike_archive2.log` | archive 26/26 |
| `reverse-projection-removed.log` | 反向：删投影 → 恰好 2 条守护红 |
| `js-final.log` / `js-after.log` | JS 35/35 exit=0 |
| `missing32.log` / `missing32.exit` | 漏跑 32 文件 281 passed（441.7 s） |
| `summary-consumers.log` | 摘要消费方回归 44 passed |
| `gate-pre-partial.log` | 改前门禁第一次（中断）现场 |
