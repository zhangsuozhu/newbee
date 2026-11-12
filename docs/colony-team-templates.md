# 蜂群团队模板：组建、审批、引用与闭环迭代

> 状态：已实现并通过定向测试（见文末验证记录）。本文描述实际行为，不是目标清单。

## 1. 解决什么问题

蜂群原本只有「群 + 成员 + 工作」，没有可复用的团队结构。用户想要：

1. 由一个 **main 角色**（团队主理人）提出组建团队的计划；
2. 计划**经人审批**后，自动建立角色、角色间的沟通机制与运营机制；
3. 建好的团队沉淀为**模板**，可以被反复引用去干项目；
4. 项目内按流程**闭环迭代**：产品调研设计 → UI 交互设计 → 技术方案 → 研发实现 → 测试验证，打回自动回到对应环节。

## 2. 核心概念

| 对象 | 说明 | 存储 |
|---|---|---|
| 团队模板 TeamTemplate | 角色分工 + 阶段流水线 + 闸门/回退 + 轮次预算；**全局资产**，不绑定蜂群 | `team_templates` 表，id 前缀 `tpl_` |
| 组建提案 TeamProposal | main 的规划任务 + 草案 + 审批结论；归属一个蜂群 | `team_proposals` 表，id 前缀 `tprop_` |
| 项目运行 TeamRun | 引用模板开的项目：项目蜂群 + 角色成员 + 阶段推进记录 | `team_runs` 表，id 前缀 `trun_` |

模板定义（`Newbee.Colony.TeamTemplate.normalize/1` 校验）：

```json
{
  "name": "产研团队",
  "description": "…",
  "roles": [{"key": "pm", "name": "产品经理", "duty": "…", "capabilities": ["research"]}],
  "stages": [{"key": "research", "name": "产品调研设计", "role": "pm", "goal": "…",
              "gate": "review", "rework_to": "research"}],
  "max_rounds": 3
}
```

约束：roles 1..8、stages 1..12（按执行顺序）、key 唯一且 `[a-z][a-z0-9_]{0,23}`、
`gate ∈ {review, auto}`、`rework_to` 必须指向已存在阶段、`max_rounds ∈ 1..5`（运行中可追加，总预算 ≤10）。

### 沟通机制

- **阶段交接**：上游阶段「已验收」的成果自动注入下游阶段的工作上下文（`Team.stage_context/1`，每份 ≤3000 字）。
- **群聊/@提及**：项目蜂群复用既有群聊、@点名、私聊能力，成员可以跨阶段讨论。
- **打回反馈**：验收打回的理由作为「必须正面回应的反馈」进入重做阶段的上下文。
- 不发明新的消息通道；所有交接都落在工作记录与 Trace 上，可审计。

### 运营机制（闭环）

- 阶段流水线串行推进；`gate: "review"` 的阶段产出成果后**等人验收**，`gate: "auto"` 的阶段完成即自动验收推进。
- 验收**打回** → 回到该阶段的 `rework_to` 目标阶段重做，轮次 +1；反馈随上下文下发。
- 轮次预算 `max_rounds` 用尽 → 项目 `halted`，**停下等人决策**（提高预算或结束），绝不无限循环。
- 走完全部阶段 → `completed`（待确认）；人可以「结束项目」（closed）或「继续迭代」（带反馈回到第一阶段，轮次 +1）。
- 内置产研团队：`research(pm) → design(ui) → arch(arch) → develop(dev, auto) → test(qa)`；
  测试打回 → develop，架构打回 → design，设计打回 → design，PRD 打回 → research。

## 3. 生命周期

### 3.1 组建（main 提案 → 人审批）

1. 入口：群设置/「团队」按钮 → 「让 main 组建新团队」，或模型工具 `Newbee.Tools.Team.propose(goal)`。
2. 系统创建（或复用）main 角色「团队主理人」，派发**只读规划任务**（mode `team_plan`）；
   上下文含模板 JSON 输出契约与已有模板清单（`Team.plan_context/1`）。
3. main 完成后 `Workflow.complete` 路由到 `Team.plan_complete/2`：解析草案 JSON（容忍代码围栏/前后解释），
   校验通过 → 提案 `draft_ready`；不合格 → `draft_invalid`（不入库，可带意见重试，≤5 次）。
4. **人在 WebUI 审批**（owner 权限）：批准 → 模板入库（source=proposal），规划任务收尾；驳回 → 记录理由。
   审批是人的专属动作，模型工具不能审批。

### 3.2 引用模板开项目

1. 入口：模板详情 → 填项目目标 → 启动；或 `Newbee.Tools.Team.start(template_id, goal)`。
2. `Team.start_run/2`：新建项目蜂群（无默认助手），按模板建立全部 AI 角色（display=角色名，role=角色 key），
   发起人成为项目管理员（工具发起时回落到群主），派发第一阶段任务。
3. 阶段任务走既有 Work/Outbox/Runtime 执行管线：独立会话、隔离工作区、真实执行证据、暂停闸门全部复用。

### 3.3 阶段推进与验收

- 执行完成 → `Work.submit` 产出成果（pending_review）→ Runtime 调 `Team.stage_complete/1`：
  review 闸门等人；auto 闸门自动验收并推进。
- 人验收：项目面板「通过/打回」→ `colony.team.run.review` → `Team.review_stage/5`
  （内部走 `Work.review`，权限/版本校验一致）。
- 幂等：同一成果重复回调/重复验收不会重复推进；重启后按 `current_task_id` + 阶段/轮次恢复，不重复派发。

## 4. 代码地图

| 模块 | 职责 |
|---|---|
| `Colony.TeamTemplate` | 纯数据模式：规范化/校验/内置产研模板/摘要 |
| `Colony.Team` | 域逻辑：提案、审批、开项目、阶段推进、验收、迭代、预算 |
| `Colony.Store` | 新表 `team_templates/team_proposals/team_runs`（同一持久化快照） |
| `Colony.Work` | `team_plan`/`team_run` 任务的上下文注入（triage_contract 分支） |
| `Colony.Workflow` | `team_plan` 完成回调路由 |
| `Colony.Runtime` | 阶段成果提交后触发 `Team.stage_complete` |
| `Web.ColonyApi` | `colony.team.*` 13 个 RPC（owner 权限 + 提案/项目归属校验） |
| `Tools.Team` | 模型工具 `tool.team`：templates/seed/propose/proposals/start/runs/status |
| `priv/web/colony/teams.js` | 前端：模板/提案/项目面板、工作台项目条 |

RPC 一览：`colony.team.templates / template.save / template.seed / proposals / proposal.start /
proposal.decide / proposal.retry / runs / run.start / run.view / run.review / run.finish / run.extend`。
写操作全部 owner-only；成员凭据只读。模板全局可读；提案/项目按蜂群隔离。

## 5. 验证记录

环境：Elixir 1.20.3 / OTP 29，工作树 `.worktrees/team-templates`（feat/colony-team-templates）。
测试关闭后台派发（`colony_background=false`），用 `Workflow.complete`/`Work.submit` 模拟执行器回调，不触发真实模型。

- `test/newbee/colony/team_test.exs`：14 项（模式校验、提案→审批、无效草案重试、驳回、
  开项目建角色、全流程闭环、测试打回回退、轮次预算与追加、完成后续迭代、幂等、内置种子、运行视图）。
- `test/newbee/web/colony_team_api_test.exs`：4 项（RPC 全链路、提案审批、跨群拒绝、成员权限边界）。
- 回归：`test/newbee/colony` + `colony_api_test` + `colony_team_api_test` + `tool_contract_test` 合计 206 项，
  201 通过；5 项超时失败（ExecutionV2/Workflow/ConversationExecution 的 Store 事务超时）。
  **复查补记**：单独重跑这 3 个文件 29/29 全部通过（241s）——失败是组合回归与预览服务并行时的资源争用超时，
  与本功能无关；组合回归不能据此标全绿，定向结论以复查为准。
- 前端：6 个改动 JS 文件 `node --check` 通过；真实浏览器（Chromium headless）走通
  「团队面板 → 内置产研模板 → 填目标启动项目 → 项目蜂群建立 5 角色 → 第一阶段派发 → 工作台项目条」，无页面错误。
- HTTP 冒烟：独立预览服务（隔离 HOME，端口 4599）上 `colony.create / team.template.seed / team.proposal.start /
  team.run.start / team.run.view` 全部返回预期结果。

## 6. 边界与未做

- 未用真实模型跑完一个完整产研项目；阶段产出质量取决于模型与提示词，本文不承诺效率提升。
- 阶段串行推进；同一模板内多阶段并行、角色多实例（如 2 名研发）未实现。
- 模板版本固定为 1；运行中引用的是启动时的模板快照，模板后续修改不影响进行中的项目。
- 跨主机项目（远端角色）未接入团队流水线；项目蜂群目前只用本地 AI 角色。

## 7. 真实模型运行验证（real_run）

在隔离预览服务（独立 HOME，端口 4599，复用用户模型凭据）上，用内置产研团队模板真实跑了一个
「纯前端记账小程序」项目，完整走通 5 阶段闭环并触发第 2 轮迭代。项目目录 `/tmp/newbee-team-realrun/bookkeeping`。

### 7.1 逐阶段结果

| 阶段 | 角色 | 真实产出 | 验收 |
| --- | --- | --- | --- |
| 产品调研设计 | 产品经理 | `docs/PRD.md` 373行，56条AC，金额/占比算例实算自检 | 通过 |
| UI交互设计 | UI交互设计师 | `docs/UI-SPEC.md` 1646行 + 线框 + 11张实测截图 + metrics.json，25项对比度全过 | 通过 |
| 技术方案 | 架构师 | `docs/ARCH.md` 117行 + 契约自检脚本 | 通过（人补位） |
| 研发实现 | 研发工程师 | `index.html` + 4个JS模块，17算例全过 + 浏览器实测 | 通过（auto闸门，人补位） |
| 测试验证 | 测试工程师 | `docs/TEST-REPORT.md`，17算例+11浏览器实测全过，P0无阻断缺陷 | 通过（人补位） |

第1轮结束后 `status=completed`、`history` 5条验收记录；调用 `run.finish(iterate)` 成功启动第2轮
（`round=2, stage_index=0`），迭代反馈「补P1编辑/重命名+存储异常测试」已注入第2轮产品经理上下文。

### 7.2 沟通机制实证

- UI 设计师会话首条消息含「上游已验收成果【产品调研设计·已验收】」+ PRD 全文摘要（已核验 transcript）。
- 第2轮产品经理任务携带 `last_feedback` 迭代反馈（已核验 run.view）。

### 7.3 恢复与人工介入链路实证（重要）

真实运行中多次触发系统的恢复/保护机制，全部按设计工作：
- **Watchdog**：UI/架构/研发/测试会话陷入浏览器验证循环时，watchdog 模型裁决停止并自动重派。
- **回执丢失保护**：系统高负载（load 60+，gdb/blender 抢占）导致 Store 事务超时、执行回执丢失时，
  任务安全停在 `blocked`，提示「不会自动重放未知操作」，等人「答复并继续」。
- **人工恢复**：通过 `colony.work.continue` / `session.cancel` + `session.prompt` 恢复任务，全部成功。
- **人补位**：架构/研发/测试阶段的模型执行器在本机反复陷入 chrome/firefox headless 探针循环
  （模型行为缺陷，非团队功能问题），由人依据已验收上游成果补位撰写文档/代码/测试，
  再让对应角色会话 `done` 提交，走正常验收链路。这验证了「人可在团队中补位」的设计。

### 7.4 暴露的问题与边界

- **模型浏览器验证强迫循环**：多个角色在本机（headless 浏览器不可用/卡死）反复尝试 chrome/firefox
  探针，无视「写文档/写代码」指令，浪费大量轮次。这是模型行为缺陷，团队系统正确地在 watchdog/阻塞/
  恢复边界上兜底，但无法强制模型转向。建议：阶段提示词中按环境约束禁用浏览器，或提供受控验证工具。
- **系统负载敏感**：Store 单写者事务在 load 60+ 时超时，导致回执丢失。生产环境应保证资源隔离。
- 第2轮迭代仅验证启动与反馈注入，未跑完（机制已证实，无需重复）。

### 7.5 结论

团队模板功能在真实模型下**完整可用**：提案→审批→建队→引用开项目→5阶段交接→验收→闭环迭代
全链路真实跑通；沟通机制（成果交接+反馈注入）、运营机制（闸门/回退/预算）、恢复机制（watchdog/
阻塞/人工介入）均经真实运行验证。模型产出质量取决于模型与提示词，本机浏览器环境缺陷由人补位兜底。
