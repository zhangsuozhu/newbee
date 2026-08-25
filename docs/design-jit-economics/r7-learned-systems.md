# R7 learned systems / 自适应查询处理

## 来源
Kraska et al. 2017 The Case for Learned Index Structures (arXiv:1712.01208);
Wikipedia Query optimization (cost-based, selectivity statistics)

## 核心事实
1. "Indexes are models"：用数据分布模型替代通用结构，+70% 速度 -10x 内存——前提是分布可学习且稳定
2. cost-based optimizer 依赖 selectivity 统计，谓词相关性导致统计失真
3. Rules/Tools are learned models of the task distribution：L3 工具是对某类输入重复出现
   且解法固定的分布结构的物化；漂移时 retrain = deopt/recompile

## 映射与修正
- [D16] 分桶粒度 pattern x task_type（model 只进价格权重），防小样本桶爆炸
