# 项目聊天室弹窗 · 可用性 / 视觉审计报告

- 审计对象：newbee WebUI「项目协作群 → 聊天室」弹窗（`priv/web/project-chat.js` 全文 260 行、`priv/web/style.css` 的 `.pc-*` 段 4017-4089、入口 `priv/web/app.js:3400,3461-3471`、后端路由 `lib/newbee/collaboration/chat/room.ex` 只读核对）
- 基线（重要）：分支 `feat/group-ui-polish`（HEAD 50686be）+ 未提交改动。审计期间（20:38-20:42）另一会话正在并发修改 `priv/web/app.js`、`priv/web/style.css`、`priv/web/index.html`。
  - `priv/web/project-chat.js` 审计前后 hash 一致（sha256 `b2d95231c45a0864a01892a65e76fec05d362ee87405973741e42a19936bef52`），JS 行号可直接使用。
  - `priv/web/style.css` 在审计后仍被修改（sha256 `ce04a05c…`）。已逐条复核：`.pc-*` 规则**文本未变**，仅整体下移 82 行，故报告中的 CSS 行号已按**当前文件**校正。
  - `priv/web/app.js`、`priv/web/index.html` 同期被修改，文中行号同样按当前文件校正（`app.js` sha256 `b88fcd06…`、`index.html` sha256 `fbc75020…`）。
- 只读纪律：未修改 `priv/` 与 `lib/` 下任何文件，未在聊天室发送消息/停止讨论/应用决议（唯一客户端动作是临时切换 `data-theme` 取证，已还原）；唯一产物是本报告与截图。
- 方法：先读 `docs/project-chat-design.md` 建立状态机预期 → Playwright（1440×900 与 390×844）打开 `http://127.0.0.1:4399` →「订单系统开发组」→「聊天室」，采集 DOM、计算样式与元素尺寸并截图 → 结论逐条回到源码行号确认。
- 证据目录：`.newbee/group-ui-audit/shots/`（00-sidebar-1440、01-chat-1440、02-topic-1440、03-topic-390、04-theme-dark|light|neumorphic|neumorphic-dark）
- 样例数据说明：预览群内两个议题均为「待讨论」，且已存在两条模型调用失败消息（`.pc-kind-error`），C3、E1、E2 即以该真实状态取证。

## 结论摘要

1. 最高风险不是视觉，而是**默认视图的行为落差**：弹窗默认落在「群聊动态」，人类等待回合在这里既不显示、也无法完成（P0，D1）。
2. 第二高风险是**不可逆动作零确认**：停止讨论会取消进行中的回合，却只是一个普通描边按钮（P0，E1）。
3. 消息流缺归属与层级：聚合视图不标议题、引用回复显示原始消息 ID、失败消息无重试入口、系统通知署名渲染成「系统 · system」（P1，C1-C4）。
4. 键盘/无障碍存在真实回归：弹窗打开时全局 Esc 会中断主会话而不是关闭弹窗（P1，G1）；`role="log"` 因全量重建而重复播报（P1，G3）。
5. 窄屏与拟物主题是两处系统性缺口：390px 下消息区只剩 155px 高、议题栏被裁；拟物主题下人类消息与普通消息对比度仅 1.05:1（P1，F1/F2、H1）。

## 覆盖矩阵

| 要求覆盖项 | 对应编号 |
| --- | --- |
| 首次进入的引导与学习成本 | A1 A2 A3 |
| 议题/代表/决议/定向邀请 角色与术语 | B1 B2 B3 B4 |
| 消息流层级与可读性（人类/模型/系统/跳过） | C1 C2 C3 C4 C5 C6 H1 |
| 人类等待回合的可操作性 | D1 D2 D3 |
| 讨论与停止的状态反馈 | E1 E2 E3 |
| 窄屏 390px | F1 F2 |
| 键盘与焦点 | G1 G2 G3 G4 |
| 三主题一致性 | H1 H2 H3 |
| 危险操作确认 | E1 B2 D3 A3 |

## 问题清单

### A. 首次进入与学习成本

- [P1] 弹窗默认打开「群聊动态」，此时「召集讨论」「停止讨论」同时灰掉且没有任何禁用原因说明，新用户不知道第一步该做什么 | priv/web/project-chat.js:162-163,203 | 运行实例（重开弹窗后实测）：`.pc-actions` 两个按钮 `disabled=true, title="", aria-describedby=null`；按钮构造器只设文本/class/type（project-chat.js:14-15） | 给禁用按钮补 title/aria-describedby 说明原因，并在首屏加一条可关闭的三步引导（勾选代表 → 发起议题 → 召集讨论）
- [P1] 代表勾选只存在于 DOM，每次 render 从勾选框反推，切议题/刷新/重开弹窗即丢失，用户无法预知"什么时候生效" | priv/web/project-chat.js:112,203,245 | 代码：`const selected = new Set([...s.members.querySelectorAll("input:checked")]...)`，会话状态 `s` 中没有任何勾选字段 | 把选择存入会话状态，并在右侧栏写明"仅对下次召集讨论生效"
- [P2] 关闭弹窗不提示"讨论仍在后台继续"，重开也没有新增/未读提示，用户容易以为关掉=停掉 | priv/web/project-chat.js:203,252-253 | 代码：`button("关闭", () => dialog.close())`，close 监听只做 `current = null` 与焦点回收，无状态保存 | 关闭前提示后台继续，重开时高亮增量消息

### B. 角色与术语

- [P1] 状态行直接倾泻内部记账术语：「待讨论 · 第0轮 · 模型2/16次 · 省下0次 · 人类回合0次」，其中"省下 N 次""人类回合"没有可理解的单位 | priv/web/project-chat.js:130 | 运行实例文本（shots/02-topic-1440.png）：`待讨论 · 第0轮 · 模型2/16次 · 省下0次 · 人类回合0次` | 改为"已用 2/16 次模型调用 · 跳过 0 次 · 等待人类回复 0 次"，并对"调用预算"给 tooltip
- [P1] 「提供给执行任务」一次点击就把决议写入执行任务上下文，无二次确认，按钮文案也看不出影响范围 | priv/web/project-chat.js:181-186 | 代码：`apply.disabled = applied \|\| !d.task_id \|\| !d.base_revision`（:183）；`grep -c 'confirm(' priv/web/project-chat.js` = 0；room.ex:596 的"执行反馈"说明决议会进入执行代理上下文 | 加确认弹层（显示版本号/任务/基线），并说明"只提供建议数据、不运行命令"
- [P2] 同一实体四套叫法：侧栏「休息/启用」「人类代表」，消息区「人类 / 会话」「议题发起」「未发言」 | priv/web/project-chat.js:122-123,135-136 | 运行实例：成员行"我（人类代表） · 人类代表"、消息 meta「人类 / 会话 · 群主本机 · 20:33」 | 统一为"代表名 · 类型"，并在侧栏补一段术语对照
- [P2] 定向邀请选择器包含自己的发言身份（@我（人类代表）），点击会插入 `@名字`，但后端会剔除作者，静默无效 | priv/web/project-chat.js:171-173；lib/newbee/collaboration/chat/room.ex:985,1004 | 代码：`mention_targets(..., false, author_id) -> Enum.reject(ids, &(&1 == author_id))`；live DOM 选择器为 @阿衡 @小满 @老周 @我（人类代表） @all | 选择器按当前发言身份过滤自己，或点击时提示"不能邀请自己"

### C. 消息流层级与可读性

- [P1] 「群聊动态」把不同议题的消息混排且卡片不标注所属议题，用户无法判断哪条属于哪个议题 | priv/web/project-chat.js:133-143 | live DOM：两个议题的 4 条消息相邻出现，meta 只有「议题发起 · 群主本机 · 20:33」（shots/01-chat-1440.png） | 聚合视图在 meta 加议题 chip，或按议题分组加分隔标题
- [P1] 引用回复渲染成原始消息 ID（「回复 msg_xxx」），不是被回复者与摘要 | priv/web/project-chat.js:138,143,234 | 代码：`"回复 " + m.reply_to`；room.ex:927-931 证明 reply_to 是消息 id（`&1["id"] == mid`） | 渲染为"回复 阿衡 · 前 60 字"，支持点击定位原消息
- [P1] 模型调用失败只有一条红边消息 + 通用文案，没有重试入口，也不标注轮次/议题，而议题状态仍是"第 0 轮"却已用掉 2 次调用 | priv/web/project-chat.js:126-138；lib/newbee/collaboration/chat/room.ex:685 | live DOM 两条 `.pc-message.pc-kind-error`：meta「阿衡 · Windows 开发机 · 20:33」，正文"模型调用失败，请检查本机模型配置和连接后重新发起议题"；状态行同时显示"模型2/16次" | 错误卡片加「重试这一回合」「查看详情」，并在议题状态里体现"有失败回合"
- [P1] 系统通知/执行反馈的作者行会渲染成「系统 · system · 20:33」，同一行中英重复 | priv/web/project-chat.js:23-28,137；lib/newbee/collaboration/chat/room.ex:1111,596 | 代码：`deviceName` 只处理空值/local/human:，`did="system"` 落到 devices 回查后原样返回 "system" | deviceName 增加 system 分支，系统消息隐藏设备段
- [P2] 「跳过」只靠 `opacity:.72` 与名字"未发言"区分，深色/拟物主题下几乎看不出，也分不清"本人跳过"与"超时失败" | priv/web/style.css:4068 | 代码：`.pc-kind-skipped { opacity: .72; border-left: 3px solid var(--nb-label-caption); }` | 加图标/徽标，明确区分"已跳过（本人）"与"超时未回复"
- [P2] 消息时间只有 HH:MM 没有日期，跨天消息无法定位 | priv/web/project-chat.js:22 | 代码：`toLocaleTimeString([], {hour: "2-digit", minute: "2-digit"})` | 非当天补日期，hover 显示完整时间戳

### D. 人类等待回合的可操作性

- [P0] 默认视图（群聊动态）既看不到也完不成人类等待回合：等待框只在选中议题时渲染；即使在这里回复，`topic_id` 为 null，后端不会把等待标记为 answered，回合仍会跑到超时 | priv/web/project-chat.js:149-156,203,234；lib/newbee/collaboration/chat/room.ex:1093-1106 | 代码：`(topic?.open_waits \|\| [])` 仅在有 topic 时渲染；`resolve_human_wait(room, _topic_id, nil) -> room`，匹配条件为 `job["topic_id"] == topic_id`，而 message.post 传的是 `topic_id: s.topicId`（null） | 聚合视图也渲染等待卡并标注议题名（或"去回复"自动切议题）；无议题时禁止署名回复并提示"请进入对应议题回复"
- [P1] 等待倒计时只在房间 revision 变化时重绘（轮询每 2s 只 refresh、不 force render），"约 N 秒"会长时间定格，甚至停在"约 0 秒" | priv/web/project-chat.js:151-152,192-199 | 代码：倒计时在 render 中一次性计算；`refresh` 里 `if (force \|\| !s.room \|\| room.revision !== s.room.revision) { s.room = room; render(s); }`（:194），poll 每 2s 调用 `refresh(s)`（:196-199） | 用本地 1s 定时器只更新等待卡文本，或让倒计时独立于整表重绘
- [P2] 「本轮不发言」是终态（写 skipped 并推进状态机）却没有确认或短时撤销 | priv/web/project-chat.js:152-155；lib/newbee/collaboration/chat/room.ex:339-356 | 代码：job.skip 直接把 job 置为 skipped 并 `advance` | 二次确认，或提供 5 秒内撤销

### E. 讨论与停止的状态反馈

- [P0] 「停止讨论」会取消所有 pending 回合（含人类等待），是不可逆的高影响操作，却没有任何确认，按钮也没有危险样式 | priv/web/project-chat.js:163,217；lib/newbee/collaboration/chat/room.ex:385-400 | 代码：discussion.stop 将同议题 pending job 置为 cancelled；按钮由 `button("停止讨论", ...)` 生成，class 仅 `pc-button`，无 confirm（grep = 0） | 危险语义样式 + 二次确认（说明将取消 N 个回合），确认后给出"已停止、可重新开启"的反馈
- [P1] 讨论进行中缺少进度反馈：没有"当前阶段/当前轮到谁/剩余预算"的可视化，`.pc-notice` 与普通消息外观几乎一样 | priv/web/project-chat.js:130,147；priv/web/style.css:4063,4069 | 代码：进行中只有一行状态文本 + 一条 notice；`.pc-kind-notice` 与 `.pc-notice` 仅靠 3px 左描边区分 | 状态行加阶段步骤条（独立评估 → 交叉讨论 → 整理决议），进行中在头部加呼吸/旋转指示
- [P2] 已停止的议题仍可再次「召集讨论」（`status not in @active` 即允许），界面没有"重开"表达，会静默重开 | lib/newbee/collaboration/chat/room.ex:358-362 | 代码：`true <- topic["status"] not in @active` 即可启动 | 对 stopped 议题显示"重新开启讨论"并确认

### F. 窄屏 390px

- [P1] 390px 下议题栏高度固定 130px，而长标题议题按钮单高约 97px，内容溢出被裁/需内部滚动才能看全 | priv/web/style.css:4084,4036 | 实测 390×844：`.pc-topics` clientH 129 < scrollH 154，议题按钮高 97px，`nav` scrollW 466 > clientW 359（shots/03-topic-390.png） | 窄屏议题项改为单行截断 + 横向滚动，或把状态移到第二行小字
- [P1] 390px 下输入区占 262px（@选择器 54px、文本域 81px、身份选择 + 发送），消息区只剩 155px 高；「常驻代表」整块被推到视口外 | priv/web/style.css:4050-4052,4064,4084-4088 | 实测：`.pc-compose` h=262、`.pc-messages` h=155、`.pc-sidebar` y=857（视口 844）（shots/03-topic-390.png） | 窄屏把 @选择器折叠为"@"按钮、代表列表改为抽屉/底部弹层，消息区 `flex:1` 且最小 40dvh

### G. 键盘与焦点

- [P1] 弹窗打开时全局 Escape 仍会中断主会话：`inInput` 只判断主面板三个输入框，且 `preventDefault()` 会阻止原生 dialog 的 cancel → Esc 关不掉聊天室，反而打断后台 AI | priv/web/app.js:7834-7840；priv/web/project-chat.js:200-210（无 cancel/close 前拦截） | 代码：`const inInput = document.activeElement === $("input") \|\| ...`（app.js:7834）；`if (e.key === "Escape" && state.busy && !inInput) { e.preventDefault(); interrupt(); }`（app.js:7837-7840） | 快捷键入口先判断是否存在打开的模态（`document.querySelector("dialog[open]")`）并直接返回
- [P2] 弹窗打开时 Ctrl+M / Ctrl+N / Ctrl+1..4 等全局快捷键仍生效，会在模态下面切换 Mission Control、新建会话 | priv/web/app.js:7842-7868 | 代码：这些分支没有模态判断（对比 app.js:3367 的 `xPopupKey` 是显式处理的） | 模态打开时统一挂起全局快捷键
- [P1] 消息区 `role="log"` 却每次 render 全量 `replaceChildren` 重建，屏幕阅读器会把整段对话重复播报 | priv/web/project-chat.js:133,194,220 | 代码：`s.messages.replaceChildren()` 后逐条重建（:133），poll 每 2s 可能触发（:194-199）；`role="log"` 自带 polite live 语义（:220） | 按 seq 增量追加，只对最新一条使用 aria-live
- [P2] 「@all」的开关不可见也不可达：真正的 checkbox 从未插入 DOM（className 也未生效），按钮没有 aria-pressed，状态只体现在一行灰字 | priv/web/project-chat.js:175,224-225,234 | live DOM：对话框内 checkbox 仅 4 个代表 + 1 个"自动会诊"，`.pc-mention-all` 查询结果为 null；CSS 中亦无 `.pc-mention-all` 规则 | 改成带 aria-pressed 的切换按钮并显示选中态

### H. 三主题一致性

- [P1] 拟物主题下"人类消息"与普通消息底色对比度仅 1.05:1，只剩 20px 缩进可区分；浅色/深色主题靠蓝色气泡区分 | priv/web/style.css:4044,3569-3575 | 计算：neumorphic `--nb-bubble #e9eaee`(3572) vs `--nb-bg-elev #e3e5ea`(3570) = 1.05:1；浅色 1.02 但有蓝色相差，深色 1.20 且有蓝色相差；实测四主题截图 shots/04-theme-*.png | 拟物主题为人类消息引入独立 token（描边/左侧色条/更明显的底色差）
- [P2] 拟物深色下人类消息比普通消息更"下沉"（#21242a vs #2e323a，1.21:1），与深色主题"更亮"的方向相反；选中态同理（#21242a vs 面板 #282c33 = 1.11:1） | priv/web/style.css:4044,4029,3582-3588 | 计算值 + shots/04-theme-neumorphic-dark.png | 选中态/人类消息统一为"高亮"方向，复用同一组 token 语义
- [P2] 遮罩颜色硬编码 `#0008`，在浅色拟物下显得过重、与拟物质感不符 | priv/web/style.css:4019 | 代码：`.pc-dialog::backdrop { background: #0008; }`（`.pc-*` 段唯一硬编码颜色） | 改用主题变量（如 `color-mix` 或 `--nb-backdrop`）

## 改动清单（按实现优先级）

| 顺序 | 改动 | 文件 | 工作量 |
| --- | --- | --- | --- |
| 1 | 人类等待回合：聚合视图渲染等待卡 + 无议题时禁止/引导回复（D1）；倒计时独立 1s 刷新（D2） | priv/web/project-chat.js | M（约 0.5 天） |
| 2 | 「停止讨论」危险样式 + 二次确认（含将取消的回合数）（E1）；「提供给执行任务」二次确认（B2） | priv/web/project-chat.js、priv/web/style.css | S（约 0.3 天） |
| 3 | 快捷键模态隔离：Esc/全局快捷键在 `dialog[open]` 时挂起（G1、G2） | priv/web/app.js | S（约 0.2 天） |
| 4 | 消息流归属与层级：聚合视图议题 chip（C1）、引用回复渲染人名+摘要（C2）、错误消息重试入口（C3）、`deviceName` 补 system 分支（C4） | priv/web/project-chat.js | M（约 0.5 天） |
| 5 | 窄屏 390px：议题栏单行截断、@选择器折叠、代表列表抽屉、消息区最小高度（F1、F2） | priv/web/style.css、priv/web/project-chat.js | M（约 0.5 天） |
| 6 | 三主题 token：人类消息/选中态独立 token，修正拟物深色方向，遮罩变量化（H1、H2、H3） | priv/web/style.css | S（约 0.3 天） |
| 7 | 无障碍：消息列表增量渲染（G3）、@all 改为 aria-pressed 切换（G4）、跳过徽标（C5） | priv/web/project-chat.js、priv/web/style.css | M（约 0.5 天） |
| 8 | 首次引导与术语：禁用原因说明、三步引导、状态行文案、术语统一（A1、A2、B1、B3、B4） | priv/web/project-chat.js | M（约 0.5 天） |
| 9 | 打磨项：关闭提示后台继续（A3）、停止后"重新开启"文案（E3）、时间戳补日期（C6） | priv/web/project-chat.js | S（约 0.2 天） |

> 说明：以上均为只读审计结论；除本报告与 `shots/` 截图外，未改动任何 `priv/`、`lib/` 文件与预览数据。
