#!/usr/bin/env bash
#
# 打包脚本：将 release 构建产物封装为 macOS .app 应用包，并生成可分发的 .dmg 磁盘镜像。
#
# 用法：
#   ./scripts/package.sh
#
# 产物：
#   dist/Renamer.app
#   dist/Renamer_v<版本号>.dmg
#
# 版本号读取自仓库根目录的 VERSION 文件（遵循语义化版本 MAJOR.MINOR.PATCH）。

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

APP_NAME="Renamer"
BUNDLE_ID="com.renamer.app"
VERSION="$(tr -d '[:space:]' < VERSION)"
DIST_DIR="$ROOT_DIR/dist"
APP_DIR="$DIST_DIR/$APP_NAME.app"
DMG_PATH="$DIST_DIR/${APP_NAME}_v${VERSION}.dmg"

echo "==> 构建 release 版本"
swift build -c release

BIN_PATH="$(swift build -c release --show-bin-path)/$APP_NAME"
if [[ ! -f "$BIN_PATH" ]]; then
    echo "错误：未找到可执行文件 $BIN_PATH" >&2
    exit 1
fi

echo "==> 组装 $APP_NAME.app（版本 $VERSION）"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"

cp "$BIN_PATH" "$APP_DIR/Contents/MacOS/$APP_NAME"
chmod +x "$APP_DIR/Contents/MacOS/$APP_NAME"

if [[ -f "$ROOT_DIR/Resources/AppIcon.icns" ]]; then
    cp "$ROOT_DIR/Resources/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"
fi

cat > "$APP_DIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundleDisplayName</key>
    <string>$APP_NAME</string>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>CFBundleExecutable</key>
    <string>$APP_NAME</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundleVersion</key>
    <string>$VERSION</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSHumanReadableCopyright</key>
    <string>© 2026 Renamer</string>
</dict>
</plist>
PLIST

cat > "$APP_DIR/Contents/PkgInfo" <<< "APPL????"

echo "==> 生成 DMG"
rm -f "$DMG_PATH"
hdiutil create \
    -volname "$APP_NAME $VERSION" \
    -srcfolder "$APP_DIR" \
    -ov \
    -format UDZO \
    "$DMG_PATH" >/dev/null

echo "==> 完成"
echo "    应用包: $APP_DIR"
echo "    磁盘镜像: $DMG_PATH"
