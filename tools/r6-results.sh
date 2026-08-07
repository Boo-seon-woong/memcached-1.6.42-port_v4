#!/usr/bin/env bash
# RESULTS2.md = 사람이 쓴 머리말 + 생성된 전 축 표. 표는 손대지 않는다.
set -eu
cd "$(dirname "$0")/.."
{ cat experiments/semi_final/RESULTS2-head.md; echo; python3 tools/r6-tables.py; } \
  > experiments/semi_final/RESULTS2.md
echo "RESULTS2.md $(wc -l < experiments/semi_final/RESULTS2.md) 행"
