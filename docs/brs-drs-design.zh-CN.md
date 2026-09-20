# newbee 的 BRS/DRS 后台学习设计

状态：评审修订提案 v2，尚未实现。中文为维护主稿；[英文版](brs-drs-design.md)同步核心契约。

## 1. 给研发经理的说明

BRS 是“先摸底”：针对一个新工具环境，安排几种不同的小练习，找出容易出错的地方。
DRS 是“攻难点”：针对一个真实失败，先验证原因，再练习解决办法，最后换一道没有练过的题验收。
学习产物是带适用条件的操作经验；模型权重不变。

例如 newbee 反复生成错误的 Elixir 代码：先截取可复现的小例子，验证错误原因，形成一条局部教训，再用其他例子检查这条教训是否真的能减少错误。不能把“多试一次终于成功”算成学会了。

**首期交付是一个可审计的离线 DRS 实验闭环。** 它输出练习证据、候选经验以及与旧版本的对照报告。先证明有收益，再接入后台自动调度和发布。首期不做 BRS 并行、不生成可执行工具、不改变生产 active 环境。

## 2. 本次评审结论及改动

| 初稿问题 | 后果 | v2 决策 |
| --- | --- | --- |
| 冻结评估放在第三阶段 | 前两阶段无法判断是真学习还是多花钱重试 | 第一条 DRS 就包含冻结对照 |
| 把 Explorer 和五层 Verifier 当成已具备全部能力 | 会把自报完成和投影兼容当作成功 | 明确适配缺口，并设置实现前置门 |
| 执行状态、任务对错和记忆准入混为一体 | 失败教训没有合法路径，重启难恢复 | 分成三个独立字段 |
| 基线不可变却又逐轮更新记忆 | 无法确定某次尝试读了哪个版本 | 固定起始基线，单独推进学习记忆指针 |
| 未说明是哪一个 Coordinator | 容易重复实现任务系统或阻塞主循环 | 环境 Coordinator 管学习事实，Hive 管任务执行 |
| 隔离靠 worktree/独立模型上下文描述 | 无法阻止读取宿主文件、测试或共享记忆 | 离线实验必须先具备实际读写边界 |
| 只写幂等键和原子提交，没有恢复规则 | 崩溃后可能重复调用、扣费、准入 | 增加准备、持久提交、恢复对账协议 |

本次仅修改设计。下述“必须”“新增”均为实现要求，不代表当前代码已满足。

## 3. 现有能力与真实缺口

评审基线：专用 worktree 的 Git HEAD `211d5126fd6fc3182b16acfd274fa181694c3145`。主工作区其他未提交改动不在本评审内。

| 源码位置 | 已有能力 | 不能直接承诺的能力 |
| --- | --- | --- |
| [Adapter](../lib/newbee/agent/adapter.ex) `run_once/synthesize` | 从 need 和热点生成候选提案 | 尚无本文的练习线、验收与记忆递进协议 |
| [Explorer](../lib/newbee/agent/explorer.ex) `run/run_in_worktree` | 独立 Loop/evaluator 和 worktree | `_opts` 未用于预算；会将返回结果标为 done，并将模型 done 映射为 accepted；返回前删除 worktree；不能直接承担证据封存和持久恢复 |
| [任务验收](../lib/newbee/collaboration/verification.ex) | 命令、文件存在、SHA-256；带验收摘要的报告 | 不是防恶意代码沙箱，也没有通用视觉/语义检查与回滚镜像 |
| [Submission](../lib/newbee/collaboration/submission.ex) | 与任务绑定的源码快照和哈希验证 | 源码快照不包含进程、数据库、远程服务等完整环境状态 |
| [Release Verifier](../lib/newbee/environment/verifier.ex) | 静态、自测、抗体及投影比较等入口 | `counterfactual_layer` 当前走投影比较，报告 `proves: projection_compatibility`；不能作为任务能力提升证明。自测执行隔离也需核验，不能只凭模块名称承诺 |
| [Memory](../lib/newbee/memory.ex) | 全局 topic 文本、脱敏和 TTL | 没有本文所需的学习版本、准入或评估冻结语义 |
| [环境 Coordinator](../lib/newbee/environment/coordinator.ex) | Change、Revision、评价和激活状态管理 | 尚无学习线命令和事件归约器 |
| [协作 Coordinator](../lib/newbee/collaboration/coordinator.ex) | Hive 任务、提交、验收和投递 | 不应再兼任另一套 Memory/Release 发布权威 |

独立 evaluator 是崩溃隔离的一部分，worktree 是文件修改隔离的一部分；二者都不等于操作系统级读写限制。本文不再把它们称作完整安全边界。

## 4. 范围与职责

首期环境选定为：**离线 Elixir 工具使用与错误恢复的小型 fixture**。每个 fixture 有固定输入、依赖、初始文件和确定性验收。不访问外部业务服务，不使用真实凭据，不学习 Provider 在线故障。

Curriculum 是 Adapter 内的规划职责，不新增一个常驻模型身份。它决定“下一道练习题是什么”，不能决定“答对了没有”。

- Worker 只提供引用原始证据的信号，继续用户工作；信号不是后台执行授权。
- Adapter 提出练习和候选教训；首期教训是有范围的文本数据，不允许生成执行代码、沉睡规则或改变验收器。
- `Newbee.Environment.Coordinator` 是学习线、预算预留、经验准入和记忆指针的唯一事实写入者。新增纯状态归约模块承载契约，长工作通过监督任务执行，不能在其 GenServer 回调内跑模型或命令。
- `Newbee.Collaboration.Coordinator` 继续通过 Hive 管任务派发、attempt、提交与验收。学习线只引用 task/submission/attestation ID，不复制 Board、投递队列或群系统。
- 首期使用 Hive 的隔离任务执行路径；旧 `Agent.Explorer.run/2` 不直接进入学习链。可复用其 Loop/evaluator 组件，但必须先完成预算、产物保留和隔离适配。
- 确定性验收由受信执行器完成。后续语义 Verifier 只拿任务和候选产物，不拿 Actor 私有对话；独立模型上下文本身不能代替文件访问控制。
- Host 控制工作根、凭据、资源和副作用。发布继续经过现有 Change/Verifier/Autonomy 门。

## 5. 版本模型：哪些固定，哪些变化

| 对象 | 含义 | 更新规则 |
| --- | --- | --- |
| `baseline_id` | 项目源码、依赖、工具版本、配置和起始记忆 M0 的完整清单 | 创建后不变；源码/模型/策略改变则新建学习线 |
| `learning_head` | 当前可供下一轮练习读取的记忆版本 Mn | 仅准入事件可从 Mn 推进到 Mn+1 |
| `input_memory_id` | 本次 attempt 实际读取的记忆 | 派发时固定，不能中途跟随 active 更新 |
| `wave_input_memory_id` | 一批 BRS 分支的共同输入 | 本批内不变，下批可用上一批提交的版本 |
| `evaluation_snapshot_id` | 某次评估冻结的输入清单 | 创建后不变；配置变化使本次比较失效 |

DRS 每次重置任务文件和交互上下文，只继承已准入的记忆。生产环境可继续变化，但实验执行必须固定到自己的 baseline；晋升遇到 active 基线过期时重新评价，不能强行覆盖。

学习记忆保存为既有项目 Store 内的不可变实验制品，属于 Evaluation Evidence 的投影，**不写全局 `Memory.write`**。每个版本包含父版本、按顺序的经验 ID、条目内容哈希和来源。只有发布候选走 Change 后才可能成为生产知识。

## 6. DRS 流程

1. **登记**：接收人工选择的失败证据，校验范围、初始 fixture、验收器和预算。缺少这些条件则停在 blocked，不自动展开练习。
2. **复现**：在起始记忆 M0 下重放开发任务，记录真实结果；无法复现时记录 `not_reproduced`，不直接学习或声明修复。
3. **计划**：Adapter 提出一个可证伪的假设、一项练习和所需证据。宿主冻结练习验收条件后再启动 Actor。
4. **练习**：干净分支读取当前 Mn。Actor 输出候选产物；调用 done 只表示准备提交。
5. **验收**：封存产物，在新的检查工作区执行可信验收。业务条件不满足记 fail；检查器崩溃或运行环境失效记 infra_error；结果无法判定记 unknown。
6. **提炼**：Actor 可提供带证据引用的候选教训；Adapter 负责合并，不读取整份私有推理。验收通过只证明该实例，不证明教训适合所有情况。
7. **准入**：正面或负面教训都要有具体适用条件、支持证据和至少一个对比/边界用例。没有这些证据的条目保留为候选，不改变 learning_head。
8. **再试目标**：记忆推进后，用干净环境重试原开发任务。原任务成功只是开发证据；要声明开发目标完成，还必须由验收器确认。
9. **停止与评估**：达到预算、无新假设或开发目标验收后结束练习，冻结 Mn，进入预先锁定的保留任务评估。

Curriculum 的 `ready` 仅表示“建议结束学习并去验收”；最终 `target_pass` 由验收器产生。即使目标 PASS，仍可在预算内用一项针对薄弱条件的练习验证稳定性；若更新记忆，必须重新验收目标。

## 7. BRS 批次协议（后续阶段）

BRS 沿用 DRS 的任务、验收和准入契约，仅改变练习编排：

1. Adapter 先冻结一批不同方向的题目及顺序、验收契约和预算；不能看某分支成绩后再改本批组成。
2. 全部分支从同一个 wave_input_memory_id 和源码基线执行，各自看不到其他分支未准入经验。
3. 每个分支独立提交、验收；fail 是合法的语义结果，不等于批次基础设施失败。
4. 全部分支到达可信终态后进入屏障。unknown、infra_error、缺失产物会阻止本批提交；按固定重试限额处理后仍未解决则 abort/quarantine 整批。
5. 按预定顺序合并可准入教训，逐条验证矛盾与适用范围。冲突项保持 unresolved、不进入可执行建议；宿主不负责用多数票判断语义真伪。
6. 一次提交完整 Mn+1。没有有效变化时记 no_change，不制造新学习成果。中止批次保留全部证据，不发布其中的部分记忆。

全批屏障可能被一个坏分支拖住，这是有意接受的首版取舍。未来若支持部分提交，必须事先定义独立学习单元和统计口径，不能事后丢弃差结果。

## 8. 状态与数据契约

执行状态、语义裁决、经验准入必须分开：

| 字段 | 值 | 决策者 |
| --- | --- | --- |
| `execution_status` | queued / running / submitted / terminal | 任务执行器和宿主 |
| `execution_reason` | completed / infra_error / cancelled / budget_exhausted | 宿主运行记录 |
| `verdict` | pending / pass / fail / unknown | 验收器；infra_error 时保持 unknown |
| `admission` | not_proposed / candidate / admitted / rejected / quarantined | 环境 Coordinator 根据准入凭证 |

合法路径示例：`terminal + completed + fail + admitted` 表示任务失败但负面教训被验证；`terminal + infra_error + unknown + quarantined` 不能推进记忆。

生命周期：`created -> planned -> practicing -> learning_stopped -> evaluating -> closed`。运行阻塞可进入 blocked，完整凭证恢复后继续；取消可进入 cancelled。学习停止原因单独记录 `target_pass / saturated / budget_exhausted / stalled / infra_error`。closed 只是流程结束，评估结论另存 `improved / regressed / no_clear_gain / invalid`。

必需数据（schema_version=1，以下为设计字段，不是新增公开 API）：

| 记录 | 必需字段 |
| --- | --- |
| Baseline | id、project_id、source_tree_hash、dependencies_hash、release_map、M0、model_config_hash、policy_hash、fixture_version |
| Lineage | id、baseline_id、trigger_event_ids、phase、learning_head、state、stop_reason、budget_reserved/spent、event_revision |
| Attempt | id、lineage_id、wave_id、parent_attempt_id、Hive task_id/attempt、input_memory_id、contract_hash、submission_id/hash、三个状态字段、cost、dispatch_id |
| Experience | id、attempt_id、claim、scope、preconditions、counterexamples、uncertainties、source_event_ids、artifact_hashes、verifier_receipt、admission |
| Memory manifest | id、parent_id、ordered_experience_ids、entry_hashes、manifest_hash、schema_version |
| Evaluation | id、baseline/candidate snapshot、locked_cohort_hash、judge_version、model/provider_config、budget、trials、all_outcomes、cost、conclusion |

模型只能填写被允许的提案字段；不能提交 admission、宿主哈希、可信事件 ID 或验收结果冒充宿主事实。存储读取同样做 schema 和引用校验。

## 9. 隔离、验收与可信证据

首期每个 fixture 工作区都必须位于会话专用实验目录。实际执行边界要求：

- 独立 OS 进程/容器或等效已验证的沙箱限制可读写根；去除宿主凭据，默认禁外网；模型 API 仅由受控宿主代理调用。
- 禁止实验代码读取生产 `.newbee`、其他会话、全局记忆、宿主保留测试和评估报告。只读挂载 input_memory；实验写入不能到 active 或持久共享库。
- evaluator 若通过 Host bridge 调用工具，Host 也必须校验 experiment_id、允许根和操作类别，不能借代理越过沙箱。此能力未验证前不运行自动学习。
- 验收器使用固定版本和单独工作区；测试输出允许写临时位置，不能更改被验收的候选内容。检查前后校验候选哈希，变动则整次验收无效。
- Actor 不能修改验收代码。练习可以看到公开要求；保留评估的隐藏 oracle 不可见。验收报告必须绑定 candidate hash、contract hash、checker version 和 attempt。
- 文件存在/哈希可以证明产物身份；能力正确性应由对应 fixture 的行为断言证明。空契约、自测通过、模型 done、投影兼容都不足以证明学习有效。

首期不依赖通用语义 Verifier 或完整 VM 回滚。以后支持 GUI/远端系统时需另立环境快照、账号和补偿策略；环境版本回退不会撤销已经发送的远端操作。

基础设施失败不能形成“业务正确性教训”，但必须保留并送到独立维护通道。若要学习基础设施恢复方法，需新建明确以恢复行为为目标、带可控故障注入和验收的学习线。

## 10. 原子准入与崩溃恢复

使用现有 EventStore 作为事实来源，项目 Store 保存内容寻址制品。新增事件必须注册为 durable，并在确认后才允许推进。不能假定现有消息 API 天然提供所有去重保证。

提交顺序：

1. 写入临时制品，校验引用/哈希，完成持久化，再原子重命名为不可变对象。
2. 环境 Coordinator 检查 expected_learning_head、expected_event_revision、尝试号、验收凭证和准入条件。
3. 追加持久的 `memory_committed` 事件，包含 command_id、旧/新记忆和有序经验 ID。确认落盘后更新投影，事件是唯一提交点。
4. 崩溃发生在事件前：只留下未引用制品，不改变记忆。发生在事件后：重放恢复同一指针，不再调用模型重新合并。

幂等规则：同一 command_id、同一载荷返回原结果；同 ID 不同载荷拒绝；过期 head 或 attempt 拒绝。合并中的模型回复也封存为制品，恢复优先重用已完成步骤，不重抽一次答案。

Hive 与环境 Coordinator 之间不宣称跨进程事务：使用带稳定引用的事件/消息、消费水位和恢复对账连接。任务结果重复到达不会重复准入；已提交但未回执可查询原提交。

外部模型调用发生后宿主崩溃，可能不知道是否已计费。记录 ambiguous_call，保守占用预留预算并对账；除非 Provider 支持幂等，否则不承诺 exactly-once 调用或扣费。缺少可验证结果时新建带原因的 retry attempt。

制品缺失、哈希错误、检查器版本不匹配时 quarantine；不能根据摘要猜测成功。先完成可信封存，再清理 workspace。GC 只能删除未引用且超过保留期的对象，不能清除活跃学习线和待审证据。

## 11. 从第一版开始的冻结对照

冻结评估是 DRS MVP 的组成部分，不是最后的加固项。

在学习前锁定三个集合：开发目标、可生成练习的范围、保留评估题。题目选择不依据本次评估得分；候选作者看不到保留答案。若只有原目标重试，没有保留题，报告只能称为“目标修复”，不能称为可迁移学习。

对照组使用 M0，候选组使用 Mn。两组固定源码、依赖、工具、模型/Provider 配置、Judge、题目、每题调用/Token 上限和初始环境，只改变记忆。每个 trial 重置交互和工作区，顺序交错以降低服务时变影响。支持随机种子则记录；不支持不能承诺确定性复现。

首期建议锁定 10 个保留 fixture、每题每组 3 次尝试作为可行性样本，**这些数值是试点配置，不是统计充分性的证明**。使用前必须写入预算清单；不足则缩小预定研究范围或停止，不能事后挑最好结果。

报告全部预定试次：pass、fail、unknown、infra_error、取消和缺失均显示。分别报告有效语义得分和运行覆盖率，不把基础设施失败自动当业务零分，也不悄悄排除后展示完整覆盖。重试政策对两组相同且保留全部尝试，不能选最高分。

能力提升、调用成本和学习成本分别报告：每题配对结果、回归题目、区间/样本限制、练习及验收全部 Token/耗时、后续预计复用次数。小样本无明确收益记 no_clear_gain；不能仅凭均值上升自动发布。

冻结运行显式 `learning_enabled=false`。事件投影、Adapter 信号收集、Memory 写入与自动抗体路径都必须识别该标志；保留日志不代表允许消费为训练信号。评估结束后若用结果改进新候选，原题组降为开发集，下一次最终判断另用保留集。

## 12. 预算与停止

MVP 由人启动一条学习线，串行执行，最多 3 个新练习，每个练习最多 1 次基础设施重试，无递归子派生。BRS 后续默认每批 3 分支、并发 2；所有默认值需可配置、落盘并明确未经成本校准。

启动前必须声明总调用、Token、墙钟、磁盘以及评估预留预算，不能使用无限默认值。成本包含规划、Actor、验收、提炼、合并、重试和对照；调度前预留，完成后核销。提供方无可靠用量时标为 estimated/unknown，不伪装精确。

预算不足以完成评估时不再开始练习。可取消正在运行的尝试，保留证据且不提交半个 wave；“只在 wave 边界判断”的策略不能绕过宿主硬超时或费用上限。

后续才接入 Daemon/need/TCE：信号先去重，按预期复用价值排序；重复错误不能无限触发新实验。前台优先，后台受并发上限、暂停和总预算限制。TCE 当前收益估计不能替代实测对照结果。

## 13. 交付拆分与验收

| 阶段 | 交付物 | 退出条件 |
| --- | --- | --- |
| A：基础契约与执行边界 | schema、纯状态归约器、fixture、沙箱/Host 限制、预算、封存/恢复 | 模拟模型和故障注入测试通过；无付费学习 |
| B：离线 DRS MVP | 复现 -> 练习 -> 验收 -> 经验 -> 冻结对照报告 | 完成一条真实模型试点并报告全部结果，保持 no activation |
| C：后台调度与受控发布 | 人工审核候选、Change 映射、过期基线重新评价、去重调度 | 证明任务收益且无必需回归失败；遵守既有 Autonomy，不自动提高档位 |
| D：BRS | 共同输入、并行、批次屏障与顺序合并 | 相同预算下比较 DRS-only、BRS-only、组合；不足以判优则不默认启用 |

应在各阶段实现并验证以下场景，而非要求“实现之前已有全部测试”：

1. Actor done 但断言失败：verdict=fail，不能进入正面准入。
2. 失败实例支持负面教训：经过边界用例后可准入，业务结果仍然是 fail。
3. 第一次验收结果 unknown：不推进 head；预算耗尽不变成 pass。
4. 沙箱尝试读取生产记忆、宿主凭据、兄弟分支和隐藏 oracle：访问被宿主/OS 拒绝。
5. 候选试图修改验收器或被验收源码：拒绝或哈希校验失效。
6. 制品写完、事件未写时崩溃：head 不变；事件已落盘时崩溃：恢复一次提交。
7. 重复 command、重复投递、旧 attempt 迟到：无重复记忆推进；不同载荷同键拒绝。
8. DRS Mn+1 只影响后续尝试；当前运行和 BRS 兄弟分支的输入不变。
9. BRS 一支 infra_error：整批不提交；可信 fail 可参与负面经验，冲突项不发布。
10. 冻结评估产生错误事件：日志存在，但 Adapter、自动抗体和记忆不更新。
11. 前台 active 改变：实验固定输入；发布遇 stale base 重新评价。
12. 所有角色和重试费用计入总预算；Provider 不确定计费不会被当成免费重试。
13. 固定模型输出回放只用于机制回归；真实能力收益必须来自真实执行对照。
14. 报告保留缺失、失败、重试与成本；不得用历史基线填未跑的候选结果。

自动激活、全局记忆发布、通用 GUI 验收和任意第三方项目均不属于 B 阶段。

## 14. 来源、限制与后续决策

参考 [RSIAgent 架构](https://github.com/AetherLabsAI/RSIAgent/blob/main/docs/ARCHITECTURE.md)、[结果口径说明](https://github.com/AetherLabsAI/RSIAgent/blob/main/docs/PAPER.md)及[论文](https://arxiv.org/abs/2609.15364)。其结果包含基线保留、选定重试与不同预算，不能作为 newbee 性能提升的保证。

本方案采用其“广度覆盖、深度练习、冻结记忆”思想，工程顺序和职责按 newbee 改造。独立确定性验收优先，保留当前版本系统，不复制其 VM 栈。

已定案：首期离线 Elixir fixture、文本经验、环境 Coordinator 单写、Hive 执行、从第一版冻结对照、人工启动且不激活。

实现时仍需完成的技术选择：选定并验证支持 Host bridge 的 OS 隔离后端；选定首批开发/保留 fixture；实测资源后填写 Token/磁盘/时间预算；确定报告统计实现。这些是阶段 A 的交付事项，不用“已有模块”替代验证。

是否扩大投入，取决于阶段 B 能否证明：**在相同执行预算下，新题更少出错，学习成本有机会在后续复用中收回。** 不满足则保留证据、缩小问题范围或停止，不靠增加 Agent 数量掩盖无收益。