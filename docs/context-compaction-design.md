# 上下文窗口压缩设计与 Codex 对比

状态：调研完成，待实现与验证
日期：2026-02-14

## 1. 结论

newbee 已经具备比 Codex 更强的持久化档案基础：transcript 追加写、段文件 SHA 校验、compactions 账本、确定性事实抽取、history:// 回读和摘要补写。Codex 的主要可借鉴点不是替换 Archive，而是补齐压缩时机和运行时状态语义：把压缩原因分型、在请求前与请求中分别处理、压缩请求失败时有界重试、并在压缩后重新计算 token 使用量。

本次拟做的最小改进：
- 将自动压缩的触发口径从单一的请求估算升级为带预算余量的 pre-request 检查。
- 为自动压缩增加 context pressure 的结构化原因与结果，避免把手动和自动语义混在 trigger 字段里。
- 压缩后再次检查请求预算；若摘要或恢复提醒本身仍超预算，继续推进切点而不是立即发送超长请求。
- 保留 newbee 的无损 Archive 设计，不引入 Codex 的销毁式替换历史。

## 2. Codex 方案

### 压缩算法

Codex 在 compaction turn 中把当前历史连同压缩指令发送给模型。模型输出 handoff summary，随后构造 replacement history：保留可识别的 user messages，并追加带 SUMMARY_PREFIX 的摘要。原始 rollout/history 仍可用于审计和 fork；活动 prompt 使用替换后的紧凑历史。不同 provider 还支持 local、remote compaction。

它不是简单按字符截断。ContextWindowExceeded 时，Codex 从历史最前端逐项移除并重试压缩请求，尽量保持近期消息；普通网络错误使用 provider 的最大重试次数与 backoff。压缩成功后会 recompute token usage，并记录 compaction window、reason、phase 和 analytics。

### 压缩时机

Codex 的时机有三层：
1. pre-turn：在新一轮采样前按模型 context window 和 token budget 决定是否自动压缩。
2. mid-turn：工具调用或多步响应使上下文超过窗口时，在当前 turn 内压缩，然后继续执行。mid-turn 会重新注入必要的初始上下文，保证模型仍能看到当前任务基线。
3. manual：用户显式 compact，使用独立的 compaction turn 和 UserRequested reason。

因此，压缩发生在请求发出前是正常路径，真正超限是兜底路径；两者不能只靠一个阈值表达。

### 失败与恢复

Codex 对中断、预算耗尽、上下文超限和普通传输错误区分处理。压缩请求超限会缩短输入后重试；普通错误有限重试；不可恢复错误向上报告。压缩后的 replacement history 与 compaction metadata 一起持久化，恢复和 fork 会识别 compacted item，避免把旧摘要或已解决的父代理提示重复注入。

## 3. newbee 当前方案

`Newbee.Agent.Loop.maybe_auto_compact/2` 在每次请求前通过 `ContextBudget.assess/2` 计算序列化输入、协议开销和输出预留；达到 soft/hard 水位后调用 `Archive.compact/2`。有 Session 时，Archive 以 `[prev_cut, new_cut)` 归档原始 transcript，生成确定性 facts，并可用 LLM 为新段生成一次 digest；视图是 digest/facts 加切点后的原文。无 Session 时才退回内存摘要并丢弃旧消息。

当前优点：
- 压缩前时机明确，避免先发送必然超限的请求。
- Archive 具备原文可回读、校验和崩溃安全语义。
- digest 只对原始段生成一次，避免摘要的摘要不断失真。
- RequestEnvelope 支持在相同 route 下复用请求前缀缓存。

当前风险：
- `estimate_request_tokens` 使用 JSON 字节数除以 3 加固定 2000，未把模型输出预留、工具结果增长和压缩后新增系统提醒分开计算。
- `compact_state` 只在请求前运行；如果实际 provider token 估算更大或工具结果在 turn 内膨胀，没有独立的 mid-turn 兜底状态。
- 自动压缩用 `retain_target` 的数值大小区分 trigger，导致 trigger 语义间接编码在保留预算中。
- Archive 失败后的 ephemeral fallback 能继续运行，但会绕过无损视图，且没有把失败原因结构化返回给调用方。
- 压缩结果加入摘要系统消息后没有再次验证整体压力，可能在很小的 context window 或超长 system 基底下再次接近上限。

## 4. 设计方案

### 4.1 时机与预算

在每次向 provider 发请求前执行 `ContextBudget.assess/2`，至少区分：
- `:normal`：估算输入加输出预留低于 soft limit，直接请求。
- `:pre_request`：达到 soft limit，先压缩旧段并重新估算。
- `:hard_limit`：压缩后仍超过 hard limit，继续推进可归档区间；没有可归档内容时返回结构化错误。
- `:mid_turn`：已有 turn 的工具/响应增量使预算越过 hard limit，在继续下一次模型请求前压缩，并保留当前 turn 必需的最后用户消息与任务基线。

预算应由 context window、输出预留、system/base instructions、当前消息估算和压缩提示开销组成。soft limit 只负责提前触发，hard limit 负责兜底，不能用输出 token 上限替代输入窗口。

### 4.2 算法与状态

继续以 Archive 为事实源。每次压缩先规划切点，再原子写 segment，最后追加 compacted ledger event；LLM digest 失败不阻断归档。视图装配后计算实际估算压力；若仍超 hard limit，在同一请求前继续压缩下一段。每次压缩记录 reason、phase、pressure_before、pressure_after 和结果状态，便于诊断重复压缩或压缩无效。

摘要输入采用结构化 handoff 提示，必须覆盖目标、关键决策、改动/验证、未完成事项和约束。确定性 facts 始终独立保留，摘要不能成为唯一事实来源。

### 4.3 失败语义

压缩失败分三类：
- 可恢复：digest 或 provider 临时失败；保留已归档段，视图使用 facts/占位 digest，并允许下一轮补写 digest。
- 预算恢复：压缩请求本身超限；缩短输入或推进切点后重试，并限制循环次数。
- 不可恢复：没有可归档消息仍超 hard limit；返回错误/事件，不再递归 fallback。

## 5. 非目标

本次不重写 Archive、不改变 history:// 协议、不引入新的模型可见工具、不做 provider-specific remote compaction，也不修改 Codex 源码。

## 6. TODO

- [x] 阅读 Codex compaction、提示词、压缩任务和相关快照测试。
- [x] 阅读 newbee Loop、Archive、Session 及现有压缩测试。
- [x] 记录压缩时机、算法、失败语义的对比结论。
- [x] 在独立 worktree 实现 `ContextBudget.assess/2` 本地预算检查。
- [x] 增加预算 soft/hard、输出预留和序列化估算测试；Archive 回归测试通过。
- [ ] 增加完整 Loop 集成测试覆盖压缩后仍超限和 mid-turn 入口。
- [x] 结构化发出压缩 reason/phase/pressure 前后值事件并写入 debug log。
- [ ] 运行格式化、编译和相关测试，再运行完整测试。
- [ ] review diff，提交分支，创建 PR，按仓库保护规则 squash 合并远程 main。
- [ ] 合并后同步本地 main，并确认工作区原有用户改动未被覆盖。
