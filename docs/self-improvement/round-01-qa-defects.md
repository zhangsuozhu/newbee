# 第 1 轮 · 缺陷清单（qa）

- 轮次：R1 · 测试验证
- 被测改动：`dev-r1.patch`（72 文件 +2031/−253，sha256 `f722681a…af4c4`）
- 对照：`.worktrees/qa-r1-base`（纯净 `5ac87ba`）
- 每条都给了：可判定命令 + 实测输出 + 修复验收标准

## 摘要

| ID | 严重度 | 类型 | 标题 | 打回？ |
|---|---|---|---|---|
| QA-D1 | P1 | 新引入缺陷 | 门禁把子进程中文输出写成乱码（双重编码），中文用例名/断言不可读 | **本轮必退** |
| QA-D2 | P1 | 测试假通过 | 热路径缓存守卫恒真：tamper 是 no-op，"不再读盘"未被验证 | **本轮必退** |
| QA-D3 | P2 | 覆盖假象 | 截断逻辑的词边界回退在"首词超预算"时失效；当前预算下零触发故测不出 | R2 修 |
| QA-D4 | P1 | 集成风险 | 补丁与主仓库在途 JS 会话硬冲突 2 个文件，合并顺序未定 | **需 main 裁决** |
| QA-D5 | **P0** | **产品缺陷（预先存在）** | `Client.interrupt()` 的全局回退：一个会话按 Esc 会掐断同 VM 内其它无 scope 会话的流 | **必退（R2 首项）** |
| QA-N1 | — | 未达标 | G4 全量仍有 1 条失败（TlsTest 等待预算），另有 1 次门禁红在 AnthropicTest = QA-D5 | 不打回 dev |
| QA-N2 | — | 未覆盖 | G8 三种子只抽 2/9 分区 | 不计缺陷 |
| QA-N3 | P2 | 口径 | 门禁"零警告"只含编译期；3 条运行时 deprecation 永不计入 | R2 补文档 |
| QA-N4 | P1 | 未修（需授权） | worktree 注册 355 条 / 31 MB，本轮测试再 +44 | 需授权 |
| QA-N5 | — | 未覆盖 | 真机浏览器/行覆盖率/真实模型基准/跨主机未做 | 记账 |

---

## QA-D1（P1，本轮新引入）· 门禁输出乱码

**最小复现**（30 秒，无长跑）：
```bash
cd .worktrees/qa-r1
MIX_ENV=test mix run qa-evidence/probe_encoding2.exs
```
**实测**：
```
DIRECT: 中文测试 直接输出        ← 父进程直写，正常
FORWARDED: ä¸­ææµè¯        ← 经 Newbee.GateStream 转发，乱码
result_valid=true
```
**证据**：`qa-evidence/gate-patched.log` 中 `热路径` / `常驻工具提示` / `源码契约` 三个中文串**均搜不到**（`:binary.match` 返回 `:nomatch`）；dev 的 `gate-verified.clean.log` 同样。

**根因**（实测，不是推断）：`lib/newbee/gate_stream.ex` 的 `IO.binwrite(io, data)` 对 `encoding: :unicode` 的 `:stdio` 会二次编码：
```
binwrite_valid=true content=<<195,164,194,184,194,173,...>>   # "中文"(6B) → 12B
write_valid=true     content="中文 write\n"
```

**为什么 CI 发现不了**：exit code 不受影响；所有 `gate_stream_test` 用例都用 ASCII 输出。

**修复验收标准**：
1. `probe_encoding2.exs` 的 `FORWARDED` 行必须输出 `中文测试`（不得出现 `ä¸­`）；
2. 新增 stream 用例：喂中文（含 `printf '中文\n'` 与多 chunk 场景），断言 `output == "中文\n"` **且** 转发到 `io` 的字节与返回值一致；
3. 反向：把实现改回 `IO.binwrite` → 该新用例必须红；
4. 门禁日志 `grep 热路径` 能命中。

**注意（给 dev 的坑）**：直接改 `IO.write/2` 能修主路径，但 `Port` 把多字节字符切成两个 chunk 时会 `** (Erlang error: :no_translation)`（实测 `<<0xE4,0xB8>>` + `<<0xAD>>` 抛错）。必须处理"未完成的多字节尾巴"，或改用 `:latin1` 设备（实测 `StringIO.open("", encoding: :latin1)` + `binwrite` 输出正确）。

---

## QA-D2（P1）· 热路径缓存守卫恒真

**最小复现**：
```bash
cd .worktrees/qa-r1 && MIX_ENV=test mix run qa-evidence/probe_hot_guard.exs
```
**实测**：
```
file_bytes=80239   newline_newline_count=0   tamper_equal=true
count_before=3     count_after_tamper=3
```
`stale_growth_guard/2` 用 `String.replace(payload, "\n\n", "  ")` 改写文件，而热路径 transcript **不含 `\n\n`** → 改写为 no-op → "命中缓存"与"文件没变"不可区分，断言恒真。

**对照**：冷路径用例是真的（我在 `session.ex` 把 `hit` 强制成 `false` 后，它准确报出 `列表重新扫描了 transcript（计数从 1502 变成 1501）`）。

**修复验收标准**：
1. 热路径也必须是"可等长改写且会改变计数"的守卫（如把某行内容等长替换 + 另一处补空格抵消长度）；
2. 反向：把 `session.ex` 的 `hit` 强制为 `false`（`hit = false`）→ **热路径与冷路径两条都必须红**（当前只有冷路径红，这就是缺陷）；
3. 不得改回全局计数器断言（会把 R1 D9 复活）。

---

## QA-D3（P2）· 截断逻辑"首词超预算"时不回退；且当前预算零触发

**实测 1（零触发）**：`MIX_ENV=test mix run qa-evidence/probe_truncation.exs`
```
entries=20   truncated=0   max_first_bytes=66   max_summary_bytes=66   total_section=1745
```
`@summary_bytes 66` 下没有任何摘要被截断 → 新增的 `truncate_summary/2` + `utf8_prefix/2` 在真实数据上没被执行过。

**实测 2（强制触发后暴露边界 bug）**：把 `@summary_bytes` 改成 20，新测试**准确抓到**：
```
1) test 每条摘要都按字节预算截断，且不在半个词/半个字符处断
   tool.fs 摘要在词中间截断："ng; prefer `Newbee.read/1` for reads."
```
根因：`utf8_prefix/2` 裁到预算后，若 `String.split(head, " ")` 只有一个元素，走 `String.trim_trailing(head)` → 直接输出半个词。

**实测 3（预算参数本身不被约束）**：`@summary_bytes` 改 120 → 新测试仍 3/3 通过（因为没有截断发生），`prompt_section` 仍 1745 B。

**修复验收标准**：
1. 直接测 `truncate_summary/2` 的参数化用例，至少含"首词 > 预算"、"恰好等于预算"、"多字节字符跨预算"三种；
2. 断言 `@summary_bytes`（或等价公开值）与测试里的期望一致，防"改参数悄悄放宽"；
3. 反向：把实现换成 `binary_part(text, 0, max_bytes)`（硬切）→ 必须有红。

---

## QA-D4（P1，集成）· 与主仓库在途 JS 会话硬冲突

```
补丁跟踪文件 ∩ 主仓库 7 个在途文件
  = test/web/conversation-work.test.js
  = test/web/conversation_work_dom.js
```
主仓库当前 HEAD 是 `8452293 (fix/jspace-open-section)`，**`5ac87ba` 不是它的祖先**（`git merge-base --is-ancestor` 判定 NOT_ANCESTOR；两侧各 11/6 个独有提交）。

**请 main 裁决二选一**：
- **A（推荐）**：先合在途 JS 会话 → dev 以其为基线 rebase 补丁（替身语义分叉风险最低）；
- **B**：本循环独占 `test/web/*`，人工合并在途的 269 行新增测试（有丢失风险，不推荐）。

---

## QA-D5（P0，预先存在）· `Client.interrupt()` 全局回退会中断别人的流

**撞到的方式**：第三次门禁复跑 `gate_final_exit=1`：
```
1) test 空流后重发成功：返回正常消息并提示用户 (Newbee.LLM.AnthropicTest)
   test/newbee/llm/anthropic_test.exs:310
   code: assert {:ok, message, usage} = Client.stream_chat(...)
   right: {:interrupted, ""}          ← 用例里没有任何人中断它
```

**确定性复现（30 秒，不靠偶发）**：
```bash
cd .worktrees/qa-r1 && MIX_ENV=test mix run qa-evidence/probe_interrupt_race.exs
```
```
client.interrupt_scope=nil
after_concurrent_interrupt interrupted?=true
stream_chat_result={:interrupted, ""}
```

**根因链**（全在 `lib/newbee/llm/client.ex`，本轮**未改动**该文件）：
1. `Client.new/1` 未传 `:interrupt_scope` → `interrupt_scope: nil`（第 109 行）；
2. `interrupted?/1` 对 `nil` scope **回退全局键** `@interrupt_legacy_key`（第 1057 行）；
3. `test/newbee/llm/clienttest_test.exs:80`（`async: true`）直接 `Client.interrupt()` → 置**全局**位；`test/newbee/dee/kerneltest_test.exs:390` 同样；
4. 任何并行、无 scope 的 `stream_chat` 在 ≤100 ms 内看到 `interrupted?=true` → `Req.cancel_async_response` → `{:interrupted, ""}`。

**"预先存在"的证据**（两树对跑，`qa-evidence/race-matrix.log`）：
| 实验 | 结果 |
|---|---|
| `lib/newbee/llm/client.ex` 两树 `diff -q` | IDENTICAL |
| `test/newbee/llm/anthropic_test.exs` 两树 `diff -q` | IDENTICAL |
| **base** `llm+web` 压测 seed 1 | **509/511 红：AnthropicTest + ChatWireProjectionTest** |
| base 同压测 seed 3 | 510/511 红：CollaborationApiTest |
| patched 同压测 seed 1/2/3 | 511/511 全绿 |
| `anthropic_test` 单文件两树各 6 seed | 18 次全绿（只在并发下红） |
| `llm` 分区两树各 12 seed | 48 次全绿（并发面不够） |

**为什么是 P0 而不是"抖动"**：生产里无 scope 的调用方一旦触发 `interrupt/0`，会中断同 VM 内**所有**无 scope 会话流 —— 即"会话 A 按 Esc，会话 B 的答案被截断"。R1 基线把它归类为 D7「等待预算过短」是**误分类**，pm 的 R1P-07 沿用了这个误判，所以整整一轮都没人修。

**修复验收标准**：
1. 删除 `interrupt/0` / `clear_interrupt/0` / `interrupted?/0` 的全局分支：无 scope 时必须显式报错或就地生成 scope，不允许静默置全局位；
2. `clienttest_test.exs:80`、`kerneltest_test.exs:390` 改为显式 scope；
3. 新增并发守护用例：两条并发 `stream_chat`，只 `interrupt()` 其中一条，断言另一条**正常完成**；反向（删掉 scope 隔离）→ 必须红；
4. 验收：`llm+web` 合并压测 seed 1–3 两树均 511/511，且门禁连续 3 次全绿。

---

## QA-N1（未达标，不打回 dev）· G4 全量 1 条抖动失败

patched 全量 `1768/1769`，唯一失败：
```
1) test 真实网关握手 insecureSkipVerify 接受自签网关 (Newbee.LLM.TlsTest)
   TLS 服务没有起来   ← tls_test.exs:317, receive ... after 5_000
```
**已做的归因**：该文件单跑两树各 3 次 **18 passed ×6**；base 全量未复现；`llm+web` 合并压测时 patched 绿、base 反而红 2 条（`ChatWireProjectionTest`、`AnthropicTest`）→ 属负载敏感的等待预算问题（R1 D7 家族，pm R1P-07 批 B「可顺延 R3」）。
**结论**：`TlsTest` 这条**不是本轮引入**（`client.ex` 与 `tls_test.exs` 两树同源，单跑 3/3 通过），属等待预算过短（`receive ... after 5_000`），归 R1P-07 批 B；但按 G4 文字标准本轮不达标，不得声称 G4 绿。**注意**：本清单里真正的 P0 是 QA-D5 —— 同族「偶发红」里藏着产品语义缺陷，不要把这两条混为一类。

---

## QA-N3（P2）· "零警告"口径需写明

`File.stream!(path, modes, line_or_byte) is deprecated` 出现 3 次，是**运行时**警告；`--warnings-as-errors` 只作用于编译期，因此门禁永远不红。建议在 G1 描述里明确"编译期零警告"，并把运行时 deprecation 单列为 R4 清理项。

---

## QA-N4（P1，需授权）· worktree 泄漏继续累积

```
git worktree list | wc -l  → 355
du -sh .git/worktrees      → 31M
```
R1 基线 204 条 / 17 MB → dev 交付 311 → **本轮 355（+44）**。门禁 preflight 只 `:warn`（阈值 300），不阻断。清理属破坏性且触及共享 `.git`，**需人工授权**；未授权前只做"停止泄漏"（R1P-08 仍在 R3）。
