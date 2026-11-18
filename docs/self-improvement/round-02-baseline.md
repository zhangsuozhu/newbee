# 第 2 轮 · 基线与环境校准（R2）—— 交付文档

> 角色：项目总协调人（main）　阶段：基线与环境校准　轮次：2
> 被测版本：`5ed39a6e8feece2cbfe3c1d309768769eb265c98`（= `origin/main` #229）
> 测量位置：会话独立工作树 `.worktrees/main-r2`（detached；`deps -> ../../deps`）
> 提交状态：**未 commit / 未 push / 未合并**；主仓库在途 10 个文件 + 4 个未跟踪目录全程未被写入（开工/收工 `git status` 一致）

## 0. 本轮要解决的三个问题

| # | 问题 | 本轮处理 |
|---|---|---|
| 1 | R1 基线在 `origin/main` 已前进（#228→#229）且并发高负载下测，数字不可作后续对照 | 干净工作树 + 独占时段重测全口径，给出 R2 基线并标注口径差异 |
| 2 | 用户反馈"右侧边自动刷新 / 输入不了字 / 会话与团队工作室项目不闭环 / 没删除功能"从未映射成可判定条目 | 用真实浏览器（Playwright，非 DOM 替身）逐条复现，拆成 U1–U5 |
| 3 | 后续 100 轮缺"改前/改后"对照物 | 固化 `repro.sh` + `metrics.json` + 门禁 G1–G9 / 数值尺 M1–M15 |

## 1. 成果位置

| 项 | 路径（相对 `.worktrees/main-r2`） |
|---|---|
| 本文档 | `docs/self-improvement/round-02-baseline.md` |
| 一键复现 | `baseline-r2/repro.sh`（`--full` 追加漏跑文件与 seed2/3） |
| 结构化基线数据 | `baseline-r2/metrics.json` |
| 原始日志（22 个） | `baseline-r2/logs/` |
| UI 复现证据（截图 5 + 数据脚本 5） | `baseline-r2/evidence/`；探针脚本在 `baseline-r2/probe/` |
| 漏跑/失败/格式清单 | `baseline-r2/{missing-files,failing-files,format-violations}.txt` |

## 2. 复现方法（命令 + 真实输出）

```bash
cd .worktrees/main-r2
ln -sfn ../../deps deps            # 工作树必须软链主仓库 deps（第一层写法会漏两层）
export TMPDIR=/tmp/r2-tmp          # 不要用 /tmp 根：R1 曾因 /tmp 满盘整分区假红
bash baseline-r2/repro.sh --full   # 约 45 分钟，逐步写 baseline-r2/logs/summary.txt
```

### 2.1 构建（四条 `--warnings-as-errors`）

| 项 | 耗时 | exit | 警告 |
|---|---|---|---|
| dev 冷 | 87.0 s | 0 | 0 |
| test 冷 | 116.3 s | 0 | 0 |
| dev 热 | 5.3 s | 0 | 0 |
| test 热 | 5.1 s | 0 | 0 |

R1 对照 81.9 / 101.1 / 9.7 / 17.6 s。冷变慢、热变快，属机器状态差异，不作回归判据。

### 2.2 格式

```
mix format --check-formatted  ->  exit=1, 6.0 s
不合规 31 个文件 = lib 15 + test 16
```
R1 为 34。下降 3 但远未清零；清单已落 `format-violations.txt`。

### 2.3 前端套件

```
node --test test/web/conversation-work.test.js
# tests 32 / pass 0 / fail 32 / duration_ms 892
```
首个失败 `wrap.classList.toggle is not a function`（`priv/web/conversation-work.js:852`，测试替身缺 API）；另有 `innerHTML` 契约违约。与 R1 一致：**32/32 红，且不在任何 mix 门里**。

### 2.4 acceptance

```
mix test.acceptance -> exit=0, 93.8 s, Result: 14 passed
```

### 2.5 官方门禁 `mix newbee.test_fast`

第一次（与 seed 测试并发，loadavg 6.5）：**exit=1，1993.6 s，15 失败**。
等并发任务全部结束后的「干净跑」：

| 分区 | exit | 结果 | 用时 |
|---|---|---|---|
| agent-dee | 0 | 116 passed, 13 excluded | 218.7 s |
| environment | 0 | 149 passed | 68.0 s |
| llm | 0 | 175 passed, 3 skipped | 48.1 s |
| tools-tui | **2** | 186/188（**2 失败**） | 91.8 s |
| web | **1** | **358 passed, 1 excluded，0 失败** | 402.1 s |
| collaboration | 0 | 160 passed | 232.2 s |
| root | **2** | 349/350（**1 失败**），10 skipped | 286.3 s |

**合计 1523 用例 = 1493 通过 / 3 失败 / 26 跳过 / 1 排除；分区墙钟 1347.2 s，端到端 1407 s。**
同一 commit 两次跑 15 失败 → 3 失败：**门禁结果对并发敏感**，这是本轮第一条硬结论。

### 2.6 test.fast 漏跑的 32 个文件（R1 的 D5 是否仍在）

独立复算分区表：**254 个测试文件，test.fast 只覆盖 221 个**，漏 33（含 acceptance，按设计在外）。逐文件补跑 32 个：

```
mix test --warnings-as-errors --seed 1 <32 files>
-> exit=3, 774 s, Result: 282/283 passed, Failed: 1
```
失败 `conversation_work_test.exs:28`：`Task.Supervised.stream(5000)` 超时。

**结论：D5 未修，缺口仍是 32 文件 / 283 用例**（colony 整子系统 + plugins + learning + codec + host + terminal + truncate + evals）。

### 2.7 失败集合的种子稳定性（11 个曾失败文件）

| seed | 结果 | 用时 | 失败集合 |
|---|---|---|---|
| 1（干净门禁内） | 3 failed | — | tool_documentation_contract、command_job、archive |
| 2 | 146/149, 3 failed | 217 s | tool_documentation_contract、session_index_perf(cold)、archive |
| 3 | 146/149, 3 failed | 179 s | session_index_perf(cold)、tool_documentation_contract、archive |

**三 seed 全红的确定失败 2 条**：
1. `tool_documentation_contract_test.exs:8` — `assert byte_size(section) <= 1800`，实测 **left: 1941**（R1 的 D1，未修）。
2. `archive_test.exs:360` — 二次压缩回放 envelope 前缀断言（R1 的 D3，未修；R1 pm 曾论证"产品对、测试错"，本轮未复核，留 arch/pm）。

**抖动 2 类**：`session_index_perf_test.exs`（cold/hot，测的是"机器上有多少会话"）、`command_job_test.exs:16`（caller exit cancels unbounded command tree）。

### 2.8 全绿分区仍被判红（R1 的 D2 在 #229 上仍成立）

web 分区 **358 passed / 0 failed 却 exit=1**，仅因两条测试文件编译警告：

```
warning: variable "cid" is unused          test/newbee/web/colony_team_api_test.exs:25
warning: unused import Plug.Conn           test/newbee/web/static_asset_allowlist_test.exs:12
```
隔离验证（`logs/warn-iso.txt`）：

```
A: mix test --warnings-as-errors static_asset_allowlist_test.exs -> exit=1, Result: 5 passed
B: mix test                        static_asset_allowlist_test.exs -> exit=0, Result: 5 passed
```
同一份用例全通过，只因 `--warnings-as-errors` 判红。另有 3 条**运行期 deprecation 永不判红**（`File.stream!/3` 旧参数序：`lib/newbee/collaboration/verification.ex:270`、`lib/newbee/event_log.ex:66`）。

### 2.9 资源与规模

| 指标 | R2 | R1 |
|---|---|---|
| `git worktree list` 注册数 | **421** | 204 |
| `.git/worktrees` 体积 | 36 MB | 17 MB |
| `/home` 使用率 | 91%（剩 6.2 G） | — |

测试自身仍在新增工作树且零清理。

## 3. 用户反馈的逐条复现（真实浏览器，非替身）

方法：`mix newbee.web --port 4211`（本工作树的 dev 构建）→ `Newbee.Tools.Browser`（Playwright + Chromium，headless）打开 `http://127.0.0.1:4211/`，用 `evaluate` 驱动真实 DOM，每 500 ms 采样一次节点同一性/值/焦点，并截图。
探针脚本：`baseline-r2/evidence/{inspect_store,stages,stall}.py`；截图 `evidence/ui-01..05*.png`。

### U1（P0·确定性）"右侧边会自动刷新，我没办法输入文字" —— 团队工作室内 8 s 轮询整块重建 DOM，正在输入的草稿被清空

**复现（可判定）**：
1. 打开 WebUI → 点顶栏 🐝 打开「团队工作室」→ 切到「组建」页（自由输入框"这个团队要做什么"）。
2. 在 textarea 里输入文字，保持焦点，不做任何操作。
3. 不加干预等待。

**实测（20 s 采样，500 ms 间隔）**：

```
{"windowMs":20000,"events":[{"at":500,"ev":"node-replaced"},{"at":500,"ev":"blur"}],
 "lastTwo":[{"t":19500,"same":false,"val":"","focus":false},...]}
```

**26 s 窗口的 DOM 变更观察**（`MutationObserver` 只看 `.tp-body` 子树里 textarea 的增删）：

```
{"textareaEvents":[{"at":5227,"removed":true},{"at":5227,"added":true},
                   {"at":13551,"removed":true},{"at":13551,"added":true},
                   {"at":21398,"removed":true},{"at":21398,"added":true}],
 "sameNodeAfter":false,"panelStillOpen":true}
```

→ **每 8 s 一次**（5.2 s / 13.5 s / 21.4 s 是"下一次轮询落点"，间隔恰为 8 s），输入框节点被物理替换，`activeElement` 变 `BODY`，草稿清空。

**根因（代码定位，两处叠加）**：
- `priv/web/team-panel.js:721`：`state.timer = setInterval(() => { if (state.opened && !document.hidden) load(false); }, 8000);` —— 面板打开即轮询。
- `priv/web/team-panel.js:143-155`：`render()` 无条件 `body.innerHTML = ""` 再逐块重建；`load(false)` 每次都调 `render()`（713 行）。面板**没有任何"正在编辑就跳过重绘"的守卫**（对比 `conversation-work.js:489` 的 `captureFocus/restoreFocus` 与 723 行 `state.composing` 守卫，团队面板一个都没有）。

**影响**：面板里所有输入（组建提案、开项目目标、打回/迭代理由、验收意见、追加轮次）都是长文本，8 s 必然被打断 —— 这就是用户说的"我没办法输入文字"。

**同源风险同类**：`.tp-body` 里 `input`（项目名称、追加轮次 number）同样被重建；已滚动的列表位置也会回到顶部（`body` 被清空重建）。

**已排除的邻域**（避免误判）：主输入框 `#input`、侧栏搜索 `#session-search`、Mission Control 协作输入 `#mc-collab-input` 在 12 s / 10 s 采样里 **节点同一、值保留、焦点保持**（后两者分别因 `refreshSessionStatus` 只改 `.sess-dot` 的 class、`renderCollaborationPane` 不改输入框）。→ **问题精确落在团队工作室面板**。

### U2（P0·确定性）"会话/会话组/团队工作室项目 不闭环" —— 自动闸门阶段卡死：任务已 `done` 并有成果，运行状态永远停在当前阶段

**现象**（线上真实数据，`~/.newbee/colonies/store-dev.json`）：

```
trun_l_1y15GAXzespO  status=active  stage_idx=3(implement)  round=1
   history: baseline=accept, diagnose=accept, plan=accept
   current_task: task_l_eiz97Cb8TVk5 status=done  has_result=True  team_stage=implement
   updated_at 1794549253235 (=2026-11-13T13:54:13), completed_at=None  -> 至 2026-11-17T13:53 已停滞 5758.8 分钟（约 4.0 天）
```

UI 表现（截图 `evidence/ui-04-blocked-run-detail.png`）：
- 项目卡片 pill 显示"推进中"，第 3 阶段标为 current；
- 展开详情后，当前任务"第1轮 · 修改代码 · @研发工程师"已 `done` 且有成果正文；
- **详情区一个操作按钮都没有**（实测 `[...document.querySelectorAll('.tp-detail button')]` = `["查看执行会话 →"]`）——因为验收按钮只在 `current_task.status === "pending_review"` 时渲染，而这里是 `done`；`status=active` 又不满足"继续迭代/结束"的 `completed` 条件，也不满足"提高预算"的 `halted` 条件。

→ **这是一个无出口的中间态**：用户看到"推进中"，但系统不会自己走，UI 也不给任何按钮。

**根因（代码 + 语义，两条）**：

1. `lib/newbee/colony/runtime.ex:521`：
   ```elixir
   if task["source"] == "team_run", do: Newbee.Colony.Team.stage_complete(task)
   ```
   `task` 是 `project_work/5` 入口处取的**旧快照**（`Store.get_task` 在 409 行附近），此时状态还是 `running`；`Work.submit/4` 之后任务已变 `pending_review/done`（`work.ex:457-462`），但**没有重新读**。`Team.stage_complete/1` 的第一条守卫就是
   ```elixir
   task["status"] not in ["pending_review", "done"] or not is_binary(task["result"]) -> {:ok, :ignored}
   ```
   → 传旧快照必然 `:ignored`，auto 闸门**从不推进**。
   **旁证（项目自证）**：`test/newbee/colony/team_test.exs:213-217` 明确写着
   `{:ok, :ignored} = Team.stage_complete(dev_task)` → "stage_complete 用旧 task 快照会 ignored；用最新快照驱动（与 Runtime 相同路径）" → 测试**把缺陷写成了预期行为**，并注释说"与 Runtime 相同路径"，实际上 Runtime 走的就是被 ignored 的那条。
   **引入版本**：`afdac16`（2026-11-12，feat(colony): 团队模板 #224）—— 即 R1 基线里 auto 闸门就已经坏了，R1 未覆盖（colony 整个子系统漏跑，见 2.6）。

2. 即使把快照修对，UI 侧对 `status=active + task=done + gate=review` 的中间态仍无按钮（`team-panel.js:313 actionArea`）：`accept/reject` 要求 `pending_review`，`iterate/complete` 要求 `completed`，`extend` 要求 `halted`。→ 修复必须两端一起做，否则只会把"卡在 done"变成"卡在 pending_review"。

**第二个线上实例（同一根因的可复现闭环断点）**：
```
trun_l_I3KnbKCEu89v  status=active stage_idx=0(第2轮 baseline)  round=2  reworks=1
  history: 第1轮 6 阶段全部 accept（闭环一次成功）
  current_task: status=blocked, next_step="执行会话意外中断，已暂停当前工作…点击"答复并继续"恢复"
  → UI「去处理 →」详情里只有"查看执行会话 →"，没有"答复并继续"入口
```
→ 第 2 轮在第一步就停住，且中文提示要求的按钮在团队工作室里不存在（"答复并继续"只在会话工作卡/蜂群工作台里）。

### U3（P0·确定性）"没删除功能" —— 团队模板 / 团队项目 / 提案 三条 RPC 根本不存在

**复现（curl 直打）**：

```
POST /api/colony.team.template.delete  -> {"error":{"code":"unknown_method","message":"未知蜂群方法"}}
POST /api/colony.team.run.delete       -> {"error":{"code":"unknown_method","message":"未知蜂群方法"}}
POST /api/colony.team.proposal.delete  -> {"error":{"code":"unknown_method","message":"未知蜂群方法"}}
```
`lib/newbee/web/colony_api.ex:371-430` 的 `team_dispatch/2` 只有 templates / save / seed / proposals / start / decide / retry / sessions / runs / start / view / review / finish / extend，**没有任何 delete**；`Newbee.Colony.Team` 也**没有 delete 函数**（`grep -n delete lib/newbee/colony/team.ex` 空）。
UI 侧：模板卡片只有"🚀 用此模板开项目"，项目卡片只有"去处理/查看详情"，提案卡片只有"批准/重新规划/驳回"。

**已存在的删除能力（说明缺口是团队层，不是全局）**：
- 单会话删除：`session.delete`（侧栏 ⋯ → 删除 / 左滑删除），实测可删；
- 多选删除：`#delete-selected-sessions`；
- 工作组删除：`group.delete`（组头 🗑 删除）；
- **删除后不闭环**（新发现）：删掉团队子会话 `20261113-181830-07A2` 后 `session.delete` 返回 `{"deleted": ...}`、`session.list` 里也没有了，但
  - `colony.team.sessions` **仍然返回这条已删除的 session_id**（`session_map/0` 只按 `conversations` 表过滤，不做存活校验）；
  - 侧栏团队分组**仍然渲染它**（实测 DOM 里 `has07A2: true`，行文本 `20261113-181830-07A2 👑 项目总协调人 · 基线与环境校准 · 0 条`）；
  - 点它 → `localStorage.newbee.sid` 被设成已删 id，转录区退化成欢迎页（截图 `evidence/ui-05-ghost-team-session.png`）。
  - 磁盘上还留着 `~/.newbee/jspace/20261113-181830-07A2.md`（会话已删、随会话文件未清）。
  → 这就是"删除功能做了，但没闭环"的实证。

### U4（P1）团队项目缺"终止/归档"出口

`Team.finish/4` 只接受 `complete | iterate`，且 `complete` 要求 `run.status == "completed"`；`halted`（轮次用尽）只能 `extend`。**没有任何"我不做了，结束这个项目"的路径**：既不能取消，也不能归档，卡片会永久留在「项目」页。这与 U2 的中间态叠加，导致项目列表只增不减。

### U5（P1）侧栏团队分组的"管理"入口与工作室信息不同步

`team-panel.js:777` 给每个团队分组渲染 `<button class="tp-sgroup-manage">管理</button>`，实测点击后工作室面板的详情**只按 `state.detail` 定位 runId**，不会带上分组里的会话上下文；`session_map/0` 只用 `run["colony_id"]` 匹配 `conversations`，当同一 colony 下有多个 run（本项目就有 2 个）时会串（本项目两个 run 分属不同 colony，暂未触发；但 `session_map` 未按 `run_id` 过滤，属结构性风险，需 arch 判定是否本轮处理）。

## 4. 本轮基线 vs 第 1 轮基线（对照表）

| 指标 | R1（5ac87ba） | R2（5ed39a6，干净跑） | 判定 |
|---|---|---|---|
| 编译 dev/test 冷 | 81.9 / 101.1 s | 87.0 / 116.3 s | 同量级，非回归 |
| 编译警告（`--warnings-as-errors`） | 0 | 0 | 持平 |
| 格式违规文件 | 34 | **31** | 下降 3，未清零 |
| `node --test`（前端） | 32 tests / 0 pass | 32 tests / 0 pass | **持平（未修）** |
| `mix test.acceptance` | 14/14 | 14/14 | 持平 |
| `mix newbee.test_fast` exit | 1 | 1 | 持平 |
| `test_fast` 失败数 | 8（4/7 分区红） | 3（2/7 分区红；同 commit 并发时 15） | 下降但**依赖负载** |
| `test_fast` 覆盖 | 250 文件中 218 | 254 文件中 **221** | **缺口仍在（32 文件 / 283 用例）** |
| 能力索引字节 | 1941 > 1800 | **1941 > 1800** | 未修 |
| archive 回放 | 红 | 红 | 未修 |
| worktree 注册数 | 204 | **421** | 恶化 |

**R1 结论的可复用部分**：缺陷分类、最小复现命令、D1/D2/D3/D4/D5/D6 全部在 #229 上仍然成立（本轮逐条复验）。**R1 结论的失效部分**：`environment`/`collaboration`/`root` 的"失败清单"不再成立（本轮 collaboration 160 全绿、environment 149 全绿、root 只剩 1 条抖动）；`test_fast` 墙钟 1760.8 s → 1407 s（独占时段）说明 R1 的耗时含并发噪声。

## 5. 本轮产出的验收尺子（后续 100 轮共用，R2 版）

### 5.1 门禁 G1–G9（每条都可一条命令判定）

| 门 | 判定命令 | R2 基线 | 达标线 |
|---|---|---|---|
| G1 编译零警告 | `mix compile --warnings-as-errors` + `MIX_ENV=test` 版 | exit=0 / 0 警告 | 保持 0 |
| G2 格式 | `mix format --check-formatted` | exit=1，**31 文件** | **exit=0（0 文件）** |
| G3 门禁主判据 | `mix newbee.test_fast` | exit=1，**3 失败**（并发时 15） | **exit=0** |
| G4 覆盖完整 | 分区表落盘 + meta 测试比对 `Path.wildcard` | **221/254** | **254/254**（acceptance 单列） |
| G5 acceptance | `mix test.acceptance` | 14/14 | 保持 14/14 |
| G6 前端 | `node --test test/web/conversation-work.test.js` | **32/0** | **全绿并入 G3** |
| G7 种子稳定 | 失败文件集跑 seed 1/2/3 | **3 seed 全红 2 条 + 抖动 2 类** | 3 seed 失败集合**完全一致** |
| G8 全绿不被标志误杀 | 任一分区"用例全绿但 exit≠0" | **存在（web: 358 绿 / exit=1）** | **不存在** |
| G9 运行期 deprecation | 门禁日志中 `deprecation` 计数 | 3 条（永不判红） | 0 条 |

### 5.2 数值尺 M1–M15

| 尺 | 定义 | R2 基线 | R3 目标 |
|---|---|---|---|
| M1 | 能力索引 `Plugins.prompt_section()` 字节 | 1941 | ≤1800 |
| M2 | dev 冷编译 | 87.0 s | ≤100 s |
| M3 | test 冷编译 | 116.3 s | ≤130 s |
| M4 | dev 热编译 | 5.3 s | ≤10 s |
| M5 | test 热编译 | 5.1 s | ≤10 s |
| M6 | `test_fast` 端到端墙钟（独占时段） | 1407 s | ≤1500 s 且 G3 绿 |
| M7 | `test_fast` 声明用例数 | 1523 | ≥1806（+283 漏跑） |
| M8 | 漏跑文件数 | **32** | 0 |
| M9 | 格式违规文件数 | 31 | 0 |
| M10 | 前端套件通过数 | 0 / 32 | 32 / 32 |
| M11 | `worktree` 注册数 | 421 | ≤450 且**增量=0/次运行** |
| M12 | `.git/worktrees` 体积 | 36 MB | 不增长 |
| M13 | 浮点抖动用例数（3 seed 不一致） | 2 类 | 0 |
| M14 | `session_index_perf` 因果断言 | 红（测绝对墙钟） | 绿且断言与机器规模无关 |
| M15 | 团队面板"输入存活窗口" | **8 s（每 8 s 清空一次）** | **≥10 min 无清空（U1 达标）** |

### 5.3 用户反馈的 5 条可判定验收（U1–U5，交 pm/arch 接力）

| ID | 验收判据（可直接写成自动化用例） | 当前 |
|---|---|---|
| **U1** | 打开团队工作室 →「组建」页输入 20 字，**保持焦点静置 10 分钟**，断言：① textarea 节点同一性不变 ② `value` 不变 ③ `document.activeElement` 仍是它 ④ 重绘期间不得丢草稿（可加"离开再回来草稿还在"） | **红**：8 s 内即清空（20 s 采样 `node-replaced@500ms`，26 s 观察 3 次） |
| **U2** | 一个 `gate=auto` 阶段的团队项目，AI 提交成果后，**无需人工点击**，`run.stage_index` 前进；断言 `stage_index` 从 N → N+1 且新任务已派发。反向：把快照改回旧值必须让该用例红 | **红**：`stage_index` 三天未前进；`team_test.exs:213` 把缺陷固化为预期 |
| **U3** | `colony.team.template.delete` / `run.delete` / `proposal.delete` 三条 RPC 存在且幂等；删除后 `colony.team.templates|runs|proposals` 不再返回该 id；删除 run 时其子会话与工作项状态明确（级联或拒绝，二选一并写清） | **红**：三条均 `unknown_method` |
| **U3b** | 删除团队子会话后，`colony.team.sessions` 与侧栏团队分组**不再引用该 id**；点击不存在的 id 不得把 UI 切到"欢迎页" | **红**：删除后仍返回/仍渲染/点开变欢迎页 |
| **U4** | 团队项目具备"终止/归档"：`status=active|blocked|halted` 均可终止，终止后不进入"需要你处理"、不出现在默认项目列表（或进"已归档"分区），且子会话与工作项状态确定 | **红**：无此路径 |
| **U5** | 侧栏团队分组「管理」打开工作室时定位到**该 run**，且列表数据按 `run_id` 过滤（同 colony 多 run 不串） | 未验证（结构性风险） |

### 5.4 本轮建议的迭代范围（给 pm/arch 的输入，不代替其排序）

**A 批（必须，都是 P0 且已被本轮实证）**
1. U1 团队面板轮询守卫（`state.composing` / 焦点在 `.tp-body` 内跳过 `render()`，或改为 diff 更新）——**纯前端，最小改动，可单测（jsdom）**。
2. U2 auto 闸门快照陈旧（`runtime.ex:521` 重读任务）+ 修 `team_test.exs:213` 的错误预期 + 补"提交后阶段前进"用例。
3. U2b UI 中间态出口（`actionArea` 对 `active+done` 给"接受并推进/继续"）。
4. U3 团队层删除（3 条 RPC + `Team.delete_*` + 审计留痕），含 U3b 存活校验（`session_map` 过滤已删会话）。
5. G4 覆盖补齐（32 文件入分区 + meta 测试）+ G2 格式 31 文件 + G1 两条测试警告（web 分区"绿却红"的根因）。
6. G6 前端 32/32（替身补 `classList.toggle` 等 API + 6 处 `innerHTML` 契约）。

**B 批（可顺延 R3）**：U4 终止/归档、U5 run_id 过滤、M13 抖动两条、M14 性能断言重写、M1 能力索引 1941→≤1800、archive 测试定性。

**C 批（需授权/不改代码）**：M11/M12 worktree 泄漏清理（**破坏性，需用户授权**）、`/home` 只剩 6.2 G 的磁盘治理。

## 6. 未覆盖范围（如实声明）

1. **门禁只跑到 3 个失败就停**：`test_fast` 是"分区整体 exit"，一个分区里后面的用例仍全部执行，但**未做逐用例 JSONL 落盘**（R1 做过，本轮未重做），因此用例级耗时分位（p50/p90/p99）**本轮无数据**，沿用 R1 的 0.023/4.99/8.85/24.28 s 仅作参考。
2. **抖动 12 条未逐条归因**：只确认"并发时 15 失败 / 独占时 3 失败"，两条确定失败（tool_documentation_contract、archive）之外的 11 条未逐条复现（`environment` 在 R1 的 seed 851020 失败本轮未复现）。
3. **`archive_test.exs:360` 未定性**：仍红，R1 pm 的"产品对、测试错"结论本轮**未复核**。
4. **U2 的修复未实施**（本轮只做基线）：只到"根因 + 可复现证据"，未改一行产品代码。
5. **U5 完全未验证**：只做了代码走查（`session_map` 未按 run_id 过滤），未构造同 colony 双 run 的实验。
6. **真实模型调用未测**：所有 UI 复现都在"已有历史数据 + 无模型调用"下完成；AI 生成中的流式重绘对输入的干扰**未覆盖**（`conversation-work.js` 有 composing 守卫，团队面板没有，但未做"流式 + 面板同时"实验）。
7. **浏览器只有 Chromium headless**：未在 Firefox/WebKit/移动视口/真机验证；`document.hidden` 在 headless 恒为 `false`，所以"切后台暂停轮询"这条豁免**未被真正触发**（真浏览器切标签才会触发）。
8. **移动端/H5 未测**：侧栏、面板在窄屏的表现未覆盖。
9. **`/home` 磁盘 91%**：本轮所有数据在 6.2 G 剩余空间内完成，未做容量压力测试；`test_fast` 的 1.4 万个 worktree 新增属既有问题未处理。
10. **未提交、未推送、未合并**：本轮交付全部留在 `.worktrees/main-r2`，主仓库在途改动与 4 个未跟踪目录未触碰。

**U3b 追加证据（删除→复活）**：点开那条"幽灵"团队会话后，`~/.newbee/sessions/20261113-181830-07A2.jsonl` 被**重建为空文件**，`session.list` 又出现了它（`total` 57 → 58，`running: true`，`title: ""`）。
即：**一次点击把已删会话复活成一个空会话**，而 `colonies/conversations` 里那条 `{"id": "…07A2", "colony_id": "col_l_5XEEBM5PkZPQ", "task_id": "task_l_3-ocKV73BDs1", "bee_id": "bee_l_KRvmUJ1TCeEf"}` 从未被清理 —— 所以 `colony.team.sessions` 永远会把它列回来。
→ 验收判据补一条：**删除团队子会话后，`colonies/conversations` 对应记录必须同时清理（或标记 archived），否则"删除"在团队视图里不可见地回滚。**

## 7. 复现脚本自身的端到端验证（第三次同 commit 门禁）

`bash baseline-r2/repro.sh`（`SKIP_GATE=1` 只跳过后半段）真实跑通一次：

```
[repro] version: 5ed39a6e8feece2cbfe3c1d309768769eb265c98
[repro] deps -> /home/alanx/data/git/newbee/deps
[repro] dev-cold exit=0 wall=8s      <- 注意：_build 已热，不是真正冷编译
[repro] test-cold exit=0 wall=6s
[repro] dev-warm exit=0 wall=4s
[repro] test-warm exit=0 wall=6s
[repro] format exit=1 wall=3s
[repro] node-test exit=1 wall=1s
[repro] acceptance exit=0 wall=102s
[repro] testfast exit=1 wall=1184s
REPRO exit=0   （脚本自身成功；G3 门禁红）
```

⚠️ **口径说明**：`repro.sh` 里的 `*-cold` 只删日志不删 `_build`，因此**重跑时表现为热编译（6–8 s）**；本文档 2.1 的 87.0/116.3 s 来自 `rm -rf _build` 后的真实冷编译。要复现冷数字必须先 `rm -rf _build`。

### 7.1 三次门禁的失败集合（同 commit、同 seed=1，负载不同）

| 次 | 环境 | 失败数 | 失败集合 |
|---|---|---|---|
| A | 与 seed 测试并发（loadavg 6.5） | **15** | 见 `logs/testfast.log`（11 个文件，含 web/collaboration 大量超时） |
| B | 独占时段 | **3** | tool_documentation_contract、command_job、archive |
| C | `repro.sh`（moderate） | **4** | tool_documentation_contract、media_test、fs_walk、archive |

**三次全红的只有 2 条**（= §2.7 的种子稳定结论，互相印证）：
`tool_documentation_contract_test.exs:8`（1941 > 1800）、`archive_test.exs:360`。
**其余全部是负载敏感的抖动**：A 次 13 条、B 次 1 条（command_job）、C 次 2 条（media_test / fs_walk）。
→ **G3 的判定必须绑定"独占时段 + 记录负载"**，否则同一 commit 会给出 3 / 4 / 15 三个不同答案。这是本轮新增的**方法论要求**，写进下面的门禁规范。

### 7.2 门禁规范补充（R3 起生效）

1. 门禁结果必须同时记录：`git rev-parse HEAD`、`/proc/loadavg` 起始值、`nproc`、`TMPDIR` 剩余空间。
2. **不许**在 `mix test` 之外并发跑任何 `mix test`（本轮 A 次 15 vs B 次 3 就是教训）。
3. "失败"必须落成**逐用例清单**（文件:行 + 用例名），不能只报分区 exit。
4. 判定"确定性失败"以 **≥3 次独立运行全红**为门槛（本轮 2 条达标）。

## 8. 本轮（R2）目标与"判定即用"验收尺子

> 本节是给 pm / arch / dev / qa 的直接输入：每条都有**命令 + 期望输出 + 反向验证**，不需要再解释。

### T1 团队工作室不再吃掉输入（对应 U1）

- 判据命令（回归用例，建议放 `test/web/team-panel.test.js`，jsdom）：
  `node --test test/web/team-panel.test.js` → 用例「面板轮询重绘时保留正在编辑的输入」绿。
- 期望行为：`state.composing` 或"焦点在 `.tp-body` 内"时，`load(false)` **只更新数据不重绘**；或改成按 key diff（不 `innerHTML=""`）。
- 反向验证：把守卫删掉 → 该用例必须红。
- 真实浏览器验收（人工或 Playwright，10 分钟）：打开工作室「组建」→ 输入 20 字 → 静置 10 min → 文字与焦点都在；切到别的 tab 再切回来，草稿仍在。

### T2 auto 闸门真的推进（对应 U2）

- 判据命令：`mix test test/newbee/colony/team_test.exs` → 新增用例「auto 闸门：提交成果后 stage_index 前进」绿；
  且 `team_test.exs:213` 那条 `{:ok, :ignored} = Team.stage_complete(dev_task)` **必须改写**（它把缺陷写成了预期）。
- 期望行为：`lib/newbee/colony/runtime.ex:521` 改用 `Work.submit/4` 之后的**最新任务**驱动 `stage_complete/1`。
- 反向验证：把 `Stage_complete` 调用改回旧快照 → 新用例必须红（证明它测的是真行为）。
- 端到端：新建一个 2 阶段 auto 模板，跑完 → 无需人工点击前进到第 2 阶段。

### T3 卡住的中间态有出口（对应 U2b）

- 判据命令：`node --test test/web/team-panel.test.js` 用例「active + task=done 时提供接受/继续按钮」。
- 期望行为：`actionArea` 对 `status=active && current_task.status in [done, pending_review]` 给出可点击出口（接受并推进 / 打回重做）。
- 反向验证：删掉分支 → 用例红。

### T4 团队层可删除（对应 U3 / U3b）

- 判据命令（curl 三条，期望 `ok`）：
  ```
  POST /api/colony.team.template.delete {"templateId": ...}
  POST /api/colony.team.run.delete      {"runId": ...}
  POST /api/colony.team.proposal.delete {"proposalId": ...}
  ```
  删除后再查 `colony.team.{templates,runs,proposals}` → 不含该 id。
- 期望行为：删除必须同时清理 `colonies/conversations` 对应记录（否则团队视图会把已删会话列回来）；删除 run 时子会话与工作项**二选一并写清**（级联删除 / 拒绝并提示）。
- 反向验证：删掉 conversations 清理 → `colony.team.sessions` 又出现该 id（本轮已实证：删了 session、`total 57→58`、点一下又复活成空会话）。

### T5 门禁真绿（G1–G4 + G6 + G8）

- `mix newbee.test_fast` → **exit=0**（当前 3~15 失败，取决于负载）。
- `mix format --check-formatted` → **exit=0**（当前 31 文件）。
- web 分区 `358 passed / 0 failed` 必须 **exit=0**（当前 exit=1，因 2 条测试文件编译警告）。
- `node --test test/web/conversation-work.test.js` → **32/32**（当前 0/32）且并入 G3。
- 分区表覆盖 **254/254**（当前 221），并加 meta 测试：删掉分区表任一行 → meta 测试必须红。

### T6 结果可判定（G7 + 方法论）

- 3 个 seed 跑同一批文件 → 失败集合**完全一致**（当前 2 条稳定 + 2 类抖动）。
- 门禁必须落**逐用例清单**（文件:行 + 用例名），并记录 `loadavg` / `nproc` / `TMPDIR` 余量。
- 判定标准：≥3 次独立运行全红 = 确定性失败；否则记为抖动并单独开条目。

### 建议的 R3 顺序（成本/收益）

1. **T1**（纯前端 1 处守卫 + jsdom 用例）—— 直接消除用户"输入不了字"的痛感，风险最低。
2. **T2 + T3**（后端 1 行快照修正 + 测试预期修正 + UI 出口）—— 直接消除"项目不闭环"的主因。
3. **T5 的 G2/G1/G8**（格式 31 + 2 条测试警告 + 门禁判定口径）—— 让"绿"变成可信信号。
4. **T4**（3 条 RPC + 级联清理 + 审计留痕）—— 功能缺口，工作量最大。
5. **T5 的 G6 + G4**（前端 32/32 + 分区补齐 32 文件）—— 补网，防止再漏掉 colony 这种整子系统。

## 9. 证据索引与自检

| 声明 | 证据文件 |
|---|---|
| 编译 87.0/116.3/5.3/5.1 s，0 警告 | `logs/{dev-cold,test-cold,dev-warm,test-warm}.log`、`summary.txt` |
| 格式 31 文件 | `logs/format.log`、`format-violations.txt` |
| 前端 32/0 | `logs/node-test.log` |
| acceptance 14/14 | `logs/acceptance.log` |
| 门禁 A 次 15 失败 | `logs/testfast.log` |
| 门禁 B 次 3 失败（主判据） | `logs/testfast-clean.log` |
| 门禁 C 次 4 失败（复现脚本） | `logs/testfast.log`（被 repro.sh 重写）+ `logs/repro-end-to-end.log` |
| 漏跑 32 文件 | `logs/missing32.log`、`missing-files.txt` |
| seed 稳定性 | `logs/seed2.log`、`logs/seed3.log`、`failing-files.txt` |
| web 分区绿却红 | `logs/warn-a.log`、`logs/warn-b.log`、`logs/warn-iso.txt` |
| U1 面板清空 | `evidence/ui-02-typed-before-wipe.png`、`ui-03-typed-after-wipe.png` |
| U2 停滞项目 | `evidence/ui-04-blocked-run-detail.png`、`evidence/stall.py` 输出（5758.8 min ≈ 4.0 天） |
| U3 缺删除 | curl 三条 `unknown_method`（本文 §3 U3 内粘贴原始返回） |
| U3b 幽灵会话 | `evidence/ui-05-ghost-team-session.png`、`evidence/inspect_store.py` |
| 工作树/磁盘 | 本文 §2.9（421 条、36 MB、91%） |

**自检（本会话已执行的核对）**
1. 主仓库 `git status` 开工/收工一致（10 M + 4 未跟踪），未触碰任何在途文件。
2. 工作树 HEAD = `5ed39a6` = `origin/main`；未 commit / 未 push。
3. 文档里每个数字都能对应到 `logs/` 下的文件；没有推断值。
4. `metrics.json` 通过 `json.load` 校验。
5. `repro.sh` 通过 `bash -n` 且**真实跑通一次**（exit=0，门禁红如实记录）。
