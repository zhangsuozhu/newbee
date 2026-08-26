# R1 经典分层 JIT (HotSpot / V8 Sparkplug / Maglev)

## 来源
Wikipedia HotSpot (tiered compilation, invocation-count threshold);
v8.dev/blog/sparkplug; v8.dev/blog/maglev

## 核心事实
1. HotSpot 只编译常运行方法，invocation-count 阈值决定谁被编译；分层=快编译器先上
2. Sparkplug cheat=从字节码编而非源码，重活前层已做 → 编译极快所以想升就升
3. Maglev 哲学（原文）: "If the feedback it relied upon ended up not being very stable yet,
   there's no huge cost to deoptimizing and recompiling later."
   中间层让系统在反馈不稳定时也敢部署，把贵层触发推迟到证据充分时
4. Maglev 能耗 -3.5%~-10%：资源消耗是一等功能指标

## 映射与修正
- [D6] profile 加时间衰减
- [D7] L3 从 L2 release 派生，复用 pattern+命中样本作测试
- deopt 是生命周期不是失败
- token = 认知能耗指标
