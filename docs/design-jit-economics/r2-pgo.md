# R2 PGO/FDO 反馈闭环

## 来源
Wikipedia Profile-guided optimization; Dehao Chen (2010) Taming hardware event samples for FDO

## 核心事实
1. 代表性警告: profiling 样本不具统计代表性时 PGO 净伤害性能 → 编译决策的校准义务
2. 插桩式双编译繁琐未广泛采用；采样式(AutoFDO)低开销无需特殊编译
3. HotSpot 动态 PGO: optimized for the actual load; 负载变化→动态重编译

## 映射与修正
- [D8] 预测必须记录并事后校准（代表性警告的工程化）
- [D9] 禁止新增旁路观测通道——事件流是免费 profile
