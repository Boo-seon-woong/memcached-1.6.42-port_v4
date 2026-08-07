#!/usr/bin/env bash
# 무장 + 프리로드 + 지문 출력을 한 번에. 야간 캠페인용.
#
#   INLINE=1 AD=64 RE=8 PC=8 DEM=0 tools/night-arm.sh 20 24 4 64
#
# 재기동하면 캐시가 비므로 프리로드는 매번 필요하다. 지문은 GO 메시지에
# 그대로 붙일 수 있는 형태로 찍는다.
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
G="ssh -n -i $HOME/.ssh/snp_guest -p 2222 -o BatchMode=yes -o ConnectTimeout=8 ubuntu@localhost"
D=${DVAL:-64}

"$ROOT/tools/exp1-arm.sh" "$@" >/tmp/night-arm.out 2>&1 || { cat /tmp/night-arm.out; exit 1; }
grep -q "coherent MR 게이트 (2 여야 한다): 2" /tmp/night-arm.out || { echo "GATE FAIL: coherent MR"; cat /tmp/night-arm.out; exit 1; }
grep -q "포트 빌드" /tmp/night-arm.out || { echo "GATE FAIL: not port build"; cat /tmp/night-arm.out; exit 1; }

$G "LD_LIBRARY_PATH=\$HOME/memtier:\$HOME/kvs-port taskset -c 0-29 \
  \$HOME/memtier/memtier_benchmark -s 127.0.0.1 -p 11411 -P memcache_text \
  -d $D --key-prefix=m- --key-minimum=1 --key-maximum=1000000 \
  --threads=8 --clients=16 --pipeline=8 --key-pattern=P:P --ratio=1:0 \
  -n 7813 --hide-histogram >/dev/null 2>&1"

items=$($G 'printf "stats\r\nquit\r\n" | nc -q1 127.0.0.1 11411 | tr -d "\r" | grep -E "^STAT curr_items" | awk "{print \$3}"')
[ "$items" = "1000000" ] || { echo "GATE FAIL: curr_items=$items"; exit 1; }

$G 'printf "stats settings\r\nquit\r\n" | nc -q1 127.0.0.1 11411 | tr -d "\r" |
      grep -E "ext_drain_empty_max|ext_submit_inline|ext_reap_every|ext_post_chain|ext_admit_max|ext_setq_max|ext_submit_batch|reqs_per_event" |
      sed "s/^STAT //" | tr "\n" " "; echo
    printf "stats\r\nquit\r\n" | nc -q1 127.0.0.1 11411 | tr -d "\r" |
      grep -E "ext_qp_per_worker|ext_ord_limit|ext_read_slots|ext_pac_fallback|curr_items|extstore_prof_span_ver" |
      sed "s/^STAT //" | tr "\n" " "; echo'
# 지문은 **실제로 띄운 바이너리**를 해시해야 한다. 고정 경로를 해시하면
# BIN 으로 다른 빌드를 띄웠을 때 게이트가 엉뚱한 sha 를 인증한다.
MCBIN=${BIN:-'$HOME/coherent-mr-v2/bin/memcached'}
sha=$($G "sha256sum $MCBIN | cut -c1-24"); echo "build $sha"
