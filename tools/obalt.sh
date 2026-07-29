#!/bin/bash
# 바이너리 교대 A/B 오케스트레이터: BINS 목록을 순서대로, genie 부하 사이 gap에 재시작.
# 사용: BINS="base pad base pad base pad" bash tools/obalt.sh
#   (이름 X → $HOME/kvs-port-v3/memcached.X)
set -u
BINS=${BINS:-"base pad base pad base pad"}
MC=${MC:-28}; W=${W:-28}; NQP=${NQP:-2}; SPIN=${SPIN:-1024}; HP=${HP:-22}
MARKS=/tmp/ob_marks.txt
: > $MARKS

rate() {
  local a b
  a=$(printf 'stats\r\nquit\r\n' | timeout 3 nc 127.0.0.1 11411 2>/dev/null | tr -d '\r' | awk '/^STAT cmd_get /{print $3}')
  sleep 2
  b=$(printf 'stats\r\nquit\r\n' | timeout 3 nc 127.0.0.1 11411 2>/dev/null | tr -d '\r' | awk '/^STAT cmd_get /{print $3}')
  echo $(( (${b:-0} - ${a:-0}) / 2 ))
}

i=0
for B in $BINS; do
  i=$((i+1)); TAGN="r$i-$B"
  tmux kill-session -t ob 2>/dev/null
  for p in $(pgrep -x "memcached[.a-z0-9]*"); do kill -9 "$p" 2>/dev/null; done
  sleep 1
  tmux new-session -d -s ob "cd $HOME/kvs-port && exec taskset -c 0-$((MC-1)) env \
LD_LIBRARY_PATH=$HOME/covlib:$HOME/kvs-port MLX5_COHERENT_QP=1 MLX5_COHERENT_CQ=1 \
EXT_RDMA_PROF=1 EXT_CRYPTO_KEY=$HOME/kvs-port/ext.key EXT_SLOT_SIZE=256 \
EXT_READ_SLOTS=64 $HOME/kvs-port-v3/memcached.$B -p 11411 -U 0 -t $MC -m 2048 \
-c 16384 -R 1024 -o ext_path=10.99.0.2:11212:4g,ext_worker_window=$W,ext_qp_per_worker=$NQP,ext_drain_spin=$SPIN,hashpower=$HP \
> /tmp/ob_server.log 2>&1"
  up=0
  for _ in $(seq 1 30); do
    sleep 2
    if pgrep -x "memcached.$B" >/dev/null; then up=1; break; fi
  done
  [ $up -eq 1 ] || { echo "START_FAIL $TAGN: $(head -2 /tmp/ob_server.log)"; exit 1; }
  MT="$HOME/memtier/memtier_benchmark -s 127.0.0.1 -p 11411 -P memcache_text \
-d 64 --key-prefix=m- --key-minimum=1 --key-maximum=1000000 --hide-histogram"
  LD_LIBRARY_PATH=$HOME/memtier:$HOME/kvs-port taskset -c 0-$((MC-1)) $MT \
    --threads=8 --clients=16 --pipeline=8 --key-pattern=P:P --ratio=1:0 -n 7813 \
    >/tmp/ob_preload.log 2>&1
  n=$(printf 'stats\r\nquit\r\n' | timeout 5 nc 127.0.0.1 11411 | tr -d '\r' | awk '/^STAT curr_items /{print $3}')
  echo "$(date -u +%s) READY $TAGN curr_items=$n" | tee -a $MARKS
  tmux kill-session -t obsample 2>/dev/null
  tmux new-session -d -s obsample "LOG=/tmp/ob_samples.tsv /tmp/obsample.sh"
  for _ in $(seq 1 300); do [ "$(rate)" -gt 200000 ] && break; done
  echo "$(date -u +%s) LOAD_START $TAGN" | tee -a $MARKS
  idle=0
  for _ in $(seq 1 300); do
    if [ "$(rate)" -lt 100000 ]; then idle=$((idle+1)); else idle=0; fi
    [ $idle -ge 3 ] && break
  done
  echo "$(date -u +%s) LOAD_END $TAGN" | tee -a $MARKS
done
echo "alternation 완료"
