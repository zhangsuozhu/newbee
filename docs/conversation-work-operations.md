# 原会话协作：运行、使用与验收

当前直接任务入口见[输入任务与自动分工](conversation-task-execution.md)：在原对话输入目标，点击「分工执行」，系统拆分、分派、执行与集成。无需 GitHub 或评论桥接。下文的来源接入属于旧版可选兼容功能，已撤出主工作入口。

本页同时保留 v0.4 的工程记录。主入口仍为 `/` 原会话；使用现有登录、模型配置、项目目录和附件。所有新增功能在本分支工作区实现，不需要新建蜂群或邀请成员。

## 日常操作

1. **普通问答与当前项目修改**：正常输入并发送，沿用原 Session 行为。没有后台工作时，普通聊天不会创建 Colony Task、要求验收或接管发送框。
2. **交给后台**：选定原会话项目，写好目标，点输入区附近的「后台做」；明确以「后台做：…」「交给后台：…」发起，或以「…在后台做」结束的请求也走同一入口。服务端固定项目根、模型/厂家/思考配置与原会话，创建独立工作区和持久化工作；网络重试复用请求 ID。已经有前台执行者正在运行时不会复制其上下文另开执行者，先等待该轮停止再发起。
3. **补充要求**：当前工作期间直接在原输入框发送；收到后显示接收事实，执行者在模型请求边界读取后才显示采用。展开历史工作仅查看，不改变当前输入目标。独立工作用现有「新对话」。
4. **回答问题**：点当前问题选项、就地写答案，或在主输入框回答。答复绑定当前问题 ID；旧问题、重复答复和其他会话的答复不能驱动执行。答复和补充都不解除暂停。
5. **暂停与结束**：卡片上暂停；收到实际停止确认前显示暂停中。恢复前核对旧执行者不再运行，保留目标/已有修改并更新执行代次；旧代次完成事件失效。执行回执不明时只保存补话，检查后再恢复。结束保留已有文件效果，不表示撤回。
6. **查看与采用**：结果回原会话，可展开过程/验证/限制。独立代码成果先「比较改动」，核对目标和差异，再「应用并完成」。目标或候选版本变化时拒绝覆盖。应用成功才允许验收完成；回执不明时核对实际文件指纹，不重复覆盖。没有文件变化的分析成果在比较后「确认完成」。
7. **离开再回来**：网页关闭不取消工作。刷新后工作、输入、问题和成果由服务端重建；后台请求与成果合并进原会话历史。列表以后台事实补全标题、消息数和时间，执行 Session 留在后台；有工作的原会话不会被空会话清扫回收。待办定位回原对话。

界面只保留一个当前后台工作；主会话没有后台工作时只显示轻量入口。工作卡有最大高度和内部滚动，避免手机输入框被挤出屏幕。

## 启用和运行

按仓库现有方式启动 newbee Web。`Newbee.Colony.Store` 保存权威事实；`Newbee.Colony.Runtime` 派发真实执行；新增 `SourceRuntime` 只负责来源回帖意图的有界发送。无需额外数据库、外部 Worker 服务或 npm 构建步骤。


从实现所在的仓库工作区启动：

```sh
./bin/newbee web --port 4174
```

浏览器打开 `http://127.0.0.1:4174/`，沿用现有登录与模型配置。先选择项目目录，再输入目标并点「后台做」。端口可自行更换；源项目中已有改动会成为隔离工作的基线，最终应用仍需通过差异核对。
同一数据目录保持一个 newbee 进程。若原实例还在运行，可在此工作区使用独立试用数据目录启动，不与原实例争写快照：

```sh
mix run --no-start -e 'Application.put_env(:newbee, :global_root_override, Path.expand(".newbee-trial")); Mix.Task.run("newbee.web", ["--port", "4174"])'
```

试用实例的对话、认证和蜂群状态位于当前工作区的 `.newbee-trial`；模型文件仍按既有 `NEWBEE_MODEL_JSON` / `model.json` / `~/.newbee/model.json` 规则读取。试用时先选择要操作的项目目录。



- 生产默认启用 `:newbee, :colony_background`；测试环境关闭自动派发，按需驱动 `Runtime.sweep/0`。
- Store schema 从 v1/v2 兼容升级为 v3，保留原文件的 `.v1-backup` / `.v2-backup`。新回执、来源事件及回复意图与任务放在同一快照事务中。原有 Task/Honey/成员保持兼容。
- 授权事实和回执落盘成功后才答复受理；磁盘失败不创建部分 Task/Colony/Delivery。Store 事务内不运行模型、Session、网络或文件应用。
- 这一个域明确使用 Colony 快照作为同步权威，不声称已经改成 EventStore Event Sourcing。会话历史/索引是可重建的投影，不能反向驱动自动工作。
- 工作区应用不 commit、不 push、不改 Git index，支持普通目录与含未提交/未跟踪文件的 Git 项目。

## 可选来源

旧版来源页面仍可通过 `/sources.html?session=<原会话>` 访问，已不在直接任务主流程显示。只允许宿主管理员配置，项目根取当前会话；客户端不能指定任意执行路径。

来源默认 `observe`，只保留事件和「本来会创建/补充什么」；实际看过事件后再保存 `explicit` 或有范围的 `auto`。设置允许交办的真人用户名、每小时新工作数、冷却间隔、暂停开关。自动规则必须明确事件类型与正文前缀，不进行无界模型推断。已有授权工作上的真人跟进留在同一工作，机器人和普通未归属讨论不产生执行授权。

### GitHub Issue / 评论

1. 在宿主环境配置独立的 Webhook secret 和 GitHub 令牌，页面只填写环境变量名称。Webhook secret 至少 16 字节；令牌仅需目标仓库所需的 Issue 评论权限。
2. 来源类型选 GitHub，填写 `owner/repo`、允许的用户名，先用观察模式保存。
3. 在 GitHub 配置 Webhook URL 为设置页给出的 `/hooks/github/<source-id>`，Content type 为 `application/json`，绑定相同 secret；选择 Issues、Issue comments 事件。
4. 查看本页记录确认仓库、线程、作者和路由。启用明确交办后，以 `@newbee …` 或 `/newbee …` 发起；工作绑定后，同线程允许的真人可以自然补充或回答。
5. 问题和成果以同一 Issue 评论线程交付。来源回帖失败只影响沟通状态，不把已完成任务改回执行中；使用退避重试。每个回帖有稳定 HTML marker，发送前先查已有评论，降低回执丢失导致的重复。不能声称网络严格至多一次；超过核对窗口时保留失败，不盲目发送。

每个有效签名事件，包括范围外过滤，均在成功响应前保存去重回执。同 ID 不同内容拒绝，编辑事件应使用新的外部 delivery ID。错误签名不受理。来源配置支持暂停，观察/预算拦截的事件可按当前策略重放；已受理事件不再建重复工作。来源暂停不自动撤销原来已授权的工作，正在执行的工作在原会话控制。

### 受控本地桥接

选择 `local` 后，宿主可用 `conversation.source.ingest` RPC 传规范化事件：`sourceId` 与 `event:{id,thread,actor,text,event_type,explicit,machine}`。调用必须带宿主认证。调用方提供的 colony/actor 权限字段不生效；处理身份来自保存的来源配置。外部 GitHub 事件不能借这个 RPC 绕过签名。

主要管理 RPC：`conversation.source.list/configure/events/replay`。工作 RPC：`conversation.work.list/start/input/answer/control/review/apply/complete`，全部带 `sessionId`，写入动作校验原会话与工作发起者权限。

## 验证方式

```sh
MIX_ENV=test mix compile --warnings-as-errors
MIX_ENV=test mix test test/newbee/colony test/newbee/web test/newbee/collaboration/workspace_test.exs test/newbee/dee/eval_safety_test.exs
node --check priv/web/app.js
node --check priv/web/sources.js
node --test test/web/conversation-work.test.js
```

特定证据：

- `conversation_work_test.exs` 覆盖并发幂等、问题身份、落盘失败、接收/采用、恢复代次、原对话隔离、后续工作和旧快照迁移。
- `workspace_review_test.exs` 覆盖普通/Git 脏基线、新增/修改/删除、完整 hash、目标冲突、符号链接/路径逃逸、可执行位、过期成果、重复应用和回执核对。
- `source_test.exs` 覆盖默认观察、允许作者、机器人边界、去重、预算、回放、Webhook 原始字节签名和回帖故障。
- `conversation_api_test.exs` 通过真实 HTTP 完成独立文件审阅、应用、最终验收、重试，检查跨会话拒绝和用户新修改不被覆盖。
- `conversation_execution_test.exs` 经真实 Runtime → Session → Loop → 本地模型 HTTP 替身生成当前版本成果，验证执行目录隔离和模型继承；测试没有替代真实模型质量评估。
- Node 测试覆盖工作卡状态、请求 ID、补充/问答、冲突应用、切会话、页面可见性、草稿和附件回执。

可复现的浏览器夹具：

```sh
MIX_ENV=test mix run --no-start test/support/conversation_browser.exs
```

地址和临时项目根写入 `.newbee-tmp/conversation-browser.json`。此夹具仅绑定回环地址，禁用自动派发；`/__fixture/question`、`/__fixture/ready` 构造确定状态，走真实主页面、RPC、Store 和文件应用，不接真实模型。它是测试程序，不挂载到生产 Router。

## 支持边界

- 首版支持**从明确请求开始隔离后台工作**。不对正在运行的前台 turn 做无条件迁移；前台修改仍沿用原 Session 目录语义。
- 自动协作复用现有 Workflow，明确授权实施的原会话工作在内部提案/互评后由负责人推进，不让用户选 Bee/填分工。业务决定仍原地问人。
- 故障恢复优先保留事实；多文件应用中断后若只完成一部分，会进入未知状态并给文件级诊断，不盲目继续覆盖。单节点目录锁不约束用户编辑器或外部主机；写入前重新检查真实文件，仍不能证明操作系统级跨进程事务隔离。
- 部分恢复判断使用内容与权限指纹。人手动恰好改回基线、或改成与候选完全相同的内容，不能仅凭指纹区分意图；不提供无条件强制覆盖。
- 尚未进行真实 GitHub 租户回帖演练、真实模型质量对比和用户持续采用试点，不能把协议/浏览器测试当成这些结果。飞书、CI 轮询和运行中跨目录迁移不是本版已启用的适配器。

对应设计：[操作设计](superagent-conversation-ux.md)、[后台融合设计](superagent-colony-integration-design.md)。

## 本工作区验收记录

以下为真实命令/浏览器结果，范围为本次受影响的系统，不代表整个仓库所有测试均已运行。

| 检查 | 结果 | 方法与证据 |
| --- | --- | --- |
| 相关 Elixir 广域回归 | 502 项通过，默认排除 2 项节点测试 | 蜂群、全部 Web、Workspace、求值安全与会话索引；随机种子 `719728`；`.newbee-tmp/conversation-verified-suite.log` |
| 节点故障补测 | 2 项通过 | `mix test test/newbee/dee/eval_safety_test.exs test/newbee/web/session_new_test.exs --only node --include node`；验证节点死亡不重放和异步执行器存活；`.newbee-tmp/conversation-node-recovery.log` |
| 原失败顺序复测 | 111 项通过 | 随机种子 `331892`；`.newbee-tmp/conversation-receipt-regression.log` |
| 前端行为 | 26 项通过 | `node --test test/web/conversation-work.test.js`；`.newbee-tmp/conversation-final-node.log` |
| 编译与格式 | 通过 | `dev` / `test` 均使用 `mix compile --warnings-as-errors`；27 个修改/新增 Elixir 文件 `mix format --check-formatted`；`git diff --check`；新增脚本和主脚本语法检查 |
| 真实主页面 | 通过 | Chromium、390×844；启动/补充/问题答复/比较/真实文件应用/刷新恢复；输入区底部为 844px、工作卡 287px；截图 `.newbee-tmp/conversation-mobile-applied.png` |
| 来源设置页面 | 通过 | 390px 下无横向溢出；观察只记录，保存明确交办策略后同一事件重放为 owned；原会话返回链接保持一致 |
| 真实执行协议 | 通过 | 实际 Runtime → Session → Loop → 本地 HTTP 模型替身；先缺凭据阻塞，修复后同一工作恢复，未消费附件保留，最终生成当前版本成果 |

收尾发现并修复了一个实际竞争：Session 的状态查询超过调用等待时间时，派发器原来会把已有持久接收记录误标为未知，随后过滤合法成果。现在暂时查询超时保留已受理记录，不重新发送；真正查无回执仍阻塞。未知状态转换在同一 Store 事务内校验当前代次和任务状态，避免迟到故障覆盖新成果。新增慢查询与真实回执丢失两项确定性测试均通过。

真实模型完成质量、真实 GitHub 租户回帖和用户持续采用收益仍未实测。测试服务和浏览器夹具已停止；保留最终日志与截图供复核。


## 主实例热更新记录

本版已经热更新到现有 `newbee_web_5151` 实例，使用原来的 HTTPS 地址；刷新浏览器即可加载「后台做」、工作卡及来源设置。线上当前正在运行的 turn 保留原执行过程，后续回合使用更新后的逻辑。

- 41 个功能、前端、测试和文档文件已同步到主工作区；保留原有 `lib/newbee/llm/client.ex` 和 `test/newbee/llm/complete_error_test.exs` 修改，文件 SHA-256 及在线客户端模块指纹未改变。
- 安全加载 19 个功能模块，线上指纹与主区编译产物逐项一致；没有硬清除正在运行的旧代码，也没有重启 Web。
- Store 从 v2 迁移为 v3，原 Store PID 不变；磁盘保存 v3，原 v2 快照另存 `.v2-backup`。新增 SourceRuntime 已纳入现有监督树。
- 12 个原会话及原有 Supervisor/Store/Runtime/Remote/HotReloader PID 均保持不变；自动热加载监控已恢复运行。
- 线上 HTTPS 的 7 份前端资源与部署文件字节一致，返回 `no-store`；带认证的工作列表、来源列表、会话历史均返回 200，无认证访问仍为 401。
- 主区叠加现有客户端修改后，`dev` / `test` 零警告编译通过；针对性兼容回归 24 项和前端 26 项通过。

部署前备份位于实现工作区 `.newbee-tmp/hotupdate-v04-before/`；线上验证记录为 `.newbee-tmp/hotupdate-v04-live.json`，编译及回归日志为 `.newbee-tmp/hotupdate-v04-{compile,compat,node}.log`。没有执行 Git 提交、合并或推送。
