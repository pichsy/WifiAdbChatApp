#!/bin/bash
set -uo pipefail
cd "$(dirname "$0")/.."
SUP="$HOME/Library/Application Support/ADBType"
mkdir -p /tmp/lanback2
cp "$SUP/paired.json" /tmp/lanback2/paired.json 2>/dev/null || true
cp "$SUP/chat.json" /tmp/lanback2/chat.json 2>/dev/null || true

WORK=$(mktemp -d /tmp/wincore-recv.XXXXXX)
head -c 1500000 /dev/urandom > /tmp/interop-file.bin

DOTNET="$HOME/.dotnet/dotnet"
( cd ../windows && "$DOTNET" run --project src/ADBTypeLink.SmokeTest/ADBTypeLink.SmokeTest.csproj -c Release --no-build -- --role=server --data-dir="$WORK/data" --receive-dir="$WORK/recv" > /tmp/wincore.log 2>&1 ) &
CHILD=$!
for i in $(seq 1 100); do grep -q '^READY ' /tmp/wincore.log 2>/dev/null && break; sleep 0.2; done
READY=$(grep '^READY ' /tmp/wincore.log | head -1)
echo "CHILD READY: $READY"
CODE=$(echo "$READY" | awk '{print $3}')
PORT=$(echo "$READY" | awk '{print $4}')
echo "CODE=$CODE PORT=$PORT"

/tmp/lan_probe send --peer-name "冒烟测试 子进程" --code "$CODE" --host 127.0.0.1 --port "$PORT" \
  --text "你好，这是 macOS 端通过真实 TCP 发来的文字 👋 中文 emoji ✅" \
  --file /tmp/interop-file.bin --seconds 30

sleep 2
echo '--- windows child log'
cat /tmp/wincore.log
echo '--- received files'
ls -l "$WORK/recv" 2>/dev/null
if cmp -s /tmp/interop-file.bin "$WORK/recv/interop-file.bin"; then echo INTEROP_FILE_IDENTICAL; else echo INTEROP_FILE_MISMATCH; fi
echo '--- windows data dir'
ls -l "$WORK/data" 2>/dev/null
python3 - "$WORK/data/chat.json" <<'PY'
import json, sys
try:
    data = json.load(open(sys.argv[1]))
except Exception as exc:
    print("chat.json error", exc); sys.exit(0)
print("chat entries:", len(data))
for item in data:
    print(" ", item["direction"], item["kind"], item.get("text") or item.get("fileName"))
PY

kill "$CHILD" 2>/dev/null || true
pkill -f 'ADBTypeLink.SmokeTest.*--role=server' 2>/dev/null || true
wait "$CHILD" 2>/dev/null || true
rm -rf "$WORK"

if [ -f /tmp/lanback2/chat.json ]; then cp /tmp/lanback2/chat.json "$SUP/chat.json"; else rm -f "$SUP/chat.json"; fi
if [ -f /tmp/lanback2/paired.json ]; then cp /tmp/lanback2/paired.json "$SUP/paired.json"; fi
rm -f /tmp/interop-file.bin
echo "RESTORED paired=$(cat "$SUP/paired.json" 2>/dev/null)"
