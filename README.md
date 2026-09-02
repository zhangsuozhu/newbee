# 🐝 newbee — 自我进化的共生 Elixir 环境

### Self-Evolving Symbiotic Elixir Environment

> **不是让 AI 替你写代码，而是把 AI 放进一座它自己会翻修、会进化、会记忆的房子里。**
>
> *Not just AI writing code — AI living inside a house it continuously rebuilds, remembers, and evolves.*

[![Elixir](https://img.shields.io/badge/Elixir-1.18%2B-4e2a8e?logo=elixir)](https://elixir-lang.org)
[![OTP](https://img.shields.io/badge/OTP-29-red?logo=erlang)](https://www.erlang.org)
[![License](https://img.shields.io/badge/license-MIT-green)](LICENSE)
[![Design](https://img.shields.io/badge/design-736_lines-blue)](DESIGN.md)

<p align="center">
  <b>长期存活 · 版本化 · 可回退 · 自我进化</b><br/>
  <em>Long-lived · Versioned · Rollback-able · Self-Evolving</em>
</p>

---

## ✨ 一句话介绍 / One Sentence

**中文：** newbee 是一个**长期运行、版本化、可自修改**的 Elixir 环境——大模型用 Elixir 作为手和脑完成任务，环境则根据真实使用证据持续把自己改得更聪明、更便宜，每一次改变都可评价、可回退、可归因。

**English:** newbee is a **long-lived, versioned, self-modifying** Elixir environment — the LLM uses Elixir as its hands and brain to get work done, while the environment continuously rewrites itself to be smarter and cheaper based on real usage evidence. Every change is evaluable, rollback-able, and attributable.

---

## 🔥 为什么 newbee 让人激动 / Why It's Exciting

| 传统 Agent (Claude Code / Codex) | **newbee** |
|---|---|
| 一次性沙箱，用完即焚 | **常驻生命体 daemon** — 关掉终端，环境继续存活、记忆、进化 |
| 每轮重传上下文，越来越贵、越来越笨 | **光头优先 (Bald-First)** — 知识住环境不住 prompt，工具面封顶 3 个 |
| 固定工具集，模型只能将就 | **一切皆 Plugin** — 工具/规则/提示/provider 皆可版本化热插拔 |
| 黑盒进化，无质检 | **五层评价 + 失败抗体** — 静态/确定性/反事实/真实使用/纵向，单调免疫 |
| 单 loop 串行干活 | **Worker / Adapter 双模型** — 前台干活，后台进化，激励隔离 |
| 上下文是日志，越积越乱 | **Event Sourcing** — 上下文是日志的物化视图，任意时点可重建 |

> **Claude Code 是"模型吩咐工具干活"；newbee 是"模型住在它自己持续翻修、且每块砖都有质检记录的房子里干活"。**
>
> *Claude Code is "model telling tools what to do." newbee is "model living in a house it keeps renovating — with a quality stamp on every brick."*

---

## 🧠 三大第一性原则 / Three First Principles

### 1) 上下文极简主义 · Context Minimalism (光头优先 Bald-First)
> 上下文臃肿不只是贵，是**变笨**。环境每编译掉一个模式，模型的上下文需求就永久降一分。

- 可见工具面仅 `run_elixir` / `done` / `ask` 三个 —— 其余能力住在环境里，按需拉取
- 大文件、AST、搜索结果留在环境 binding，模型只持变量名 — 最大头的 token 节省
- *Only 3 tools visible to the model. Knowledge lives in the environment, not the prompt. Every pattern compiled into the environment permanently reduces context needed.*

### 2) 环境能力全模块化 · Everything is a Plugin
> 没有例外层，没有旁路。一种形态，统一治理。

- `tool | rule | prompt | workflow | provider | verifier | projection | stateful_service` 全是 Plugin
- 不可变 Release + 原子激活 + 一键回退 + 依赖解析 + 能力门校验
- *No exceptions, no side doors. One abstraction to govern them all.*

### 3) 模型自治，宿主守物理边界 · Model Autonomy, Host Guards Physics
> 自治的激进程度与安全网厚度成正比。

- Worker 和 Adapter 都是模型，拥有请求/实现/评价/激活/回退的自治权
- Host Shell (Ring 0) 只拦三件事：凭证泄露、越宿主边界、不可恢复破坏
- *The more radical the autonomy, the thicker the safety net.*

---

## 🏗️ 架构一览 / Architecture

```
┌─────────────────────────────────────────────────────────────┐
│  Host Shell (Ring 0) — 唯一不可被模型覆盖的边界              │
│  凭证/路径/资源/审计/紧急停用 · credential & boundary guard  │
├─────────────────────────────────────────────────────────────┤
│  Environment Coordinator — Change/Release/Revision 状态机    │
│  唯一写入者 · 串行指针转换 · 并行委托评测                    │
├─────────────────────────────────────────────────────────────┤
│  Event Store (checksum frame · 单调 id · durability 三档)   │
│  唯一同步事实 · 可回放 · 崩溃截断安全                        │
├─────────────────────────────────────────────────────────────┤
│  Evaluator Pool / Generation Manager + Binding Continuity   │
│  隔离 BEAM 节点 · active/candidate 双 generation             │
│  quiesce → snapshot → codec 白名单 → 原子切换 → 排空        │
├─────────────────────────────────────────────────────────────┤
│  Plugin System (Contract · Manager · Supervisor)            │
│  声明式 capabilities · effect 登记 · 泄露检查               │
├─────────────────────────────────────────────────────────────┤
│  TUI / CLI — 薄客户端，可 detach，只消费 Projection          │
└─────────────────────────────────────────────────────────────┘
         ↕                  ↕                  ↕
     Worker Agent      Adapter Agent      Advisor (optional)
     前台干活           后台进化            旁观评审
```

**环境是常驻生命体，TUI 只是探视窗。** `newbee daemon` 让环境在终端关闭后依然存活、记忆、进化；`newbee attach` 随时接回。

*The environment is a living organism. The TUI is just a window. Close the terminal — it keeps living, remembering, evolving.*

---

## 🚀 核心创新 / Core Innovations

### 🧬 绑定持久化 + 跨 Generation 迁移
专属 IEx：`run_elixir` 变量跨轮存活。大文件、AST、搜索结果留在环境侧，模型只传变量名。Generation 切换时经 **quiesce → 快照 → 白名单 codec → 校验哈希 → 原子切换**，零丢失。

*Your IEx never dies. Large artifacts stay in the environment; the model only holds names. Zero-loss migration across generations.*

### 🔌 Plugin = 能力的唯一形态
一个 Plugin 可含多源文件、测试、资源与声明。`capabilities` 声明式清单在 pre-execute 被物理拒绝，未声明的能力寸步难行。有状态插件的 `ets/pg/pubsub/process` 必须经 wrapper 登记，泄露即告警。

*One Plugin can carry multiple files, tests, and resources. Undeclared capabilities are physically rejected. Stateful effects must be registered — leaks are detected.*

### 🛡️ 五层评价 + 失败抗体
`静态 → 确定性 → 反事实回放 → 真实使用 → 纵向` 五层裁判。失败用例沉淀为**单调增长的抗体**，独立回放验证，永不回归。`fitness / price_tag / convergence` 用真实使用数据给每个 Release 打价签。

*5-layer verdict: static → deterministic → counterfactual replay → real usage → longitudinal. Failures become monotonic antibodies — never regress.*

### ⚡ 认知 JIT — 环境是 JIT 编译器
持续把"需要模型推理的智能"编译成"不需要推理的结构"：`教训 → 沉睡规则(L1) → 蒸馏工具(L2/L3)`，热度剖析驱动晋升，退化即 deopt。沉睡规则平时零 context，犯错当口精准注入。

*The environment is a JIT compiler for cognition: lessons → sleeping rules → distilled tools. Hot paths get promoted; regressions get deoptimized. Zero cost until triggered.*

### 🔄 Event Sourcing + 物化视图
上下文不是日志，是日志的**物化视图**。compaction 改视图不动日志，任意时点可重建。Event Store 单调 `event_id`、checksum frame、durability 三档、崩溃截断安全。

**会话档案库（Archive）把这句话落到会话 transcript 上**：压缩 = 归档（append-only 账本 + sha256 内容寻址段），不是覆写。早期对话分层蒸馏——确定性事实账本（用户意图逐字、文件、✗→✓ 错误对）+ 每段一次的 LLM digest（永不"摘要的摘要"）；被压缩的原文随时 `Newbee.read("history://q/关键词")` 拉回。**在 newbee 里，忘记不是一个不可逆操作。**

*Context is not the log — it's a materialized view of the log. Rebuild any point in time. Crash-safe, checksummed, monotonic.*

### 👥 Worker / Adapter 双模型拓扑
前台 Worker 用 active 环境干活，后台 Adapter 用 candidate 环境进化。通过 **Agent Protocol (outbox/inbox 去重 + 幂等键)** 解耦，激励隔离，互不阻塞。

*Foreground Worker ships. Background Adapter evolves. Decoupled via idempotent protocol, isolated incentives.*

---

## ⚡ 快速开始 / Quick Start

```bash
# 工具链 — OTP 29 + Elixir 1.20
export PATH=$HOME/toolchains/otp-29/bin:$HOME/toolchains/elixir-1.20/bin:$PATH

mix deps.get

# 配置模型 (OpenRouter 示例) — 凭证永不进仓库
mkdir -p ~/.newbee
cat > ~/.newbee/model.json <<'EOF'
{
  "providers": {
    "openrouter": {
      "baseUrl": "https://openrouter.ai/api/v1",
      "apiKey": "${OPENROUTER_API_KEY}",
      "models": []
    }
  },
  "roles": {
    "default":  { "provider": "openrouter", "model": "deepseek/deepseek-v4-flash-0731" },
    "worker":   { "provider": "openrouter", "model": "deepseek/deepseek-v4-flash-0731" },
    "adapter":  { "provider": "openrouter", "model": "deepseek/deepseek-v4-flash-0731" }
  }
}
EOF
# 支持标准 Responses API `previous_response_id` 的 provider 可配置：
# `"api": "openai-responses", "responsesContinuation": true`。该选项会发送
# `store: true` 以允许跨进程续接；兼容网关未实现或不接受服务端存储时保持 false。
# 失效的 response id 会自动回退完整请求。
export OPENROUTER_API_KEY=sk-or-v1-...

# 启动
./bin/newbee            # 全屏 TUI (推荐)
./bin/newbee cli        # 单列流式 CLI
./bin/newbee daemon     # 常驻 daemon — 后台自动进化
./bin/newbee attach     # 接回最近会话 (记忆仍在)
./bin/newbee bench      # 公开基准
./bin/newbee doctor     # 环境体检
```

---

## 🎨 TUI 体验 / TUI Experience

对齐 `codex` / `Claude Code` 的沉浸式交互：

- 单列流式对话：模型输出、思考流(灰色)、工具块、审计事件依次追加
- `Enter` 发送 · `\` 续行 · `↑/↓` 历史(跨会话持久) · `Tab` 补全(`@路径` / 命令)
- `Esc` 中断执行 · `Ctrl-C` 清输入/退出 · `Ctrl-L` 重绘 · `PgUp/PgDn` 翻屏
- `Ctrl-T` 切换窗格(绑定/事件日志/工具块/输入队列) · 括号粘贴 · 状态栏(模型/工程/token/绑定/策略)

**命令 / Commands:** `/model` `/bindings` `/tokens` `/rules` `/dump` `/resume` `/reset` `/approve` `/reject` `/log` `/snapshot` `/rollback` `/evolve` `/policy` `/genes` `/bench` `/goal` `/diff` `/undo` `/session` `/init` `/tools` `/permissions` `/compact` `/quit` · TUI 内 `/reasoning` 切换思考流 · `@文件` 引用 · `!shell` 执行

*Single-column streaming, reasoning in grey, tool blocks, audit events — all flowing. Every keybinding you expect, plus project-aware superpowers.*

---

## 🌐 WebUI（浏览器控制台，支持 HTTPS + 登录）

浏览器里的工作台：文件浏览、git 操作（diff/checkpoint/PR）、agent 会话管理，走 JSON-RPC over HTTP/WebSocket。

```bash
# 本地（零摩擦，免登录）
./bin/newbee web

# 远程安全访问（HTTPS + 登录 + 图形验证码防暴破）
./bin/newbee web --https --host 0.0.0.0 --set-password
# 设置后每次访问：密码 + SVG 验证码登录拿 token → Bearer 认证
```

**安全模型：**
- **本地（回环地址）免认证** —— 绑定 `127.0.0.1` 时全放行，开发零摩擦
- **远程（非回环）强制认证** —— 除登录接口外一律要求 `Authorization: Bearer <token>`（WebSocket 用 `?token=`），未登录 `401`
- **图形验证码防暴破** —— SVG 验证码 + 登录失败限流
- **HTTPS 自签证书** —— RSA 2048，首启自动生成于 `~/.newbee/web/{cert,key}.pem`（私钥 `chmod 600`），零外部依赖
- **自定义证书** —— `--certfile/--keyfile` 挂 mkcert/CA 证书；或反代（nginx/caddy）终止 TLS
- **HTTP→HTTPS 重定向** —— `--redirect` 起一个只做 308 跳转的 HTTP server

> ⚠️ 远程暴露**必须**配 `--https`（或反代 TLS），否则密码与 token 明文传输。浏览器首访自签证书会提示警告，点继续即可；要绿锁用 CA 签发证书或反代。

---

## 🧰 工具调用约定 / Tool Contracts

模型对外仍只看到 `run_elixir` / `done` / `ask`。环境内工具遵循一套稳定约定：

- **文本局部编辑只有一个入口**：`Newbee.Tools.Edit.show/2` + `patch/1`。读取返回一次文件快照 tag 和普通行号；补丁使用 `PUT N..M`、`CUT N..M`、`PUT <N`、`PUT >N`。旧逐行 hash 和 `Edit.V2` 已删除。
- **安全生成 Elixir 源码**：包含插值、sigil 或 heredoc 时，先用 `Newbee.Tools.Edit.source_literal/1` 包装目标文本，避免外层 cell 提前插值或分隔符嵌套。
- **可恢复错误是值**：工具返回 `{:error, %{reason: atom(), hint: String.t(), ...}}`；带 `!` 的函数保留 Elixir 的抛异常语义。
- **简单 GET 优先统一读取**：只要正文时用 `Newbee.read("https://...")`；需要 POST、headers、status 或网络错误分类时用 `Newbee.Tools.Http`。
- **浏览器自动化**：需要真实渲染、点击/输入、DOM 查询、下载、PDF 或截图时用 `Newbee.Tools.Browser.run/1`；默认使用隔离 Playwright，只有明确授权才使用 `backend: "screen"` 操作现有 Chrome。

- **避免重复入口**：Scaffold 只做工程创建/依赖；编译测试用 Run。长命令使用 `Run.sh(..., timeout: ms)`，没有 `sh_long` 或项目专用 Django helper。
- **按需说明不重复**：`Newbee.read("tool://模块名")` 展示用途/示例和编译器真实签名。

Edit 完整协议、错误类别和示例见 [`docs/edit-design.md`](docs/edit-design.md)。

---

## 📦 项目结构 / Project Structure

```
lib/newbee/
├── agent/          # Worker / Adapter / Explorer / Loop / Protocol / Progress
├── dee/            # Evaluator (隔离 BEAM 节点) / EvalWorker / Rules / Result
├── environment/    # Coordinator / Store / Manifest / Release / Revision
│                  # Plugin* / Generation / EvaluatorPool / Antibodies
│                  # Verifier / PPT / Fitness / JIT / Autonomy / Projection
├── llm/            # Client (OpenRouter SSE) / Config
├── plugins/        # RepoMap / Provider.OpenRouter (无凭证适配器)
├── tools/          # Fs / Edit / Structural / Run / Git / Search / ...
├── tui/            # Screen / Cards / History / Key / Highlight
└── host/           # Shell (Ring 0) — 凭证/边界/审计

~/.newbee/jspace/   # J-Space 长任务台账（可用 NEWBEE_JSPACE_DIR 覆盖）
.newbee/            # 项目权威快照 (被 gitignore，重启完整恢复)
```

---

## 🧪 测试与基准 / Testing & Benchmarks

```bash
mix test                          # 全量测试
mix test test/newbee/acceptance_test.exs  # §15 架构验收 (12 项)
mix newbee.bench                   # 真实 LLM 公开基准
mix newbee.doctor                  # 工具链/配置/目录体检
```

- 全套件 **282–284/287** 通过 (OTP 29 + Elixir 1.20)，`acceptance` 单跑 12/12 全过
- *Full suite 282–284/287 passing, acceptance 12/12 green in isolation.*

---

## 🗺️ 路线图 / Roadmap

- [x] EventStore / Environment.Store / 对象模型 (Release/Change/Revision)
- [x] PluginContract + Manager + Supervisor + 内置插件 registry
- [x] BindingCodec + Generation + EvaluatorPool
- [x] Antibodies + Verifier 五层 + PPT 锦标赛
- [x] Autonomy 档位 + Fitness 价签 + JIT 三级晋升
- [x] Coordinator 状态机 + Agent.Protocol + Projection + Host.Shell
- [ ] 多后端 Provider (Ollama 本地路由)
- [ ] 分布式 Evaluator 集群
- [ ] 可视化 Fitness 看板

---

## 🤝 贡献 / Contributing

```bash
git clone <your-fork>
mix deps.get && mix test
# 改 DESIGN.md → 提 PR，附 acceptance 证据
```

---

## 📄 许可证 / License

MIT — 详见 [LICENSE](LICENSE)

---

<p align="center">
  <b>Built with Elixir. Evolved by models. Guarded by physics.</b><br/>
  <em>用 Elixir 构建 · 由模型进化 · 以物理边界守护</em>
</p>

<p align="center">
  <a href="DESIGN.md">📖 设计文档 Design Doc</a> ·
  <a href="priv/jspace/SKILL.md">🗂️ J-Space 台账</a>
</p>
