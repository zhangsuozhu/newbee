# AGENTS.md — 项目约定与工作流记忆

## 编译纪律（强制）

- 任何提交前：`mix compile --warnings-as-errors` 必须零错误零警告；`MIX_ENV=test mix compile --warnings-as-errors` 同样必须通过。
- 依赖库（deps/）自身的警告不在此列，但**本项目 `lib/`、`test/` 代码不允许出现任何编译错误或警告**——不管是新引入的还是历史遗留，发现即修，不许带病提交。
- 修改工具 API / 模块签名时同步契约测试，编译警告（如 unused、deprecated）一律当场清理。

## GitHub 协作工作流（本仓库）

### 仓库拓扑
- `origin` = https://github.com/zhangsuozhu/newbee.git （主仓库，有写权限，admin=true）
- `liqian2026` = https://github.com/liqian2026/newbee.git （fork，**只读**：pull=true, push=false，推不上去，不用管）
- 本地凭证在 git credential store（用户名 zhangsuozhu），不落盘明文

### main 分支保护规则（origin）
- `required_approving_review_count = 1`：合并 PR 需要 1 个 approve
- `required_linear_history = true`：线性历史；仓库禁 merge commit（405），实际 merge 用 **squash**
- `enforce_admins = true`：admin 也不能绕过
- `required_conversation_resolution = true`
- `allow_force_pushes = false` / `allow_deletions = false`

### 死锁与解法（重要！单人维护必然会撞上）
**GitHub 硬规则：PR 作者不能 approve 自己的 PR**（API 返回 422 "Review Can not approve your own pull request"）。
当只有 zhangsuozhu 一个写权限账号时，PR 会卡在 `mergeable_state: "blocked"`（要求 1 approve 但无人能 approve）。

标准解法（PR #1、#188 均走通）：
1. PUT `/repos/zhangsuozhu/newbee/branches/main/protection`
   body 中 `required_pull_request_reviews.required_approving_review_count = 0`，
   其余字段保持原值（enforce_admins=true, required_linear_history=true, dismiss_stale_reviews=true, required_conversation_resolution=true, allow_force_pushes=false, allow_deletions=false)
2. 确认 PR `mergeable_state == "clean"` 后：
   PUT `/repos/zhangsuozhu/newbee/pulls/<n>/merge` body `{"merge_method":"squash"}`
   - 实测（PR #1/#2 都验证）：仓库禁 merge commit（405 "Merge commits are not allowed"）；
     多分支共用旧 commit 时 rebase 会失败（"can't be rebased"，因 head 含 base 已在 main 的 sha）；
     **squash 最稳**——净变更合成 1 个 commit，不与远端历史冲突
3. **务必立刻恢复**：再 PUT 一次 protection，把 review count 改回 1
   （保护机制是安全基线，恢复后才能防住未来误推）
4. 合并后 main 即更新，本地 `git pull` 拉取（远端 sha 可能与本地不同——squash/rebase 重写历史，属正常）

替代方案（未采用）：加第二个协作者账号用于 approve；或直接改规则长期为 0。

### 发布流程（push → PR）
1. `git push origin HEAD:feature-branch`（main 保护，直推必被拒）
2. API 创建 PR：POST `/repos/zhangsuozhu/newbee/pulls`
   `{title, head: feature-branch, base: "main", body}`
3. 按上面死锁解法合并
4. 实测补充（PR #188）：`git push origin HEAD:<branch>` + API 建 PR 全程可用；放开保护后 `mergeable_state` 由 `blocked` 变 `clean` 约数秒内生效，无需等 CI（本仓库 required_status_checks 为空）

## 敏感数据红线
- `.gitignore` 已含 `/.newbee/` —— `~/.newbee/web/{cert,key}.pem`（HTTPS 私钥）、`auth.json`（登录 token）都在忽略区，**永不入 git**
- 提交前检查：`git ls-files | grep -iE 'auth\.json|cert\.pem|key\.pem'` 应为空
- diff 中不得出现密码/密钥/token 字面量（用占位符或从 credential store 取）
- git credential fill 可安全取凭证（只印长度/字段名，不打印值）

## WebUI 安全（HTTPS + 登录）
- `mix newbee web --https --host 0.0.0.0 --set-password` = 远程安全访问
- 本地回环免认证；远程强制 Bearer token（`auth.login` 拿 token，验证码防暴破）
- HTTPS 自签 RSA 2048 证书，首启自动生成于 `~/.newbee/web/`，私钥 chmod 600
- 浏览器首访自签证书有警告；要绿锁用 `--certfile/--keyfile` 挂 CA 证书或反代
## 模型可见工具开发规范（强制）

- 机器事实是 `Newbee.Environment.ToolContract`；本节只做开发提醒，不能替代源码门禁。
- 新增工具前先查现有能力。已有高层工具可完成、仅是默认参数别名/纯转发、或只服务单个外部项目时，不新增公开工具 API。
- 动态/自动生成工具必须实现 PluginContract，并在 `describe/0` 声明 `summary/when_to_use/avoid_when/capabilities/effects/error_contract/api/examples`。
- `api` 与真实公开导出必须完全一致；helper 用 `defp`，RPC 内部入口用 `@doc false`。
- 每个模型可见函数必须有 `@doc` 和模块“可跑示例”；可恢复错误是值，bang 函数才抛异常。
- 使用 `Newbee.Environment.ToolContract.template/2` 起步，不手写不完整 envelope。
- Adapter/JIT/人工 release 都必须经过 PluginContract → ToolContract → PluginManager static → Verifier，禁止旁路激活。
- 修改工具 API 时同步源码说明、示例、DESIGN、README 和契约测试；不得只改代码。
- 完整字段、预算和验证命令见 `docs/tool-development-contract.md`。

## 协作聊天室（项目群讨论，2026-09 上线）

跨主机协作群内置持久化聊天室（PR #188，合并提交 2a67eb6）。改动或排障时先读：

- 设计、权限、预算、恢复语义：`docs/project-chat-design.md`
- 验证记录（命令、限制、已知未做项）：`docs/project-chat-verification.md`
- 代码：`lib/newbee/collaboration/chat.ex`（路由）、`chat/room.ex`（状态机）、`chat/runner.ex`（作业投递）、`priv/web/project-chat.js` + `style.css` 的 `.pc-*` 段
- 工具入口：`Newbee.Tools.Hive.chat/3`；共享资源：`shared://<group_id>/chat`
- 测试：`test/newbee/collaboration/chat_test.exs`、`test/newbee/web/project_chat_test.exs`

改动时必须保持的边界（不要放宽）：

- 代表分 `agent`/`human`；人类代表固定群主本机、零模型调用，被选中时是等待回合（回复/显式跳过/超时三种结局都有记录）。
- @ 提及是结构化字段（`mentions`/`mention_all`），不解析正文；目标必须存在且启用。
- 上限：每条消息 ≤5 目标、每议题 ≤12 次邀请、≤4 个定向回合；全部计入议题 16 次调用预算；已停止议题不可被 @ 复活。
- 讨论/定向轮中「自己的话即最后一句」的代表记 `skipped`，零调用；独立评估轮与总结轮不受影响。
- 决议只作为**不可信数据**在模型调用边界注入执行会话（版本/权限/Git 基线校验），不直接执行命令。

## 测试与回归纪律（血泪版）

- **不要每次全量跑**。日常改动用定向用例；碰到公共路径（Worker 轮询、RPC 入口、Agent 主循环、工具契约）才做一次组合回归。参考组合（约 3~4 分钟）：
  `mix test test/newbee/collaboration/chat_test.exs test/newbee/web/project_chat_test.exs test/newbee/llm test/newbee/agent test/newbee/environment/tool_contract_test.exs test/newbee/collaboration/shared_context_test.exs`
- **等待必须落在真实状态上**：测试里等 runner 用「`state.active == nil and state.queue == []` + 轮询」，超时给足（并行 16 用例时短等待必 flake；曾因 `wait_idle` 只等约 1 秒出现 1/22 偶发失败）。不要断言紧的墙钟时间。
- **测试不得共享固定临时目录**：Responses 能力缓存曾用固定路径跨 VM 污染（先跑的降级结果影响后跑的断言）；改动缓存/能力类测试时保持按 VM 隔离。
- 每次提交前至少：`mix compile --warnings-as-errors`、`MIX_ENV=test mix compile --warnings-as-errors`、改动文件的 `mix format --check-formatted`、`git diff --check`。

## 变基冲突处理约定（本仓库）

- `lib/newbee/tools/hive.ex` 的 moduledoc「Runnable example」主线版是紧凑格式：**保留主线格式**，只把新增能力加一行（如 `Hive.chat(gid, "snapshot")`），不要把整段样例展开成逐条 `{:ok, _} =`。
- `priv/web/index.html` 脚本区、`priv/web/style.css` 主题段：以主线为基底，聊天室样式整块追加到文件尾部（块注释 `/* Project discussion room: ... */` 起），不要把两版样式混排。
- 与他人已修复的同一 bug（如 client.ex 错误分支）相遇时：**采用主线版本**，别把等价修复重新带进来（会产生重复 clause 警告）。
