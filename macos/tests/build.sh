#!/bin/bash
# 编译测试用探针：/tmp/lan_probe（无界面协议联调）和 /tmp/render_chat_ui（界面离屏渲染）
set -euo pipefail
cd "$(dirname "$0")/.."
SDK=$(xcrun --sdk macosx --show-sdk-path)
COMMON=(-O -swift-version 5 -target arm64-apple-macos13.0 -sdk "$SDK" -framework SwiftUI -framework AppKit)

swiftc "${COMMON[@]}" Sources/LANTransfer.swift tests/lan_probe.swift -o /tmp/lan_probe
echo "built /tmp/lan_probe"

swiftc "${COMMON[@]}" Sources/LANTransfer.swift Sources/LANTransferView.swift tests/render_chat_ui.swift -o /tmp/render_chat_ui
echo "built /tmp/render_chat_ui"
