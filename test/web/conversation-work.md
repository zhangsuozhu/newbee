# 原会话工作卡前端（v0.4）— 集成说明与定向测试

文件：

- `priv/web/conversation-work.js` — 组件实现，导出 `window.NewbeeConversationWork`。
- `priv/web/conversation-work.css` — 卡片样式，只引用 `style.css` 已有的主题变量（`--nb-*`），四种主题自动跟随。
- `test/web/conversation-work.test.js` — 定向测试（`node:test`，无需浏览器或 Elixir 服务）。
- `test/web/conversation_work_dom.js` — 测试用的极简 DOM 替身（无 `innerHTML`，缺 API 就报错）。

运行测试：

```bash
node --test test/web/conversation-work.test.js
```

## 组件契约

```js
const work = window.NewbeeConversationWork.init({
  rpc,            // (method, payload) => Promise<any>，复用 app.js 的 rpc（POST /api/<method>）
  getSessionId,   // () => 当前会话 id；空串/null 时组件不发任何请求
  getDirectory,   // () => 会话目录，仅作为展示回退，不参与 root 判定
  notify,         // (text, kind) => void，可选的宿主提示
  readDraft,      // () => 输入框当前文本（「后台做」用它作为目标）
  writeDraft,     // (text) => void，成功后清空草稿
  appendUser,     // (text) => void，在会话里回显这条用户消息
  getUploadIds,   // 可选，() => string[]，把当前附件随 start 一起带上
});

work.refresh();                       // 主动刷新，返回 work[]
await work.submit(text, uploadIds);    // 只有“当前有后台工作”时返回 true
work.destroy();                       // 取消轮询、移除卡片
work.peek();                          // 只读诊断（会话、work 概览），供集成/测试
```

## 主 send hook（Lead 集成）

```js
const handled = window.NewbeeConversationWork
  ? await window.NewbeeConversationWork.submit(draft, uploadIds)
  : false;
if (!handled) {
  // 走原来的普通发送；普通对话不被接管
}
```

要点：

- `submit` 只在存在“当前后台工作”（`queued/running/blocked/pending_review` 且阶段未结束、且属于本会话）时接管输入，
  把这句补充作为 `conversation.work.input` 发出；其余一律返回 `false`。
- 失败时组件不清草稿、不假装已发送，会抛出错误并在卡内给出可见提示；主 send 应把错误展示给用户，而不是静默吞掉。
- `conversation.work.start`（「后台做」按钮）读取草稿、携带 `uploadIds`，成功后自动清草稿并回显；
  客户端**不传 `root`**，工作目录由服务端会话校验。

## 契约要点（与后端一致）

| 方法 | payload | 返回 |
| --- | --- | --- |
| `conversation.work.list` | `{sessionId}` | `{works:[work]}` |
| `conversation.work.start` | `{sessionId,text,requestId,uploadIds?}` | `{work,receipt?}` |
| `conversation.work.input` | `{sessionId,workId,text,requestId,uploadIds?}` | `{work,receipt?}` |
| `conversation.work.answer` | `{sessionId,workId,questionId,text?|value?}` | `{work,receipt?}` |
| `conversation.work.control` | `{sessionId,workId,action:pause\|resume\|stop\|retry}` | `{work,receipt?}` |
| `conversation.work.review` | `{sessionId,workId}` | `{review:{patch_sha256,files,target_root,summary,conflicts}}` |
| `conversation.work.apply` | `{sessionId,workId,patchSha256,requestId}` | `{work,receipt?}` |
| `conversation.work.complete` | `{sessionId,workId,requestId}` | `{work,receipt?}` |

- `sessionId` 由组件最后写入：payload 里的同名字段不能覆盖它。
- `start`/`input`/`apply`/`complete` 的 `requestId` 稳定：同一工作、同一段文字（同一哈希）失败重试复用同一 ID，
  只有服务端明确成功后才释放，避免重复建单或重复写入。`control`/`answer` 用工作与问题 id 天然幂等，不带 requestId。
- `work` 字段按后端 snake_case 读取；缺失字段用中性文案，不显示臆造的进度百分比。
- `work.inputs` 是可选字段：只有服务端返回的状态（`received/adopted/...`）才会写成“已收到/已采用”；
  本端刚送出的补充显示为“本会话已送出 N 条，服务端暂未回报状态”，不冒充已采用。
- `receipt` 形状兼容字符串与 `{text,state}`；缺失时不虚报状态（`apply` 只有拿到 `applied` 才显示“已应用”）。

## 行为约束

1. **不接管普通对话**：没有（属于本会话的）后台工作时 `submit` 返回 `false`，不产生任何 RPC。
2. **不切执行 Session**：卡片只在本会话渲染与操作，不跳转 `task.session_id`；别会话的工作只读展示并注明归属。
3. **安全渲染**：全程 `textContent`，用户文本、标题、文件路径、diff 片段都不会被解析成标记。
4. **有界轮询**：`4s`（有活动工作）/`15s`（空闲），失败指数退避到 15s；`document.hidden` 时停止，回到前台立即刷新。
5. **旧响应作废**：每次请求带 `{generation, session}` 标记，会话切换或 `destroy` 后旧响应直接丢弃。
6. **结束 != 撤回**：`stop` 先要一次确认，回执固定说明“已有修改和历史保留，结束不表示撤回”。
7. **采用前双核对**：`apply` 先 `refresh` 比对 `revision/context_revision`，再重新 `review` 比对 `patch_sha256`；
   任一不一致或存在 `conflicts` 就停止，不写目标文件，并提示“重新比较”。
8. **已应用 vs 未应用**：独立工作区结果区分“尚未写入项目”“已应用”“已应用，检查待完成”“目标已变化”。
9. **可访问性**：按钮有 `title`/`aria-label`，状态用 `role=status` + `aria-live`，焦点在重渲染后回到原控件；
   输入法 composing 期间的 Enter 不提交，多行答案用 `Ctrl/⌘+Enter`；手机主动作 ≥44px。

## 测试覆盖（22 项）

源码契约（导出名/RPC 名/无 `innerHTML`/主题变量）、无会话不发请求、文本渲染不注入、
已收到/已采用只来自服务端、`submit` 普通对话返回 `false`、补充带稳定 `requestId` 且失败重试复用、
原地答复（`questionId` + `value/text`，composing Enter 不误发）、暂停/结束回执与二次确认、
review/apply 哈希与版本核对、冲突不覆盖、切换会话丢弃旧响应、隐藏不轮询、
start 失败保留草稿、apply 版本变化即停止、destroy 停止轮询、
多工作时优先本会话自己的工作且别的工作只读、只有别会话工作时普通发送不被接管、
轮询重渲染不清空正在写的答案且焦点回到原输入框、卡片挂在 `#main` 内输入区之前且刷新不重建、
进行中的真实活动可展开且不被写成结果、完整故事（后台做→答复→待审阅→应用→已应用）走通、
回执三种形状都不崩且不虚报、没有 `applied` 状态时不显示“已应用”。

未覆盖：真实浏览器布局/触摸手势、真实后端 RPC 端到端（后端按同一契约实现后需联调）、
`work.inputs` 缺失时“已采用”只能等后端补字段。

## 已知取舍

- 组件不订阅事件流；`init` 后按上表间隔轮询，属于设计内的临时方案。
- 卡片插入位置依赖 `#main` / `#composer` 两个既有 id；缺 `#main` 时退到 `document.body`，不会让页面报错。
- `getDirectory()` 只作展示回退，`root` 始终由服务端会话决定。

## 进度条：为什么原来永远“不结束”（v0.6）

现场证据：`conversation.work.list` 对某条工作返回 `coordination: {total: 2, completed: 0, phase: "ended"}`，
两个子项的 `status` 都是 `cancelled`。卡片按 `completed` 渲染，于是长期停在 `0/2`——
用户看到的进度条永远没有结束。

根因在后端 `Decomposition.view/1`：`completed` 只数 `pending_review | done`（还要成果版本匹配），
被取消、失败的分项永远不计入，而 `phase` 已经是 `ended`。

修法：**不改变 `completed` 语义**（依赖调度仍只用它），新增三个只读字段：

| 字段 | 含义 |
| --- | --- |
| `settled` | 不再推进的分项数：交付、失败、取消都算 |
| `failed` | `failed` 的分项数 |
| `cancelled` | `cancelled` 的分项数 |

前端据此渲染真正的进度条（`role="progressbar"` + `aria-valuenow/max/valuetext`），
进度按 `settled/total` 走，并区分三种收尾语义：

- 全部**交付** → `data-tone="done"`，实心绿，文案「N/N 项 · 已完成」。
- 已结束但没全交付 → `data-tone="stop"`，条纹灰，文案带「取消 N / 未完成 N · 已结束」。
- 有失败 → `data-tone="err"`，红色。

“收尾”不等于“成功”：取消也会让进度走满 100%，但绝不用成功色，避免谎报。
老后端没有 `settled` 字段时，前端按子项状态自算，不会退回 0/N。

## 视觉对齐（v0.6）

用户反馈「样子和其它窗口不一致」。实测对比后改了三处：

| 位置 | 之前 | 现在 | 依据 |
| --- | --- | --- | --- |
| 卡片圆角 | 6px | 14px | 同列 `.msg-assistant` / `.msg-boxed` / `.msg-tool` 都是 14px |
| 窗口/动作按钮圆角 | 6px / 999px 胶囊 | 8px | 站内 `.btn-*`、`.icon-btn` 统一 `--ui-r-sm` |
| 按钮高度 | 28px 自定 | `--ui-h-sm`(26) | 站内按钮四档 |
| 阴影 | 硬编码黑色投影 | 主题变量 | 拟物主题用 `--nb-neu-*`，其它主题无投影 |

另外补齐拟物主题材质：卡片凸起、按钮凸起/按下内嵌、进度条与分项卡内嵌，
与 `.collab-task`、`.terminal-panel` 等既有面板同一套 `--nb-neu-*` 变量。
## 输出窗口：放大 / 缩放 / 最小化（v0.5）

工作卡按窗口使用，解决三件原本做不到的事：

| 能力 | 操作 | 落点 |
| --- | --- | --- |
| 放大 | 标题栏 ⛶ | `data-mode="maximized"`，铺满可视区；再点还原 |
| 最小化 | 标题栏 − | `data-mode="minimized"`，只留标题栏（手机约占 7% 屏高） |
| 缩放 | 拖上边缘、`↑↓`（Shift 加大步长）、`Home/End`、双击复位 | `--cw-h` + `data-sized="1"` |

结构约束（回归测试覆盖，不要退回）：

- 标题栏 `.cw-head` 与窗口控件**不属于**滚动容器；正文在 `.cw-scroll` 里独立滚动。
  控件被放进滚动区时，长内容一滚就点不到，“功能不可用”正是这样来的。
- `.cw-card` 自身 `overflow: hidden` 且不滚动，`scrollTop` 必须恒为 0。
- `[data-sized="1"]` 必须**同时**解除 `max-height`，否则拖动超过默认上限会被 clamp 回去，
  表现为“怎么拖都不变高”。
- 默认高度紧凑：桌面 `min(42vh, 380px)`、手机 `min(46dvh, 360px)`；会话流必须仍然读得到。
- 窗口状态（模式 + 高度）存 `localStorage["newbee.workcard.window"]`，刷新与重新 init 后保持。

## 比较/应用的可用性门禁

服务端 `WorkspaceReview.reviewable/1` 只在 `pending_review` 时接受比较与应用。前端此前对
`isolated && apply_state != applied` 一律渲染「比较改动」，于是**已结束或仍在推进**的工作上
必然点出 4xx——“有的功能不可用”的直接来源。

现在 `reviewable(work)` 与后端条件对齐（`isolated && apply_state != applied &&
status == pending_review && stage == needs_review`）；不满足时不出按钮，改为说明原因：

- 已结束：结果保留在独立工作区、尚未写入项目，服务端不再接受比较或应用。
- 仍在推进：等结果准备好（状态变成「等待查看」）才开放。

## 测试覆盖（40 项）

在上述 22 项之外新增 8 项窗口/门禁用例：

窗口控件在标题栏内且内容区独立滚动、最小化只留标题栏并可还原、放大与最小化互斥不互相踩、
拖动上边缘改高度用 CSS 变量、双击复位、键盘 `↑↓/Home/End` 调高度、
窗口大小跨刷新与重建保留、已结束/推进中不出「比较改动」且给出原因、等待查看仍能比较与应用。

测试替身 `test/web/conversation_work_dom.js` 相应补齐 `classList.toggle`、`style.setProperty/removeProperty`、
`Document.dispatch(type, event)` 事件载荷与 `localStorage/sessionStorage` 替身——缺这些就测不出窗口行为。

真实浏览器实测（Chromium，1280×720 与 390×844）：

- 长内容滚动 2245px 后 `elementFromPoint` 仍命中放大按钮，卡片 `scrollTop` 为 0，无横向溢出。
- 拖动 200px → 高度恰好 +200px（修复 clamp 前只 +120px 就被夹住）。
- 手机默认 360px、最小化 58px（7% 屏高），放大精确等于视口且无横向溢出。
- 线上那条已结束的工作：不再渲染「比较改动」。

仍未覆盖：Safari/Firefox、真机触摸拖拽、屏幕阅读器朗读窗口状态。
