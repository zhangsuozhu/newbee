# 第 2 轮 · 测试验证（qa）—— 缺陷清单

- 被测补丁：`dev-r2.patch`（sha256 `83b75e41…0cf16`），基线 `5ed39a6`（= `origin/main` #229）
- 判定口径：**阻断（必须打回/必须先修）** = 验收标准明确不满足或引入新缺陷；**非阻断** = 记录并给 R3 入口
- 本轮全部结论都有实跑证据，路径见 `qa-evidence/logs/`；一键复现 `bash qa-evidence/repro.sh`

## 一、阻断项（必须进 R3 首项）

### QA2-D1（P1，本轮新发现）R2P-04 的守卫只认"焦点"，用户一失焦草稿照样被 8 s 轮询清空

**验收标准出处**：pm R2P-04 §验收①「当 `state.action` 或 `activeElement` 位于 `.tp-body` 内时 `load(false)` 只更新数据不重绘」——实现**照做了**，但标准本身漏了"焦点已离开但仍在编辑"的真实场景；基线 U1 要求的是"输入 20 字、静置 10 分钟，文字与焦点都在"，实测失焦后 8 s 内即丢失。

**复现（30 秒）**
```bash
cd .worktrees/qa-r2
NODE_PATH=/home/alanx/data/git/anxin-combine/node_modules \
  node qa-evidence/probe_poll_blur.js priv/web/team-panel.js
```
实测（jsdom，真实 8.3 s 定时器）：
```json
[
 {"scenario":"A 输入后失焦（activeElement=body）→ 等 8s 轮询",
  "active_element_seen":"BODY","polls":1,
  "present":false,"same_node":false,"value":null},      ← 草稿没了、节点被换掉
 {"scenario":"B 输入后保持焦点 → 等 8s 轮询（对照）",
  "active_element_seen":"user-form","polls":1,
  "present":true,"same_node":true,"value":"ABC"}        ← 达标
]
```
base 侧对照（同样场景 B 也红，属于改前缺陷）：`A present=false`、`B present=false`。

**影响**：用户在组建表单里打完字，去旁边看项目列表/点一下别处 → 8 s 内草稿被清空。这正是基线 U1「输入不了字」的一大半。

**根因**：`priv/web/team-panel.js` 的 `isEditing()` 只看 `document.activeElement`；没有 `input`/`compositionstart` 的"脏"标记，也没保存 `textarea.value` 快照。

**建议修法（最小）**：给 `.tp-body` 内的表单加 `input` 监听置 `state.dirtyForm=true`，在 `render()` 重建前把输入值与焦点位置快照/回填；或把 `render()` 改成按 key diff（不 `innerHTML=""`）。

**打回理由**：U1 的"静置 10 分钟不丢字"未达成。因为 UX 上"打一半字去看别处"是常态，本项不能作为已修。

---

### QA2-D2（P1，本轮新发现，需 arch 定性）R2P-02 收紧后 `spawn_monitor` 路径的 Esc 失效

**验收标准出处**：pm R2P-02 §验收②「无 scope 时不再写共享全局位」——实现照做，代价是**跨进程但无 `$callers` 关系**的中断不再生效。

**复现（20 秒）**
```bash
cd .worktrees/qa-r2 && TMPDIR=$PWD/.qa-tmp MIX_ENV=test \
  mix run --no-start qa-evidence/probe_interrupt_callers_gap.exs
```
| 场景 | base | patched |
|---|---|---|
| A 同进程 `interrupt/0` → `stream_chat/5` | `{:interrupted, ""}` | `{:interrupted, ""}` |
| B `Task.async`（`$callers` 继承） | `{:error, {:stream_error, …}}`＝**没被判为中断**（读到 `{:interrupt, :undefined}` 伪 scope → false），于是真的去发请求，而探针里 Finch 未启动所以报错 | `{:interrupted, ""}`（修好了：能沿 `$callers` 读到真实状态） |
| C `spawn_monitor`（无 `$callers`） | `{:interrupted, ""}`（靠 VM 级 legacy 全局位兜住） | `{:error, {:stream_error, …}}`＝**没被判为中断**（全局位已删，无 `$callers` 找不到树） |

补充事实（`probe_callers_spawn.exs`）：`spawn_monitor` 子进程 `$callers = :none`，`Task.async` 子进程 `$callers = [#PID<…>]`。

**影响面**：仓库里 `lib/newbee/llm/client.ex` 自己的流式 worker 是 `spawn_monitor`，但它的中断判据是**调用方进程**每 50 ms 轮询 `interrupted?(client)`（`await_stream_chat/4`），所以 main 路径不受影响（已用 `probe_interrupt_e2e.exs` 验证 A/B 两路都 `{:interrupted, ""}`）。风险在于：`agent/adapter.ex`、`agent/explorer.ex`、`host/shell.ex`、`environment/human_brief.ex`、`tools/browser.ex`、`learning/actor.ex`、`collaboration/chat/runner.ex` 这些用 `Config.client_for(...)`（**无 scope**）的地方，若将来在独立进程里跑流式请求，Esc 将不再生效。

**建议**：arch 明确"无 scope 的调用方必须注入 scope"这条规则，并把上述 7 处 `client_for` 显式补 `interrupt_scope`（或统一在 `Loop.start_link` 里生成）。本项不要求在 R2 修，但**必须写进 R3**，否则是把"误中断"换成了"不能中断"。

---

### QA2-D3（P1，门禁口径）新用例不在任何分区里，`mix newbee.test_fast` 一条都不跑

**复现**
```bash
cd .worktrees/qa-r2 && TMPDIR=$PWD/.qa-tmp MIX_ENV=test \
  mix run --no-start qa-evidence/probe_partition_coverage.exs
```
实测：
```
declared_files=256  covered_by_test_fast=222  missing_count=34
partition agent-dee 22 / environment 31 / llm 16 / tools-tui 25 / web 51 / collaboration 21 / root 56
missing 里包含：test/newbee/colony/team_auto_gate_test.exs、test/newbee/colony/team_test.exs、test/newbee/llm/interrupt_scope_test.exs（以及整个 colony 目录）
```
base 同脚本：`254 / 221 / 33`。

**影响**：门禁 G3 永远看不到这 8 条 Elixir 用例；G4/M8 的"漏跑 32→0"反而从 32 变 34。新增的 JS 套件同理（`node --test` 不在任何 mix 门里，G6 仍是 32/0）。

**建议修法**：在 `lib/mix/tasks/newbee/test_fast.ex` 的 `@partition_specs` 补 `{"colony", ["test/newbee/colony"]}`（以及 `codec/host/learning/plugins/terminal/truncate/evals`），并加一条 meta 测试：删掉分区表任一行 → meta 测试必须红（基线 T5 已提出，未实施）。

---

### QA2-D4（P1，未达标）G8：`web` 分区"全绿却 exit≠0"仍在

**复现**
```bash
cd .worktrees/qa-r2 && TMPDIR=$PWD/.qa-tmp MIX_ENV=test \
  mix test --no-compile --warnings-as-errors --seed 1 test/newbee/web/colony_team_api_test.exs
```
实测（两棵树一致）：`Result: 5 passed`，随后 `ERROR! Test suite aborted after successful execution due to warnings`，`exit=1`，警告是 `variable "cid" is unused`。

**影响**：G8 判据"不存在此类分区"仍未达成；dev 只清了 2/5 类警告（`tool_documentation_contract_test.exs:12` 的 `unused import Plug.Conn`、`colony_team_api_test.exs:25` 的 `cid` 仍在）。

**建议**：R3 把这两条各改一行（和本轮已做的两条同性质），G8 即可清零。

## 二、非阻断记录项

### QA2-N1（P2）`mailto:` 在新窗口打开的体验问题（非缺陷）
`app.js` 的 `SAFE_LINK_SCHEME = /^(?:https?:|mailto:)/i`，`colony/md.js` 相同；但 `linkTag` 一律 `target="_blank" rel="noopener"`，`mailto:` 在新窗口打开体验略差。非缺陷，记录。另外 `data:image/*` 被一律拦截（arch 决策 2 已确认，属安全侧收紧，测试用例已覆盖 `data:` 被降级）。

### QA2-N2（P2）`test/newbee/llm/clienttest_test.exs:78-83` 仍用无 scope 的 `interrupt/0` 断言"已置位"
改后仍通过（因为本进程 pdict 位对自己可见），但它**不再验证**"全局可见"这一旧语义；若将来有人把 pdict 位改成"仅 Task 继承"，该用例会误红。建议 R3 改为显式 scope（与 `kerneltest_test.exs` 一致）。

### QA2-N3（P2）静态扫描仍有 13 处"属性位插值未转义"，但逐条复核均不可利用
```bash
cd .worktrees/qa-r2 && node qa-evidence/scan_attr_unescaped.js
```
命中项分三类：① 值来自代码常量（`cls`、`展开/收起` 三元、`changeId`/`groupId` 由后端 id 生成）；② `data-media-id`/`data-cred-id` 来自后端且用于 `querySelector`（`p.media_id` 直接插进选择器，属"选择器注入"而非 HTML 注入，最坏是选不中）；③ `app.js:275` 的 `path` 来自受控正则（`[\\w\\./\\-]+`）。**未发现可利用点**，但建议 R3 一并换成 `escapeAttr`，避免以后有人改正则后失守。

### QA2-N4（P2）继承自基线、本轮未修（已在报告 §3 列明）
`fstest:17`、`archive_test:360`、`goal_steering:64`、`error_contracts:49`、`tool_documentation_contract:8`（能力索引 1941>1800）、`colony_api:252`、`colony_api:328`。两棵树表现一致，非本轮引入。

### QA2-N5（P2）门禁对负载敏感（方法论）
同一 commit 同 seed：`test_fast` 在负载 0.74 时 313 s 全量跑完，在负载 4+ 时出现额外 1 条 60 s 超时（`EventStoreTailTest`）。**必须记录 loadavg 与墙钟**，否则同版本会给出不同答案（R2 基线已记，本轮复现）。

## 三、与 R1 遗留项的关系

| R1 遗留 | 本轮结论 |
|---|---|
| QA-D5（全局中断误伤） | **已修**（即 R2P-02），有 4 条用例 + 反向验证；但引入 QA2-D2 的边界，需 arch 定性 |
| QA-D1（`GateStream` `IO.binwrite` 二次编码） | **不适用**：`grep -rn 'GateStream' lib test` 无结果，代码只在 R1 补丁里 |
| QA-D2（热路径缓存守卫恒真） | 同上，`summary_bytes`/`tamper_equal` 在主干无结果 |
| QA-D3（`@summary_bytes 66` 零触发） | 同上 |
| QA-D4（R1 补丁与主仓库硬冲突） | **R2 侧已解**：`8452293 + 在途 10 文件 + dev-r2.patch` 实测可应用、可编译、定向 86 passed；R1 补丁对 `5ed39a6` 的 3 处冲突仍需 main 裁决基线策略 |
