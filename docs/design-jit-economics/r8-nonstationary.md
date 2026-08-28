# R8 非平稳 bandit / concept drift → deopt 判据定稿

## 来源
Wikipedia Multi-armed bandit Non-stationary; Concept drift

## 核心事实
1. 非平稳 setting 对照基准是 dynamic oracle（每步选当步最优），regret 相对它计算
2. concept drift 使模型失效但模型没坏——是世界变了

## deopt 双通道判据 [D17]
A 工具退化: P(p < p_min | alpha,beta) > 0.95 且频率后验未显著下降
  -> 对策: deopt 到 L2 候选 release + adapter 修复 need(high)
B 分布漂移: E[lambda] 相对编译时快照跌落 > h sigma（Gamma-Poisson 后验预测区间）
  -> 对策: dormant 冷层级，不降级工具；长期 dormant 归档
判别式: 失败率升+频率降=B；失败率升频率不变=A。数学上=两个独立后验各自序贯检验
