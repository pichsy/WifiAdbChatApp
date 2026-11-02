#!/bin/bash
# 编译剪贴板注入用的 dex（推送到手机 /data/local/tmp 后由 app_process 运行）
set -euo pipefail
cd "$(dirname "$0")/.."

SDK="${ANDROID_HOME:-$HOME/Android/sdk}"
ANDROID_JAR="$SDK/platforms/android-31/android.jar"
D8="$SDK/build-tools/34.0.0/d8"

if [ ! -f "$ANDROID_JAR" ]; then
    echo "找不到 $ANDROID_JAR" >&2
    exit 1
fi
if [ ! -x "$D8" ]; then
    echo "找不到 d8: $D8" >&2
    exit 1
fi

rm -rf build/clip
mkdir -p build/clip/classes build/clip/dex

echo "==> javac"
javac -source 1.8 -target 1.8 -classpath "$ANDROID_JAR" \
    -d build/clip/classes tools/clip/Clip.java

echo "==> d8"
"$D8" --release --min-api 26 --lib "$ANDROID_JAR" \
    --output build/clip/dex build/clip/classes/Clip.class

echo "==> 打包 jar"
rm -f Resources/adbtype-clip.jar
zip -q -j Resources/adbtype-clip.jar build/clip/dex/classes.dex
ls -l Resources/adbtype-clip.jar
