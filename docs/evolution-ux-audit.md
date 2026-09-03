# 进化 WebUI 面板第一性原理审计与整改（worktree: fix/evo-ux-focus）

> 使用者原话：根本不知道展示的是什么，也不知道要不要批准，展示了一堆乱码七糟的东西，根本不是给使用者看的；步骤面板会自动刷新抢焦点。
> 方法：第一性原理 + 启发式评估 + 文献证据；大胆创新，小心求证；全部在 /tmp/newbee-evo-ux 实现，主仓不动。

## 0. 第一性原理：这个功能为什么存在？

- 本质：环境自我改进闭环。Worker 在真实任务中反复失败/命中规则/显式 need → Adapter 把“重复模式”固化为最小候选（新工具/规则/prompt/projection）→ 经过五层验证（静态→确定性→回放→真实使用→长期）→ 人类门控批准 → 生成新 revision 并切换 active，旧 revision 保留可回退。
- 为什么这么干：人记不住重复失败，机器能统计；直接改 active 环境会 destabilize，所以用 revision 不可变 + 门控 + 可回退。这是典型的 human-in-the-loop automation：机器提议，人类拍板。
- 益处（若 UX 成立）：减少重复踩坑，沉淀组织记忆，且不丢稳定性。若 UX 不成立：人类无法校准信任，要么盲批（风险），要么全拒（进化停滞），要么被打扰到关掉面板。
- 因此面板的唯一用户任务可压缩为三问（Decision Triad）：
  1. 这次要改变什么？对我有什么好处？
  2. 证据充分吗？风险多大？能否撤销？
  3. 我现在要做什么（批准/再看看/忽略）？不做会怎样？
- 现状面板没有一条直接回答这三问，全是内部 IDs 和流水账。这就是“乱码感”的根源。

## 1. 现状事实盘点（代码证据）

- 入口：priv/web/index.html#mc-evolution（~40行）+ priv/web/app.js L4129~L4470（refresh/render/approve/feed）+ lib/newbee/web/api.ex evolution.*（status/feed/approve/reevaluate/trigger）。
- 顶览：ACTIVE ENVIRONMENT / rN / 健康 pill / autonomy_label（观察/人工门控/自主/紧急停止）+ 三个 KPI（开放Change/激活Release/待处理信号）。
- 生命周期条：信号→候选→五层验证→门控→Revision（静态文本，与当前卡片进度无联动）。
- Change 卡：标题 = plugin_id || shortRelease(candidate_release) || change_id（如 foo.bar@sha），副标题 = changeId · Ring N；状态 tag；reason 原文（adapter: …）；五层格 PASS/FAIL/LIVE/WAIT/N/A + samples/replay 数字；foot = next_action + 批准激活/重新评测按钮。
- 批准弹窗：`批准 {changeId} 激活？验证通过的候选将生成新 revision。`按钮 批准激活/取消。未说明改了什么、风险、可逆性。
- 信号区：capability/urgency/evidence 原文字段，最多5条。
- Release 区：plugin/? + uses次 · 成功率% · 均耗tok + kind。
- 证据区：标题“不可变事件证据”，details 列表，每条 summary + <pre> 原始 JSON（含 topic/id/identity/payload）。
- 抢焦点：priv/web/app.js setBusy(true) → if (MC.open) switchMCTab("steps")；setBusy(false) → switchMCTab("files")+refreshMCFiles。任何 AI 起止都强制切 tab，用户在进化/概览/Diff 上会被拽走。renderMCSteps/mcToolResult 本身不切 tab，定时器 refreshEvoStatus 只在 tab==evolution 时跑，无辜。

## 2. 什么是好的（保留）

- 有门控：can_approve/can_reevaluate/next_action/status_label/evaluation.layers 在后端已算好，前端不用猜。derived_status 区分 awaiting_approval/stale_base/canary 等，正确。
- 有证据链：EventStore 不可变事件 + 五层验证 + Fitness 观测（uses/success_rate/avg_tokens）是信任校准的原材料，只是展示错了层级。
- 有空状态文案意识：暂无Change/信号队列为空/无激活Release 都有兜底，不是白屏。
- 定时刷新有节制：setInterval 10s 仅在 tab==evolution 时 refreshEvoStatus；websocket pushEvoEvent 也仅在 evolution tab 才 refreshStatus。性能克制，值得保留。

## 3. 有问题 + 依据 + 改法（每条都有文献）

### P0-1 术语是内部黑话，违反“说人话”（H2）
- 事实：ACTIVE ENVIRONMENT、r-、Ring -、shortRelease hash、adapter: 前缀、suggestion_ready/stale_base、Worker→Adapter、不可变事件证据。用户无从建立心智模型。
- 依据：Nielsen H2 “Match Between System and Real World：说用户的语言，用用户熟悉的词，不要用内部 jargon；永远不要假设你的理解和用户一致” (https://www.nngroup.com/articles/ten-usability-heuristics/)；NN/g Plain Language 要求专家术语必须翻译。
- 改法：引入 evoHumanize 翻译层 + 首屏一句话定义 + “怎么判断要不要批准？”折叠指南；标题用人话（reason 为主，ID 降为 mono 副标题）；Ring N → “影响范围 Ring N（3=单工具最稳，1=底层需更严验证）”；reason 去 adapter: 前缀并加“原因：”；autonomy 加一句话解释（见后端 autonomy_explain）。

### P0-2 批准按钮无法决策，违反“确认框必须具体”（H5/H9）
- 事实：旧弹窗只有 changeId + “将生成新 revision”，无改了什么、无验证摘要、无风险、无可逆性。用户只能盲批/盲拒。
- 依据：NN/g Confirmation Dialog：确认框必须 restate 请求并解释后果，给出 specific 信息，否则用户会自动化点 Yes，失去防错意义；按钮不能是 Yes/No，要用总结后果的动词（Delete file/Keep file）；高后果必须可 undo (https://www.nngroup.com/articles/confirmation-dialog/)；对应 H5 Error Prevention + H3 User Control。
- 改法：新批准弹窗 = 改了什么（human title+reason）+ 验证结论（5门 X通过/Y观察/失败名）+ 影响与可逆（生成新版本，旧版本保留，可回退）+ 风险（Ring+autonomy）+ 按钮“批准并激活 / 再想想”；后端新增 risk_label/reversibility/verification_summary/human_title 字段供前端直接渲染，避免前端猜。

### P0-3 信息平铺无优先级，违反 Progressive Disclosure
- 事实：进行中/信号/Release/原始JSON 四区等权平铺，重要决策（awaiting_approval）淹没在流水中；原始 JSON 默认展开 largest 认知负荷。
- 依据：NN/g Progressive Disclosure：把用户最需要的放首屏，高级/低频放二级；这样 novice 少犯错、expert 少扫描，learnability/efficiency/error 三项都提升；必须让“如何进入二级”显而易见 (https://www.nngroup.com/articles/progressive-disclosure/)；对应 H8 Minimalist。
- 改法：重排为 ①需要你决定 ②正在进行（含管道进度）③AI发现的问题 ④环境状态（折叠）⑤历史（默认折叠，原始JSON藏在“技术详情”后）；无待决策时显示庆祝空状态而非“暂无Change”。

### P0-4 生命周期条是死的，违反 Visibility of Status（H1）
- 事实：evo-loop 五个词静态，与每张卡的实际 stage 无映射，用户不知道“我的卡走到哪了，下一步要等什么”。
- 依据：H1 “永远让用户知道发生了什么，在合理时间内给反馈；可预测的交互建立信任” (https://www.nngroup.com/articles/ten-usability-heuristics/)。
- 改法：每张进行中卡渲染 mini 管道（信号●→候选●→验证◐→门控○→版本○），当前阶段高亮；顶览健康 pill 加 title 解释 degraded 原因。

### P1-1 抢焦点 = 系统发起的中断，违反 User Control（H3）+ 注意力瓶颈
- 事实：setBusy 强制 switchMCTab，用户看进化/Diff/概览时被拽到步骤/文件；只要 AI 在跑就无法停留在其他面板。
- 依据：H3 “用户需要明确的 emergency exit，不要被困；支持 Undo 让用户有掌控感”；NN/g Attention Economy：注意力是有限瓶颈（Simon bottleneck），wealth of information creates poverty of attention，同时只能专注一件事，频繁通知/抢占会耗尽预算 (https://www.nngroup.com/articles/attention-economy/)；系统发起的中断必须克制，confirmation 本身就是中断，能免则免。
- 改法：删除 setBusy 中的强制 switch；引入 sticky tab（localStorage 持久 MC.tab）+ 未读徽标（steps/files/evolution 有新内容时亮点，不切换）；mcToolStart/Result 只在后台更新数据+徽标；完成时静默刷新文件列表，不切 tab。用户点 tab 才算显式意图，清除徽标并记忆。

### P1-2 无帮助文档（H10）
- 事实：面板无“这是什么/怎么用”，用户只能猜。
- 依据：H10 Help and Documentation。
- 改法：evo-guide 折叠面板写三条判断标准（证据→风险→可逆）+ 术语表（Revision/Change/Ring/五门各是什么），一句话一条，不跳链。

## 4. 创新点（大胆，但可验证）
- 决策三问卡：把批准从“ID+按钮”变成“问题→证据→后果→动作”四段式，ID 降级为 mono 副标题。这是 Human-Automation Trust 校准（Lee & See 2004；Parasuraman et al. 2000 Levels of Automation：越高的自动化越需要显式的人类批准点与可逆设计）的落地。
- 管道 mini 进度 + 验证 pills tooltip：把后端已有的 layers reason/samples/replayed 变成 hover 可查的二级披露，不增加首屏负荷。
- 徽标代替抢占：把“系统替你切”变成“系统提醒你有更新”，把控制权还给用户，可用徽标点击率/停留时长验证。

## 5. 验证标准（小心求证）
- 编译：mix compile --warnings-as-errors（lib+test）零警告；MIX_ENV=test 同。
- 后端契约测试：evolution_change 新增字段（human_title/risk_label/reversibility/verification_summary/autonomy_explain）断言；旧字段不删（兼容）。
- 前端：无自动化单测，用“依据证明”：① 旧 setBusy switch 字符串在 worktree 中消失（grep）；② 新 switchMCTab 持久化 + updateMCBadges 存在（grep）；③ 进化 pane 含 evo-intro/evo-guide/evo-decide（grep）；④ 手工浏览器走查：切到进化→发 /evolve 或触发 AI→确认不跳走且徽标亮；待决策卡显示人话标题+后果+可逆。
- 回归：git diff 只碰 priv/web/{index.html,app.js,style.css} + lib/newbee/web/api.ex + 新增 docs + test；main 分支保护用 squash 流程合回。

文献索引（可点击）：
- https://www.nngroup.com/articles/ten-usability-heuristics/ （H1/H2/H3/H5/H8/H10 原文）
- https://www.nngroup.com/articles/confirmation-dialog/ （specific + 动词按钮 + undo）
- https://www.nngroup.com/articles/progressive-disclosure/ （首屏/二级切分）
- https://www.nngroup.com/articles/user-control-and-freedom/ （Back/Undo/Exit）
- https://www.nngroup.com/articles/attention-economy/ （Simon bottleneck，注意力有限）
