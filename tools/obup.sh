#!/bin/bash
# off-box 런 하네스: guest에서 실행.
#
# in-guest memtier 없이 memcached만 띄우고, keyspace를 로컬에서 프리로드한 뒤,
# genie가 10.99.0.3:11411로 부하를 모는 동안 서버 측을 1초 간격으로 계속
# 샘플링한다. 샘플은 누적 카운터라 어느 구간이든 사후에 델타로 잘라낼 수 있다.
#
# 사용: MC=28 W=28 NQP=4 bash tools/obup.sh
set -u
MC=${MC:-28}; W=${W:-28}; NQP=${NQP:-4}; SPIN=${SPIN:-1024}; RS=${RS:-64}
SCPU=${SCPU:-0-$((MC-1))}
BIN=${BIN:-$HOME/kvs-port-v3/memcached}
LOG=${LOG:-/tmp/ob_samples.tsv}

tmux kill-session -t ob 2>/dev/null
tmux kill-session -t obsample 2>/dev/null
for p in $(pgrep -x "memcached[.a-z0-9]*"); do kill -9 "$p" 2>/dev/null; done
sleep 1

OPT="ext_path=10.99.0.2:11212:4g,ext_worker_window=$W,ext_qp_per_worker=$NQP,ext_drain_spin=$SPIN"
CMD="cd $HOME/kvs-port && exec taskset -c $SCPU env \
LD_LIBRARY_PATH=$HOME/covlib:$HOME/kvs-port MLX5_COHERENT_QP=1 MLX5_COHERENT_CQ=1 \
EXT_RDMA_PROF=1 EXT_CRYPTO_KEY=$HOME/kvs-port/ext.key EXT_SLOT_SIZE=256 \
EXT_READ_SLOTS=$RS $BIN -p 11411 -U 0 -t $MC -m 2048 -c 16384 -R 1024 -o $OPT"
tmux new-session -d -s ob "$CMD > /tmp/ob_server.log 2>&1"
sleep 4
pgrep -x "memcached[.a-z0-9]*" >/dev/null || { echo "START_FAIL: $(grep -iE 'illegal|failed|REJECT' /tmp/ob_server.log | head -1)"; exit 1; }

# keyspace 프리로드: 로컬 loopback으로 1M SET. 측정 구간이 아니라 셋업이다.
# 각 SET은 genie MR로 RDMA WRITE되므로 이후 어디서 GET하든 hit한다.
MT="$HOME/memtier/memtier_benchmark -s 127.0.0.1 -p 11411 -P memcache_text \
-d 64 --key-prefix=m- --key-minimum=1 --key-maximum=1000000 --hide-histogram"
LD_LIBRARY_PATH=$HOME/memtier:$HOME/kvs-port taskset -c "$SCPU" $MT \
  --threads=8 --clients=16 --pipeline=8 --key-pattern=P:P --ratio=1:0 -n 7813 \
  >/tmp/ob_preload.log 2>&1
PRE=$(printf 'stats\r\nquit\r\n' | timeout 5 nc 127.0.0.1 11411 | tr -d '\r' | awk '/^STAT curr_items /{print $3}')
echo "preloaded curr_items=$PRE  (1000000 이어야 함)"

# 연속 샘플러. 누적 카운터를 그대로 적는다 — 구간은 사후에 자른다.
cat > /tmp/obsample.sh <<'SAMP'
#!/bin/bash
LOG=${LOG:-/tmp/ob_samples.tsv}
PID=$(pgrep -x "memcached[.a-z0-9]*" | head -1)
HZ=$(getconf CLK_TCK)
# 재시작해도 이어 붙인다 — truncate하면 앞 구간이 날아간다.
[ -s "$LOG" ] || printf 'ts\tbusy_cpu\tmc_cpu_s\tcmd_get\tget_hits\tread_cnt\tread_avg_ns\tread_p99_ns\twait_enq\n' > "$LOG"
PT=0; PI=0
while kill -0 "$PID" 2>/dev/null; do
  read -r _ a b c d e f g h _ < /proc/stat
  T=$((a+b+c+d+e+f+g+h)); I=$d
  BUSY=0
  [ $PT -ne 0 ] && BUSY=$(awk -v dt=$((T-PT)) -v di=$((I-PI)) -v n="$(nproc)" 'BEGIN{printf "%.2f", (dt>0)?(dt-di)/dt*n:0}')
  PT=$T; PI=$I
  MC=$(awk -v hz="$HZ" '{printf "%.2f", ($14+$15)/hz}' "/proc/$PID/stat" 2>/dev/null)
  S=$(printf 'stats\r\nquit\r\n' | timeout 2 nc 127.0.0.1 11411 2>/dev/null | tr -d '\r')
  G=$(echo "$S" | awk '/^STAT cmd_get /{print $3}')
  HIT=$(echo "$S" | awk '/^STAT get_hits /{print $3}')
  RC=$(echo "$S" | awk '/read_count /{print $3}')
  RA=$(echo "$S" | awk '/read_avg_ns /{print $3}')
  RP=$(echo "$S" | awk '/read_p99_ns /{print $3}')
  WE=$(echo "$S" | awk '/ext_worker_wait_enq /{print $3}')
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$(date -u +%s)" "$BUSY" "$MC" "${G:-0}" "${HIT:-0}" "${RC:-0}" "${RA:-0}" "${RP:-0}" "${WE:-0}" >> "$LOG"
  sleep 1
done
SAMP
chmod +x /tmp/obsample.sh
tmux new-session -d -s obsample "LOG=$LOG /tmp/obsample.sh"
sleep 3
echo "server up: mcT=$MC cores=$SCPU W=$W nqp=$NQP spin=$SPIN"
echo "sampling -> $LOG  (1s 간격, 누적 카운터)"
date -u +"ready at %Y-%m-%dT%H:%M:%SZ"
