# R4 贝叶斯不确定性 → 小样本数学

## 来源
Wikipedia Conjugate prior; Empirical Bayes method (Poisson-Gamma, Robbins NPEB)

## 核心事实
1. 共轭先验闭式后验 O(1) 在线更新，无需 MCMC
2. EB 从群体数据矩估计超参数，收缩个体小样本估计
3. Gamma-Poisson 后验预测=负二项分布，区间有解析解

## 落位
PatternStats 三组共轭后验(freq/succ/save)；时间衰减=缩放充分统计量仍合法共轭形态；
EB 收缩群体先验 [D12]
