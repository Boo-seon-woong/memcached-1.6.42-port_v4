#!/bin/bash
# EXP-1 구성 하나를 guest에 띄운다. host에서 실행.
#
#   tools/exp1-arm.sh S2          # 표에 있는 이름
#   tools/exp1-arm.sh 4 40 4 64   # submit_batch W nqp read_slots
#
# 구성마다 손으로 tmux 줄을 고치면 한 글자가 어긋나도 모른다. 표를 코드에
# 두고 이름으로만 부른다. 기동 후 게이트 세 개(coherent MR, genie_connect,
# stats settings 판별자)를 찍는다 — 하나라도 비면 그대로 보인다.
set -eu
G="ssh -n -i $HOME/.ssh/snp_guest -p 2222 -o BatchMode=yes -o ConnectTimeout=8 ubuntu@localhost"

MCT=${MCT:-30}  # 워커 스레드 수
CPUSET=${CPUSET:-0-29}
SQ=${SQ:-1}    # ext_setq_max
PC=${PC:-1}    # ext_post_chain
RE=${RE:-1}    # ext_reap_every
AD=${AD:-0}    # ext_admit_max: 워커당 backend 체류 상한 (0=무제한)
ILP=${ILP:-0}  # item_lock_power: 0 = 스레드수에서 유도(30스레드면 15)
HP=${HP:-22}  # hashpower
ORD=${ORD:-0}  # ext_ord_limit: QP당 READ 게이트. 0 = CM 협상값(16)
ORDOPT=""; [ "$ORD" != 0 ] && ORDOPT=",ext_ord_limit=$ORD"
ILPOPT=""; [ "$ILP" != 0 ] && ILPOPT=",item_lock_power=$ILP"
R=${R:-1024}   # reqs_per_event: pass 당 명령 수 상한 (= backend 유입 조리개)
SLOT=${SLOT:-256}   # EXT_SLOT_SIZE — semi_final 은 1024
PROF=${PROF-1}  # EXT_RDMA_PROF. 빈 값이면 계측 없이 뜬다 (exp1 은 −4.2% 를 안 물어야 한다)
# BIN 은 게스트에서 전개돼야 한다. 기본값에 \$HOME 을 그냥 쓰면
# 로컬 셸이 먼저 전개해 host 의 홈이 박힌다(2026-08-06 야간에 이걸로
# 무장이 다섯 번 연속 실패했다). 단따옴표로 막고 원격에서 푼다.
MCBIN=${BIN:-'$HOME/coherent-mr-v2/bin/memcached'}
DEM=${DEM:-0}  # ext_drain_empty_max: 연속 빈 CQ poll 이 이 값이면 스핀 중단. 0=무중단
case "${1:-}" in
  S3) SB=20; W=40; NQP=4; SLOTS=64 ;;
  S2) SB=4;  W=40; NQP=4; SLOTS=64 ;;
  S1) SB=1;  W=40; NQP=4; SLOTS=64 ;;
  W1) SB=${2:?best submit_batch}; W=64; NQP=4; SLOTS=64 ;;
  W2) SB=${2:?best submit_batch}; W=96; NQP=8; SLOTS=128 ;;
  A*) SB=${SB:-20}; W=40; NQP=4; SLOTS=64; AD=${1#A} ;;   # A<n>: admission 축
  R*) SB=20; W=40; NQP=4; SLOTS=64; R=${1#R} ;;   # R<n>: -R 축. 그 외는 기준선
  [0-9]*) SB=$1; W=${2:?}; NQP=${3:?}; SLOTS=${4:?} ;;
  *) echo "usage: $0 {S3|S2|S1|W1 <sb>|W2 <sb>| <sb> <W> <nqp> <slots>}" >&2; exit 1 ;;
esac

echo "── 무장: submit_batch=$SB W=$W nqp=$NQP READ_SLOTS=$SLOTS -R $R admit=$AD reap=$RE chain=$PC setq=$SQ dem=$DEM mcT=$MCT ilp=$ILP hp=$HP ord=$ORD cpu=$CPUSET (총 QP = $MCT × $NQP)"

# /tmp 에 스테이징한 바이너리(mc_stock 등)는 이름이 memcached 가 아니라
# -x 로 안 죽는다. 그래서 포트가 안 뜬 채 stock 이 계속 서비스했고, 나는
# 낡은 /tmp/mc.log 를 읽고 "게이트 2 통과"로 오독했다. 로그도 함께 비운다.
$G 'tmux kill-session -t mc 2>/dev/null || true; pkill -x memcached 2>/dev/null; pkill -f "^/tmp/mc_" 2>/dev/null; : > /tmp/mc.log'
sleep 3

$G "tmux new-session -d -s mc \"cd \\\$HOME/kvs-port && exec taskset -c $CPUSET env \
LD_LIBRARY_PATH=\\\$HOME/coherent-mr-v2/lib:\\\$HOME/kvs-port \
MLX5_COHERENT_QP=1 MLX5_COHERENT_CQ=1 ${PROF:+EXT_RDMA_PROF=1} EXT_SELFTEST=1 \
EXT_CRYPTO_KEY=\\\$HOME/kvs-port/ext.key EXT_SLOT_SIZE=256 EXT_READ_SLOTS=$SLOTS \
$MCBIN -p 11411 -U 0 -t $MCT -m 2048 -c 16384 -R $R \
-o ext_path=10.99.0.2:11212:4g,ext_worker_window=$W,ext_qp_per_worker=$NQP,ext_drain_spin=1024,hashpower=$HP,ext_submit_batch=$SB,ext_admit_max=$AD${INLINE:+,ext_submit_inline},ext_reap_every=$RE,ext_post_chain=$PC,ext_setq_max=$SQ,ext_drain_empty_max=$DEM$ILPOPT$ORDOPT \
> /tmp/mc.log 2>&1\""
sleep 10

echo "── coherent MR 게이트 (2 여야 한다): $($G 'grep -icE "coherent MR [0-9]+B" /tmp/mc.log')"
$G 'grep -iE "genie_connect OK|Address already|error|failed" /tmp/mc.log | head -3'
$G 'printf "stats settings\r\nquit\r\n" | timeout 5 nc -q1 127.0.0.1 11411 | grep -E "ext_submit_batch|ext_drain_spin|ext_pac_set|reqs_per_event|ext_admit_max|ext_submit_inline|ext_reap_every|ext_post_chain|ext_setq_max|ext_drain_empty_max"'
echo "── 프리로드 필요 (재기동했다)"

# 무엇이 11411 을 쥐고 있는지 확인한다. 로그만 보면 낡은 것을 읽는다 —
# stock 이 계속 서비스하는데 낡은 로그를 보고 "게이트 2"라 한 적이 있다.
# ps 는 tmux 명령줄을 잡으니 못 쓴다. stock 에 없는 설정으로 판별한다.
if [ "$($G 'printf "stats settings\r\nquit\r\n" | timeout 5 nc -q1 127.0.0.1 11411 | grep -c ext_submit_inline')" -ge 1 ]; then
  echo "── 서비스 중: 포트 빌드 (ext_submit_inline 응답)"
else
  echo "── 서비스 중: ★포트가 아니다★ — stock 이 남아 있거나 기동 실패다"
fi
