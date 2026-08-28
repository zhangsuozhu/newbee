# Newbee.Tools 工具易错点压力测试报告

> 测试时间：会话内执行
> 测试方法：模拟 LLM 在 DEE 里调用 `Newbee.Tools.*` 做读/改/新建操作，对每个工具跑"正确调用 + 常见错误调用"共 74 组，捕获真实返回与异常。
> 语料：Elixir(`reader.ex`)、Python(`cert_generator.py`/`transfer_channel_rule.py`)、C(`sqlite3.c` 9MB/`aarch64_init.c`)、TS(`typescript.ts` 9MB/`page_catalog.ts`)、JS(`undici_index.js`)，取自本工程与 `/home/alanx/data/git/S01`。
> 外网不通，网络类结论基于本地失败复现 + 工具源码核对。

## 一、总览（74 组调用）

| 工具 | 调用数 | 成功 | 失败/异常 |
|------|-------:|-----:|----------:|
| Edit(V1) | 15 | 0 | 15 |
| Edit.V2 | 14 | 3 | 11 |
| Fs | 15 | 5 | 10 |
| Git | 4 | 3 | 1 |
| Http | 2 | 0 | 2 |
| Introspect | 3 | 2 | 1 |
| Json | 3 | 1 | 2 |
| Run | 4 | 2 | 2 |
| Scaffold | 2 | 0 | 2 |
| Search | 6 | 4 | 2 |
| Structural | 6 | 3 | 3 |

失败根因可归为 4 类：
1. **工具自身缺陷 / 文档与实现不一致**（Edit V1 锚点全失败、Scaffold API 名错、Git 参数语义错）
2. **返回形态与文档/惯例不符**（Edit.show 返回裸 map 且 `lines` 是行数、Fs 用 `{:ok,_}` 而 Edit 用裸 map、V2 用 `%{status:}`）
3. **错误输入导致崩溃（未捕获异常）而非友好报错**（Search 非法正则抛 Regex.CompileError、Fs 越界抛 ArgumentError）
4. **严格约束踩坑**（Edit.V2 每次改动必须 re-show、Structural 不校验函数体、Run 高危命令部分放行）

---

## 二、各工具易错点明细

### 2.1 Edit（V1 哈希锚点编辑）—— 最严重，几乎不可用
**结论：在当前环境下 `Edit.patch/1` 对任何合法锚点格式都稳定返回 `锚点格式错误`，无法完成任何编辑。** 已用最小样例（全新 3 行文件、严格按文档 `N.#8位hash` 格式、每行重新 show）复现，成功率 0/15。

典型失败：
```
[mini.ex#feaa2e6f]
PUT 2.a3f85f3c|1.29393f9b:
+  def hello(name), do: "hi " <> name
→ ERR: 锚点格式错误: 2.a3f85f3c（应为 N.#8位hash）
```
所有变体（单锚点、无尾冒号、`N#hash` 分隔）均失败。源码 `@anchor_re = ~r/^(+).#([0-9a-f]{8})$/` 在 REPL 单独测试能匹配，但运行时 `parse_single_anchor/1` 始终走失败分支——疑似运行时 beam 与 `parse_line`/`@line_re` 非贪婪 `(.+?)` 解析链存在未文档化的耦合问题（疑似旧 beam 或字符串尾随字符污染）。**LLM 一旦选 V1 必卡死**。

易错点清单：
- 锚点格式 `N.#hash` 极难手搓正确（需从 `show` 文本里逐行抠 hash，且 `|` 分隔上下文）；
- `show/2` 返回**裸 map 而非 `{:ok, map}`**（文档写"返回 %{tag,...}"但 LLM 常按 `Fs.read` 的 `{:ok,_}` 解构 → MatchError）；
- `show` 返回的 `lines` 字段是**整数行数**，不是行列表，真正带锚点的文本在 `text` 字段（LLM 误以为 `lines` 可遍历）；
- 上下文锚点必须与目标行**相邻**（非相邻 → `上下文锚点必须与目标行相邻`）；
- 内容行**必须**以 `+` 开头（忘写 → ParseError，不再静默丢行）；
- 节头必须 `[path#tag]` 用方括号（缺 `[` → ParseError）。

### 2.2 Edit.V2（快照行号编辑）—— 真正可用，但有严格约束
成功率 3/14（失败多为 stale，符合设计）。**这是 LLM 应该优先使用的编辑工具。**
- 语法简单：`PUT N..M:` / `PUT <N:` / `PUT >N:` / `CUT N..M`，纯行号，无需锚点。
- 错误 tag（`#deadbeef`）→ `节头格式错误 ... 应为 [path#12位tag]`（注意 V2 tag 是 12 位，V1 是 8 位，混用会错）。
- **致命约束：文件每次变化后必须重新 `show` 取新 tag**，否则 `RejectError: 文件已变化（stale）`。LLM 连续多次编辑同一文件极易踩（每次 patch 前都要 re-show）。
- no-op（写入相同内容）也会被 stale 拒（因文件已变）。

### 2.3 Fs（文件读写）
成功率 5/15（含正确读、ls、exists?、write、tree）。
易错点：
- `Fs.write/2` 经 Staging 暂存，**返回的是暂存条目 id 而非 `{:ok, :ok}`**，且未启动时降级直接落盘——LLM 难判断"写完没"。
- **路径越界**：写 `/etc/...` 抛 `ArgumentError`（软边界，仅约束推荐 API，模型仍可 `File.write!` 绕过）。
- `Fs.read` 对不存在文件返回 `{:error, :enoent}`（友好），但 `Fs.read!` 会**抛异常崩溃**——LLM 常混淆 `read`/`read!`。
- `Fs.ls` 对文件（非目录）或对不存在目录返回意外形态（非 `{:error}`），需自行判空。
- 读 9MB 大文件（sqlite3.c）`Fs.read` 能返回但体积巨大，挤爆上下文——应用 `Newbee.read` 的 512KB 截断或针对性搜索。

### 2.4 Search（grep/find）
易错点（成功率 4/6）：
- **`grep` 对非法正则直接抛 `Regex.CompileError` 崩溃，未捕获**（如 `([a-z` 漏 `]`）。这是 LLM 最高频踩坑：模型生成的正则常带未闭合字符类 → 整个工具调用炸，且错误形态是底层异常而非友好 ParseError。
- `find` 对不存在目录返回 `[]`（不报错，LLM 可能误判"没找到" vs "目录错"）。
- 路径用相对工程根，跨目录搜需显式传 `dir`。

### 2.5 Run（shell 执行）
易错点（成功率 2/4）：
- 返回 `%{exit:, output:}`，**不是 `{out, code}` 元组**——LLM 按 `{out, 0} = Run.sh(...)` 解构必 MatchError。
- 高危命令拦截**不全面**：`rm -rf /tmp/x` 返回 `exit=0`（只拦 `/` 根与 `git push` 等），LLM 误以为 rm 全被拦 → 实际可删非根目录。
- 超时返回 `exit: :timeout`（需单独判，否则当整数处理）。
- 不存在命令返回 `exit=127` + stderr，需读 `output` 才能知失败原因。

### 2.6 Structural（AST 编辑，仅 Elixir）
易错点（成功率 3/6）：
- **`insert_function` 不校验函数体语法**：传入 `"this is not valid elixir ((("` 仍返回 `:inserted` 成功，文件被静默写入非法代码，下次编译才暴露——危险。
- 第二个参数是**运行时已加载的 module atom**（如 `Newbee`），传不存在/未加载模块 → `:module_not_found`。LLM 易把"文件路径"当模块参数。
- 对非 Elixir 文件（.py）调用 → 抛 Sourceror 解析异常（底层崩溃），非友好错误。

### 2.7 Git
易错点（成功率 3/4）：
- **参数语义坑**：`Git.status/1`、`Git.diff/1` 的参数是 opts/cwd 类，但传非 git 目录（如测试根）时，git 沿父目录找到主工程 `.git`，**返回了主仓库状态**（污染上层！）。做隔离测试时必须先 `git init` 或用完全独立路径。
- 目录不存在 → git 抛 `{128, "fatal: ..."}` 元组错误（非 `{:error, reason}` 形态）。
- 真实导出为 `status/0|1`、`diff/0|1`、`add_all`、`commit`、`log`、`rollback`、`worktree_*` 等（无文档里暗示的纯 path 参数）。

### 2.8 Http
易错点（成功率 0/2）：
- 外网不通时 `get` 返回 `{:error, :request_failed}`，**无法区分 DNS/证书/超时/URL 格式错**——非法 URL（`"not a url"`）和真实网络失败返回同一原子，LLM 无法据此自愈。
- 内部经 `Req`，默认 30s 超时；大响应 512KB 截断。

### 2.9 Json
易错点（成功率 1/3）：
- `decode` 非法 JSON 返回 `{:error, %Jason.DecodeError{}}`（友好），但 LLM 需匹配 `%Jason.DecodeError` 而非简单 `{:error, reason}`。
- `encode` 接受 map/struct，但含 Tuple/函数等不可序列化值会抛异常（非 `{:error}`）。

### 2.10 Introspect
成功率 2/3。最稳的工具之一，但：`exports(不存在模块)` 返回 `[]`（不报错，LLM 可能误判"模块无导出" vs "模块不存在"）。**强烈建议 LLM 在调用任何工具前先用 `Introspect.exports` 核实真实函数签名与 arity**，可规避 Scaffold 类"API 名错"问题。

### 2.11 Scaffold
易错点（成功率 0/2）：
- **文档/依赖图声称 `Scaffold.new/2`，但实际导出是 `new_project/1`、`deps_get/0`、`compile/0`、`test/0|1`**——直接按文档调 `new/2` 抛 `undefined or private`。典型"文档与实现不一致"陷阱。

---

## 三、跨工具共性根因（LLM 视角）

1. **返回形态不统一**：有的 `{:ok,_}`/`{:error,_}`（Fs.read/Json），有的裸 map（Edit.show），有的 `%{exit:, output:}`（Run），有的 `%{status:}`（Edit.V2），有的直接崩溃（Search 正则、Structural 非 elixir）。模型很难一套模式通吃。
2. **文档与实际导出漂移**：Edit V1（锚点机制疑似坏）、Scaffold（API 名错）、Git（参数语义）、Edit.show 的 `lines` 字段语义——都靠"实测"而非"读文档"才准。
3. **友好报错 vs 崩溃不一致**：同一类错误输入，Fs 给 `{:error}`，Search/Structural 直接抛底层异常。模型遇到未捕获异常时整段工具调用失败。
4. **严格前置条件不显眼**：Edit.V2 的 stale-recheck、Structural 的已加载模块、Fs 的路径边界——都是"不遵守就静默/崩溃"的隐藏约束。

## 四、给 LLM 的调用建议（速查）

1. **改文件优先用 `Edit.V2`**（纯行号），每次 patch 前务必 `show` 取新 tag；不要用 V1 锚点。
2. 调任何工具前先 `Newbee.Tools.Introspect.exports(Mod)` 核实函数名/arity，别信文档。
3. `Run.sh` 结果用 `res.exit`/`res.output` 取，别解构成元组；`rm -rf` 非根目录**会真的执行**。
4. `Search.grep` 的正则务必写闭合、自测；非法正则会崩溃。
5. `Fs.read` 用 `{:ok,_}` 匹配，`Fs.read!` 会抛错；大文件用 `Newbee.read`（有截断）。
6. `Structural` 只用于已加载的 Elixir 模块，且插入代码后务必 `mix compile` 验证（它不校验语法）。
7. `Git` 操作务必在 `git init` 过的隔离目录，避免污染主仓库。
8. 网络不可用环境下，`Http` 一律 `{:error, :request_failed}`，不要依赖它取外网资源。

## 五、给工具实现的改进建议（按性价比）

1. **停用/修复 Edit V1**：当前 `patch/1` 100% 失败，应修复解析链或直接从 prompt 与文档移除，统一引导到 V2。
2. **Search.grep 捕获正则编译错误**，返回 `{:error, :bad_regex}` 而非崩溃。
3. **统一返回形态契约**：所有工具收敛到 `{:ok,_}`/`{:error, reason}`，或至少在文档头部明确每种形态。
4. **Fs.write 返回明确 `{:ok, path}` 或暂存 id 说明**；越界路径用友好 `{:error, :out_of_bounds}` 而非 ArgumentError。
5. **Structural.insert_function 增加 Code.string_to_quoted 预校验**，非法函数体返回 `{:error, :invalid_syntax}`。
6. **文档与导出对齐**：Scaffold、Git 参数、Edit.show 的 `lines` 字段语义，以运行时 `Introspect.exports` 为准更新。
7. **Git 工具默认 cwd 隔离**：传入非 git 目录时应 `{:error, :not_a_repo}` 而非上溯父目录找主仓库。

---
附：完整 74 组调用原始记录见同目录 `results.jsonl`；测试语料见 `s01_samples/`、`*_reader.ex` 等；锚点解析与 Stress 框架见会话内 `Stress` 模块（不落盘）。
