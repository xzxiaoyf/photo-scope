#!/bin/bash
# 生成可分发的 PhotoScope DMG 安装包
#
#   ./make_dmg.sh                # 先构建 release universal .app，再打包
#   ./make_dmg.sh --skip-build   # 复用已有的 .app，只重新打包 DMG
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="PhotoScope"
VERSION="$(plutil -extract CFBundleShortVersionString raw Support/Info.plist)"
VOLUME_NAME="${APP_NAME} ${VERSION}"
DMG="${PS_DMG_OUTPUT:-$(pwd)/${APP_NAME}-${VERSION}.dmg}"
STAGE="$(mktemp -d /tmp/photoscope-dmg.XXXXXX)"
MOUNT=""

cleanup() {
    if [ -n "$MOUNT" ] && [ -d "$MOUNT" ]; then
        hdiutil detach "$MOUNT" >/dev/null 2>&1 || true
        rmdir "$MOUNT" 2>/dev/null || true
    fi
    rm -rf "$STAGE"
}
trap cleanup EXIT

if [ "${1:-}" != "--skip-build" ]; then
    echo "==> 构建 ${APP_NAME}.app (${VERSION})"
    ./build.sh release universal
fi
if [ ! -d "${APP_NAME}.app" ]; then
    echo "缺少 ${APP_NAME}.app，请先运行 ./build.sh" >&2
    exit 1
fi

echo "==> 准备 DMG 内容"
ditto "${APP_NAME}.app" "$STAGE/${APP_NAME}.app"
ln -s /Applications "$STAGE/Applications"
cat > "$STAGE/README.txt" <<'README'
PhotoScope — macOS 照片查看器
========================================

安装
----
把 PhotoScope.app 拖到同目录下的 Applications（应用程序）快捷方式即可。
universal 版本，同时支持 Intel (x86_64) 与 Apple Silicon (arm64)，
需要 macOS 13.0 或更高版本。

首次打开提示「无法打开」或「已损坏」
--------------------------------------
本程序为 ad-hoc 签名、未做 Apple 公证。请在 Finder 中右键点击
PhotoScope.app →「打开」→「打开」；或在终端执行：

    xattr -dr com.apple.quarantine /Applications/PhotoScope.app

之后即可正常双击启动。

功能速览
--------
· 左侧目录树选目录，底部缩略图条左右切换（← → / 工具栏 ‹ ›）
· 标题栏右上角三段图标切换三种视图（⌥⌘1 / ⌥⌘2 / ⌥⌘3）：
  · 全部照片列表：网格显示当前目录所有照片 + 拍摄时间/机型/镜头/曝光摘要，
    双击网格项回到单张大图
  · 单张查看：大图 / 视频 + 底部缩略图条
  · 双张并排对比：A/B 两侧分别选图，点击面板切换活动侧，缩放两侧联动
· 访达右键照片 →「打开方式」→ PhotoScope：自动打开所在目录并定位到该文件
· 工具栏：放大、缩小、适合窗口、实际大小、信息(EXIF)、地图位置、另存为 JPG
· 支持 JPG / HEIC / HEIF / AVIF / PNG / TIFF / WebP，以及各厂相机 RAW
  （ARW / NEF / CR2 / CR3 / DNG / RAF / RW2 / ORF …）
· 「信息」面板显示完整 EXIF / TIFF / GPS / 厂商扩展，可一键复制
· 有 GPS 时「地图位置」可用：高德地图 JS API 2.0，WGS-84 自动转 GCJ-02
· 「另存为 JPG」按原始尺寸导出，保留原始 EXIF / GPS；质量可在保存面板
  调整（10%–100%），也可用「文件 → JPG 导出质量…」设默认值
· 缩略图右键：顺 / 逆时针旋转、恢复原始方向、移到废纸篓、在 Finder 中显示、
  复制路径，以及按文件名 / 拍摄日期及时间 / 型号名 / 镜头名排序 + 升 / 降序
· 视频文件提供封面帧、拍摄时间/GPS 写入与简单播放
· 轨迹匹配写入 GPS（工具栏 /「工具」菜单 ⌥⌘G）：用 GPX / TCX / FIT 轨迹按拍摄时间
  给「选中的照片」或「当前目录全部照片」写入 GPS；FIT 为二进制轨迹，程序内置解码器
  无需转换、也不依赖 fitparse；支持小米伪 Z 时间修正（仅 GPX / TCX）、
  前 3 条轨迹时间预览、匹配容差/照片时区、写入前备份到 exif_backup/、
  滚动处理日志，结束时在当前目录生成 GPS写入日志_时间戳.log

关于轨迹写入的外部依赖
----------------------
该功能需要本机安装 exiftool（https://exiftool.org/），程序会自动在 PATH 与常见
安装位置查找。未安装时仍可解析轨迹、查看预览、试运行匹配，但提交会被阻止。
exiftool 不随本 DMG 分发，也只是可选运行时工具，不是编译依赖。
**这是唯一会修改原始照片文件的功能**：默认备份、默认跳过已有 GPS、
超出容差绝不写入；提交前会二次确认。

关于高德地图 Key
----------------
到 https://lbs.amap.com 控制台创建「Web端 (JS API)」类型的 Key，
并取得配套的安全密钥 jscode。打开 App 的「地图位置」窗口，
把两者填入顶部输入框后点「应用」。
若给 Key 设过域名白名单，请放行 photoscope.local（WebView 的页面 host）。
Key 仅保存在本机 UserDefaults，不会随程序分发；源码不含任何可用密钥。
未配置时窗口显示坐标卡片与申请指引，不会白屏。

命令行自检
----------
/Applications/PhotoScope.app/Contents/MacOS/PhotoScope --selftest --dir /path/to/photos

完整说明
--------
同目录下的「PhotoScope-操作与功能说明.md」包含界面布局、全部功能与快捷键、
支持格式、JPG 导出的 EXIF 保留行为、高德地图 Key 配置与常见问题。
README

# 完整手册随包分发（若文件存在）
DOC="PhotoScope-操作与功能说明.md"
if [ -f "$DOC" ]; then
    cp "$DOC" "$STAGE/$DOC"
fi

echo "==> 生成 DMG（UDZO 压缩，只读）"
rm -f "$DMG"
hdiutil create -volname "$VOLUME_NAME" -srcfolder "$STAGE" \
    -ov -format UDZO -o "$DMG" >/dev/null

echo "==> 校验 DMG 可挂载且内容完整"
hdiutil verify "$DMG" >/dev/null 2>&1 || {
    echo "!! DMG 校验失败" >&2
    exit 1
}
MOUNT="$(mktemp -d /tmp/photoscope-mount.XXXXXX)"
hdiutil attach "$DMG" -mountpoint "$MOUNT" -nobrowse -readonly >/dev/null
[ -x "$MOUNT/${APP_NAME}.app/Contents/MacOS/${APP_NAME}" ] || {
    echo "!! DMG 内缺少可执行文件" >&2; exit 1; }
[ -L "$MOUNT/Applications" ] || { echo "!! DMG 内缺少 Applications 快捷方式" >&2; exit 1; }
[ -f "$MOUNT/README.txt" ] || { echo "!! DMG 内缺少 README.txt" >&2; exit 1; }
if [ -f "$DOC" ]; then
    [ -f "$MOUNT/$DOC" ] || { echo "!! DMG 内缺少操作说明文档" >&2; exit 1; }
fi
ARCHS="$(lipo -info "$MOUNT/${APP_NAME}.app/Contents/MacOS/${APP_NAME}" 2>/dev/null | sed 's/.*: //' || true)"
hdiutil detach "$MOUNT" >/dev/null
rmdir "$MOUNT" 2>/dev/null || true
MOUNT=""

echo "==> 完成: $DMG"
echo "    卷名: $VOLUME_NAME"
echo "    内容: ${APP_NAME}.app / Applications / README.txt / ${DOC}"
echo "    架构: ${ARCHS:-unknown}"
echo "    大小: $(du -h "$DMG" | cut -f1)"
