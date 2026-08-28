# AppImage 模板目录

本目录是 AppImage 构建的**模板素材**，由 `bin/appimage/build.sh` 在打包时读取。

| 文件 | 作用 | 可改？ |
|---|---|---|
| `AppRun` | AppImage 入口脚本（设环境 + 首启初始化 + exec newbee） | ✅ 改启动逻辑 |
| `newbee.desktop` | 桌面入口元数据 | ✅ |
| `newbee.png` | 应用图标（256x256 PNG） | ✅ 换自己的 logo |
| `README.md` | 本说明 | — |

## 构建

```bash
cd <项目根>
bin/appimage/build.sh
```

修改模板后重新构建即生效。

## 正式文档

完整的构建原理、目标机器要求、故障排查、FAQ 见：

- [`docs/appimage-packaging.md`](../../docs/appimage-packaging.md)（正式文档）
