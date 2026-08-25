# R6 LLM 经济学 → token 成本真实形状

## 来源
FrugalGPT (arXiv:2305.05176); RouteLLM (arXiv:2406.18665)

## 核心事实
1. LLM API 价格差两个数量级；cascade 策略最高省 98% 不掉点
2. RouteLLM router 有迁移性：换强/弱模型仍工作
3. L3 工具调用零 token = 比任何模型路由都彻底的便宜层——智能价格降到 0

## 映射与修正
- L1/L2/L3 不仅有编译层级语义还有运行时级联语义：
  新输入先被 L2 拦截(零token)，未命中走推理；L3 命中整个循环短路
- [D15] 收益公式升级为级联期望节省:
  E[save] = P(l3)*C_infer + P(l2_only)*(C_infer - C_l2_read)
