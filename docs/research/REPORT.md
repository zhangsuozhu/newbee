# AI 编程工具护城河调研报告：从第一性原理到可落地功能

> 调研轮次：10 轮（arXiv 实证论文 40+ 篇，对照 newbee 现状源码）
> 方法：每轮结论标注可证伪证据；否定再否定后收敛

## 0. 第一性原理推导

**场景**：程序员给 AI 一个任务 → AI 用工具在环境里干活 → 产出代码。

不可约减的链条：

```
任务成功率 = f(模型能力, 上下文质量, 工具面, 环境反馈)
```

模型能力不可控（换模型即变）。工具面 newbee 已封顶 3 个（run_elixir/done/ask）。环境反馈 newbee 有 EventStore。剩下**上下文质量**是 harness 唯一能主动优化的杠杆，且它被论文反复证明是性能的主导变量：

| 证据 | 量化结论 |
|---|---|
| 2601.15300 | Qwen2.5-7B 在 40-50% 上下文长度处 F1 从 0.55 崩到 0.3（-45.5%），阈值效应非渐变 |
| 2605.12366 | Opus4.6/GPT5.4/Gemini3.1 在 800K token 后漏检危险行为多 2-30 倍 |
| 2307.03172 (Lost in the Middle) | 关键信息在上下文中部时检索准确率显著下降 |
| 2605.24050 | 技能库从 helpful 集扩到 202 个，pass rate 掉 21%，主因是选错技能(skill shadowing)而非上下文开销 |

**结论 1**：AI 编程工具最重要的特性是**上下文质量**——不是窗口大小，而是"窗口里装的东西是否让模型在关键任务上更准"。

## 1. 护城河方向：为什么选择"经验的实证质量进化"

上下文质量的子方向排除法：

| 候选方向 | 排除/选择理由 |
|---|---|
| 更长上下文 | 模型厂商军备竞赛，harness 无差异化 |
| RAG 检索优化 | 已饱和（SWE-Explore 证明 agentic 探索已超经典检索） |
| 技能库/记忆库扩容 | **反方向**：More Skills Worse Agents 证明扩容降性能 21% |
| **经验质量的实证度量与进化** | **选中**：每篇自进化论文(ACE/Evo-Harness/Continual Harness/Prime Agent)都在"存"经验，几乎无一在"度量经验是否真的有用" |

**关键空白（竞品未做）**：
- Prime Agent (2608.23552)：Continual Harness 存 prompts/memories/skills，**无注入前后效果对比**
- Evo-Harness (2608.15071)：context-to-harness 编译，**单 shot 噪声蒸馏，无质量门**
- ACE (2510.04618)：playbook 累积，**依赖增量更新防 collapse，但无因果归因**

## 2. 最锋利的失败模式（必须规避）

**Blind Curator (2607.07436)**：自进化 agent 用 LLM judge 决定技能退休，judge 的 false-pass 偏差超过 0.45 时，退休机制**无声失效**——不是变噪，是整个策展机制停摆。结论：质量度量必须用**确定性验证器**（测试通过/编译成功/diff 匹配），不能用 LLM 自评。

**Agent Skills Can Be Harmful (2608.11888)**：307 个技能致败案例归因——功能失败主因不是"明显不相关技能"，而是"看似相关技能让 agent 错误实现"；效率回归 62.6% 是 Excessive Procedure、25.3% 是 Context Bloat。方法：**差分归因**——对比"注入技能 run" vs "无技能/语义匹配 run"。

**STALE (2605.06527)**：记忆过期检测，最好模型仅 55.2% 准确率。经验会过期，必须有失效检测。

## 3. newbee 现状的精确盲区

源码实证：
- `PatternStore`（lib/newbee/environment/pattern_store.ex）：度量 tool 级 token 成本与成功率（成本侧）
- `Jit`（lib/newbee/environment/jit.ex）：热度剖析决定编译晋升，deopt 看成功率 < 0.5
- **缺失**：当 adapter 把一条教训编译成沉睡规则/记忆注入上下文后，**没有任何机制度量这条注入让后续任务变好还是变差**

这正是 Blind Curator 警告的场景：newbee 的自进化闭环（adapter→release→注入）目前没有质量侧裁判。

## 4. 功能设计：ContextQuality（上下文经验质量度量）

**一句话**：给 newbee 的自进化闭环装上"实证质量裁判"——每条被注入上下文的经验（规则/记忆/技能）都有基于确定性信号的 A/B 效果分，差的自动降级。

**核心机制（全部落在已有架构上）**：

1. **Outcome 信号采集**：复用 EventStore，任务级 outcome = 确定性验证器结果（测试通过数变化/编译成功/edit 锚点命中率/tool_error 率）。零 LLM judge。
2. **差分归因**：对每个活跃 release（规则/记忆），维护"注入时 outcome 分布" vs "未注入时 outcome 分布"（PatternStore 已有分桶基建，按 release_id 加维度）。
3. **退休门**：PatternStats 的 Beta 后验已存在；新增"经验效果"后验——P(注入后 outcome 优于基线) < 阈值且样本足够 → 标记 stale，走 Change 生命周期降级（deopt 已有路径）。
4. **Context Bloat 护栏**：每条注入记录 token 成本，效果分为负且成本为正 → 优先退休（直接回应 25.3% Context Bloat 回归）。

## 5. 验证方案（数据说话）

- **单元**：PatternStats 后验更新 + 退休判据的统计正确性（已有 pattern_stats 测试基建）
- **集成**：合成事件流——注入"好规则"（提升 outcome）与"坏规则"（降低 outcome），验证系统正确退休坏规则、保留好规则
- **基准对照**：模拟 Blind Curator 场景（有偏信号）验证确定性裁判不退休好规则
- **自跑**：在 newbee 自身开发中启用，收集真实 ReleaseObservation

## 6. 与现有工作的差异声明

| 系统 | 存经验 | 度量效果 | 确定性裁判 | 反事实归因 | 自动退休 |
|---|---|---|---|---|---|
| ACE | ✅ | ❌ | ❌ | ❌ | ❌ |
| Prime Agent | ✅ | ❌(仅token) | 部分 | ❌ | ❌ |
| Evo-Harness | ✅ | ❌ | ❌ | ❌ | ❌ |
| SkillTriage(论文) | — | ✅ | 手动 | ✅ | ❌(离线工具) |
| **newbee ContextQuality** | ✅(已有) | ✅ | ✅ | ✅ | ✅(走Change生命周期) |
