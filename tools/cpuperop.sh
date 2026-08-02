#!/bin/bash
# memcached 자신의 CPU 시간만으로 op 당 CPU 를 잰다. guest 에서 실행.
#
#   bash cpuperop.sh <초>
#
# co-located 자체실험에서 /proc/stat 을 쓰면 memtier 가 섞인다. 서버 프로세스의
# utime+stime 만 차분하면 그 오염이 없다 — 절대값이 off-box 와 다를 뿐 두 arm 을
# 같은 방식으로 재는 한 비교는 성립한다.
set -eu
SEC=${1:-20}
PORT=${PORT:-11411}
pid=$(pgrep -x "memcached" | head -1)
[ -n "$pid" ] || { echo "서버가 없다" >&2; exit 1; }
HZ=$(getconf CLK_TCK)

read_cpu() { awk '{print $14+$15}' /proc/$pid/stat; }
read_ops() {
  printf 'stats\r\nquit\r\n' | timeout 3 nc 127.0.0.1 "$PORT" | tr -d '\r' |
    awk '$1=="STAT" && ($2=="cmd_get"||$2=="cmd_set"){s+=$3} END{print s+0}'
}

c0=$(read_cpu); o0=$(read_ops); t0=$(date +%s.%N)
sleep "$SEC"
c1=$(read_cpu); o1=$(read_ops); t1=$(date +%s.%N)

awk -v c0="$c0" -v c1="$c1" -v o0="$o0" -v o1="$o1" -v t0="$t0" -v t1="$t1" -v hz="$HZ" '
BEGIN {
  cpu = (c1-c0)/hz; ops = o1-o0; dt = t1-t0;
  if (ops <= 0) { print "부하 없음"; exit 1 }
  printf "%.3f M ops/s   서버 CPU %.2f 코어   %.3f µs/op\n", ops/dt/1e6, cpu/dt, cpu/ops*1e6;
}'
