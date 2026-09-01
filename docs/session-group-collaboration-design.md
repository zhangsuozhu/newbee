# 会话群协作设计：跨会话消息与派生会话共同工作

> **状态**：核心已落地。已实现：群/成员/消息/任务事件溯源（含重启恢复）、notify/queue/wake 三种消息投递（queue/wake 经会话队列驱动一轮模型工作，忙时排队去重，不打断当前工具调用）、让另一个 AI 帮忙（会话创建+分派）、任务报告与结果回收、成员移除保护、WebUI 左侧分组 + Mission Control 协作/工作项面板、投递方式选择与徽标。未实现：跨会话权限审批卡、任务结果卡/文件归因、独立 worktree 与按子会话审查集成。  
> **日期**：2026-08-27  
> **范围**：后端运行时、持久化协议、HTTP RPC、WebSocket、WebUI、权限、并发与验收  
> **对应需求**：  
> 1. 各活动（会话）之间可以相互发消息；  
> 2. 一个会话可以启动其它会话，形成会话群，共同完成一个工作。

---

## 0. 结论先行

本功能不应实现成“把多个会话接到同一个聊天室”。推荐新增一个独立的 **Collaboration / 会话群协作域**：

- **Session 仍是执行单元**：一个会话拥有自己的 `Agent.Loop`、evaluator、上下文、transcript 和模型配置。
- **Group 是协作聚合体**：保存群目标、成员、任务、消息、预算和状态；不替代 Session。
- **Task 是协作工作单元**：父会话可以把一个结构化任务分派给子会话，子会话返回结构化结果。
- **Message 是可靠事件**：消息写入协作事件流，再投递给在线 UI 或目标会话；不把消息直接伪装成用户输入。
- **Coordinator 是单写者**：所有群组、成员、任务、消息状态变化经一个 `Collaboration.Coordinator` 串行裁决。
- **工作区默认隔离**：写代码的子会话默认使用独立文件系统副本；自动应用默认关闭，必须显式审查/集成。Git 仅作为可选适配器。
- **模型唤醒可控**：消息分为 `notify`（只通知）、`queue`（空闲时处理）和 `wake`（受预算限制触发一轮模型工作）。
- **上下文必须显式携带身份**：不能继续依赖全局 `Session.current_id/0` 判定“谁在执行”；并行会话必须使用 `ExecutionContext`。

首版推荐默认值：

| 项目 | 默认值 | 原因 |
|---|---|---|
| 消息传递 | at-least-once + `message_id` 幂等 | 不宣称分布式 exactly-once |
| 子会话创建者 | 父会话 | 满足“一个会话启动其它会话” |
| 子会话工作区 | 文件系统副本 | 防止并行写入互相覆盖；不要求 Git |
| 普通聊天消息 | `notify` | 不因聊天无限消耗模型预算 |
| 任务分派消息 | `wake` 或 `queue` | 让子会话真正开始工作，但有界、可取消 |
| 自动合并 | 关闭 | 合并是高风险副作用，必须显式操作 |
| 群组删除 | 软删除/保留事件 | 便于审计、恢复和问题定位 |

---

## 1. 背景：现有架构能复用什么，缺什么

### 1.1 可以直接复用的基础设施

| 现有组件 | 当前职责 | 在会话群中的复用方式 |
|---|---|---|
| `Newbee.Session` | transcript、artifacts、meta、会话索引 | 继续作为单会话持久化；不承载群组真相 |
| `Newbee.Web.Session` | 一个 session 对应一个 Web/Loop 进程，负责排队与生命周期 | 作为群成员的运行时进程；增加协作收件和派生入口 |
| `Newbee.Agent.Loop` | 单会话模型循环、工具执行、事件渲染 | 增加显式 `ExecutionContext` 和内部协作消息入口 |
| `Newbee.Bus` / `Newbee.Events` | 实时事件广播、durable/live 事件域 | 广播群事件给 WebSocket 和运行时观察者 |
| `Newbee.EventStore` | JSONL + checksum + 单调 event id + 重放 | 作为协作域的权威事件存储实现 |
| `Newbee.Web.Api` | `/api/<method>` RPC-over-HTTP | 增加 `group.*` / `collab.*` 方法 |
| `Newbee.Web.Socket` | 当前 session 的 WebSocket 下行 | 保持旧帧兼容，增加群组订阅和群事件帧 |
| `Newbee.Agent.Explorer` | 临时 agent + worktree 的探索任务 | 借鉴 evaluator/worktree 生命周期；正式群成员需可恢复 |
| `Newbee.Tools.Git` | worktree、Git 操作 | 子会话隔离和后续显式集成 |

### 1.2 当前不能直接复用的部分

1. **`Web.Socket` 当前按 `session=<sid>` 过滤事件**：只能看到一个会话，不能表达群组订阅、游标和成员权限。
2. **`Newbee.Agent.Protocol` 面向 Worker/Adapter 环境进化**：其 `need`、`feedback`、`candidate_ready` 等消息不能直接当作用户会话协作协议；两者应保持不同命名空间和生命周期。
3. **`Session.current_id/0` 是主节点级 `persistent_term`**：多个 Loop 并行时，后启动会话可能覆盖身份，导致媒体、J-Space、审计和协作消息归属串线。
4. **普通 transcript 是单会话视图**：把其它会话消息直接 append 成 `user` 或 `assistant` 会污染模型历史，且无法表达送达、确认、重试和群游标。
5. **共享 cwd 不等于协作隔离**：多个写型 agent 同时使用同一工作树会出现覆盖、stale edit、测试相互影响和无法归因。

### 1.3 设计原则

1. **单会话向后兼容**：不加入群组的 session 行为、API 和历史格式不变。
2. **事件先于视图**：事件流是事实，snapshot、inbox、WebUI 列表和模型上下文都是派生物。
3. **消息不等于指令**：消息可被读取，只有经过投递策略和权限校验才会触发模型工作。
4. **最小上下文**：模型只收到当前任务所需的消息摘要和引用，旧消息按需读取。
5. **显式副作用**：创建会话、运行模型、写工作区、合并分支、请求用户批准分别审计。
6. **可恢复优先**：断线、重启、重复投递和半帧写入都是正常故障路径，不是异常假设。
7. **安全拒绝优于静默错改**：冲突、越权、预算耗尽和不明确目标必须拒绝并给出可操作原因。

---

## 2. 目标与非目标

### 2.1 目标

- 会话 A 可以向会话 B、多个指定成员或整个群组发送消息。
- 用户可以从一个父会话创建、查看、停止、恢复其它子会话。
- 父会话可以创建任务、分派任务、接收进度和结构化结果。
- 子会话可以反向提问、报告阻塞、提交 artifact/diff 引用。
- 群组在浏览器断线、会话重启、Coordinator 重启后仍可恢复。
- 消息、任务状态和成员状态可追踪、可重放、可审计。
- 所有群内内容具有明确来源和身份，不越权提升工具权限。
- 首版可以只支持一个项目根目录，但必须为未来多项目/多 actor 保留字段。

### 2.2 非目标（首版不做）

- 不承诺跨进程分布式 exactly-once。
- 不允许多个写型 agent 默认共享同一工作树并自动解决冲突。
- 不把整个父会话 transcript 自动复制给子会话。
- 不实现复杂的多人账号、组织、计费和跨租户权限系统；先保留 `actor_id` 扩展点。
- 不允许群内 agent 通过消息绕过现有 `Permissions`、Capability Gate、Host 边界或人工确认。
- 不把群组做成模型自由 spawn 无限子代理的无界递归系统。
- 不在首版实现跨群广播、公开链接邀请或外部 IM 网关。

---

## 3. 核心对象模型

### 3.1 三层关系

```text
┌─────────────────────────────────────────────────────────────┐
│ CollaborationGroup                                         │
│  goal / policy / budget / event stream / members / tasks    │
│                                                             │
│  ┌───────────────┐   assigns   ┌─────────────────────────┐ │
│  │ parent session│ ───────────> │ child session(s)         │ │
│  │ coordinator   │ <─────────── │ worker/reviewer/...      │ │
│  └───────────────┘  messages    └─────────────────────────┘ │
│          │                         │                        │
│          └──────────── Task ───────┴────── ArtifactRef      │
└─────────────────────────────────────────────────────────────┘
```

Group 不拥有一个新的模型上下文；它编排若干已有 Session。一个 Session 可以在生命周期内加入多个 Group，但首版建议限制为“一个 session 同时最多参与一个 active group”，降低身份和资源复杂度。

### 3.2 Session（会话）

已有对象，仍然是实际执行模型的最小单元：

- `session_id`
- 一个 `Newbee.Web.Session` 进程
- 一个 `Agent.Loop` 和一个 evaluator
- 独立模型、上下文、绑定、transcript、usage
- 可加入 Group；加入群组不会改变其 session 身份
- 可记录 `parent_session_id`，仅表示派生来源，不等于 OTP 父子生命周期

### 3.3 CollaborationGroup（会话群）

建议字段：

```text
group_id                  稳定 id，例如 grp_...
title                     群组标题
goal                      共同目标（短文本 + 可选结构化约束）
project_root              项目根目录身份（不把秘密路径发给客户端）
created_by_actor_id        创建请求来源，不保存 token 原文
created_by_session_id      发起创建的会话
coordinator_session_id     当前群协调会话，可为空
status                    draft | running | paused | completed | failed | cancelled
policy                    成员、消息、工作区、预算和失败策略
member_ids                物化索引；真相来自 member_added/member_removed 事件
active_task_ids            物化索引
next_seq                  群内事件/消息游标
created_at / updated_at
```

一个 group 可以有多个 worker，但首版只允许一个 `coordinator_session_id`。协调会话本身也可以承担 worker 任务。

### 3.4 GroupMember（成员）

```text
member_id                 membership id，不直接等同 session id
group_id
session_id
role                      coordinator | worker | reviewer | observer | tester
state                     joining | idle | working | waiting | blocked | stopped | failed
parent_session_id         谁创建/邀请了该成员
spawned                   是否由群内 spawn 创建
worktree                  none | shared_readonly | dedicated
worktree_path / branch    仅存受控相对信息或 opaque id
capabilities              群内附加能力，不得超过 Host 全局能力
joined_at / last_seen_at
```

成员资格是可撤销的；session 被删除、重启或离线不等于 membership 自动删除。一个被停止的成员仍可作为历史消息的发送者显示。

### 3.5 Task（任务）

```text
task_id
 group_id
parent_task_id            可选，形成有限深度的任务树
title
description
acceptance                 验收条件（文本 + 可选结构化检查）
assigned_to                member_id，可为空
created_by                 member_id / actor
status                     pending | leased | running | blocked |
                          succeeded | failed | cancelled
priority
dependencies               只能引用同 group 的 task_id
input_refs                 文本或 ArtifactRef
output_refs                ArtifactRef / diff / test report
delivery                   notify | queue | wake
lease_owner / lease_until
budget / timeout / retry_policy
created_at / updated_at / completed_at
```

任务不是消息的别名。消息表达协作沟通，任务表达可追踪的工作承诺。

### 3.6 Message（消息）

消息是协作域中的一等事实，不直接写入普通 session transcript：

```text
message_id                 全局幂等 id，例如 msg_<session>_<seq>
command_id                 客户端/工具请求幂等键，可为空
group_id
seq                        group 内单调序号
sender_session_id          系统消息可为空
sender_member_id
recipients                 session/member/group 广播目标
kind                       chat | task_assign | task_accept |
                          task_progress | task_result | question |
                          approval_request | artifact | system | error
delivery                   notify | queue | wake
status                     accepted | delivered | processed | failed
reply_to / correlation_id
task_id
body                       text、结构化字段、ArtifactRef
created_at / delivered_at / processed_at
```

正文必须保留来源、发送者和任务关联；不能只保存一段无身份的字符串。

### 3.7 Artifact 与 Diff

文件、测试报告、截图、日志等大对象不直接塞进消息正文，消息只携带：

- `artifact_id` / `sha256`
- 类型、字节数、来源 session/member
- 受控相对路径或内部 media URL
- 可选 diff/base commit/branch 信息
- 访问策略和过期策略

复用现有 `Newbee.ArtifactRef` 的内容寻址思路。Artifact 引用不能自动授予读取项目外路径的权限。

### 3.8 ExecutionContext（执行上下文）

并行会话必须显式携带以下身份：

```elixir
%Newbee.ExecutionContext{
  session_id: "20260827-child",
  group_id: "grp_01J...",
  member_id: "mem_01J...",
  task_id: "task_01J...",
  correlation_id: "turn_42",
  delivery_id: "msg_...",
  root: "/project/worktrees/grp_01J-child",
  capabilities: [:fs, :shell],
  actor: :agent,
  source: :collaboration
}
```

字段必须可序列化、可审计，不携带 API key、token、PID、closure 等运行时句柄。

---

## 4. 群组与子会话生命周期

### 4.1 Group 状态机

```text
draft ── start ──> running ── pause ──> paused
  │                  │                    │
  └─ cancel ───────> cancelled <──────── resume
                       ▲
         running ──────┼──── failed
         running ──────┴──── completed
```

- `draft`：已创建但尚未允许模型工作。
- `running`：允许投递任务和唤醒成员。
- `paused`：保留消息和任务，不启动新的模型 turn；已有 turn 可按策略中断。
- `completed`：达到目标或用户确认结束；保留只读历史。
- `failed`：群级不可恢复错误，仍可查看和人工重试任务。
- `cancelled`：用户主动取消；事件不可删除。

状态转换只能由 Coordinator 接受合法命令产生；前端按钮不能直接修改 snapshot。

### 4.2 Member 状态机

```text
joining -> idle -> working -> idle
             │       │  └──> blocked -> working
             │       └─────> failed
             └──────────────> stopped
```

运行状态由 session 进程事件和协作事件共同投影，不能仅由前端心跳推断。`offline` 应作为连接/进程观测字段，不覆盖历史状态。

### 4.3 Task 状态机

```text
pending -> leased -> running -> succeeded
   │         │          │  ├──> blocked -> running
   │         │          │  ├──> failed -> retry -> pending
   │         │          └──┴──> cancelled
   └──────> cancelled
```

`lease` 防止一个任务被两个成员同时执行；lease 过期后由 Coordinator 重新排队或标记失败。任务重试必须增加 attempt 序号，不能复用一次执行的结果。

### 4.4 从父会话启动子会话的流程

```text
父会话/用户
    │  group.session.spawn(command_id, task, policy)
    ▼
Collaboration.Coordinator
    │ 1. 校验父成员身份、群状态、fanout/depth/budget
    │ 2. 生成 session_id、member_id、task_id
    │ 3. 写 member_added + task_created 事实事件
    ▼
Web.Session.ensure(session_id, cwd/worktree)
    │ 4. 启动独立 Web.Session / Loop / evaluator
    │ 5. 注入最小 group ExecutionContext
    ▼
子会话
    │ 6. 收到结构化 task_assign（不是伪造的 user prompt）
    │ 7. 回 task_accept / task_progress / task_result
    ▼
父会话与群 UI
    │ 8. 由 message.created / task.* 事件更新视图
```

所有步骤使用 `command_id` 幂等。父会话重复调用 spawn 不应创建两个相同任务。spawn 失败时必须产生 `collab_spawn_failed` 或等价事件，并返回稳定错误码。

### 4.5 父会话结束时的子会话策略

群组策略显式配置：

- `on_coordinator_stop: continue`（推荐默认）：父 session 停止不代表群停止，子会话继续，群可由用户恢复。
- `on_coordinator_stop: pause`：暂停新任务和 wake，但保留已有状态。
- `on_coordinator_stop: cancel_children`：适合临时审查群，取消所有未完成子任务。

不能把“父子关系”直接实现为 OTP 父进程退出即杀子进程，否则浏览器切换会话或父会话重启会意外破坏整个工作。

### 4.6 成员加入已有群组

首版支持两种方式：

1. **spawn**：由群内成员创建全新 session，自动加入群组。
2. **attach**：用户选择一个已经存在的 session 加入群组，需显式确认其工作区和上下文策略。

`attach` 默认以 `observer` 或 `reviewer` 角色加入，不能自动获得写入任务；改成 `worker` 必须通过权限检查和工作区检查。

---

## 5. 消息协议

### 5.1 消息类型

| kind | 发送方向 | 作用 | 默认 delivery |
|---|---|---|---|
| `chat` | 任意成员 → 成员/群 | 普通讨论 | `notify` |
| `task_assign` | coordinator → worker | 分派结构化任务 | `wake` |
| `task_accept` | worker → coordinator | 接受/拒绝任务 | `notify` |
| `task_progress` | worker → 群/发起者 | 进度、阻塞、预计完成 | `notify` |
| `task_result` | worker → coordinator | 结构化完成结果 | `wake` |
| `question` | 任意成员 → 指定成员 | 请求澄清 | `notify` 或 `wake` |
| `approval_request` | worker → 用户/有权限成员 | 请求高风险操作确认 | `notify` |
| `artifact` | 任意成员 → 群 | 分享 ArtifactRef/diff/test report | `notify` |
| `system` | Coordinator → 成员 | 生命周期和策略通知 | `notify` |
| `error` | Coordinator/成员 | 失败和重试信息 | `notify` |

### 5.2 delivery 语义

#### `notify`

- 写入可靠收件箱和群事件流。
- 在线 WebSocket 立即展示未读徽标和时间线卡片。
- 不启动模型，不改变 Loop 的模型上下文。
- 模型可通过协作工具或 `collab://` 读取。

适合聊天、进度、artifact 分享。

#### `queue`

- 写入收件箱。
- 目标 session 忙时不打断当前 turn。
- 当前 turn 完成且 session 空闲后，合并一批消息启动一次内部协作处理。
- 支持最大条数、最大字节数和 debounce 时间。

适合非紧急的多个进度更新。

#### `wake`

- 写入收件箱后尝试唤醒目标 session。
- 若目标正在运行，进入有界队列，不并发启动第二个 Loop turn。
- 一次 wake 最多携带固定数量/字节的消息摘要，完整内容按 `message_id` 拉取。
- 受 group budget、session budget、最大 wake 频率和取消状态约束。

适合任务分派和任务结果，不适合普通闲聊。

### 5.3 线协议示例

发送任务：

```json
{
  "groupId": "grp_01J...",
  "commandId": "cmd_parent_18",
  "senderSessionId": "20260827-parent",
  "to": {"type": "session", "sessionId": "20260827-child"},
  "kind": "task_assign",
  "delivery": "wake",
  "taskId": "task_01J...",
  "body": {
    "title": "为 API 增加回归测试",
    "description": "覆盖未登录、过期 token 和成功路径",
    "acceptance": ["mix test 通过", "不修改现有认证语义"]
  }
}
```

任务结果：

```json
{
  "groupId": "grp_01J...",
  "messageId": "msg_20260827-child_7",
  "senderSessionId": "20260827-child",
  "kind": "task_result",
  "delivery": "wake",
  "taskId": "task_01J...",
  "body": {
    "status": "succeeded",
    "summary": "增加 3 个认证回归测试，全部通过",
    "files": ["test/newbee/web/auth_gate_test.exs"],
    "tests": {"command": "mix test test/newbee/web/auth_gate_test.exs", "passed": true},
    "artifacts": [],
    "nextActions": ["请审查 diff 后决定是否集成"]
  }
}
```

### 5.4 可靠性与幂等

采用 **at-least-once delivery + 幂等 effect**：

1. 发送者生成并持久化 `message_id`，重试时复用同一 ID。
2. Coordinator 接受命令时先检查 `command_id`，写消息时检查 `message_id`。
3. 事件成功落盘后才向 Bus 和 WebSocket 广播。
4. 目标 session 处理消息时记录 `processed_message_ids` 或处理水位；重复消息只更新投影，不重复执行任务。
5. 进程崩溃、网络断开、WebSocket 重连都可能造成重复投递；客户端和 agent 都必须按 ID 去重。
6. 不把“收到 WebSocket 帧”视为消息已处理；`delivered`、`read`、`processed` 是不同状态。

群内 `seq` 只保证同一 group 的事件顺序；不同 group、不同 session 之间不提供全局实时排序。

### 5.5 消息中的模型内容是不可信输入

Peer message 与用户 system prompt 的信任级别不同：

- 不允许消息正文覆盖 system policy、Host capability 或群预算。
- `task_assign` 必须经过 schema 校验；未知字段保留在 `metadata`，不能被当成权限声明。
- 注入模型上下文时使用明确的来源标记，例如 `[来自协作成员的未验证信息]`。
- 消息中的代码、URL、文件路径仍须经过现有规则、Capability Gate、Permissions 和 Host 边界。
- 任务结果只能报告事实和引用，不能直接声明“已批准合并”或“已获得用户授权”。
- 群消息大小、嵌套深度、附件数量和附件总字节数必须有上限。

### 5.6 Agent 侧协作上下文注入

建议给 Loop 增加三类内部输入，而不是把协作消息伪造成普通用户消息：

```text
{:collab_notify, envelope}       只更新可读收件箱/事件
{:collab_queue, batch, ref}      空闲后形成一次内部处理
{:collab_wake, batch, ref}       经过预算校验后触发一次内部处理
```

Loop 处理时追加带来源的内部消息视图，例如：

```text
[协作事件，未验证外部内容]
来自: child-session / worker
任务: task_01J...
消息: 请确认接口返回值的兼容性。
完整消息: collab://message/msg_...
```

内部事件不应进入用户对话的 `role=user` 历史；如果需要在 UI 显示，写入协作时间线或专门的 `role=collab` 投影视图。

---

## 6. 持久化与事件溯源

### 6.1 权威数据与派生视图

推荐复用 `Newbee.EventStore` 的实现，创建一个协作域专用实例：

```text
项目根/.newbee/
└── collaboration/
    ├── events.jsonl                 # 唯一权威事实流
    ├── groups/
    │   └── <group_id>/
    │       ├── snapshot.json        # 可丢弃、可重建的群状态快照
    │       ├── members.json
    │       ├── tasks.json
    │       └── cursor
    ├── inbox/
    │   └── <session_id>.jsonl       # 收件箱派生视图/索引
    └── outbox/
        └── <session_id>.seq         # message_id 序列水位
```

规则：

- `events.jsonl` 是唯一事实来源；snapshot、members、tasks、inbox 都是 projection。
- 快照写入使用 tmp + rename；快照损坏时从事件流重建。
- inbox 可以重建，不得反过来成为消息真相。
- 普通 session transcript 不替代协作事件流。
- 协作事件进入项目 `.newbee`，不进入全局 `~/.newbee`，避免跨项目泄漏。
- 路径中的 `group_id/session_id` 必须使用安全 slug；原始用户输入不能直接形成文件名。

### 6.2 事件主题

建议内部使用稳定 atom，线协议使用字符串：

```text
:collab_group_created
:collab_group_started
:collab_group_paused
:collab_group_resumed
:collab_group_completed
:collab_group_cancelled
:collab_group_failed
:collab_member_added
:collab_member_state_changed
:collab_member_removed
:collab_task_created
:collab_task_assigned
:collab_task_leased
:collab_task_started
:collab_task_progressed
:collab_task_succeeded
:collab_task_failed
:collab_task_cancelled
:collab_message_created
:collab_message_delivered
:collab_message_read
:collab_message_processed
:collab_message_failed
:collab_artifact_attached
:collab_budget_changed
:collab_spawn_failed
```

事件 data 至少带：`group_id`、`actor/session_id`（适用时）、`command_id`、`message_id/task_id`（适用时）、`at` 和结构化 payload。

### 6.3 重启和恢复

#### Coordinator 重启

1. 启动 `EventStore`，校验 checksum 并截断坏尾帧。
2. 从上次 snapshot cursor 之后重放事件。
3. 重建群、成员、任务、未处理消息投影。
4. 对 `leased/running` 任务按 lease 策略重新排队或标记 `blocked`。
5. 对 `wake` 消息重新尝试投递，使用原 `message_id`。
6. 恢复 WebSocket 连接只需按 cursor 补发，不依赖内存状态。

#### Web.Session / Loop 重启

- 协作收件箱中的未 `processed` 消息仍然存在。
- Session 启动时根据 membership 恢复 group context 和待处理消息摘要。
- 不把所有历史群消息灌进模型上下文；只恢复未处理消息和必要的 task 状态，旧内容按需读取。
- 重复投递由 `message_id` 去重。

#### 浏览器断线

- 工作继续运行，不因 UI 断线停止群组。
- 重连后发送 `group.subscribe(group_id, since_seq)`。
- 服务端先补发缺失事件，再转发实时事件。
- 客户端按 `eventId/messageId/seq` 去重，并在游标确认后更新本地 checkpoint。

### 6.4 压缩策略

协作事件与会话档案一样遵循“压缩改视图、不改日志”：

- 事件流永不覆写。
- 群 snapshot 只用于加速启动。
- 消息正文可按保留策略转为 ArtifactRef/归档段，但 `message_id`、摘要、任务结果和引用永远保留。
- 前端只请求当前窗口；模型通过 `collab://` 按需读取旧消息。


---

## 7. ExecutionContext：并行会话的身份隔离前提

### 7.1 结构与不变量

新增 `Newbee.ExecutionContext`（名称可调整，语义必须保留）：

```elixir
%Newbee.ExecutionContext{
  session_id: "20260827-child",
  group_id: "grp_01J...",
  member_id: "mem_01J...",
  task_id: "task_01J...",
  correlation_id: "turn_42",
  delivery_id: "msg_...",
  root: "/project/worktrees/grp_01J-child",
  capabilities: [:fs, :shell],
  actor: :agent,
  source: :collaboration
}
```

不变量：

- `session_id` 必须存在且与运行中的 Loop 一致。
- 若有 `group_id`，则 `member_id` 必须属于该 group 且绑定同一 session。
- `task_id` 只能引用同一 group 的任务。
- `root` 必须经过 Workspace/Host 路径检查，不能由消息正文直接覆盖。
- `capabilities` 只能是全局允许能力的子集。
- `correlation_id` 用于把 turn、工具调用、消息和审计串起来。
- context 必须可 JSON/ETF 安全编码，不携带 API key、token、PID、closure 等运行时句柄。

### 7.2 传播路径

```text
Web.Session
  └─> Agent.Loop opts/context
       └─> Evaluator.eval(..., context: ctx)
            └─> EvalWorker.with_context(ctx)
                 └─> Host.call/emit(..., context: ctx)
                      └─> Media / JSpace / Events / audit
```

对于 evaluator peer 到主节点的 RPC，context 必须作为受控参数随请求传输，不能依赖两个 BEAM 节点共享 process dictionary 或 persistent term。

### 7.3 对现有 `Session.current_id` 的迁移

- 保留 `Session.current_id/0` 供旧 CLI/TUI 单会话兼容。
- Web 会话、群组会话和所有新协作工具禁止把它作为权威身份来源。
- `Tools.Media`、`Tools.JSpace`、审计、事件和新 `Tools.Collaboration` 优先读取显式 context。
- 无 context 时才回退到旧的 current session，并记录兼容性审计事件。
- context 缺失时不能默默把消息发到“当前活动会话”，除非调用明确标注为 legacy 兼容路径。

### 7.4 生命周期上下文

每次 turn 开始创建不可变 context；工具调用只读它。子任务尝试 spawn 新成员时，子 context 继承：

- `group_id`
- `parent_session_id`（作为审计字段）
- 可继承的最小 capabilities
- 项目根和群 policy 的受控派生值

子 context 不继承父任务的 `task_id`、用户授权结果或任意秘密；必须生成新的 task/message/correlation id。

---

## 8. 后端设计

### 8.1 模块分层

建议新增以下模块（具体命名可根据仓库习惯调整）：

```text
lib/newbee/collaboration/
├── group.ex          # Group / Member / Policy 结构与校验
├── task.ex           # Task 结构、状态转换和 schema
├── message.ex        # Message envelope、kind/delivery 校验
├── coordinator.ex    # 单写者 GenServer，命令裁决与投递调度
├── store.ex          # collaboration EventStore、snapshot 和 cursor
├── projection.ex     # 事件 → group/member/task/message 物化视图
├── dispatcher.ex     # inbox/outbox、ack、重试、wake/queue
├── workspace.ex      # filesystem copy / shared policy / optional Git adapter
├── context.ex        # ExecutionContext 构造、验证、传播
└── supervisor.ex     # Coordinator、Dispatcher、恢复任务
```

Web 层：

```text
lib/newbee/web/
├── api.ex            # group/collab RPC 分派
├── socket.ex         # group subscription、cursor、下行帧
└── session.ex        # 接收 collab delivery、启动/恢复成员任务
```

首版不建议把所有逻辑塞进 `Web.Session`；Web.Session 负责单会话运行，Coordinator 负责跨会话事实和策略。

### 8.2 Coordinator 命令接口

内部 API 建议使用明确命令，而不是暴露任意 `GenServer.cast`：

```elixir
create_group(attrs, actor_context)
start_group(group_id, actor_context)
pause_group(group_id, reason, actor_context)
resume_group(group_id, actor_context)
add_member(group_id, session_id, attrs, actor_context)
spawn_member(group_id, parent_member_id, task_attrs, policy, actor_context)
remove_member(group_id, member_id, reason, actor_context)
create_task(group_id, task_attrs, actor_context)
assign_task(group_id, task_id, member_id, actor_context)
send_message(group_id, message_attrs, actor_context)
ack_message(group_id, message_id, stage, actor_context)
progress_task(group_id, task_id, payload, actor_context)
complete_task(group_id, task_id, result, actor_context)
cancel_task(group_id, task_id, reason, actor_context)
get_group(group_id, opts)
replay_group(group_id, since_seq, limit)
```

每个命令都执行：

1. actor/member 身份校验；
2. group/member/task 归属校验；
3. 当前状态机转换校验；
4. policy、深度、fanout、预算和大小限制；
5. 生成事件并同步写入 EventStore；
6. 更新内存 projection；
7. 调度投递并广播 Bus；
8. 返回稳定的结果或错误码。

### 8.3 错误码

建议稳定、可国际化的错误码：

```text
not_found
not_member
forbidden_role
invalid_state
invalid_schema
duplicate_command
duplicate_message
budget_exhausted
fanout_limit
spawn_depth_limit
worktree_unavailable
workspace_conflict
session_unavailable
message_too_large
rate_limited
group_paused
group_cancelled
lease_lost
internal_error
```

错误响应不能把内部文件路径、token、进程信息或完整异常栈直接发给浏览器；详细信息只进入审计日志。

### 8.4 子会话启动策略

`spawn_member` 不应直接在 HTTP 请求进程中同步启动完整模型链路：

1. Coordinator 先提交群事实事件。
2. `Workspace` 准备工作树并返回 opaque workspace id。
3. `Web.Session.ensure` 启动会话进程。
4. session 进程异步 boot evaluator/Loop，沿用现有非阻塞 boot 设计。
5. Dispatcher 投递 `task_assign`。
6. 成员返回 `task_accept` 或 `task_failed`。

HTTP 只等待“成员记录和启动请求已受理”，不等待模型完成任务。前端通过事件看到 `joining → idle/working`。

### 8.5 Workspace 策略

```text
none             只读/讨论成员，不允许写型任务
shared_readonly  可读取指定基准，不可写
 dedicated       独立文件系统副本，允许写和测试；Git 可选增强
shared_write     首版禁用；未来需锁、编辑事务和冲突协议
```

Dedicated worktree 元数据至少记录：

- base commit；
- branch/worktree opaque id；
- owner member/task；
- 创建和清理事件；
- 变更统计与测试结果。

子会话完成后只报告 diff/artifact，不自动把文件复制回父工作树。集成流程：

```text
child result
  -> parent review
  -> diff/impact/test checks
  -> explicit integrate command
  -> conflict check
  -> user approval when policy requires
  -> commit/merge/cherry-pick
```

### 8.6 预算与背压

Group policy 至少包括：

```text
max_members                 默认 8
max_spawn_depth             默认 2
max_active_tasks            默认 8
max_pending_messages       默认 500
auto_wake_per_minute        默认 20
max_task_retries            默认 2
max_group_tokens            可选
max_group_wall_time         可选
max_message_bytes           默认 64 KiB
max_attachment_bytes        默认 10 MiB
```

预算消耗事件必须可观察；当预算耗尽时：

- 不再 spawn 或 wake；
- 已运行任务按策略继续到当前 turn 结束或中断；
- 群组产生 `budget_exhausted` 通知；
- 用户可以提高预算、继续任务或取消群组；
- 不通过重启进程清零预算。

### 8.7 与现有事件总线的关系

协作事件走 `Newbee.Events`/`Newbee.EventStore` 的 durable 事实路径，但使用 `collab_*` 命名空间。Bus 只做实时广播，不是可靠队列。

推荐事件顺序：

```text
append durable event
  -> update projection
  -> dispatch inbox/wake
  -> Bus.emit(:collab_event, envelope)
```

若 dispatch 或 Bus 失败，事件仍然成立；恢复流程根据 projection/cursor 重试投递。

---

## 9. HTTP RPC 设计

### 9.1 Group 管理

沿用现有 `POST /api/<method>` 信封：

```text
group.list(payload)
group.get({groupId})
group.create({title, goal, policy})
group.start({groupId})
group.pause({groupId, reason})
group.resume({groupId})
group.cancel({groupId, reason})
group.delete({groupId})       # 仅软删除
```

返回示例：

```json
{
  "groupId": "grp_01J...",
  "status": "running",
  "goal": "完成认证模块重构",
  "coordinatorSessionId": "20260827-parent",
  "members": 3,
  "activeTasks": 2,
  "unread": 4,
  "cursor": 38
}
```

### 9.2 成员与任务

```text
group.members({groupId})
group.member.add({groupId, sessionId, role, workspace})
group.member.spawn({groupId, parentSessionId, task, role, workspace, commandId})
group.member.stop({groupId, memberId, reason})
group.member.remove({groupId, memberId, reason})

group.task.list({groupId, status, limit, cursor})
group.task.create({groupId, title, description, acceptance, delivery})
group.task.assign({groupId, taskId, memberId, commandId})
group.task.cancel({groupId, taskId, reason})
group.task.retry({groupId, taskId, commandId})
group.task.integrate({groupId, taskId, strategy, commandId})
```

`group.task.integrate` 首版只生成集成计划和检查结果；真正写回父工作树前仍走权限/审批策略。

### 9.3 消息

```text
collab.message.send({
  groupId,
  to: {type: "member" | "session" | "group", id: ...},
  kind: "chat" | "question" | "artifact" | ...,
  delivery: "notify" | "queue" | "wake",
  body,
  taskId,
  commandId
})
collab.message.list({groupId, sinceSeq, limit, kind})
collab.message.get({groupId, messageId})
collab.message.ack({groupId, messageId, stage: "delivered" | "read" | "processed"})
```

首版建议保留 `group.message.send` 作为别名，最终统一到 `collab.message.*`，避免未来把 group 管理和消息语义混在一起。

### 9.4 会话兼容接口

为满足“从一个会话启动其它会话”，可提供受控的内部工具 API：

```elixir
Newbee.Tools.Collaboration.create_group(goal, opts)
Newbee.Tools.Collaboration.send(group_id, to, body, opts)
Newbee.Tools.Collaboration.spawn(group_id, task, opts)
Newbee.Tools.Collaboration.tasks(group_id, opts)
Newbee.Tools.Collaboration.messages(group_id, opts)
Newbee.Tools.Collaboration.report(task_id, result, opts)
```

这些函数必须从显式 `ExecutionContext` 取得发送者身份；不接受模型任意传入 `sender_session_id` 冒充其它成员。

工具文档应接入既有 `tool://Newbee.Tools.Collaboration` 渐进式披露，而不是把长协议塞入系统 prompt。

模型调用 `Newbee.Tools.Collaboration.delegate(title, opts)` 时，运行时从当前 evaluator 上下文取得父会话身份；没有工作组会自动创建模型协作组。子代理 ID 由运行时生成，默认进入独立文件系统副本；成员最多 12 个、任务最多 64 个。

---

## 10. WebSocket 与实时协议

### 10.1 连接模型

保持现有连接兼容：

```text
GET /ws?session=<sid>
```

增加群订阅控制帧：

```json
{"type":"subscribe_group","groupId":"grp_01J...","sinceSeq":0}
{"type":"unsubscribe_group","groupId":"grp_01J..."}
{"type":"ack","groupId":"grp_01J...","seq":38}
```

也可支持独立连接：

```text
GET /ws?session=<sid>&group=<group_id>&since=38
```

首版推荐“一个连接、多个订阅”，减少浏览器连接数；服务端必须维护每个 socket 的授权订阅集合。

### 10.2 下行帧

群事件：

```json
{
  "type": "group_event",
  "groupId": "grp_01J...",
  "seq": 39,
  "eventId": 39,
  "topic": "collab_message_created",
  "payload": {
    "messageId": "msg_...",
    "senderMemberId": "mem_...",
    "kind": "task_progress",
    "taskId": "task_...",
    "body": {"percent": 60, "summary": "测试中"}
  }
}
```

成员状态摘要：

```json
{
  "type": "group_member",
  "groupId": "grp_01J...",
  "memberId": "mem_...",
  "sessionId": "20260827-child",
  "state": "working",
  "busy": true,
  "lastMessageId": "msg_..."
}
```

补发完成：

```json
{"type":"group_sync_complete","groupId":"grp_01J...","cursor":39}
```

### 10.3 认证与授权

- 复用现有远程 Bearer token gate；WebSocket 使用 query token 的现有兼容方式，但日志中必须脱敏 query string。
- 每次 subscribe、send、spawn、ack 都执行服务端授权，不信任连接建立时的 session 参数。
- 当前 actor 若只是 observer，只能读群事件，不能发消息、spawn 或集成。
- 群成员只能看到其有权访问的 group；未来多 actor 时按 group ACL 过滤事件。
- 不把完整项目路径、其它群组 token 或未授权 artifact URL 推给客户端。

### 10.4 背压和断线

- 每个 socket 有界发送队列；慢客户端只丢实时重复通知，不丢 durable 事件。
- 队列超过上限时发送 `resync_required`，关闭或暂停实时流。
- 重连客户端带 `sinceSeq`，服务端从 EventStore 补发。
- 客户端按 `(groupId, seq)` 去重；若检测到 gap，主动请求 `group.events` 补洞。

---

## 11. 前端 WebUI 设计

### 11.1 信息架构

现有布局为“左侧 session 列表 + 中间当前会话 + Mission Control”。建议增加一个 **Groups / 会话群** 层，不破坏单会话模式：

```text
左侧栏
├── 会话
│   ├── 单会话列表
│   └── 群成员标记（属于哪个群、角色、状态）
└── 会话群
    ├── 群组列表
    └── + 新建群组

中间区（选择群组后）
├── 群目标/状态/预算顶栏
├── 群时间线（消息、任务、成员事件）
├── 群任务看板
└── 群 composer（发送 chat / 创建任务）

右侧 Mission Control
├── 成员
├── 任务
├── 文件与 Diff
├── 预算/事件游标
└── 集成审查
```

选择单会话时保持现有 transcript；选择群组时不把群消息混入单会话 transcript，而显示独立群时间线。
### 11.1.1 前端管理与显示流程简图

前端不直接维护群组真相：管理操作提交给服务端，页面状态由群组事件和物化投影驱动。

```text
                                  管理操作
┌──────────────────────────────────────────────────────────────┐
│ 浏览器 WebUI                                                 │
│ 群组列表 · 群详情 · 成员 · 任务 · 时间线 · Diff               │
└───────────────┬───────────────────────────▲──────────────────┘
                │ POST /api/group.*         │ 查询结果 / 增量事件
                ▼                           │
         ┌──────────────┐             ┌─────┴────────────┐
         │ Web.Api      │             │ Web.Socket        │
         └──────┬───────┘             └─────▲────────────┘
                ▼                           │ group_event / sync
┌───────────────────────────────────────────┴──────────────────┐
│ Collaboration.Coordinator                                   │
│ 权限、状态、预算、幂等校验；写事件；调度成员                    │
└───────────────┬───────────────────────────┬──────────────────┘
                │ durable event             │ task/message delivery
                ▼                           ▼
       ┌─────────────────┐          ┌────────────────────────┐
       │ EventStore       │          │ Dispatcher              │
       │ + GroupProjection│          │ Web.Session / Agent.Loop│
       └────────┬────────┘          └───────────┬────────────┘
                │ query / snapshot              │ progress / result
                └──────────────┬────────────────┘
                               ▼
                    Coordinator 更新事件并广播
```

**管理路径**：用户点击创建群、spawn 子会话、分派任务、暂停或集成时，WebUI 调用 `group.*`/`collab.*` RPC。服务端完成权限、状态、预算和幂等校验后才接受命令；前端先显示“已受理”，最终状态以事件确认，不能根据按钮点击直接假定成功。

**显示路径**：首次打开群组时通过查询 API 加载 snapshot 和事件窗口；运行中由 WebSocket 推送增量事件。浏览器按 `groupId + seq` 去重，更新成员状态、任务卡、时间线和未读数。发现序号间隙时暂停局部投影，使用 `sinceSeq` 补发后再恢复显示。

**界面分工**：

- 左侧栏管理群组选择、创建和未读入口；不承载完整消息历史。
- 中间区显示当前群目标、状态、群时间线、任务操作和消息 composer。
- 右侧 Mission Control 显示成员、任务、预算、游标、Diff 和集成审查。
- 点击成员或任务结果可以打开对应 session/diff，但不自动切换当前会话、不自动合并代码。


### 11.2 最小可用 UI（P0）

1. 群组列表：标题、目标摘要、运行状态、成员数、未读数、最近活动。
2. 新建群组弹窗：标题、目标、初始策略和是否立即启动。
3. 群详情：成员卡片、状态点、当前任务、最近消息。
4. 从当前会话“启动子会话”：任务描述、角色、工作区模式、预算确认。
5. 任务卡：待处理/运行中/阻塞/完成，显示负责人和结果摘要。
6. 消息 composer：选择目标、消息类型、delivery 模式；普通文本默认 `notify`。
7. 子会话结果卡：summary、文件、测试、artifact、查看 diff/打开会话。
8. 暂停/取消群组及确认对话框。

### 11.3 消息与任务视觉区分

- `chat`：普通气泡/时间线项，显示发送者头像或 session 名。
- `task_assign`：任务卡，显示验收条件、工作区和 lease 状态。
- `task_progress`：进度条/状态标签，不重复刷屏，按 task 合并展示。
- `task_result`：结果卡，显示成功/失败、测试、diff 和下一步按钮。
- `approval_request`：高对比度审批条，明确“谁请求、改什么、影响哪个工作树”。
- `system/error`：不可编辑的事件项，可展开查看 correlation id。

消息正文中的 Markdown/链接/代码仍按现有 WebUI 安全渲染路径处理；不能直接把 HTML 作为可信内容插入 DOM。

### 11.4 前端状态模型

建议新增：

```js
state.groups = new Map();
state.activeGroupId = null;
state.groupEvents = new Map();       // groupId -> bounded event list
state.groupCursors = new Map();      // groupId -> last seq
state.groupMembers = new Map();
state.groupTasks = new Map();
state.groupUnread = new Map();
state.groupSubscriptions = new Set();
```

事件处理要求：

1. 收到 `group_event` 先校验 groupId、seq 和 schema。
2. `seq <= cursor` 丢弃重复事件。
3. `seq > cursor + 1` 标记 gap，暂停局部渲染并请求补发。
4. 事件投影到 members/tasks/messages，再更新 DOM；不要每个 token 重建整个群页面。
5. 切换群组时只加载窗口，滚动到顶部再分页读取旧事件。
6. socket 重连后先 sync，再解除 loading 状态。

### 11.5 前端交互细节

- 从会话页点击“加入/查看群组”时保留当前 session 页面状态。
- 子会话启动后自动在左栏显示成员条目，但不自动切换用户当前会话。
- 点击成员卡片可打开其 session transcript（只读/可切换），返回群组不丢群时间线。
- 任务结果中的“查看 diff”打开 Mission Control 的 Diff tab，不自动应用。
- “集成”按钮必须展示 base commit、变更文件、测试结果和冲突检查；危险操作走现有权限条。
- 群组暂停时 composer 仍可发送 `notify`，但禁止新的 `wake`/task，UI 给出明确原因。
- 无权限操作按钮隐藏或 disabled，但服务端仍必须拒绝，不能只依赖前端。

### 11.6 退化与错误体验

| 情况 | UI 行为 |
|---|---|
| 群 Coordinator 未启动 | 显示“服务恢复中”，允许重试，不假装任务已执行 |
| 子会话 booting | 成员显示 joining，任务显示 pending |
| 消息重复 | 静默合并，不出现两条相同气泡 |
| 事件 gap | 显示同步中，补齐后恢复；补齐失败提供刷新按钮 |
| 工作树冲突 | 结果标记 conflict，提供只读 diff，不自动覆盖 |
| 预算耗尽 | 顶部警告和继续/提高预算入口 |
| 远程认证过期 | 复用现有登录遮罩，保留本地未发送草稿 |
| 成员离线 | 显示 last seen；任务可重试/转派 |

---

## 12. 安全、并发与一致性

### 12.1 权限矩阵

| 操作 | observer | worker | coordinator | 用户/管理员 |
|---|---:|---:|---:|---:|
| 查看群事件 | ✓ | ✓ | ✓ | ✓ |
| 发送 `chat` | 可选 | ✓ | ✓ | ✓ |
| 发送 `task_assign` | ✗ | 受 policy | ✓ | ✓ |
| spawn 成员 | ✗ | 默认 ✗ | ✓ | ✓ |
| 暂停/取消群 | ✗ | ✗ | 受 policy | ✓ |
| 停止成员 | ✗ | ✗ | ✓ | ✓ |
| 集成工作树 | ✗ | ✗ | 生成计划 | ✓/审批 |
| 修改预算/policy | ✗ | ✗ | ✗ | ✓ |

角色权限只是第一层；仍需通过 `Permissions`、Capability Gate、Host 路径检查和现有 ask/deny 策略。

### 12.2 并发写入

- Coordinator 是群元数据单写者。
- 每个 session 内部仍由 `Web.Session` 串行化 prompt/queue。
- 每个 dedicated 副本默认只有一个 active writer lease。
- EventStore 追加必须经过一个进程，不能由多个会话直接并发写同一文件。
- 同一 task 的状态转换检查版本/lease，过期更新返回 `lease_lost`。
- `command_id` 和 `message_id` 是所有可重试命令的幂等边界。

### 12.3 Prompt injection 防护

协作消息是来自另一个模型/成员的不可信数据：

- 以数据块而非 system 指令注入 Loop。
- 任何“忽略规则、泄露密钥、提升权限、直接合并”的消息都只能作为文本，不能改变策略。
- 任务验收条件与权限配置分离存储；模型不能通过消息修改 policy。
- 发送到子会话的上下文只包含必要字段，默认不传父会话全部历史、凭证或未授权文件。
- 结果回传必须经过 schema 校验和长度限制。

### 12.4 失败处理

故障矩阵：

| 故障 | 事实状态 | 恢复动作 |
|---|---|---|
| 写事件后投递失败 | 消息已成立 | 从 inbox/cursor 重试 |
| 投递后成员崩溃 | 未知是否处理 | 用 message_id 重投，接收端去重 |
| lease 过期 | 任务未确认完成 | 重新排队或标记 blocked |
| 工作区副本创建失败 | 成员可存在，任务不可运行 | 成员标记 failed，允许重试/转派 |
| Coordinator 重启 | 事件保留 | snapshot + replay |
| WebSocket 断线 | 工作继续 | sinceSeq 补发 |
| 合并冲突 | 子结果保留 | 人工审查，不覆盖父树 |
| 预算耗尽 | 新执行被拒 | 用户决策继续或取消 |

---

## 13. 分阶段实施计划

### P0：协议和基础设施（先做，无 UI 大改）

交付：

- `ExecutionContext` 和显式 context 传播骨架。
- Collaboration domain structs/schema：Group、Member、Task、Message、Policy。
- 独立 collaboration EventStore/Store、projection、幂等 command。
- 单元测试：状态机、schema、ID 去重、坏尾帧恢复、权限矩阵。
- 不改变现有单会话 UI 和行为。

完成标准：可以在测试中创建 group、添加两个 session、写消息、重启 Coordinator 并重放出相同状态。

### P1：会话间消息

交付：

- `collab.message.send/list/get/ack`。
- Dispatcher 的 notify/queue/wake 基础语义。
- Web.Session 接收协作 envelope；只读 notify 不启动模型。
- WebSocket 多 group subscription、sinceSeq、补发和去重。
- 内部 `Newbee.Tools.Collaboration.send/messages`。

完成标准：A → B、B → A、群广播、离线重连、重复投递均可验证；不会把消息混入普通 transcript。

### P2：从会话 spawn 子会话和任务协作

交付：

- `group.member.spawn` 和异步 boot。
- task 创建/分派/lease/progress/result/retry/cancel。
- 成员角色和预算/深度/fanout 限制。
- dedicated 文件系统副本创建与清理。
- 子会话最小 group context 和结构化 result。

完成标准：父 session 创建两个子 session，两个任务并行执行，分别回传结果；父 session 可按 `task_id` 消费结果；一个子会话失败不破坏其它成员。

### P3：WebUI 群组工作台和集成审查

交付：

- 群组列表、详情、成员、任务、时间线。
- 从现有 session 页面 spawn/查看群。
- WebSocket 事件同步、游标、gap 恢复和未读计数。
- Diff/测试/artifact 结果卡。
- 显式 integrate 流程和审批。

完成标准：浏览器刷新/断线后群状态和消息完整；用户能从父会话发起任务、查看子结果、审查后选择是否集成。

### P4：优化（可选）

- 任务 DAG 可视化和自动调度。
- reviewer/验证会话。
- 更细的多 actor ACL。
- 跨群 artifact 引用和全局经验提炼。
- 共享写工作树的锁/事务协议（在有充分测试前不启用）。

---

## 14. 测试与可观测性

### 14.1 后端测试矩阵

#### 单元测试

- Group/Member/Task 状态转换全部合法/非法边界。
- Message kind/delivery/schema/大小限制。
- `command_id`、`message_id` 重复请求幂等。
- recipient 解析：session/member/group、空目标、跨群目标。
- budget、fanout、depth、rate limit。
- ExecutionContext 序列化、继承和越权拒绝。
- 副本路径、基线快照、清理失败。

#### 集成测试

- Coordinator + EventStore + projection 重启恢复。
- A/B 双会话互发消息。
- 忙碌 session 的 queue/wake 排队与中断。
- 子 session 异步 boot、结果回报和父 session 消费。
- duplicate delivery 不重复启动任务。
- EventStore 坏尾帧、Bus 故障、目标进程崩溃。
- dedicated 文件系统副本并行改动不污染父工作树。

#### Web/API 测试

- RPC 信封、稳定错误码和 auth gate。
- group list/get/create/start/pause/cancel。
- message send/list/ack 分页和游标。
- WebSocket subscribe/sync/gap/ack/权限。
- 不泄露路径、token、未授权成员事件。

### 14.2 前端测试

若当前项目仍无浏览器测试依赖，P0/P1 先采用：

- 纯 JS reducer/schema 测试（可抽为无 DOM 模块）；
- WebSocket frame fixture 测试；
- API mock 测试；
- 手工验收清单。

P3 再引入浏览器 E2E（优先 Playwright），覆盖：

1. 创建群；
2. 从当前 session spawn 子会话；
3. 断线/重连与事件补发；
4. 任务结果和 diff 卡；
5. 切换单会话/群组不串消息；
6. 远程认证过期恢复。

### 14.3 指标和审计

至少记录：

```text
collab.groups_created
collab.members_spawned
collab.messages_created/delivered/processed/failed
collab.wake_attempts/suppressed
collab.tasks_started/succeeded/failed/retried
collab.task_latency_ms
collab.queue_depth
collab.budget_consumed
collab.worktree_conflicts
collab.websocket_sync_gap
```

审计事件必须能从 `correlation_id` 串出：谁发起、哪个 session、哪个 task、哪个工具调用、哪个工作树、结果是什么。敏感字段只记录脱敏摘要。

---

## 15. 迁移、兼容与发布策略

### 15.1 数据迁移

首版无需迁移已有 session transcript。新增目录不存在时惰性创建：

```text
.newbee/collaboration/
```

已有 session 加入群组后只新增 membership 事件和 `meta.json` 的非破坏性关联字段；不要重写旧 transcript。

### 15.2 API 兼容

- 保持 `session.*` RPC 原样。
- 保持现有 `/ws?session=<sid>` 下行帧格式。
- 新增 `group_event`/`group_member` 帧，不改变旧 `event`/`system` 帧。
- API 新方法未知时仍返回现有 `unknown_method`。
- 客户端不支持群帧时继续使用单会话功能。

### 15.3 Feature flag

建议增加显式开关：

```text
collaboration.enabled = false       # 默认关闭，开发阶段可开启
collaboration.max_members = 8
collaboration.auto_wake = true
collaboration.workspaces = "dedicated"
```

开启顺序：

1. 只读事件和群列表；
2. notify 消息；
3. queue/wake；
4. spawn；
5. worktree 集成。

每一步都可独立回退，不因关闭 UI 而删除事件或杀掉已有任务。

### 15.4 发布前检查

- `mix format --check-formatted`。
- `mix compile --warnings-as-errors`（若项目发布配置适用）。
- `mix test` 全量及协作专项测试。
- 检查 `.gitignore` 和 `git ls-files`，不得包含 auth、证书、私钥、token。
- 进行一次进程重启/浏览器断线恢复演练。
- 验证默认关闭时旧 session 的 CPU、内存和事件路径无明显回归。

---

## 16. 待确认决策

以下事项建议在开始 P0 实现前确认；本文给出了推荐默认值：

| 决策 | 推荐值 | 需要确认的原因 |
|---|---|---|
| 一个 session 是否可同时进多个 active group | 否，首版最多一个 | 降低身份、预算和 UI 复杂度 |
| 普通消息是否自动唤醒模型 | 否，默认 notify | 控制成本，避免反馈循环 |
| 父会话停止后的子会话 | continue | 防止 UI/父进程重启误杀工作 |
| 子会话写区 | dedicated 文件系统副本 | 防止静默覆盖 |
| 子任务最大深度 | 2 | 避免无界递归 spawn |
| 默认最大成员数 | 8 | 防止资源爆炸 |
| 结果是否自动合并 | 否 | 合并是高风险副作用 |
| 群事件是否进入 session transcript | 否 | 保持单会话历史语义纯净 |
| 首版是否支持 attach 已有 session | 支持 observer/reviewer，worker 需显式授权 | 兼顾复用和隔离 |
| 首版是否支持多用户 ACL | 保留字段，先单用户/单 actor | 控制范围 |

---

## 17. 最终验收场景

### 场景 A：双向消息

1. 创建群并加入 session A、B。
2. A 发送 `chat` 给 B，B 在线收到一条带 `message_id` 的群事件。
3. B 回复 A，A 收到并显示来源。
4. 重复发送同一 `command_id`，UI 和事件投影不重复。
5. B 断线期间 A 发送消息；B 恢复后从 `sinceSeq` 补到消息。
6. 消息不会出现在 A/B 的普通用户 transcript 中。

### 场景 B：父会话启动子会话

1. A 创建并启动群。
2. A 通过内部工具或 UI spawn 两个 child session。
3. 系统为每个 child 建立独立 evaluator、Loop、ExecutionContext 和 dedicated 文件系统副本。
4. 两个 task 并行运行，互不覆盖父工作树和彼此工作树。
5. child 回传 `task_result`，包含 summary、测试和 artifact/diff 引用。
6. A 被 `wake` 一次并消费两个结果；重复投递不重复执行。
7. A 审查 diff 后显式 integrate；冲突时系统拒绝自动覆盖并保留子结果。

### 场景 C：故障恢复

1. Coordinator 写入任务后立即崩溃，重启后从事件流恢复 task。
2. child 在处理消息时崩溃，重启后收到同一 `message_id`，只处理一次。
3. WebSocket 在事件 10 和 15 间断线，重连请求 `sinceSeq=10`，补齐 11–15。
4. EventStore 尾部存在半帧，启动时截断坏尾帧，已确认事件不丢。
5. 父 session 重启，群和子任务继续；按 policy 决定继续/暂停/取消。

### 场景 D：安全拒绝

1. observer 尝试 spawn，返回 `forbidden_role`。
2. 子会话消息要求读取项目外秘密路径，仍被 Host/Capability Gate 拒绝。
3. 消息正文要求自动合并，系统不改变 integrate policy。
4. 超过 wake、成员、消息或 token 预算，新的执行被拒绝并产生审计事件。
5. 两个 writer 试图取得同一 worktree lease，后者收到 `workspace_conflict`。

---

## 18. 实现进度

当前已落地 P0/P1 以及 P2 的基础任务能力：

- P0/P1：群组、成员、消息的单写者 Coordinator；EventStore 持久化与重放；HTTP RPC；WebSocket 群事件；WebUI 群组工作台；父会话 spawn 子会话。
- P2 基础：Task 创建、分派成员、状态更新（accepted/running/blocked/succeeded/failed/cancelled）、进度/结果字段、任务事件重放和 WebUI 任务栏。
- P2 完整闭环：指派后自动投递结构化任务到目标会话；`Newbee.Tools.Collaboration` 提供 report/send_message/tasks；终态结果一次性回收通知创建者。
- P3 基础：任务 lease/claim 防重复领取；群组 running/paused/cancelled 状态控制；WebUI 提供暂停/恢复和未分配任务领取。
- P3 协作安全闭环：只有协调会话可修改群状态；claim 会绑定 lease_owner/lease_until/attempt 并投递到领取者；owner 可在 30-3600 秒范围续租；任务终态向创建者会话一次性回收结构化结果。
- 自动分派：任务创建并指定成员时，Coordinator 立即把结构化任务提示投递到目标 Web.Session 队列（忙时排队、空闲直接执行）；任务提示带来源标记与 group/task/session id。
- 模型工具：`Newbee.Tools.Collaboration`（已注册内置插件）供子会话调用——report 更新任务状态/进度/结果，send_message 发群消息，tasks 查询列表。
- 当前仍未落地：显式 wake/queue 分档调参和更丰富的集成策略；文件系统副本隔离、基线快照、审查、冲突检测、显式应用与清理已落地。


实现验证以代码测试为准：协作领域/API/Socket 专项测试覆盖消息双向传递、命令和消息幂等、成员权限、任务状态机、重启恢复与群事件帧。

## 19. 总结

会话群的本质是 **可恢复的多会话协作调度**，不是聊天 UI 的扩展。正确的落点是：

```text
独立 Session 执行
      +
Group/Task/Message 事件模型
      +
单写 Coordinator
      +
显式 ExecutionContext
      +
可靠投递与游标恢复
      +
默认 worktree 隔离
      +
前端群时间线与任务看板
```

按 P0 → P1 → P2 → P3 实施，可以先获得可测试的消息基础，再增加自动执行和工作区集成；任何阶段都不需要破坏现有单会话 transcript、WebSocket 或权限边界。
