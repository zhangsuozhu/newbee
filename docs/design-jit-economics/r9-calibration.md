# R9 校准评分 → 验收实验设计定稿

## 来源
Wikipedia Brier score (strictly proper scoring rule; Reliability/Resolution/Uncertainty)

## 核心事实
1. strictly proper scoring rule：唯一最优策略是报告真实概率 → 系统性高报无利可图（Goodhart 防线）
2. 三分解: Reliability(校准)/Resolution(区分度)/Uncertainty

## 实验设计（对应 DESIGN 15/16）
验收15 编译前后对照: 同 pattern 任务流 N>=30，Welch/Mann-Whitney + Cliff's delta + 95% CI;
对照组 = 同 task_type 未编译 pattern（混杂控制）
验收16 收敛: Change 提交记录 predicted_save 快照; 月度相对平方误差=(pred-realized)^2/pred^2;
滑窗分数单调不增或低于阈值 -> 收敛
[D18] 校准协议: prediction 快照入 Change 事件 + calibration 投影按期评分 + 偏差驱动先验更新（元学习闭环）
