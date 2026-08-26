# R3 多臂老虎机 → 编译排序

## 来源
Wikipedia Multi-armed bandit; Thompson sampling

## 核心事实
1. MAB = 有限资源在竞争选择间迭代分配最小化 regret
2. 认知 JIT 是 budgeted BAI 变体：不是每轮选臂而是何时买断哪个臂（buy 有固定成本 C）
3. Thompson/UCB 天然输出不确定性——点估计的解药

## 映射与修正
- [D10] LCB 排序（保守买入），小样本 UCB 项大自然实现 P1 小样本不决策
- [D11] 决策快照入审计事件供校准闭环
- regret = 继续用推理而未编译的机会成本累计
