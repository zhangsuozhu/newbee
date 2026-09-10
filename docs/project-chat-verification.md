# 项目聊天室交付验证

实现基于 `a76202801d57be637994eba06329b561484414c2`，位于会话专属工作树 `.newbee/worktrees/project-chat-20260910`。没有提交、推送或合并到main。测试服务已停止，测试数据与证书在工作树的 `.newbee/chat-checks/` 下，不进入源码提交。

## 已跑通的流程

- 项目群入口 → 添加一台主机的多位代表 → 创建关联任务的议题 → 独立提交 → 交叉讨论 → 决议草案 → 提供给任务上下文 → 人类继续发言。
- 代表名字、风格和关注方向持久化；单机多位代表具有不同ID，不能冒用另一设备拥有的代表。
- 独立草稿跨重启仍保持隐藏；作业领取、重复结果、超时、停止和空模型回复有明确终态。
- 决议应用校验版本、任务范围、任务设备权限和代码基线。执行上下文仅对分配到该会话的未结束任务生成；工作区存在未验证修改时标为基线不匹配。任务结束回帖不会将“讨论通过”伪装成测试验证。

## 构建与自动测试

| 检查 | 结果 | 说明 |
|---|---|---|
| `mix compile --warnings-as-errors` | 通过 | 开发环境严格编译 |
| `MIX_ENV=test mix compile --warnings-as-errors` | 通过 | 测试环境严格编译 |
| 所有改动Elixir文件的 `mix format --check-formatted` | 通过 | 包括新增测试 |
| `git diff --check` | 通过 | 无尾随空格/新增EOF空行 |
| `bun build priv/web/project-chat.js` | 通过 | JavaScript语法与打包检查 |
| 协作与Web目录整组回归 | 292通过，1排除 | 集成阶段运行；随后模型兼容修复再次进行下述定向检查 |
| 聊天交付定向检查 | 33通过 | 聊天生命周期、Web/真实HTTP模型协议、4xx错误、共享上下文、工具合同 |
| 续写缓存与维护评估专项检查 | 21通过 | 包含新加入的确定性缓存隔离回归 |
| 收尾后的完整相关组合 | 两轮均106通过 | 分别使用此前失败的种子40410、851020；没有排除上述失败用例 |

聊天定向33项检查命令：

```sh
mix test test/newbee/collaboration/chat_test.exs \
  test/newbee/web/project_chat_test.exs \
  test/newbee/llm/complete_error_test.exs \
  test/newbee/collaboration/shared_context_test.exs \
  test/newbee/environment/tool_contract_test.exs
```

初次交付的105项组合检查曾分别在 `ResponsesTest` 和 `AdapterMaintenanceTest` 中出现失败。继续收尾时修复了两处测试基础设施问题：

- Responses的默认测试能力缓存原来写入所有测试VM共用的 `/tmp/newbee-test-caps`。模型名中的 `System.unique_integer` 只保证VM内唯一，新VM可能读取此前留下的能力降级记录。现改用当前测试VM的独立GlobalStore目录；新增路径隔离用例在修复前明确失败、修复后通过。涉及 `NEWBEE_HOME` 的测试模块改为串行，并恢复调用前的环境变量值，避免污染并行或后续测试。生产环境的缓存位置保持原有规则。
- Adapter维护用例此前最多轮询200次、每次20毫秒，然后即使评估尚未完成也返回状态。现先订阅总线，等待当前Change的 `change_evaluated` 完成事件（有30秒上限），再检查真实状态仍为 `canary`，并保留原有证据断言。

加入隔离回归后，相关组合共有106项。使用两个历史失败种子重跑，两轮均全部通过：种子40410用时42.1秒，种子851020用时50.0秒。这是相关组合的结果，不代表运行过全仓库所有测试。

```sh
mix test test/newbee/collaboration/chat_test.exs \
  test/newbee/web/project_chat_test.exs \
  test/newbee/llm test/newbee/agent \
  test/newbee/environment/tool_contract_test.exs --seed 40410
# 同一组合另以 --seed 851020 验证
```

收尾记录：`.newbee/chat-checks/cache-isolation-before.log`、`isolation-event-after.log`、`continued-regression-40410.log`、`continued-regression-851020.log`。开发/测试环境严格编译、改动文件格式和补丁检查也再次通过。


## 跨进程与真实模型

### 两个独立BEAM进程

实际启动Hub和Worker两个独立进程、使用独立存储目录，经HTTPS服务器证书SHA-256钉选连接；Worker通过真实轮询接口领到自己的工作项并回传。

结果：3位代表，2个实际回应设备身份，7条代表消息，议题达到 `proposed`。此验证使用本地受控模型协议端点，验证的是跨进程、认证、传输、调度和状态流转，不是模型推理质量。它没有替代两台物理主机上的生产部署测试。

记录：`.newbee/chat-checks/tls-result.json`、`tls-worker.log`。

### 外部真实模型调用

在已有配置的 `deepseek / deepseek-v4-flash` 上运行两位代表、一轮交叉讨论和一次总结。

- 实际模型调用：5次。
- 公开代表回复：5条，错误消息0条。
- 最终状态：`proposed`，仍为待验证建议。
- 端到端时间：27.031秒。
- 提供方返回用量：输入6,426、输出1,977、合计8,403 tokens。

这是一次连通性测量，不是性能基准或质量增益实验；没有费用数据就不估算实际账单。未修改用户全局模型配置。

原默认模型返回HTTP403，提供方声明该模型在当前地区不可用。代码现将4xx作为可恢复错误返回，并在群内显示失败。真实调用还发现默认长思考可能耗尽小输出预算而不产生正文，已加入空回复终态和DeepSeek文档支持的聊天模式参数。

记录：`.newbee/chat-checks/live-verified.log`、`live-result.json`。

## 浏览器

在实际页面完成创建议题、两轮讨论、决议应用、人类补充消息和同机新增代表。包含 `<script>` 的名字以普通文字呈现，没有注入脚本节点。390×844视口检查未发现横向溢出；手机上先展开侧栏即可进入聊天室。最终页面还检查了可选模型提供方和模型名称字段。

截图：`.newbee/chat-checks/chat-desktop.png`、`chat-mobile.png`。截图内模型内容明确标有“协议测试回复”。

## 使用入口与边界

运行工作树版本后，在项目群标题旁点击「聊天室」。跨主机使用时，Hub和参与讨论的Worker都应运行包含本功能的版本。

新代表默认沿用所在主机的advisor配置；本环境中可选择已验证的 `deepseek` / `deepseek-v4-flash`。加入其他主机前应确认该主机有对应的提供方配置。

生产凭据、分支发布和现有运行服务没有被修改。首次使用说明、预算及持久化限制见 [项目聊天室设计](project-chat-design.md)。

## 人类代表与定向邀请验证

本轮在原有聊天室上增加了人类代表和结构化 @ 提及，并用真实浏览器复核。

### 界面实测（演示群：3 位智能体代表 + 1 位人类代表）

| 检查 | 实测结果 |
|---|---|
| 人类代表 | 添加代表表单出现「人类代表（我自己发言，不消耗模型调用）」；选中后隐藏 provider/model |
| 代表列表 | 显示「岩松 · 主机A · 笔记本」「小桥 · 主机A · 笔记本」「木木 · 主机B · 台式机」「Alan · 人类代表」 |
| 定向邀请 | 人类消息 @木木 后，消息卡片显示「定向邀请：@木木」，只有主机B的木木被唤醒（主机A无新工作项） |
| 等待人类 | 消息区显示「等待 Alan 发言（约 247 秒，超时自动继续）」，旁边有「本轮不发言」按钮 |
| 发言身份 | 输入区身份下拉为「匿名人类发言（不署代表名）」/「以 Alan 的身份发言」，选中后消息署名 Alan |
| @ 选择器 | 聊天室底部提供 @岩松 / @小桥 / @木木 / @Alan / @all（最多5位） |
| 省费记账 | 已完成议题状态栏显示「模型4/16次 · 省下1次 · 人类回合0次 · 1280 tokens」 |
| 决议面板 | 决议草案 v1 + 任务/基线 + 「提供给执行任务」按钮保持不变 |
| 手机（390px） | 单列布局，输入区可见，`scrollWidth == innerWidth`，无横向溢出 |

截图：`.newbee/chat-checks/shot-desktop.png`、`shot-finished.png`、`shot-form.png`、`shot-mobile.png`（已上屏）。

### 自动测试

`test/newbee/collaboration/chat_test.exs` 从 14 项扩展到 22 项，覆盖：

- 人类代表创建（拒绝 provider/model、固定 local 设备、可用性不看心跳）
- 人类等待回合：可见、可显式跳过、可超时继续，且从不进入模型调用队列
- 结构化提及：目标校验、未知目标报错、@all 上限 5 且排除作者
- 定向回合：只唤醒被点名设备、记账 `mentions_used` / `run` / `calls`、轮次进行中排队到轮后
- 模型侧 @：从回复文本精确匹配代表名单，丢弃自己/未知/重复目标
- 已停止议题不能被 @ 复活，且拒绝原因可见
- 静默省费：最后发言者不被重复计费，记为 `skipped`，独立评估轮与总结轮照常运行

连续运行结果（同一套测试）：

```text
seed 2001: 22 passed
seed 2002: 22 passed
seed 2003: 22 passed（修复前曾出现 1 次偶发 wait_idle 超时）
seed 3001: 22 passed
seed 3002: 22 passed
```

偶发失败定位为测试自身的 `wait_idle` 只等约 1 秒（并行 16 个用例时交付链偶尔更慢），已把上限放宽到约 15 秒并改为轮询真实状态；修复后连续多轮无失败。

### 设计边界

- 人类代表不消耗模型调用，也不占用其它主机的设备名额；它固定在群主本机（`device_id = "local"`）。
- 提及是结构化字段，不解析正文；正文里的 `@xyz` 不会误触发任何人。
- 上限：每条消息 5 个目标、每议题 12 次邀请、每议题 4 个定向回合、所有邀请共享议题的 16 次调用预算；超限或被拒绝都会留下可见通知。
- 讨论轮与定向轮里，如果某位代表的自己消息就是最后一条，它记为 `skipped` 而不产生调用；独立评估与总结轮不受影响，保证仍有结论。

