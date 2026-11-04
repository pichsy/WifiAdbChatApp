#!/usr/bin/env bash
# 一键运行 mobile/tests 下的协议自测与端到端联调自测（不依赖 Android/iOS App）。
#
#   ./run_tests.sh                 # 跑全部（推荐）
#   ./run_tests.sh -k pairing      # 只跑名字含 pairing 的用例
#   PYTHON=/path/to/python3 ./run_tests.sh
set -uo pipefail
cd "$(dirname "$0")"

PYTHON_BIN=${PYTHON:-python3}
echo "== Python: $("$PYTHON_BIN" --version 2>&1) =="
echo "== 目录: $(pwd) =="

status=0
if [ "$#" -gt 0 ]; then
  "$PYTHON_BIN" -m unittest -v "$@" || status=1
else
  "$PYTHON_BIN" -m unittest -v test_protocol.py || status=1
  "$PYTHON_BIN" -m unittest -v test_interop.py || status=1
fi

if [ "$status" -eq 0 ]; then
  echo "ALL TESTS PASSED"
else
  echo "SOME TESTS FAILED"
fi
exit "$status"
