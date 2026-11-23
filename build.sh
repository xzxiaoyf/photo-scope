#!/bin/bash
# 构建并组装 PhotoScope.app
#
#   ./build.sh                    # release，默认 universal (arm64 + x86_64)
#   ./build.sh debug              # debug
#   ./build.sh release native     # 只构建本机架构（更快，适合开发调试）
#   ./build.sh release native run # 构建后直接启动
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="PhotoScope"
CONFIG="${1:-release}"
TARGET="${2:-universal}"
ACTION="${3:-}"

banner() { echo "==> $*"; }

BIN=""
if [ "$TARGET" = "universal" ]; then
    banner "swift build -c $CONFIG --arch arm64 --arch x86_64"
    if swift build -c "$CONFIG" --arch arm64 --arch x86_64; then
        CAP="$(echo "${CONFIG:0:1}" | tr '[:lower:]' '[:upper:]')${CONFIG:1}"
        BIN="$(pwd)/.build/apple/Products/$CAP/$APP_NAME"
    else
        echo "!! universal 构建失败，回落本机架构" >&2
        BIN=""
    fi
fi

if [ -z "$BIN" ] || [ ! -f "$BIN" ]; then
    banner "swift build -c ${CONFIG} (native)"
    swift build -c "$CONFIG"
    BIN="$(swift build -c "$CONFIG" --show-bin-path)/$APP_NAME"
fi

if [ ! -f "$BIN" ]; then
    echo "构建产物未找到: $BIN" >&2
    exit 1
fi

APP="$APP_NAME.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$APP_NAME"
cp Support/Info.plist "$APP/Contents/Info.plist"
if [ -f Support/AppIcon.icns ]; then
    cp Support/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
fi
printf 'APPL????' > "$APP/Contents/PkgInfo"

# ad-hoc 签名，便于本机直接运行
codesign --force --sign - --timestamp=none "$APP" >/dev/null 2>&1 || true

ARCHS="$(lipo -info "$APP/Contents/MacOS/$APP_NAME" 2>/dev/null | sed 's/.*: //' || true)"
echo "==> 完成: $(pwd)/$APP"
echo "    架构: ${ARCHS:-unknown}"
echo "    运行: open \"$APP\""
echo "    自检: \"$APP/Contents/MacOS/$APP_NAME\" --selftest --dir /path/to/photos"
echo "    地图: 高德地图 JS API 2.0 —— 到 lbs.amap.com 申请「Web端 (JS API)」Key 与 jscode，在「地图位置」窗口填入"
echo "    导出: 另存为 JPG 保留原始 EXIF / GPS，质量可在保存面板调整或「文件 → JPG 导出质量…」预设"
echo "    打包: ./make_dmg.sh 生成可分发的 DMG 安装包"
echo "    列表: 在缩略图上右键可旋转 / 移到废纸篓 / 按文件名·拍摄时间·型号·镜头排序"
echo "    视图: 标题栏右上角三段图标 = 全部照片列表 / 单张 / 双张对比（⌥⌘1/2/3）"
echo "    访达: 右键照片 →「打开方式」→ PhotoScope 会自动打开所在目录并定位该文件"
echo "    图标: swift Support/generate_icon.swift Support/AppIcon.png 可重新生成"

if [ "$ACTION" = "run" ]; then
    open "$APP"
fi
