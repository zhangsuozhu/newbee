# Newbee 多任务协作 v2 审计与修正版设计

> 审计日期：2026-09-03
> 对比源码：OpenAI Codex `94311d447587411789533c47601fd8bc9d81eb48`；DeepSeek Harness `b150a551b8d465e31e418e1b2eaf5e79bbb7d28e`。
> 本文区分四类陈述：**源码事实**、**外部实证**、**设计推论**、**待验证假说**。设计推论不伪装成论文结论。

## 结论先行

上一版抓对了三个方向：统一状态、事件驱动等待、递归限额；也正确注意到 Newbee 已有的 OTP、EventStore、capability 和隔离工作区优势。但它的论证和实现都有严重问题：

1. 将特定基准结果外推为普遍规律。例如 MacNet 的“不规则拓扑优于规则拓扑”不能推出代码协作应采用扁平任意通信。
2. 将论文作者的主张写成既定事实。例如 SEMAP 的 47%–70% 是初步实验中的**失败计数降幅**，不是普适成功率增益；论文自己要求扩大数据、增加 baseline、做消融和测成本。
3. 将设计意图写成已实现事实。原 Hive 的 persona、fork_turns、wake、interrupt、认证主路径均没有真正贯通。
4. 新建 `Newbee.Collab.Group`，与已有 `Newbee.Collaboration.Coordinator` 双写。两个持久状态机不能同时成为“共享事实”。
5. 声称“验收机检”，实现却只保存任意字符串；worker 可把任务直接写成 `succeeded`。

本轮修正不再扩张第二套系统，而是删除 `Collab.Group`，把 v2 不变量放进已有的唯一事实源 `Collaboration.Coordinator`。

---

## 1. 第一性原理：这个功能为什么存在

多代理不是目标。目标是在约束下更快、更可靠地完成任务。

设：

- `W`：可并行的有效工作量；
- `S`：必须顺序执行的工作比例；
- `C(n)`：n 个代理的协调、上下文复制、验证和冲突成本；
- `P_fail(n)`：架构下的最终失败概率；
- `V`：任务成功的业务价值；
- `K(n)`：token、工具调用、机器时间等直接成本。

是否启用多代理，至少应满足：

```text
期望净收益(n)
= V × [P_success(n) - P_success(1)]
  + 时间价值 × [T(1) - T(n)]
  - [K(n) - K(1)]
  - C(n)
> 0
```

这不是形式主义。Amdahl 1967 说明串行部分限制并行加速上限；Anthropic 2025-06-13 的 Research 多代理生产报告显示该研究系统约消耗聊天的 15 倍 token（单代理约 4×），并明确指出多数编码任务可并行子任务少、LLM 实时协调与委派能力尚弱，不适合当前多代理。Towards a Science of Scaling Agent Systems（260 配置 × 6 基准 × 5 架构 × 3 模型家族）在固定计算量下报告架构与任务是否对齐决定成败：相对单代理从结构化金融推理的 +80.8% 到顺序规划的 -70.0%，tool-heavy 任务存在显著协调惩罚（β=-0.096, p=0.002），跨域模型 R²=0.373（另-capability 口径 0.413）。

因此 Hive 的意义不是“能派更多代理”，而是提供三个最小保障：

1. **并发不丢更新**：一个线性化单写者 + revision CAS；
2. **依赖不乱序**：显式 DAG；
3. **完成不可自证**：执行者提交，Lead 依据结构化验收独立判定。

### 何时应使用

使用：子任务边界清晰、写集可分、可并行探索、单上下文容纳不下、失败代价高到值得额外验证。

不要使用：一步修改、强顺序约束、多个代理必须共享全部上下文、工具调用密集且难分割、单代理已经高可靠、任务价值不足以覆盖多倍调用开销（Anthropic 的该研究系统观测约为聊天的 15 倍 token）。

这些是基于现有证据的保守准则，不是自动最优策略。自动选择架构仍需 Newbee 自身 A/B 数据。

---

## 2. 上一版哪些分析是好的

### 2.1 协作应围绕共享状态、通信和责任

**评价：保留，但从“四个终极本体”降格为工程分解。**

roster、共享状态、通信、责任确实覆盖了本项目的大部分故障面。MAST（1,600+ 条、7 框架）提出 14 种失败模式并聚为 3 类：系统设计、agent 间失调、任务验证。论文未发表这 3 类的跨系统聚合占比（图 4 只画各系统前 30 条、共 210 条的系统内分布，且明确不做跨系统性能比较），因此本轮不引用 41.8%/36.9%/21.3% 这类无出处聚合数；保留三者同治的工程结论，依据是分类覆盖面而非虚构占比。

边界：MAST 的 1,642 条并非全部人工标注；表 1 中大量扩展数据由 LLM judge 标注，人工流程用于 210 条跨框架 trace，并报告 LLM judge 与人工标签 Cohen κ=0.77。上一版只写“1600+，κ=0.88”混淆了 taxonomy 标注者一致性和 judge 一致性。

### 2.2 revision CAS 是正确方向

**评价：保留，并升级为所有 v2 Board 写入的硬前置。**

Harness Teams 的 `expectedRevision` 是直接工程先例。更基础的依据是 Herlihy/Wing 1990 的 linearizability：并发对象的每个操作应能解释为在调用和返回之间某一点原子发生。Newbee 的 Coordinator GenServer 天然是单写者；revision CAS 防止模型基于旧视图覆盖新事实。

上一版问题：仅新 `Collab.Group` 有 CAS，真实 UI/旧工具仍写另一个 Coordinator；这不构成共享事实。

修正：删除第二个 Group，revision 由现有 Coordinator 的 `put_group/2` 单调推进；create/update/claim/verify 均检查 `expected_revision`，两个并发写者同 revision 最多一个成功。

### 2.3 `wait` 应事件驱动

**评价：保留，但要用无丢唤醒的原子 check-and-register。**

Codex v2 与 Harness Teams 均提供等待状态/信箱边沿的工具。这是源码先例，不是论文证明“token 一定更省”。本项目能够证明的是：等待调用不会让模型反复生成 `tasks()` 调用。

修正：同一个 Coordinator 在一个 `handle_call` 内先比较 revision，再注册 waiter；任一持久事件经 `put_group` 唤醒；caller 死亡自动移除；超时、组删除都显式返回。一次本机测量为：已有边沿返回约 75μs，1 秒 timeout 为约 1.001 秒；这些只是环境观测，不作为跨机器性能承诺。

### 2.4 write scope 只诊断，不冒充锁

**评价：保留。**

Harness 源码明确拒绝把 path prefix 当锁，因为 shell、formatter、generator、外部程序可绕过工具级 CAS。Newbee 仍采用这个边界：scope 重叠返回 warning，不授权、不阻塞。真正隔离由现有 filesystem workspace + review/apply 流水线承担。

### 2.5 深度和累计总量双限额

**评价：保留。**

Codex `AgentRegistry` 同时维护总 spawn 数和 thread depth；Harness 也给 in-process provider 设 depth limit。它们证明这是成熟系统的共同防失控机制。数学上，无限递归会让最大节点数随 branching factor 指数增长；硬上限是资源安全不变量，不依赖模型自律。

修正：限额移入唯一 Coordinator，delegate 在创建 workspace/session **之前** preflight（限额/成员资格经 `Coordinator.can_delegate`，v2 acceptance 经无状态 `Verification.normalize_contract` 预检，非法合约不物化 workspace/session）；深度来自持久 roster 的 parent lineage，累计总数不会因 close 被“洗掉”。

---

## 3. 上一版哪些分析有问题

### 3.1 “MacNet 说明扁平 roster + 任意消息拓扑优于严格层级”

**结论：不成立，删除。**

MacNet (ICLR 2025) 测 MMLU、HumanEval、SRDD、CommonGen-Hard；默认约 4 节点、GPT-3.5、相邻 agent 至多 3 轮交换。其 token complexity 分析（C 与 C̄ 公式）指出无 memory control 时上下文随规模按 n² 增长；论文报告从 2⁰→2⁴（1→16 节点） scaling 时制品 token 长度增 7.51 倍。表 1 显示 chain 在 HumanEval 为 0.3720，低于 CoT 的 0.6098 和 AgentVerse 的 0.7256。

能够推出的只是：拓扑与任务存在交互，不能默认一个拓扑。不能推出 Newbee 应开放无约束 peer mesh。本轮仍保留 Lead 中心化的生命周期权限，仅允许组内定向消息。

### 3.2 “SEMAP 降失败 47%–70%，所以行为契约/CAS/DAG有效”

**结论：数字是真的，归因过强。**

SEMAP arXiv:2510.12120 报告：HumanEval 开发中总失败数最高降 69.6%，ProgramDev 最高降 56.7%，vudenc100 最高降 47.4%，devign100 最高降 28.2%。但：

- 是 failure counts，不是 success rate；
- vulnerability 两个数据集各 100 样本；
- baseline 主要是 MetaGPT；
- 没有组件消融，不能分辨 contract、message、lifecycle 各自贡献；
- 未测资源开销，论文把扩大数据、增加 single-agent/domain baseline、消融和成本测量列为 future work。

正确使用方式：它支持“结构化契约 + 生命周期验证值得试验”，不证明我们的具体 CAS、DAG 或 API 已最优。

### 3.3 “MAST verification/termination 失败无解”

**结论：绝对化，改正。**

MAST 本身给出干预数据：ChatDev 高层目标验证使 task success +15.6%；角色层级优化 +9.4%。但另一项 topology intervention 对 GPT-4 的 Wilcoxon p=0.4，不显著；在 GPT-4o 才 p=0.03。正确结论是验证通常重要，但效果依赖模型、任务和验证器质量；“有 verifier”不是银弹。

本轮据此增加多层门：worker `submitted`、机器验收、Lead 批准。验收仅覆盖声明的 command/file_exists/file_sha256，不能证明高层产品目标；文档明确保留该剩余风险。

### 3.4 “lease 是错误设计，应否定”

**结论：混淆租约与锁。**

Gray/Cheriton 1989 的 lease 是故障下有界存活权机制。Newbee 的 lease 用于判断任务执行者是否仍有活性，不应声称它提供文件互斥。上一版因为 Harness 不把 task owner/write scope 当锁，就推导应否定 lease，这是 category error。

修正：保留旧协议 lease 以兼容存活性回收；v2 正确文档化：lease 不是写权限，Board CAS 也不是文件锁。

### 3.5 “Persona 已实体化为 model/tool/budget/system 配置”

**结论：上一实现不真实。**

原 `Persona.compile/1` 只返回 map；Delegator 不消费 model/tool/budget；persona 提示通过普通 collaboration message 注入，且固定 `group_id=hive`，不是 system 权限；自制 TOML parser 对语法错误近乎全接受。

修正：

- 用户配置改为严格 JSON schema；未知字段/错误类型/过长 instructions 拒绝；
- 只保留 runtime 已支持的 provider/model/reasoning_effort/instructions；
- 配置在 child session 启动前持久化；Web.Session 构造 client 时读取 model/effort；Agent.Loop 将 instructions 加到受信 system prompt；
- 不再声称 tool allowlist/token budget 已实现。它们要实现必须进入 Host capability 与 Loop 用量执行路径，不能只是 prompt。

### 3.6 “fork_turns 已实现”

**结论：上一实现只收参数，完全未使用。**

修正后的 ContextFork 只复制已完成的 `user → final assistant` 轮次；排除 system、tool、tool_calls、reasoning、usage 私有字段和不完整尾轮。支持 none/N/all，拒绝往非空 child 写入，并以 64 个完整轮次、128 KiB 文本为硬上限；超限显式失败而非静默截断。这吸收了 Codex fork 对工具协议项的过滤思想，同时避免把父代理权限/工具结果当作子代理输入。

### 3.7 “send quiet / wake 已实现”与“interrupt 可用”

**结论：上一实现不成立。**

原 Hive `send` 只把 `wake` boolean 存入新 Group，没有调用 Web.Session；`interrupt` 把 session id 直接传给需要 pid 的 `Web.Session.interrupt/1`，还忽略 group_id 和权限。

修正：quiet 映射到现有 Coordinator `notify`（只落持久时间线），wake 映射到真实 `wake` 投递；interrupt 先验证 Lead/直接父权限，再 `lookup` pid。这里没有声称实现“quiet 注入下个上下文而不唤醒”；Newbee 目前没有这个 primitive，文档按真实语义写。

### 3.8 “Codex 无持久状态、无 peer 寻址”

**结论：描述过时/错误。**

审计 commit 中已有 SQLite-backed `agent-graph-store`，持久化 parent/child edge 与 open/closed 状态。Codex v2 的 target 经 `AgentPath.resolve`，不是只能父子通信；`send_message` 能解析可见 agent path。更准确的差异是：该源码没有 Hive/Harness 式持久共享任务 Board 与 CAS task revision。

### 3.9 “OTP 天然解决 Activation 生命周期”

**结论：过度乐观。**

OTP 解决 process supervision，不自动解决 durable session、inbox ownership、cold resume、idempotent delivery 或 task/session/run 生命周期映射。原 Hive 的 Group 甚至没进 Application supervisor。正确做法是复用已经受监督的 Coordinator 与 Web.Session，而不是凭语言特性宣称问题消失。

---

## 4. 修正版架构

```text
Agent.Loop capability token
        │
        ▼
Newbee.Tools.Hive                  模型可见意图 API
        │
        ├── delegate ──> Delegator ──> workspace / persona / fork / Web.Session
        │                          └── commit one collab_delegated event
        │
        └── board/send/wait/verify
                 verify│  （主节点执行，不接收模型构造的 attestation）
                       │
                       ▼
        Collaboration.Coordinator  唯一线性化事实源
                       │
                       ├── EventStore durable log
                       ├── revision + CAS
                       ├── DAG + write-scope diagnostics
                       ├── waiters (ephemeral derived state)
                       └── message/task dispatch
```

### 4.1 不变量

- **I1 单一事实源**：无 `Collab.Group`；UI、legacy Collaboration 与 Hive 共用 Coordinator/EventStore。
- **I2 CAS**：v2 Board mutation 均携带 exact revision；验收执行期间有任意 Board 变化，提交即拒绝。
- **I3 DAG**：依赖必须存在；形成环的更新拒绝；依赖未 `succeeded` 不可 claim；已指派依赖在前序通过后自动激活。
- **I4 责任不可自改**：worker 不能改 title/description/acceptance/depends_on/write_scope，任务开始后连 creator/Lead 也必须先转 blocked 才能改契约。
- **I5 独立完成门**：worker 只能 `submitted`；`succeeded` 仅来自受信验收。legacy update/claim/renew 对 v2 返回 `protocol_mismatch`。
- **I6 验收来源**：调用者不能提交 attestation；主节点依据权威 task/workspace 运行检查，contract SHA-256、逐项规格和 revision 在提交时重检。
- **I7 无丢唤醒**：revision check 与 waiter registration 在同一个 GenServer callback；组删除也唤醒；RPC timeout 覆盖最长 120 秒事件等待。
- **I8 有界输入**：depth/cumulative spawn、task count、fork 上下文、验收项/argv、Board JSON 载荷均有上限；command 验收项只有 Lead 可创建或修改。
- **I9 诚实 Persona**：只声明 runtime 真正消费的字段；JSON 严格校验，模型配置在发布成员前验证，system prompt 以 profile hash 失效缓存。
- **I10 生命周期/迁移**：异步 kernel boot 归 Session 所有并可取消；旧事件缺少 revision/total_spawned 时仍能重放。

### 4.2 结构化验收

支持：

```json
{"kind":"command","program":"mix","args":["test"],"timeout_ms":120000}
{"kind":"file_exists","path":"lib/newbee/foo.ex"}
{"kind":"file_sha256","path":"artifact.bin","sha256":"..."}
```

command 只接受白名单程序与 argv 数组；验收契约最多 32 项，argv 最多 64 项且逐项限长，每个参数 shell quote，运行进程树受 `Run.sh` timeout/cleanup 管理。只有 Lead 能写 command 验收，普通成员只能写文件存在/哈希条件。文件检查拒绝路径逃逸与任一路径分量的符号链接。

验收在主节点执行，模型只请求 `verify`，不能传入结果。attestation 保存 exit code、**被 Run 捕获的至多 32 KiB 输出**之 SHA-256/字节数/截断标记、检查时间；不把原始命令输出写入共享 Board。该哈希不是完整 stdout 哈希，字段名明确为 `captured_output_sha256`。

安全边界：这是**验收证据**，不是不可信项目的沙箱。`mix test`、`make` 等程序会执行项目代码；Lead 调用 verify 即明确授权该检查。Board CAS 约束协作状态，不提供文件系统 snapshot/lock；attestation 证明 `checked_at` 时观察到的结果，不证明工作区此后未被外部 writer 修改。

公共 Hive API 的 capability 防止正常工具调用自报别的 session；它不是对任意 evaluator Elixir/RPC 的安全沙箱。把 `Newbee.Collaboration.Coordinator` 视为 Ring0 内部接口仍依赖 Host/CapabilityGate 边界，本文不把它宣称为抵御任意恶意 BEAM 代码的隔离机制。

### 4.3 为什么仍是中心化 Lead

外部数据支持“中心化验证降低错误传播”，不支持无条件 peer mesh。`Towards a Science of Scaling Agent Systems` 报告独立架构 trace error amplification 17.2×，中心化协调为 4.4×；但其跨域模型 `R²=0.373`，只能解释部分方差，而且 SWE-bench/Terminal-Bench 各仅 20 实例。故本轮选择中心化生命周期与验证、允许定向消息；不声称这是所有任务最优。

---

## 5. 可复现实证

### 5.1 上一实现故障复现

正常 Agent.Loop 注入的是：

```elixir
Process.put({Newbee.Tools.Collaboration, :context}, %{capability: token})
```

上一 Hive 却查自己的 key 并期待 `%{session_id: ..., project_root: ...}`。实测返回：

```text
{:error, "no_execution_context", "无协作身份..."}
```

另经源码追踪确认 shadow group 的 coordinator 是 `hive-shadow-<id>`，真实 parent 不在其中，Delegator 的 `parent_can_delegate` 必然拒绝。

### 5.2 新测试覆盖

新增的反例和正例覆盖：

- 正常 capability 可 `Hive.open`，无 token 拒绝，Hive 插件声明真实 `fs/shell` 副作用；
- 两个同 revision 并发 writer 仅一个提交；验收运行期间 revision 漂移不能提交；
- DAG 阻止提前 claim，前序验收事件先广播，随后自动激活已指派依赖；
- worker 不能自证 succeeded、不能改任务契约，旧 Collaboration API 不能绕过 v2 完成门；
- 调用方伪造 `all_passed=true` 被忽略，Coordinator 运行实际检查并得到 blocked；
- 非 Lead 不能注入 command 验收，Board 缺 command_id、超长文本、非 JSON 结果均拒绝且 revision 不变；
- contract hash、逐项结果、捕获输出摘要、验收项/argv 限额、路径逃逸和符号链接拒绝；
- write scope 重叠只产生 diagnostic，不伪装为文件锁；
- wait 边沿、timeout、caller 清理、group delete 和长 RPC timeout 对齐；
- EventStore 重放恢复 revision/command idempotency，真实旧版 delegated 事件缺 `total_spawned` 仍可启动；
- depth 与累计 spawn 限额不会因 close 洗掉；v2 非法 acceptance 在 workspace/session 物化前预检拒绝且零副作用；
- persona JSON 字段/类型/名称严格校验，无效模型在 member 发布前回滚；profile 改变会失效 system prompt 缓存；
- fork 排除 system/tool/tool_calls/未完成轮次，超 64 轮或 128 KiB 明确失败；
- delegate 保持同一个 Coordinator group，无 shadow group；interrupt 解析 pid 并校验 Lead/直接父权限；
- Session 在异步 evaluator boot 中销毁时取消启动树，真实 node primary/standby 故障回归继续通过。

此外用仓库现存旧事件库执行 `mix run`，验证应用可完成启动；验证命令见文末。

### 5.3 尚未证明

- 没有证明 Hive 能提高 Newbee 在真实仓库任务上的 solve rate；
- 没有证明 token 成本下降；wait 只消除了轮询这一项；
- 没有自动估计任务可分解度或最优 agent 数；
- 没有 durable 离线 mailbox acknowledgement / exactly-once delivery；
- 机器验收不能自动判断高层需求是否满足；command 检查会执行项目代码，不是 sandbox；
- Board revision 不冻结文件系统，尚无验收时刻的不可变 workspace snapshot；
- capability 保护公开 Hive 调用路径，不构成针对任意恶意 BEAM/RPC 代码的进程隔离；
- 本地测试不代表生产延迟，测试通过也不等于多代理在成本/质量上优于单代理。

下一轮应建 paired benchmark：同一任务、同一模型、固定总 token/tool budget，对比 single-agent 与 Hive，报告成功率、wall-clock、token、tool calls、冲突数和 verification false-positive；至少用 bootstrap 置信区间，不能只报单次 demo。

---

## 6. 证据矩阵

| 主张 | 证据 | 能支持什么 | 不能支持什么 |
|---|---|---|---|
| 多代理有显著成本 | Anthropic Research 报告（2025-06-13）：multi-agent ≈ 15× chat（单代理 ≈4×）；token 用量解释 BrowseComp 方差约 80% | 必须做价值/成本 gate | 不能外推所有模型和任务 |
| 并行只适合可分任务 | Amdahl 1967；Anthropic coding 限制；Scaling 跨 6 基准相对单代理 +80.8% 到 -70.0% | 默认保守 opt-in | 不能给出 Newbee 的精确阈值 |
| 失败不仅来自模型 | MAST 1,600+ traces、7 框架、14 模式聚 3 类（论文无跨系统聚合占比） | 需要架构/通信/验证治理 | 不能证明某个具体 API 有效 |
| 验证可改善结果 | MAST ChatDev 干预 +15.6%；SEMAP failure count 降幅 | 值得设置验证门 | 不代表 verifier 是银弹 |
| 中心验证可抑制传播 | Scaling：Independent 17.2× vs Centralized 4.4×；跨域 R²=0.373（capability 口径 0.413）；SWE/Terminal 各取 20 实例子集 | 支持 Lead verify | 样本有限，不能外推所有任务 |
| 更多 agent 可能提高 benchmark accuracy | More Agents 采样投票随规模增益；MoA AlpacaEval 2.0 65.1 vs GPT-4 Omni 57.5 | 并行采样在某些任务有效 | 不等于长时工具型编码协作有效 |
| 任意 mesh 不一定好 | MacNet 无 memory control 上下文随 n² 增长；1→16 节点制品 token 长 7.51×；HumanEval chain 0.3720 低于 CoT 0.6098 | 不开放无界 peer mesh | 不证明层级永远最优 |
| CAS 可定义并发正确性 | Herlihy & Wing 1990；本项目并发测试 | 防 stale write | 不防工作区外部 writer |

---

## 7. 来源

### 外部论文与工程数据

1. Gene M. Amdahl, *Validity of the Single Processor Approach to Achieving Large Scale Computing Capabilities* (1967), DOI: https://doi.org/10.1145/1465482.1465560
2. Cemri et al., *Why Do Multi-Agent LLM Systems Fail?* arXiv:2503.13657v3, https://arxiv.org/abs/2503.13657
3. *Towards Engineering Multi-Agent LLMs: A Protocol-Driven Approach* (SEMAP), arXiv:2510.12120v1, https://arxiv.org/abs/2510.12120
4. Li et al., *More Agents Is All You Need*, arXiv:2402.05120v2, https://arxiv.org/abs/2402.05120
5. Qian et al., *Scaling Large Language Model-based Multi-Agent Collaboration* (ICLR 2025), arXiv:2406.07155v3, https://arxiv.org/abs/2406.07155
6. Wang et al., *Mixture-of-Agents Enhances Large Language Model Capabilities*, arXiv:2406.04692v1, https://arxiv.org/abs/2406.04692
7. *Towards a Science of Scaling Agent Systems*, arXiv:2512.08296v3, https://arxiv.org/abs/2512.08296
8. Anthropic Engineering, *How we built our multi-agent research system* (2025-06-13), https://www.anthropic.com/engineering/multi-agent-research-system
9. Herlihy & Wing, *Linearizability: A Correctness Condition for Concurrent Objects* (1990), DOI: https://doi.org/10.1145/78969.78972
10. Gray & Cheriton, *Leases: An Efficient Fault-Tolerant Mechanism for Distributed File Cache Consistency* (1989), DOI: https://doi.org/10.1145/74850.74870
11. Hayes-Roth, *A Blackboard Architecture for Control* (1985), DOI: https://doi.org/10.1016/0004-3702(85)90063-3

### 源码依据

- Codex：`core/src/agent/control.rs`、`agent/registry.rs`、`tools/handlers/multi_agents_v2/*`、`protocol/src/protocol.rs`、`agent-graph-store/*`。
- DeepSeek Harness：`packages/subagent/*`、`packages/experimental/agent-team/*`、`2026-08-05-agent-teams.md`。Teams 在该 commit 仍是 private experimental package，不应表述为稳定产品基线。
- Newbee：`Collaboration.Coordinator`、`Delegator`、`Verification`、`ContextFork`、`Persona`、`Workspace`、`Capability`、`Web.Session`、`Agent.Loop`。

### 验证命令

```bash
mix compile --warnings-as-errors
MIX_ENV=test mix compile --warnings-as-errors
mix test test/newbee/collaboration
mix test test/newbee/dee/evaluatornodetest_test.exs --include node
mix test test/newbee/tools/tool_documentation_contract_test.exs \
         test/newbee/tools/documentation_contract_test.exs
mix test
```
