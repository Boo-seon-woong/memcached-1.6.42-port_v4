#!/usr/bin/env bash
# 블록 4 (osdi exp4 batching) 무인 구동. 구성마다 무장 → GO → genie 응답 대기.
#
#   nohup bash tools/night-block4.sh > /tmp/night-b4.log 2>&1 &
#
# 구성이 10 개고 각각 서버 재기동이 필요해 왕복이 10 번이다. 사람이 끼면
# 그 10 번이 밤을 다 먹는다. 실패하면 멈춘다 — 스스로 재시도하지 않는다.
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd); cd "$ROOT"
S=/tmp/night-msgs; mkdir -p $S

# chain reap  (E4-C8 == E4-R8 == 운영점, 한 번만)
CFG="1 8
2 8
4 8
8 8
12 8
16 8
8 1
8 2
8 4
8 12"

echo "$CFG" | while read -r c r; do
  [ -n "$c" ] || continue
  id="E4-C${c}R${r}"
  echo "=== $id  $(date -u +%H:%M:%S) ==="
  INLINE=1 AD=64 RE="$r" PC="$c" SQ=1 DEM=${DEM:-0} \
    tools/night-arm.sh 20 24 4 64 > /tmp/night-arm-$id.txt 2>&1 || {
      echo "ARM FAILED $id"; cat /tmp/night-arm-$id.txt; exit 1; }
  fp=$(cat /tmp/night-arm-$id.txt)

  # set -e 아래에서 `A || B && C` 를 그대로 쓰면 조건이 거짓인 구성에서
  # 목록 전체가 non-zero 를 돌려주고 스크립트가 죽는다. if 로 쓴다.
  low=""
  if [ "$r" = 8 ] && { [ "$c" = 1 ] || [ "$c" = 8 ]; }; then
    low=$'\n'"${id}-LO-W1        0:1        8      30s"$'\n'"${id}-LO-W2        1:9        8      30s"
  fi

  cat > $S/$id.md <<EOF

---

## [$(TZ=Asia/Seoul date +%Y-%m-%d) KST] ariel — 블록 4: \`$id\` 무장 (chain=$c reap=$r)

\`\`\`text
$fp
\`\`\`

### 요청

\`\`\`text
셀                     ratio      pipe   test-time
${id}-W1            0:1        256    30s
${id}-W2            1:9        256    30s
${id}-W3            1:0        256    30s$low

memtier -s 10.99.0.3 -p 11411 -P memcache_text -d 64 \\
  --key-prefix=m- --key-minimum=1 --key-maximum=1000000 --key-pattern=R:R \\
  --distinct-client-seed --hide-histogram -t 30 -c 4 \\
  --pipeline=<pipe> --test-time=30 --ratio=<ratio>
\`\`\`

W3(SET-only) 생략 금지. 셀마다 avg/p50/p99/p99.9.
raw \`experiments/night-20260806/genie/<cell>.txt\`.

NEXT: genie ($id)
EOF
  TIMEOUT=1800 tools/night-cell.sh post $S/$id.md "$id" || { echo "WAIT FAILED $id"; exit 1; }
done
echo "=== BLOCK4 DONE $(date -u +%H:%M:%S) ==="
