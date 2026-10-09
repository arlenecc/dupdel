#!/bin/bash
# 构建并打包成标准 macOS App（含图标、Info.plist、ad-hoc 签名）。
# 用法： ./scripts/make_app.sh  ->  dist/DupDel.app
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
APP_DIR="$DIST_DIR/DupDel.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
BUNDLE_NAME="DupDel"
VERSION="${DUPDEL_VERSION:-1.0.0}"
BUILD_NUMBER="$(date +%Y%m%d%H%M)"

cd "$ROOT_DIR"
mkdir -p "$DIST_DIR"

# 默认构建通用二进制（Apple Silicon + Intel）；可用 DUPDEL_ARCHS=arm64 关闭
ARCH_FLAGS=()
for arch in ${DUPDEL_ARCHS:-arm64 x86_64}; do
    ARCH_FLAGS+=(--arch "$arch")
done

echo "==> 编译 Release (${DUPDEL_ARCHS:-arm64 x86_64})"
swift build -c release "${ARCH_FLAGS[@]}"
BIN_DIR="$(swift build -c release "${ARCH_FLAGS[@]}" --show-bin-path)"

echo "==> 生成图标"
if [ ! -x "$DIST_DIR/make_icon" ] || [ "$ROOT_DIR/scripts/make_icon.swift" -nt "$DIST_DIR/make_icon" ]; then
    swiftc -O "$ROOT_DIR/scripts/make_icon.swift" -o "$DIST_DIR/make_icon"
fi
rm -rf "$DIST_DIR/AppIcon.iconset"
"$DIST_DIR/make_icon" "$DIST_DIR/AppIcon.iconset" > /dev/null
iconutil -c icns "$DIST_DIR/AppIcon.iconset" -o "$DIST_DIR/AppIcon.icns"

echo "==> 组装 App 包"
rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"
cp "$BIN_DIR/$BUNDLE_NAME" "$MACOS_DIR/$BUNDLE_NAME"
cp "$DIST_DIR/AppIcon.icns" "$RESOURCES_DIR/AppIcon.icns"
printf 'APPL????' > "$CONTENTS_DIR/PkgInfo"

cat > "$CONTENTS_DIR/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>zh_CN</string>
    <key>CFBundleExecutable</key>
    <string>$BUNDLE_NAME</string>
    <key>CFBundleIdentifier</key>
    <string>com.dupdel.app</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>$BUNDLE_NAME</string>
    <key>CFBundleDisplayName</key>
    <string>重复文件清理器</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundleVersion</key>
    <string>$BUILD_NUMBER</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIconName</key>
    <string>AppIcon</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.utilities</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>NSHumanReadableCopyright</key>
    <string>DupDel $VERSION</string>
</dict>
</plist>
PLIST

# 去掉编译产物可能带上的扩展属性，否则签名会失败
xattr -cr "$APP_DIR"

echo "==> 代码签名（ad-hoc）"
codesign --force --sign - --timestamp=none "$APP_DIR"
codesign --verify --deep --strict --verbose=1 "$APP_DIR"

# 让 Finder/LaunchServices 立刻识别新的图标
touch "$APP_DIR"

echo "可执行文件架构：$(lipo -archs "$MACOS_DIR/$BUNDLE_NAME")"
echo "已生成：$APP_DIR"
du -sh "$APP_DIR"
