#!/bin/bash
# off-box worker sweep 오케스트레이터: guest에서 실행.
#
# genie가 같은 shape를 gap을 두고 N번 돌리는 동안, 부하가 끝난 gap을 감지해서
# 다음 worker 수로 재시작하고 재프리로드한다. 양측이 시각을 맞출 필요가 없다.
#
# 사용: MCLIST="24 28 30" bash tools/obsweep.sh
set -u
MCLIST=${MCLIST:-"24 28 30"}
W=${W:-28}; NQP=${NQP:-4}; SPIN=${SPIN:-1024}; RS=${RS:-64}; EM=${EM:-0}
BIN=${BIN:-$HOME/kvs-port-v3/memcached}
LOG=/tmp/ob_samples.tsv
MARKS=/tmp/ob_marks.txt
: > $MARKS

start_server() {   # $1 = mcT
  local mc=$1 scpu="0-$(( $1 - 1 ))"
  tmux kill-session -t ob 2>/dev/null
  for p in $(pgrep -x memcached); do kill -9 "$p" 2>/dev/null; done
  sleep 1
  local opt="ext_path=10.99.0.2:11212:4g,ext_worker_window=$W,ext_qp_per_worker=$NQP,ext_drain_spin=$SPIN"
  [ "$EM" != 0 ] && opt="$opt,ext_drain_empty_max=$EM"
  tmux new-session -d -s ob "cd $HOME/kvs-port && exec taskset -c $scpu env \
LD_LIBRARY_PATH=$HOME/covlib:$HOME/kvs-port MLX5_COHERENT_QP=1 MLX5_COHERENT_CQ=1 \
EXT_RDMA_PROF=1 EXT_CRYPTO_KEY=$HOME/kvs-port/ext.key EXT_SLOT_SIZE=256 \
EXT_READ_SLOTS=$RS $BIN -p 11411 -U 0 -t $mc -m 2048 -c 16384 -R 1024 -o $opt \
> /tmp/ob_server.log 2>&1"
  sleep 4
  pgrep -x memcached >/dev/null || { echo "START_FAIL mcT=$mc: $(head -2 /tmp/ob_server.log)"; return 1; }
  local MT="$HOME/memtier/memtier_benchmark -s 127.0.0.1 -p 11411 -P memcache_text \
-d 64 --key-prefix=m- --key-minimum=1 --key-maximum=1000000 --hide-histogram"
  LD_LIBRARY_PATH=$HOME/memtier:$HOME/kvs-port taskset -c "$scpu" $MT \
    --threads=8 --clients=16 --pipeline=8 --key-pattern=P:P --ratio=1:0 -n 7813 \
    >/tmp/ob_preload.log 2>&1
  local n
  n=$(printf 'stats\r\nquit\r\n' | timeout 5 nc 127.0.0.1 11411 | tr -d '\r' | awk '/^STAT curr_items /{print $3}')
  echo "$(date -u +%s) READY mcT=$mc curr_items=$n" | tee -a $MARKS
}

# 샘플러는 obup.sh 것을 재사용 — 서버 PID를 다시 잡아야 하므로 재시작마다 띄운다.
start_sampler() {
  tmux kill-session -t obsample 2>/dev/null
  tmux new-session -d -s obsample "LOG=$LOG /tmp/obsample.sh"
}

# cmd_get 증가율로 부하 유무를 판정한다.
getrate() {
  local a b
  a=$(printf 'stats\r\nquit\r\n' | timeout 3 nc 127.0.0.1 11411 2>/dev/null | tr -d '\r' | awk '/^STAT cmd_get /{print $3}')
  sleep 2
  b=$(printf 'stats\r\nquit\r\n' | timeout 3 nc 127.0.0.1 11411 2>/dev/null | tr -d '\r' | awk '/^STAT cmd_get /{print $3}')
  echo $(( (${b:-0} - ${a:-0}) / 2 ))
}

for MC in $MCLIST; do
  start_server "$MC" || exit 1
  start_sampler
  echo "mcT=$MC 준비 완료 — genie shape 대기중"
  # 부하 시작 대기 (최대 10분)
  for _ in $(seq 1 200); do
    [ "$(getrate)" -gt 200000 ] && break
  done
  echo "$(date -u +%s) LOAD_START mcT=$MC" | tee -a $MARKS
  # 부하 종료 대기: 연속 3회 저조
  idle=0
  for _ in $(seq 1 200); do
    if [ "$(getrate)" -lt 100000 ]; then idle=$((idle+1)); else idle=0; fi
    [ $idle -ge 3 ] && break
  done
  echo "$(date -u +%s) LOAD_END mcT=$MC" | tee -a $MARKS
done
echo "sweep 완료. 구간 표시는 $MARKS"
