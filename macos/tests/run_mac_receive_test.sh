#!/bin/bash
set -uo pipefail
cd "$(dirname "$0")/.."
SUP="$HOME/Library/Application Support/ADBType"
mkdir -p /tmp/lanback
cp "$SUP/paired.json" /tmp/lanback/paired.json 2>/dev/null || true
cp "$SUP/chat.json" /tmp/lanback/chat.json 2>/dev/null || true
rm -rf /tmp/lan-test-recv; mkdir -p /tmp/lan-test-recv
head -c 1048576 /dev/urandom > /tmp/lan-test-file.bin

/tmp/lan_probe serve --seconds 30 --name MacProbe --receive-dir /tmp/lan-test-recv > /tmp/probe.log 2>&1 &
PROBE=$!
for i in $(seq 1 60); do grep -q READY /tmp/probe.log 2>/dev/null && break; sleep 0.2; done
CODE=$(sed -n 's/.*code=\([0-9][0-9]*\).*/\1/p' /tmp/probe.log | head -1)
echo "CODE=$CODE"
PORT=$(lsof -nP -a -p "$PROBE" -iTCP -sTCP:LISTEN 2>/dev/null | awk 'NR>1 {print $9}' | sed 's/.*://' | head -1)
echo "PORT=$PORT"
python3 tests/py_send.py --code "$CODE" --host 127.0.0.1 --port "$PORT" --file /tmp/lan-test-file.bin
SEND_EXIT=$?
sleep 1
kill "$PROBE" 2>/dev/null || true
wait "$PROBE" 2>/dev/null || true
echo '--- probe log'
cat /tmp/probe.log
echo '--- chat.json (tail)'
tail -c 1800 "$SUP/chat.json" 2>/dev/null; echo
echo '--- recv dir'
ls -l /tmp/lan-test-recv
if cmp -s /tmp/lan-test-file.bin "/tmp/lan-test-recv/lan-test-file.bin"; then echo FILE_IDENTICAL; else echo FILE_MISMATCH; fi
if [ -f /tmp/lanback/chat.json ]; then cp /tmp/lanback/chat.json "$SUP/chat.json"; else rm -f "$SUP/chat.json"; fi
if [ -f /tmp/lanback/paired.json ]; then cp /tmp/lanback/paired.json "$SUP/paired.json"; fi
rm -rf /tmp/lan-test-recv /tmp/lan-test-file.bin
echo "SEND_EXIT=$SEND_EXIT"
echo "RESTORED paired=$(cat "$SUP/paired.json" 2>/dev/null)"
