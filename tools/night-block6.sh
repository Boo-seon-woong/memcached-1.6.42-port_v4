#!/usr/bin/env bash
# 블록 6 (osdi exp3 값 크기) 무인 구동.
#
# 상한 탐침은 genie 가 필요 없다 — 프리로드 자체가 1M 건의 SET 이라
# `ext_pac_fallback` 이 그 자리에서 판정된다. 계산값은 키 12 B 기준 155 B.
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd); cd "$ROOT"
G="ssh -n -i $HOME/.ssh/snp_guest -p 2222 -o BatchMode=yes -o ConnectTimeout=8 ubuntu@localhost"
S=/tmp/night-msgs; mkdir -p $S

fb() { $G 'printf "stats\r\nquit\r\n" | nc -q1 127.0.0.1 11411 | tr -d "\r" |
        awk "/^STAT ext_pac_fallback/{print \$3}"'; }

# ── 상한 탐침: 큰 값부터 내려오며 fallback=0 인 첫 값을 CAP 으로
CAP=""
for d in 152 144 136 128; do
  echo "=== probe -d $d  $(date -u +%H:%M:%S) ==="
  INLINE=1 AD=64 RE=8 PC=8 SQ=1 DEM=0 DVAL=$d tools/night-arm.sh 20 24 4 64 \
    > /tmp/night-arm-probe$d.txt 2>&1 || { echo "ARM FAILED d=$d"; cat /tmp/night-arm-probe$d.txt; exit 1; }
  f=$(fb); echo "  ext_pac_fallback=$f"
  if [ "${f:-1}" = 0 ]; then CAP=$d; break; fi
done
[ -n "$CAP" ] || { echo "NO CAP FOUND"; exit 1; }
echo "=== CAP=$CAP ==="

for d in 16 32 64 "$CAP"; do
  id="V$d"
  echo "=== $id  $(date -u +%H:%M:%S) ==="
  INLINE=1 AD=64 RE=8 PC=8 SQ=1 DEM=0 DVAL=$d tools/night-arm.sh 20 24 4 64 \
    > /tmp/night-arm-$id.txt 2>&1 || { echo "ARM FAILED $id"; exit 1; }
  f=$(fb); [ "${f:-1}" = 0 ] || { echo "GATE FAIL $id: pac_fallback=$f"; exit 1; }
  fp=$(grep -v '^──' /tmp/night-arm-$id.txt)

  cat > $S/$id.md <<EOF

---

## [$(TZ=Asia/Seoul date +%Y-%m-%d) KST] ariel — 블록 6: 값 크기 \`-d $d\` 무장 ($id)

\`\`\`text
$fp
ext_pac_fallback = 0  ← 전 건 원격 경로. 이 게이트가 이 블록의 판정 조건이다
\`\`\`

프리로드도 \`-d $d\` 로 다시 했다(1M 키). **부하도 반드시 \`-d $d\`** 로 —
프리로드와 부하의 크기가 어긋나면 SET 은 새 크기, GET 은 옛 크기를 읽는다.

\`\`\`text
셀          ratio   pipe   test-time   -d
${id}-W1     0:1     256    30s         $d
${id}-W2     1:9     256    30s         $d
${id}-W3     1:0     256    30s         $d

memtier -s 10.99.0.3 -p 11411 -P memcache_text -d $d \\
  --key-prefix=m- --key-minimum=1 --key-maximum=1000000 --key-pattern=R:R \\
  --distinct-client-seed --hide-histogram -t 30 -c 4 \\
  --pipeline=256 --test-time=30 --ratio=<ratio>
\`\`\`

셀마다 avg/p50/p99/p99.9. raw \`experiments/night-20260806/genie/<cell>.txt\`.

NEXT: genie ($id 3부하)
EOF
  TIMEOUT=1800 tools/night-cell.sh post $S/$id.md "$id" || { echo "WAIT FAILED $id"; exit 1; }
done
echo "=== BLOCK6 DONE CAP=$CAP $(date -u +%H:%M:%S) ==="
