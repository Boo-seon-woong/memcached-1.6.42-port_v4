#!/usr/bin/env bash
# 블록 2 (shape 캠페인 마감) 무인 구동. 셀마다 서버 재기동이라 왕복이 곧
# 시간이다 — 야간 실행 순서에서 맨 뒤에 둔 이유다. 중간에 끊겨도 셀 단위로
# 쓸모가 있으므로 진행분은 그대로 남는다.
#
#   CELLS="A16-5 A32-1 ..." nohup bash tools/night-block2.sh > /tmp/night-b2.log 2>&1 &
#   (CELLS 미지정이면 아래 기본 목록 전부)
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd); cd "$ROOT"
S=/tmp/night-msgs; mkdir -p $S

# 셀 → nqp ORD W slots  (A: W=P·slots=256 / B: ORD=1 W=64 slots=256 / C2: 운영형태)
spec() { case $1 in
  A16-5)   echo "16 1 16 256" ;;
  A32-1)   echo "2 16 32 256" ;;  A32-2) echo "4 8 32 256" ;;   A32-3) echo "8 4 32 256" ;;
  A32-4)   echo "16 2 32 256" ;;  A32-5) echo "32 1 32 256" ;;
  A64-1)   echo "4 16 64 256" ;;  A64-2) echo "8 8 64 256" ;;   A64-3) echo "16 4 64 256" ;;
  A64-4)   echo "32 2 64 256" ;;  A64-5) echo "64 1 64 256" ;;
  A128-1)  echo "8 16 128 256" ;; A128-2) echo "16 8 128 256" ;; A128-3) echo "32 4 128 256" ;;
  A128-4)  echo "64 2 128 256" ;; A128-5) echo "128 1 128 256" ;;
  B1) echo "1 1 64 256" ;;  B2) echo "2 1 64 256" ;;  B3) echo "4 1 64 256" ;;
  B4) echo "8 1 64 256" ;;  B5) echo "16 1 64 256" ;; B6) echo "32 1 64 256" ;;
  B7) echo "64 1 64 256" ;;
  C1-128|C1-256|C2-*) echo "4 0 24 64" ;;     # 운영 형태 (ORD=0 → CM 협상 16)
  *) return 1 ;;
esac; }
# C2 는 mcT=mtT 를 함께 바꾼다
mct() { case $1 in C2-*) echo "${1#C2-}" ;; *) echo 30 ;; esac; }
pipe_of() { case $1 in C1-128) echo 128 ;; *) echo 256 ;; esac; }

DEFAULT="A16-5 A32-1 A32-2 A32-3 A32-4 A32-5 A64-1 A64-2 A64-3 A64-4 A64-5 \
A128-1 A128-2 A128-3 A128-4 A128-5 B1 B2 B3 B4 B5 B6 B7 \
C2-8 C2-12 C2-16 C2-20 C2-24 C1-128 C1-256"

for id in ${CELLS:-$DEFAULT}; do
  read -r nqp ord w slots <<<"$(spec "$id")" || { echo "UNKNOWN CELL $id"; exit 1; }
  m=$(mct "$id"); p=$(pipe_of "$id")
  echo "=== $id nqp=$nqp ORD=$ord W=$w slots=$slots mcT=$m pipe=$p  $(date -u +%H:%M:%S) ==="
  MCT=$m CPUSET="0-$((m-1))" INLINE=1 AD=64 RE=8 PC=8 SQ=1 DEM=0 ORD=$ord \
    tools/night-arm.sh 20 "$w" "$nqp" "$slots" > /tmp/night-arm-$id.txt 2>&1 || {
      echo "ARM FAILED $id"; tail -20 /tmp/night-arm-$id.txt; echo "--- 다음 셀로 넘어간다"; continue; }
  fp=$(grep -v '^──' /tmp/night-arm-$id.txt)

  cat > $S/$id.md <<EOF

---

## [$(TZ=Asia/Seoul date +%Y-%m-%d) KST] ariel — 블록 2: shape \`$id\` 무장 (nqp=$nqp ORD=$ord W=$w slots=$slots mcT=$m)

\`\`\`text
$fp
\`\`\`

\`\`\`text
셀           ratio   pipe   test-time   mtT
${id}-GET     0:1     $p     60s         $m
${id}-MIX     1:9     $p     60s         $m
${id}-SET     1:0     $p     60s         $m

memtier -s 10.99.0.3 -p 11411 -P memcache_text -d 64 \\
  --key-prefix=m- --key-minimum=1 --key-maximum=1000000 --key-pattern=R:R \\
  --distinct-client-seed --hide-histogram -t $m -c 4 \\
  --pipeline=$p --test-time=60 --ratio=<ratio>
\`\`\`

shape 캠페인은 **60초** 규율이다(08-04 진행분과 같은 조건이어야 이어붙는다).
셀마다 avg/p50/p99/p99.9. raw \`experiments/night-20260806/genie/<cell>.txt\`.

NEXT: genie ($id 3부하)
EOF
  TIMEOUT=1800 tools/night-cell.sh post $S/$id.md "$id" || { echo "WAIT FAILED $id — 중단"; exit 1; }
done
echo "=== BLOCK2 DONE $(date -u +%H:%M:%S) ==="
