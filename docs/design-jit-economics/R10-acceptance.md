# R10 验收对照（DESIGN §15 智能验收 ↔ TCE 实现/测试）

| 验收项 | 要求 | 实现落位 | 测试证据 |
|---|---|---|---|
| #13 已验证抗体零复现 | verified_regression_test 覆盖的输入在确定性门零复现 | Antibodies.gate 在 Coordinator 确定性门执行（既有） | antibodies_test |
| #14 反事实回放对比 | 进化补丁经回放对比非固定考题 | 投影回放=PatternStore 幂等投影重放；执行回放=replay fixture | tce_e2e_test（真实事件形状重放）|
| #15 固化后 token 可测下降 | 同类任务 token 可测下降报样本量与CI | V3 蒙特卡洛：LCB 决策 10/10 热点选中 0 噪声；R6 校准后分离边界清晰 | tce_monte_carlo_test V3 |
| #16 价签偏差收敛 | 滑窗内预测实测偏差收敛 | Calibration.converging?/adjust_compile_cost + V4 误差单调下降实证 | calibration_test + monte_carlo V4 |

## 第三轮新增的超越原验收的验证
1. SPRT alpha 实测校准（2000 trials，2.5% < 标称 5%，Wald 不等式）
2. CUSUM ARL 测量（平稳零误报 / 漂移 59.5 步平均延迟）
3. kappa 参数敏感性扫描（0.0-2.0 决策稳定，3.0 开始过滤边界模式）
4. 400 步生命周期仿真（劣化检出→持续报警→修复恢复）
5. 性能基准（11.8k 事件：投影 1.5ms / 持久化 8.8ms / 决策 <0.1ms）

## 遗留 v3 方向
- BOCPD run-length 后验（概率化漂移检测，替代 CUSUM 启发式）
- Gittins index 查表（Bernoulli bandit 最优停时的精确解）
- 校准阈值反解（从 settled 历史反解 LCB 阈值，替代固定 0）
