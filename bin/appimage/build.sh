<<<data origin="file:/home/alanx/data/git/newbee/bin/appimage/build.sh" hash="609ca3ba16360e98" trust="untrusted" bytes="7833">>
#!/usr/bin/env bash
# newbee AppImage 构建工具
# 用法:
#   bin/appimage/build.sh                     # 构建到 dist/newbee-x86_64.AppImage
#   bin/appimage/build.sh --clean             # 清理构建中间产物
#   bin/appimage/build.sh --output PATH       # 指定输出路径
#   bin/appimage/build.sh --toolchain ~/toolchains  # 指定工具链根目录
#
# 需要:
#   - OTP >= 29（源码构建，支持 ERL_ROOTDIR）
#   - Elixir >= 1.18
#   - appimagetool（自动下载到 .appimage-cache/）
#   - mksquashfs（squashfs-tools）

set -euo pipefail

# ── 常量 ──
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT_DIR="$PROJECT_ROOT/bin/appimage"
TEMPLATE_DIR="$PROJECT_ROOT/priv/appimage"
CACHE_DIR="$PROJECT_ROOT/.appimage-cache"
DIST_DIR="$PROJECT_ROOT/dist"
BUILD_DIR="$CACHE_DIR/build"

# ── 平台探测（只支持 x86_64 Linux）──
ARCH="$(uname -m 2>/dev/null || echo unknown)"
if [ "$ARCH" != "x86_64" ]; then
  echo "错误: 当前仅支持 x86_64，检测到 $ARCH" >&2
  exit 1
fi

# ── 参数解析 ──
OUTPUT=""
TOOLCHAIN_ROOT="${TOOLCHAIN_ROOT:-$HOME/toolchains}"
CLEAN=0
while [ $# -gt 0 ]; do
  case "$1" in
    --clean) CLEAN=1 ;;
    --output) OUTPUT="${2:-}"; shift ;;
    --toolchain) TOOLCHAIN_ROOT="${2:-}"; shift ;;
    -h|--help)
      sed -n '2,16p' "${BASH_SOURCE[0]}" | sed 's/^# {0,1}//'
      exit 0
      ;;
    *) echo "未知参数: $1" >&2; sed -n '2,16p' "${BASH_SOURCE[0]}" | sed 's/^# {0,1}//'; exit 1 ;;
  esac
  shift
done

if [ -z "$OUTPUT" ]; then
  OUTPUT="$DIST_DIR/newbee-x86_64.AppImage"
fi

# ── 工具链探测 ──
OTP_DIR=""
ELIXIR_DIR=""
if [ -d "$TOOLCHAIN_ROOT/otp-29" ]; then OTP_DIR="$TOOLCHAIN_ROOT/otp-29"; fi
if [ -d "$TOOLCHAIN_ROOT/otp" ]; then OTP_DIR="$TOOLCHAIN_ROOT/otp"; fi
if [ -d "$TOOLCHAIN_ROOT/elixir-1.20" ]; then ELIXIR_DIR="$TOOLCHAIN_ROOT/elixir-1.20"; fi
if [ -d "$TOOLCHAIN_ROOT/elixir" ]; then ELIXIR_DIR="$TOOLCHAIN_ROOT/elixir"; fi

if [ -z "$OTP_DIR" ] || [ -z "$ELIXIR_DIR" ]; then
  echo "错误: 未找到 OTP/Elixir 工具链，可指定 --toolchain <dir>" >&2
  echo "  期望: $toolchain/otp-29 或 $toolchain/otp  (含 bin/erl, lib/)" >&2
  echo "        $toolchain/elixir-1.20 或 $toolchain/elixir  (含 bin/elixir, lib/)" >&2
  exit 1
fi

# 验证 erl 可移植（ERL_ROOTDIR 支持）
if ! grep -q 'ERL_ROOTDIR' "$OTP_DIR/bin/erl" 2>/dev/null; then
  echo "警告: OTP bin/erl 脚本未检测到 ERL_ROOTDIR 支持，打包后可能无法运行" >&2
fi

# ── 版本信息 ──
NEWBEE_VERSION="$(grep -m1 'version:' "$PROJECT_ROOT/mix.exs" | sed -E 's/.*version: "([^"]+)".*/\1/')"
OTP_VERSION="$($OTP_DIR/bin/erl -noshell -eval 'io:format("~s", [erlang:system_info(otp_release)]), halt().' 2>/dev/null || echo unknown)"
ELIXIR_VERSION="$($ELIXIR_DIR/bin/elixir --short-version 2>/dev/null || echo unknown)"

echo "==> newbee v$NEWBEE_VERSION"
echo "==> OTP $OTP_VERSION @ $OTP_DIR"
echo "==> Elixir $ELIXIR_VERSION @ $ELIXIR_DIR"
echo "==> 输出: $OUTPUT"

# ── install appimagetool ──
mkdir -p "$CACHE_DIR/tools"
APPIMAGETOOL="$CACHE_DIR/tools/appimagetool-x86_64.AppImage"
if [ ! -f "$APPIMAGETOOL" ]; then
  echo "==> 下载 appimagetool..."
  curl -L --fail -m 300 -o "$APPIMAGETOOL" \
    https://github.com/AppImage/appimagetool/releases/download/continuous/appimagetool-x86_64.AppImage
  chmod +x "$APPIMAGETOOL"
fi

# ── 清理 ──
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR/AppDir/usr/bin" \
         "$BUILD_DIR/AppDir/usr/lib/newbee" \
         "$BUILD_DIR/AppDir/usr/lib/toolchain" \
         "$BUILD_DIR/AppDir/usr/lib/libraries" \
         "$BUILD_DIR/AppDir/usr/share/applications" \
         "$BUILD_DIR/AppDir/usr/share/icons/hicolor/256x256/apps"

echo "==> [1/6] 复制工具链 (OTP 裁剪版)..."
mkdir -p "$BUILD_DIR/AppDir/usr/lib/toolchain/otp"
cp -a "$OTP_DIR/bin" "$BUILD_DIR/AppDir/usr/lib/toolchain/otp/"
cp -a "$OTP_DIR/erts" "$BUILD_DIR/AppDir/usr/lib/toolchain/otp/"
mkdir -p "$BUILD_DIR/AppDir/usr/lib/toolchain/otp/lib"
for app in kernel stdlib compiler syntax_tools crypto public_key ssl inets asn1 runtime_tools sasl tools parsetools mnesia debugger; do
  [ -d "$OTP_DIR/lib/$app" ] && cp -a "$OTP_DIR/lib/$app" "$BUILD_DIR/AppDir/usr/lib/toolchain/otp/lib/"
done
# strip 二进制、删静态库
for f in "$BUILD_DIR/AppDir/usr/lib/toolchain/otp/bin/x86_64-pc-linux-gnu/"*; do
  case "$f" in
    *.a) rm -f "$f" ;;
    *) strip --strip-unneeded "$f" 2>/dev/null || true ;;
  esac
done
# 删 emulator 中间产物
rm -rf "$BUILD_DIR/AppDir/usr/lib/toolchain/otp/erts/emulator/obj" \
       "$BUILD_DIR/AppDir/usr/lib/toolchain/otp/erts/emulator/test" \
       "$BUILD_DIR/AppDir/usr/lib/toolchain/otp/erts/emulator/internal_doc" \
       "$BUILD_DIR/AppDir/usr/lib/toolchain/otp/erts/emulator/asan" \
       "$BUILD_DIR/AppDir/usr/lib/toolchain/otp/erts/emulator/valgrind" \
       "$BUILD_DIR/AppDir/usr/lib/toolchain/otp/erts/emulator/utils"
echo "     OTP 体积: $(du -sh "$BUILD_DIR/AppDir/usr/lib/toolchain/otp" | cut -f1)"

echo "==> [2/6] 复制 Elixir + hex..."
cp -a "$ELIXIR_DIR" "$BUILD_DIR/AppDir/usr/lib/toolchain/elixir"
rm -rf "$BUILD_DIR/AppDir/usr/lib/toolchain/elixir/man"
mkdir -p "$BUILD_DIR/AppDir/usr/lib/toolchain/mix-archives"
if [ -d "$HOME/.mix/archives" ]; then
  cp -a "$HOME/.mix/archives/." "$BUILD_DIR/AppDir/usr/lib/toolchain/mix-archives/" 2>/dev/null || true
fi

echo "==> [3/6] 打包 OpenSSL 1.1..."
mkdir -p "$BUILD_DIR/AppDir/usr/lib/libraries"
if [ -f /usr/lib/x86_64-linux-gnu/libcrypto.so.1.1 ]; then
  cp /usr/lib/x86_64-linux-gnu/libcrypto.so.1.1 "$BUILD_DIR/AppDir/usr/lib/libraries/"
elif [ -f /lib/x86_64-linux-gnu/libcrypto.so.1.1 ]; then
  cp /lib/x86_64-linux-gnu/libcrypto.so.1.1 "$BUILD_DIR/AppDir/usr/lib/libraries/"
fi
[ -f /usr/lib/x86_64-linux-gnu/libssl.so.1.1 ] && cp /usr/lib/x86_64-linux-gnu/libssl.so.1.1 "$BUILD_DIR/AppDir/usr/lib/libraries/"
if [ ! -f "$BUILD_DIR/AppDir/usr/lib/libraries/libcrypto.so.1.1" ]; then
  echo "警告: 未找到 libcrypto.so.1.1，crypto 模块在目标机器可能不可用" >&2
fi

echo "==> [4/6] 复制 newbee 源码（不含 .git/.newbee/_build）..."
for item in lib test priv bin mix.exs mix.lock README.md AGENTS.md DESIGN.md deps bench; do
  [ -e "$PROJECT_ROOT/$item" ] && cp -a "$PROJECT_ROOT/$item" "$BUILD_DIR/AppDir/usr/lib/newbee/"
done
# 清理源码内嵌的构建产物/敏感数据
rm -rf "$BUILD_DIR/AppDir/usr/lib/newbee/.git" \
       "$BUILD_DIR/AppDir/usr/lib/newbee/.newbee" \
       "$BUILD_DIR/AppDir/usr/lib/newbee/_build" \
       "$BUILD_DIR/AppDir/usr/lib/newbee/erl_crash.dump" \
       "$BUILD_DIR/AppDir/usr/lib/newbee/nohup.out"

echo "==> [4.5/6] 修补 deps 警告（Elixir 1.20+ pin 警告）..."
if [ -f "$BUILD_DIR/AppDir/usr/lib/newbee/bin/patch-deps.sh" ]; then
  bash "$BUILD_DIR/AppDir/usr/lib/newbee/bin/patch-deps.sh" 2>&1 | sed 's/^/     /' || true
fi

echo "==> [5/6] 写 AppRun / desktop / icon..."
cp "$TEMPLATE_DIR/AppRun" "$BUILD_DIR/AppDir/AppRun"
chmod +x "$BUILD_DIR/AppDir/AppRun"
cp "$TEMPLATE_DIR/newbee.desktop" "$BUILD_DIR/AppDir/newbee.desktop"
cp "$TEMPLATE_DIR/newbee.desktop" "$BUILD_DIR/AppDir/usr/share/applications/newbee.desktop"
if [ -f "$TEMPLATE_DIR/newbee.png" ]; then
  cp "$TEMPLATE_DIR/newbee.png" "$BUILD_DIR/AppDir/usr/share/icons/hicolor/256x256/apps/newbee.png"
  cp "$TEMPLATE_DIR/newbee.png" "$BUILD_DIR/AppDir/newbee.png"
else
  SYSICON="$(find /usr/share/icons -path '*256x256*' -name '*.png' 2>/dev/null | head -1)"
  if [ -n "$SYSICON" ]; then
    cp "$SYSICON" "$BUILD_DIR/AppDir/usr/share/icons/hicolor/256x256/apps/newbee.png"
    cp "$SYSICON" "$BUILD_DIR/AppDir/newbee.png"
  fi
fi

echo "==> [6/6] 构建 AppImage..."
mkdir -p "$(dirname "$OUTPUT")"
APPIMAGE_EXTRACT_AND_RUN=1 "$APPIMAGETOOL" "$BUILD_DIR/AppDir" "$OUTPUT" 2>&1 | tail -5

echo ""
echo "✅ 完成: $OUTPUT ($(du -h "$OUTPUT" | cut -f1))"
echo "   版本: newbee v$NEWBEE_VERSION | OTP $OTP_VERSION | Elixir $ELIXIR_VERSION"
echo "   用法: $OUTPUT  （首次运行自动初始化，之后秒启）"

<<<end 609ca3ba16360e98>>>
