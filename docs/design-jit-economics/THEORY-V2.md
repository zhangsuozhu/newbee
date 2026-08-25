# TCE v2.0 — 论文驱动的理论深化 (第二轮 R11-R17)

## 新读文献与核心收获

| # | 文献 | 核心机制 | TCE 映射 |
|---|---|---|---|
| P1 | Wald SPRT (+Wald-Wolfowitz 最优性) | 累积 log-LR 对阈值 a=log(beta/(1-alpha)), b=log((1-beta)/alpha) 的序贯检验 | deopt 双通道判据的理论化：现状是"后验尾部概率一次性检验"，升级为真正的序贯检验——样本效率最优 |
| P2 | Page CUSUM (1954) | S_{n+1}=max(0, S_n + x_{n+1} - omega)，单侧累积漂移检测，超阈报警 | 漂移检测从"快照对比一次检验"升级为在线 CUSUM——对缓慢漂移更敏感、对偶发噪声更鲁棒 |
| P3 | Gittins index | 折扣因子 gamma<1 下贝叶斯 bandit 的最优停时指数策略；折扣 ↔ 有效记忆长度 | 时间衰减 gamma 与 Gittins 折扣数学同构——衰减版贝叶斯更新继承近优性论证；编译排序可选用 Gittins 风格 index 替代朴素 LCB |
| P4 | Budgeted MAB (omega-UCB, Tran-Thanh 等) | 目标是 reward-cost RATIO 最大；非对称置信区间 | 印证 LCB(net)/C 排序形式；升级点：区间应非对称（成本端用 UCB，收益端用 LCB） |
| P5 | BOCPD (Adams & MacKay 2007) | run-length 分布 + hazard function 在线消息传递，精确推断最近变化点 | 漂移检测的概率化终极形态：v3 方向；v2 先落 CUSUM（工程成本低一个量级） |
| P6 | UCCI 校准优先路由 | isotonic regression 把不确定性映射为错误概率；约束成本最小化选阈值 | Calibration 的阈值不应拍脑袋：从校准数据反解；proper scoring rule 路线得到印证 |
| P7 | 采样法近似 Gittins | 截断视野 + 最优停时 + 随机逼近，有限时间误差界 | 大 pattern 数时 LCB 排序的计算可行性兜底 |

## 四个理论升级（v2 定稿）

### U1 序贯检验替代单次检验 [SPRT 化 deopt]
工具坏判定改为 Bernoulli SPRT：
  H0: p >= p_ok (工具健康), H1: p <= p_bad (工具坏)
  S_n = S_{n-1} + log[ f(x_n|p1)/f(x_n|p0) ]
  S_n >= log((1-beta)/alpha) -> 判 H1 (deopt)
  S_n <= log(beta/(1-alpha)) -> 判 H0 (清白，重置)
  否则继续观察。
性质：期望样本数在两类错误约束下最小（Wald-Wolfowitz）。alpha=beta=0.05 时
b≈2.944, a≈-2.944。每次失败加 log(p1/p0)>0，成功加负项。

### U2 CUSUM 漂移检测器 [替代快照对比]
频率漂移：对 lambda 的标准化偏移做 CUSUM:
  x_t = (observed_count_t - E[lambda])/sd, omega=0.5 (允许带)
  S_{n+1} = max(0, S_n + x_t - omega); S > h -> 报警
ARL(平均运行长度)特性：误报率由 h 直接控制（h=4~5 → ARL 约几百），比 h-sigma 快照检验
对缓漂敏感一个数量级。

### U3 非对称置信区间 [omega-UCB 启发]
net = benefit - cost 两端不确定性不同质：
  benefit 端取 LCB（保守收益）
  compile_cost 端取 UCB（悲观成本）
排序分 = LCB(benefit) - UCB(C)。比对称 kappa*sigma 更贴合预算语义。

### U4 校准阈值反解 [UCCI 启发]
compile_worthy? 的 min_samples 与 LCB>0 阈值不再硬编码：
从历史 settled 预测中反解"使事后 regret 最小"的阈值（isotonic/分段常值近似）；
数据不足时回退默认值。v2 先实现"误差驱动调整"（已有 adjust_compile_cost），
阈值反解留接口。

## 数值稳健性升级
- PatternStats.beta_quantile 用 Newton 初值正态近似在小 alpha/beta 发散风险
  → 改为 bisection 包络（保收敛，精度 1e-8 足够）
- betai/gammainc_p 增加 edge-case 守卫（a 或 b 极小时 front 因子溢出）
- 全部特殊函数增加 python3 math.lgamma/erf 真值交叉验证测试（属性级）
