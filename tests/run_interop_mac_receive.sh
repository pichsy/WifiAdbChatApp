#!/bin/bash
set -uo pipefail
cd "$(dirname "$0")/.."
SUP="$HOME/Library/Application Support/ADBType"
mkdir -p /tmp/lanback3
cp "$SUP/paired.json" /tmp/lanback3/paired.json 2>/dev/null || true
cp "$SUP/chat.json" /tmp/lanback3/chat.json 2>/dev/null || true

rm -rf /tmp/macprobe-recv; mkdir -p /tmp/macprobe-recv
head -c 900000 /dev/urandom > /tmp/interop2-file.bin

/tmp/lan_probe serve --seconds 60 --name MacProbe --receive-dir /tmp/macprobe-recv > /tmp/macprobe.log 2>&1 &
PROBE=$!
for i in $(seq 1 60); do grep -q READY /tmp/macprobe.log 2>/dev/null && break; sleep 0.2; done
CODE=$(sed -n 's/.*code=\([0-9][0-9]*\).*/\1/p' /tmp/macprobe.log | head -1)
echo "MAC CODE=$CODE"

DOTNET="$HOME/.dotnet/dotnet"
( cd windows && "$DOTNET" run --project src/ADBTypeLink.TestPeer/ADBTypeLink.TestPeer.csproj -c Release --no-build -- \
    send --peer-name MacProbe --text "你好，这是 Windows core 发来的文字 🚀" \
    --file /tmp/interop2-file.bin --code "$CODE" \
    --data-dir /tmp/winprobe-send-data --name WinProbe --timeout 30 > /tmp/winsend.log 2>&1 )
SEND_EXIT=$?
sleep 2
echo '--- windows sender log'
cat /tmp/winsend.log
echo '--- mac probe log'
cat /tmp/macprobe.log
echo '--- received files'
ls -l /tmp/macprobe-recv 2>/dev/null
if cmp -s /tmp/interop2-file.bin /tmp/macprobe-recv/interop2-file.bin; then echo INTEROP2_FILE_IDENTICAL; else echo INTEROP2_FILE_MISMATCH; fi
kill "$PROBE" 2>/dev/null || true
wait "$PROBE" 2>/dev/null || true

if [ -f /tmp/lanback3/chat.json ]; then cp /tmp/lanback3/chat.json "$SUP/chat.json"; else rm -f "$SUP/chat.json"; fi
if [ -f /tmp/lanback3/paired.json ]; then cp /tmp/lanback3/paired.json "$SUP/paired.json"; fi
rm -rf /tmp/macprobe-recv /tmp/interop2-file.bin /tmp/winprobe-send-data
echo "SEND_EXIT=$SEND_EXIT"
echo "RESTORED paired=$(cat "$SUP/paired.json" 2>/dev/null)"
