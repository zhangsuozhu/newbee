# R10 Goodhart / reward hacking → 防操纵设计

## 来源
Wikipedia Goodhart's law; Manheim & Garrabrant 2018 Categorizing Variants of Goodhart's Law (arXiv:1803.04585)

## 四机制与对策
| 风险 | 场景 | 对策 |
|---|---|---|
| regressional | 小样本热点收益高估 | EB收缩 + LCB 判据 |
| extremal | 极端复杂 pattern 编译亏本 | C 按候选复杂度分位数估计非常数 |
| casual | 任务变简单误归因工具有效 | task_type 分桶对照归因 |
| adversarial | 刷校准分/刷 need 热度 | proper scoring rule + 决策快照审计 + need 幂等去重 |
| 权力集中 | autonomous 下自评自选 | Autonomy 档位挣得制 + 校准投影对用户可见 |

关键句: importance of Goodhart effects depends on the amount of power directed towards optimizing the proxy

## 技术护城河总结
1. 数据闭环: PatternStats 后验只能从真实使用史长出，抄公式抄不走历史
2. 架构复合: 判据全挂既有 Event Store/Projection/Change 生命周期，零旁路
3. 理论交叉: JIT x BAI x Bayes x 实物期权 x proper scoring 五域交叉点
4. 元学习复利: 偏差驱动先验更新越用越准
