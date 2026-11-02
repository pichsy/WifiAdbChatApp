#!/bin/bash
# 文件互传助手 · 一键安装并解除 macOS 的隔离限制
# 用法（终端里执行）：
#   bash /路径/授权并安装.sh
# 或者给了可执行位之后：./授权并安装.sh
set -uo pipefail
cd "$(dirname "$0")" || exit 1

APP="文件互传助手.app"
DEST="/Applications/${APP}"
HERE="$(pwd)"

pause() {
    echo
    read -n 1 -s -r -p "按任意键关闭这个窗口…"
    echo
}

echo "======================================"
echo "   文件互传助手 · 安装与授权"
echo "======================================"
echo

# 找到 App：脚本旁边（dmg / 解压后的文件夹）、上一级（源码目录）或已经装在应用程序里
SRC=""
if [ -d "${HERE}/${APP}" ]; then
    SRC="${HERE}/${APP}"
elif [ -d "${HERE}/../${APP}" ]; then
    SRC="$(cd "${HERE}/.." && pwd)/${APP}"
elif [ -d "$DEST" ]; then
    SRC="$DEST"
fi

if [ -z "$SRC" ]; then
    echo "没找到 ${APP}。"
    echo "请把「文件互传助手.app」和本脚本放在同一个文件夹，"
    echo "或者先把 App 拖进「应用程序」，再运行本脚本。"
    pause
    exit 1
fi

# 已经在运行就先退出，避免替换文件时出问题
osascript -e 'tell application id "dev.local.adbtype" to quit' >/dev/null 2>&1 || true
pkill -f '文件互传助手.app/Contents/MacOS/ADBType' >/dev/null 2>&1 || true

if [ "$SRC" != "$DEST" ]; then
    echo "==> 安装到 /Applications"
    rm -rf "$DEST" 2>/dev/null || true
    if ! ditto "$SRC" "$DEST" 2>/dev/null; then
        echo "==> 需要管理员权限，请在弹窗里输入开机密码"
        if ! osascript -e "do shell script \"rm -rf '${DEST}' && ditto '${SRC}' '${DEST}'\" with administrator privileges"; then
            echo "安装没成功。可以把 App 手动拖进「应用程序」，再运行一次本脚本。"
            pause
            exit 1
        fi
    fi
fi

echo "==> 解除系统隔离标记（这就是首次打开被拦的原因）"
xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true
xattr -dr com.apple.quarantine "$SRC" 2>/dev/null || true

echo "==> 校验应用签名"
if codesign --verify --deep --strict "$DEST" 2>/dev/null; then
    echo "    签名完好"
else
    echo "    提示：签名校验没通过，App 可能被下载工具改坏了，建议重新下载"
fi

# macOS 13/14 可以把 App 加进白名单；macOS 15+ 已移除这个命令，失败就跳过
spctl --add --label "文件互传助手" "$DEST" >/dev/null 2>&1 || true

echo "==> 打开 App"
open "$DEST"

echo
echo "完成。以后直接双击「应用程序」里的「文件互传助手」即可。"
echo "连接手机后，记得在手机上点「允许 USB 调试」。"
pause
