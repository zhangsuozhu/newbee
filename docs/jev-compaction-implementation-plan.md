# Jev 可回退上下文压缩：设计与函数级实施方案

状态：第一版已在本 worktree 实现并通过离线测试。真实 Jev 网络评测未执行。

## 0. 交接信息与执行约束

- newbee 基线：`c459380b409732ef4e981b6a4589e36639499758`。
- 分支：`design/jev-compaction-1789898354`。
- worktree：`/home/alanx/data/git/newbee/.newbee/worktrees/jev-compaction-design-1789898354`。
- 本文位置：`docs/jev-compaction-implementation-plan.md`。
- 参考项目：<https://github.com/tamaratran/fast-jev-compaction>，固定参考提交 `e3f262a7f4d42bd8dd32ced30d26176f7cb545b0`。
- 用户目标：利用 Jev 的速度和价格优势，在摘要前筛除低价值工具上下文；没有 Jev 时继续使用原来的压缩方式。
- 当前交付仅含设计文档。实施者从本 worktree 开始，按第 11 节逐步实现；不要将“设计写好了”当成“功能已经可用”。
- 主工作区存在未提交的 browser Jev 等文件；它们不在本基线内，不复制、不覆盖、不作为编译依赖。本功能暂不抽取浏览器与压缩共用的 Jev 框架。
- 不修改原始 transcript，不替换 Archive，不新增模型可调用工具，不新增 npm/TypeScript 运行时，不修改主模型 provider 路由。
- 不顺便修改 Archive 的用户意图截取策略、归档摘要算法、前端配置页面或全局记忆系统。
- 实施提交、推送、PR、合并须由后续用户单独授权；本文不授权远端操作。

## 1. 已核实的现状与设计结论

### 1.1 newbee 的真实接入点

以下函数均已在本基线源码中核对，行号仅供定位，实施以函数名为准。

| 文件 / 函数 | 当前行为 | 本方案处理 |
| --- | --- | --- |
| `lib/newbee/agent/loop.ex`：`init/1` | `Session.seal_pending_tools/1` 后，用 `Archive.view/1 |> repair_history/1` 恢复 | 加载配置；仅启用 Jev 模式时重放有效的本地裁剪记录 |
| 同上：`maybe_auto_compact/2` | 用 ContextBudget 检查压力，然后进入原压缩重试 | 在原压缩之前最多尝试一次 Jev |
| 同上：`compact_until_budget/5` | 最多三次压缩；hard limit 下仍不足则拒绝主模型请求 | 保留原逻辑；不得在递归内部再次调用 Jev |
| 同上：`compact_state/2` | 有 session 时走 Archive；失败时保留 session，使用 ephemeral 回退 | 保留；成功改变视图后废弃旧 Jev 投影 |
| 同上：`handle_call(:compact, ...)` | 手动 `/compact` 调用 `compact_state(state, 8)` | 保留原路径，完全不请求 Jev |
| 同上：`push_msg/2` | 写入 transcript；私有 usage 字段分离 | 不改变，不往 transcript 追加裁剪后的伪消息 |
| 同上：`repair_history/1` | 规范 ID、修复工具配对、过滤 UI 审计行 | 继续使用；但不能把它当作容忍错误裁剪的工具 |
| `lib/newbee/agent/context_budget.ex`：`assess/2`、`estimate/1` | 估算 JSON 消息体，计入固定开销和输出预留 | 最终采纳 Jev 结果时使用同一预算口径 |
| `lib/newbee/archive.ex`：`compact/2`、`view/1` | 追加归档、生成 digest、装配近期视图 | 不改变这些公开 API 和日志格式 |
| `lib/newbee/spill.ex`：`store/2`、`id_for/1` | 内容寻址落盘，支持 `spill://` 回读 | 为被裁剪调用提供可验证的原文恢复地址 |
| `lib/newbee/llm/responses_continuation.ex`：`plan_with_reason/3` | 检查输入前缀 hash，不匹配时使用完整请求 | 增加回归测试，通常无需改该模块 |
| `lib/newbee/host.ex`：`call/4` | 本机 apply 或主节点 RPC | Jev 凭证只在 Host HTTP 执行路径中读取 |
| `lib/newbee/llm/config.ex`：`load/0` | 加载 model.json | 新配置模块读取顶层 `compaction`，不新增 LLM role |

注意：当前 Archive 用户意图是每条最多 160 字符、最多 12 条，并非无限量全文保留。本功能不顺便修这个问题。Jev 成功路径要求所有已有非工具文本原样保留；退回 Archive 后仍是现有 Archive 语义。

### 1.2 从参考项目借鉴什么

参考源码链接：

- [分离 call/result 打分与决策](https://github.com/tamaratran/fast-jev-compaction/blob/e3f262a7f4d42bd8dd32ced30d26176f7cb545b0/src/compact.ts)
- [候选收集与评分状态压缩](https://github.com/tamaratran/fast-jev-compaction/blob/e3f262a7f4d42bd8dd32ced30d26176f7cb545b0/src/state.ts)
- [TypeSafe 请求及响应协议](https://github.com/tamaratran/fast-jev-compaction/blob/e3f262a7f4d42bd8dd32ced30d26176f7cb545b0/src/request.ts)
- [Claude hook 的不足量回退](https://github.com/tamaratran/fast-jev-compaction/blob/e3f262a7f4d42bd8dd32ced30d26176f7cb545b0/hooks/fast-jev.ts)

采用三种动作：`keep`、`drop_result`、`drop_call`；保留近期完整工具事务；失败回退；记录实际收益。

不照搬以下细节：

1. 参考实现评分时完全省略结果正文。newbee 给评分器提供有限的结果证据，不只提供长度和成功状态。
2. 参考实现提示重新执行工具。newbee 必须给原文地址；`run_elixir` 可能有副作用、临时绑定或不可重现输出。
3. 参考实现用字符减少比例作为回退条件。newbee 使用当前主模型请求的 ContextBudget，包含恢复目录的开销。
4. 参考实现对批次 `Promise.all`。第一版 newbee 串行、最多两批，统一截止时间，避免并发与取消复杂度失控。

“快、便宜”是用户选择此方向的理由。本次没有调用真实 Jev，没有得到延迟、价格或任务质量实测；本文参数是起始配置，不是性能结论。

## 2. 范围、行为与不可破坏的约束

### 2.1 唯一控制流

```text
自动压缩触发
  -> legacy 模式 / 无 session / 无 key / 冷却中：原 compact_until_budget
  -> Jev 模式：收集候选 -> 有界评分 -> 纯函数投影 -> 预算验收
       -> 可采纳：原文 spill 验证 -> 原子保存决策 -> 替换内存视图
       -> 跳过或失败：使用“本次尝试前的 state”进入原 compact_until_budget
       -> 用户中断：停止本次请求；不再请求 Jev 或摘要模型

手动 /compact
  -> 原 compact_state(state, 8)，不请求 Jev

重启恢复
  -> 原 Archive.view + repair_history
  -> legacy 模式：直接使用原视图
  -> Jev 模式：本地校验并重放裁剪记录，不请求网络
```

### 2.2 必须维持的 invariants

- I1：压缩操作前后 transcript 字节不变；后续用户/助手消息仍正常追加。
- I2：候选结果未经全部校验、预算验收、原文持久化和决策持久化，不得替换 `state.messages`。
- I3：任意失败不得把 `state.session` 改成 nil；原来的摘要回退仍能继续落盘。
- I4：不得单独留下 tool result；不得留下因本次删除而缺失 result 的 call。保留原消息顺序和一对多工具事务结构。
- I5：system、user、assistant 非工具内容逐字保留；不得由 Jev 生成摘要替换它们。
- I6：删除工具调用前必须持有调用及结果的完整恢复包；不依赖重执行。
- I7：第一条消息、最近 N 条消息涉及的完整事务、未完成事务、结果未知/错误事务、不能安全解析的事务不可裁剪。
- I8：评分只产生固定枚举动作；模型返回的自由文本不能变成工具、命令、路径、配置或 system 指令。
- I9：本次 Jev 失败时原压缩入口只调用一次；原入口内部原有最多三次重试不变。
- I10：主模型请求前仍执行已有 hard-limit 检查。Jev 声称成功不能绕过这个检查。
- I11：关闭 Jev 不要求删除任何历史或恢复文件。使用旧版本代码打开同一会话仍能从原 transcript 和 Archive 恢复。
- I12：使用 Jev 后上下文前缀可能变化；不能强制继续使用旧 `previous_response_id`。

### 2.3 回退的准确含义

| 情况 | 动作 | 是否增加服务故障计数 |
| --- | --- | --- |
| `mode=legacy` | 不读投影、不请求 Jev，原逻辑 | 否 |
| mode=jev 但未配置 key | 可重放以前有效的本地投影；下一次压缩走原逻辑 | 否 |
| session=false | 完全沿用原 ephemeral 压缩 | 否 |
| 无候选、候选不够、状态/请求预算不足 | 原逻辑 | 否 |
| Jev 超时、断网、429/5xx、401/403、异常响应 | 原逻辑 | 是；认证错误直接进入冷却 |
| 结果合法但没有达到预算采纳条件 | 原逻辑 | 否；清除连续服务失败计数 |
| 配对、原文验证或磁盘提交失败 | 原逻辑，当前试验不生效 | 否；记录本地失败 |
| 连续失败进入冷却 | 冷却期间不请求 Jev，原逻辑 | 不重复累加 |
| 用户主动中断 | 停止，不发摘要请求 | 否 |
| 手动 `/compact` | 原逻辑 | 否 |

第一次失败就回退，不等连续失败阈值。冷却只是避免后续反复等待。

配置在 Loop 初始化时读取。第一版不做运行中热切换：将 mode 改成 legacy 后，停止并重新打开该会话，忽略投影并恢复传统视图；数据不会丢。服务掉线则无需重启，会自动回退。不要承诺“配置文件一改，当前正在运行的 Loop 立刻重建”。

## 3. 配置与默认值

在现有 model.json 顶层增加可选字段；省略整个字段时行为必须与基线一致：

```json
{
  "compaction": {
    "mode": "jev",
    "jev": {
      "apiKeyEnv": "TYPESAFE_API_KEY",
      "model": "jev-latest",
      "keepThreshold": 0.5,
      "preserveRecentMessages": 8,
      "maxCandidates": 64,
      "maxStateTokens": 20000,
      "maxRequestTokens": 28000,
      "maxBatches": 2,
      "requestTimeoutMs": 3000,
      "totalTimeoutMs": 6000,
      "failureThreshold": 3,
      "cooldownMs": 60000,
      "truncateHeadChars": 200,
      "truncateTailChars": 200,
      "minReductionRatio": 0.10
    }
  }
}
```

- mode 默认 `legacy`；允许值只有 `legacy`、`jev`。显式配置 mode=jev 后使用 Jev，无需第二个 feature flag。
- key 存在不能自动启用外发。API key 只读取上述环境变量，配置中不接受明文 apiKey；返回的公开配置不含密钥。
- 生产 endpoint 固定为 `https://api.typesafe.ai/v1/systemone`，第一版不提供任意 URL 配置。测试通过 transport 注入，不改全局 endpoint。
- `jev-latest` 是参考项目默认，不保证永远存在；可配置 model，失效即回退。不要将 Jev 伪装成 OpenAI chat role。
- 数值必须是有限数值，比例范围 [0,1]；超范围、负数、字符串类型不悄悄转换。非法可选字段使本次配置回落 legacy，并输出一个不含原值的原因码。
- 整数范围：recent 2..64，candidates 1..128，state 1000..25000，request 2000..30000，batches 1..4，request timeout 100..10000ms，total timeout 100..20000ms，failure threshold 1..10，cooldown 1000..600000ms，head/tail 0..1000。
- 跨字段要求：maxStateTokens < maxRequestTokens；requestTimeoutMs <= totalTimeoutMs。保留第一条消息不受 recent 参数影响。
- 每次评分使用绝对 monotonic deadline，不通过批次数乘出无限等待。总超时限制评分工作；持久化磁盘 IO 另有对象大小上限，不声称磁盘卡死也能严格 6 秒完成。
- 阈值与默认值要在一个模块内定义，测试和文档不另写一套默认值。

## 4. 文件与模块清单

第一版新增 7 个内部模块，除 Compaction facade 外不扩大现有模块职责；不注册为工具或插件。

| 文件 / 模块 | 职责 |
| --- | --- |
| `lib/newbee/compaction.ex` / `Newbee.Compaction` | 阶段编排、成功验收、恢复入口、结果协议 |
| `lib/newbee/compaction/config.ex` / `.Config` | 配置解析、默认值、纯函数校验 |
| `lib/newbee/compaction/policy.ex` / `.Policy` | 候选收集、pin、评分 state、分批、三态决策 |
| `lib/newbee/compaction/jev_client.ex` / `.JevClient` | Host 内凭证、TypeSafe HTTP、答案校验、有界执行 |
| `lib/newbee/compaction/projection.ex` / `.Projection` | 工具事务裁剪、恢复目录、结构验收 |
| `lib/newbee/compaction/store.ex` / `.Store` | 原文恢复包、决策投影原子持久化与重放校验 |
| `lib/newbee/compaction/breaker.ex` / `.Breaker` | 纯会话级失败计数与冷却状态 |

修改文件只需要：`lib/newbee/agent/loop.ex`、`lib/newbee/application.ex`，以及对应测试。配置读取复用 `LLM.Config.load/0`，不必修改其路由逻辑。新增配置示例写本文或独立示例文件，不编辑真实用户 model.json。

实现中如发现必须修改 Reader、Archive 或 Responses：先说明哪个现有契约无法满足，写失败测试，再做最小修改；不要默认重构这些模块。

## 5. 数据契约（先定义，再写实现）

以下 `%{}` 是内部 Elixir map；落盘 JSON 使用字符串 key。不要对模型输出或磁盘数据执行 `String.to_atom/1`。

### 5.1 Loop 新字段

```elixir
compaction_config: nil,
jev_breaker: %{failures: 0, retry_at_ms: nil},
jev_projection: nil
```

- config 是校验后的非敏感配置；不得包含 API key。
- breaker 的时间来自 monotonic clock，只保存在内存，不落盘、不跨会话共享。
- projection 是 Store 已接受的 manifest，含记录及确定性生成的恢复目录。nil 表示当前无裁剪覆盖。
- 使用 Loop opts `:compaction_config` 注入测试配置；生产默认从 Config.load/1 加载。
- 使用 `:compaction_deps` 注入 fake scorer、clock、store；不把测试回调写进配置或持久化文件。

### 5.2 候选 Call

```elixir
%{
  id: "t0",
  tool_call_id: "call_abc",
  name: "run_elixir",
  input: %{"code" => "...", "title" => "..."},
  call_index: 4,
  result_index: 5,
  call: original_tool_call_map,
  result: original_tool_message,
  source_sha: "...",
  pinned: false,
  pin_reason: nil,
  result_bytes: 9000,
  evidence: %{status: :ok, head: "...", tail: "..."}
}
```

`id` 只是本次评分短 ID，不用于跨重启匹配。持久化身份为 tool_call_id + source_sha + Archive cut。

fingerprint 输入固定为 `{call_map, result["role"], result["tool_call_id"], result["content"]}`，用 `:erlang.term_to_binary(term, [:deterministic])` 后 SHA-256 hex。忽略 transcript 添加的时间戳等非协议元数据，但 call map 和结果正文不做 trim、不规范化空白。运行时编码规则变化造成 hash 不匹配时保守回退，不尝试“修复”旧 hash。

### 5.3 Decision / Record

评分结果（纯内存）：

```elixir
%{id: "t0", keep_call: 0.8, keep_result: 0.1, action: :drop_result}
```

持久化 Record（不保存远端自由文本）：

```json
{
  "tool_call_id": "call_abc",
  "source_sha": "hex",
  "action": "drop_result",
  "recovery_id": "64-char-spill-sha256",
  "head_chars": 200,
  "tail_chars": 200,
  "replacement": "原文头尾 + 固定恢复提示"
}
```

- drop_call 不需要 replacement/head_chars/tail_chars；drop_result 保存当次片段长度，replacement 必须由本地 Projection 生成。重放时用恢复包、记录的长度和 version=1 固定模板重新生成并比对 replacement，不能把任意磁盘字符串当成合法替代内容。payload_sha 用于检测损坏，不是身份认证。
- keep 不落盘。已裁剪的事务不再次评分，避免对截短结果反复做有损判断。
- 第一次压缩最多 maxCandidates 条；当前 cut 下累计 records 最大 128 条。达到上限后本轮跳过 Jev，走 Archive，清掉旧投影。
- recovery_id 指向 JSON 包：`{"tool_call": original_call, "tool_result": original_result}`。包保存当前待裁剪消息中的完整值，不执行包内代码。
- 该包若原来已经含 spill 句柄，必须保留句柄；不假称包里包含该上游 spill 的全部原文。

### 5.4 Facade 返回值

```elixir
{:ok, %{messages: projected, projection: manifest, stats: stats}}
{:skip, reason, stats}
{:error, reason, stats}
{:interrupted, stats}
```

reason 为固定枚举或 `{fixed_atom, status_integer}`，不能带 HTTP 正文、key、用户内容或任意异常 inspect。

stats 至少含 strategy、outcome、reason、candidates、pinned、kept、results_dropped、calls_dropped、request_count、estimated_scoring_tokens、elapsed_ms、budget_before、budget_after、saved_tokens_est、reduction_ratio、state_fit_stage。主模型 usage 和 Jev usage 分开，不把估算当账单。

## 6. 函数级实施规格

本节的新函数签名是实施目标，不声称已经存在。public 指 Elixir 模块内可跨模块调用，不代表新增 Agent Tool。

### 6.1 `Newbee.Compaction.Config`

1. `load(opts \\ []) :: config`
   - opts 可注入 `:raw_config`；没有时读取 `Newbee.LLM.Config.load/0`。
   - 只提取顶层 compaction，调用 resolve/1；加载异常时返回 legacy 配置和固定 warning 原因。
   - 不读取或返回 API key。
2. `resolve(raw) :: {:ok, config} | {:error, reason}`
   - 纯函数，按第 3 节校验、填默认值、执行跨字段约束。
   - raw 缺省/nil 得到 legacy；未知 mode 和非法配置返回 error。未知 key 可忽略，但 apiKey 明文项应拒绝。
3. `legacy/0 :: config`
   - 唯一默认配置来源；供 load 的异常回退使用。

第一版不在每个请求边界重读配置文件，避免对热切换作隐含承诺。

### 6.2 `Newbee.Compaction.Policy`

1. `collect_calls(messages, config, source, projection) :: {:ok, calls} | {:skip, reason}`
   - 消费 Loop 已 repair 的 Chat Completions 内部消息格式，不消费参考项目的 toolUses 格式。
   - assistant 的 `tool_calls` 按 `id` 与 `role=tool/tool_call_id` 配对；同一 assistant 多个 call 独立建候选。
   - 重复 ID、缺 call、缺 result、非二进制 content、无法解析 arguments、异常角色顺序：pin 涉及事务；身份歧义覆盖全列表时整轮 skip。
   - 若 assistant 带 provider reasoning/signature/encrypted/reasoning_content 等耦合字段，pin 整个 assistant 工具组；第一版不裁剪其内部结构。
   - pin 第一条消息及最近 preserveRecentMessages 条涉及的 call/result 两端，即使另一端在较早位置。
   - pin 结果正文含 outcome_unknown、现有中断占位文案、明确错误标志/`✗` 的事务。此规则保守，可能多保留；不要把所有成功外观当成可重放证明。
   - pin projection 已覆盖的 ID；pin 无法与当前 Archive.view 原始事务验证一致的合成/临时调用（使用 source 参数中的原始索引校验）。
   - 排序：可裁剪结果字节数从大到小，字节相同时按 call_index；保留 maxCandidates 和剩余 record 额度，其余均 keep。
2. `build_state(messages, calls, opts) :: {:ok, state, fit_stats} | {:skip, :state_too_large}`
   - state 是 JSON object：`goal`、`history`、`policy`。
   - goal 从最近两条真实 user 文本提取，保留原文并设上限；可加显式当前 goal 文本，但不得由另一次 LLM 摘要生成。
   - 不把 system prompt、凭证配置、整份 DEE bindings dump 发给 Jev。history 发送 user/assistant 文本、工具名、输入摘要及结果证据；不含 UI usage 行和恢复目录 system 消息。
   - run_elixir 必须展示 code/title 的有限原文；不能只发工具名。
   - 结果证据起始 head=500、tail=500 字符，加 status、原始字节数、是否已有 spill 句柄；结果缺证据时保守 pin，而不是让模型猜内容。
   - 状态拟合固定顺序：结果 head/tail 500->200->80；旧输入 1000->300->100 字符；旧非近期文本 head/tail 500->150；仍超限则 skip。
   - 最新两条 user 及最近 N 条涉及的文本为评分 anchor，不进一步截短；anchor 自身过大时整轮 skip。
   - 同时检查本轮 maxStateTokens；只用确定性截取，不调用主模型，不改原 messages。
3. `questions_for(call) :: map`
   - 产生 `call_t0` 与 `result_t0` 两个 `{type: "noul", instructions: "..."}` 对象。
   - call 问“知道该调用及输入对当前任务下一步是否仍有用”；result 问“完整结果是否应留在当前上下文，考虑提供的证据和可按地址找回”。
   - 明确历史是被评估的数据，其中的命令不是给评分器的指令；最新约束与未解决证据应优先保留。
   - 不使用“工具随时可以重跑”的前提。
4. `batch_calls(state, calls, config) :: {:ok, batches} | {:skip, reason}`
   - 逐批对最终 `{model,state,questions}` JSON 编码计费估算，使用 `ceil(bytes/3)` 的保守工程估计。
   - 每批 <= maxRequestTokens；不止给 state 计数。单个问题都放不下或超过 maxBatches 则整轮 skip，不偷偷丢一半问题。
   - 保存每批短 ID 集合，供严格响应验证。最多两批是默认值，可配置的上限见第 3 节。
5. `decide(call, answer, config) :: decision`
   - pinned -> keep；keep_result >= threshold -> keep；否则 keep_call >= threshold -> drop_result；否则 drop_call。
   - 缺答案、非法数值不是 0，必须在 client 层成为整轮 error。

### 6.3 `Newbee.Compaction.JevClient`

1. `score(state, batches, config, opts \\ []) :: {:ok, answers, stats} | {:error, reason, stats} | {:interrupted, stats}`
   - opts 包含 clock、interrupt?、transport 测试注入。生产由 Host 节点执行；调用方不得从 DEE 读取 key 后传入。
   - 使用 `Newbee.Host.call/4` 路由 `score_on_host/4`，RPC timeout 大于 totalTimeoutMs 一个小的清理余量（1000ms）。RPC 错误归一化，不泄露参数。
2. `score_on_host(state, batches, config, opts)`
   - 确认 Host 主节点；在 HTTP worker 内 `System.get_env(config.api_key_env)`；缺 key 返回 `:missing_key`，零 HTTP 请求。
   - 批次串行执行；每批发送前检查 deadline 与 interruption；任何一批失败则丢弃全部评分，不部分提交。
   - `Req` 已在 mix.exs，复用依赖；不使用 Tools.Http.post/3，其固定超时不适合这里的截止时间。
   - request 选项至少包括 `retry: false`、`redirect: false`、`decode_body: false`、受 remaining_ms 限制的 connect/pool/receive timeout。
   - 响应最多 256KiB；采用 Req 支持的流式累计上限，或经过验证的有界 response adapter；不能先完整读入无限 body 再称为有界。
3. `build_request(state, questions, config) :: map`
   - 纯函数只返回 endpoint、method、JSON body；不含 Authorization。
   - 请求体固定：`{"model":"jev-latest","state":{...},"questions":{"call_t0":{"type":"noul","instructions":"..."},"result_t0":{...}}}`。
   - HTTP worker 最后添加 `authorization: Bearer <key>`，不返回或记录最终 request headers。
4. `parse_response(status, body, expected_ids) :: {:ok, answers} | {:error, reason}`
   - 要求 2xx、合法 JSON object、answers object；每个预期键必须为 `{"noul": number}`，有限且 0<=n<=1，bool/string/null 均拒绝。
   - 任意缺键使整轮失败；额外键忽略；不得创建 atoms。usage 如果有，只保存明确的数值字段，不依赖其存在。
   - HTTP 错误只返回状态码，不把 body 拼入异常。认证错误、限流、服务端失败分别标记。
5. 私有 `run_bounded/3`、`await_result/4`、`watch_owner/3`
   - Application 增加 `{Task.Supervisor, name: Newbee.Compaction.Tasks}`，不复用 collaboration 的 supervisor。
   - 用 async_nolink 启动一个 scoring worker，避免 worker 异常杀死 Loop。worker 内捕获常规异常并归一化。
   - 单独 watchdog 监视 caller 和 worker，收到 caller DOWN 或到达绝对 deadline 时终止 worker；worker 完成则 watchdog 退出。watchdog 本身由同一 supervisor 管理。
   - caller 以 <=50ms 间隔轮询 task/interrupt?，中断时 shutdown worker，并清理 monitor/task 消息。
   - 必须测 caller 死亡、worker 崩溃、超时后无遗留 worker/watchdog。不要只写 Task.yield 后返回却忘记 shutdown。
   - 本模块不写 session、Spill 或投影；迟到响应无法修改上下文。

### 6.4 `Newbee.Compaction.Projection`

1. `apply(messages, records, opts \\ []) :: {:ok, projected, stats} | {:error, reason}`
   - 纯函数。先验证每个 record 的 tool_call_id 唯一且 fingerprint 匹配，再生成新列表。
   - drop_result：保留 call，只替换对应 tool message 的 content；其他字段保持。
   - drop_call：从 assistant.tool_calls 删除该 call，并删除对应整个 tool result。assistant 还有文本或其他 call 时保留；只有确认没有其他语义字段时才删除空 assistant。
   - 不删除 user 消息、不改文本、不重排消息、不修改 base system。
   - 未触及消息按原 map 返回；不要顺便清理或标准化它们。
2. `replacement(result_text, recovery_id, config) :: binary`
   - 用 String.slice 做 Unicode 安全的 head/tail；原文较短且新内容不更小时取消该 drop_result，转为 keep。
   - 固定提示包含 `Newbee.read("spill://<id>")`，说明是原调用与结果的恢复包；提示“先读取原文，不要为恢复历史而重新执行”。
   - 正文只含原文片段和本地固定模板，不含 Jev 自由文本。
3. `catalog(records) :: message | nil`
   - drop_call 已把调用移走，必须新增一个精简 system 恢复目录：每个被移走 call 的 ID 和恢复包地址；不拷贝工具输出。
   - 按 tool_call_id 排序，以记录集合 hash 标识目录；插入到连续 leading system 消息之后、首条非 system 之前，不插到工具事务中间。
   - drop_result 自带指针，无须在目录重复列出。
   - 目录也是上下文成本，必须计入最终预算。record 数量上限保证目录有界。
4. `strip_catalog(messages, old_projection) :: {:ok, messages} | {:error, :ambiguous_catalog}`
   - 只移除由旧 manifest 确定性生成、完全相等且唯一的一条目录消息。nil projection 不移除任何东西。
   - 不按用户可伪造的文本前缀删消息；若出现重复完全相等的目录，保守失败。
   - 新试验失败时保留旧 state，不把 strip 后的临时列表写回。
5. `validate(before, after, changed_records) :: :ok | {:error, reason}`
   - 检查文本不变、相对顺序、call/result 完整配对、近期 pin、只有声明的内容发生变化。
   - Loop 可额外要求 `repair_history(projected) == projected`；若 repair 新增占位或丢消息，拒绝本次投影。
   - 不把修复后的“看起来合法”列表当作成功，避免静默掩盖裁剪 bug。

### 6.5 `Newbee.Compaction.Store`

1. `source_index(session) :: {:ok, %{cut: cut, calls: index}} | {:error, reason}`
   - 从 Archive.current_cut/1 取 upto，未归档时 cut=0；从 Archive.view/1 构建原始事务索引。
   - 不从已裁剪 state 构建“原文”索引。重复 ID/不完整事务不允许生成可裁剪记录。
2. `prepare_recovery(calls) :: {:ok, recoveries} | {:error, reason}`
   - 在发送评分前为候选预计算完整 JSON 恢复包和大小；单包最大 1MiB，超过即 pin，再构造评分问题。评分后只选出实际改变的事务持久化；不得因为包过大再调用第二轮 Jev。
   - 纯构造阶段先用 Spill.id_for/1 计算 ID，供预算试算；不要在预算不够时盲目写所有原文。
3. `persist_recoveries(recoveries) :: :ok | {:error, reason}`
   - 逐包调用 Spill.store/2；必须 `partial == false` 且返回 ID 与预计算一致，并验证可读取和内容 hash。
   - 任一失败则整个 Jev 计划失败。已写的孤立 spill 是允许的可回收对象，不改变 transcript，不删除可能被其他路径引用的对象。
4. `load(session, source) :: {:ok, manifest} | :none | {:error, reason}`
   - 文件路径仅由 session.dir 派生：`jev-projection.json`。
   - envelope：version=1、session_id、archive_cut、records、payload_sha；payload_sha 对确定性编码的前四字段计算。
   - 文件最大 1MiB，records<=128；检查 schema、session ID、cut、动作枚举、重复 ID、fingerprint、spill 存在/完整/hash。
   - 一条无效则全部投影不采用，返回原 Archive 视图；不部分加载，不调用网络“修复”。
5. `commit(session, source, records) :: {:ok, manifest} | {:error, reason}`
   - 合并旧 records 与本轮新 records；同一 ID 不重复，不对旧记录二次评分；必须再次验证当前 source cut 和所有 fingerprint。
   - 同目录临时文件写入 -> close/sync -> rename 原子替换。失败清理本次临时文件，不覆盖旧文件。
   - 决策文件是可丢弃的投影缓存，不是事实日志；不改 compactions.jsonl 格式。
6. `clear(session) :: :ok | {:error, reason}`
   - 原子写空记录 envelope（cut 使用当前值）；不删除原文 spill 和 transcript。
   - 用于手动或原路径压缩实际改变视图之后。若归档 cut 已前进，即使 clear 失败旧投影也因 cut 不匹配失效。
   - 如 Archive 内部失败而 ephemeral 回退成功、cut 未前进，clear 失败时记录警告；重启仍可能重放旧的有效投影，不承诺持久化了 ephemeral 摘要。这与原 ephemeral 回退不落归档的边界一致。

### 6.6 `Newbee.Compaction.Breaker`

纯函数，无 ETS、进程、持久化、网络：

- `new/0` -> `%{failures: 0, retry_at_ms: nil}`。
- `allow?(breaker, now_ms)` -> boolean；nil 或 now>=retry_at 时允许。
- `success(breaker)` -> new；只要模型回答合法，即使压缩收益不足，也算服务成功。
- `failure(breaker, reason, now_ms, config)` -> 更新计数；达到阈值时 retry_at=now+cooldown；401/403 立即进入冷却。
- `skip(breaker)` -> 原值；配置关闭、无候选、磁盘失败等不算模型服务失败。
- 冷却到期后的首轮重新允许；若失败再进入冷却。模型成功才清零，不靠时间自动把失败次数清零。

### 6.7 `Newbee.Compaction` facade

1. `restore(session, base_messages, config) :: {messages, projection, restore_stats}`
   - base_messages 为 Loop 原有 Archive.view |> repair_history 结果，不包括新鲜 base system prompt。
   - legacy 或无 session：原样返回 base_messages、nil。
   - jev：source_index -> Store.load -> Projection.apply -> validate；失败返回 base_messages、nil。
   - 恢复不读 key、不访问 Jev，即使服务消失也能恢复已接受的本地投影。
2. `try_prune(messages, context, config, deps \\ %{}) :: facade_result`
   - context 含 session、projection、budget_opts、interrupt?；budget_opts 与 Loop.compaction_budget/1 的参数一致。
   - 顺序固定：interrupt 检查 -> source 索引 -> strip 旧目录 -> collect/pin -> 恢复包大小预检/pin -> 构造评分 state -> 分批 -> score -> decide -> 预计算恢复 ID/替换文本 -> apply 本轮新动作 -> 附加“累计 records”的目录 -> validate -> budget 验收 -> persist_recoveries -> Store.commit -> 返回新视图。
   - 本轮 apply 只作用新 records，因为输入已应用旧 records；启动 restore 则把累计 records 一次性应用到原 Archive 视图。两条路径不可混用。
   - 预算验收：after.status 必须 `:ok`，且 `(before.request_tokens-after.request_tokens)/before.request_tokens >= minReductionRatio`。始终计算含 base system、旧摘要、恢复目录、输出预留的完整候选列表。
   - 即使少量节省也能离开 hard limit，只要未满足上述验收，仍走原压缩；第一版保持单一验收规则，之后按评测调参数。
   - 未通过验收不提交磁盘、不修改 messages；返回 skip/insufficient_reduction。
   - 提交前再检查用户 interruption。提交后视图已有效，可返回 accepted，Loop 仍要在主模型请求前检查中断，不能因此发出新请求。
   - source 可能与合成消息不同，无法验证原文的 call 必须 pin。不要为方便而跳过 source 校验。
3. `invalidate(session)` -> Store.clear；对 nil 返回 :ok。
4. `legacy_reason(result)` -> 固定 reason，供 Loop 事件和 breaker 分类；不泄露上下文正文。

## 7. Loop 的逐函数修改说明

### 7.1 `defstruct` 与 `init/1`

增加第 5.1 节字段和 `compaction_deps: %{}` 测试注入字段。在恢复 prior_messages 前解析配置和初始化 breaker。现有 `seal_pending_tools` 顺序保持，先取得原 `Archive.view |> repair_history`，再调用 Compaction.restore/3。

restore 后继续原有 base system 拼接、J-Space 会话登记、bindings 恢复。不得持久化上次 base system 替代当前 prompt。旧会话没有投影文件时逐字兼容。不要修改 Session.messages/1、Archive.view/1 的全局语义，前端历史继续读取原始记录。

### 7.2 `maybe_auto_compact/2`

保留 auto_compact=false、budget=:ok、消息太少时的原有分支。只替换原 true 分支：

```text
retain = 原公式
if mode != jev or session == nil or breaker 不允许:
    原 compact_until_budget(state, retain, step, budget, 3)
else:
    result = try_jev_compaction(state)
    accepted -> {:ok, 新 state}
    interrupted -> 进入 turn 原有中断收尾，不请求摘要
    skipped/failed -> 旧 messages、旧 session + 新 breaker 状态
                      进入原 compact_until_budget(..., 3)
```

- 新增私有 `try_jev_compaction/1`：组装 context/deps、调用 facade、更新 breaker、发事件；常规异常归一化，可选优化不得炸 Loop。
- 成功更新 messages、jev_projection；不发假的 `{:compacted, archived_count}`，因为 Jev 没有推进归档切点。
- 失败只保留 breaker 和诊断信息，丢弃本次临时投影。
- 新增私有 `compaction_budget_opts/1` 提取当前 `compaction_budget/1` 的参数构造；后者调用 ContextBudget.assess/2。soft/hard/output_reserve 数值不变。
- 本基线唯一调用点是 `run_turn_unpaused/2`。增加 `{:interrupted, state}` 后，调整其预算检查 case 的外层控制流：该分支 emit `{:interrupted, nil}` 并直接返回 `{{:interrupted, nil}, state}`，不能继续解构 `{state, overflow}` 后落入发送逻辑。成功与 overflow 两分支保持现有处理；使用 `Newbee.LLM.Client.interrupted?(state.client)`（以及当前 colony pause）作为 interrupt?，不清除中断标志。

### 7.3 `compact_until_budget/5`

算法不改；递归内部不请求 Jev。保留原三次尝试、hard overflow 拒绝 provider、compaction_pressure 事件。attempts_left 不与 Jev 重试额度混用。

### 7.4 `compact_state/2`

采用最小包装，避免重写 Archive 错误处理：

1. 原有两条 compact_state/2 定义体移到私有 `legacy_compact_state/2`；原 rescue 中递归调用也改名，session 回填逻辑保持。
2. 新 compact_state/2 调用 legacy_compact_state/2。
3. count>0：调用 Compaction.invalidate(original_session)，新 state 的 jev_projection=nil；保留现有 J-Space reminder 与 repair_history。
4. count=0：保留旧投影和 messages。
5. Store.clear 失败只记录固定告警，不覆盖原压缩结果、不丢 session、不重新摘要。Archive cut 校验负责阻止旧投影在新切点重放。

### 7.5 `handle_call(:compact, ...)`

保持 `compact_state(state, 8)`、`{:ok, count}` 返回值，不请求 Jev。手动命令用于强制原压缩，不能宣称能撤销所有历史摘要；原文仍可回读。

### 7.6 `push_msg/2`、`repair_history/1` 与发送边界

push_msg 不改，synthetic catalog 不写 transcript。repair_history 不改，只能用于检测投影是否已经合法，不能用修复后的输出掩盖 bug。

RequestEnvelope 必须仍保存真正发送的主模型请求，禁止保存 Jev scoring request。ResponsesContinuation 已检查前缀，裁剪后应自然返回 full；添加前缀变化测试，不增加强制 continue 捷径。

预算只是工程估算；保留既有主模型请求前 hard-limit 检查，不宣称 tokenizer 级精确。

## 8. 生命周期、崩溃与关闭示例

### 8.1 两轮成功与重启

```text
原 Archive 视图有 A、B、C
第一轮：A -> drop_result，保存原文 hash/spill
第二轮：A 已处理并 pin；B -> drop_call
持久化累计 A+B，目录列出 B
重启：原 Archive 视图 -> 校验 A+B -> 一次性应用 A+B
```

禁止第二次对 A 的替代结果评分；禁止重启时拿裁剪后的视图当原文再次应用。新追加消息不在 records 中，自然保留。

### 8.2 服务消失与主动关闭

- 运行中服务消失：旧有效投影保留；下次压缩失败后走 Archive。
- Archive 从原 transcript 归档，不能从替代结果生成摘要；cut 前进，旧投影失效。
- mode=jev 但无服务/无 key 的重启：可本地重放有效投影，无网络依赖；后续压缩用原路径。
- mode=legacy 后重新打开会话：忽略投影，使用原 Archive 视图；不用删文件或修 key。
- 旧版本代码忽略未知投影文件，照常读取原日志。第一版不提供运行中配置热切换。

### 8.3 崩溃矩阵

| 时点 | 重启结果 |
| --- | --- |
| 评分中 | 使用旧投影，无新持久化状态 |
| spill 部分完成，manifest 未提交 | 孤立 spill 不影响旧视图 |
| manifest 临时文件未 rename | 忽略临时文件 |
| manifest 已 rename，内存未更新 | 重放新投影 |
| Archive cut 已前进，旧 manifest 未 clear | cut 不匹配，忽略旧投影 |
| manifest 损坏或 spill 丢失 | 整体忽略投影，原 Archive 视图 |

不新增全局垃圾回收任务；不要删除可能仍被其他消息引用的 spill。

## 9. 观测与质量验证

新增 `{:jev_compaction, stats}` 事件，通过现有 emit/2 和 DebugLog 记录，第一版不改前端。

- outcome 使用 accepted/skipped/fallback/interrupted/restore_ignored 等固定枚举。
- 禁止日志包含 key、Authorization、HTTP 正文、评分 state、工具输出或任意原始异常对象。
- request_count、elapsed_ms、每批重复 state 的估算总量都要记录。不能只记一批 stateTokens 假装是总成本。
- 现有 `{:compacted, n}` 的 n 仍指归档消息，不混用。
- 无配置和冷却跳过不刷完整堆栈。
- provider 未提供 usage 时标为估算；无价格数据时不编造费用。默认值不是已测出的性能数据。

真实评估是独立步骤，默认测试只使用 fake scorer：

1. 同一主模型、会话输入和工具返回，比较 legacy 与 jev。
2. 至少覆盖重复文件读取、末尾关键报错、已变化文件的旧结果、不可重放命令输出、长 user 约束、持久变量相关 run_elixir。
3. 记录评分延迟 p50/p95、主模型输入与费用、历史回读次数、任务完成/约束遵守、额外工具执行次数。
4. 关键约束遗漏、错误重执行、原文无法恢复不能被压缩率抵消。
5. scripted demo 和 fake 单测不算真实质量证明；未测则明确标记。
6. 调低保留阈值、提高上限、修改默认 mode，须由真实评估支持，第一版不自动做。

## 10. 测试矩阵

新增纯模块测试放 root 分区 `test/newbee/compaction_*_test.exs`，集成测试放 `test/newbee/dee/`，确保现有 mix test.fast 自动包含。

### 10.1 `compaction_config_test.exs`

- 缺配置 legacy；显式 jev 默认值正确；非法类型/比例/跨字段冲突不崩 init。
- key 存在不自动启用；config/日志/序列化 state 不含测试 key。

### 10.2 `compaction_policy_test.exs`

- 多 call assistant、跨 recent 边界、第一消息、未完成事务保护。
- 重复 ID、坏 arguments、多模态 content、reasoning/signature、未知/错误结果保留。
- run_elixir 输入含 code/title；证据含尾部错误，不只取头部。
- 已裁剪记录不二次评分；候选排序和上限确定；累计 record 上限。
- 拟合不改原文；最新 user anchors 不丢；不足返回 skip。
- 每批 state 计入预算；问题放不下或批次数超限整轮跳过。
- threshold 边界；缺答案不能变成 0。

### 10.3 `compaction_jev_client_test.exs`

- fake transport 断言 endpoint/method/schema；key 只在 worker headers。
- 合法答案；坏 JSON、缺键、noul string/bool/null/越界均整轮失败。
- 401/403/429/500、连接失败、超时、超大 body；日志无正文/key。
- 第一批成功、第二批失败，不返回部分可提交结果。
- retry=false；总 deadline 不逐批重置。
- 中断、caller death、worker crash 后 worker/watchdog 消失，无迟到持久化。
- 使用可控 fake transport/clock，不用真实长 sleep，不访问公网。

### 10.4 `compaction_projection_test.exs`

- 输入 fixture 不变；所有非工具文本完全相等。
- drop_result 只改对应 content，短结果不增肥。
- drop_call 保留同 assistant 的正文与其他 call；无 orphan。
- 目录地址正确、位置合法、累计不重复；不误删其他 system。
- Unicode 片段有效；目录开销入预算。
- repair_history 前后相同；故意 orphan 必须拒绝，不能补占位后通过。

### 10.5 `compaction_store_test.exs`

- transcript 二进制不变；恢复包等于原 call/result。
- partial/write error/hash mismatch/包过大不裁剪。
- 两轮累计 + 重启一致；追加消息保留。
- 坏文件、版本、session/cut/hash 错、重复 ID、spill 缺失整体回原视图。
- tmp 写失败不覆盖旧 manifest；rename 后重启可恢复。
- legacy 忽略有效 manifest；启用仅重放匹配 cut/source 的记录。
- fake Archive digest 收到原始结果，不能收到 Jev 替代文本。
- 两个 session 不共享投影/breaker。临时目录及 GlobalStore override 隔离。

### 10.6 `compaction_breaker_test.exs`

首次失败立即回退；第三次冷却；冷却内零请求；到期允许；成功清零；401/403 立即冷却；本地失败不增加服务计数。用注入时间测试。

### 10.7 `test/newbee/dee/kerneljevcompact_test.exs`

沿用现有 kernelcompact_test.exs 的 session/evaluator fixture；不要用 :sys.replace_state 构造与生产初始化不一致的捷径。

| 编号 | 场景 | 核心断言 |
| --- | --- | --- |
| L1 | 默认配置 | legacy 行为一致，Jev=0 |
| L2 | Jev 成功足量 | 主模型收到投影，摘要=0，transcript 不变 |
| L3 | 无 key/超时/限流/坏响应 | 原压缩执行，session 保留，继续落盘 |
| L4 | 收益不足 | 旧 messages 回退，新 manifest 未提交 |
| L5 | 两路仍 hard limit | 不调用主模型 |
| L6 | 手动 /compact | Jev=0，返回格式不变 |
| L7 | session=false | 原 ephemeral，无投影文件 |
| L8 | 连续失败冷却 | 后续无需等 Jev，到期再试 |
| L9 | 成功后重启 | 无 Jev 请求，恢复相同投影，正常追加 |
| L10 | 关闭后重启 | 原 Archive 视图，Jev=0 |
| L11 | Archive 故障回退 | 不丢 session |
| L12 | Jev 阶段中断 | 不再请求 Jev/摘要/主模型 |
| L13 | 旧投影 + 新尝试失败 | 不被临时 strip/apply 破坏 |
| L14 | RequestEnvelope | 只记录真实主模型请求 |

### 10.8 现有回归

必须通过 `test/newbee/dee/kernelcompact_test.exs`、`test/newbee/archive_test.exs`、`test/newbee/agent/context_budget_test.exs`、`test/newbee/llm/responses_test.exs` 和 `test/newbee/request_envelope_test.exs`。本基线没有独立 responses_continuation_test.exs，前缀变化回归加入 responses_test.exs。

`test/newbee/llm/cache_hit_e2e_test.exs` 是现有缓存端到端测试入口；先检查其运行条件，真实网络测试不得混入默认离线验收。用 RequestEnvelope 的离线测试证明 warm-prefix 摘要快照没有被 Jev 请求覆盖。

## 11. 分阶段任务单

每阶段报告函数改动、测试命令/结果、未解决失败。前一阶段不通过不继续叠功能。

### P0 基线

确认第 0 节 worktree/branch，读真实函数，若基线后续变化更新锚点。运行现有 kernelcompact、Archive、ContextBudget 测试，记录结果。依赖缺失只在本 worktree 准备；如用依赖 symlink 必须核对绝对路径，不照抄错误相对层级。不带入主工作区未提交文件。

### P1 纯策略

实现 Config、Breaker、Policy、Projection 及不变量测试。不碰 Loop、不联网、不持久化。通过配对、原文本、拟合、阈值测试。

### P2 Host HTTP

实现 JevClient 和专用 Task.Supervisor；fake transport 测 schema、deadline、取消、清理。完成条件是无泄密、无遗留任务、无自动重试。

### P3 持久化

实现 Store、facade restore/3；临时 Session/Spill 测两轮投影、重启、失效和崩溃。transcript 不变、原文可恢复、坏记录回原视图。

### P4 Loop

实现 try_prune/4，再按第 7 节接入。legacy helper 本体不改算法。L1-L14 通过，手动、自动回退与 hard limit 保持正确。

### P5 验证交付

在实施 worktree 执行，globs 以实际新增文件为准：

```sh
mix compile --warnings-as-errors
MIX_ENV=test mix compile --warnings-as-errors
mix test test/newbee/compaction_*_test.exs test/newbee/dee/kerneljevcompact_test.exs test/newbee/dee/kernelcompact_test.exs test/newbee/archive_test.exs test/newbee/agent/context_budget_test.exs test/newbee/llm/responses_test.exs test/newbee/request_envelope_test.exs --warnings-as-errors --seed 1
mix format --check-formatted lib/newbee/compaction.ex lib/newbee/compaction/*.ex lib/newbee/agent/loop.ex lib/newbee/application.ex test/newbee/compaction_*_test.exs test/newbee/dee/kerneljevcompact_test.exs
mix test.fast
git diff --check
```

只在新改动/新失败需要时重复检查。既有或依赖失败单列，不掩盖本次新增失败。更新本文状态、实际文件、验收结果。

真实 Jev 评测单列，显式启用、限样本与请求数；未执行就写未验证。默认测试不读取真实 TYPESAFE_API_KEY，不提交私有会话 fixtures。

## 12. 不允许擅自简化的部分

- fallback 不只捕获 HTTP exception；无 key、坏响应、预算不足、原文/磁盘失败全部覆盖。
- 不遗漏重启投影；不把裁剪消息写回 transcript。
- 不删除非工具文本换压缩率。
- 不用 repair_history 掩盖配对错误。
- 不省略 drop_call 恢复目录；不生成尚不存在的 history segment 地址。
- 不跳过 hash，不对截短结果二次评分。
- 不每批重置 totalTimeout，不默默自动重试 Jev。
- 不引入无限并发，不将 Jev 放进主模型默认 role。
- 不把单测通过写成模型效果保证。
- API 失效不能阻止用户继续任务。
- 不改真实用户配置/环境、其他 worktree 或远端仓库。

## 13. 可直接交给实施模型的任务说明

> 请在 `/home/alanx/data/git/newbee/.newbee/worktrees/jev-compaction-design-1789898354` 内，按 `docs/jev-compaction-implementation-plan.md` 的 P0-P5 实现 Jev 可回退压缩。先核对基线与真实函数，再实施，不自行更换架构。保持默认 legacy、手动 /compact 原行为、服务失效自动回退、transcript 不变、原文可恢复、重启可重放、中断不继续请求。每阶段用 fake scorer/transport 验证后再进入下一阶段。不调用真实 Jev，不操作其他 worktree，不提交/推送/开 PR。完成后报告文件、关键函数、测试命令与结果、未验证项。源码与方案冲突时，用源码和失败测试说明后作最小修正，不省略难做的验收项。

## 14. 本设计验证记录

已直接核对基线 Loop、Archive、ContextBudget、Session、Spill、Host、LLM.Config 和测试入口；已核对参考固定提交的协议、动作和回退；未调用真实 TypeSafe API。

Req/Jason 是现有依赖。本次只新增设计文档，没有实现代码、没有运行功能测试或性能评测。文档交付检查包括 Git 状态、空白检查与现有文件/函数锚点校验。代码验证由 P0-P5 执行。

