# R1 应用场景第一性分析

## TCE 在 newbee 中的真实位置（生产触发链核实）
daemon heartbeat(10min) / prompt_injection debounce / 用户 /evolve
  → Adapter.run_once → collect_signals【TCE入口】→ synthesize(LLM合成)
  → propose_change → Coordinator 五层评价 → activate/rollback

## 四个场景的 TCE 角色界定
S1 周期进化(10min tick): TCE = 过滤器+排序器（哪些模式值得花 adapter 预算）
S2 prompt_injection 即时防护: TCE 不参与（安全域，走沉睡规则）
S3 手动 /evolve: 同 S1
S4 worker need 消息: TCE = 排序器（need 不该被过滤，只该被排后）

## 发现的场景缺口（本轮核心产出）
G1 【token 归因断裂】tool_start 事件无 token 字段；token 计数在 LLM 层的
   usage 事件里，两者无关联 ID。TCE 假设的 "pattern→tokens" 观测在真实流中脱节。
   → 解法 v2.1: PatternStore.Collector(GenServer) 订阅 Bus，
     tool_start 记名、usage 归因给最近工具、批量 flush。零旁路。
G2 【触发粒度】10min heartbeat 对"即时 deopt"太慢：坏工具在两次 tick 间
   可能已浪费大量 token。→ 解法: Bus 订阅 tool_error 连续超阈即时 debounce 进化。
G3 【冷启动语义】新项目 PatternStore 空 → tce_hot_needs 返回 [] → 回退旧点估计。
   回退路径的正确性此前未验证。→ 补测试。

## 行动项
A1 实现 Collector (G1)
A2 daemon 加 tool_error 风暴即时触发 (G2)
A3 冷启动回退测试 (G3)

## R6 补充：编译成本默认值校准（实证）

10_137 事件基准下扫描发现：旧默认 compile_cost=5000 导致 46 候选（42 噪声）；
改为 100_000（adapter 合成+测试+评价的真实 token 量级）后精确选中 5 真热点零噪声。
教训：**决策阈值必须用决策成本的真实分布校准，拍脑袋的低估比不决策更糟。**
同时移除 estimate_tokens=500 的捏造默认——无 token 观测时不做节省估计。
性能：11.8k 事件投影 1.5ms / 持久化 8.8ms / 决策 <0.1ms，远低于 10min 周期预算。
