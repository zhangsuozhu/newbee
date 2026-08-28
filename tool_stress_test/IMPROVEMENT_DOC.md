# Newbee.Tools 工具调用直觉适配改进文档

> 核心原则：让工具的返回值/行为**符合模型在训练语料里学到的调用直觉**，而不是让模型去适应工具的独特设计。
> 模型不是按逻辑推理调用工具，而是按预训练里见过的几千万个 Python/JS/Shell/Elixir 代码片段的统计规律去写代码。
> 数据来源：74 组工具调用实测 + 本会话 REPL 层 12 个错误模式实测。

---

## 第一部分：两个维度的错误全景

### 维度一：工具层错误（74 组调用，按根因归类）

| 根因 | 数量 | 典型场景 | 违背的语料直觉 |
|------|-----:|---------|--------------|
| 工具自创抽象（哈希锚点）难用 | 13 | Edit V1 所有 patch 调用 | sed -i 的行号直觉 |
| 严格前置条件（stale） | 5 | Edit 连续编辑同一文件 | sed 行号失效需重读 |
| 参数语义坑（模块需已加载） | 2 | Structural.insert_function | Python 传字符串路径 |
| 文档与实现漂移（API 名错） | 2 | Scaffold.new/2 | 文档驱动调用习惯 |
| 错误无法区分类型 | 2 | Http.get 非法 URL vs 网络失败 | requests.get 错误分类 |
| 越界用 ArgumentError 而非权限错误 | 1 | Fs.write(/etc/x) | PermissionError |
| 错误以异常形式抛出（崩溃） | 1 | Search.grep 非法正则 | grep 友好报错 |
| 其他（正常错误返回） | 18 | Fs.read 不存在文件等 | — |

### 维度二：REPL 层错误（本会话实测 12 个模式）

模型在 DEE（动态 Elixir 求值环境）里写代码时的肌肉记忆错误：

| 错误模式 | 频率 | 违背的语料直觉 | 典型例子 |
|---------|-----:|--------------|---------|
| binding()[:x] = val 非法赋值 | 高频 | Python globals() / JS window 可变绑定 | binding()[:results] = results |
| 对工具返回形态误判 | 高频 | Python open() / Rust Result | {:ok, shown} = Edit.show(f) |
| 字符串插值里嵌套复杂表达式 | 高频 | Python f-string / JS 模板字符串 | 插值里写 Enum.find(...)[hash] |
| 工具 API 名按文档调用 | 中频 | 文档驱动调用习惯 | Scaffold.new/2 实为 new_project/1 |
| File.size/1 不存在 | 中频 | Python os.path.getsize / JS fs.statSync().size | File.size(path) |
| Jason.decode 参数语法误用 | 中频 | Python dict 传参 | Jason.decode!(s, [{keys: :copy}]) |
| 字符串里嵌套引号转义失败 | 中频 | 多语言字符串引号混用 | 三引号里嵌套三引号 |
| heredoc 字符串边界错误 | 高频 | Python 三引号 / JS 反引号 / Shell <<EOF | 三引号里嵌套三引号 |
| 跨语言调用工具（对 python 文件用 Structural） | 低频 | 通用文件操作直觉 | Structural.list_functions(py, Newbee) |
| Git 工具参数语义误判（传路径当 cwd） | 低频 | Python subprocess.run(..., cwd=dir) | Git.status(base) 返回主工程状态 |
| Edit.V1 锚点格式误用 | 高频 | git diff 的 @@ 行号直觉 | PUT 30.hash|31.hash:（应为 30.#hash） |
| Edit 连续编辑忘 re-show（stale） | 高频 | sed -i 行号失效直觉 | 连续两次 patch 用旧 tag |

---

### 维度三：历史会话错误模式（17 个会话，252 个错误汇总）

从 ~/.newbee/sessions/ 的 17 个会话文件中提取的错误类型分布：

| 错误类型 | 总数 | 典型例子 | 违背的语料直觉 |
|---------|-----:|---------|--------------|
| SyntaxError | 71 | invalid syntax found on lib/newbee/archive.ex:956:1 | 模型写代码时的语法错误 |
| ArgumentError | 36 | unknown registry: Req.Finch | 模型调用不存在的注册表/服务 |
| MatchError | 36 | no match of right hand side value: {:error, :not_purged} | 模型按成功路径解构，实际返回错误 |
| CompileError | 31 | cannot compile file (errors have been logged) | 模型写的代码编译失败 |
| FunctionClauseError | 19 | no function clause matching in Enum.at/3 | 模型传错参数类型/数量 |
| UndefinedFunctionError | 18 | function String.index/2 is undefined or private | 模型调用不存在的函数 |
| Protocol.UndefinedError | 14 | protocol Jason.Encoder not implemented for Tuple | 模型试图 JSON 编码元组 |
| CaseClauseError | 10 | no case clause matching: 38 (lib/newbee/tools/edit.ex:51) | 模型对工具返回值 case 分支不完整 |
| MismatchedDelimiterError | 10 | mismatched delimiter found on cell_45:8:16 | 模型字符串/括号配平失败 |
| KeyError | 4 | key :old not found | 模型访问不存在的 map key |
| File.Error | 3 | could not list directory | 模型对非目录调用 File.ls! |

**关键发现**：
- **SyntaxError 是最高频错误（71 次，占 28%）**——模型在 REPL 里写代码时的语法错误（heredoc、字符串插值、括号配平等）
- **ArgumentError 次之（36 次）**——模型调用不存在的注册表/服务（如 Req.Finch）
- **MatchError 36 次**——模型按成功路径解构，实际返回错误（如 {:error, :not_purged}）
- **FunctionClauseError 19 次**——模型传错参数类型/数量（如 Enum.at/3、Kernel.=~/2）
- **UndefinedFunctionError 18 次**——模型调用不存在的函数（如 String.index/2、Edit.show/3）
- **Protocol.UndefinedError 14 次**——模型试图 JSON 编码元组/Map 等不可序列化值

---

## 第二部分：改进意见（按训练语料直觉对齐）

每条意见 = **违背的语料直觉 → 解决原理 → 为什么能改进**

### 意见 A：文件读取返回 {:ok, content} | {:error, reason}
**违背的直觉**：Python open() 抛异常、Go os.ReadFile 返回 (string, error)、Rust read_to_string 返回 Result<String, io::Error>、Elixir File.read 返回 {:ok, binary} | {:error, posix}。模型对读文件的直觉是"要么拿到内容，要么拿到错误原因"的二元结构。
**当前问题**：Fs.read/1 符合（{:ok,_}），但 Fs.read!/1 抛异常、Edit.show/1 返回裸 map——同一类读操作三种形态。
**解决原理**：所有读类函数统一为 {:ok, content} | {:error, reason}。Edit.show 改为 {:ok, %{tag, text, lines}}。
**为什么能改进**：模型看到 {:ok, ...} 就知道用 case 匹配，不会再 MatchError。

### 意见 B：命令执行返回 %{exit_code, stdout, stderr}
**违背的直觉**：Python subprocess.run(..., capture_output=True) 返回 CompletedProcess(returncode, stdout, stderr)；Shell 里 $? 是退出码。
**当前问题**：Run.sh 返回 %{exit, output}——output 把 stdout/stderr 混在一起，字段名 exit 不是语料里高频的 exit_code/returncode。
**解决原理**：返回 %{exit_code: integer, stdout: string, stderr: string}。
**为什么能改进**：模型看到 exit_code 就知道对齐 $?；看到 stdout/stderr 就知道分开处理。

### 意见 C：JSON 解析返回 {:ok, term} | {:error, %{message, line, column}}
**违背的直觉**：Python json.loads 抛 JSONDecodeError（含 pos/lineno/colno）；Rust serde_json::from_str 返回 Result<T, Error>（含 line/column）。
**当前问题**：Json.decode 返回 {:error, %Jason.DecodeError{position: 1, ...}}——字段名 position 而非语料里高频的 pos/line/col，且是 struct 而非 map。
**解决原理**：{:error, %{message: ..., line: n, column: m, offset: k}}。
**为什么能改进**：模型看到 line/column 就知道怎么提示用户定位。

### 意见 D：正则搜索非法正则返回 {:error, :invalid_regex} 而非崩溃
**违背的直觉**：grep 对非法正则是 grep: Invalid regular expression 友好报错退出码 2；Python re.compile 抛 re.error（可捕获）。
**当前问题**：Search.grep 对非法正则直接抛 Regex.CompileError 崩溃，LLM 整个工具调用炸掉。
**解决原理**：在 grep/3 内部对 Regex.compile! 加 try/rescue Regex.CompileError，把底层崩溃转为 {:error, %{reason: :invalid_regex, hint: ...}}。
**为什么能改进**：转为 {:error, ...} 后，模型能读到正则非法并据此自我修正，形成可恢复的错误循环而非崩溃。

### 意见 E：结构编辑非法代码返回 {:error, :invalid_syntax} 而非静默成功
**违背的直觉**：Python ast.parse 抛 SyntaxError；Django manage.py makemigrations 失败打印错误。模型对写入类操作的直觉是"要么成功，要么明确告诉我为什么不行"。
**当前问题**：Structural.insert_function 对非法 Elixir 代码也返回 :inserted（静默成功），文件被污染后下次编译才爆炸。
**解决原理**：insert_function 先 Code.string_to_quoted/1 预校验，非法代码返回 {:error, :invalid_syntax}。
**为什么能改进**：前置校验把失败暴露在工具调用点，模型能立刻感知并重试，避免延迟爆炸型错误。

### 意见 F：HTTP 错误区分 :invalid_url 与 :network_error
**违背的直觉**：Python requests.get 抛 requests.exceptions.RequestException（含 ConnectionError/Timeout 等子类）；JS fetch 网络错误抛 TypeError。
**当前问题**：Http.get 对非法 URL 和真实网络失败都返回 {:error, :request_failed}。
**解决原理**：{:error, :invalid_url} vs {:error, :network_error, detail}。
**为什么能改进**：模型看到 :invalid_url 就知道改 URL，看到 :network_error 就知道换策略，避免无限重试同一错误。

### 意见 G：工程脚手架 API 名与文档对齐
**违背的直觉**：mix new my_app 成功打印路径，失败打印错误。模型对创建工程的直觉是"按文档调用就能成功"。
**当前问题**：Scaffold.new/2 不存在（实际导出 new_project/1）——文档与实现漂移。
**解决原理**：以 Introspect.exports/1 运行时真实导出为准，统一文档。
**为什么能改进**：模型按文档调用就能成功，不再踩 API 名错坑。

### 意见 H：删除逐行哈希锚点，只保留文件快照标签和行号补丁
**违背的直觉**：sed -i '2c\new_line' file（按行号替换）、git apply（补丁带行号上下文）。模型对改文件的直觉是"指定行号，给新内容"。
**当前问题**：旧 Edit 要求模型手抄 `N.#hash|上下文.#hash`，格式容易误读；另一套 V2 又公开了重复的 `show + patch` 协议。实测 V1 并未损坏，失败根因是漏写 `#`，说明协议可用但不符合模型直觉。
**解决原理**：只公开 `Newbee.Tools.Edit.show/2 + patch/1`：补丁使用 `PUT N..M`/`CUT N..M` 普通行号；保留一次文件级快照 tag 做 stale 检查；删除逐行 hash 和 `Edit` 重复模块。
**为什么能改进**：模型只需抄一次文件 tag，并按 sed/diff 直觉写行号范围；文件变化仍会被 stale 检查拒绝，不牺牲并发安全。

### 意见 I：路径越界返回 {:error, :out_of_bounds} 而非 ArgumentError
**违背的直觉**：Python open("/etc/passwd", "w") 抛 PermissionError；Node fs.writeFileSync("/root/x", ...) 抛 EACCES。模型对路径越界的直觉是"权限错误，可捕获"。
**当前问题**：Fs.write("/etc/x", ...) 抛 ArgumentError——ArgumentError 在语料里对应"参数类型错误"，而非"权限/边界错误"。
**解决原理**：Fs.write/Fs.guard_path! 越界时返回 {:error, :out_of_bounds}（或抛 PermissionError 自定义异常）。
**为什么能改进**：模型看到 :out_of_bounds 就知道"我该写到工作目录里"，而不是反复尝试不同路径格式。

### 意见 J：所有工具的所有可预见错误统一返回 {:error, reason}，不抛异常
**违背的直觉**：Rust 生态里 Result<T, E> 的 Err(E) 永远是可模式匹配的值；Go 的 if err != nil。模型对错误的终极直觉是"错误是一个可以被 case/if 检查的值，而不是一个会把我程序炸掉的异常"。
**当前问题**：Search.grep 非法正则崩溃、Structural 对非 Elixir 文件崩溃、Json.encode 对不可序列化值崩溃。
**解决原理**：所有工具的所有可预见错误，统一返回 {:error, reason}（或带 hint 的 map），不抛异常。
**为什么能改进**：模型只需一套 case {:ok, x} -> ...; {:error, r} -> ... 模式即可处理所有工具的所有错误，无需 try/rescue。这是最根本的一条——把"错误即值"的 Rust/Go 直觉贯彻到底。

---

## 第三部分：REPL 层错误的改进建议（环境/提示词层）

这些是"模型在 DEE 里写代码时的自身错误模式"，需要通过**环境设计**或**提示词注入**来规避：

### 建议 K1：DEE 的 binding() 语义在系统提示里明确"只读"
**问题**：模型按 Python globals()['x']=1 / JS window.x=1 的可变绑定直觉，写 binding()[:results] = results 导致编译错误（本会话实测高频）。
**解决原理**：在系统提示里明确"DEE 里 binding() 返回的绑定是只读快照，变量跨轮持久靠普通变量名，不要对 binding() 赋值"。
**为什么能改进**：模型对持久化的直觉是"写进某个全局容器"，明确告知"普通变量即持久"可消除这个误用。

### 建议 K2：字符串插值里避免嵌套复杂表达式（提示词层）
**问题**：模型在字符串插值里写 Enum.find(...)[hash] 等多层嵌套时，括号/引号配平失败（本会话实测 2 次）。
**解决原理**：在系统提示里建议"字符串插值里只放简单变量，复杂表达式先在外部算好再插值"（对齐 Python f-string 的最佳实践）。
**为什么能改进**：f-string 的社区最佳实践就是"插值里只放变量"，模型见过大量这类代码，提示后能减少配平错误。

### 建议 K3：跨语言调用前明确"工具仅支持特定语言"
**问题**：模型对 Structural.list_functions(python_file, ...) 调用失败（Sourceror 只解析 Elixir）。
**解决原理**：在工具文档头部明确"本工具仅支持 Elixir 文件（.ex/.exs）"，并在系统提示里列出各工具的语言边界。
**为什么能改进**：模型对工具通用性的直觉是"读文件的工具应该什么文件都能读"，明确语言边界后能避免跨语言误用。

### 建议 K4：File 模块的常用函数映射表注入系统提示
**问题**：模型按 Python os.path.getsize / JS fs.statSync().size 的直觉调 File.size/1（不存在）。
**解决原理**：在系统提示里附一个"Elixir File 模块 vs Python/JS 常用函数对照表"（如 File.size/1 不存在，应 File.stat!/1 |> elem(1).size）。
**为什么能改进**：模型对文件大小的直觉是"有个 size 函数"，对照表能直接纠正这个误用。

### 建议 K5：工具返回值形态速查表注入系统提示
**问题**：模型按 Fs.read 的 {:ok,_} 惯例去解构所有工具，导致 MatchError（本会话实测高频）。
**解决原理**：在系统提示里附一个"各工具返回值形态速查表"（如 Edit.show → 裸 map、Run.sh → %{exit, output}、Edit → %{status:}），并强调"调用前先用 Introspect.exports 核实"。
**为什么能改进**：模型对"同类型操作应同形态返回"的直觉很强，速查表能直接消除"按惯例解构"的错误。

### 建议 K6：文档与实现的自动对账机制（环境层）
**问题**：Scaffold.new/2 文档有但实际是 new_project/1，模型按文档调用失败（本会话实测 2 次）。
**解决原理**：在环境启动时自动跑 Introspect.exports/1 对所有工具生成真实签名，与文档对比，不一致时在系统提示里标注"文档可能过时，以运行时导出为准"。
**为什么能改进**：模型对"文档可信"的直觉很强，自动对账能消除"文档陷阱"。

### 建议 K7：heredoc 使用规范注入系统提示
**问题**：模型按 Python 三引号 docstring 的直觉写 Elixir heredoc，在生成长文档时三引号里嵌套三引号或含插值序列导致编译错误（本会话实测高频）。
**解决原理**：在系统提示里明确"Elixir heredoc 里**不要嵌套三引号**，长文档建议分段写入文件（先写 part1 再 append part2）"。
**为什么能改进**：Python 三引号可以嵌套（只要不成对出现），但 Elixir heredoc 对内部三引号更敏感。明确规范后模型会主动分段写入。

### 建议 K8：字符串插值最佳实践强化（对齐 f-string 社区规范）
**问题**：模型在字符串插值里写复杂表达式（如 Enum.find(...)[hash]）导致括号/引号配平失败（本会话实测 2 次）。
**解决原理**：在系统提示里强化"**插值里只放简单变量，复杂表达式先在外部算好再插值**"，并给出反例（不要在插值里写多层嵌套调用）。
**为什么能改进**：f-string 的社区最佳实践就是"插值里只放变量"，模型见过大量这类代码，强化提示后能减少配平错误。

### 建议 K9：关键字参数 vs 元组列表的对照提示
**问题**：模型把 Elixir 关键字列表 [keys: :copy] 误写为 Python 风格的 dict 传参 [{keys: :copy}]（本会话实测 1 次）。
**解决原理**：在系统提示里附"Elixir 关键字参数写法对照表"（如 Jason.decode!(s, keys: :copy) 而非 [{keys: :copy}]）。
**为什么能改进**：模型对"函数选项"的直觉是 Python 的 **kwargs 或 JS 的 object 参数，对照表能直接纠正这个误用。

### 建议 K10：File 模块函数映射表（扩展版）
**问题**：模型按 Python os.path.getsize / JS fs.statSync().size 的直觉调 File.size/1（不存在，本会话实测 1 次）。
**解决原理**：在系统提示里附"Elixir File 模块 vs Python/JS/Go 常用函数对照表"（如 File.size/1 不存在，应 File.stat!/1 |> elem(1).size；File.exists?/1 对应 Python os.path.exists）。
**为什么能改进**：模型对文件操作的直觉来自主流语言，对照表能直接纠正"函数名猜错"的问题。

### 建议 K11：工具语言边界明确标注（跨语言调用防护）
**问题**：模型对 Structural.list_functions(python_file, ...) 调用失败（Sourceror 只解析 Elixir，本会话实测 1 次）。
**解决原理**：在工具文档头部用醒目标记注明"**本工具仅支持 Elixir 文件（.ex/.exs）**"，并在系统提示里列出各工具的语言边界表。
**为什么能改进**：模型对"工具通用性"的直觉是"读文件的工具应该什么文件都能读"，明确语言边界后能避免跨语言误用。

### 建议 K12：Git 工具参数语义明确（避免 cwd 误判）

### 建议 K13：SyntaxError 高频防护（语法检查前置）
**问题**：历史会话中 SyntaxError 高达 71 次（占 28%），模型在 REPL 里写代码时的语法错误（heredoc、字符串插值、括号配平）。
**解决原理**：在系统提示里强化"**写代码前先想语法边界**"（heredoc 不嵌套三引号、字符串插值只放简单变量、括号配平用编辑器检查），并在工具层提供"语法预检查"（如 Code.format_string!/1 在写入前先跑一遍）。
**为什么能改进**：模型对"语法正确性"的直觉来自训练语料里的正确代码，但实际写代码时容易在边界情况出错。前置检查能把语法错误暴露在写入前。

### 建议 K14：ArgumentError 防护（注册表/服务存在性校验）
**问题**：历史会话中 ArgumentError 36 次，典型是"unknown registry: Req.Finch"——模型调用不存在的注册表/服务。
**解决原理**：在系统提示里列出**可用的注册表/服务清单**（如 Req.Finch 是否存在），并在工具层对"调用注册表/服务"的操作先做存在性校验。
**为什么能改进**：模型对"服务可用性"的直觉是"写了就能用"，实际服务可能未启动。明确清单后模型会先检查再调用。

### 建议 K15：MatchError 防护（错误分支覆盖）
**问题**：历史会话中 MatchError 36 次，典型是"no match of right hand side value: {:error, :not_purged}"——模型按成功路径解构，实际返回错误。
**解决原理**：在系统提示里强化"**所有工具调用都要处理错误分支**"（case {:ok, x} -> ...; {:error, r} -> ...），并在工具文档里明确"可能返回的错误值清单"。
**为什么能改进**：模型对"调用成功"的直觉很强，但实际工具可能返回错误。明确错误分支后模型会主动写 case 处理。

### 建议 K16：FunctionClauseError 防护（参数类型/数量校验）
**问题**：历史会话中 FunctionClauseError 19 次，典型是"no function clause matching in Enum.at/3"——模型传错参数类型/数量。
**解决原理**：在系统提示里附"常用函数的参数签名速查表"（如 Enum.at/3 的参数是 (list, index, default)），并在工具层对参数类型做预校验。
**为什么能改进**：模型对"函数参数"的直觉来自训练语料里的调用例子，但实际参数顺序/类型可能记错。速查表能直接纠正。

### 建议 K17：UndefinedFunctionError 防护（函数存在性校验）
**问题**：历史会话中 UndefinedFunctionError 18 次，典型是"function String.index/2 is undefined or private"——模型调用不存在的函数。
**解决原理**：在系统提示里强化"**调用函数前先用 Introspect.exports/1 核实**"，并列出"常用模块的真实导出函数清单"（如 String 模块没有 index/2）。
**为什么能改进**：模型对"函数存在性"的直觉是"按直觉猜"，实际函数可能不存在。强制核实后能避免这个误用。

### 建议 K18：Protocol.UndefinedError 防护（JSON 编码值类型校验）
**问题**：历史会话中 Protocol.UndefinedError 14 次，典型是"protocol Jason.Encoder not implemented for Tuple"——模型试图 JSON 编码元组。
**解决原理**：在系统提示里明确"**Jason 只能编码 map/list/string/number/bool/nil，不能编码元组/函数/PID**"，并在工具层对 Json.encode 的输入做类型预校验。
**为什么能改进**：模型对"JSON 编码"的直觉是"什么都能编码"，实际元组等类型不可序列化。明确类型清单后模型会先转换再编码。

---

**问题**：模型按 Python subprocess.run(..., cwd=dir) 的直觉，以为 Git.status(path) 是切换到该目录执行，实际返回主工程状态（污染上层仓库，本会话实测 1 次）。
**解决原理**：在工具文档里明确"Git.status/1 的参数是 opts 而非路径，切换目录请用 File.cd!/1 或显式 cwd"。
**为什么能改进**：模型对"命令执行"的直觉是"可以传 cwd 参数"，明确参数语义后能避免污染上层仓库。

---

## 第四部分：整改优先级

### 最优先整改（直接导致 LLM 调用失败或崩溃）
- 意见 H：统一 Edit，删除逐行 hash 和重复 V2 模块
- 意见 D：Search.grep 捕获正则错误
- 意见 G：Scaffold API 名与文档对齐
- 意见 J：所有工具错误统一返回 {:error, reason} 不抛异常

### 高优先整改（影响正确性与安全性）
- 意见 A：读类函数统一 {:ok, content} | {:error, reason}
- 意见 B：Run.sh 返回 %{exit_code, stdout, stderr}
- 意见 E：Structural.insert_function 语法预校验
- 意见 I：Fs 越界返回 {:error, :out_of_bounds}
- 建议 K5：工具返回值形态速查表注入

### 中优先整改（提升体验与健壮性）
- 意见 C：Json.decode 错误带 line/column
- 意见 F：Http 错误区分类型
- 建议 K1：binding() 只读语义提示
- 建议 K2：字符串插值最佳实践提示
- 建议 K3：工具语言边界提示
- 建议 K4：File 模块对照表注入
- 建议 K6：文档自动对账机制
- 建议 K7：heredoc 使用规范提示
- 建议 K8：字符串插值最佳实践强化
- 建议 K9：关键字参数对照提示
- 建议 K10：File 模块函数映射表（扩展版）
- 建议 K11：工具语言边界标注
- 建议 K12：Git 工具参数语义明确

---

## 附：数据来源

- **工具层 74 组调用**：tool_stress_test/results.jsonl
- **测试语料**：tool_stress_test/s01_samples/（含 9MB sqlite3.c/typescript.js）
- **REPL 层错误**：本会话实测 12 个模式
- **历史会话错误**：~/.newbee/sessions/ 17 个会话文件，252 个错误汇总
- **完整报告**：tool_stress_test/TOOLS_STRESS_REPORT.md

## 实施审计补充：工具数量与重复面

- 不新增独立 SourceLiteral 工具；安全源码字面量能力并入现有 `Newbee.Tools.Edit.source_literal/1`。
- 已删除 `Newbee.Tools.Edit` 重复公开模块；`Newbee.Tools.Edit` 是唯一文本编辑入口，采用文件快照 tag + 普通行号范围。
- `Newbee.Tools.Http.get/2` 与 `Newbee.read("https://...")` 在简单 GET 上重叠：无 headers/status 需求优先 `Newbee.read/1`；POST、自定义 headers、status 和网络错误分类使用 Http。
- Fs/Edit/Structural 分别负责全量文件 IO、并发安全文本补丁、Elixir 语义编辑，职责不同，不合并。
- Run 与 Git/Scaffold 底层都可能执行 shell，但 Git/Scaffold 是高层安全封装；模型应优先高层工具，Run 作为通用兜底。

## 源码生成错误的最终方案

- 二阶插值与 heredoc/sigil 分隔符冲突不再只靠固定提示规避。
- 使用 `Newbee.Tools.Edit.source_literal/1` 动态选择目标内容中不存在的 raw sigil 分隔符；所有候选冲突时回退到安全转义字符串。
- `Newbee.Codec` 的 run_elixir 描述提前提示该用法；`Newbee.DEE.Result` 在失败后识别二阶插值和分隔符冲突并给专项修复建议。
