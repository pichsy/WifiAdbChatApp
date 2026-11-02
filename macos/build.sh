#!/bin/bash
# 编译并打包「文件互传助手.app」（原生 SwiftUI，无第三方依赖）
set -euo pipefail
cd "$(dirname "$0")"

BUNDLE_NAME="文件互传助手"
EXECUTABLE="ADBType"
APP="${BUNDLE_NAME}.app"
SDK=$(xcrun --sdk macosx --show-sdk-path)
ARCHS="${ARCHS:-arm64 x86_64}"

rm -rf "$APP" build
mkdir -p build "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "==> 编译 (${ARCHS}, macOS 13+)"
BINARIES=()
for arch in $ARCHS; do
    out="build/${EXECUTABLE}-${arch}"
    swiftc -O \
        -swift-version 5 \
        -target "${arch}-apple-macos13.0" \
        -sdk "$SDK" \
        -framework SwiftUI -framework AppKit \
        Sources/*.swift \
        -o "$out"
    BINARIES+=("$out")
done

if [ "${#BINARIES[@]}" -eq 1 ]; then
    cp "${BINARIES[0]}" "build/${EXECUTABLE}"
else
    lipo -create "${BINARIES[@]}" -output "build/${EXECUTABLE}"
fi

echo "==> 组装 app bundle"
cp "build/${EXECUTABLE}" "$APP/Contents/MacOS/${EXECUTABLE}"
cp Resources/Info.plist "$APP/Contents/Info.plist"
if [ -f Resources/AppIcon.icns ]; then
    cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
fi
if [ -f Resources/adbtype-clip.jar ]; then
    cp Resources/adbtype-clip.jar "$APP/Contents/Resources/adbtype-clip.jar"
else
    echo "警告: 缺少 Resources/adbtype-clip.jar，中文粘贴会不可用（先运行 tools/buildclip.sh）" >&2
fi

echo "==> 本地临时签名"
codesign --force --sign - "$APP" >/dev/null 2>&1 || true

echo "完成: $(pwd)/${APP}"
