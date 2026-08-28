# ContextQuality：上下文经验的实证质量裁判

> 落位调研报告 docs/research/REPORT.md §4。解决 newbee 自进化闭环的质量盲区。

## 问题

newbee 的 adapter 会把教训编译成沉睡规则/记忆注入上下文（认知 JIT）。但
**没有任何机制度量"这条经验注入后，同类任务变好还是变差"**。

调研发现这是全行业的空白，且有一个致命陷阱：

- **Blind Curator (arXiv:2607.07436)**：自进化 agent 用 LLM judge 决定技能退休，
  judge 的 false-pass 偏差超过 0.45 时退休机制**无声失效**——不是变噪，是停摆。
  → 我们的裁判**只用确定性信号**（测试/编译/edit 命中/无 tool_error），不用 LLM 自评。
- **More Skills Worse Agents (2605.24050)**：经验库膨胀使 pass rate 掉 21%。
  → 必须有退休机制，不能只做加法。
- **Agent Skills Can Be Harmful (2608.11888)**：差分归因定位致败经验。
  → 我们对比"注入时 outcome" vs "未注入时 outcome"（同一 release 的两侧）。

## 架构

```
事件流（Bus）
  ├─ prompt_injection{source: rule_id}  ── 某规则在本 turn 注入
  ├─ tool_error / final_check_low        ── 失败信号
  ├─ goal_done                           ── 成功信号
  └─ usage{tokens}                       ── token 成本
        │
        ▼
  ContextQuality.Collector（GenServer，订阅 Bus）
    按 session 追踪 turn 边界，关联注入集合 × outcome
        │  record(ledger, injected?, success, tokens)
        ▼
  ContextQuality（纯函数核）
    每个 release 维护双侧 Beta 后验：with_ctx / without_ctx
        │  verdict(ledger) → :harmful | :ok | :insufficient
        ▼
  retire_candidates → Coordinator 走 Change 生命周期降级
```

## 核心判据（调研落位，Blind Curator 防线）

**harmful 判定 = 双侧置信区间不重叠**：

```
UCB(with_ctx 成功率, 1-α) < LCB(without_ctx 成功率, α)   → :harmful
LCB(with_ctx, α) > UCB(without_ctx, 1-α)                 → :ok（有益）
否则                                                      → :insufficient
```

α=0.05（harmful 单侧），help α=0.15（ok 单侧，尽早标记好经验）。

### 为什么用区间不重叠而不是点估计 + 效应量 margin

蒙特卡洛实证（500 trials/场景，n=20/组）：

| 判据 | 中性 FPR | 说明 |
|---|---|---|
| prob_less > 0.9（裸后验） | **11%** | 小样本尾部误判，Blind Curator 陷阱 |
| + 效应量 margin 0.15 | 11% | 无效——误报恰是随机大效应量 |
| **CI 不重叠（采用）** | **0.8-1%** | 样本不足时区间自然变宽 → 自动 insufficient |

区间法的优雅之处：**样本不足自动退化为 insufficient**（区间宽→不重叠不成立），
无需单独的 min_samples 硬门槛，一个判据统一处理"不确定"和"有害"。

### 功效-保守权衡（500 trials，CI 判据）

| 场景 | harmful | ok | insuff | 评价 |
|---|---|---|---|---|
| 极有害(0.4v0.8, n=20) | 0.60 | 0 | 0.40 | 多数检出 |
| 有害(0.5v0.8, n=20) | 0.36 | 0 | 0.64 | 保守但方向正确 |
| 有害(0.5v0.8, n=40) | 0.70 | 0 | 0.30 | 样本足功效升 |
| 微有害(0.65v0.75, n=40) | 0.09 | 0.01 | 0.90 | 小效应谨慎 ✓ |
| **中性(0.7v0.7, n=20)** | **0.01** | 0.06 | 0.93 | **FPR≈1%** ✓ |
| 有益(0.8v0.5, n=20) | 0 | 0.70 | 0.30 | **零误杀** ✓ |

设计取向：**宁缺勿滥**——误退休一条好经验的代价（丢失有效教训）远高于
暂留一条坏经验（多花点 token）。这与 Blind Curator 论文的结论一致。

## outcome 的诚实性

- 只认确定性信号：`goal_done` 且无 `tool_error` = 成功；有 `tool_error` = 失败。
- `turn_end` 无 goal 信号且无错误 → **不记账**（成败未定，诚实缺测，宁缺毋滥）。
- 绝不用 LLM 自评分数作为退休依据（Blind Curator 防线）。

## Context Bloat 护栏

`bloat_regression?`：注入后 token > 基线 × 1.2 且成功率不升 → 额外退休理由。
直接回应调研 2608.11888 的"25.3% 效率回归源于上下文膨胀"。

## 与既有模块的关系

| 模块 | 度量维度 | ContextQuality 补充 |
|---|---|---|
| PatternStore/Jit | tool 成本侧（省 token、成功率 <0.5 deopt） | release 注入的**任务级**效果 |
| Fitness | release 使用的价签（token/延迟/成功率） | **反事实**（不用它时会怎样） |
| **ContextQuality** | — | **注入 vs 不注入的差分归因** |

复用 `PatternStats` 数值核（betai/log_gamma/分位数），零重造。

## 文件

- `lib/newbee/environment/context_quality.ex` — 纯函数核（Beta 后验 + CI 判据）
- `lib/newbee/environment/context_quality/collector.ex` — 事件流 Collector
- `test/newbee/environment/context_quality_test.exs` — 17 测试（含 3 统计回归锁定）
- `test/newbee/environment/context_quality_collector_test.exs` — 8 集成测试

## 后续（闭环最后一公里）

- [ ] Coordinator.deopt 接 retire_candidates（当前是建议清单，未自动执行）
- [ ] Projection 向模型暴露 price_tags（模型可自查"我注入的经验有用吗"）
- [ ] TUI `/quality` 命令展示质量价签
