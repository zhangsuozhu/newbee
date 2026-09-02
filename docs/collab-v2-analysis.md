# 多任务协作深度调研报告 (2026-09-02)
## 来源: codex-rs 源码 + deepseek-harness 源码&决策笔记 + arXiv 论文

============================================================
第一部分: 三个系统的事实画像
============================================================

## A. OpenAI Codex (codex-rs, Rust) — "企业级会话树"

### 核心抽象
- ThreadId + AgentPath ("/root/aaa/bbb" 路径式寻址), 层级树
- AgentControl: 每棵 root 会话树一个控制平面, 全局共享
- AgentRegistry: 限额(总子代理数, spawn 深度), SpawnReservation 令牌
- InterAgentCommunication 协议消息: {author, recipient, other_recipients, content, trigger_turn}
  → 极简! 只有"发给谁、是否唤醒", 没有任务/租约/版本概念
- v1 工具: spawn_agent / send_input / wait / close_agent / resume_agent
- v2 工具: spawn_agent / send_message / followup_task / wait_agent / interrupt_agent / list_agents
  - send_message(quiet) vs followup_task(wake) 分离
  - wait_agent = 阻塞等 mailbox 边缘事件(非轮询)
  - interrupt_agent = 打断 turn 但保留 inbox
- 角色(role)系统: TOML 配置 agent_roles, 可覆盖 model/reasoning/personality/skills/features
- 委派(delegate): 强制 approval_policy=never, fork 可截断历史(fork_turns)
- usage hint 注入: root 与 subagent 看到不同提示文本, 明确"你们都同等智能"
- 协作工具**故意不进 functions.exec** namespace — 防止模型在沙箱代码里间接 spawn

### 优势
1. 协议极简, 语义正交 (send/followup/wait/interrupt 四元组完备)
2. 深度+总量双重限额, 防递归爆炸
3. wait_agent 是事件驱动边缘触发, 不是轮询 → token 高效
4. fork_turns 让上下文继承可调 (none/N/all)
5. 消息有 encrypted_content 选项 (加密转发)
6. approval=never 硬约束 → 子代理永不卡住等人

### 劣势
1. 无持久任务板: 没有 task/DAG/revision, 任务全靠消息流承载 → MAST 的 verification/termination 失败无解
2. 无黑板: 共享状态只能靠 root 自己攒, 无 CAS
3. 层级树严格 parent→child, 无 peer 寻址 (AgentPath 能表达但工具未暴露)
4. 单进程单租户, 跨进程要靠 app-server
5. close_agent 要求模型显式回收, 泄漏风险靠限额兜底

## B. DeepSeek Harness (TS monorepo) — "工程纪律教科书"

### 核心抽象
- capability seam 三件套: Service Definition / Service Provider / Consumer
  → ctx.subagents 是注册表, 多 provider 共存 (in-process/fork/ACP/codex/claude-code)
- SubagentRun: 一次激活; Activation: 一次驻留纪元; Session: 持久会话 — 三者生命周期严格区分
- Continuable child: durable Session + ≤1 process-local Activation
  → followup() 冷恢复: 不在内存就从持久 Session 冷启动
- report 工具: 子→父**单向义务**, {output} → {messageId}, 非终态, 可重复, 只跨一条边
- Agent Teams: 隐式 Lead=root, 平铺 roster, kebab-case 名字
  - team/member 预配快照 (provisioning→active/failed 两阶段落盘)
  - 共享任务板: 全量快照 + 单调 revision + CAS (expectedRevision) + DAG 依赖
  - writeScopes: 路径前缀只做**重叠诊断**, 不做锁 ("假互斥比明示警告更危险")
  - mailbox: Lead 会话是事务主场; quiet 邮件不物化目标
  - wait_agent: 边缘触发阻塞, 醒来必须重读权威状态

### 优势
1. 生命周期三层分离 (Task/Run/Session/Activation) — 每个概念恰好一个职责
2. 一切协调状态 durable + CAS, 崩溃可恢复, HMR 不丢
3. 失败语义明确: 每个错误有唯一 code, 恢复路径可证明
4. "同一世界"共享 checkout + writeScopes 诊断 → 务实, 不假装能做锁
5. 决策笔记驱动开发 (每个设计点有 alternatives-rejected 档案)
6. report 义务化 (子代理必须汇报, 但不终结自己)

### 劣势
1. 复杂度极高: 仅 subagent 域就 11 个包, 认知负担重
2. Teams 仍是 experimental, 名字永不复用 (失败耗名额)
3. 事件溯源+快照的写放大明显 ("Lead Session grows with whole snapshots")
4. 对模型要求苛刻: 工具 result 全 schema 化紧凑 JSON, 模型必须精准
5. 进程内为主, 跨进程 ACP 的 continuable 仍是 future work

## C. newbee 现状 (Elixir/OTP) — "OTP 原生的潜力股"

### 现状
- Coordinator: GenServer 单写者 + EventStore(JSONL) 事件溯源, 崩溃重放
- Delegator: workspace(文件系统副本隔离) → session → 事件 三步, 失败补偿
- Capability token: Agent.Loop 签发短时令牌, 防冒充
- 消息: notify/queue/wake 三种 delivery, 先落盘再调度
- 任务: lease(5min)+renew, 状态机 accepted/running/.../succeeded/failed
- 子代理由 Web.Session 拉起, prompt 注入任务+acceptance+report义务, 标注"不可信数据"
- 隔离: 默认文件系统副本, 完成 review+apply patch (有 sha256 校验)

### 优势(相对另两者独有)
1. **OTP 进程模型天然契合**: 每个子代理是真进程, 监督树崩溃自愈, 不需 harness 那套手工 Activation 管理
2. 事件溯源+重放已经在 (Coordinator 比 codex 的纯内存强)
3. workspace 副本隔离 + review/apply 流水线 — codex/harness 都没有的合并纪律
4. capability token 安全模型比 codex 的纯线程内调用严谨
5. "内容是不可信数据"横幅 + 保护栏 — prompt injection 防御已在

### 劣势(要否定掉的)
1. **无黑板/CAS**: 任务板是消息列表, 无 revision, 无 DAG, 无 writeScopes
2. **租约双刃剑**: lease 回收逻辑是 harness 明确拒绝过的 ("crashed owners remain durable"), 它假设崩溃=可回收, 但 OTP 下子代理崩溃 ≠ 任务该回收 (活锁/僵尸)
3. **轮询重**: 模型要 tasks/1 轮询, 无 wait_agent 边缘触发 → token 浪费 (违背 wait 设计共识)
4. **无 peer 消息语义分层**: send_message 广播/点对点混在一个函数, 无 quiet/wake 分离的明确协议消息
5. **无角色/模型覆写**: role 只是个标签字符串, 不像 codex 能换模型/推理强度
6. **无递归深度限额**: 子代理可以再 delegate, 无深度/总数上限 → MAST 递归失控风险
7. **上下文继承不可调**: 子代理是全新会话(空历史), 没有 fork_turns 式的可控继承
8. **group 语义混乱**: group 既是"协作空间"又是"任务板"又是"消息频道", 没有 harness 那种 Team/Session/Task 分层

============================================================
第二部分: 论文注入的关键思想
============================================================

- MAST (2503.13657): 14 失败模式三类 — 系统设计缺陷 / agent间失调 / 任务验证缺失。
  → 教训: 光有加协作工具会"minimal gain", 必须有 (a)行为契约 (b)结构化消息 (c)生命周期验证
- SEMAP (2510.12120): 三原则实例化后失败率降 47-70%
  → 教训: explicit behavioral contract + structured messaging + lifecycle-guided execution+verification
- Beyond Self-Talk (2502.14321): 通信中心视角 — 架构/目标/协议 + 策略/范式/对象/内容
  → 教训: message passing vs blackboard 要显式选型, 不是顺手为之
- Context Engineering (2507.13334): 上下文是稀缺资源
  → 教训: fork_turns/截断继承是必要能力, 全量历史转发是浪费
- MacNet (2406.07155): 协作 scaling law — 拓扑不规则优于规则, 超千agent logistic 增长
  → 教训: 平铺 roster + 任意消息拓扑 > 严格层级
- MetaGPT (2308.00352): SOP 编码防级联幻觉
  → 教训: acceptance/验收必须前置且可机检, 不是事后描述
- ADAS (2408.08435): agent 即代码, 可被 meta agent 编程
  → 教训(远期): newbee 的 DEE 环境天然支持 "工具即代码", 协作原语也应可被 JIT 工具编排

============================================================
第三部分: 第一性原理分解 (协作的本质)
============================================================

剥离所有实现, 多代理协作只有四个基本问题:
1. 存在性 (Being): 谁在场? → roster/registry + 生命周期 (durable identity)
2. 共享事实 (Shared Truth): 什么是大家认可的状态? → blackboard + CAS/revision + DAG
3. 通信 (Communication): 谁对谁在何时说什么, 要不要叫醒? → 消息 + delivery 语义 (quiet/wake) + 寻址
4. 责任 (Accountability): 谁欠谁什么, 何时算完, 怎么验收? → 任务契约 + acceptance + report 义务 + verification

codex 强在 3, 弱在 2/4; harness 四项全但复杂; newbee 1/3/部分4, 缺 2 且 4 的 verification 是形式。

============================================================
第四部分: 否定之否定 (对现有 newbee 的扬弃)
============================================================

正题(现有): Coordinator 事件溯源 + lease + 消息 + workspace 隔离
反题(暴露的矛盾): 轮询浪费 token; lease 假互斥; 无共享事实板; 无递归护栏; 角色无实义
否定之否定(新综合): 保留 OTP/事件溯源/隔离流水线/能力令牌 这些"正",
                   否定 lease/轮询/弱角色/无界递归/无黑板 这些"反",
                   在更高层次综合为 —— **"黑板驱动的可验证协作团队"**

============================================================
第五部分: 新设计 (大胆创新)
============================================================

设计名: **Newbee.Collab v2 — "Hive" (蜂群)**
核心隐喻: 蜂群不是靠中央调度, 而是靠共享信息素黑板 + 简单契约 + 局部决策涌现协作。

### 五条设计公理 (第一性原理推导)
A1. 一切协调状态必须 durable 且可被 CAS 修改 (对抗崩溃+并发)
A2. 模型等待必须边缘触发, 禁止轮询 (上下文是稀缺资源)
A3. 递归必须有两道硬墙 (深度+总数), 默认关 (默认安全)
A4. 角色必须产生真实配置差异 (模型/工具/预算), 否则只是标签
A5. 验收必须机检前置 (acceptance 是函数不是形容词)

### 四大子系统

#### 1. Board (黑板) — 替代现有"消息列表当任务板"
- 每个 group 一个 Board GenServer, 状态=全量快照+revision
- 条目: task(带 DAG deps, owner, writeScopes, acceptance, status)
- 所有写走 `put(board, key, value, expected_revision)` CAS
- writeScopes 只做重叠**诊断** (harness 教训: 不做锁)
- 持久化复用现有 EventStore, 但状态从"消息叠加"改为"快照+事件增量"

#### 2. Rendezvous (会合点) — 替代轮询
- `wait(group_id, opts)` 阻塞 GenServer.call (带 timeout)
- 边缘触发: board revision 变化 / mailbox 新信 / 成员终态 → 立即返回变更摘要
- 醒后模型必须 `read_board` 重读权威状态 (不回放旧边)
- 底层用 GenServer + Registry, 崩溃自动退订

#### 3. SpawnGate (派生闸门) — 递归护栏
- 全局+每组: max_depth(默认3), max_total(默认12)
- 每个 delegate 发 SpawnToken (一次性), 深度+1 写入子代理血统
- capability token 里编码 depth, 超限直接拒 (A3)
- 这是 codex registry.rs 的直译, 但我们用 OTP 计数器+ETS 更轻

#### 4. Persona (角色实体化) — 替代标签 role
- role 声明可带: model 覆写 / reasoning / 工具白名单 / token 预算 / system 提示补丁
- delegate 时 Persona 编译进子会话 config (借 codex apply_role_to_config)
- 内置三角色: worker/tester/reviewer, 但允许 TOML 自定义

### 保留并强化 (继承的"正")
- workspace 副本隔离 + review/apply (newbee 独有, codex/harness 都没有) → 保持
- capability token → 扩展载荷携带 depth/persona
- 不可信数据横幅 → 保持, 且消息协议化
- report 义务 → 保持, 但改为"非终态、可重复、跨一边" (harness 语义)

### 模型可见 API (v2, 与旧 API 并存, 旧标记 deprecated)
- hive_delegate(title, opts)        — 派生(带 persona/fork_turns/budget)
- hive_board(action, group, ...)    — 黑板读写 (put_cas/claim/add_dep/write_scope)
- hive_wait(group, timeout)         — 边缘触发等待
- hive_send(group, to, body, wake?) — 消息 (quiet/wake 二选一, 不再有广播滥用)
- hive_report(group, task, body)    — 汇报义务 (非终态)
- hive_list(group)                  — roster+board 摘要 (紧凑)
- hive_interrupt(group, sid)        — 打断但保 inbox
- hive_close(group, sid)            — 显式回收 (codex 教训: 显式 close 防泄漏)

### 明确不做 (第一性原理剪枝)
- 不做 worktree 自动编排 (harness: "worktree isolation is deployment choice")
- 不做任务锁/writeScope 强制 ("假互斥比明示警告更危险")
- 不做跨进程 (现有 Web.Session 已是进程边界, 够用)
- 不自动建 team (opt-in, harness: "Enable Teams in the default catalog. Rejected")

============================================================
第六部分: 与现状的 diff 一览
============================================================
| 能力 | 现状 | codex | harness | v2 Hive |
|---|---|---|---|---|
| 任务板 CAS | ✗ | ✗ | ✓ | ✓ |
| DAG 依赖 | ✗ | ✗ | ✓ | ✓ |
| 边缘触发 wait | ✗ | ✓ | ✓ | ✓ |
| 递归护栏 | ✗ | ✓ | ✓ | ✓ |
| 角色实体化 | 标签 | ✓ | ✓ | ✓ |
| fork_turns | ✗ | ✓ | fork 一次性 | ✓ |
| writeScope 诊断 | ✗ | ✗ | ✓ | ✓ |
| 显式 close | ✗ | ✓ | dispose | ✓ |
| 隔离+合并流水线 | ✓ | ✗ | ✗ | ✓ (保留) |
| capability 令牌 | ✓ | 进程内 | ✓ | ✓ (扩展) |
| report 义务 | 弱 | ✗ | ✓ | ✓ (强化) |
