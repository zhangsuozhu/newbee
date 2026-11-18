# 第 1 轮 · 测试验证（qa）—— 测试报告与缺陷清单
> 阶段：第 1 轮 · 测试验证（qa）　|　被测：`dev-r1.patch`　|　基线：`5ac87bad…` = `origin/main`
> 交付：本报告 + `round-01-qa-defects.md` + `qa-evidence/`（64 文件 / 1004 KB / `SHA256SUMS` 22 条全通过）
> 一句话结论：**批 A 六条验收标准 6/6 通过（含反向验证），门禁 6/6 绿（508 s，二次复现 413 s）；G4 因 1 条非本轮引入的抖动未清零；新发现 3 条真实缺陷（QA-D1/D2/D3）+ 1 条集成冲突（QA-D4）+ 1 条预先存在的 **P0 产品缺陷**（QA-D5，已确定性证明）。**


- 轮次：R1（自我改进循环第 1 轮）
- 角色：测试工程师（qa）
- 时间：2026-11-16 17:50–19:40 (+08:00)
- 被测改动：`dev-r1.patch`（72 文件 +2031/−253，sha256 `f722681a…af4c4`），基线 `5ac87bad…` = `origin/main`（#228）
- 测量位置：
  - 改造后树 `.worktrees/qa-r1`（detached `5ac87ba` + `git apply dev-r1.patch`，`deps` 软链主仓库）
  - 改前对照树 `.worktrees/qa-r1-base`（同 commit 纯净树，未打补丁）
  - 两树各自独占，未与其他会话共用写目录；主仓库 7 个在途文件全程未被触碰（收尾 `git status` 与开工一致）
- 原始证据：`.worktrees/qa-r1/qa-evidence/`（见 §6 清单，含 `SHA256SUMS`）
- 提交状态：**未 commit / 未 push / 未合并**

---

## 0. 结论（先看这段）

**判定：批 A 六条验收标准 6/6 达成（每条都有反向验证）；门禁能跑绿（3 次里 2 次 6/6 绿），但做不到"连续三次全绿"。整体 G4 未达标、G8 部分达标。共 5 条缺陷：QA-D1（本轮新引入，P1）、QA-D2（测试假通过，P1）、QA-D3（覆盖假象，P2）、QA-D4（集成冲突，P1）、QA-D5（预先存在的 P0 产品缺陷，已确定性证明）。**

| 项 | 结论 | 依据 |
|---|---|---|
| G1 编译零警告 | **达标** | base 树 4 处测试警告 → patched 树 0；两树编译 `--warnings-as-errors` 均 exit=0 |
| G2 格式 | **达标** | base `exit=1，34 文件` → patched `exit=0`；反向（插入未格式化代码）→ `exit=1` |
| G3 test.fast | **达标** | base `exit=1（tools-tui / web / root 三分区红）` → patched `exit=0（9 分区全绿，1755 passed）` |
| G4 全量单进程 0 失败 | **未达标** | patched `1768/1769（1 失败：TlsTest 抖动）`；base `1742/1745（3 失败）`。该抖动非本轮引入，见 §3 QA-D5 |
| G5 架构验收 | **达标** | 两树均 14/14 |
| G6 前端 | **达标** | base `32 tests / 0 pass` → patched `35/35`；源码 `innerHTML`=0；反向 → 恰好 1 条契约红 |
| G7 覆盖完整性 | **达标** | base `217/250`（漏 32 文件 / 281 用例，acceptance 按设计在外）→ patched `255/256`（同样只排除 acceptance） |
| G8 三种子一致 | **部分达标** | 抽查 `root`（seed 1/40410/851020）与 `environment`（851020×3/1/40410）**全部一致**；9 分区全量三种子**未跑** |

**打回判定：不打回 dev。** 六条验收标准逐条可判定且均已通过，未发现"改坏了"的证据（产品语义零改动，见 §2 AST 对比）。
**但必须辩解清楚的三点**（不接受"绿了就等于交付"）：
1. 门禁本身有**新引入的可观测性缺陷**（QA-D1，中文子进程输出在门禁日志里全程乱码），这恰好是 R1 D8 要治的问题，等于"门禁绿了但看不了"。
2. `session_index_perf_test` 的**热路径守卫是恒真的**（QA-D2），"不再读盘"这条断言在热路径用例里根本没有被真正验证过。
3. 第三次门禁红了，撞出一条**预先存在的 P0 产品缺陷**（QA-D5）：`Client.interrupt()` 的全局回退会让一个会话按 Esc 掐断另一个会话的流。它在 R1 被误分类为「等待预算过短」，所以一整个轮次没人发现。

---

## 1. 真实验证方法与结果

### 1.1 补丁可移植性（先证明测的是什么）

```
cd .worktrees/qa-r1 && git apply --check dev-evidence/dev-r1.patch   → APPLY_CHECK_OK
git apply dev-evidence/dev-r1.patch                                  → 71 个跟踪文件改动 + 6 个新文件
git diff --numstat HEAD (含新文件)                                    → 72 files +2031 −253
content diff -r vs .worktrees/dev-r1（排除 .git/_build/.newbee/日志）  → 无差异
```
即：**本会话测的树与 dev 交付的树内容一致**，结论对 dev 的补丁成立。

### 1.2 门禁 `mix newbee.gate`（改后，qa-r1，`TMPDIR=/var/tmp/qa-r1-tmp`）

`loadavg 7.15 → 4.4`（20 核），墙钟 **508 s**（dev 报告 505.73/530.71/541.43/551.25，同量级）。

| 步骤 | exit | 墙钟 |
|---|---|---|
| compile-dev | 0 | 2 s |
| compile-test | 0 | 114 s |
| format | 0 | 5 s |
| test-fast | 0 | 378 s |
| acceptance | 0 | 8 s |
| web-js | 0 | 1 s |
| **合计** | **0** | **508 s** |

9 分区用例：`agent-dee 109 / environment 149 / llm 180 / tools-tui 215 / web 336 / collaboration 150 / colony 177 / plugins-learning 80 / root 359` = **1755 passed / 0 failed**（+13 excluded、10 skipped、3 skipped），另 acceptance 14 passed、JS 35 passed。

**门禁三次复跑的完整记录（含唯一一次红）**：

| 次 | 场景 | 结果 | 墙钟 | 日志 |
|---|---|---|---|---|
| 1 | 首次，`loadavg ≈7` | **6/6 绿** | 508 s | `gate-patched.log` |
| 2 | `repro.sh` 内，反向实验前 | **6/6 绿** | 413 s | `gate-rerun.log` |
| 3 | 全部反向实验并还原**之后** | **5/6 红**：`test-fast exit=1`，唯一失败 `AnthropicTest`（`{:interrupted, ""}`） | 362 s | `gate-final.log` |

第 3 次的红**不是**反向实验残留（还原后 8 个受影响测试文件 52 passed + JS 35/35 全绿，见 `post-restore-check.log`；`git status` 显示仍是那 72 个补丁文件、无残留），而是**踩中了一条预先存在的跨测试竞态** → 这就是 QA-D5。**结论：门禁目前不可"连续三次全绿"**，这与 G8 未达标同源。

**复现性**：`qa-evidence/repro.sh` 端到端跑通一次（`repro_exit=0`），其中门禁第二次 **6/6 全绿，413 s**
（`compile-dev 2 / compile-test 9 / format 4 / test-fast 390 / acceptance 8 / web-js 0`，9 分区同结果：
`109 / 149 / 180 / 215 / 336 / 150 / 177 / 80 / 359`）。即门禁可从零复现，不是一次性偶然。

### 1.3 改前 / 改后同口径对照（同 249 文件、同 seed、同 TMPDIR、串行）

为排除"多跑/少跑文件"的口径差，我把 base 树与 patched 树都按 **同一份 249 文件清单**（= patched 分区表展开后去掉 6 个新增测试文件）逐分区跑：

| 分区 | base 结果 | patched 结果 | 分区墙钟 base→patched |
|---|---|---|---|
| agent-dee | 109 passed | 109 passed | 30 s → 24 s |
| environment | 149 passed | 149 passed | 12 s → 12 s |
| llm | 180 passed, 3 skipped | 180 passed, 3 skipped | 18 s → 19 s |
| tools-tui | **209/210（1 失败：能力索引 1941>1800）** | **210 passed** | 25 s → 24 s |
| web | 336 passed, **2 编译警告→exit=1** | 336 passed, 0 警告→**exit=0** | 119 s → 103 s |
| collaboration | 150 passed | 150 passed | 71 s → 75 s |
| colony | 177 passed, **2 编译警告→exit=1** | 177 passed, 0 警告→**exit=0** | 38 s → 43 s |
| plugins-learning | 77 passed | 77 passed | 26 s → 34 s |
| root | **340/343（3 失败：archive + 2×session_perf）** | **344 passed** | 20 s → 22 s |
| **合计** | **1727 passed / 13 skipped / 14 excluded，4 条用例失败（工具提示 1 + root 3），4 分区红（tools-tui/web/colony/root，其中 web 与 colony 是编译警告判红、用例全过）** | **1732 passed / 13 skipped / 14 excluded，0 失败，9 分区全绿** | **359 s → 356 s** |

结论：
- **行为差异全部是"红转绿"，没有任何用例从绿转红**（同一文件清单、同一 seed，逐分区比对）。
- **性能差异在噪声内**（−0.8%）：墙钟数字对这台机器（`/tmp` 满盘历史、loadavg 3–7）不可作回归判据，只做上限检查；`≤2100 s` 上限达成（508 s，远低于上限）。

### 1.4 全量单进程套件（G4，dev 未做的那一项）

`MIX_ENV=test mix test --warnings-as-errors --seed 1`，两树串行、各自 detached：

| 树 | 结果 | 失败 | 墙钟 |
|---|---|---|---|
| base（纯净 5ac87ba） | **1742/1745**，13 skipped，14 excluded | archive（旧契约）、session_perf×2、能力索引 → **3 失败** | 348 s |
| patched | **1768/1769**，13 skipped，14 excluded | `TlsTest 真实网关握手 insecureSkipVerify 接受自签网关`（`TLS 服务没有起来`）→ **1 失败** | 354 s |

`1745 → 1769` 的 24 条增量 = 新增/改写的守护用例（archive +1、prompt_section +3、partition_coverage +3、gate_preflight +4、gate_stream +4、lifecycle +4、gate_contract +5）。
`--warnings-as-errors` 下 base 出现 4 处测试编译警告、patched 0 处（另一个维度证明 R1P-03 已修）。

### 1.5 反向验证（证明新测试会红，不是恒绿）

| 反向实验 | 期望 | 实测 |
|---|---|---|
| 从 `partition_specs` 删掉 `colony` 一行 | 覆盖元测试红并列 19 文件 | **红**：`门禁漏跑这些文件: …colony 19 个文件…`，2/3 passed |
| `project_chat_messages` 的 `drop_keys` 改成 `[]`（投影退化为 identity） | archive 新守护红灯 | **红**：恰好 1 条（`前缀缓存不变量…`），25/26 |
| `conversation-work.js` 改回 1 处 `innerHTML` | 源码契约红 | **红**：`not ok 1 - 源码契约…`，34/35 pass、1 fail |
| `session.ex` 的 `hit = false`（缓存恒失效） | 冷路径用例红 | **红**：`列表重新扫描了 transcript（1502→1501）`，2/3 |
| 插入未格式化代码 | format 步骤红 | **红**：`mix format failed … codec.ex`，exit=1 |
| PATH 里去掉 node | 门禁显式失败（不静默跳过） | **红**：`newbee.gate: 找不到 node（前端套件 G6 无法执行）` |
| `mix newbee.gate --list` / `--bogus` | 打印 6 步 / 参数报错 | 6 行步骤表 / `未知参数 [{"--bogus", nil}]` |
| `mix test.all --list` | 路由到 gate（不再自称完整入口） | 打印 gate 的 6 步 |

### 1.6 三种子稳定性（G8 抽查，非全量）

| 分区 | seed 1 / 40410 / 851020 | 结论 |
|---|---|---|
| root（59 文件） | 三 seed **全 exit=0、全绿** | 一致（R1 该分区三次一致，保持） |
| environment（31 文件） | seed 851020 跑 3 次 + 1 + 40410 **全部 149 passed** | 一致（R1 D7 的 851020 多 1 失败**未复现**；但见 QA-D5，这只说明"这台机器此刻没复现"，不能证明已修——4 s 等待预算与 `dt < 500` 断言原样未动） |

### 1.7 语义零改动验证（产品代码到底改了什么）

对 `lib/` 229 个两树共存文件做 **AST 抹 meta 后逐一比对**（比 `git diff -w` 更强）：

- `217/229` 文件 **AST 完全相同**（纯格式化）。
- 12 个文件有真实差异，逐个核对后只有 **3 类**：
  1. `lib/newbee/plugins.ex`：`@summary_bytes 66` + `truncate_summary/2` + `utf8_prefix/2`（R1P-05 的实现）；
  2. `lib/mix/tasks/newbee/test_fast.ex`：分区表/公开 API/实时转发（R1P-01 + D8）；
  3. 9 个 tools 文件 + `team.ex` + `edit.ex`：**只改 `@moduledoc` 首句**（为压到 66 B 预算），其中 `edit.ex` 把 `docs/edit-design.md` 引用从首行移进正文（`docs/edit-design.md` 的引用契约仍成立）。
  - 新增 3 个文件：`gate.ex` / `gate_preflight.ex` / `gate_stream.ex`。
- **未改动**：`lib/newbee/llm/client.ex`（投影语义）、`session.ex`、`archive.ex`、`conversation-work.js` 的产品逻辑语义（后者只把 6 处 `innerHTML` 换成 DOM 构建）。

---

## 2. 缺陷清单（本轮 qa 共 5 条：4 条新发现 + 1 条预先存在的 P0；另有 4 条未达标/未覆盖项）

> 严重度：P0 阻断（必须退回）／P1 必修（本轮内或下一轮首项）／P2 应修。

### QA-D1 · P1 · 门禁把子进程中文输出去成了乱码（新引入，可观测性反而变差）

**现象**：`gate-patched.log` 里，`[gate]` 行（父进程 `Mix.shell`）中文正常，但所有**子进程输出**（`mix test` 的用例名、断言消息、`node --test` 的 TAP 名称）全部乱码。实测 `热路径` / `常驻工具提示` / `源码契约` 三个中文串在该日志中**一次都搜不到**；dev 证据 `gate-verified.clean.log` 同样（同样三个串搜不到）。

**复现**（30 秒，不依赖长跑）：
```bash
cd .worktrees/qa-r1
MIX_ENV=dev mix run qa-evidence/probe_encoding2.exs   # 见 qa-evidence/probe_encoding2.exs
# 输出：
#   DIRECT: 中文测试 直接输出          ← 父进程直写，正常
#   FORWARDED: ä¸­ææµè¯           ← 经 GateStream 转发，乱码
```

**根因**（已实测定位，非猜测）：`lib/newbee/gate_stream.ex:67` 用 `IO.binwrite(io, data)`。`:stdio` 设备的 `:io.getopts` 是 `encoding: :unicode`，`binwrite` 会把已经是 UTF-8 的二进制**再按 unicode 编码一次**：
```
binwrite_valid=true content=<<195,164,194,184,194,173,…>>     # "中文" → 6 字节变 12 字节（双重编码）
write_valid=true     content="中文 write\n"                  # IO.write 正常
```
**影响**：门禁的存在理由之一就是 R1 D8「逐用例结果可见」。乱码让中文用例名/断言消息不可读、`grep` 不到，打回定位成本回到"盲猜"。不影响 exit code，所以 CI 不会报警。

**修复方向（有实测依据，交给 dev）**：
- 直接改 `IO.write/2` **能修好主路径**（我改后实测 `VIA-GATE-STREAM 中文` 正确），**但**当 `Port` 把一个多字节字符切成两个 chunk 时会 `** (Erlang error: :no_translation)`（实测：分两次写 `<<0xE4,0xB8>>` + `<<0xAD>>` 抛错）。所以正确修法是「按设备编码写 + 保留未完成的多字节尾巴」，或把 `io` 包装成 `:latin1` 设备再 `binwrite`（实测 `StringIO.open("", encoding: :latin1)` + `binwrite` 输出正确）。
- 必须补一条**含中文输出**的 `gate_stream_test` 用例（现有 4 条全用 ASCII，所以测不出来）。

### QA-D2 · P1 · `session_index_perf_test` 的热路径守卫恒真（"不再读盘"没被真正验证）

**现象**：新用例 `热路径：追加消息后列表不再读 transcript` 末尾调用 `stale_growth_guard(3, session_path(id))`，而该守卫靠 `String.replace(payload, "\n\n", "  ")` 改写文件。**热路径建的 transcript 里没有 `\n\n`**，改写是 no-op：
```
file_bytes=80239   newline_newline_count=0   tamper_equal=true   count_before=3   count_after_tamper=3
```
即：文件一个字节没变，"命中缓存所以计数不变"与"根本没改文件"无法区分 → 该用例恒真。
**冷路径那条是真的**（有 `\n\n`，且我实测 `hit=false` 时它准确报出 `1502→1501`）。

**复现**：`MIX_ENV=test mix run qa-evidence/probe_hot_guard.exs`（`tamper_equal=true` 即证）。
**建议**：热路径也构造一个可等长改写的差异（例如把某行 `"hi"` 改成 `"ho"` 并同时把另一处补一个空格抵消长度），或直接断言 `transcript_scan_count/0` 在"只列表不追加"期间不增长（在 `async: false` 下已足够安全）。

### QA-D3 · P2 · 新截断逻辑的"词边界回退"在"首个词超预算"时不成立（当前预算下不可达）

**现象**：`@summary_bytes 66` 下，**没有任何一条摘要超过 66 B**（实测 `truncated=0`，最长首句恰 66 B）→ 新加的 `truncate_summary/2` + `utf8_prefix/2` **在真实数据上零触发**。把预算压到 20 B 强制触发后，新测试**准确抓到**边界 bug：
```
1) test 每条摘要都按字节预算截断，且不在半个词/半个字符处断
   tool.fs 摘要在词中间截断："ng; prefer `Newbee.read/1` for reads."
```
根因：`utf8_prefix/2` 截到预算后若 `String.split(head, " ")` 只有一个元素，走 `String.trim_trailing(head)` 直接输出**半个词**，没有回退到"整词丢弃"。
**影响**：现在不可达（所以门禁绿），但下一条带长单词首句的工具/摘要一进来就会切断，且那时代码已经"有测试覆盖"的假象。**反向验证**：预算改 120 B 时测试仍 3/3 通过（因为根本没有截断发生），说明当前预算参数本身不被测试约束。
**建议**：加参数化用例直接测 `truncate_summary/2`（含"首词超预算"用例），并把 `@summary_bytes` 也断言在测试里。

### QA-D4 · P1（集成风险，非代码缺陷）· 补丁与主仓库在途改动有 2 个文件硬冲突

```
补丁跟踪文件 ∩ 主仓库 7 个在途文件 = test/web/conversation-work.test.js, test/web/conversation_work_dom.js
```
主仓库当前分支是 `fix/jspace-open-section`（**不是** `5ac87ba`，且 `5ac87ba` 不是它的祖先），在途会话正在改同一个 JS 替身/套件。arch 的 R-1、dev 的未覆盖项都只提到"替身归在途"，**没给合并顺序**。
**请 main 裁决**：先合在途 JS 会话、再由 dev 以其为基线 rebase 补丁（推荐，避免替身语义分叉）；或由本循环独占 `test/web/*` 并对在途改动做人工合并（有丢失在途 269 行新增测试的风险）。

### QA-D5 · P0（预先存在，非本轮引入）· `Client.interrupt()` 的全局回退让任意测试中断别人的流式请求

**我怎么撞到的**：第三次门禁复跑（`qa-evidence/gate-final.log`，`gate_final_exit=1`）红在
```
1) test 空流后重发成功：返回正常消息并提示用户 (Newbee.LLM.AnthropicTest)
   test/newbee/llm/anthropic_test.exs:310
   code: assert {:ok, message, usage} = Client.stream_chat(...)
   right: {:interrupted, ""}
```
即：这条用例的那次 `stream_chat` **被中断了**，但用例里没有任何人中断它。

**确定性机制证明**（不依赖偶发，30 秒可复现）：
```bash
cd .worktrees/qa-r1 && MIX_ENV=test mix run qa-evidence/probe_interrupt_race.exs
```
```
client.interrupt_scope=nil
after_concurrent_interrupt interrupted?=true
stream_chat_result={:interrupted, ""}        ← 别处调用 interrupt() 后，这条流立刻被中断
after_clear2 interrupted?=false
```
**根因**：
- `Client.new/1` 不传 `:interrupt_scope` 时该字段为 `nil`（`client.ex:109`）；
- `interrupted?/1` 对 `nil` scope **回退到全局 `@interrupt_legacy_key`**（`client.ex:1057`）；
- `test/newbee/llm/clienttest_test.exs:80` 在 `async: true` 的用例里直接 `Client.interrupt()`（不传 client → 置**全局**标志），`test/newbee/dee/kerneltest_test.exs:390` 同样调用；
- 于是同一 VM 里任何**并行**跑着的、无 scope 的 `stream_chat` 都会在 ≤100 ms 内看到 `interrupted?=true` → `Req.cancel_async_response` → 返回 `{:interrupted, ""}`。

**为什么判定"预先存在、非本轮引入"**：
| 证据 | 结果 |
|---|---|
| `lib/newbee/llm/client.ex` 两树 `diff -q` | **IDENTICAL**（本轮**未改动**该文件） |
| `test/newbee/llm/anthropic_test.exs` 两树 | **IDENTICAL** |
| **base 树**（纯净 5ac87ba）`llm+web` 合并压测 seed 1 | **509/511，红在 `AnthropicTest` + `ChatWireProjectionTest`**（`qa-evidence/race-matrix.log`）→ 同一竞态在修改前就存在 |
| base 同压测 seed 3 | 510/511，红在 `CollaborationApiTest`（另一个同族竞态） |
| patched 同压测 seed 1–3 | 511/511 **全绿**（本轮恰好没撞上） |
| 单文件 `anthropic_test` 两树各 6 seed | 18 次全绿（证明它只在**并发**下红） |
| llm 分区两树各 12 seed | 48 次全绿（并发面还不够） |

**严重度定 P0 的理由**：这是**产品代码**的语义缺陷，不只是测试问题。`Client.interrupt/0` 在生产里如果被无 scope 的调用方触发，会中断**同 VM 内所有**无 scope 的会话流——正是"会话 A 按 Esc，会话 B 的流被掐断"。而现在的测试套件"有时绿"，把这个真实缺陷掩盖成了"抖动"。R1 基线把它归到 D7「等待预算过短」是**误分类**（pm 的 R1P-07 也沿用了这个误判）。

**修复验收标准**（给 arch/dev，R2 首项）：
1. `Client.interrupt/0` 不再有"全局"分支：无 scope 时要么报错、要么生成并返回一个 scope（不允许静默置全局位）；
2. `test/newbee/llm/clienttest_test.exs:80`、`test/newbee/dee/kerneltest_test.exs:390` 改为显式 scope；
3. 新增守护用例：两个并发 `stream_chat`，只对其中一个 `interrupt()`，断言另一个**正常完成**；反向（去掉 scope 隔离）→ 该用例必须红；
4. 验收：`llm+web` 合并压测 seed 1–3 两树均 511/511，且三次门禁连续全绿。

### 未达标 / 未覆盖项（不算新缺陷，但必须记账）

| 编号 | 项 | 状态 | 说明 |
|---|---|---|---|
| QA-N1 | **G4 全量 0 失败** | **未达标** | 三次门禁里有两次全绿、一次红：第三次红在 `AnthropicTest`（`{:interrupted, ""}`）。根因已定位为**预先存在**的跨测试全局中断标志竞态（QA-D5），**不是本轮引入**；但按 G4 文字标准本轮不达标 |
| QA-N2 | G8 三种子 | 部分 | 只抽了 `root` + `environment`（2/9 分区）；9 分区全量三种子未跑（每轮 ≈3×360 s） |
| QA-N3 | 运行时警告仍存在 | 已知 | 3 条 `File.stream!/3 is deprecated` 是**运行时**警告，`--warnings-as-errors` 只在编译期生效，故门禁不红。门禁"零警告"的口径只是编译期，需在 G1 描述里写明 |
| QA-N4 | worktree 泄漏 | 未修（无授权） | 注册 **355** 条 / `.git/worktrees` **31 MB**（R1 基线 204/17 MB，dev 交付 311）→ 本轮测试又 +44。门禁 preflight 只 `:warn`。清理属破坏性操作，需人工授权 |
| QA-N5 | 未覆盖范围 | — | 未在真实浏览器/Playwright 跑 JS；未做行覆盖率（R1P-13）；未做真实模型调用/计费基准（R1P-14）；未验证跨主机/多进程；`plugins-learning` 与 `root` 的用例耗时未做 p50/p95 采集（本轮只取分区墙钟） |

---

## 3. 与基线（R1）的行为/性能对比总表

| 指标 | R1 基线 | 本轮 patched | 差 |
|---|---|---|---|
| 门禁命令 | 不存在 | `mix newbee.gate`（6 步，`--fail-fast`/`--list`） | 新增 |
| test.fast 分区 | 7，217/250 文件 | 9，255/256 文件 | +2 分区、+38 文件覆盖 |
| 漏跑用例 | 281 条（32 文件） | 0（acceptance 按设计在外） | 修 |
| 门禁墙钟 | 1760.8 s，4/7 红 | **508 s**，9/9 绿 | −71%，红→绿 |
| 编译警告 | 4 | 0 | 修 |
| 未格式化文件 | 34 | 0 | 修 |
| 能力索引 | 1941 B > 1800 | **1745 B**（20 条目不变） | 修（余量 55 B） |
| archive 回放 | 24/25（假警报） | 26/26 + 反向哨兵 | 修（并补上真实不变量守护） |
| 前端套件 | 32/0 | 35/35，源码 `innerHTML`=0 | 修 |
| 全量单进程 | 8 失败（R1 记录） | **1 失败（抖动）** | −7，未清零 |
| 用例总数（声明） | 1772 | 1796 | +24 |
| worktree 注册 | 204 | **355** | +151（未修，需授权） |

---

## 4. 打回理由（不达标项）

**本轮不整轮打回**：六条验收标准全部可判定通过，无绿转红，产品语义零改动（AST 已证）。
**但下列 4 项必须由 main 在 R2 首项处理**，否则"门禁绿"不可信：

- **QA-D1（P1）**：门禁把中文子进程输出写成乱码。理由：本轮 R1P-09 的验收标准里写明"门禁必须让失败看得见"（D8），现在 fail 时的中文用例名不可读、不可 `grep`，等于把可观测性缺陷从"没有输出"换成了"输出不可读"。修复成本约 10 行 + 1 条含中文的 stream 用例。
- **QA-D2（P1）**：热路径守卫恒真。它不是"测试失败"，而是"测试假通过"——比失败更危险，因为它会让人以为 R1 D9 已经根治。
- **QA-D4（P1）**：与在途 JS 会话的文件级冲突，需要 main 裁决合并顺序后才能进入主线。
- **QA-D5（P0）**：`Client.interrupt()` 的全局回退会让一个会话按 Esc 掐断另一个会话的流。这不是测试问题而是**产品语义缺陷**，且被"偶发红"掩盖了整整一轮（R1 基线误分类为 D7 等待预算）。修复 + 守护用例 + 两树压测全绿之前，任何"三种子一致"的结论都不成立。

---

## 5. 复现方式

```bash
cd /home/alanx/data/git/newbee

# 1) 建两棵树（一次性）
git worktree add --detach .worktrees/qa-r1       5ac87bad145b0801e7d8c5145895e87ddd4ac3ff
git worktree add --detach .worktrees/qa-r1-base  5ac87bad145b0801e7d8c5145895e87ddd4ac3ff
ln -s /home/alanx/data/git/newbee/deps .worktrees/qa-r1/deps
ln -s /home/alanx/data/git/newbee/deps .worktrees/qa-r1-base/deps
cd .worktrees/qa-r1 && git apply /home/alanx/data/git/newbee/.worktrees/dev-r1/dev-evidence/dev-r1.patch

# 2) 一键复跑本轮全部结论（约 25 分钟；写 qa-evidence/*.log）
bash .worktrees/qa-r1/qa-evidence/repro.sh

# 3) 只看门禁（≈9 分钟）
cd .worktrees/qa-r1 && TMPDIR=/var/tmp/qa-r1-tmp mix newbee.gate

# 4) 单点复现 QA-D1（30 秒）
cd .worktrees/qa-r1 && MIX_ENV=test mix run qa-evidence/probe_encoding2.exs

# 5) 反向验证
bash .worktrees/qa-r1/qa-evidence/reverse.sh          # archive 不变量
bash .worktrees/qa-r1/qa-evidence/reverse-js.sh       # innerHTML 契约
bash .worktrees/qa-r1/qa-evidence/reverse-js-double.sh # 替身 toggle 缺失
```

---

## 6. 证据文件清单（`qa-evidence/`）

| 文件 | 内容 |
|---|---|
| `gate-patched.log` / `.meta` | 门禁全绿 508 s 原始输出（乱码现象现场） |
| `qa-parts.log` / `qa-parts2.log` / `qa-part-*.log` | patched 同口径 249 文件逐分区结果 |
| `qa-parts.sh` / `qa-parts2.sh` | 上述分区的可重跑脚本（与 base 完全同一份文件清单） |
| `fullsuite-patched2.log` | 全量单进程 1768/1769（G4 实测） |
| `seed-*.log` | root/environment 三种子稳定性 |
| `js-patched.log` | 前端 35/35 |
| `probe_encoding2.exs` / `probe_encoding3.exs` / `probe_io_fix.exs` | QA-D1 根因与候选修复实测 |
| `probe_hot_guard.exs` / `probe_cold_guard.exs` | QA-D2 恒真证明（热路径 tamper 是 no-op） |
| `probe_truncation.exs` | QA-D3：`truncated=0`（截断零触发） |
| `reverse.sh` / `reverse-archive.log` | 反向：投影退化 → archive 红 |
| `reverse-js.sh` / `reverse-js.log` | 反向：改回 innerHTML → 契约红 |
| `reverse-budget.log` / `reverse-truncate.log` | 反向：预算/截断（结论见 QA-D3） |
| `probe_node_missing.exs` | 反向：缺 node → 门禁显式失败 |
| `SHA256SUMS` | 上述文件校验 |

对照组在 `.worktrees/qa-r1-base/`：`qa-base-{format,testfast,acceptance,js}.log`、`qa-base-part-*.log`、`qa-base-fullsuite-base2.log`、`qa-base-expanded.sh`。
