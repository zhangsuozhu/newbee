# 会话卡顿调查

> 取证窗口：2026-09-08 13:20–13:42（本机时区）。范围限定为当前仓库代码、当前父/子会话的结构化事件，以及明确相关的全局快照锁元数据。未重启服务、未 kill 运行服务、未清理全局锁，未读取其他会话 transcript 正文。

## 结论

目前有两条独立原因，不能把同一条提示当成同一种故障：

1. **已证实的正常历史修补 bug**：`done` 的 assistant 摘要先于它自己的 tool 响应落盘。下一次提交或恢复时，历史修补器把这看成悬空 tool call，生成“该工具调用因进程重启/中断未完成，结果已丢失”占位，并丢掉实际的 `✓ done`。这条路径无需进程崩溃即可触发，因而该提示本身不是 crash 证据。
2. **已证实的真实锁泄漏路径**：13:20 的回合在 `Edit.show` 运行期间被中断。`Edit.show` 会写快照而非纯读；中断会硬杀 evaluator cell，跳过快照锁的 `after` 清理，遗留 `ecf9d79a.lock`。之后的 `Edit.show` 等待 30 秒并抛出锁超时。这个锁故障会让使用同一有效 cwd 的后续编辑读取反复卡住。

长 LLM 回合会放大体感：日志中有 133–816 秒的 turn，用户通常会在等待期间中断；这解释了为什么锁泄漏和“工具结果丢失”会连续出现，但不是上述 done 占位的必要条件。

## 生产证据

### 13:20 中断与锁

- 父会话 transcript `/home/alanx/.newbee/sessions/20260908-124112-30dd.jsonl:156` 在 13:20:15 写入一个 `run_elixir` assistant tool call；该调用的安全摘要显示调用了 `Edit.show`。同一调用没有匹配的 tool result；下一条用户消息在 `:157`，后续调用/结果位于 `:161–163`。
- 统一事件 `/home/alanx/.newbee/events.jsonl:51401` 是 13:20:15 的 `tool_start`；`51402` 在 13:20:20 是 `interrupted`；`51403` 同时是 `turn_end`。该调用序列没有 `tool_result`。安全摘要只保留事件主题和字符串长度，没有保存请求正文。
- 调试日志同一窗口记录：13:20:15 `tool start`；13:20:20 `eval interrupted`、`done run_elixir in 5343ms`。之后 13:20:53 出现父会话的 standby peer，13:21:01 记录 standby up，说明 evaluator 进入了恢复路径；没有同窗口的 kernel owner-down 记录。
- 锁元数据读取结果：`/home/alanx/.newbee/edit_snapshots/ecf9d79a.lock` 在 13:20:18 存在，大小 13 字节，内容只有 BEAM 内部 PID `<0.851.0>`，没有密钥；之后 13:21:35 仍阻塞到超时。该 hash 对应 cwd `/home/alanx/data/git/newbee`，而不是本子会话 workspace（父 workspace hash `5ae95a88`、本 workspace hash `ea1e17bc`）。这证明当时调用的有效 cwd 是主仓库；究竟哪个 evaluator 持锁无法由跨 BEAM 节点的内部 PID 单独确认。
- `/home/alanx/.newbee/events.jsonl:51408–51410` 对应 13:21:05 开始、13:21:35 `tool_error`/`tool_result`；错误字符串包含精确的 `snapshot store lock timeout`。调试日志也记录该调用耗时 30616ms 且 status=error。13:42:14 再查时锁文件已不存在；删除者和确切删除时刻未记录。

### done 提示不是 crash 证明

- 父/子 transcript 在调查时都没有精确等于该中文占位内容的 tool 消息；因此不能用 transcript 中出现源码片段或错误输出中的这句话，反推一次真实重启。
- 当前代码的 `lib/newbee/agent/loop.ex:612–617` 每个新回合开始都会先调用 `repair_history/1`。`lib/newbee/agent/loop.ex:1480–1509` 的 `done` 分支先在 `1497` `push_msg(done_msg)`，再在 `1509` `push_msg(tool_msg)`；于是落盘顺序是 `assistant(tool_calls=done) → assistant(done=true, summary) → tool(✓ done)`。
- `lib/newbee/agent/loop.ex:1591–1623` 遇到悬空 assistant 的普通分支（`1618–1619`）会补占位并清空 pending；随后真实 tool 在 `1609–1610` 因 id 已不在 pending 中被丢弃。占位内容来自 `loop.ex:1641–1644`。
- `lib/newbee/llm/client.ex:1097–1103` 每次 Chat 请求前也调用 `fill_tool_placeholders/1`；`client.ex:1228–1271` 具有相同逻辑，中文占位位于 `client.ex:1230`。所以同一历史即使没有重新启动，只要进入下一次请求，也会出现该提示。
- `lib/newbee/session.ex:171–210` 的 `seal_pending_tools/1` 只在扫描结束后仍有 pending id 时写入另一种 `outcome_unknown` recovery 消息。done 的真实 `tool` 虽然位置错误但仍存在，扫描会先后看到它并清除 id，因此这里不会替该顺序 bug 生成 recovery 消息。

## 锁泄漏机制

- `lib/newbee/tools/edit.ex:373–386` 的 `show/2` 最终进入 `show_range/2`；`edit.ex:456–466` 读文件后调用 `SnapshotStore.record/3`，所以 `Edit.show` 会写共享快照。
- `lib/newbee/tools/edit/snapshot_store.ex:174–185` 以 `File.cwd!()` 的前四字节 hash 选择项目锁；`snapshot_store.ex:195–210` 用 O_EXCL 文件创建锁，在 `try ... after` 中于 `208` 删除。
- `snapshot_store.ex:219–236` 的陈旧判断是 mtime 超过 `@lock_stale_ms=120_000` 才删除，获取上限是 `@lock_timeout_ms=30_000`。注释 `199` 仍写“30s 自动可抢”，与真实 120s 不一致；而且没有竞争者时陈旧文件会一直留着。
- evaluator 取消链是可核验的：`lib/newbee/agent/loop.ex:95–125` 设置会话中断并调用 evaluator；`lib/newbee/dee/evaluator.ex:195–200` 取消当前 job；`lib/newbee/dee/evalworker.ex:177–180` 用 `Process.exit(runner, :kill)` 杀 runner。cell task 的资源清理在 `evalworker.ex:313–330` 的 `after`，但 task 在 `333` 被 unlink；owner watcher 在 `423–447` 监控 owner 退出并再次 `Process.exit(task_pid, :kill)`。硬杀不执行 Elixir `after`，因此快照锁的 `File.rm/1` 不会运行。
- `lib/newbee/dee/eval_guardian.ex:33–60` 还会在取消后 1 秒升级，必要时杀 primary peer；`evaluator.ex:342–352` 也会在 deadline 杀 job/隔离 primary。这些路径都不能依赖被杀 cell 的 finally 清理。
- 当前源码没有证据表明 `SnapshotStore.record` 在一次正常调用内部自锁重入：`with_store/2` 只调用一次 `with_file_lock/2`，正常临时复现可成功写 `.term` 并释放锁。已证实的是硬杀后的 stale lock，而不是 self-deadlock。

## 最小复现

所有以下实验都使用唯一 `/tmp` project/global 目录，结束后删除；没有修改仓库或全局锁。

1. **客户端纯内存复现**：输入三条消息 `assistant(tool_calls=done) → assistant(done=true, 非空 summary) → tool(✓ done)`，当前加载的 `Newbee.LLM.Client.sanitize_messages/1` 输出 `assistant(tool_calls) → tool(中文占位) → assistant(done=true)`；实际 `✓ done` 被丢弃。
2. **真实 Loop 同进程复现**：临时 evaluator stub + 假 client。第一次 `submit` 和第二次 `submit` 都返回 `{:done, "summary"}`。第一次状态是 `assistant(tool_calls) → assistant(done=true) → tool(✓ done)`；第二次提交后，第一次历史变为 `assistant(tool_calls) → tool(中文占位) → assistant(done=true)`，第二次 done 仍正常。证明无需重启。
3. **真实 Loop 重启复现**：第一次 done 后正常停止并用同一 session id 重建 Loop，恢复状态同样出现占位和 done 摘要，真实 `✓ done` 消失。
4. **锁正常路径**：临时 `SnapshotStore.record/3` 成功，`.term` 存在且 `lock_exists_after=false`。
5. **锁 stale 路径**：临时锁 mtime 设为 2020 年，下一次 `record/3` 自动抢占并成功，锁不存在。
6. **锁活跃路径**：临时新鲜锁会让 `record/3` 自然等待 `30004ms`，抛出 `RuntimeError: snapshot store lock timeout`，且超时后锁仍存在。该结果与生产 13:21:35 的 30 秒错误一致。

## 运行时代码核对

当前调查 DEE 的 `:code.which/1` 指向共享构建目录 `/home/alanx/data/git/newbee/_build/dev/lib/newbee/ebin`，而非本 workspace 的 source tree。`beam_lib` abstract code 直接核验到：

- loaded `Newbee.Agent.Loop.repair_history/1` 行 1591，含中文占位；
- loaded `SnapshotStore.with_file_lock/2` 行 200 的整数常量含 30000，`do_acquire_lock/2` 行 212 含 10 和 120000；
- loaded `LLM.Client.loop/7` 行 873 含 100 和 300000；
- loaded BEAM mtime 是 2026-09-07，而本 workspace 三个 source 文件 mtime 是 2026-09-08 13:23:48。也就是说不能只凭 source 推断线上版本；本次 loaded AST 与生产日志的行为一致，但父服务是否另有 hot reload 未通过 RPC 直接确认。

长回合的实现边界也已核对：`lib/newbee/llm/client.ex:417` 的首响应 receive timeout 为 120s，`client.ex:907` 的 SSE 空闲/总计检查使用 300s；Web 会话 `lib/newbee/web/session.ex:1453` 的 turn watchdog 是 1,800,000ms（30 分钟），启动位置为 `web/session.ex:2810`、`:2864`。近期 debug.log 只筛选 tag、耗时、消息数和状态，未读取完整模型请求。

## 证据等级与未证实项

### 已证实

- done 顺序 bug 可在同一进程和恢复后稳定复现。
- 13:20:15 的 tool 调用被真实标记为 interrupted；13:20:18 有对应 hash 的锁；13:21:35 后续调用真实锁超时。
- 当前锁实现依赖 hard-kill 不会执行的 finally；陈旧锁只能在竞争者轮询时被抢占。
- 当前 loaded BEAM 含任务描述所指的占位与锁常量。

### 未证实或仅为高可信推断

- 13:20 中断的外部起因是用户 Esc、宿主工具中断，还是 BEAM/节点重启：事件只明确记录 `interrupted`，没有 crash stack。
- `<0.851.0>` 的确切 owner、是否为 primary cell，以及最终删除锁的进程：跨节点 BEAM 内部 PID 不足以映射到 OS 进程。
- 父服务是否与当前调查 DEE 100% 使用同一 hot-loaded module：当前 loaded AST 与日志相符，但没有对父服务做远程代码查询。
- 这次全部“卡死”是否都来自快照锁：长 LLM 请求、provider 连接/首 token 等也会造成长等待；快照证据只覆盖反复 `Edit.show` 的 30 秒阻塞。

## 最小修复建议（本阶段未实施）

1. **先修 done 顺序**：在 `loop.ex:1480–1509` 先 `push_msg(tool_msg)`，再落 `done_msg`；增加同进程第二次 submit、正常恢复、以及 `Client.sanitize_messages/1` 的精确顺序回归测试。这样“正常 done”不会再伪装成中断。
2. **补锁回归与清理语义**：增加 evaluator cell 被 hard-kill 后锁可恢复的测试；至少把注释从 30s 改为真实 120s，并让锁错误携带可诊断的 owner/node/mtime 元数据而不含请求正文。更稳妥的长期方案是使用进程死亡自动释放的 OS advisory lock，或带心跳/明确租约的跨节点锁，避免把 `File.rm` finally 当作 hard-kill 保证。
3. **缩短故障放大**：对锁等待提供可识别的 busy/短超时结果，并让 `Edit.show` 的快照写入失败时保留明确的非持久 tag 语义；不要静默把读工具卡 30 秒。具体 API 变化需 Lead 先批准。
4. **固定 cwd 和观测身份**：执行工具前强制使用会话 workspace，避免主仓库 `ecf9d79a` 锁被多个运行时共享；DebugLog 的 tool start/end 记录 session id、锁 hash、耗时和状态摘要，但不记录密钥或完整请求。
5. **恢复流程保持单一语义**：中断后的真实悬空调用继续由 `Session.seal_pending_tools/1` 生成 `outcome_unknown`；历史修补器应识别并保持 `done=true` UI 摘要与 tool 响应的合法顺序，避免同时出现两种占位协议。

本报告只新增 `docs/session-stall-investigation.md`；未修改运行代码、测试或其他会话文件。未运行 `mix test`，复现证据来自当前 loaded BEAM 的内存/临时路径实验和只读日志分析。

