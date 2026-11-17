# 隔离工作区：构建产物自动接入（deps / _build）

子会话与 Colony 任务都在 `.newbee/workspaces/<session_id>` 下拿到独立工作目录，避免并行修改互相踩踏。工作目录默认**只复制源码**：`deps`、`_build`、`node_modules`、`.git`、`.newbee` 等按快照排除规则留在源项目，不进入副本。本文件记录随后自动补上的那一步——把源项目的构建产物以符号链接接入隔离目录，让工作区里的 `mix` 不必手工 `ln -s`。

## 行为

`Newbee.Collaboration.Workspace.prepare/4` 在物化快照之后接入构建产物：

| 产物 | 默认 | 开启方式 | 说明 |
|---|---|---|---|
| `deps` | 接入 | 始终 | 依赖源码 |
| `_build` | 不接入 | `Workspace.prepare(root, sid, :auto, link_build: true)` | 编译缓存；多数场景不必共享 |

- 链接是**绝对符号链接**，指向解析后的真实目录。源项目自己用相对链接时（AGENTS.md 里记录的 `ln -sfn ../../../deps deps`），解析会一路跟到最终目录，不会把相对路径原样搬进工作区——否则新位置会解析失败。
- 只建链接，**不复制字节**。`read_link/1` 能读到源项目真实路径；链接本身是独立 inode（`File.lstat(link).type == :symlink`），但 `File.stat!(link <> "/child")` 与 `File.stat!(source <> "/child")` 的 inode 相同，即同一个文件。
- 每个接入项都记在返回值的 `build_artifacts` 里：

```elixir
{:ok, workspace} = Newbee.Collaboration.Workspace.prepare(root, "child-1", :auto)
workspace["build_artifacts"]
#=> [%{"name" => "deps", "status" => "linked", "target" => "/abs/path/deps", "message" => nil}]
```

- 源项目**没有** `deps`（或它是悬空链接）时，`status` 为 `"missing"`，`prepare` 仍然成功、**不建悬空链接**，并在 `workspace["warning"]` 给出可读提示：

```elixir
workspace["warning"]
#=> "源项目没有 deps，未建立依赖链接；请先在源项目 mix deps.get 后再派生工作区"
```

  提示不是错误：审阅、应用、清理照常工作。
- 链接建失败（权限、目标不是目录、链接层数超过 8 层）返回 `{:error, "workspace_link_failed", message}`，并把刚建出的半个工作区按链接语义回滚，不留半成品。
- `prepare` 遇到同名工作区已存在时返回 `{:error, "workspace_exists", _}`，**不会**回滚删除别人的工作区。

Colony 侧（`Newbee.Colony.Workspace`）额外处理一件事：Git 源会先把物化好的目录整体 rename 再就地 `git worktree add`，链接会指向已搬走的路径。因此 worktree 建好之后**重新**按源项目解析并重建 `deps`/`_build` 链接，工作树里不会残留悬空链接。

## 清理语义

`Workspace.cleanup/1` 与 `discard_orphan/1` 只删链接本身：

1. 对工作区里的每个产物名，`File.lstat` 确认是符号链接，记录其绝对目标，然后 `File.rm/1`——**只删链接，不进入目标**。
2. 之后才 `File.rm_rf(workspace_path)`（对普通目录递归删除；即使还有漏网链接，`File.rm_rf` 也按链接本身删除，不会递归进去）。
3. 删除完成后核对第 1 步记下的每个目标仍然存在；目标消失说明有东西递归进入了链接，返回 `{:error, "workspace_cleanup_failed", _}` 而不是静默放过。

因此清理后源项目的 `deps`/`_build` 逐项、逐字节不变，且仍是真实目录（不会退化成链接或空壳）。测试用 `tree_fingerprint/1`（路径 + 类型 + 大小 + 权限 + 内容 hash）在 prepare 前后比对。

## 边界（重要）

- **只读语义靠约定，不靠权限。** 链接只是路径共享：在工作区里跑 `mix deps.get`、`mix compile`（默认写 `_build`）会写进源项目目录，影响其他会话。需要严格隔离时用 `link_build: true` 之外的方式：给工作区单独的 `MIX_BUILD_PATH`，或干脆不接 `_build`（默认行为），让每个工作区自己编译。
- **不可移植。** 链接是绝对路径，工作区搬家、换机器、源项目挪目录后全部失效；链接不会被 Git 记录，也不该被提交。
- **Git 源会看到一条未跟踪项。** 源项目 `.gitignore` 里常见的 `/deps/`（带尾斜杠）只匹配目录，**不匹配符号链接**，所以 Git worktree 里 `git status` 会多出 `?? deps`（`git check-ignore deps` 返回空）。这不影响审阅与应用（`Workspace.review/1` 按文件比对，未跟踪的链接不会进入 `files`），但会让工作区的 `git status` 不再干净。想消除它需在源仓库写 `.git/info/exclude`——那是跨会话共享的持久副作用，本实现不做，留给调用方决定。
- **没有免费的一致性。** 源项目 `deps` 在会话期间被 `mix deps.update` 改动时，所有共享链接的工作区同时看到新依赖；这不是快照语义。

## 在隔离工作区里使用 MIX_DEPS_PATH / MIX_BUILD_PATH

不想共享（或源项目根本没有）构建产物时，可以不建任何链接，改用 Mix 的两个环境变量把路径指过去：

```sh
# 用源项目的依赖，但把编译缓存留在工作区自己这里
cd .newbee/workspaces/<session_id>
MIX_DEPS_PATH=../../../deps MIX_BUILD_PATH=./_build mix compile

# 完全自包含：两边都放工作区自己的目录
MIX_DEPS_PATH=./deps MIX_BUILD_PATH=./_build mix deps.get
MIX_DEPS_PATH=./deps MIX_BUILD_PATH=./_build mix test
```

`MIX_DEPS_PATH` / `MIX_BUILD_PATH` 是 Mix 官方支持的路径覆盖，源码在 `Mix.Project.deps_path/1`、`Mix.Project.build_path/1`：

```elixir
dir = System.get_env("MIX_DEPS_PATH") || config[:deps_path]   # 之后 Path.expand
build_path = System.get_env("MIX_BUILD_PATH") || ...          # 命中时直接 Path.expand，不再拼子目录
```

要点（其中前两条是实测结论）：

- 相对路径按**当前工作目录**解析（两个函数最后都 `Path.expand`），所以先 `cd` 进工作区，或直接给绝对路径。
- **`MIX_BUILD_PATH` 不追加 `MIX_ENV` 子目录。** 设为 `./_build` 时 dev 与 test 共用同一份 `_build/lib`，先编译 dev 再跑 `MIX_ENV=test mix compile` 只会打印 `Generated`、**不会重编译**，测试环境实际复用了 dev 的 beam。需要逐环境隔离时用 `MIX_BUILD_ROOT`（会拼 `MIX_ENV`），或给每个环境各自独立的 `MIX_BUILD_PATH`。
- 两个变量都要显式传给每条命令，或用 `direnv`/容器注入。本项目里 `Newbee.Collaboration.Verification` 在验收命令前注入的是 `MIX_DEPS_PATH`（`verification_env_prefix/0`），不注入 `MIX_BUILD_PATH`。
- 与链接方式互斥地使用更清晰：`deps_path` 默认就是 `deps`，链接在那儿时无需环境变量；`MIX_DEPS_PATH` 会覆盖它。

## 可复现验证

```sh
# 严格编译，零警告。dev 与 test 用不同构建目录，否则 test 会复用 dev 产物（见上一节）
MIX_DEPS_PATH=/path/to/source/deps MIX_BUILD_PATH=$PWD/_build \
  mix compile --warnings-as-errors
MIX_ENV=test MIX_DEPS_PATH=/path/to/source/deps MIX_BUILD_PATH=$PWD/_build-test \
  mix compile --warnings-as-errors

# 定向用例（MIX_DEPS_PATH 指向源项目依赖，避免在本工作树里造 deps）
MIX_DEPS_PATH=/path/to/source/deps MIX_BUILD_PATH=$PWD/_build-test \
  mix test test/newbee/collaboration/workspace_test.exs \
           test/newbee/colony/workspace_review_test.exs

# 补丁卫生
git diff --check
mix format --check-formatted <改动文件>
```

`test/newbee/collaboration/workspace_test.exs` 覆盖：

- `prepare` 后 `deps` 是符号链接、`read_link/1` 指向源项目真实目录、内容可读（不复制字节）；
- 源项目没有 `deps` 时 `prepare` 仍成功、无悬空链接、`build_artifacts` 与 `warning` 有可读提示；
- `link_build: true` 同时接入 `_build`，默认不接入；
- `cleanup` 后工作区消失，源 `deps`/`_build` 指纹不变且仍是真实目录；
- 源项目 `deps` 本身是相对链接时，工作区链接是绝对路径且指向解析后的真实目录；
- `deps` 是悬空链接时的提示与不建链；
- 重复 `prepare` 同名字不删除已存在工作区；非法选项被拒绝；
- 既有规则未被破坏：快照仍排除 `deps`/`_build`/`_build*`/`.appimage-cache`，源码目录符号链接仍以 `workspace_unsupported_file` 拒绝。

`test/newbee/colony/workspace_review_test.exs` 额外覆盖 Git worktree 路径：链接在目录 rename 之后被重建、指向源项目真实 `deps`、清理后源目录完整且 worktree 注册被移除；无 `deps` 时不建链并可正常审阅。

## 端到端验证（真实 mix 工程，非单元测试替身）

用一个依赖 `jason` 的最小工程把实现当用户用一遍：

1. 源工程 `mix deps.get` 后 `deps/jason` 就位；
2. `Newbee.Collaboration.Workspace.prepare(root, "e2e-child", :auto)` → `build_artifacts` 为
   `[%{"name" => "deps", "status" => "linked", "target" => "<root>/deps"}]`，`warning` 为 `nil`；
3. 在工作区里**不做任何 `ln -s`、不设 `MIX_DEPS_PATH`**，直接 `mix compile` → `Compiling 10 files (.ex)`（jason）+ `Generated probe app`；
4. `mix run -e 'IO.inspect(Probe.encode(%{a: 1}))'` → `"{\"a\":1}"`，即真的用上了经链接的依赖；
5. `cleanup` 后工作区目录消失，源工程 `deps` 仍是真实目录（`File.dir? == true`、`lstat.type != :symlink`）、`deps/jason/lib/encoder.ex` 仍在。

`mix compile` 会在工作区里生成自己的 `_build`（本实现不接 `_build`），因此这份共享是单向的：读源依赖，写本地缓存。

## 相关代码

- `lib/newbee/collaboration/workspace.ex` — `prepare/4`、`link_build_artifacts/3`、`build_artifact_target/1`、`detach_build_artifacts/1`
- `lib/newbee/colony/workspace.ex` — `attach_git/2` 之后重建链接、失败补偿
- `lib/newbee/collaboration/submission.ex` — 冻结候选仍按快照规则复制源码，不含链接
