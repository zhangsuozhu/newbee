# 前缀缓存命中优化：实施方案（供实现模型执行）

> 状态：审计完成，方案定稿，待实施。
> 基线：`main` @ `4c885b6`（工作区干净）。相关既有提交：`36ab076`（缓存优化第一版）、`4c885b6`（decode_body 修复）。
> 目标读者：另一个编程模型。请按 §8 顺序实施，每阶段跑通测试再进下一阶段。

## 1. 审计结论：为什么当前改动不成立

### 1.1 先厘清"省 token"的含义

- **KV/前缀缓存命中不减少 API 返回的 `prompt_tokens`**。它只是把其中一部分记为
  `cache_read_tokens`（DeepSeek 侧 `prompt_cache_hit_tokens`），降低计费单价与首 token 延迟。
- 真正减少"每次请求携带的 token 数"的是**压缩本身**（用短摘要替换长历史）。这是两件独立的事。
- 当前改动（`36ab076`）把压缩摘要的输入从"有界抽取物"（`build_extract`，上限 `@extract_budget` 9,000 字符，
  `archive.ex`）扩大为"压缩前完整物化视图的回放"（接近 80% 上下文窗口）。**只有缓存命中时这才便宜；
  一旦未命中，摘要请求比旧实现贵一个数量级。** 所以命中正确性是生死线，不是锦上添花。

### 1.2 三个硬伤（当前实现的命中前提不成立）

1. **摘要请求缺 `tools`。** 正常路由请求由 `Newbee.LLM.Client.stream_chat/4` 发出，
   body 带 `tools: Newbee.Codec.tools()`（`client.ex:122-128`）；而摘要走
   `Client.complete/3`（`client.ex:235-245`），body **不带 tools**。DeepSeek/OpenRouter 系
   provider 的 prompt 缓存键包含工具定义，`system+messages` 相同但 tools 有差异 → 前缀失配，
   从头计费。对照 deepseek-harness：`summarizer.ts:157-158` 显式回放 `tools`（`...input.tools`）。
2. **摘要请求的"前缀"不等于上一路由请求的前缀。**
   - Loop 在 init / compact 后会在 `state.messages` 头部插入 J-Space 恢复提醒
     （`loop.ex:231-237` 与 `1340-1342`），它**进入下一次路由请求**，但 `36ab076` 的摘要路径
     （`archive.ex:793-797` `llm_digest_replay`）自己拼 `[system base] ++ warm_prefix`，
     不含该提醒 → 有 J-Space 的会话首条消息后就失配。
   - 摘要指令放尾部 user 消息这个做法本身是对的（deepseek-harness 同款），但前缀必须
     **逐字节等于上次真实发出的请求**，不能由 Archive 重新"组装一个很像的"。
3. **非流式 `complete` 读不到顶层 usage。** `client.ex:272` 只读 `choice["usage"]`；
   OpenAI 兼容协议 usage 常在响应**顶层**。摘要调用（complete）的命中与否因此无法观测，
   且命中指标（`cache_read_tokens`）被吞。流式路径已在 SSE 帧上处理（`client.ex:595-598`），无此问题。

### 1.3 与 deepseek-harness 的差距对照

| 维度 | deepseek-harness | newbee 当前 | 本方案后 |
|---|---|---|---|
| 请求头持久化 | session 事件流持久化 epoch header（system+tools+config） | 无 | 新增 last-routed-request 快照（§4） |
| 摘要请求构造 | 精确重放 header + 被归档区间消息 + 尾部指令（`region.ts:498-514`） | 重放 system + 整个压缩前视图，缺 tools | 重放上次真实请求全部消息 + 尾部指令，带 tools |
| 命中资格判定 | 路由 header 即事实 | 无判定，一律回放 | route(model+base_url) 一致才回放，否则回退有界抽取 |
| 崩溃语义 | compaction/start + end 显式事件 | 段文件+账本两段提交（可用） | 保持现状 |
| 命中验证 | 形状单测 + 真实 API E2E（`request-cache.e2e.ts`，断言 cacheReadTokens>0） | 仅形状断言 | 形状单测 +（可选）真实 E2E |
| 压缩后视图体积 | 摘要 maxTokens 默认 8192（输出侧） | digest ≤700 字、汇总预算 ~1400 tokens（**更小，保留**） | 保持现状 |
| 摘要成本模型 | 只回放被归档区间，保留尾不重复计费 | 回放整份快照，保留尾全价（§5.4 护栏暴露） | 一致（护栏版） |

结论：deepseek-harness 的命中设计是"可重建请求"不变量 + 请求头持久化；newbee 应做到同级，
同时保留自己更小的压缩视图（这是 newbee 在"后续 prompt 体积"上的优势，不要为了学它而照搬 8192 摘要）。

## 2. 目标不变量（实现后必须成立的命题）

- **I1**：每次**标准路由请求**（`stream_chat`，非测试注入函数）发出前，其
  `messages` 快照 + `tools` + `model/base_url` 原子持久化到会话制品目录。
- **I2**：压缩摘要请求（LLM 调用）== 上一次路由请求的**严格前缀**（逐字节相同，
  不截断、不降维、不重排）++ 一条尾部 user 压缩指令。这是命中前提。
- **I3**：不具备命中资格时（无快照 / model 或 base_url 与快照不一致 / client 是注入函数），
  摘要走**有界抽取路径**（现状 `build_extract`），绝不伪装命中。
- **I4**：transcript 永不覆写、Archive 账本仍是压缩唯一事实（现有纪律不动）。
- **I5**：`complete/3` 不回归——无 tools 参数时请求体与现状逐字节一致。

## 3. 架构决策

- **引入 "last-routed-request" 快照**，由 Loop 在发出请求前写入，Archive 只消费，不猜测。
- **摘要回放整个快照**（system + 全部消息 + tools）+ 尾部指令，而非只回放被归档区间：
  newbee 没有 deepseek-harness 的 seq 对齐节点投影，做"区间精确切片"需要引入
  transcript↔envelope 索引映射（易错）。回放整条快照同样是"上次请求的严格前缀 + 指令"，
  命中前提等价；但注意保留尾不在缓存中（它是上次输出，非输入前缀），会全价计费——
  见 §5.4 保留尾护栏。
  若命中前提失效，I3 回退抽取路径，不付这笔钱。
- **重复压缩自动成立**：第二次压缩时，快照里的 messages 已经是
  `[system] ++ [汇总摘要] ++ [近期原文]`（上次真实发送的样子），摘要请求回放它即天然
  包含"旧摘要前缀"——不需要 view(session) 参与。
- **route 一致性 = 资格判定**：`switch_model` / `set_context_window` 之后首次压缩会因
  model 或 base_url 不匹配走抽取路径；下一次路由请求刷新快照后恢复命中。
- **可观测**：修复 complete 的顶层 usage 读取；摘要命中/未命中进 debug.log。

## 4. 数据模型：last-routed-request 快照

位置：`<session.dir>/last-routed-request.json`（session.dir = `~/.newbee/session-artifacts/<id>/`）。
写入方式：tmp + rename 原子写（同 Archive 段文件纪律）。无会话（`session: false`）不写。

```json
{
  "version": 1,
  "base_url": "https://openrouter.ai/api/v1",
  "model": "deepseek/deepseek-v4-flash-0731",
  "tools": [ { "type": "function", "function": { "name": "run_elixir", "...": "..." } } ],
  "messages": [ { "role": "system", "content": "<完整 system prompt>" }, { "role": "user", "content": "..." } ],
  "message_count": 23,
  "sha256": "<messages 与 tools 序列化后的 sha256，供校验>",
  "recorded_at": "2026-08-26T12:34:56Z"
}
```

- `messages` 是**即将发送的**消息数组（含 system 头与 J-Space 提醒等全部头部注入），
  与 `stream_chat` body 的 `messages` 完全同一对象树。
- `tools` 直接存 `Newbee.Codec.tools()`（静态 list of maps，可 JSON 编码）。
- 快照只被**标准 LLM client**（`%Newbee.LLM.Client{}`）写；注入函数 client 不写 → 永不假装命中。

## 5. 逐文件改动规格

### 5.1 新增 `lib/newbee/request_envelope.ex`

```elixir
defmodule Newbee.RequestEnvelope do
  @moduledoc """
  上一次路由请求的可缓存前缀快照（§prefix-cache 方案 I1）。
  由 Agent.Loop 在 stream_chat 前写入；Archive 摘要路径消费（I2/I3）。
  """

  @file_name "last-routed-request.json"
  @version 1

  @doc "记录即将发出的标准路由请求。非 LLM client 或 session 为 nil 时 no-op。"
  def record(%Newbee.Session{} = session, %Newbee.LLM.Client{} = client, messages, tools \\ Newbee.Codec.tools())
  def record(_session, _client, _messages, _tools), do: :ok

  @doc "读取快照；缺失/损坏/版本不符返回 nil（视为无快照，走抽取路径）。"
  def load(%Newbee.Session{} = session) :: map | nil

  @doc "命中资格：快照存在且 model/base_url 与当前 client 一致。"
  def hit_eligible?(env, %Newbee.LLM.Client{} = client) when is_map(env)
end
```

实现要点：
- `record`：JSON 编码 `%{"version" => @version, "base_url" => ..., "model" => ...,
  "tools" => tools, "messages" => messages, "message_count" => length(messages),
  "sha256" => ..., "recorded_at" => ...}`；`File.write!(tmp); File.rename!(tmp, path)`。
  写失败静默降级（rescue → :ok），不影响主循环。
- `load`：`File.read` + `Jason.decode`；版本不符/字段缺失（`messages` 非 list、
  `tools` 非 list、`base_url`/`model` 非 binary）返回 nil。
- `hit_eligible?`：`env["base_url"] == client.base_url and env["model"] == client.model`。
- 禁止在 `record` 中修改 messages（必须是逐字节一致的引用；测试将用 `==` 断言）。

### 5.2 `lib/newbee/llm/client.ex`

1. **complete 支持 tools**（I5 兼容）：
   - `complete(%__MODULE__{} = client, messages, opts \\ [])` 不变；
   - 在 body 组装后：
     ```elixir
     body =
       case Keyword.get(opts, :tools) do
         tools when is_list(tools) and tools != [] -> Map.put(body, :tools, tools)
         _ -> body
       end
     ```
   - 无 `:tools` 时请求体与现状一致（既有 clienttest 必须全绿）。
2. **修复顶层 usage**（`client.ex:265-276` 区域）：
   ```elixir
   {:ok, %{"choices" => [choice | _]} = body_map} ->
     usage = normalize_usage(choice["usage"] || body_map["usage"] || %{})
   ```
   注意 `resp.body` 已被 decode_body 解码为 map；兼容 binary 分支（decode_body 已保证 map）。
3. （可选，低风险）在 complete 的 DebugLog 里带上 `opts[:task]`，摘要调用传
   `task: "compaction"`，便于日志分桶。不改任何返回形状。

### 5.3 `lib/newbee/agent/loop.ex`

1. **请求前记录快照**：`run_turn` 中 `call_client(state.client_fun, state.messages, ...)`
   调用点（现 `loop.ex:584`）之前插入：
   ```elixir
   Newbee.RequestEnvelope.record(state.session, state.client, state.messages)
   ```
   - 无会话 / 注入 client（`%{}` 等）→ record no-op，全部既有 kernel 测试不受影响。
   - 注意：这里是**请求前**记录，快照即本次请求内容；摘要请求的回放对象就是它。
2. **compact_state（session 分支）**：删除 `base: base["content"]` 传参，改为：
   ```elixir
   opts = [
     retain: retain_target,
     client: state.client,
     envelope: Newbee.RequestEnvelope.load(state.session),
     trigger: if(retain_target <= 64, do: "manual", else: "auto")
   ]
   ```
   - `base = hd(state.messages)` 局部变量保留（压缩后重建 `[base | view]` 仍需要）。
   - `session: nil` 分支不动。
3. 无其他改动。`switch_model`/`set_context_window` 不需改：快照在下一次请求时刷新；
   model 变化期间 Archive 的资格判定自动失配 → 抽取路径（I3）。

### 5.4 `lib/newbee/archive.ex`

1. **compact/2**：删除 `warm_prefix = view(session)`（现 `archive.ex:74`）；
   opts 增加 `:envelope`。摘要调用改为：
   ```elixir
   digest_segment(session, seg_id, client, envelope: Keyword.get(opts, :envelope))
   ```
2. **digest_segment 签名改为 opts**：
   `def digest_segment(%Session{} = session, seg_id, client, opts \\ [])`
   （替代现有 5 参位置签名；同步更新 `archive_test.exs:241/245` 与 backfill 调用点。）
   - 命中分支：
     ```elixir
     case Keyword.get(opts, :envelope) do
       env when is_map(env) ->
         if Newbee.RequestEnvelope.hit_eligible?(env, client) do
           prefix = env["messages"]
           tools = env["tools"] || []
           request = prefix ++ [%{"role" => "user", "content" => @compaction_instruction}]
           Newbee.DebugLog.log(:compact, "digest seg=#{seg_id} hit-path replay messages=#{length(request)} tools=#{length(tools)}")
           complete_and_record(session, seg_id, client, request, tools)
         else
           extract_digest(session, seg_id, client)
         end
       _ ->
         extract_digest(session, seg_id, client)
     end
     ```
   - `extract_digest/3` = 现状的 `build_extract` + `llm_digest` + `record_digest`
     （`archive.ex:191-197` 路径原样保留，零改动）。
   - `complete_and_record`：`Client.complete(client, request, tools: tools, extra: %{max_tokens: 500})`，
     成功走 `record_digest`，失败返回 `{:error, ...}`（不写事件，语义同现状）。
   - **删除** `llm_digest_replay/4`（base/warm_prefix 版）及任何 replay 截断逻辑。
   - **保留尾护栏**：若 `retain` 对应的保留尾估算 token 数超过
     `compaction_retain × context_window × 0.5`（即超过 8% 窗口），
     摘要请求仍回放整份快照，但 DebugLog 标记 `large-retain-tail`，
     提示用户考虑调低 `compaction_threshold` 或改用 `retainTokens` 上限。
     这暴露了"保留尾全价"的成本，不隐藏。
   - 已知可接受缺口：快照回放覆盖的是"上次请求时的全部消息"；极端小会话 + 手动
     `retain ≤ 64` 下，若归档区间包含快照之后新增的消息，摘要看不到这几条。
     因为这些消息几乎必然落在保留尾部（I2 不要求摘要覆盖保留区），作为可接受折衷记录在案。
     （可选强化，非本阶段：envelope 存 `message_count` 与 `head_extra`，new_cut 超出
     `message_count - head_extra` 时降级抽取路径。）
3. **backfill** 维持抽取路径（历史段没有可证明的暖前缀），签名随 digest_segment 改为 opts 调用。
4. `@compaction_instruction`、`record_digest`、账本/段文件纪律全部不动。

### 5.5 `lib/newbee/environment/projection.ex`

不改。`built_at: nil`（`36ab076` 已做）保证同会话 system prompt 逐字稳定；缓存友好的
成分排序（`render/1`，`projection.ex:236-247`）维持现状。

### 5.6 兼容性约束

- `Newbee.LLM.Client.complete/3` 无 tools 时请求体不变（I5）。
- `Newbee.Archive.compact/2` 返回值形状不变；`digest_segment` 是内部/测试 API，允许改签名但
  必须同步所有调用点。
- 无会话路径（`session: false` 测试/ephemeral）行为完全不变。
- 所有既有测试（archive 18 条、kernelcompact、clienttest、全量）必须保持绿。

## 6. 测试规格

### 6.1 新增 `test/newbee/request_envelope_test.exs`

1. record → load 往返：字段齐全，messages 深比较 `==` 原始传入值。
2. 原子性：写坏路径（session.dir 不存在时先 mkdir_p；rename 失败不残留半文件——可用临时
   目录权限模拟，或只断言 tmp 文件不残留）。
3. load 容错：缺失 → nil；损坏 JSON → nil；版本 99 → nil；缺 `messages` 字段 → nil。
4. hit_eligible?：model/base_url 一致 → true；任一不一致 → false。
5. record no-op：`record(session, %{}, ...)`、`record(nil, client, ...)` 均 `:ok` 且不落文件。

### 6.2 重写 `test/newbee/archive_test.exs` 前缀缓存相关测试

（现 ~293 行起两条测试替换为下列；capture_client 需升级为同时捕获 opts，至少捕获 `:tools`）

1. **命中形状**：构造 envelope（`messages` = 模拟上次请求：system + 6 轮对话 + tools 列表），
   `compact(s, retain: 4, client: capture_client, envelope: env)`。
   断言收到的请求 == `env["messages"] ++ [尾部指令]`（`==` 深比较，不截断）；
   断言指令为最后一条 user 消息且含"压缩引擎""不要调用工具"；断言 `tools == env["tools"]`。
2. **无快照 → 抽取路径**：不传 envelope，断言请求是单 user 消息且内容含 `build_extract`
   产物特征（如"任务目标"字段或段消息正文片段），消息数 1。
3. **model 不一致 → 抽取路径**：envelope.model = "A"，client model = "B"（用可插桩 client），
   断言走抽取路径（同上）。
4. **二次压缩回放旧摘要**：第一次 compact（带 envelope1）→ 构造"压缩后真实发送过的请求"
   envelope2（messages = [system, 汇总消息, 近期原文]），第二次 compact 带 envelope2，
   断言摘要请求前缀 == envelope2["messages"]（含汇总消息，即旧摘要前缀）。
5. **digest 失败不写事件**：命中路径 client 返回 `{:error, ...}`，断言 `digests(s)` 无该段。

### 6.3 `test/newbee/llm/clienttest_test.exs` 补充

1. `complete(client, msgs, tools: Codec.tools())` → 请求 body（Req.Test 插桩捕获）含 tools；
   无 `:tools` → body 无 tools 键（与现状一致）。
2. 顶层 usage：响应 `%{"choices" => [%{"message" => ...}], "usage" => %{"prompt_tokens" => 100, "prompt_cache_hit_tokens" => 64}}`
   → 返回 usage 的 `cache_read_tokens == 64`。
3. choice 内 usage 仍优先（现状行为不回归）。

### 6.4 既有测试必须保持绿（回归清单）

`mix test`（含 archive_test 18 条、kernelcompact_test、clienttest、web 等全量）。
特别注意：`kernelcompact_test.exs` 用 `client: %{}` + scripted client_fun —— record 必须 no-op，
否则测试环境出现文件副作用。

### 6.5 可选：真实 API E2E（第三阶段，需 key）

仿 `deepseek-harness/packages/core/agent-loop/tests/request-cache.e2e.ts`：
- tag `:cache_e2e`，无 `DEEPSEEK_API_KEY` 环境变量时 skip；
- 用真实 DeepSeek（或 OpenRouter deepseek 模型）跑一个会话到压缩触发，
  断言压缩摘要调用与压缩后首个路由请求的 usage 中 `cache_read_tokens > 0`；
- 不在 CI 常跑（费用+网络）。可放 `test/newbee/cache_e2e_test.exs` 并在 CI 排除。

## 7. 验收指标

1. **正确性**：§6.1/6.2/6.3 全部通过；`mix format` 干净；`mix test` 全绿；无编译警告。
2. **命中可观测**：真实运行中 debug.log 出现 `digest seg=seg-0001 hit-path ...`；
   TUI 状态栏 `缓存 X%` 在压缩摘要后应显著上升（对比修复前）。
3. **成本不回归**：命中前提成立时，被归档区间（head 段）为 cache_read（打折），
   保留尾为全价 prompt（它是上次输出，不在输入前缀中）；前提不成立（模型切换等）
   自动走 ≤9K 字符抽取路径，最坏成本与优化前相同。
4. **行为不回归**：会话恢复、history:// 检索、digest 失败重试、J-Space 恢复提醒等既有
   archive/loop 测试全绿。

## 8. 实施顺序（每阶段一个可提交的 checkpoint）

- **P1 数据层**：新增 `request_envelope.ex` + `request_envelope_test.exs`。跑测试。
- **P2 客户端**：`client.ex` complete tools 参数 + 顶层 usage 修复 + clienttest 补充。跑测试。
- **P3 接线**：`loop.ex` 请求前 record + compact_state 传 envelope。跑 kernel 相关测试。
- **P4 摘要路径**：`archive.ex` 按 §5.4 改造 + archive_test 重写（§6.2）。跑 archive + 全量。
- **P5 收尾**：`mix format`、全量 `mix test`、检查 debug.log 样例。（可选）§6.5 E2E。

## 9. 明确不做（范围外）

- 不改压缩阈值/保留策略默认值（0.8/0.16，与 deepseek-harness 相同）。
- 不引入逐节点 token 计量器（bytes/3 估算维持；列为后续优化）。
- 不做 provider 固定路由（OpenRouter 路由漂移会吞缓存命中，列为后续优化，本方案以
  route 一致性检测 + 降级兜底）。
- 不照搬 deepseek-harness 的 8192 maxTokens 摘要（保留 newbee 的 ≤700 字 digest +
  1400 token 汇总预算——这是 newbee 在压缩后 prompt 体积上的优势）。
- 不改 Archive 崩溃语义/账本纪律（现状可接受）。
