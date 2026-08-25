# 认知 JIT 的分级编译经济学（TCE）— 设计总纲 v1.0

> 10 轮设计-查证闭环收敛产物。证据链: 00-first-principles + r1..r10。
> 核心功能点: 把 newbee 的认知 JIT 从点估计启发式升级为
> 不确定性下的在线投资决策系统（Tiered Compilation Economics, TCE）。

## A. 数据结构: PatternStats (R3/R4/R7)

每个 pattern（{kind, key}）维护三组共轭后验:
- freq: Gamma(a,b) 出现频率后验，指数衰减 gamma
- succ: Beta(alpha,beta) 成功率后验
- save: 正态模型 单次节省 token 幅度后验
分桶: pattern x task_type [D16]；群体先验 EB 矩估计收缩 [D12]；
充分统计量持久化 evaluations/pattern_stats.jsonl 重启可恢复。

## B. 决策引擎 (R1/R5/R8)

编译判据:
    LCB(net) = E[lambda]*E[save] - kappa*sigma(net) - C(pattern复杂度) > 0 且 n>=min_samples
排序: LCB/C 降序进 adapter 预算队列 [D10][D11]
deopt 双通道序贯检验 [D17]:
  工具坏: P(p<p_min|alpha,beta)>0.95 且频率未降 -> deopt 到 L2 候选 release [D13]
  漂移: E[lambda] 相对快照跌落 > h sigma -> dormant 冷层级不降级
时间衰减 [D6]: 每 N 次观察乘 gamma，均值保持方差增大

## C. 运行时级联语义 (R6)

E[save] = P(l3)*C_infer + P(l2_only)*(C_infer - C_l2_read) [D15]
P(hit) 来自 PatternStats 后验预测分布。

## D. 校准闭环 = 元学习 (R2/R9)

- Change 携带 prediction 快照 [D8][D11]
- calibration 投影按期算相对平方误差; proper scoring rule 防系统性高报
- 滑窗不收敛 -> 编译成本上调 (学习率 alpha 封顶 x3) [D18]

## E. 实证协议 (R9, 对应 DESIGN 15/16)

编译前后对照 N>=30, Welch/Mann-Whitney + Cliff's delta + 95% CI;
同 task_type 未编译 pattern 对照组; 全部指标来自既有事件流零旁路 [D9]。

## F. 实现落位（已完成）

| 组件 | 文件 | 测试 |
|---|---|---|
| PatternStats 纯函数库 | lib/newbee/environment/pattern_stats.ex | pattern_stats_test.exs (10) |
| PatternStore 投影/持久化 | lib/newbee/environment/pattern_store.ex | pattern_store_test.exs (5) |
| TCE 决策引擎 (Jit 扩展) | lib/newbee/environment/jit.ex | tce_decision_test.exs (5) |
| Calibration 校准投影 | lib/newbee/environment/calibration.ex | calibration_test.exs (4) |
| Cascade 级联收益模型 | lib/newbee/environment/cascade.ex | cascade_test.exs (3) |
| DESIGN.md 附录 | DESIGN.md §17 | — |

## G. 护城河 (R10)

数据闭环（真实使用史长出后验）/ 架构复合（事件溯源上的投影判据）/
理论交叉（JIT x budgeted BAI x 共轭后验 x 实物期权 x proper scoring rule）/
元学习复利（偏差驱动先验更新）。

## H. Goodhart 防线 (R10)

regressional->EB+LCB; extremal->C 复杂度分位数; casual->task_type 分桶对照;
adversarial->proper scoring+审计快照+need 去重; 权力集中->Autonomy 挣得制+投影可见。
