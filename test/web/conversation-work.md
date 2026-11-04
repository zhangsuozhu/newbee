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
