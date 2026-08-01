#!/bin/bash
# 캠페인 내내 1초마다 서버 상태를 CSV로 남기는 연속 추적기. guest에서 실행.
#
#   OUT=/tmp/shape/trace.csv setsid bash shape-trace.sh &
#
# 실시간 판단을 하지 않는다 — 창 잡기·부하 감지·리셋을 전부 빼고 누적값만
# 적는다. 창은 사후에 잘라내며, prof 평균은 누적이므로 `(avg×count)` 차분으로
# 창 국소값을 정확히 복원한다(설계 문서 §F-4와 같은 방법).
#
# 실시간 감지 방식은 무인 운용에서 세 번 깨졌다: 인스턴스가 겹쳐 같은 로그에
# 섞이고, 감지 시점이 부하와 어긋나고, 셀 경계에서 샘플러 수명이 꼬였다.
# 이 방식에는 그런 상태가 없다.
set -u
OUT=${OUT:-/tmp/shape/trace.csv}
PORT=${PORT:-11411}; HOST=${HOST:-127.0.0.1}
mkdir -p "$(dirname "$OUT")"
# pgrep -f 는 이 스크립트 경로를 담은 ssh 명령 자신까지 매칭한다. 그걸로
# kill 하면 자기 셸을 죽인다(실제로 세 번 겪었다). pidfile 로만 다룬다.
PIDF=${PIDF:-/tmp/shape/trace.pid}
echo $$ > "$PIDF"
trap 'rm -f "$PIDF"' EXIT

# v3 열은 뒤에 붙인다 — 기존 슬라이서가 위치로 읽으므로 앞을 건드리면 깨진다.
# admit/ret 은 avg 만 있고 count 가 없다. 같은 op 가 e2e 도 함께 기록하므로
# 창 국소값 복원에는 e2e count 를 그대로 쓴다.
[ -s "$OUT" ] || echo "ts,cmd_get,cmd_set,get_hits,get_misses,rcount,ravg,rp99,wcount,wavg,wp99,badcrc,err5,cpu_total,cpu_idle,re2ec,re2ea,re2ep99,we2ec,we2ea,we2ep99,radmit,wadmit,wret" > "$OUT"

while true; do
  S=$(printf 'stats\r\nquit\r\n' | timeout 3 nc "$HOST" "$PORT" 2>/dev/null | tr -d '\r')
  if [ -n "$S" ]; then
    read -r _ ca cb cc cd ce cf cg ch _ < /proc/stat
    echo "$S" | awk -v ts="$(date -u +%s.%N)" \
        -v ct=$((ca+cb+cc+cd+ce+cf+cg+ch)) -v ci="$cd" '
      $1=="STAT"{v[$2]=$3}
      END{ printf "%s,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d\n", ts,
        v["cmd_get"], v["cmd_set"], v["get_hits"], v["get_misses"],
        v["extstore_prof_read_count"], v["extstore_prof_read_avg_ns"], v["extstore_prof_read_p99_ns"],
        v["extstore_prof_write_count"], v["extstore_prof_write_avg_ns"], v["extstore_prof_write_p99_ns"],
        v["badcrc_from_extstore"],
        v["get_misses"]+v["extstore_read_failures"]+v["extstore_write_failures"]+ \
          v["extstore_engine_dead"]+v["ext_slot_acct_leak"],
        ct, ci,
        v["extstore_prof_read_e2e_count"], v["extstore_prof_read_e2e_avg_ns"], v["extstore_prof_read_e2e_p99_ns"],
        v["extstore_prof_write_e2e_count"], v["extstore_prof_write_e2e_avg_ns"], v["extstore_prof_write_e2e_p99_ns"],
        v["extstore_prof_read_admit_avg_ns"], v["extstore_prof_write_admit_avg_ns"],
        v["extstore_prof_write_ret_avg_ns"] }' >> "$OUT"
  fi
  sleep 1
done
