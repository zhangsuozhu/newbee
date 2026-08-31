# Loop & Goal 指令深度分析与优化方案

## 1. Codex 源码剖析

### Goal 指令体系 (ext/goal)

#### 存储
- `state/goals_migrations/0001_thread_goals.sql` 建表 `thread_goals`:
  ```
  thread_id PK, goal_id, objective TEXT, status CHECK(active/paused/blocked/usage_limited/budget_limited/complete),
  token_budget INTEGER, tokens_used INTEGER, time_used_seconds INTEGER, created_at_ms, updated_at_ms
  ```
- 额外表 `thread_goal_continuation_deferrals` 用于延迟 continuation 注入（空表占位，ON DELETE CASCADE）

#### 状态机
```
  active <-> paused       (用户 /goal pause/resume)
  active -> budget_limited (token >= budget, 由 accounting 自动转换)
  active -> usage_limited  (外部配额)
  active/paused -> complete|blocked (模型 tool: update_goal 仅允许这两个终态)
  blocked 三击审计: 同一阻塞条件连续3个 goal turn 才允许标记 blocked
```

#### 三大 Steering 模板 (templates/goals/*.md)
- `continuation.md`: 每轮自动注入，含 objective + tokens_used/token_budget/remaining, 要求最终调用 update_goal complete
- `budget_limit.md`: 触顶后注入，禁止新实体工作，只做收尾总结
- `objective_updated.md`: 用户 edit 后注入，强调新 objective 覆盖旧 objective

#### 运行态
- `GoalService` (api.rs): 统一入口 get/set/clear, 校验 objective 非空、budget 合法、同一 thread 只能一个 unfinished goal
- `GoalRuntimeHandle` (runtime.rs): 墙钟 + token 记账 (AccountingState), 每次 turn 结束通过 `GoalAccountingMode` 结算
- `GoalExtension` (extension.rs): 实现 `ThreadLifecycleContributor` + `TurnLifecycleContributor` + `ToolContributor`
  - 创建工具: create_goal(objective, token_budget), get_goal, update_goal(status)
  - 用户侧 API: thread/goal/set|get|clear (app-server-protocol)
  - 记账采用 `GoalAccountingState.progress_snapshot()` 取得 delta 后 `account_thread_goal_usage`

#### TUI 侧
- `tui/slash_command.rs` 定义 `Goal` 为内置命令，支持在任务进行中可用 (`available_during_task=true`)
- `tui/chatwidget/slash_dispatch.rs` 处理 `/goal`:
  - 空参 → OpenThreadGoalMenu
  - `clear|pause|resume` → 对应 AppEvent
  - `edit` → OpenThreadGoalEditor
  - 否则视为新 objective draft → SetThreadGoalDraft(ConfirmIfExists)
- 支持 "goooal" 模糊拼写容错 (`strip_prefix('g').strip_suffix("al")` 全 o 检查)

### Loop 语义
Codex 并无显式的 `/loop` slash; loop 指：
- core turn loop: `prompt → LLM → tool_calls → execute → loop` 直至无 tool_call (run_turn)
- goal continuation loop: GoalExtension 在 `on_turn_stop` / `on_thread_idle` 时若 status=active 自动注入 continuation 促使模型持续推进
- AppServer 的 UpdateLoop / pid-update-loop 等后台轮询 loop

### 启示
- 把“目标”与“轮次循环”解耦：目标是带预算/状态的声明式对象，循环是其执行引擎
- 预算与时间双维度限界，预算触顶有专门的温和收尾提示而非硬杀
- 阻塞需三击确认，避免模型因一次困难就甩锅
- 记账必须是独立的 accounting 状态机，而非简单计数

## 2. Newbee 现状

### Loop (Agent.Loop)
- 经典 ReAct loop: `system_prompt → LLM stream → extract_tool_calls → execute_calls → run_turn` 无硬步数上限，每25步审计
- 压缩采用 threshold=0.8 触发 retain=0.16
- JSpace 已做持久化 ledger，但与 loop 的收敛判断未联动

### Goal
- 极简: `%{text, rounds, max_rounds, idle, msg_len, error_retries}`
- after_turn 仅处理 text→continue / done→done / ask→保留 / error→一次重试
- idle 连续3轮无 tool 调用的温和提醒，无 budget、无状态机、无 persistence

### 差距
| 维度 | Codex | Newbee 现状 |
|------|-------|-------------|
| status | 6态状态机 | 无 |
| budget | token_budget + time_used 记账 | 无 |
| persistence | SQLite thread_goals | 仅内存 |
| blocked audit | 3击确认 | 无 |
| steering | 3模板注入 | 1行 continue 提示 |
| loop 反思 | - | 无 |
| JSpace 联动 | - | 仅恢复提示 |

## 3. 论文借鉴

### ReAct (Yao 2023)
Reasoning+Acting 交替，loop 的每一步都应是“思考-行动-观察”三元组。Newbee 已具备，但可加强：行动前显式 reason 字段、观察后的自检。

### Reflexion (Shinn 2023)
失败后用自然语言反思存入 episodic memory，下次尝试前读取。对应：检测到连续错误签名/空闲时注入 reflection prompt，要求模型先分析阻因再行动，而非盲目重试。

### Voyager (Wang 2023)
技能库 + 课程式自主探索。Goal 的 objective 可被分解为子技能，loop 每轮应尝试复用已有工具/技能，失败则合成新工具。

### Self-Refine / Self-Consistency
迭代自批评与多路径采样。Loop 应在接近 done 前增加验证回合 (verification gate)。

### Budget-aware Agent (Codex实践) + Adaptive Stopping (Chen 2024)
基于 token/time 预算的软限与硬限，软限仅注入收尾提示，硬限才停止。阻断判定需多次确认。

### LATS / Tree-of-Thoughts
语言代理的搜索可视为树，loop 是深度优先遍历，需记录 visited 状态避免死循环。对应：工具指纹去重、重复调用检测。

## 4. Newbee 优化设计 (本任务落地)

### 4.1 Goal 状态机升级 (lib/newbee/goal.ex + goal/steering.ex)
- 结构: `%Goal.State{id, objective, status, token_budget, tokens_used, time_used_ms, rounds, max_rounds, idle, blocked_streak, last_block_reason, created_at, updated_at}`
- status: `:active | :paused | :budget_limited | :blocked | :complete` (映射 Codex 的6态，合并 usage_limited→budget_limited)
- persistence: 写入 `~/.newbee/goals/<session_id>.json` (若有 session) + Loop 内存双写，重启可恢复
- blocked 三击: 模型 `done` 带 blocked 语义或输出含“blocked/等待用户”连续3轮才标记 blocked，否则仅计数
- API:
  - `Newbee.Goal.State.new(objective, opts)` → state
  - `Newbee.Goal.Steering.continuation(state)` / `budget_limit` / `objective_updated` → prompt 文本 (复用 Codex 模板思想，但加入 JSpace ledger 摘要)

### 4.2 Loop 增强 (lib/newbee/agent/loop.ex)
- Goal 存储升级为 rich map, 新增字段: id, status, token_budget, tokens_used, time_used_ms, wall_start, blocked_streak, last_tool_sig, repeat_count, reflect_cooldown
- 记账: 每次 run_turn 结束累加 usage.total_tokens + wall时间；触 budget_limited 即注入 budget 模板并暂停新实体工作
- 收敛检测 (convergence):
  - idle = 连续无 tool 轮数
  - repeat = 同一 tool+args 指纹连续出现 ≥2
  - error_loop = 同一 error 签名连续 ≥2
  - → 触发 reflection 注入 (Reflexion): 要求模型先输出 <reflection> 分析再行动，冷却3轮
- 验证门 (verification gate, jspace联动):
  - done 前检查 JSpace ledger: 若 verified==0 且 open 存在，注入 “verified 未落账，不能 done” 提醒并拒绝 done (类似 jspace-verified 规则)
- steering 注入点:
  - goal_start → system prompt + continuation 首条
  - 每轮 goal_next → continuation (含 budget)
  - idle≥3 → idle_reminder
  - budget触顶 → budget_limit
  - objective edit → objective_updated
  - repeat/error_loop → reflection

### 4.3 /loop 指令 (lib/newbee/commands.ex)
新增 `/loop <任务> [--iterations N] [--budget TOKENS]`:
- 紧凑循环模式：同步执行 N 次 submit (默认5)，无 done 即继续，类似 goal 但无状态机、轮间无异步，用于“小范围连续打磨”
- 复用 Goal 的记账与收敛检测，但生命周期仅本指令内
- 与 /goal 互斥：执行 loop 时若已有 active goal 则提示

### 4.4 /goal 命令增强
- `/goal` 无参 → 展示 rich 状态 (objective, status, rounds, budget, tokens_used, idle)
- `/goal <objective>` [--budget N] [--max-rounds N] → 启动 (解析后缀 flags)
- `/goal pause|resume|clear` → 状态切换
- `/goal edit <new objective>` → objective_updated 注入
- `/goal status` → 同无参
- `/goal budget <N>` → 调整预算

### 4.5 测试与验证
- 新增 `test/newbee/goal/steering_test.exs`, `test/newbee/agent/loop_goal_test.exs`
- `mix test` 全量
- 手工验证: 启动 Loop with mock client, 走一轮 goal 生命周期 + budget + idle + reflection + JSpace gate

