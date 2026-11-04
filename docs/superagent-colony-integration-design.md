# newbee 蜂群与 dsh-superagent 融合设计

> 状态：v0.4 已实现原会话工作流、可靠输入回执、安全成果采用、受控本地/GitHub 来源与有限自动规则。实现及验证范围见[运行与验收](conversation-work-operations.md)。真实用户持续采用与模型质量仍需试点测量。
>
> 参考实现：[deepseek-ai/dsh-superagent-prototype @ 6337fc8](https://github.com/deepseek-ai/dsh-superagent-prototype/tree/6337fc823ce20251c8de8085948165c81aaa701e)。该项目声明为研究原型，以下区分“源码中存在的机制”和“机制可能带来的收益”；没有实测数据就不宣称收益已被证明。
>
> 本地核对基线：`e78f05872cdbaf50886fcd84aaf1e18053424f78`。关联：[newbee 总体设计](../DESIGN.md)、[蜂群协作 v2](bee-colony-collaboration-design.md)、[跨主机协作](cross-host-collaboration-design.md)、[项目聊天室](project-chat-design.md)。

## 1. 第一性原理

人提出的不是一串待分类的消息，而是一项希望得到结果的委托。Agent 系统的首要责任，是接住委托并持续负责，直到产生可用结果、遇到确实需要人的决定，或被授权的人明确停止。

设计按以下次序判断，而不是按模块数量或 Agent 数量判断：

1. **有价值的结果**：是否完成了请求，证据是否真实，结果是否能被人检查和使用？
2. **人的注意力**：人花了多少时间重复解释、找负责人、追状态、处理噪声或救回丢失工作？
3. **责任连续性**：每条有效输入是否都有明确处理者，工作是否能跨消息、模型轮次、进程重启和执行者替换继续？
4. **权限与可恢复性**：执行是否来自真实授权，越界、重复和不确定副作用是否能被阻止或显式呈现？
5. **系统代价**：完成质量和人工时间是否值得模型、运行资源与维护成本？

目标不是“自动处理更多消息”，而是在不降低交付质量和安全性的前提下，减少人从委托到可用结果所付出的总成本。增加 Bee、讨论轮数、通知量和代码抽象本身都不是收益。

### 1.0 使用方式是首要约束

用户明确反馈旧蜂群基本弃用，主因是易用性、可用性与操作习惯。v0.3 虽强调少占注意力，仍过多沿用了蜂群入口和阶段操作；本版改为交互先行。

日常契约是：继续在原会话提出需求、补充、回答和看结果，系统在后台选择协作者；用户不必先建群、选 Bee、给 AI 填分工表。普通问答不强制创建 Task/验收；后台工作才显式持久绑定，查看过程不能改变输入收件对象。

具体操作、六条使用故事、目录与采用语义、故障恢复、旧用户迁移和操作验收以[使用与操作设计](superagent-conversation-ux.md)为准；[交互原型](superagent-conversation-prototype.html)供先行走查，所有演示数据不代表真实执行。Colony 作为后台复用能力，不再要求用户先进入 colony.html。


### 1.1 dsh-superagent 的本质

dsh-superagent 的核心不是 GitHub 接入器、Ticket 看板或一组新提示词，而是一种以人为中心的托付纪律：

- 只处理允许的人明确提出的工作，或团队书面规则允许观察/处理的事件；新规则先观察其判断，不直接自动执行。
- 先判断输入是否属于已有工作，再考虑是不是新工作。订阅线程把后续消息交给原工作负责人；负责人可在既有授权内处理，也可说明理由交回路由。
- 工作有稳定 Ticket、授权 Mandate、当前 Assignment 和专属执行上下文。Ticket 不等于一个模型会话；会话可以结束、重建或被替换，工作的目标、输入和授权仍然存在。
- 人只在能使用结果、必须做决定、需要提供权限/资源，或系统确实无法继续时被打扰。常规进度、模型重试和可自行修复的问题留在系统内部。
- 交付回到原请求渠道，并区分“正在做”“需要人决定”“可供人检查”和“已经完成”。开了 PR 或模型说 done 不自动等于请求已交付。

这些机制的合理收益是减少重复描述、人工转派、遗漏跟进和无效通知，同时让一项工作更容易从失败或重启中接续。它们是因果上合理的设计假设，不是此原型已经证明的质量提升。

### 1.2 不应照搬的结论

参考实现是面向一个 GitHub 仓库、运行在 DeepSeek Harness 上的研究原型。它不能证明多 Source 的生产可靠性、模型判断质量或远端副作用“恰好一次”。newbee 已经有自己的 Bee、Task、Workflow、Session、Workspace、成果验收和插件治理；融合不应再建一套 Ticket、Executor、策略 UI 和任务存储。

## 2. newbee 已有什么，真正缺什么

| 当前 newbee 能力 | 源码中已存在的语义 | 设计处理 |
| --- | --- | --- |
| `Colony.Interaction.say/3` | 从蜂群对话创建工作、补充工作、暂停/恢复并显示真实工作卡 | 复用命令语义，默认入口移到原主会话；旧蜂群页仅历史/高级入口 |
| `Colony.Work`、`Colony.Task` | 一个负责人、工作约束、revision、request_id 幂等、Work Store 事务 | Task 是唯一工作实体；新来源复用或扩展这些写路径 |
| `Colony.Workflow` | 负责人先判断是否独立完成或需要讨论/提案/子工作 | 保留蜂群的选择性协作；它不同于 Source 准入，不新增第二次接单评估 |
| `Colony.Runtime`、`Workspace`、`Web.Session` | 工作区、会话、Delivery、工具活动、ask 和 done 回报 | 执行仍由现有 Runtime 负责；补充输入回执和执行代次 |
| `Colony.Work.submit/review`、`Honey` | 成果、工作版本、证据、限制和人类验收 | 保留为完成与验收权威，不被讨论结论或 PR 状态替代 |
| `Colony.Control` | 经授权的工作/成员/蜂群暂停与中断 | 继续是执行控制权威，Source 和自动规则必须遵守 |
| `Collaboration.Chat.Room` | 有限预算的代表讨论、结构化提及、独立意见和决议版本 | 讨论仍是讨论，不自动成为任务授权或工作输入 |
| `Newbee.EventStore`、Plugin Contract、Capability Gate | 环境事件/插件演化/插件能力治理 | 不把插件能力声明误当成每个 Task 的隔离沙箱 |

主要缺口不是“少一个 Ticket 系统”，而是：

- 外部来源缺少统一的稳定事件身份、重投去重和原请求回复路径；
- 线程/工作之间缺少明确的“谁负责处理这条后续输入、何时交回路由”的持久规则；
- Session 队列、Delivery 状态、问题答复和执行报告之间缺少足够的持久关联，难以证明输入被读取、问题被正确回答或旧执行者已经失效；
- 自动发送遇到“远端已成功但本地没收到回执”时，没有诚实且可恢复的 unknown 语义；
- 完成后的跟进、待验收成果、暂停工作和终止工作边界不应只靠聊天相似度猜测。

要补的是跨越现有入口、Task 和 Runtime 的责任闭环，而不是复制 dsh 的基础设施。

## 3. 融合后的心智模型

```text
人或规则提出一项委托
  → 先鉴权，再判断它属于哪个已有工作
  → 已有工作：交给该工作的唯一负责人；超出授权时交回路由
  → 新工作：按现有 Work/Workflow 创建，必要时由 Bee 决定是否协作
  → 每次输入、执行尝试和成果都关联同一个 Task 与工作版本
  → 只在结果可用或需要人的明确动作时通知人，并回到原渠道
```

外部事件只是不同的输入适配器。稳定工作对象仍是 `Newbee.Colony.Task`；一个 Task 仍由一个当前负责人对结果负责。多 Bee 讨论、子任务、集成是完成复杂工作的手段，不是每个任务的固定拓扑。

### 3.1 概念映射与取舍

| dsh 概念 | newbee 落点 | 决策 |
| --- | --- | --- |
| Source | 现有 Interaction；未来的 Source 插件/服务 | 新 Source 翻译输入并发送回复；不创建任务、不决定权限 |
| Trigger | Task 输入/来源回执中的稳定外部引用 | 首版作为受理和审计数据，不另建一套全局 Trigger 数据库 |
| Thread | 已验证的来源会话引用；可属于 Task 的工作线程或上下文线程 | 线程关联用于找工作/提供上下文，不等于授权 |
| Gate / Admission | 现有成员认证与 RPC 权限 + 最小来源策略 | 明确授权的请求直达现有工作入口；推断工作后置且默认 observe |
| Eval | 仅对歧义路由或明确启用的自动规则评估 | 不新增常驻 orchestrator；蜂群协作 triage 仍由现有 Workflow 决定 |
| Mandate | Task 上的来源、授权依据和既有约束快照 | 不新建独立授权实体；复用 created_by、source、constraints、acceptance、approval_required 等并补来源版本信息 |
| Ticket | `Colony.Task` | 唯一工作实体，不建平行状态机或第二个 Ticket Store |
| Assignment | Task/Delivery 上的当前执行代次及 Session/Workspace 绑定 | 仅增加防止重复/过期报告所需的 generation 与回执，不复制完整 Executor 子系统 |
| Attention | 现有 Task `question` / `waiting_for` / ask transcript | 补稳定 question id 和答复关联，不另建问题聊天室 |
| Outbox | 现有 Task `deliveries` 加必要的来源回复队列 | 先可靠派发和投递；不建设包办所有副作用的通用效果平台 |
| Result | `Honey` 与现有 Work review | 保留成果、版本、证据和人工验收 |

在代码需要统一来源上下文时，最小 `origin_ref` 至少标识 `project/colony/source_instance/native_event/version`。显式 UI 请求可以沿用现有字段；只有外部来源/自动规则才需要相应的来源回执。不要为了统一术语把所有现有本地操作都迁成新协议。

## 4. 收件和路由规则

先做确定性身份验证和归属判断，最后才调用模型。流程必须让每条输入有处理结果，而不能用“再跑一个 LLM”掩盖路由不明。

1. **身份与目标校验**：确认项目、蜂群、设备/成员、Source instance 和操作权限。原始消息自称“人类”、显示名、正文 `@name` 或外部 JSON 都不是身份凭据。
2. **明确控制**：暂停、恢复、停止、验收和批准走现有的具体授权命令；模型只能识别意图，不能代替权限检查。
3. **明确问题答复**：带 `question_id` 的答案只交给对应 Task；来源 `reply_to` 可确定唯一问题时可映射，否则提出一个具体澄清，不把答复猜给多个问题。
4. **已有工作输入**：通过显式 Task/PR/回复关系，或一个唯一、授权且仍可接收输入的线程归属路由。主题相似和“最近的工作”不能独自决定归属。
5. **新工作请求**：经认证入口明确创建，直接进入现有 `Interaction`/`Work.create`/`Workflow`；不得再新增一次“是否授权”的模型评估。
6. **规则触发或来源歧义**：仅在 Source 配置和规则允许时进行有预算的路由评估。新规则默认只记录系统本来会怎么处理；只有验证后显式启用才自动创建工作。
7. **无匹配/多匹配/越权**：无授权则拒绝并记录；多个可行 Task 时问一个具体问题；负责人交回的输入才进入新工作路由，不丢失原始消息。

每个输入都要落下可查询的 disposition：`delivered_to_task`、`context_only`、`handed_back`、`accepted_as_new_work`、`ignored_by_policy`、`needs_human_route` 或 `rejected`。同一条人类输入可以被其他订阅工作作为上下文看到，但同一时刻只有明确的工作负责人拥有“处理并回复这条请求”的责任。

跨线程关联只带来上下文。CI、bot 和其他机器事件默认既不产生人类授权，也不重启终止工作；只有 Task 明确订阅且当前流程等待这类事件时，才唤醒该工作。

## 5. 持续责任，而非每条消息重开任务

### 5.1 Thread 订阅分两种

- **owned thread**：这是工作请求、明确关联的 Issue/PR/对话，或用户显式附加的线程。人类跟进进入当前负责人；负责人判断它是否在 Task 当前约束内。
- **context-only thread**：用于 CI、依赖工作或旁支讨论上下文。消息可读，但不授权写入、不自动成为人类答复，不单独唤醒已结束工作。

如果一条 Trigger 同时属于多个线程，owner 由主线程/显式关联决定；其他关联只增加上下文。所有订阅都要能够说明其来源和用途。

### 5.2 负责人处理或交回

- 在既有目标和约束内的修复请求、review feedback、失败测试和澄清，交给原负责人，带上明确输入 ID，并复用其 Task/Workspace 与历史证据。
- 负责人判断超出授权、指向另一项工作或关联不明确时，持久化一次 `handback` 和理由；路由系统随后创建/关联其他 Task，或问人。已交回的消息不重复进入同一轮路由。
- 输入被投递到 Session 不等于已阅读；只有被纳入一次模型请求或被明确处理，才记为 consumed。执行结束时仍未 consumed 的输入回到路由队列，不能随旧 turn 一起丢失。
- 同一 Task 同时只有一个当前写入负责人。复杂任务可通过已有 Workflow 创建有限的子任务/协作 Bee；阶段完成由集成负责人合成并做组合验证。

这直接借鉴 dsh 的“订阅线程后续先由原 Worker 决定、越权再 handback”的机制。它减少人重新找成员、复制背景和重新建单的负担，同时避免“任何提及都把消息发给所有 AI”。

### 5.3 工作结束后的跟进

newbee 当前 Task 的 `done/failed/cancelled` 是终态，且完成后的 Honey 可能已验收；不能为了仿照 dsh 而悄悄复活同一个终态记录。

- `blocked`、待答问题和待验收成果仍是原 Task 流程，使用现有 continue/revise/review 规则。
- 对已验收成果的后续修正、同一 PR 后续反馈或与原请求明确连续的追加工作，创建**关联的后续 Task**，默认路由给原负责人并引用原 Task、来源线程和旧成果；新的输入重新记录授权和约束。这样保留一条责任链，又不篡改已经验收的 Honey。
- `cancelled` 不因普通跟帖复活。新的人类请求可显式创建新 Task；不能沿用已撤销/不适用的 Mandate。
- 机器事件不能创建上述后续 Task，除非已明确配置等待该事件的自动规则和预算。

因此 continuity 是“同一工作脉络和负责人可接续”，不等于“终态对象永远重新打开”。

## 6. 权限和工作范围

授权分清三个层次：

1. **谁能发命令**：现有 Colony Membership、设备认证、`Control.authorize` 和具体 RPC 权限；
2. **人要求做什么**：Task 的 title/description/acceptance/constraints/facts/approval_required，以及来源、请求人和输入引用；
3. **宿主实际允许什么副作用**：现有 Host Safety、Capability Gate、Workspace 隔离和工具权限。

这些层次不能互相代替。`CapabilityGate` 能校验插件图中的能力类别，不会自动把通用 `run_elixir` 限制成一个 Task 的安全沙箱。自然语言 `scope` 适合描述工作目标，不是可强制执行的文件或命令 ACL。

外部来源的授权凭据由 Host/Source 持有，模型只看到必要的脱敏身份、许可范围和资源引用。跨主机代表身份按认证凭据映射，不按显示名合并。引用别人的 PR、聊天决议或 Worker 摘要是证据，不扩大当前 Task 的授权。

对显式用户请求，复用创建工作时的成员权限和现有 approval_required 规则，不因新增 Source 额外强制确认。对未点名事件的自动执行，先用精确 allowlist/scope、`observe` 基线和独立预算；不能从“当前工作订阅了一个 Thread”推导出“任何参与者都能扩充写入范围”。

策略变化不改写历史输入和已有成果。对工作有实质影响的规则/权限变化，作为有版本的 Task 输入告知负责人；授权撤销、暂停和高风险动作限制在实际派发/执行边界生效。已取消工作不能靠 CI、bot 或普通 follow-up 自动解锁。

## 7. 蜂群分工：借鉴责任制，不复制单 Worker 拓扑

dsh 的每个 Ticket 一个 Worker/目录，让长工作有明确 owner；newbee 的 Hive/Colony 优势是多个有边界的 Bee 可以提案、拆分、执行、集成和验收。两者兼容的规则是：

- 一个 Task 始终有一名负责人，负责输入路由、工作推进、结果合成和交付回原渠道。
- 一个普通小 Task 默认由一个 Bee 直接做完，不开全员讨论，不增加协调任务。
- 负责人可以依据风险、独立性、专业能力和并行收益，使用现有 triage/workflow 邀请有限 Bee；每个子工作需有明确交付、边界和依赖。
- 讨论只提供候选方案；实施授权仍来自用户/Task。独立意见、会议消息和多数赞成不构成权限或正确性证明。
- 同一写入 Workspace 不得被两个并行 Bee 同时修改。继续使用现有隔离 Workspace/独立工作树，最终由负责人集成并重测。
- 人应能继续已有 Task，而不被新工作占满所有并发槽；并发限制与控制权由 Colony Runtime/Control 管理。

现有 `workflow: true` 新工作可能进入 triage，再进入提案/讨论/choosing。保留它的后端选择性协作能力，但修改前台必经操作：明确授权的实施不能因系统内部讨论而等待用户勾选 Bee 或填写分工表，负责人须在既有约束内推荐并安排分工；用户明确“先给方案”或遇到业务/权限取舍时，才停下来问人。P0 应验证这条自主推进路径，不能以“复用现有 Workflow”为由保留被弃用的操作负担。

triage 是协作判断，不是 Source 准入，不能再叠一次相同的模型调用。是否给简单任务跳过 triage，仍通过真实成本和完成质量比较后决定。


## 8. 少打扰但不隐瞒的交付规则

面向用户的系统按“人是否必须做事”安排通知，而不是按 Agent 每做一步就发一条进度。

- 接单确认一次，简短说明目标和负责人；工作中状态保存在 Task/工作卡，不连续发 IM。
- 只有可供人检查/使用的结果、需要的权限/资源/具体决定、或确实无法继续且需要人处理时，才发主动消息。
- 负责人能自行修复的测试失败、普通 provider retry、还在跑的 CI 和未完成草稿留在后台。发现问题但仍可在授权内继续，不等于要打扰人。
- 问题采用一个结构化、具体、可回答的 ask，并关联原输入与来源渠道；答复只能结束对应问题版本。缺少权限时“同意继续”的自由文本不替代宿主授权。
- Ready、draft、blocked、failed、cancelled、merged 等词采用可核对定义。开 PR 不是 ready，测试通过不代表需求完成，未验证必须说明。
- 最终结果或必要问题回到提出请求的原对话；不要要求人去 dashboard 猜是哪一项工作。WebUI/工作卡做完整状态，消息只承载人此刻有用的信息。
- 工作按影响和授权边界停止，不按固定轮数或改动行数停止。授权内的局部实现、相关测试和常规 review fix 可以继续；需要改变现有调用约定、跨多个独立模块重设职责、提高权限或执行不可逆动作时才暂停问人，并指出具体影响。

真实收益应体现为人少追问、少路由、少复制上下文，且交付不退化；静默失败和把所有状态藏进 UI 都不符合目标。

## 9. Task 视图和问题状态

Task 当前 status 是业务事实；用户看到的 `stage` 是由状态、Control、Delivery、question、Workflow 和 Honey 派生的单一 projection，不要另行持久化一份可漂移状态。

建议投影优先级：

| stage | 依据 |
| --- | --- |
| `ended` | Task 为 done/failed/cancelled；终态原因和结果另行展示 |
| `paused` | Colony/Bee/Task Control 有效 |
| `needs_delivery` | 关键输入或结果有永久失败/unknown，且需要重试、核对或放弃 |
| `needs_answer` | Task 当前有一个 open 阻塞问题 |
| `needs_review` | 有对应当前 context_revision 的 Honey 待验收 |
| `blocked` | 权限、环境、依赖或执行明确受阻，但不是问题等待或待验收 |
| `queued` | Task/Delivery 已持久化，尚无当前活跃执行名额或 Session turn |
| `working` | 当前负责人有有效 turn 或被跟踪的后台工作 |
| `waiting` | 没有待执行输入/工作，明确等待新的来源事件或人类跟进 |
| `inconsistent` | 当前事实互相矛盾，进入诊断，不默认伪装成 working |

映射要根据实际 Task/Delivery/Workflow 字段定义并由表驱动测试覆盖，不能假设内部 status 已一一对应。来源回帖失败作为独立沟通问题，不把已验收 Task 改回未完成。UI 的优先列表突出 needs_answer、needs_delivery、blocked、needs_review；正常重试和健康状态不制造新通知。

`ask` 继续复用 Runtime 已写入 `task.question` 的行为，补稳定 `question_id`、Task/执行代次、来源回复引用和 answer receipt。一个 Task 首版最多一个 open 阻塞问题；替换时关闭旧问题并撤销未发送的旧问句。answer、skip、timeout 是不同事实；skip/timeout 不是批准。已有 Colony Web UI、Session queue 和 Colony Runtime 是要补齐的边界，不新建 Attention 服务。

## 10. 持久化权威与恢复

### 10.1 首版单写者

Colony 当前由 `Colony.Store` 串行处理事务，并以 JSON 快照持久化 Task、Delivery、Trace 等。第一阶段明确选择它作为 Colony 自动接入域的写入权威：将新 receipt/input/outbox 记录纳入同一 Store schema 与事务；在提交前不确认 webhook/桥接请求，不启动 Runtime/网络效果。

创建 Task 不能用 `Engine.create_task/2` 后再分别写授权、Trigger 和回执，因为该入口当前先写 Task，再写 Trace，再尝试派发。应扩展 `Work.create` 的纯状态构建/事务路径；已有 Task 的 follow-up 要扩展 `Work.continue/revise`，在同一事务中去重请求、写输入、更新工作版本并创建现有 Delivery。Store 事务回调内不再嵌套调用 Store、LLM、文件操作、Session 或网络。

每个命令/输入的去重键至少限定：

```text
project_id + colony_id + source_instance_id + native_event_id + event_version
```

本地命令使用稳定 `request_id`，并保存 `content_hash`：相同 ID 和相同内容返回原 receipt；相同 ID 不同内容返回 conflict。Task 创建、相关输入/trace、执行 Delivery 和首个回复意图必须在一个存储事务中提交，或有明确的下一步恢复记录。

Colony.Store 当前在全局目录，所有 key/query 都必须再限定 project/colony/source instance。外部事件不能依赖进程当前 cwd 定义归属。

### 10.2 EventStore 关系

本首版**不在 Colony.Store 与 Environment.EventStore 之间做同步双写**。`Newbee.Events.emit/2` 的当前实现会捕获持久化异常，返回 :ok 不足以作为业务提交回执；EventStore 的项目 Store 注册方式也不是一个天然的跨 Colony transaction。

因此 P0 的授权事实、输入 disposition、Task/Delivery 和回复意图都以 Colony.Store 及其事务内 Trace 为权威。EventStore 可以异步收集脱敏的分析事件，但失败不能改变已提交 Task，也不能驱动业务恢复。必须把这一域与 `DESIGN.md` §4.6“EventStore 唯一同步事实写入”的差异明确记录；不能同时声称该域已完全 Event Sourced。

将来若要统一 EventStore，必须迁移 Colony 的完整写入边界并重放生成 projections，或提供真正的原子提交协议；只包装两个 Store 调用不是事务。迁移前先做旧快照 bootstrap、全写入口覆盖、确定性重放和故障恢复演练。

### 10.3 提交、回执与崩溃

| 崩溃/失败点 | 规则 |
| --- | --- |
| Colony 事务未提交 | 没有新 Task/Input/Effect；同一请求可以重投 |
| 已提交但调用方未收到响应 | 查询稳定 command/event receipt；不得重复建单或加第二条 Input |
| 已提交、Runtime 尚未唤醒 | 启动扫描现有 pending Delivery/outbox；不能依赖内存 `send` |
| Local Store 写入返回不确定错误 | 用幂等 key 查询快照确认，不假定 rename 之前/之后就是回滚/提交 |
| Source 与 Colony 是两个 Store | Source 持久 outbox 至收到 Colony receipt 再确认；使用 at-least-once + 目标去重，不声称分布式 exactly-once |
| 旧 Assignment 延迟报告 | 留作审计，不更新新代次的 Task/Honey |

当前快照全量编码写入的吞吐与耗时需要在真实工作规模下测量。若高频 Source 使提交/队列过载，先批量接收、控制保留期或再评估存储迁移，不能先假定当前快照无限可扩展。

## 11. 执行、Delivery 与副作用

Colony `Delivery` 是向 Session/远端 Worker 交付输入或启动工作的现有机制，不是外部平台回复的可靠 outbox。第一阶段先强化已有 Delivery，不新增平行调度器。

每个可重试执行尝试至少带有稳定 `delivery_id` 和递增 `execution_generation`；Task/Workspace/Session 是目标。运行回报、done、ask、文件变更集和 Honey 提交都要携带当前 generation/context_revision。旧 generation 的迟到结果可记录但不可覆盖当前结果。

Generation fencing 只能阻止旧 Worker 回报，不会撤销旧进程已经运行的代码。切换 owner 前必须通过现有 Runtime 中断/Control 和 workspace 隔离确认旧写 turn 已停；远端停止无法确认时保持 blocked/unknown，不并行启动第二个写者。

外部回复另用有界、持久的来源发送队列，先只支持 acknowledgement/result/required question：

- 相同 effect key 和相同 payload 复用回执；payload 改变时创建新版本并显式 supersede，不能改写已经发送的消息。
- 能确认未送达的短暂故障按指数退避和次数上限重试；权限/参数错误不无限重试。
- 远端支持幂等 key 时复用同一个 key；支持可靠查询时先核对；两者都不支持且发送结果不确定时记录 `unknown` 并让人核对，不能盲目宣称至多一次或无限重发。
- 同一 Task/Channel 回复按序；单个目标的 unknown 不应堵塞其他 Task。
- 取消 Source 发送、通知待处理或本地投递失败是不同事实。外部消息已送达不代表 Task 已完成，Task 已验收也不代表 source reply 已成功。

## 12. Source 与聊天室边界

### 12.1 从已有入口开始

第一阶段使用现有已认证的主会话/Web 入口作为原对话；复用 Colony Interaction/Work 的后台命令语义，不让用户先进入旧蜂群。普通问答保持原行为，只在明确的长期工作/协作需要时绑定持久工作；新外部 Source 延后。

未来长驻 GitHub/Webhook/CI/Feishu 接收器可由现有 `stateful_service` 插件承载；纯映射逻辑无需注册成有状态插件。先定义最小 Source Port 的语义：验证实例与身份、将原生事件规范化、读取可恢复 cursor、有限读取线程上下文、发送并分类 sent/retryable/permanent/unknown。具体函数签名等首个真实 Source 确定后再冻结，不先设计空泛的全平台抽象。

轮询 cursor 只在该页事件/过滤记录都持久受理后推进；坏数据保留原 ID、错误和重放入口；重启只能有一个有效 poller；Source 的调用身份由 Host 注入。Webhook 收到成功响应必须意味着目标 receipt 已持久化。

### 12.2 Project Chat 以后显式桥接

`Collaboration.Chat.Room` 当前使用 CrossHost Store，Room topic 的 `task_id` 指向其协作任务；`Colony.Task` 在另一个 Store。Project Chat 的 `@代表` 是有限预算的讨论邀请，`decision.apply` 也是有基线与权限校验的建议应用，不代表收到一条 @ 就授权 工作执行者 执行工作。

所以 Project Chat 不是 P0 的隐式 Source。未来需提供人类明确的“将此讨论/消息交给蜂群工作”动作，并绑定 project/colony、已认证设备/成员和目标 Task。跨 Store 用 source outbox + Colony receipt + 幂等补发；Room 保存窗口当前仅保留最近 600 条，不能只轮询 snapshot 并声称没有事件丢失。

决议注入工作仍沿用现有版本、权限、Git 基线和“不直接执行命令”校验；聊天消息和 Agent 生成的提及始终是不可信资料。

## 13. 自动化策略：先观察，再证明

显式的人类工作命令与主动观察不是一类行为：

| 模式 | 允许动作 | 默认 |
| --- | --- | --- |
| Explicit | 认证用户在现有权限内创建/补充/控制 Task；走当前蜂群 Workflow | 已有本地入口行为 |
| Observe | Source 记录事件，并保存策略本会如何路由；不创建自动执行 Task、不发 unsolicited 工作回复 | 新 Source/新规则默认 |
| Auto | 仅对明确启用的 Source scope/actor/rule 自动受理，计入调用/时间/费用预算 | 观察结果和回归覆盖经人启用后 |

给外部 Source 的配置先保持少而明确：连接哪个项目/频道、哪些人/机器能发起、是否只接 @、是否 observe/auto。不要第一版就做含大量单元格的 Policy 编辑器。

每次模型调用要把“语义评估”与“蜂群协作 triage”分开计量。`Interaction.say` 的新工作目前可能通过 Workflow triage 决定独做或协作；这是 newbee 的协作决策。新建 Source Admission 后不可又为相同问题调用第二个 evaluator。是否给简单 Task 增加直接自做路径，应在保留当前行为的对照实验后决定。

## 14. 分阶段实现

| 阶段 | 范围 | 验收重点 |
| --- | --- | --- |
| UX0：使用方式验证 | 操作规范 + 离线交互原型；走查发起、后台、补充、问答、结果采用和失败恢复 | 不先解释 Bee/Task；不建群、不选人、不填分工；验证用户是否知道当前工作、文件位置与下一动作 |
| P0：主会话最小可用版 | 现有主会话绑定一个明确工作；复用 Work/Runtime，补 receipt/输入/问题；修改 choosing 让内部协作自主推进，业务决定原地问人 | 原对话内从请求到结果；普通问答不工单化；不跳执行会话，不重复问“继续” |
| P1：可靠后台和成果采用 | 独立后台启动、单执行者、owned/context-only 跟进、旧工作关联、断线/重启恢复、Colony 成果版本校验应用 | 目录语义清楚；不双写，不覆盖用户变化；“应用并完成”按回执恢复，不能先记完成再失败 |
| P2：试点日常使用与迁移 | 一个 opt-in 项目；原会话/快捷键保留，旧蜂群仅历史/高级入口；按真实失败修正 | 实际愿意持续使用、少误路由/追问；不是只看自动化用例通过 |
| P3：一个外部 Source | 从受控本地 Source 到一个有需求的平台；先 observe，再明确请求执行 | 外部原线程可以完成同样的补充/问答/交付，不要求回工作台 |
| P4：少量主动规则 | 验证来源范围、规则、预算和暂停，逐步从 observe 转 auto | 以质量和人工注意力的对照数据证明收益，再扩大范围 |

实施复用后端实体，改变日常操作负担。现有 CrossHost group.workspace.apply 不能冒充 Colony 已有应用能力；“应用并完成”需要专门的目标/hash 校验、应用回执和 finalize。暂不支持运行中迁移时，不显示无条件后台按钮；先支持明确请求从隔离后台开始。


## 15. 验证：证明价值而不是证明“跑过”

功能正确性测试至少包含：

- 收件/命令相同 ID 相同内容幂等，不同内容冲突；不同 project/colony/source 不碰撞；乱序编辑不会让旧内容覆盖新版本。
- 请求身份和权限从认证边界获得；伪造 actor/human/@、跨 colony、撤销权限、禁用规则均不能创建执行任务。
- owned-thread follow-up 先交原负责人；context-only 不授权也不恢复；越权输入只 handback 一次；未消费输入在 Assignment 结束后仍可被路由。
- Task 创建/continue、来源 receipt、Delivery 与回复意图的提交和重启故障注入；EventStore 旁路失败不能改变 Colony 的权威状态。
- ask/reply/skip/timeout 绑定 question_id 与当前执行代次；skip/timeout 不算批准；替换问题不重复发送旧问题。
- 旧 generation 的 done/ask/Honey 不应用；停止未确认时不能双写 Workspace。
- 原渠道发送成功、短暂失败、永久失败、成功但回执丢失、远端无幂等且无查询能力分别有可见且正确状态。
- stage 投影覆盖当前 Task status、Control、Workflow、Delivery、Honey 所有合法组合；不能出现一份任务同时显示 working 和已结束。

验证自动化收益时，用同类任务、相同权限和费用预算做对照，至少记录：

- 从首次请求到可用结果的时间；
- 人为追问、重复解释、重新选择负责人和手动恢复次数/分钟；
- ready 结果比例、验收通过率、返工和遗漏输入数；
- unsolicited 通知、需要人工决定次数及其正确性；
- Task 重复、source 重放、旧报告覆盖和权限越界次数；
- 模型调用、token、实际费用、Source 延迟和维护成本。

先建立 newbee 现有单 Bee/Workflow 入口的基线，再逐项比较 Source 续办、handoff 和 observe/auto。测试替身只能证明协议和故障恢复，不证明模型准确率；目前没有数据时只记录假设和测量计划。

## 16. 迁移、风险与非目标

- 新 Source 默认关闭或 observe，仅 opt-in 一个试点 colony/project；历史 Task 不伪造 origin 或 Mandate，不批量自动启动。
- 暂停自动接单不删除输入、Task、Question、receipt、Honey 或待发送效果；人可以继续人工工作并看到未完成的系统责任。
- Schema 变化要求备份、可重放迁移和旧版拒写策略；未知 schema 不允许静默丢掉授权或 outbox 字段后继续保存。
- 首版工作量与全量 Colony Store 快照大小、串行写入延迟和 Source 重投窗口一起测；超出容量后再决定存储升级。
- 不在本轮承诺 EventStore 与 ColonyStore 已统一、跨平台远端 exactly-once、无人值守的不可信代码安全、自动合并或 Agent 数量增加能提高质量。
- `DESIGN.md` §4.6 把 EventStore 定义为系统级同步事实权威；本方案为首版 Colony 域明确选择 Colony.Store 单写入，须在任何代码实施前登记这个域边界及未来退出方案。若产品不接受该例外，实施前先做全量事件溯源迁移，不可偷偷双写。

## 17. 决策摘要

融合结论是：

```text
dsh 提供“持续负责已授权工作、跟进交回原 owner、人少被打扰”的托付纪律
newbee 提供 Task/Bee/Workflow/Workspace/Session/Honey/验收与插件治理
合并方式：把来源事件和后续跟进接入现有 Task 责任链，不再造第二套工作系统
```

第一阶段先证明用户能在原会话里自然发起、补充、回答和采用成果，再实现使这些操作可靠的 Task/Input/Delivery。使用流程走不通时先改流程，不以继续扩充后台协议替代。
