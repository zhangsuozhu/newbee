# 协作消息调度方案：现状、数据、理论与最终设计

> 日期：2026-09-07
> 性质：调研 + 方案。事实、推论、待验证分开写，不把推论伪装成论文结论。
> 范围：`Newbee.Collaboration.Coordinator` 投递语义 + `Newbee.Web.Session` 队列消费 + `Agent.Loop` 中断边界。不改 Board CAS / DAG / Lead 验收。

## 0. 结论先行（人话版）

1. **保留现在的大骨架**：单写者 Coordinator + 事件先落盘 + `delivery_id` claim/ack + 单会话串行执行 + 忙时不强杀工具。这个是正确性底座，不要动。
2. **不要给每条协作消息配一个 AI 裁判**：它更慢、更贵，还会让不可信的正文获得“喊停”的权力，属于负优化。
3. **要改的是“排队规则”，不是“加裁判”**：
   - 进度/通知：只更新展示，不启动模型（现状已有，保留）。
   - 普通协作聊天/问题：排队，等本轮结束（现状已有，保留）。
   - 任务分派/最终结果（`wake`）：忙时不等整轮，可以“插到下一轮队头”，但不注入当前轮、不杀死当前工具。
   - 打断：只能由可信身份的显式中断发起（Lead/直接父），且只在工具调用结束的安全点生效；正文写得再急也不能升级成打断。
4. **分诊用纯函数，不用模型**：输入是结构化头（kind/delivery/发送者角色/task 状态/board revision/会话忙闲），输出是丢弃/只展示/排队/队头/请求抢占。正文只能降级，不能升级。
5. **先加三个数字再调参**：轮时长分布、协作等待时长（按 kind 分）、过期丢弃率。没有这三个数，任何阈值都是拍脑袋。

---

## 1. 现状事实（源码证据）

### 1.1 投递语义：可靠事件，不是直接函数调用

- `lib/newbee/collaboration/coordinator.ex` moduledoc：`notify` 只进时间线；`queue`/`wake` 投给目标会话运行时，忙时排队，不强行打断当前 turn。
- `@message_kinds`：chat / question / task_assign / task_progress / task_result / artifact / system / error；`@deliveries`：notify / queue / wake。
- 发送路径：`send_message` 先做 `command_id` + `message_id` 幂等检查，落盘 `collab_message_created` 事件后再 `dispatch_message`。语义是 at-least-once + 幂等 effect，不宣称 exactly-once。
- 投递状态机：`delivery_claim` 有 obsolete / duplicate / deliver 三种裁决；`delivery_ack` 要求先 claim 且同 `runtime_id`，否则 `invalid_state` / `delivery_owner` / `obsolete_delivery`。`pending_deliveries` 过滤 consumed/obsolete。
- `dispatch_message` 中 `task_progress` 直接返回，不打扰模型；`queue`/`wake` 在线都走 `Web.Session.collaboration_message`；只有目标不在线且是 `wake` 时，才异步 `ensure` 持久会话并投递。也就是说：**在线时 queue 和 wake 走同一条路，这是当前最大的可优化点**。
- 重启后：`pending_deliveries` 补拉 + Session 启动时 `:pull_pending_deliveries`，`task_progress` 只更新展示不启动新轮次。

### 1.2 会话队列：单 FIFO，忙时阻塞，人能 steering、协作不能

- `lib/newbee/web/session.ex`：`@max_queue_items 128`；`queue` 是 `:queue`，`busy`/`booting`/`kernel==nil` 时 `dispatch_pending` 直接返回。
- 人和协作共用一个等待队列，但协作项用 `delivery_id` 标识（`collaboration_item?`）。
- `handle_cast(:interrupt)`：调 `Loop.interrupt`，清空用户排队项，但保留协作项，当前协作投递重排。测试 `session_queue_test.exs` 明确断言了这一点：“interrupt preserves queued collaboration deliveries and requeues the current one”。
- `handle_call(:take_steering, ...)` 注释原文：“Agent.Loop 在相邻模型请求之间领取普通用户输入；命令和协作项保留到 turn 结束。”`steerable_item?` 只接受 `origin=user` 的 text/images 非命令，协作一律 false。
- 推论：**人的输入可以在一次 turn 内部的两次模型请求之间插进去，协作必须等整轮 `turn_finished` 才消费**。这不是 bug，是故意留的安全口：避免把别人口中的任务混进当前任务的上下文。
- `turn_finished` 后：`finish_current` + `finish_delivery`（成功才 ack，失败/中断重排）+ `dispatch_pending` + 补拉 pending。ack 绑定 `runtime_id`，防止重启后的旧运行时误确认。

### 1.3 信任边界：协作是不可信数据

- 协作转模型输入时带横幅：来源会话、不可信声明、保护栏；任务 JSON 明确标注字段不可信，persona 来自受信 system prompt。
- 设计文档 `session-group-collaboration-design.md` §5.5 / §12.3：peer message 与 system prompt 信任级别不同，不允许覆盖策略/能力/预算，任务结果不能自称已批准合并，注入时用明确来源标记。
- 这意味着：**调度决策不能建立在正文语义上**，只能建立在 Coordinator 已校验的结构化字段上。

---

## 2. 外部数据事实（已联网验证）

### 2.1 Anthropic：多智能体能赢，但很贵，且只适合可分解的广度任务

来源：`https://www.anthropic.com/engineering/built-multi-agent-research-system`（2025-06-13，已拉取正文验证）。

- 架构：Lead 规划 + 并行 Subagents + CitationAgent；子代理独立上下文窗口，并行探索后压缩回传。
- 效果：Lead=Opus 4 + Subagents=Sonnet 4，比单 Opus 4 在内部 research 评测高 **+90.2%**，典型例子是“S&P500 IT 公司全部董事会成员”这类广度优先任务，单代理顺序搜索失败，多代理分解成功。
- 成本：单代理约 **4x** 聊天 token，多智能体约 **15x** 聊天 token。BrowseComp 方差分析：token 用量单独解释 **80%**，再加工具调用数和模型选择共解释 **95%**。
- 教训：无约束时会出现 50 个子代理打简单问题、无尽搜索不存在来源、子代理互相刷屏干扰；解法是 prompt 工程三原则：理解代理心智、教 Lead 如何委派（含目标/格式/工具/边界，否则重复和遗漏）、按问题复杂度定 effort（简单 1 代理 3-10 调用，复杂才多代理）。
- 对本方案的含义：并行收益来自“独立上下文 + 可分解 + 足够 token”，不是来自“消息更快”。接收端是单串行执行器时，加发送端解决不了问题；乱协调反而烧 token。

### 2.2 MAST：失败主因是设计与验证，不是模型不够强

来源：arXiv `2503.13657`《Why Do Multi-Agent LLM Systems Fail?》v3，已验证摘要 + HTML 干预段落。

- 数据：**1600+ 标注 trace，7 框架**，14 种失败模式聚为 3 类：系统设计、agent 间失调、任务验证；人标注一致性 kappa **0.88**。
- 干预：ChatDev 加高层目标验证，ProgramDev 成功率 **+15.6%**；确保 CEO 终裁（修“不守角色”），成功率 **+9.4%**。
- 方法论红线：图 4 只画各系统前 30 条共 210 条的系统内分布，原文明确不做跨系统性能比较。任何跨系统聚合占比都不应引用。
- 对本方案的含义：**独立验证 + 明确终裁权**比“更聪明的拓扑/更快的消息”重要。worker 只能 submitted、Lead 结构化验收、调用方不能自带 attestation，这套门要保留；协作调度同样需要“终裁只能来自可信身份”。

### 2.3 间接提示注入：数据和指令的边界必须用机制保证

来源：arXiv `2302.12173`《Not what you've signed up for... Indirect Prompt Injection》，已验证摘要。

- 结论：LLM 应用模糊了数据与指令边界；检索到的数据可以充当任意代码执行、操纵 API 调用；当时尚无有效通用缓解。
- 对本方案的含义：协作者正文 = 外部检索数据。**让正文决定是否打断，等于把中断权交给不可信输入**，是典型的间接注入放大器。调度权只能给结构化头 + 身份 + 权限。

### 2.4 存疑数据（本次不采用）

- 内部文档提到的 “Towards a Science of Scaling Agent Systems：260 配置x6 基准x5 架构x3 模型、+80.8% 到 -70.0%、tool-heavy 协调惩罚 beta=-0.096、R2=0.373” 未能在 arXiv 检索到同名论文，**本次列为待验证，不作为方案依据**。需要时应先找到原文再引用。

---

## 3. 理论依据（为什么这样设计）

1. **Amdahl 定律（1967）**：加速比上限由串行部分决定。单 Session 的 Loop/工具链就是串行部分 S。给每条消息加裁判会增大 C(n)（协调成本），S 不变时整体更慢。正确方向是缩短 S（更快结束本轮）或在安全点让路，而不是在 S 外面再串一个裁判。
2. **单服务台排队 + 队头阻塞（HOL blocking）**：单 FIFO 下，一个长 turn 会挡住后面所有 wake。这是当前唯一真实的延迟痛点。解法是优先级 + 老化，不是抢占执行器。优先级必须有界，否则低优先级饿死；饥饿用 aging 解决（等越久优先级越高）。
3. **优先级反转（Mars Pathfinder 经典教训）**：低优先级持有锁，高优先级等待。我们的“锁”就是当前 turn。解法是优先级继承/上限 + 有界临界区，而不是任意杀死持有者。对应到这里：工具调用是临界区，不杀；LLM 请求间隙是可让点，可以 steering。
4. **混合主动性原则（Horvitz）与中断科学（McFarlane；Monsell 任务切换代价）**：中断要考虑不确定性、效用和时机；协商式/延迟式中断优于立即打断；打断有认知残留成本。对应到这里：协作打断默认走“请求-协商-在边界生效”，只有可信中断才走“尽快在安全点生效”。
5. **at-least-once + 幂等是分布式现实解**：发送方重试、Coordinator 去重、接收方按 `delivery_id` 去重、claim/ack 分离、过期判断。claim 只能在真正要启动前做，ack 只能在成功后做，崩溃不提前确认。这是现状已做对的部分，方案不得退化。
6. **最小权限 + 显式身份**：中断、模型切换、工作区应用都是高风险副作用，必须走权限审批/可信身份，不能走正文情绪。

---

## 4. 为什么“每条消息一个 AI 裁判”是负优化（算账）

设裁判一次调用延迟 `Tj`（含取上下文），本轮剩余时间 `Tr`。

- 若 `Tr < Tj`（短轮常见），等本轮比问裁判更快。问裁判纯属加延迟。
- 若 `Tr >> Tj`（长工具调用），裁判再快也救不了，因为真正该等的是工具临界区，杀掉工具的代价是重做 + 副作用不可逆 + lease/attempt 错乱。
- 成本：每条协作消息多一次模型调用。Anthropic 数据下多智能体已是 15x token，再叠裁判是火上浇油；且 `wake` 高频时裁判自己会成为第二个 Coordinator 瓶颈（Coordinator 要求单回调内完成 revision 检查 + waiter 注册，绝不能塞 LLM 调用）。
- 安全：裁判把不可信正文变成控制决策，攻击者用一句话即可 DoS（让所有任务反复中断）。规则用不可伪造字段（kind/delivery/角色/权限/revision/attempt），裁判看的是可伪造字段，此消彼长。
- 可验证性：纯函数分诊可单测、可审计、可回放；LLM 裁判不可复现，线上出问题无法定责。

允许的例外只有一种：**离线批量归纳**（把 10 条闲聊合并成 1 条摘要、建议降级），且无权升级为打断，超时默认等。

---

## 5. 最终方案：三档 + 双通道 + 纯函数分诊

### 5.1 不变量（不动）

- Coordinator 单写者、EventStore 先落盘、revision CAS、DAG、worker 只 submitted、Lead 验收、attestation 不可自带。
- claim 在启动前、ack 在成功后、失败/中断重排、过期变 obsolete、重启补拉。
- 中断保留协作、清空用户排队、当前投递重排（已测试行为）。

### 5.2 消息三档（按头，不按正文情绪）

- **A 档：只展示，不启动模型**：`notify`、`task_progress`、artifact 分享、过期/重复投递。现状已对，保留。
- **B 档：排队，等本轮结束**：普通 `chat` / `question`（`delivery=queue`）。FIFO + 去重 + 合并（同 sender 同 task 短窗合并）。
- **C 档：下一轮队头，不进当前轮**：`task_assign` / `task_result` / 高可信 `question`（`delivery=wake` 且在线）。**这是本次唯一的行为变更**：在线 wake 不再和 queue 完全同权，而是取得“下一轮优先权”，但仍不注入当前轮、不杀工具。

为什么 C 不直接 steering 进当前轮：当前轮属于另一个任务，把新任务正文塞进当前上下文会造成跨任务污染，且 claim/ack 生命周期会被打乱（steering 成功不代表任务成功）。队头是正确折中。

### 5.3 中断两通道（显式、可信、可审计）

- **控制通道**：`Hive.interrupt`（Lead/直接父，lookup pid 校验）。语义不变：在工具边界尽快生效，协作重排，用户排队清空。
- **请求通道**：新增 `request_preempt`（结构化原因 + 相关 task/revision/attempt）。只产生一个 C 档队头项 + UI 徽标，不直接杀 turn。是否提前结束当前轮，由 Session 在下一个 LLM 间隙按确定性策略决定，例如：当前任务的依赖已失败/任务已 obsolete/收到同 task 新 attempt 时允许早停，否则跑完本轮。
- 正文中的“快停下”“十万火急”：**一律视为 B 档**，最多加 UI 未读徽标，不得进入请求通道。

### 5.4 分诊函数（纯函数，O(1)，可单测）

```
triage(headers, session_state) ->
  :drop | :display_only | :enqueue | :enqueue_head | :request_preempt
```

- 输入只用：kind / delivery / sender 角色与成员资格 / 是否 Lead/父 / task_id+attempt+board revision / session 忙闲 + 当前 task / 队列长度 + 频率预算。
- 正文只用于 preview/展示和离线合并建议，不得改变分诊结果的方向（只能同档内合并，不能跨档升级）。
- 所有升级（B->C，C->request_preempt）必须有可信身份或显式控制调用背书，否则拒绝并记审计事件。

### 5.5 抗 DoS 与有界性（沿用现状并补齐）

- 保留：`@max_queue_items 128`、成员/任务/spawn/depth/fork 上限、验收项/argv 上限、command_id/message_id 幂等。
- 补齐：按 sender 的 wake 频率预算（例如沿用设计中的 auto_wake_per_minute=20 思路，先度量再定值）、同 task 短窗合并、过期 perception（`delivery_obsolete?` 已有，调度时提前判断避免入队）。
- Coordinator 回调内永不做网络/模型调用；`wake_persisted_session` 保持异步 Task，避免自调用死锁。

### 5.6 可观测（先加，再调参）

- turn 时长直方图（按 kind：text/images/collab_task/collab_message/collab_result）。
- 协作等待时长（入队到 claim，按 A/B/C 分）。
- claim 结果比（deliver/duplicate/obsolete）、ack 成功率、重排率、中断次数与来源。
- 队头插队次数与 aging 生效次数、合并条数、频率限流触发次数。
- 目标：先跑一周看基线，再定 C 档是否需要 aging 上限、B 档合并窗口、request_preempt 早停条件。没有基线不准调阈值。

---

## 6. 最小实验（按顺序，每步可回滚）

1. **只加指标，不改行为**：上述 6 组计数 + 日志采样。验证：现有测试全过 + 新指标有数据。
2. **只做 C 档队头**：在线 wake 在 claim 前具备下一轮优先权；queue 不变。验证：`session_queue_test` 扩展（wake 越过 queue 用户项，但不越过当前 turn；中断语义不变；claim/ack 不变）。
3. **只加 request_preempt 请求通道**：不加自动早停，先只做到队头 + 徽标。验证：伪造正文无法触发早停；Lead 控制中断仍走老通道。
4. **可选：离线合并器**（独立进程，批量 2-5s 窗）：只合并 B 档闲聊展示，不参与分诊。验证：合并错误最多影响展示，不影响任务状态机。
5. **暂不做**：每消息 LLM 裁判、协作 steering 进当前轮、工具中途强杀、第二套 group/board。

---

## 7. 风险与未证明事项（诚实标注）

- 未证明 Hive 能提高真实仓库任务 solve rate；未证明 token 成本下降；wait 只消除了轮询。
- 验收只覆盖声明的 command/file 检查，不能证明高层产品目标；command 会执行项目代码，不是沙箱。
- Board revision 不冻结文件系统；attestation 只证明检查时刻的观察，不证明此后未被改。
- 本方案的 C 档队头在极端 wake 洪流下仍可能饿死 B 档，需靠频率预算 + aging + 指标来兜底，具体阈值待基线数据。
- 扩展性论文数字本次未验证通过，不作为依据；如需引用必须先找到原文。

---

## 附录：证据索引

- 现状语义：`lib/newbee/collaboration/coordinator.ex`（moduledoc + send/claim/ack/pending + wake 异步恢复）、`lib/newbee/web/session.ex`（dispatch_pending/take_steering/steerable_item/interrupt/collaboration_item/requeue）、`test/newbee/web/session_queue_test.exs`（去重/中断保留协作/排队）、`docs/session-group-collaboration-design.md`（notify/queue/wake + 不可信输入）、`docs/collab-v2-analysis.md`（审计口径：事实/实证/推论/假说分离）。
- 外部：Anthropic Research 多智能体报告（2025-06-13）、MAST arXiv:2503.13657（摘要 + HTML 干预段）、间接提示注入 arXiv:2302.12173。
- 理论：Amdahl 1967；单服务台 HOL 阻塞；优先级反转与优先级继承；Horvitz 混合主动性；McFarlane 中断方式比较；Monsell 任务切换代价；at-least-once + 幂等 effect。
