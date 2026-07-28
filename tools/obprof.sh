#!/bin/bash
# 부하가 감지되면 memcached worker들을 bpftrace로 프로파일한다.
# 사용: TAG=mc28 DUR=15 bash tools/obprof.sh   (부하 시작 대기 후 자동 실행)
set -u
TAG=${TAG:?}; DUR=${DUR:-15}
OUT=/tmp/bt-$TAG.txt

rate() {
  local a b
  a=$(printf 'stats\r\nquit\r\n' | timeout 3 nc 127.0.0.1 11411 2>/dev/null | tr -d '\r' | awk '/^STAT cmd_get /{print $3}')
  sleep 2
  b=$(printf 'stats\r\nquit\r\n' | timeout 3 nc 127.0.0.1 11411 2>/dev/null | tr -d '\r' | awk '/^STAT cmd_get /{print $3}')
  echo $(( (${b:-0} - ${a:-0}) / 2 ))
}

PID=$(pgrep -x memcached | head -1) || exit 1
echo "부하 대기중 (pid=$PID)..."
for _ in $(seq 1 200); do
  [ "$(rate)" -gt 200000 ] && break
done
echo "$(date -u +%s) 프로파일 시작 ($DUR s)"

# 유저스택 샘플링. 커널 심볼은 이 커널에서 못 풀므로 유저 프레임에 집중.
sudo timeout $((DUR+10)) bpftrace -p "$PID" -e "
profile:hz:499 /pid == $PID/ { @u[ustack(8)] = count(); }
interval:s:$DUR { exit(); }
" > "$OUT" 2>/tmp/bt-$TAG.err
echo "저장: $OUT ($(wc -l < "$OUT") 행)"
