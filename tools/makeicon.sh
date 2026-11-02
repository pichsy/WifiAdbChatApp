#!/bin/bash
# 重新生成应用图标：
#   有 Resources/icon-source.png 时直接用它缩放出整套尺寸；
#   没有时退回 tools/makeicon.swift 的矢量绘制。
set -euo pipefail
cd "$(dirname "$0")/.."

mkdir -p build
rm -rf build/AppIcon.iconset
mkdir -p build/AppIcon.iconset

if [ -f Resources/icon-source.png ]; then
    SOURCE=Resources/icon-source.png
    echo "==> 从 $SOURCE 生成图标"
    # 先放大到 1024 母版，再统一从母版缩放，边缘和配色更一致
    sips -z 1024 1024 "$SOURCE" --out build/icon-master.png >/dev/null
    for spec in \
        16:icon_16x16 32:icon_16x16@2x \
        32:icon_32x32 64:icon_32x32@2x \
        128:icon_128x128 256:icon_128x128@2x \
        256:icon_256x256 512:icon_256x256@2x \
        512:icon_512x512 1024:icon_512x512@2x; do
        size="${spec%%:*}"
        name="${spec#*:}"
        sips -z "$size" "$size" build/icon-master.png \
            --out "build/AppIcon.iconset/${name}.png" >/dev/null
    done
else
    echo "==> 用 tools/makeicon.swift 绘制图标"
    swiftc -O tools/makeicon.swift -o build/makeicon
    build/makeicon build/AppIcon.iconset
fi

iconutil -c icns build/AppIcon.iconset -o Resources/AppIcon.icns
echo "图标已更新: Resources/AppIcon.icns"
