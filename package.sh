#!/bin/bash
# 生成可分发的安装包：dist/ADBType-<版本>.dmg 和 dist/ADBType-<版本>-macOS.zip
set -euo pipefail
cd "$(dirname "$0")"

./tools/makeicon.sh
./build.sh

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist)
DIST="dist"
STAGE="$DIST/ADBType-macOS"

rm -rf "$DIST"
mkdir -p "$STAGE"
cp -R ADBType.app "$STAGE/"
cp "packaging/安装说明.txt" "$STAGE/"
cp "packaging/授权并安装.sh" "$STAGE/"
chmod +x "$STAGE/授权并安装.sh"
ln -s /Applications "$STAGE/Applications"

echo "==> 打包 zip"
ditto -c -k --keepParent "$STAGE" "$DIST/ADBType-${VERSION}-macOS.zip"

echo "==> 打包 dmg"
hdiutil create -quiet -volname "ADB 输入" -srcfolder "$STAGE" -ov -format UDZO "$DIST/ADBType-${VERSION}.dmg"

echo "==> 校验"
codesign --verify --deep --strict "ADBType.app"
lipo -info "ADBType.app/Contents/MacOS/ADBType"
ls -lh "$DIST"
