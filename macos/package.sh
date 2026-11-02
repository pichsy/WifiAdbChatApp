#!/bin/bash
# 生成可分发的安装包：dist/文件互传助手-<版本>.dmg 和 dist/文件互传助手-<版本>-macOS.zip
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="文件互传助手"
APP="${APP_NAME}.app"

./tools/makeicon.sh
./build.sh

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist)
DIST="dist"
STAGE="$DIST/${APP_NAME}-macOS"

rm -rf "$DIST"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
cp "packaging/安装说明.txt" "$STAGE/"
cp "packaging/授权并安装.sh" "$STAGE/"
chmod +x "$STAGE/授权并安装.sh"
ln -s /Applications "$STAGE/Applications"

echo "==> 打包 zip"
ditto -c -k --keepParent "$STAGE" "$DIST/${APP_NAME}-${VERSION}-macOS.zip"

echo "==> 打包 dmg"
hdiutil create -quiet -volname "$APP_NAME" -srcfolder "$STAGE" -ov -format UDZO "$DIST/${APP_NAME}-${VERSION}.dmg"

echo "==> 校验"
codesign --verify --deep --strict "$APP"
lipo -info "$APP/Contents/MacOS/ADBType"
ls -lh "$DIST"
