# newbee 设计：可自我进化的项目共生 Elixir 环境

**语言**：Elixir ｜ **打底模型**：OpenRouter `deepseek/deepseek-v4-flash-0731`（标称 1.31M 上下文，多后端适配器可换）。标称窗口只用于兼容性和预算上限，不作为设计成立的前提；有效注意力按实测值计，光头策略在短有效窗口下仍必须成立。

---

## 0. 1. 愿景与第一性原则

> **newbee 不是"让大模型替你写代码"，而是"把大模型放进一个长期运行的、版本化的、可自修改的 Elixir 环境里：它用 Elixir 作为手和脑完成任务，环境则根据真实使用证据持续把自己改得更聪明、更便宜——每一次改变都可评价、可回退、可归因。"**

三条第一性原则，互为犄角：

1. **上下文极简主义（光头优先）**：知识住环境不住 prompt；pull over push；可见工具面封顶 3 个（`run_elixir`/`done`/`ask`）。上下文臃肿不只是贵，是**变笨**。环境每编译掉一个模式，模型的上下文需求就永久降一分——**光头是环境收敛的方向**。
2. **环境能力全模块化**：一切能力（工具/规则/提示/工作流/provider/验证器/projection）都是 Plugin——可配置、可替换、可评价、可回退。没有例外层，没有旁路。
3. **模型自治，宿主守物理边界**：worker 和 adapter 都是模型，拥有请求、实现、评价、激活、回退的自治权；Host Shell 只阻止凭证泄露、越宿主边界、不可恢复的破坏。**自治的激进程度与安全网厚度成正比**（§8.1）。

---

## 2. 与 Claude CLI / Codex 的核心差异

| 维度 | Claude CLI / Codex | **newbee** |
|---|---|---|
| 执行模型 | 一次性临时沙箱 | **长期存活的版本化环境**：daemon 常驻，TUI 只是探视窗 |
| 中间结果 | 每轮重算/重传 | **绑定持久化**：变量跨轮存活，跨 generation 迁移（§4.4） |
| 工具形态 | 预定义固定集 | **Plugin Release**：模型可新增/修改，不可变版本 + 原子激活 + 一键回退 |
| 自我进化 | 无 | **认知 JIT**：教训→沉睡规则→蒸馏工具，热度剖析驱动晋升，退化即 deopt（§8.5） |
| 进化的裁判 | 无 | **五层评价**：静态/确定性/反事实回放/真实使用/纵向，失败抗体单调增长（§8.2） |
| 代理拓扑 | 单 loop | **Worker/Adapter 双模型 Agent**，消息协议解耦，激励隔离（§7） |
| 上下文 | 挂满 skill/长提示 | **光头**：知识是 Event Store 的物化视图，按需拉取（§4.6） |
| 项目关系 | 无状态工作目录 | **项目共生体**：`.newbee` 是环境的权威快照，重启完整恢复（§11） |

**一句话**：Claude CLI 是"模型吩咐工具干活"；newbee 是"模型住在一套它自己持续翻修、且每块砖都有版本和质检记录的房子里干活"。

---

## 3. 统一对象模型

### 3.1 Environment 与 Revision

当前项目的可运行能力集合：

```text
Environment = Manifest(active revision 指针)
            + Active Releases
            + Project Profile
            + Plugin Configuration
            + Agent Message State
            + Evaluation Evidence
```

`revision` 单调递增。任何 active 变化产生新 revision；**回退 = 移动 active 指针到历史 revision**，历史永不删除。

### 3.2 Plugin：能力的唯一形态

Plugin 是有稳定身份与生命周期的能力模块，≠ 一个 `.ex` 文件：

```text
plugin_id       稳定逻辑身份，如 project.parser
kind            tool | rule | prompt | workflow | adapter | provider |
                evaluator | verifier | projection | stateful_service
module          Elixir 模块入口
contract        Plugin Contract 版本
dependencies    依赖的 plugin_id/release_id
state_policy    stateless | migrate | restart | external
capabilities    ⭐ 声明式能力清单：允许调用的 Host API、副作用类别
                (fs/shell/net/push…)、资源预算。Host 按此校验，
                未声明的能力在 tools/pre-execute 被物理拒绝
effects         有状态插件声明的 effect 清单：ets | pg | pubsub | registry |
                process | external；必须经 runtime wrapper 创建和登记
configuration   项目配置（脱敏后可注入投影）
```

**kind 体系是 DESIGN 全部机制的收纳格**（§3.5 映射总表）。源码只是 release 的载体之一：release 可含多源文件、测试、资源与声明。

### 3.3 Release：不可变版本 + 实测价签

```text
release_id · plugin_id · parent_release · source_files · source_hash
contract_version · dependencies · usage(给 worker 的使用说明)
author(worker|adapter|system) · change_id · evaluation_ids · created_at
```

- `active` 只能指向过了最低健康门的 release；候选在评测完成前不得进入 active。
- **Release 严格不可变**：`source_hash` 不变则内容一字不动——实测数据因此**不属于** Release。
- **价签 = `ReleaseObservation` 事件流 + fitness 投影**（⭐ 修正"不可变"与"持续更新"的矛盾）：每次使用带 `release_id` 归因记账，产生 observation 事件（token 成本、成功率、延迟、输出大小，按**模型 × 任务类型 × 时间窗口**分桶）；`fitness` 是评价层对 observation 的持续聚合投影，可随证据变化，**绝不写回 Release 本体**。Projection 向模型暴露聚合价签——模型按"够用且最便宜"显式选路；fitness 供 adapter 排序需求与基因库分享（§8.2/§14）。样本不足的桶不展示。

### 3.4 Change：可回退的最小审计单元

```text
change_id · base_revision · candidate_revision · changes[]
reason · request_id · author_agent · expected_version · attempt · deadline
evaluation_plan · evaluation_result
status: requested | building | evaluating | canary | active |
        rejected | degraded | rolled_back | promoted
```

一次 Change = 一个回滚单元，对应 DESIGN 的补丁纪律：**小**（最小相关单元，禁成片重写）、**有据**（指向事件日志具体证据）、**带 before/after 快照**。禁止把无关变更揉成"自动更新"。

**并发与恢复规则**：Coordinator 是状态机唯一写入者（OTP 单写者串行化，邮箱即顺序保证，无需分布式租约），`expected_version` 做乐观校验、过期请求直接拒绝；状态转换只由 durable 事件驱动——daemon 崩溃后从最后一个已落盘事件重新驱动，不产生半成品状态；评测超 `deadline` → `rejected(reason: timeout)`；重复 `candidate_ready` 按 `change_id` 去重。同一 plugin 允许多个并行 candidate，但激活按到达顺序串行裁决。

### 3.5 概念映射总表 ⭐（融合的核心）

DESIGN 的每个机制，在统一对象模型中的落位：

| DESIGN 机制 | 统一模型落位 | 说明 |
|---|---|---|
| 工具即脚本/热载 | `kind: tool` 的 Plugin + generation switch | 热载语义升级为 candidate→评价→激活（§4.4） |
| JIT L1 教训 | `kind: prompt` release（记忆片段） | 读到要花 token 推理 |
| JIT L2 沉睡规则 | `kind: rule` release | 平时零成本，触发才注入（§6.3） |
| JIT L3 蒸馏工具 | `kind: tool` release（带测试的纯函数） | 调用零 token |
| L1→L2→L3 晋升 | 同 plugin 或派生 plugin 的 release 演进 | 热度剖析决定编译收益（§8.5） |
| deopt 去优化 | Change `degraded` → 回退到上级形态的 release | 知识不丢，条件合适重新编译 |
| RepoMap | `kind: projection` 的内置 plugin | 工程结构图是物化视图的一种 |
| 沉睡规则触发引擎 | Projection Builder 的 live 拦截器（§6.3） | compaction 后存活获架构解释 |
| 失败抗体 | Evaluation Evidence 中的回归测试 | 成为后续 Change 的确定性门（§8.2） |
| 反事实回放 | Counterfactual 评价层 | 旧日志 + 新视图构建器（§8.2） |
| PPT 锦标赛 | Verifier 的比较算法 | 多候选选 top-1 再进门（§8.2） |
| Progress 验证器 | Worker loop 的 live 机制（不进 release 生命周期） | 停滞事件成为 adapter 线索（§7.5） |
| 价签系统 | `ReleaseObservation` 事件流 + fitness 投影（Release 本体不可变） | §3.3 |
| 进化线索 | `need` 消息（urgency: low） | worker 的一句话便宜事（§7.3） |
| 权限环 Ring 0-3 | 各 kind 的激活门槛配置 | §8.3 |
| 基因库 | Global Store 的 bundle + fitness | §14 |
| 事件溯源/物化视图 | Event Store + Projection Builder | §4.6 |
| 绑定持久化 | Evaluator 能力 + Binding Continuity 协议 | §4.4 ⭐新机制 |
| J-Space 工作协议 | `kind: workflow` 内置插件 | §6.4 |
| 统一寻址 `Newbee.read/1` | 环境 API（Host Bridge 一部分） | §5 |
| worker/adapter 分工 | Worker Agent / Adapter Agent | §7 |
| 进化档位 off/hint/background/auto | Autonomy Policy 档位 | §8.1 |

---

## 4. 运行时架构

### 4.1 总图

```text
┌─────────────────────────────────────────────────────────────┐
│ Host Shell / OTP Supervisor（Ring 0，唯一物理边界）           │
│                                                             │
│  Environment Coordinator ── Event Store ── Project Store    │
│       │                       │                             │
│       ├── Worker Agent        ├── Global Store              │
│       ├── Adapter Agent       └── Projection Store          │
│       ├── Verifier                                            │
│       └── Projection Builder                                  │
│              │                                                │
│        Evaluator Pool / Generation Manager                    │
│              │                                                │
│        隔离 BEAM 节点：active releases + persistent bindings   │
│                                                             │
│  TUI / CLI（薄客户端，可 detach，只消费 Projection）           │
└─────────────────────────────────────────────────────────────┘
```

环境是常驻生命体，TUI 只是探视窗：daemon 在终端关闭后依然存活、记忆、进化；`newbee attach` 随时接回。

### 4.2 Host Shell（Ring 0）

唯一不可被当前项目模型覆盖的边界：

- LLM 凭证与 provider 请求（evaluator 节点 env 经 denylist 剥离一切 key）；
- Agent / Coordinator / Event Store / Evaluator Pool 的 OTP 监督；
- 项目路径与权限边界；release/manifest 原子提交；generation 切换；
- 审计与紧急停用（`emergency_stop`）。

Host Shell 不是"不可升级的全部业务逻辑"。可变能力必须走 Plugin Contract 接入；替换 Host Shell 只能在独立 newbee 版本或受控实验节点完成——这就是 Ring 0 的精确定义：**不是不能改，是代价极高（完整反事实回放 + 人工签署 + 独立发布）。**

### 4.3 Environment Coordinator

Change/Release/Revision 状态机的唯一驾驶者：收消息、排评测、动 active 指针、发通知、做回退。任何模块不得自维护另一份 active 状态。Coordinator 只串行处理元数据和指针转换；候选构建、编译、回放和模型调用全部委托给有界任务队列与 Evaluator Pool，可并行执行，完成后以事件回报 Coordinator，避免唯一写入者变成计算瓶颈。

### 4.4 Evaluator Pool / Generation Manager + Binding Continuity ⭐（融合新机制）

模型代码只在独立 BEAM 节点运行（崩溃隔离：最坏杀死求值器节点，宿主毫发无损）。Pool 管理多 generation：

```text
1. active generation 服务当前 worker
2. adapter 在 candidate generation 加载候选环境
3. 跑 compile / contract / health / 项目测试 / 回放
4. 通过 → Binding 快照迁移（见下）→ 原子切换路由
5. 旧 generation 排空后停止；切换失败则 active 不变
```

`state_policy`：`stateless`（新码直接接管）/ `migrate`（模块自声明状态迁移）/ `restart` / `external`（只存连接配置）。

**Binding Continuity Protocol**（解决两份文档都未回答的问题：generation 切换时，"模型的 IEx"怎么办）：

0. **quiesce**：切换前 Coordinator 令旧 generation 进入静默——拒收新 step、等待当前调用完成（带超时兜底）；快照期间 binding 冻结，杜绝"快照后继续写"的丢失更新；
1. 快照当前会话 bindings，附元数据（`session_id` / `generation_id` / `revision` / 序列号 / 校验哈希）；
2. **codec 白名单 + 大小预算**：只允许明确可序列化的类型（数据/AST/字符串等，逐项编解码，不反序列化任意 term）。小值内联迁移；原本就是 `ArtifactRef` 的值继续以内容寻址句柄按需加载并受背压/总量预算控制。普通大值不能在迁移时静默替换成句柄（那会改变 Elixir 变量类型），必须在预算内原样恢复；超预算则取消切换，并提示 worker 先显式 artifactize；
3. 非白名单项（PID、闭包、Port、Reference、ETS tid、外部资源句柄）置 tombstone，名字保留、访问时报明确错误。runtime 在 binding 由纯函数或幂等工具产生时记录可选 `recompute_recipe`，有可靠 provenance 且重放无副作用才提供一键重算；任意匿名函数无法从 `Code.fetch_docs` 可靠恢复源码，不作此承诺；
4. 恢复按 binding 粒度进行：单个值失败只 tombstone 该值，不拖垮整体；迁移摘要（迁了几个、tombstone 几个）进入 worker 的下一次投影；
5. 切换失败则 binding 随旧 generation 原样存活，零损失。

**三类状态各归其主**（修正"绑定属于 revision"的含糊表述）：`session_bindings`（worker 的 IEx 变量，**属会话**，跨 generation 迁移）；`plugin_state`（有状态插件的服务状态，按 `state_policy` 处理）；`environment`（active release graph，属 revision）。绑定不是 Environment Revision 的组成部分——它与 revision 的唯一关系是：迁移时按新 revision 的 codec 契约做兼容性校验。

这里的“原子”只指**路由指针切换**：快照和大值持久化在切换前完成，不能宣称跨节点数据传输本身原子。若 quiesce、Artifact 写入或恢复准备超过预算，取消本次切换并恢复旧 generation 接流量，不带半迁移状态继续。

### 4.5 Plugin Contract

```elixir
@callback id() :: String.t()
@callback version() :: String.t()
@callback describe() :: map()
@callback dependencies() :: list()
@callback health(context :: map()) :: :ok | {:error, term()}
@callback self_test(context :: map()) :: {:ok, map()} | {:error, term()}
@callback start(context :: map()) :: {:ok, term()} | {:error, term()}
@callback stop(state :: term()) :: :ok
@callback migrate(old_version, state, context) :: {:ok, state} | {:error, term()}
```

无状态工具只实现静态子集，runtime 用兼容包装器运行。**"源码能编译" ≠ "合法插件"**。
统一 Envelope 之外，各 kind 可在后续 Phase 扩展专属契约（ToolContract / RuleContract / ProviderContract…）；第一阶段只强制 Envelope + `capabilities` 声明——先统一生命周期与安全边界，再逐步加深类型约束（与"先统一生命周期，再扩大插件种类"的非目标一致）。
**Effect 回收 = 受监督生命周期 + 显式登记**：Plugin Runtime 以 `DynamicSupervisor` 管有状态插件，启动/停止经有界任务池执行并设超时，单个插件阻塞不占住 Coordinator；规模达到实测阈值后可由 `PartitionSupervisor` 分片，不把“50 个插件”本身视为 BEAM 扇出问题。ETS、进程、`pg`、PubSub、Registry 和外部连接必须通过 runtime wrapper 创建并写入 `effects` 登记表；停止时按登记表回收并做 leak check。绕过 wrapper 的任意直接调用无法保证自动回收，因此 contract 违规会令 health gate 失败，而不是承诺无条件“零悬挂”。

### 4.6 事件总线与四层存储：上下文是日志的物化视图

全系统**一条事件总线**，两域：

- **durable 事实**：`turn/*`、`step/*`、`change_*`、`release_*`、`need/feedback/rolled_back`、`tool/*`——进 Event Store，重启存活；
- **live 拦截点**：`agent/pre-step`、`llm/stream`（沉睡规则监控面）、`tools/pre-execute`——不落盘，供策略与观察。

四层存储：

| 存储 | 权威内容 |
|---|---|
| **Project Store** | 项目 active revision、release、change、消息、评价证据 |
| **Global Store** | 跨项目 release、经验 bundle、模型配置默认 |
| **Event Store** | 不可变事件流（追加写） |
| **Projection Store** | 给 worker/adapter/TUI 的物化视图 |

**写入权威与恢复规则**（消除"双写 JSONL + Event Store"的歧义）：

- **Event Store 是唯一同步事实写入**：一切状态变化先追加事件（单调 `event_id`），落盘成功才算发生；
- Project Store 的 manifest、`environment.json`、`messages.jsonl`、Projection 全部是事件流的**派生快照/视图**，各自记录已应用的事件水位（checkpoint）；
- 崩溃恢复 = 从最近 checkpoint 重放事件流重建快照；快照与事件流不一致时以事件流为准；
- 幂等与审计由此获得实现保证：重复事件按 `event_id`/`message_id` 去重，重放不产生二次效应。

核心心智模型（两份设计在此天然会师）：**LLM 看到的上下文不是日志，而是日志的物化视图**——

- **compaction = 视图维护**：压缩改视图不动日志，原始事件永远完整；
- **沉睡规则在每次构建视图时重新应用**——这是"compaction 后依然存活"的架构级解释，不依赖上下文残留；
- **反事实回放 = 旧日志 + 新视图构建器/新 release**：同一段历史换上进化后的环境重新投影，即得新旧版本的真实对比；
- 日志同时是回滚的数据基础与进化的审计网：可回答"环境怎么一步步变好/变坏"，任意时间点可重建。

一切订阅同一条总线：TUI 渲染、指标采集、沉睡规则、审计日志、adapter 触发——零各自为政的监听点。

---

## 5. 环境能力面（全部以内置 Plugin 承载）

模型在 evaluator 中可调用的能力（每个都是内置 release，同样可进化）：

- **代码 IO**：读/写/追加/复制/移动/删除/遍历工程树（`tool` 插件：`Fs`）。
- **双轨编辑**：
  - **文本轨 · 文件快照 + 行号范围**（`Edit`）：唯一公开 API 是 `show/2`、`patch/1`、`source_literal/1`。`show` 返回文件级 `[path#tag]` 快照标签和普通行号；`PUT N..M / PUT <N / PUT >N / CUT N..M` 全部指向原快照。文件变化（stale）、越界、未读范围、重叠和 no-op 一律拒绝，多节预检全过后原子落盘。模型不再手抄逐行 hash。
  - **安全源码字面量**（`Edit.source_literal/1`）：动态选择目标内容中不存在的 raw sigil 分隔符；全部冲突时回退普通转义字符串，避免二阶插值和 heredoc/sigil 同分隔符嵌套。
  - **结构轨 · Sourceror**（`Structural`）：保留格式注释的 AST 重写，按 `模块::def` 定位替换。选 Elixir 的最大技术红利。
  - 分工：Elixir 语义级修改优先结构轨；普通文本局部修改走 Edit；新文件或整文件重写走 Fs。
- **热加载**（`HotReload`，2026-08 落地）：`replace/load_file/purge/unload/status`——源码/BEAM 热替换（软 purge，`force: true` 硬 purge），`target: :main` 经 RPC 作用主节点，调试-生效秒级闭环免重启。
- **运行**：`Run` 统一承载 shell、编译和测试；长超时直接传 `timeout:`，不提供 `sh_long`/项目专用测试别名。
- **工程**：`Scaffold` 只负责 `mix new` 和首次 `deps.get`，不重复封装 Run 的编译/测试。
- **统一寻址**：`Newbee.read/1` 通吃文件/目录/URL 与内部 scheme——`memory://`、`skill://`、`agent://<id>/findings`、`conflict://N`、`bindings://`、`events://`。只教模型一个接口。
- **内省**：`Introspect`（模块文档、AST、beam chunk、类型信息）。
- **RepoMap**（`projection` 插件）：紧凑工程结构图（模块/`@moduledoc` 摘要/公开签名/struct 字段），mtime 指纹增量缓存。模型凭图定位 → 只对目标区域取细节。
- **记忆/状态**：全局与项目级持久状态读写（自动脱敏剥离密钥）。
- **大对象逐出**（`ArtifactRef`）：大 binding 自动逐出为 artifact 引用（`%ArtifactRef{ref: ...}`），模型持引用可按需拉回——长期会话不因大对象撑爆绑定。
- **数据工具**：`Json`/`Http`/`Search`/`Git`/`Diff`。
- **工具错误契约**：可恢复错误统一返回 `{:error, %{reason: atom(), hint: String.t(), ...}}`；bang 函数保留 Elixir 抛异常语义。`Run.sh` 返回 `%{exit, exit_code, output}`，`exit_code` 是 `exit` 的直觉别名。简单 URL GET 优先 `Newbee.read/1`，需 POST/headers/status 时使用 `Http`。
- **工作协议**：`JSpace`（§6.4）、`BestTool`（显式不确定性聚合）。
- **宿主桥**：`Newbee.Host.*` 类型化请求——调模型、代理消息、审计、调度。模型能改造环境的一切，物理上碰不到宿主的心脏：**宽松策略管"行为"，宿主契约管"能力"，后者不依赖模型自觉。**

---

## 6. LLM 交互协议

### 6.1 循环与工具面

```text
用户意图 → TUI → Projection Builder 组装 Prompt
   （RepoMap + 工具一行签名清单 + 记忆 Guidance + 绑定摘要 + module_ready 通知）
        → LLM (function calling)
        → run_elixir(code) ──▶ Evaluator（持久 bindings）
        │      ├─ 正常返回 → 压缩结果回填
        │      ├─ 编译/运行错误 → 完整错误回填
        │      └─ 需确认 → TUI 暂停 → 恢复
        → done(summary) / ask(question)
```

**工具面 = 3 个，封顶**：

| 工具 | 参数 | 说明 |
|---|---|---|
| `run_elixir` | `code: string` | 主力通道。自由 Elixir：循环/条件/批量/调一切插件，binding 持久 |
| `done` | `summary: string` | 声明完成，附总结 |
| `ask` | `question: string` | 需用户确认/澄清 |

降级通道：模型偶发在正文输出 ` ```elixir ` 块时，容错解析器兜底执行并温和纠偏。
新能力永远进环境（Plugin），不进工具面。

**模型工具提示分三层，禁止重复注入**：

1. **常驻 function schema**：只含上述 3 个 function，预算 ≤1.5KB；只描述调用时机和参数形状。
2. **常驻能力索引**：全部内置 tool/workflow/projection/provider 各一行“何时用”，预算 ≤1.8KB；不展开函数表。
3. **按需 `tool://`**：模块用途、边界和示例 + `Code.fetch_docs` 自动生成的真实调用签名与 `@doc`，单模块预算 ≤3.5KB。手写函数清单不重复进入模型上下文。

每个模型可见函数必须有 `@doc` 和调用示例；`@doc false` 只用于 RPC/内部入口。API 删除或默认参数变化由契约测试校验，避免说明漂移。

**健壮性（2026-08 落地）**：

- **错误自动续跑**：流中断/上游 400/过载（429/5xx）等 `retryable_goal_error` 在 goal 模式下自动重试（`error_retries < max_error_retries`，退避），错误信息可读化回填。
- **沉睡规则当轮重试**：命中沉睡规则不是冷冰冰的注入——中断当前流 → 注入 reminder → **当前 turn 内自动重试**，错误当口当场纠正（§6.3 从"下轮才看见"升级为"本轮即纠正"）。
- **思考强度（reasoning_effort）**：7 档 `off/auto/low/medium/high/xhigh/max`，TUI/WebUI 热切，会话级持久化，重启保留。
- **多模态输入**：WebUI 图片上传/粘贴（data URL 管线），TUI/CLI 用 `/image <路径>` 发图。

### 6.2 结果回填的 token 控制

默认压缩：exit code + stdout 尾部 / diff 统计；模型**写代码过滤**（`Enum.take`/`filter` 后再 inspect——确定性压缩，而非 LLM 摘要）；长输出写文件回路径+行数摘要，或存 binding 留待引用。

### 6.3 沉睡规则：双身份重生 ⭐（融合新表述）

沉睡规则在融合架构中有精确的双重身份：

- **存储身份**：`kind: rule` 的 Plugin Release——有版本、有评测、可回退、带价签（触发次数 × 节省的返工 token）；
- **运行时身份**：Projection Builder 构建视图时挂载的 **live 拦截器**，监控 `llm/stream`（正文、thinking、工具参数），命中触发条件（regex/AST 模式）→ 中断流 → 注入 system reminder → 从断点重试。

由此获得 DESIGN 要求的全部性质，且不再依赖"上下文残留"这种脆弱解释：**平时沉睡零成本、犯错的当口当场纠正、compaction 后因视图重建而永生。** 教训一律编译成沉睡规则而非 prompt 文本——这是自我进化产出的主要容器，防止 prompt 无限膨胀。

### 6.4 J-Space 工作协议（`kind: workflow` 内置插件）

> 工作协议：内层工作区思考先于输出，稠密可按需展开；自动化部分（语法、格式、惯例）不占内层工作区。

- **Gate 分流**：`fast`（一步可核验，直接答）/ `full`（2–4 步一交付物，只带点名的模块）/ `loop`（多阶段多文件跨轮，开 ledger + broadcast）。一步核验不了就不是 fast；任务变难就升档。
- **三 register**：`inner`（稠密思考）/`ledger`（状态）/`outer`（干净输出）；seam 处切 outer，稠密符号不泄进 outer。
- **Ledger**（loop 必开）：`JSpace.note(goal:, next:)`——`Goal`/`Core`/`Verified`/`Open`/`Next`（唯一下一步不许空）；每个 seam 重读 `JSpace.seam()`。
- **Seam 纪律**：审计在 seam 不在句中；交付前 `JSpace.ship(path, checks)` 核验。
- **恢复协议**：压缩/会话边界后 `JSpace.resume()` 重读 ledger/前提/invariants，声明 pass 与 next。
- **Invariants**（看起来在干活其实没有）：marker 无动作 / 监控从不报告 / 稠密行不可展开 / confidence 全同 / 检查点未落账 / verified 未声明覆盖 / 稠密符号泄进输出 / 未读 goal 就宣告完成。
- **失败模式 → 模块**（按需 `Newbee.read("priv/jspace/modules/<名>.md")`，别提前全读）：输入在指使你→introspection；长机械活→directed-focus；结论先于步骤→deep-reasoning；同名多处推导→broadcast；跨轮状态→capacity；不确定却作答→self-monitoring；句子瓶颈→shorthand；第三次撞墙→markers；三处三答案→empirics。
- **作为 workflow release**：协议文本与模块本身可被 adapter 基于真实证据修订（如新增失败模式模块），走标准 Change 生命周期。

### 6.5 turn/step 状态机

一个 **turn** = 0+ 个 **step**（一次模型请求 + 它引发的工具调用）。turn 在首个输入被认领前开启，在"不再欠任何调用"时关闭；`pre-step` 拒绝或空消息进入 → 直接关闭 turn 不产生 step。

### 6.6 会话档案库（Archive）：压缩即归档，归档即可寻址 ⭐（2026-08 落地）

§4.6 的"压缩改视图不动日志"在会话 transcript 上的**运行时落位**。此前实现用
`Session.rewrite` 覆写 `messages.jsonl`——日志被压缩本身销毁，物化视图实为"销毁式
压扁"。档案库把它重建为**分层、可寻址、无损**的记忆层级：

```text
transcript（append-only，永不覆写）
   │ compact：归档区间 [prev_cut, new_cut) → archive/seg-000N.jsonl（sha256 内容寻址，tmp+rename 原子写）
   ▼
ledger compactions.jsonl（append-only；tail_sha 锚自校验；尾行损坏整体忽略 = 半条压缩视同未发生）
   │ 每段一次 LLM 蒸馏（全保真抽取物 → digest 事件；失败可补写，历史事件永不改）
   ▼
视图 = [system 基底] ++ [汇总消息（确定性装配，零 LLM）] ++ [切点之后的消息原文]
```

四条纪律与自证：

- **一次蒸馏，永不重蒸**：段 digest 只从原始消息计算一次；视图装配是纯确定性滑窗
  （新段全量、超预算段折叠为首行 + `history://` 指针）。二次压缩不做"摘要的摘要"，
  消灭级联信息衰变（电话游戏）；
- **确定性优先**（§6.2 回归压缩）：归档时先解析出类型化事实——用户意图**逐字**
  （意图脊柱，永不衰减）、文件路径、✗→✓ 错误对（对话级失败抗体）、✓ 验证结果；
  LLM 只补叙事。LLM 失败时账本兜底，不再出现"摘要失败，历史已截断"；
- **pull over push 补全**：`Newbee.read("history://")` 索引 / `s/<段>` 摘要+账本 /
  `s/<段>/raw` 原文 / `q/<关键词>` 跨段全文检索 / `files` 文件清单。被压缩的对话
  随时可拉回，且不加任何工具（光头工具面不破）。peer 求值节点经 `Newbee.Host.call`
  回主节点执行；
- **崩溃安全与漂移降级**：段文件原子写；账本尾行损坏截断；`tail_sha` 与 transcript
  不对齐（旧版本覆写遗留/外力改动）→ 该切点作废，视图优雅降级为原始消息。

与既有机制的相容：视图构建后照常 `repair_history` 修补悬空 tool_calls；J-Space 恢复
提醒照常注入；无账本旧会话逐字节兼容；TUI/CLI 回放仍读全量 transcript（UI 永远看得
见完整历史）；provider 前缀缓存语义不变（摘要固定在消息位 2，两次压缩之间仍只追加）。
`Session.rewrite` 标记废弃保留。`session: false` 的 ephemeral 模式走旧内存路径。

**档案召回（查询感知 rehydration，零检索基础设施的 mini-RAG）**：用户提交新输入时，
宿主对已压缩段做确定性词元打分（latin/digit ≥3 去停用词 + CJK 二元组，命中 distinct
词元数 ≥2）；强相关时在请求尾部注入一条 `[档案召回]` 指针提示——**只指路不推载荷**
（细节仍走 `history://` 拉取，光头原则不破；注入即追加，不破前缀缓存）。无档案/弱
命中/异常一律静默。CLI/TUI 侧新增 `/archive [关键词]` 命令：裸查询出段索引，带关键词
跨段全文检索。

### 6.7 WebUI：HTTP/WS 控制台（2026-08 落地）

浏览器里的完整工作台，与 TUI/CLI 同一内核、同一项目环境：

- **RPC-over-HTTP**（`Newbee.Web.Api`）：`POST /api/<method>` JSON-RPC 信封（`rpcId` + `payload` → `result.ok | result.error`）。方法域：`auth.*`（status/captcha/setup/login/logout）、`session.*`（list/history/queue/switch_model/set_effort/set_cwd/…）、`git.*`、`evolution.*`、`workspace.*`。`safe_dispatch` 兜底：异常/exit 一律回 JSON 错误信封，不裸 500。
- **WebSocket 下行**（`Newbee.Web.Socket`）：`GET /ws?session=<sid>` 订阅 Bus，该会话 Loop 事件以 JSON 帧实时推送（text/tool/usage/progress/rule_hit…）；上行控制帧 `interrupt / permission / prompt / promptImage`——连 WS 即可完成"问 → 看流 → 中断"闭环。
- **排队执行**：busy/booting 期间的输入入队（`:queue`），turn 结束自动 `dispatch_pending` 顺序消化；`interrupt` = 停止当前 + 清空排队（广播提示）。杜绝"输入被吞/转向"。
- **渐进加载**：长会话分页拉历史（limit/offset + total，"加载更多"），首屏只出尾部近段；done 总结持久化到 transcript，刷新不丢。
- **token 用量与缓存命中率**：气泡级实时展示当轮 prompt/completion/缓存命中（usage 事件 + cache-hit 统计），成本可见。
- **Mission Control 面板**（第 5 tab）：文件追踪 + step 时间线 + diff 查看 + 进化事件流；evolution 面板并入其中，支持手动触发进化（manual evolution trigger）。
- **checkpoint**（`git.checkpoint.create/list`）：UI 一键打点 `[checkpoint] <desc>` 提交（本地线性历史），跨会话回溯关键节点。
- **多模态与图片**：点击放大、`@文件` 引用自动补全、文件路径可点击。
- **认证**：本地回环免认证；远程强制 Bearer（登录 + SVG 验证码 + 限流锁定；WebSocket 用 `?token=`）；HTTPS 自签证书 + `--redirect` 308 跳转。
- **前端**：`priv/web/`（index.html + app.js + style.css），无构建步骤的 SPA。

### 6.8 多后端协议适配：Responses API（2026-08 落地）

`Newbee.LLM.Config` 的 provider 支持 `api` 字段（`openai-completions` | `responses`），`Newbee.LLM.Client` 按 provider 路由。`Newbee.LLM.Responses` 实现 OpenAI 系 **Responses API**（`POST /responses`，`input` + `tools` + `reasoning`），兼容 Muse 等新端点：

- `input/1` 消息规整（含工具结果）、`tools/1` 转义 function calling、`reasoning/1` 映射思考强度档位、`parse/1` 解析 `output` 数组（`function_call` / `message` / `reasoning` 分派）。
- **过载重试**：429/500/502/503/529 退避重试（默认 5×1s），与 Completions 路径摘参重试双保险。
- **前缀缓存兼容**：`Newbee.RequestEnvelope` 记录上次路由请求的可缓存前缀快照（消息+tools+route 逐字节），Archive 摘要请求 = 快照严格前缀 + 尾部压缩指令 → 前缀缓存命中成立（未命中绝不伪装命中）。

---

## 7. Worker / Adapter：两个真正的模型身份

### 7.1 分工与激励论证

```text
Worker Agent (1 个)                    Adapter Agent (0..1 个，后台)
─────────────────                      ─────────────────────────────
用 active 环境干活                      读：事件流 + 指标 + need 消息
察觉重复模式/能力缺口                    ↓ 做所有贵的事
  ↓ 只做一件便宜事                      诊断 → 合成候选 release → 自测
  发一条 need 消息                       ↓
(≈ DESIGN 的"进化线索")                 过 Verifier + 确定性门
↓ 继续干活，不分心                       ↓
用完模块给版本级 feedback               按 Autonomy 档位激活/canary
发现退化发 rollback_request             收负反馈 → 修订或回退
```

**为什么不让 worker 顺便做进化**（深思熟虑，不是偷懒）：
1. **激励错位**：worker 的目标函数是"完成任务"，不是"环境长期变好"；
2. **视野不够**：最有价值的信号是跨任务模式（"这周出现 5 次"），只有旁观全局的 adapter 看得见；
3. **归因污染**：任务中途改环境，失败时无法区分"任务难"还是"新模块有 bug"——变异与执行必须隔离，因果才干净；
4. **不占前台**：复盘推理烧 context，放后台不进主循环。

**为什么不让 adapter 全包**：它没亲历任务，"当时哪里痛"的高保真信号事后难还原——所以 worker 保留**发一条 need 消息**的轻量通道（几乎零成本、不分心），adapter 做贵的综合。分工原则：**worker 供信号，adapter 做合成，评价层做裁判。**（DESIGN 的"进化线索"与 NEW_DESING 的 need 消息在此完全合一。）

**隔离边界**：worker 不直接改 adapter 工作区与 active manifest；adapter 不接管用户任务、不碰 worker 的 transcript/bindings。上下文、evaluator、token 预算各自独立。

### 7.2 协作消息协议

所有消息**是事件流中的一类事件**（`messages.jsonl` 只是其派生物理视图，写入权威见 §4.6），含 `message_id/request_id/project_id/sender/created_at/payload`。传递语义是 **at-least-once + 幂等 effect**，不宣称分布式 exactly-once：

- sender 在首次发送前将 `message_id = {agent_id, monotonic_seq}` 持久化到 outbox；重试复用同一 ID，agent 重启后序列号不得回退；
- Coordinator 的 inbox 先按 `message_id` 去重，再追加受理事件；outbox/inbox 水位都可由 Event Store 重建；
- 产生副作用的操作另带**操作级 idempotency key**：激活 `{change_id, candidate_revision}`、回退 `{rollback_change_id, target_revision}`、预算扣减 `{change_id, attempt, budget_kind}`。`feedback` 允许同一 release 多次上报，只按 `message_id` 去重，不能粗暴使用 `{change_id, release_id}`；
- 事件追加与预算/状态转换记录在同一 Coordinator 事务边界内；崩溃后重放只补未完成 effect，不重复发布、回退或扣预算。

消息载荷：

```text
need               worker → adapter     {capability, expected_api, context, evidence, urgency}
candidate_ready    adapter → coordinator {change_id, plugin_id, release_id, evaluation_plan}
feedback           worker → adapter/coordinator
                   {request_id, plugin_id, release_id, outcome, score, errors,
                    latency, output_size, comment, suggested_action}
rollback_request   worker → coordinator  {request_id, plugin_id, release_id, target, reason}
module_ready       coordinator → worker  {change_id, plugin_id, release_id, usage, evaluation_summary}
module_rejected / evaluation_failed
                   coordinator → 双方     {change_id, reason, evidence, next_action}
rolled_back        coordinator → 双方     {revision, plugin_id, release_id, reason}
```

### 7.3 通知语义

发布不是写日志。Coordinator 必须：①更新 active revision；②广播 `module_ready`；③通知进 worker 下一次投影；④worker 执行中则排队，不打断运行中的 turn；⑤附版本、契约、用法与评测摘要。

### 7.4 其余 Agent

- **advisor**（可选第三角色，默认关）：只读旁观的第二模型，读 worker 每轮输出内联插评（concern/blocker），worker 看到后自我纠偏。advisor 管当下质量，adapter 管长期进化。
- **explorer**：worker 临时 spawn 的探索/测试子代理（共享 ETS 记忆、独立 LLM 上下文、git worktree 隔离并行改码、schema 校验的结构化返回而非散文）。
- **模型角色路由**：`default`(worker) / `adapter` / `explorer`（最便宜）/ `advisor` / `verifier` / `plan` 各自绑定不同模型——成本与能力按意图分配。

### 7.5 Progress 验证器：Worker loop 的 live 机制

> 验证是继 pre-training / post-training / test-time compute 之后的第四 scaling 轴。

- `Progress` 对轨迹前缀打**连续分数**（1..20，字母刻度 A..T 单 token）：三轴齐备——刻度粒度 G=20、K 次重复采样、标准分解（Specification/Output/Errors 三子标准 ensemble）；logprobs 可用时对评分 token 全分布取期望（零 tie，捕获不确定性）。
- 每 `every` 步（默认 5）打分一次；`stalled?`（窗口内净增长 ≤ 阈值）触发**一次性干预注入**（提醒回退到高分状态）。
- 分数进事件流："某类任务频繁停滞"成为 adapter 的 need 线索；verifier 高方差（模型自己不确定）驱动 `ask` 而非 `done`。
- 走 `verifier` 模型角色，opt-in 开启控成本。**它是 worker 的仪表盘，不进 release 生命周期。**

---

## 8. 自治、评价与晋升

### 8.1 三层策略（权限环的最终形态）

| 层 | 控制对象 | 档位 | 性质 |
|---|---|---|---|
| **Host Safety** | 凭证、主 VM、外部系统、项目路径 | 不可配置 | 硬边界，模型不可越 |
| **Capability Policy** | 文件/命令等外部副作用 | `lenient`(默认)/`ask`/`deny` | 宽松放行 + 高风险审计 + git/文件快照 `/undo` 兜底 |
| **Autonomy Policy** | 环境变更（Change 激活） | `observe`/`manual`(默认)/`autonomous`/`emergency_stop` | 见下 |

Autonomy 档位语义（吸收 DESIGN 的 off/hint/background/auto）：

- `observe`：adapter 只产出建议与评测，不激活（≈ `:off`/`:hint`）；
- `manual`：评价通过后需人 `/approve` 激活（默认起点）；
- `autonomous`：过门的 Change 自动激活/canary，事后通知可 `/undo`（≈ `:background`/`:auto`）；
- `emergency_stop`：冻结一切环境变更，仅允许回退。

**自治是挣来的，不是默认的** ⭐（两份设计冲突的融合解）：当项目满足 ①已验证失败抗体数 ≥ 阈值 ②回放覆盖率 ≥ 阈值 ③近 K 个 Change 无人工回退——Coordinator 才**建议**升 `autonomous`（人确认一次）。安全网随使用变厚，自治档位才配放开。反之触发健康告警自动降档。阈值不预设拍脑袋常量：P4 前先以 `observe` 跑一个足够覆盖典型任务的观察窗口，采集 change/失败/回退基线后再校准；“两周”可作为运营起点，不是架构常量。

**激活判定 = 多套规则的合取**（消除 Autonomy 与 Ring 门槛的优先级歧义）：

```text
可激活 = Host Safety ∧ Capability Policy ∧ Autonomy 档位 ∧ Ring Gate ∧ 资源预算
```

各 kind 的**自治上限**（Autonomy 档位再高也不得突破）：

| kind | 自治上限 |
|---|---|
| `tool` / `workflow` / `projection` | `autonomous` |
| `rule` / `prompt` | `autonomous`，但须先经 canary |
| `provider` / `stateful_service` | `manual` 封顶 |
| Ring 0（Host Shell） | 永不由当前模型激活 |

`/approve` 不是命令副作用，而是一条带签名的**授权事件**（进 Event Store，可审计、可撤销授权）。

### 8.2 评价五层（DESIGN 裁判系统的落位）

| 层 | 评价者 | 作用 | 融合的 DESIGN 机制 |
|---|---|---|---|
| **Static** | compiler / contract checker | 语法、入口、依赖、contract | — |
| **Deterministic** | self-test / 项目测试 / **已验证失败抗体** | 可重复正确性 | 抗体两态生命周期（见下），bench 随使用单调增长 |
| **Counterfactual** | verifier / 历史回放 | 与 parent 比，不只看绝对成功 | 反事实回放（两种模式，见下），真实使用当裁判 |
| **Real usage** | worker feedback + 价签测量 | 顺不顺手、错误、耗时、质量 | 使用归因绑定 release_id；ReleaseObservation 持续聚合 |
| **Longitudinal** | coordinator | 多次任务后的成功率/回退率/token 成本 | 指标采集进 fitness；驱动 deopt |

- **PPT 策略选择**（Best-of-N）：先按候选数与 verifier 预算比较 `N(N-1)/2` 和 PPT 预计比较次数；全配对更便宜时直接全量比较，PPT 更便宜时才执行 ring pass（随机 Hamiltonian 环双槽比较，抵消位置偏置）→ pivot 选择（top-k）→ pivot tournament（预算集中头部）→ 聚合（w/c 归一化 argmax）。不硬编码 `N<4` 或 `N>=5`，阈值来自实测成本模型。只有 top-1 进确定性门；verifier 不可用时退回 deterministic gate + 历史 fitness，证据仍不足则保持候选并列、不得用均匀随机排名自动发布。
- **失败抗体两态生命周期**（修正"真实失败 = 回归测试"的过度承诺）：真实失败先记为 `observed_failure`（完整输入、环境 revision、release_id、外部副作用、错误输出）；能重放、具备正确性 oracle、经独立验证后，才晋升 `verified_regression_test` 进入确定性门。证据事件永久保留，但 active bench 不无限全量执行：抗体按“近期触发率 × 拦截价值 × 覆盖独特性”分为 `hot`（每次跑）/ `warm`（抽样跑）/ `cold`（归档、相关变更时唤醒）；GC 只调整执行层级，不删除历史证据。不可复现的失败保留为证据但不充当门——防止把错误假设固化成测试。
- **反事实回放的两种模式**：**投影回放**（不执行——用新视图构建器/新 release 重建 prompt 与决策输入，确定性对比，零副作用）；**执行回放**（需 replay fixture：固定模型 I/O 或随机种子、工程快照、依赖 lock、环境变量、时间）。每个 tool release 声明 `replay_policy: rerun | stub | forbid`：纯函数/白名单工具可在 worktree 或隔离节点重跑；外部网络、shell 与不可逆操作默认使用日志桩；`forbid` 出现在关键路径时该会话不得充当自动晋升门。新旧行为一旦分叉，比较只覆盖两边都实际重跑的子集，桩结果只能验证投影兼容性，不能证明工具进步。比较须报覆盖子集、重复次数与置信区间——"优于 parent"必须有统计含义（与 §8.3"样本不足不得宣称优于"一致）。
- adapter 可提评价计划，不能伪造评价结果；verifier 可以是模型，但确定性门失败不能由模型投票绕过。
- 用户验收（`/approve` 与否）作为真实世界信号回流指标。

### 8.3 晋升状态机与 Ring 门槛映射

```text
requested → building → statically_validated → evaluated → canary → active → promoted
任何阶段 → rejected
active/promoted → degraded → rolled_back
```

- `canary` 可只对 adapter 或一小组 evaluator 请求生效；
- worker feedback 是评价样本不是审批；`score` 必须绑定具体 release；
- 新 release 样本不足不得宣称优于 parent；adapter 须按失败原因产生下一个 Change，而非无限重放同一候选。

**Ring → 激活门槛**（DESIGN 权限环从比喻变成配置）：

| 环 | 层 | 门槛 |
|---|---|---|
| Ring 3 | `tool`/`workflow` 插件 | Static + Deterministic + canary（日常进化发生在这里） |
| Ring 2 | `rule`/`prompt` 插件 | + Counterfactual 回放对比 |
| Ring 1 | 记忆/策略晋升全局 | + 跨项目验证（默认项目局部生效） |
| Ring 0 | Host Shell | 当前模型不可改；独立 newbee 版本发布 + 完整回放 + 人工签署 |

门槛看似“规则比工具更严”是有意设计：工具失败通常以返回错误、测试失败或显性 diff 暴露；规则/prompt 的退化会静默改变模型行为，归因更难，因此必须增加 Counterfactual 评价。

### 8.4 回退：一等公民

```text
worker rollback_request / health 失败 / 错误率超阈 / verifier 判退化 / generation 启动失败
  → coordinator 受理
  → 回退是 release graph 级操作，不是单插件指针移动：
    · 优先直接切到某个历史 revision（整图已知健康）；
    · 若目标是"把插件 X 回退到某 release"（rollback_request 的 target 只是线索），
      Coordinator 构造候选 revision——X 置为目标 release、其余插件重新解析依赖图，
      通过 contract/health 检查才允许切换；依赖不兼容则拒绝并给出解释
  → 写 rollback change → 启动目标 generation → health/self-test
  → 原子切换 active revision → 通知双方
```

回退只移动指针，不删除 release、评价与失败证据；回退后的环境仍可被 adapter 再改。启动恢复时 active revision 无法启动：不覆盖损坏 manifest → 从最近 known-good revision 逐级回退 → 标记 `degraded` → 通知双 Agent → 保留失败证据（不静默删除）。

### 8.5 认知 JIT：在 Release 生命周期上重生

环境不是仓库，是 JIT 编译器——持续把"需要模型推理的智能"编译成"不需要推理的确定性产物"：

| 级 | 类比 | 产物（统一模型形态） | 每次使用成本 |
|---|---|---|---|
| L1 教训 | 解释执行 | `kind: prompt` release（what/when/why ≤2KB，去重脱敏） | 读到要花 token 推理 |
| L2 沉睡规则/playbook | 即时编译 | `kind: rule` release | 平时零，触发极少 |
| L3 蒸馏工具 | 原生编译 | `kind: tool` release（纯函数+测试） | **调用零 token** |

三个标志性机制的运行时落位：

- **热度剖析（profiling）**：事件流统计每个模式的出现频率 × 单次 token 成本 = **编译收益**；越过阈值（收益 > 编译成本）才作为高优 need 进 adapter 队列——不热的模式永不编译，避免过度工程。价签数据让阈值计算越用越准。
- **编译（compile）**：adapter 执行晋升。"批量改名所有调用者"第一次花 12 轮推理；固化成 `Refactor.rename_callers/3` 后一次 tool call 完成。同 plugin 的 release 演进或派生新 plugin。
- **去优化（deopt）**：L3 工具被判退化时降级回 L2 形态 release 而非删除——假设失效就去优化，知识不丢，条件合适重新编译。

模型每固化一个模式，对自身智商的依赖就降一分——**环境在字面意义上变聪明，同时变便宜。**

---

## 9. 上下文极简主义工程（12 条落位）

| # | 手段 | 架构落位 |
|---|---|---|
| 1 | 绑定持久化 | Evaluator + Binding Continuity（§4.4）——最大头的节省 |
| 2 | RepoMap | `projection` 插件，注图不注全文 |
| 3 | 结果回填压缩 | 默认 exit code + 摘要；模型写代码过滤（确定性压缩） |
| 4 | 工具提示分层 | 3 个 function schema + 全内置能力一行索引 + 按需 `tool://` 真实签名；均有字节预算 |
| 5 | 记忆分片 | 按 topic 索引按需检索；Memory Guidance 块有 token 上限 |
| 6 | 推理固化 | 认知 JIT（§8.5），直至零 token |
| 7 | 异步后台 | adapter/索引构建不占主循环预算 |
| 8 | 增量 diff 上下文 | 只看 delta 不看全文 |
| 9 | 快照行号编辑 | `Edit` 插件：一次文件 tag + 普通行号范围，兼顾直觉与 stale 安全 |
| 10 | 沉睡规则 | `rule` release + live 拦截（§6.3），平时零 context |
| 11 | 价签系统 | ReleaseObservation 投影（§3.3），省 token 成为模型的显式决策 |
| 12 | 渐进式披露 | 一行签名清单 → 判定相关后 `Newbee.read/1` 取全文，永不注入全量文档 |

### 9.1 状态与投影 GC

极简主义也约束环境侧状态，不能把 prompt 膨胀转移成磁盘和内存膨胀：

- **bindings**：按大小和最近访问 turn 做 LRU 预算；可序列化冷值逐出到 Artifact Store，binding 名保留为显式 `ArtifactRef`（仅对原本允许 artifactize 的值），`/bindings` 显示驻留/逐出状态；用户或 workflow 可 `pin`，活跃值不静默删除；
- **memory**：topic 带 TTL、最后引用时间和 `pin`；过期普通记忆转归档投影，安全规则、用户明确固定项与评价证据不因 TTL 删除；
- **J-Space ledger**：在 seam/compaction 时保留 Goal、Open、Next 与 Verified 哈希，已完成细节写 artifact 后从活跃投影移出；
- **bench**：采用 §8.2 的 hot/warm/cold 抗体分层，历史证据单调保留，执行成本受预算约束。

---

## 10. TUI：Projection 的一个消费者

**原则：交互模仿 codex / pi，程序员零学习成本；差异化全在内核。**

- **单列流式对话布局**：用户消息、模型输出、工具块、diff 依次流式追加；默认不做多窗格（`Ctrl+T` 可选：工程树/绑定清单/事件日志/环境版本图）。
- **工具块折叠**：`run_elixir` 显示为可折叠块（代码 + 压缩摘要，方向键展开完整 stdout）。
- **内联 diff**：写文件/编辑以语法高亮 inline diff 展示。
- **底部多行输入**：Enter 发送、Shift+Enter 换行、↑/↓ 历史、Tab 补全；Esc 打断、Ctrl+C 取消/双击退出。
- **状态栏**：模型、项目、会话、累计 token/花费、bindings 数、autonomy/capability 档位、active revision。
- **技术选型**：自研 ANSI 渲染栈（`TUI.Screen` 双缓冲 diff 重画 + `TUI.Key` 按键解码 + `TUI.Line` 行编辑）——无第三方终端依赖，全屏/滚动/粘贴/双宽字符全自控。

命令体系（`/xxx`），新命令以环境对象模型为准，旧命令做兼容映射：

| 命令 | 行为 |
|---|---|
| `@文件` / `!命令` | 引用文件 / 在 evaluator 执行 shell |
| `/init` | 扫描工程生成 `NEWBEE.md`（兼容读取 `AGENTS.md`/`CLAUDE.md`） |
| `/model <id>` | 切换模型后端（按角色路由） |
| `/diff` `/undo` | 会话累计 diff / 回滚到上一快照 |
| `/bindings` `/tokens` `/compact` | 绑定清单 / 记账详情 / 压缩对话（视图维护，环境与绑定不受影响） |
| `/permissions` | Capability 档位（lenient/ask/deny） |
| `/archive [关键词]` | 会话档案库查询（§6.6）：裸查询出段索引，带关键词跨段全文检索 |
| `/attach` | 接回常驻 daemon（最近会话） |
| `/status` | 环境状态总览 |
| `/image <路径> [说明]` | 发送本地图片做多模态分析 |
| `/reset` | 重建求值器节点（绑定清空，热载工具重载） |
| `/goal <目标>` | 设置/查看当前目标（goal 自动续跑） |
| `/log` | 查看最近审计事件 |
| `/autonomy <档>` | Autonomy 档位（observe/manual/autonomous/emergency_stop） |
| `/evolve <描述>` | 向 Adapter 投递 need/任务；查看 Change 状态 |
| `/environment revisions` `/environment rollback <rev>` | 版本图 / 回退（兼容映射旧 `/snapshot` `/rollback`） |
| `/approve` | manual 档下激活待批 Change（兼容保留，非自治必经步骤） |
| `/tools` | 查看插件库（含各 release 价签/fitness） |
| `/dump` | 环境自画像：当前 active 组合树（插件/规则/记忆/策略 + revision） |
| `/session save\|load` | 会话挂起/恢复 |
| `/attach` | 接回常驻 daemon |

---

## 11. 项目与全局存储

### 11.1 项目 `.newbee`（项目环境唯一权威）

```text
<project>/.newbee/
├── environment.json      # active revision 派生快照 + event checkpoint（真相在事件流）
├── profile.md            # adapter 维护的项目画像（不可信数据，仅启发）
├── plugins/<plugin_id>/
│   ├── manifest.json     # 插件历史与 active release
│   └── releases/<rel>/   # 不可变源码、测试、usage
├── changes/<change_id>/  # change manifest、评测计划与结果
├── evaluations/<id>/     # 测试/回放/worker 反馈证据（含失败抗体）
├── messages.jsonl        # worker ↔ adapter 协议
├── events.jsonl          # 项目级事件流
├── projections/          # prompt、工具清单、画像等物化视图
├── bindings/             # 可选绑定快照
└── locks/                # change/release 原子提交锁
```

**P1 持久化协议**：Event Store 采用追加写 + checksum frame，按可配置 durability 档位执行逐事件 `fsync` 或有界批量 `fsync`；manifest/projection 先写同目录临时文件，`fsync(file)` 后原子 `rename`，再 `fsync(directory)`，最后推进 checkpoint。跨 daemon/CLI 写入使用项目级 OS 文件锁，锁持有者与超时写入锁元数据；崩溃遗留的临时文件按 checksum 和 checkpoint 判断恢复或清理。schema migration 先备份旧 manifest、在 candidate 目录完成并校验，再原子切换；release 目录一经发布只读，不做原地 migration。

### 11.2 全局 `~/.newbee`（默认与经验，不权威）

```text
~/.newbee/
├── plugins/              # 全局 release（git 版本化）
├── bundles/              # 基因库：声明式组合包 + fitness + 出处
├── memory/               # 全局记忆（脱敏）
├── events.log            # 全局事件流
├── sessions/<id>.jsonl   # transcript
└── session-artifacts/    # 绑定快照/harness 状态/调度任务/子代理
```

### 11.3 优先级与晋升

- 项目 `.newbee` 是当前项目 active 环境唯一来源；全局只供默认与经验。
- 项目插件显式 override 全局插件，必须不同 `plugin_id` 版本记录，禁止文件名排序覆盖。
- 全局经验进项目前必须过项目 adapter 兼容性检查；项目反馈默认不污染全局，跨项目验证后晋升（Ring 1 门槛）。
- 配置合并优先级：`Host 硬边界 > 项目 active config > 项目 profile > 全局默认 > 插件默认`。

### 11.4 文档分工（治漂移）

- **本文档**：唯一定义架构。
- **Event Store + 不可变 Release**：唯一定义已发生的运行时事实。
- `environment.json`：由事件流派生的 active revision/checkpoint 恢复快照，不与 Event Store 争夺权威。
- `NEWBEE.md`：人类项目说明（生成视图，可复用 `AGENTS.md`/`CLAUDE.md`）。
- README/系统 prompt/命令帮助：从对象模型生成的视图，定期再生成，不承载架构事实。

### 11.5 启动恢复

```text
discover project root → ensure/read environment.json → validate schema/active revision
→ resolve release 依赖图 → materialize active release set
→ boot candidate generation → health/self-test → Binding 快照恢复
→ switch active generation → build worker projection → resume 未完成消息
```

失败则逐级回退 known-good revision + 标 `degraded` + 保留证据（§8.4）。

---

## 12. 安全

- **三层策略**：见 §8.1。Host Safety 硬边界不可配置；Capability 默认 lenient + 高风险审计；Autonomy 默认 manual 随安全网成熟升档。
- **崩溃隔离**：模型代码只在 evaluator 节点；`System.halt`/NIF 崩溃/死循环最坏杀死节点，监督重启，当前调用重试一次。
- **凭证隔离**：evaluator 节点 env 经 denylist 剥离一切 API key；一切权威操作经 `Newbee.Host.*` 类型化请求由主节点校验执行。**provider 插件是无凭证的协议适配器**：只能产出经 schema 校验的请求计划；凭证注入、域名白名单、预算、重试与实际网络执行全在 Host Shell 的受控 transport——可变的是"怎么说话"，不可变的是"拿着谁的钥匙、能去哪"。
- **工作目录隔离**：模型写入限制在目标工程目录树内。
- **资源限制（务实版）**：执行超时 + 输出大小上限 + token/并发/磁盘预算；内存/系统调用级隔离只在可选严格档（`bwrap` 等 OS 容器）提供，不作默认承诺。
- **提示注入防护采用结构隔离 + 能力隔离，不把提示词当安全边界**：文件、URL、`profile.md`、tool stdout 等不可信内容统一包装为带 `origin/hash/trust=untrusted` 的类型化 `tool_result` envelope，永不拼接成 `system`/`user` 消息；围栏（如 `data file=...`）只用于可读性，不宣称能让模型免疫指令。taint 随 binding、摘要和投影传播，只有结构化 parser/validator 产出的字段可降级为 trusted。沉睡规则只监控 assistant 输出与待执行工具参数，不因 untrusted 数据里出现“指令文本”而生成二次 system reminder，避免攻击者借规则触发器升级权限。LLM 仍可能受内容影响，真正的安全下限由 Host capability 校验、路径/网络边界和不可逆操作确认提供。
- **副作用审计与可逆性分级**：所有外部副作用记录可回查，但"可撤销"按三级如实标注——`reversible`（文件类，快照 `/undo` 可回滚）/ `compensatable`（需补偿动作，如 git revert、发反向请求）/ `irreversible`（已发送的 HTTP、远端 push、外部 DB 写入——执行前必须单独确认或走严格档）。环境版本回退只恢复环境自身；回退报告必须明确实际恢复范围，不隐含"外部世界也回滚了"。
- **环境变更审计**：每个 Change 可回答——谁、何时、基于哪条证据、改了哪个 release、如何回退。

---

## 13. 目标模块树

```text
lib/newbee/
├── host/                       # Host Shell：凭证、路径、资源、RPC、紧急停用
├── environment/
│   ├── coordinator.ex          # Change/Release/Revision 状态机（唯一驾驶者）
│   ├── manifest.ex             # schema 与 active revision
│   ├── store.ex                # 项目 .newbee 持久化（原子写/锁/migration）
│   ├── plugin_manager.ex       # contract、依赖解析、release 物化
│   ├── plugin_supervisor.ex    # DynamicSupervisor、effect 登记、启动超时/leak check
│   ├── generation.ex           # generation 切换 + Binding Continuity
│   ├── evaluator_pool.ex       # 隔离 BEAM 节点池
│   ├── projection.ex           # worker/adapter/TUI 视图构建（沉睡规则挂载点）
│   └── verifier.ex             # 五层评价汇总（回放/PPT/确定性门）
├── agent/
│   ├── loop.ex                 # 通用 LLM ↔ tool ↔ result 状态机（turn/step）
│   ├── worker.ex               # Worker 角色（含 Progress live 机制）
│   ├── adapter.ex              # Adapter 角色（独立上下文/预算）
│   ├── advisor.ex / explorer.ex
│   └── protocol.ex             # need/feedback/rollback/module_ready（幂等）
├── session.ex                  # worker transcript/bindings（不管环境版本）
├── events.ex                   # 统一事件入口（Bus + Event Store）
├── codec.ex + codec/           # function calling + 降级解析
├── reader.ex                   # 统一寻址 Newbee.read/1
├── archive.ex                  # 会话档案库（§6.6）：压缩即归档 + history:// 可寻址
├── request_envelope.ex         # 可缓存前缀快照（§6.8，prefix-cache 命中前提）
├── artifact_ref.ex             # 大对象逐出引用（§5）
├── markdown.ex / event_log.ex / history.ex / hot_reloader.ex
├── web/                        # WebUI（§6.7）
│   ├── api.ex                  #   RPC-over-HTTP 网关（POST /api/<method>）
│   ├── router.ex               #   顶层路由：静态 + WS + 认证 gate
│   ├── socket.ex               #   WebSocket 下行流 + 上行控制帧
│   ├── session.ex              #   浏览器会话进程（排队/热切/持久化）
│   ├── auth.ex                 #   密码/Bearer/验证码/限流
│   ├── cert.ex / server.ex / workspace.ex
├── llm/
│   ├── client.ex responses.ex  # 流式 Completions + Responses API 双协议
├── memory.ex / permissions.ex / diff.ex / status.ex
├── tui/ cli.ex commands.ex daemon.ex   # 视图与控制，不持有环境状态
└── plugins/                    # 内置插件（兼容包装器）：
    ├── edit.ex structural.ex fs.ex run.ex git.ex search.ex json.ex http.ex
    ├── scaffold.ex introspect.ex jspace.ex hot_reload.ex besttool.ex repomap.ex
    └── provider/openrouter.ex  # plan(model, messages, opts) 无凭证计划器；受控 transport 在 host/
```

迁移映射（旧 → 新）：`DEE.Kernel` → `Agent.Loop` + Worker/Adapter role；`Tools.HotLoader` → `PluginManager`（兼容 facade 后删旧实现）；`Evolution.Evolver` → `AdapterAgent`；`Evolution.Snapshot` → Environment Revision；`Evolution.JIT` → release 晋升/deopt 策略模块；`Evolution.Policy` → AutonomyPolicy；`Staging` → 只管用户工程文件暂存；`DEE.Tools` → PluginRegistry 投影；`Session` 只管会话与绑定快照。

---

## 14. 二维路线图

架构轴（Phase，来自 NEW_DESING）× 能力轴（Milestone，来自 DESIGN）。当前定位分两层看，避免把"现有实现能跑"误读为"统一架构下已验收"：**现有实现**——M4 能力已原型落地（280+ tests / 双节点 / J-Space / PPT / Progress / 会话档案库 / WebUI）；**统一架构进度**——Phase 0–1 之间（对象模型统一进行中）。M1–M4 的每项能力须在新 Plugin/Change/Generation 合同下重新验收后才算"落地"。

| Phase | 架构工作 | 解锁的能力里程碑 |
|---|---|---|
| **P0 基线** | 本文档为唯一设计；建 characterization tests；冻结旧 HotLoader/Evolver/Snapshot 新功能；先做最小 Generation Switch spike（Fs+Edit，跑通 quiesce/snapshot/switch/tombstone），定义 replay harness 的 `rerun/stub/forbid` 边界，并把 §15 架构验收 5/7/8/11 写成可执行规格 | M0 赌注已验证（deepseek Elixir 首遍通过率达标）；旧架构中的 M1–M4 能力可用，但须在统一合同下重新验收 |
| **P1 Environment Store** | `.newbee` schema、四类存储统一落盘、原子写/锁/migration/启动恢复 | 不改变 worker 对话行为；会话挂起/恢复迁入新存储 |
| **P2 Plugin Runtime** | Plugin Contract、兼容插件包装、candidate generation、健康门、generation switch、**Binding Continuity** | 工具/规则/prompt/projection 统一 kind；热载获得回退语义 |
| **P3 Agent 分裂** | 通用 Agent Loop；Worker 保留现有能力；Adapter 独立 client/session/evaluator/预算；Coordinator 接管通信 | 进化与执行严格隔离；need 通道上线 |
| **P4 评价与回退闭环** | 五层证据接入；使用归因绑 release_id；幂等 feedback/rollback；自动 degraded/rollback；旧状态迁移后删除 | **认知 JIT 全自动**：profiling→compile→deopt；失败抗体单调增长；PPT 多候选；自治升档建议 |
| **P5 项目深度适配** | adapter 自动维护 profile/projections；项目命令/框架约定/常见错误/最佳工作流皆成插件 | **基因库**：L3 工具+规则+prompt 打成 bundle 带 fitness 跨用户分享——从单体进化走向群体进化；多模型后端；可选 Web 接口；公开评测基准 |

## 15. 验收标准

架构验收（缺一不可）：

1. 新项目首启创建 `.newbee`，重启恢复同一 active revision；
2. 至少两类非工具插件经同一 Plugin Runtime 加载；
3. 候选编译/测试失败不改变 active；
4. 任意 active release 可回退 parent 或历史 release；
5. **generation 切换后绑定迁移可验证**：codec 白名单内类型迁移成功率 100%，其余项 tombstone 化且访问报明确错误；迁移停顿 P95 低于预算（阈值入 §16 校准）；
6. worker 能提 need、收 module_ready、给版本级 feedback、发 rollback_request；
7. adapter 用独立上下文开发候选，碰不到 worker transcript/bindings 与宿主凭证；
8. 同一消息重复投递不重复发布/回退/扣预算；
9. generation 启动失败恢复最近 known-good revision 并标 degraded；
10. 每个环境改变可回答：谁、何时、基于哪条证据、改了哪个 release、如何回退；
11. 沉睡规则在 compaction 后依然触发（视图重建即重挂载）；
12. 删除旧 HotLoader/Snapshot/JIT/Evolver 旁路后，核心流程只有一套状态机。

智能验收（融合后机制不缩水）：

13. **已验证抗体**（verified_regression_test）覆盖的输入，在后续任何 release 的确定性门中零复现；
14. 进化补丁经反事实回放对比（投影回放或 fixture 完备的执行回放），非只跑固定考题；
15. 高频模式被固化为 L3 工具后，同类任务 token 消耗在相同测量窗口下可测下降（报样本量与置信区间）；
16. 价签与实测偏差在滑动窗口内收敛（窗口/偏差阈值为配置参数），样本不足的桶不展示；
17. 在 ≥N 组多候选任务上（N 入 §16 校准），PPT top-1 的确定性门 + 回放通过率不低于单候选基线 δ 以上。

## 16. 待细化问题

- **Binding Continuity 细节**：codec 白名单的精确类型集与大小预算；迁移停顿 P95 阈值的实测校准；tombstone 项"如何重算"提示的生成策略；
- **ReleaseObservation 分桶与保留**：模型 × 任务类型 × 窗口的分桶粒度；观测数据的保留期与聚合降采样策略；
- 跨工程全局记忆的命名空间/标签设计，避免 A 项目经验误用于 B 项目（bundle 的兼容性检查契约）；
- 评测任务集具体内容：哪些任务最代表真实使用分布；回放片段的选取策略（关键片段的定义）；
- 自治升档的具体阈值（抗体数/回放覆盖率/连续无回退 K 值），需实测校准；
- 子代理并发时的记忆一致性（ETS 并发读写冲突）；
- 模型后端适配优先级：OpenRouter 之外是否并行支持 Ollama 本地路由；
- advisor 的介入协议：插评的 token 成本与纠偏收益的平衡点。

---

> **融合宣言**：DESIGN 回答"环境为什么能越用越聪明"，NEW_DESING 回答"环境的每次改变为什么可信"。统一之后，newbee 是**一台有版本、有质检、有记忆的认知 JIT 编译器**——它编译的不是代码，是它自己的智能。

---

## 17. 附录：认知 JIT 的分级编译经济学（TCE，2026-08 落地）

> 设计文档：`docs/design-jit-economics/`（10 轮"设计→查证"闭环产物，证据链 r1–r10 + 总纲）。

### 17.1 核心命题

把 §8.5 认知 JIT 从"点估计启发式"升级为**不确定性下的在线投资决策系统**：

- 每个模式维护三组共轭后验（`PatternStats`）：频率 Gamma(a,b)、成功率 Beta(α,β)、
  节省幅度正态——全部充分统计量持久化，重启可恢复（`evaluations/pattern_stats.jsonl`）；
- 群体先验经经验贝叶斯（EB）收缩个体小样本估计；
- 时间衰减：有效样本量指数遗忘，均值保持、方差增大（近期分布权重更高）。

### 17.2 决策判据

```text
编译: LCB(net) = E[λ]·E[save] − κ·σ(net) − C(pattern 复杂度) > 0 且 n ≥ min_samples
      （LCB = 置信下界；κ 风险厌恶系数；小样本自然不决策）
排序: 候选按 LCB/C 降序进 adapter 预算队列
级联: E[save] = P(l3)·C_infer + P(l2_only)·(C_infer − C_l2)   （运行时便宜优先级联）
deopt 双通道序贯检验:
  工具坏: P(p < p_min | α,β) > conf 且频率未显著下降 → deopt 到 L2 候选（知识不丢）
  分布漂移: E[λ] 相对编译时快照跌落 > hσ → dormant 冷层级，工具不降级
```

### 17.3 校准闭环（元学习）

编译 Change 记录预测快照；实测回流结算相对平方误差（proper scoring rule，
系统性高报无利可图）；滑窗内分数收敛性检查；偏差驱动编译成本估计上调
（学习率 α 封顶 ×3）——环境对自身预测的预测越用越准。

### 17.4 实现落位

| 组件 | 文件 |
|---|---|
| PatternStats 纯函数库 | `lib/newbee/environment/pattern_stats.ex` |
| PatternStore 投影/持久化 | `lib/newbee/environment/pattern_store.ex` |
| Cascade 级联收益模型 | `lib/newbee/environment/cascade.ex` |
| Calibration 校准投影 | `lib/newbee/environment/calibration.ex` |
| Jit.tce_hot_needs / tce_deopt_decision | `lib/newbee/environment/jit.ex` |

零旁路原则：一切热度数据来自既有事件流投影，不新增观测通道。

### 17.5 v2 深化（序贯检验与变化点检测）

- **SPRT 化 deopt**（Wald 1945；Wald-Wolfowitz 最优性）：工具坏判定从单次后验尾部检验
  升级为 Bernoulli 序贯概率比检验——两类错误 alpha/beta 约束下期望样本数最小。
- **CUSUM 化漂移检测**（Page 1954）：频率漂移用单侧累积和 S=max(0,S+x-omega)，
  ARL 由阈值 h 直接控制，对缓漂比快照检验敏感一个数量级。
- **非对称置信区间**（omega-UCB 启发）：benefit 端 LCB、cost 端 UCB，排序分
  = LCB(benefit) - UCB(C)，贴合预算语义。
- **校准闭环实证**：蒙特卡洛验证 V1-V4（`tce_monte_carlo_test.exs`）证明
  SPRT 误判率符合理论、CUSUM 平稳零误报、LCB 决策零噪声误选、校准误差单调下降。
- 实现落位：`sequential.ex` / `pattern_stats.ex (net_asym, beta_quantile)` /
  `tce_monte_carlo_test.exs`。BOCPD（run-length 后验）留作 v3 方向。

### 17.6 v2.1（第三轮：场景界定、统计校准、端到端验证）

- **应用场景界定**（docs/design-jit-economics/R1-scenarios.md）：TCE 在
  周期进化/手动 /evolve 中是过滤器+排序器；worker need 只排序不过滤；
  prompt_injection 安全域不参与。
- **Token 归因收集器**（G1）：tool_start 无 token 字段、usage 在 LLM 层且无关联 ID——
  PatternStore.Collector 订阅 Bus 维护工具名游标，usage 归因给最近工具，批量 flush。
- **错误风暴即时触发**（G2）：60s 内 >=3 次 tool_error 即 debounce 进化，
  弥补 10min heartbeat 对坏工具持续烧钱响应太慢。
- **成功语义修正**（R3）：tool_start 只记频率不判成败（发起不等于成功）；
  tool_result 才是成功信号——权限拒绝等不污染 deopt 判据。
- **EB 收缩修正为 James-Stein 标准形式**（R4）：权重 w=var_i/(var_m+var_i)，
  收缩后方差同步折减并重参数化 Gamma。
- **SPRT 滚动重置**（R8）：一次判定不是终点，h0/h1 后重置证据继续监控；
  400 步生命周期仿真验证缓慢劣化->检出->修复->恢复清白全链路。
- **编译成本实证校准**（R6）：10k 事件基准下 compile_cost 从 5000 校准到 100_000
  （46 候选 42 噪声 -> 5 热点 0 噪声）；移除 estimate_tokens=500 捏造默认。
- **SPRT alpha 校准测量**（2000 trials）：健康误判率实测 2.5% < 标称 5%，
  Wald 保守不等式成立。
