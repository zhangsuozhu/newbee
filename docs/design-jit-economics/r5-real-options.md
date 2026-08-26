# R5 实物期权 → deopt 与延迟编译

## 来源
Wikipedia Real options valuation

## 核心事实
1. option to abandon = American put（deopt）；option to defer = 等待更清晰再投资；
   switching options = L1/L2/L3 三形态切换链
2. 与金融期权差异：管理层影响标的价值；波动率只能感知 → adapter 合成质量影响工具价值；
   波动率=PatternStats 后验宽度
3. deopt 行权价 = L2 形态持续价值（规则还能触发）→ 知识不丢

## 映射与修正
- defer option 论证 LCB 推迟的合法性：不确定时观察是正价值行为
- [D13] deopt 必须产出 L2 降级候选 release（完整降级路径）
- [D14] 净收益含不确定性惩罚: LCB(net) = E[B] - kappa*sigma(B)
