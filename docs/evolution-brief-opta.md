# 进化批准讲人话卡（opt_a：提案时生成）

## 第一性原理
批准是个委托决策，人只需要五问：发现了什么、要变成什么样、为什么有效、
风险反悔、要我干啥。答不上这五问的信息（英文ID、哈希、PASS 格子）全是噪音。

## 病根（截图实证）
- `Adapter.process_proposal` 写 `reason: "adapter: #{proposal["id"]}"`，
  标题与原因复读同一英文 ID（如 distill-stream-chat-hotpath）。
- `evidence` 只有 `%{proposal: id, type: type}`，没有失败次数与任务故事。
- 前端 `layer.samples != null` 对空串为真，数字丢失显示"次试用"。

## 做法
- 新模块 `Newbee.Environment.HumanBrief`：`template_brief/1` 纯函数兜底
  （只用给定材料造句，绝不复读裸 ID）；`generate/2` 调 adapter 角色 LLM
  写 JSON 六段，严格校验（六段齐全、含中文、无 chg_、长度封顶），
  任何失败 30s 超时内回退模板，永不 raise。
- `Change` 新增 `human_brief` 字段，随 change.json 快照审计。
- Coordinator：propose 时同步挂模板（零等待）；candidate_ready 后
  `Task.start` 异步 LLM 升级，经 `{:brief_ready, ...}` cast 写回
  （仅覆盖仍是模板的卡），广播 `change_brief_ready` 事件；
  WebSocket 转发该事件，前端自动刷新。
- `evolution.explain` RPC：老数据按需生成并落盘（force 可重讲）；
  前端模板卡上"换一种说法"按钮调用它。
- 前端：叙事五段卡（发现/改法/依据/风险/决定），PASS 格收进
  "验证细节"折叠，技术 ID 收进"技术详情"折叠；修空串 samples bug；
  批准弹窗读叙事段落，主按钮写明后果。

## 验证
- `human_brief_test.exs` 6 用例（模板/成功采用/失败回退/拒收无中文/拒收伪造ID）
- `human_brief_coordinator_test.exs` 2 用例（propose 即带卡、update_brief）
- `evolution_explain_test.exs` 1 用例（status 透 brief、explain 落盘、未知ID/缺参）
- `evolution_ux_test.exs` 更新叙事标记断言；coordinator_reevaluate 回归通过
