# newbee AppImage 打包与分发

> 把 newbee 连同完整运行环境（OTP + Elixir + 依赖 + OpenSSL）打包成单个自包含
> AppImage（约 86MB），拷到任意 x86_64 Linux 直接运行——目标机器无需安装
> Erlang/Elixir，也无需联网拉依赖。

## 1. 为什么需要 AppImage

newbee 是跑在 BEAM（Erlang VM）上的自治代理，正常运行依赖：

- Erlang/OTP 运行时（当前 29）
- Elixir 语言与工具链（当前 1.20）
- hex 依赖（bandit/finch/jason/req/sourceror/plug 等 16 个）
- OpenSSL（`crypto` 模块的 `libcrypto.so.1.1`）

这些在开发机上齐全，换一台机器就全没了。AppImage 把整套环境打进一个
可执行文件，解决"环境不在"的问题。

**核心设计**：镜像只读 + 工作区可写。

```
AppImage（只读挂载）
├── usr/lib/toolchain/otp      OTP 29（裁剪版：strip + 删编译中间产物 + 保留运行必需 apps）
├── usr/lib/toolchain/elixir   Elixir 1.20.3
├── usr/lib/toolchain/mix-archives  hex 归档（离线可用）
├── usr/lib/libraries          libcrypto.so.1.1 + libssl.so.1.1
├── usr/lib/newbee             newbee 源码 + deps（不含 .git/.newbee/_build）
└── AppRun                     入口脚本（模板：priv/appimage/AppRun）

用户区（可写）
└── ~/.local/share/newbee/     首次运行自动复制的工作副本（源码 + _build 缓存）
```

首次运行：自动把源码复制到 `~/.local/share/newbee/`，一次性编译
（deps + 源码），之后启动只需数秒。用户数据目录 `<cwd>/.newbee/` 落在
用户可写区，天然持久。

## 2. 快速开始

### 2.1 构建（在开发机上）

```bash
cd <newbee 项目根>
bin/appimage/build.sh
```

产物：`dist/newbee-x86_64.AppImage`（约 86MB）。

如果工具链不在默认位置：

```bash
bin/appimage/build.sh --toolchain /path/to/toolchains
```

如需指定输出路径：

```bash
bin/appimage/build.sh --output /tmp/newbee.AppImage
```

### 2.2 运行（在目标机器）

```bash
# 方式一：直接运行（要求内核支持 FUSE，多数发行版默认支持）
./newbee-x86_64.AppImage

# 方式二：无 FUSE 环境强制解包运行
APPIMAGE_EXTRACT_AND_RUN=1 ./newbee-x86_64.AppImage

# 带会话参数：恢复指定 session
./newbee-x86_64.AppImage -r <session-id>
```

首次运行会看到初始化日志（复制源码 + 一次性编译，慢机器 3-6 分钟），
之后每次启动 5 秒内。

## 3. 构建脚本

`bin/appimage/build.sh` 全自动完成 6 步：

| 步骤 | 内容 |
|---|---|
| 0. 探测 | 自动找 `$TOOLCHAIN_ROOT/{otp-29,otp}` 与 `{elixir-1.20,elixir}`；自动下载 appimagetool 到 `.appimage-cache/` |
| 1. 工具链 | 复制 OTP（只留 kernel/stdlib/compiler/syntax_tools/crypto/public_key/ssl/inets/asn1/runtime_tools/sasl/tools/parsetools/mnesia/debugger），strip 二进制，删 `libbeam.a`、`erts/emulator/obj` 等中间产物（906MB → 270MB） |
| 2. Elixir | 完整复制 + hex 归档（`~/.mix/archives`） |
| 3. OpenSSL | 打包 `libcrypto.so.1.1` + `libssl.so.1.1` |
| 4. 源码 | 复制 newbee（lib/test/priv/bin/deps/mix.exs/mix.lock 等），净化敏感/冗余（.git/.newbee/_build/erl_crash.dump/nohup.out） |
| 5. 模板 | 从 `priv/appimage/` 复制 AppRun / desktop / 图标 |
| 6. 打包 | `appimagetool` 压成 squashfs AppImage |

### 3.1 参数

| 参数 | 说明 |
|---|---|
| `--output PATH` | 输出路径（默认 `dist/newbee-x86_64.AppImage`） |
| `--toolchain DIR` | 工具链根目录（默认 `$HOME/toolchains`） |
| `--clean` | 清理 `.appimage-cache/` 与 `dist/` |
| `-h` / `--help` | 帮助 |

### 3.2 环境变量

| 变量 | 说明 |
|---|---|
| `TOOLCHAIN_ROOT` | 同 `--toolchain`（脚本内可用） |

## 4. 模板文件（priv/appimage/）

| 文件 | 说明 |
|---|---|
| `AppRun` | 入口脚本：设置 `ERL_ROOTDIR`/`PATH`/`LD_LIBRARY_PATH`/`MIX_ARCHIVES`；首启复制 + 编译；设 `NEWBEE_CWD`；exec `mix newbee` |
| `newbee.desktop` | 桌面入口元数据（名称/图标/类别） |
| `newbee.png` | 应用图标（256x256，可替换） |
| `README.md` | 本目录说明 |

**修改模板后重新构建即可生效**：

```bash
vim priv/appimage/AppRun   # 改启动逻辑
bin/appimage/build.sh      # 重新打包
```

## 5. 运行时细节

### 5.1 关键环境变量

| 变量 | 默认 | 说明 |
|---|---|---|
| `NEWBEE_HOME` | `$HOME/.local/share/newbee` | 工作区位置（镜像副本 + _build 缓存） |
| `NEWBEE_CWD` | 当前目录 | newbee 数据目录 `<cwd>/.newbee/` 落点 |
| `APPIMAGE_EXTRACT_AND_RUN` | 未设 | 设 1 强制解包运行（无 FUSE 时） |

### 5.2 数据持久化

| 数据 | 位置 | 说明 |
|---|---|---|
| 会话/事件/记忆 | `<NEWBEE_CWD>/.newbee/` 与 `~/.newbee/` | 用户可写区，跨运行存活 |
| 工作副本 + 编译缓存 | `$NEWBEE_HOME/_build/` | 首启编译后永久复用，二启秒开 |
| API key 配置 | `~/.newbee/model.json` | 新机器首次运行提示配置 |

### 5.3 编译缓存行为

Elixir Mix 的 `_build` 增量判定基于源码路径与 mtime，**跨目录移动/复制会触发全量重编**（这是语言固有行为）。因此：

- 首启在**目标机器本地**编译一次（一次性成本）
- 之后 `_build` 缓存保留在用户区，**同一台机器二次启动秒开**
- 不要试图把 `_build` 预打进 AppImage（换机器必重编，白占体积）

## 6. 目标机器要求

| 要求 | 说明 |
|---|---|
| 架构 | x86_64 |
| 内核 | Linux（squashfs + FUSE；无 FUSE 用解包模式） |
| glibc | >= 2.31（麒麟 V10 / Ubuntu 20.04+ / Debian 11+ 等） |
| 工具链 | 无（全部自带） |
| 网络 | 首次运行不需要（依赖已随包）；使用 LLM 需能访问模型 endpoint |

> **兼容性说明**：动态库 `libcrypto.so.1.1` / `libssl.so.1.1` 已随包，
> 通过 `LD_LIBRARY_PATH` 注入；系统仅需基础 glibc。OTP 29 本身的
> beam.smp 依赖 `libtinfo.so.6`、`libz.so.1` 等，这些在绝大多数发行版
> 默认就有（若缺，用 `--appimage-extract-and-run` 模式 + 目标机器补装）。

## 7. 故障排查

| 现象 | 原因 | 解决 |
|---|---|---|
| `AppImage 无法挂载` | FUSE 缺失/权限 | `APPIMAGE_EXTRACT_AND_RUN=1 ./xxx.AppImage` |
| 首启一直在编译 | 慢机器；移动过工作区 | 正常，等 3-6 分钟；不动 `_build` 下次就快 |
| `缺少 API key` | 新机器无配置 | 编辑 `~/.newbee/model.json` 填模型 endpoint/key |
| `libcrypto.so.1.1 not found` | 打包时源机没找到该库 | 在开发机装 `libssl1.1`（如 `apt install libssl1.1`）后重打 |
| 启动即崩 / segmentation | 目标机器 glibc 太老 | 升级系统，或换 glibc 兼容的构建机 |
| `Permission denied` | AppImage 无执行权限 | `chmod +x` |

## 8. 常见问题（FAQ）

**Q: 为什么不把历史会话/记忆打进镜像？**
A: 镜像只读，记忆需可写才能积累。新机器从零开始是特性——把记忆数据
`~/.newbee/`（或项目 `.newbee/`）手动拷贝过去即可迁移。

**Q: 为什么 OTP 打的是裁剪版？**
A: 全量 OTP 906MB，裁剪后 270MB（未压缩），AppImage 压缩后 86MB。
裁掉的都是运行不需要的：编译中间产物（obj/test/internal_doc）、静态库
（libbeam.a）、wx/megaco/snmp/ssh 等未用 apps。若未来需要这些 apps，
在 build.sh 的 `for app in ...` 列表加上即可。

**Q: 为什么首启编译要几分钟？**
A: 16 个 hex 依赖 + 103 个源文件需要本地编译一次（写 `_build` 缓存）。
这是 Elixir 的标准首次构建成本；之后启动 5 秒内。

**Q: 支持哪些平台？**
A: 当前只构建 x86_64 Linux。ARM64（树莓派/Apple Silicon 虚拟机）需在
对应机器上重新构建（改 ARCH 探测 + 用该架构的 appimagetool）。

**Q: 能让首启更快吗？**
A: 可以。缩短路径：① 换更快的构建机；② 减少 deps（把 bandit/web 拆
出去做成可选）；③ 用 `ERL_COMPILER_OPTIONS` 关 debug_info 减编译量
（不推荐，会影响调试）。根本解法是把初始化做成安装脚本预跑，或直接用
debian/arch 包分发（各角色不同，见 §9）。

## 9. 其他分发形态（路线图）

AppImage 是最快落地形态。长期可演进：

| 形态 | 优点 | 代价 |
|---|---|---|
| AppImage（当前） | 单文件、免安装、隔离 | 首启编译、glibc 绑定 |
| mix release（escript/embedded） | 官方方案、启动最快 | 不含 Elixir 编译能力，无法 JIT 进化 |
| 系统包（deb/rpm） | 更新走包管理 | 需要维护仓库 |
| Docker 镜像 | 隔离完善 | 需要 Docker 运行时 |

newbee 的自我进化依赖源码级修改 + 重新编译（认知 JIT/Plugin），因此
AppImage 保留完整工具链是最契合的形态。

---

*文档对应实现：`bin/appimage/build.sh` + `priv/appimage/` 模板*
*最后更新：2026-08-25*
