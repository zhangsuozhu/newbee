# 统一寻址 12 协议批判审计（2026-09-03，worktree audit-reader-20260903）

## 第一性原理：为什么只要一个 read

- 模型侧只有一个读入口，工具数不膨胀。认知负荷理论（Sweller 1988）与 Hick 定律：
  选择数越少，决策越快越少错。12 种地址共用一套 `{:ok,_}|{:error,_}` 与 trust 信封，
  prompt 里只教一句话。
- Unix“一切皆文件”（Ritchie/Thompson 1974 CACM）与 Plan 9 9P（Pike 等 1995）：
  裸路径/file 读文件、目录一层列表，就是本地版“一切皆文件”。
- URI 统一标识（RFC3986，T. Berners-Lee 2005，实测拉回 141811 字节）：
  `scheme://rest` 自描述、可拼、可记，`Newbee.read("history://q/关键词")` 与
  `agent://id/path` 都是 URI 子集。好处：可发现、可组合、错误可归因到 scheme。
- pull over push：压缩档案、事件、冲突都只在模型要时才拉，不预推。
  长上下文“Lost in the Middle”（Liu 等 arXiv:2307.03172，实测拉回 41931 字节）证明
  上下文越长中间越丢；按需拉取比全量回放更保真。Archive 的“一次蒸馏永不重蒸”
  正是对“摘要的摘要会电话游戏”的防御。
- 事件溯源（Fowler 2005 EventSourcing，实测拉回 57156 字节）：events 读的是
  append-only 日志的重放，不是可变状态的快照，可审计、可回放。
- 记忆 TTL 与遗忘曲线（Ebbinghaus 1885；Generative Agents Park 等 arXiv:2304.03442
  实测拉回 44065 字节）：memory 按 topic 存、按 last_ref 衰减、pin 不删，是机器版
  间隔重复。空键列主题是可发现性的最低要求，否则模型只能瞎猜。
- SSRF（OWASP Server Side Request Forgery，实测拉回 32128 字节）：URL 读必须默认
  无凭证、拦私网。云元数据 169.254.169.254 一旦可读就是凭证泄露。

## 逐协议 verdict（好用 / 有问题 / 多余否 / 优化）

1. 裸路径 + file:// ——好用。保留两者：裸路径最短，file:// 强制文件语义（含敏感红线、
   512KB 截断+信封）。问题：前缀剥离用 trim_leading 会吞重复前缀（HexDocs
   trim_leading/2 实测 298210 字节，`ababhello` 会被吞成 `hello`）。已改 replace_prefix。
2. tool:// ——好用。@moduledoc+真实签名是防幻觉的关键（只认 binary 会丢 Elixir 1.15+
   的 map 文档，曾致模型瞎猜 Fs.write）。保留；本次未动截断策略（首段500字），
   后续可加 error_contract 段。
3. rules:// ——有问题，已修。原实现忽略子串（`rules://foo` 与 `rules://` 同解，违反最小惊讶），
   且直查本地 GenServer，peer 求值节点必回“未启动”（history 已用 Host.call 回主节点，
   此处不一致）。改为 `read_rules(query)`，空列全部、非空按 id+pattern 过滤，经 Host.call。
4. memory:// ——有问题，已修。空键回 `:not_found` 不可发现。改为 `memory://` 列主题清单；
   有键包 trust 信封不变。TTL GC 与脱敏（sk-/Bearer/key=）保留，好用。
5. bindings:// ——有问题，已修。同 rules 的 peer 不一致，改经 Host.call；`{:badrpc,_}` 也归为
   “未启动”兜底，不崩。
6. history:// ——好用，标杆。索引/段/原文/检索/文件清单五件套 + Host.call 跨节点 + 崩溃安全
   （段 tmp+rename，账本尾坏忽略）。保留不动。
7. events:// ——有问题，已修。`?n=` 无钳制，`n=100000` 可打爆上下文（Lost in Middle）。
   改为默认 200、钳制 1..1000。项目 EventStore 优先、全局回退的策略保留，好用。
8. skill:// ——有问题，已修。`.md` 硬拼导致 `skill://github_flow.md` 变 `.md.md` 找不到；
   且读出不包信封（同为文件背书，file/memory 都有）。改为后缀幂等 + 包 skill 信封。
9. agent:// ——有问题，已修。`Json.get` 永回 `{:ok,nil}`（缺段与显式 null 不分），导致
   `:path_not_found` 死分支（实测 dummy 的 `/nope` 回 `ok nil`）。根修 Json.get/get!：
   缺键/越界回 `:error`，显式 null 才回 `{:ok,nil}`；仅调用方是 reader，安全。
10. conflict:// ——有问题，已修。`[ours,rest]=split` 在坏块（有<<<<<<<无=======）直接
    MatchError 崩整个 read。改 case+flat_map 跳过坏块；无冲突/无块的友好文案保留。
11. http(s):// ——有问题，已修。无 SSRF 拦、私网/元数据可读。加字面 IP 私网段（10/8、
    172.16/12、192.168/16、127/8、169.254/16、::1 等）+ localhost/.local/.internal/.lan
    拦截；DNS 重绑定声明需出口代理根治，此处为纵深一层。超时 30s 与 512KB 截断保留。
12. 无可删协议。file/裸路径、tool、rules、memory、bindings、history、events、skill、
    agent、conflict、http 各有唯一数据源与调用方，无重复；删任何一个都会逼模型走
    更贵或更不可审计的旁路。

## 改了什么（worktree diff）

- lib/newbee/reader.ex：replace_prefix 精确剥离9处；rules 加过滤+Host.call；
  memory 空键列主题；bindings 经 Host.call；events 钳制；skill 幂等+信封；
  conflict 容错；url SSRF 拦；新增 schemes/0 注册表；moduledoc 同步。
- lib/newbee/tools/json.ex：get/get! 缺段语义根修 + fetch_path 显式 null 区分。

## 依据与证据（互联网可验）

- RFC3986 全文 141811 字节已拉回；HexDocs String.trim_leading/2 页 298210 字节；
  OWASP SSRF 页 32128 字节；arXiv 2307.03172（Lost in Middle）41931 字节；
  arXiv 2304.03442（Generative Agents）44065 字节；Fowler EventSourcing 57156 字节。
  以上均经 Newbee.Tools.Http.get 200 取回，字节数即取证。
- trim 重复前缀实证：`String.trim_leading("ababhello","ab")=="hello"`，
  应一次性剥离，故用 replace_prefix。
- Json 缺段实证：旧实现 `probe-dummy/nope` 回 `{:ok,nil}`，修后回 `:error`，
  reader 才能走到 `:path_not_found`。

## 待验证（本轮未竟）

- worktree 冷构建慢（deps 全编），严编与契约测试仍在后台跑，需补 `mix compile
  --warnings-as-errors` 双环境零警告 + `mix test test/newbee/readertest*`
  + 新增审计测试全绿的日志。

## 补记（测试落定后）

- dev 严编：`mix compile --warnings-as-errors` 零警告（自家文件无 warning；deps 警告不计，符合 AGENTS 纪律）。
- test 严编：`MIX_ENV=test mix compile --warnings-as-errors` 通过（能进 ExUnit 即证）。
- 四套用例 24 全绿：reader_audit（9）+ reader（6）+ scheme（4）+ searchjson（5），
  日志 `/tmp/reader_test2.log` 尾行 `Result: 24 passed`。
- 契约变更：Json.get 缺段旧语义靠 BadMap 崩出偶发 `:error`（单缺回 ok nil、双缺回 error），
  已改为有无显式跟踪（缺一律 error，显式 null 才 ok nil），旧测试已同步更新并注明原因。
