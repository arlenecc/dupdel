#!/bin/bash
# 打包成可分发的 DMG（拖拽安装：App + Applications 快捷方式）。
# 用法： ./scripts/make_dmg.sh  ->  dist/DupDel-<版本>.dmg
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
STAGING_DIR="$DIST_DIR/dmg-staging"
APP_NAME="DupDel"
VOLUME_NAME="重复文件清理器"
VERSION="${DUPDEL_VERSION:-1.0.0}"
DMG_PATH="$DIST_DIR/$APP_NAME-$VERSION.dmg"

cd "$ROOT_DIR"
"$ROOT_DIR/scripts/make_app.sh"

echo "==> 准备 DMG 内容"
rm -rf "$STAGING_DIR"
mkdir -p "$STAGING_DIR"
cp -R "$DIST_DIR/$APP_NAME.app" "$STAGING_DIR/"
ln -s /Applications "$STAGING_DIR/Applications"
xattr -cr "$STAGING_DIR/$APP_NAME.app"

echo "==> 生成 DMG（UDZO 压缩）"
rm -f "$DMG_PATH"
hdiutil create \
    -volname "$VOLUME_NAME" \
    -srcfolder "$STAGING_DIR" \
    -format UDZO \
    -imagekey zlib-level=9 \
    -ov \
    "$DMG_PATH" > /dev/null

echo "==> 签名并校验 DMG"
codesign --force --sign - "$DMG_PATH" > /dev/null 2>&1 || true
hdiutil verify "$DMG_PATH" > /dev/null
spctl --assess --type open --context context:primary-signature "$DMG_PATH" > /dev/null 2>&1 || \
    echo "提示：未使用 Apple 开发者证书签名；他人首次打开需右键「打开」，或在「隐私与安全性」中允许。"

rm -rf "$STAGING_DIR"

echo "已生成：$DMG_PATH"
ls -lh "$DMG_PATH"
