#!/bin/bash
# 서버 측 실시간 관측 + 최종 요약. guest에서 실행.
#
#   DUR=300 bash tools/obwatch.sh          # 300초 창을 열고 1초마다 실시간 출력
#   DUR=60 INT=5 bash tools/obwatch.sh     # 5초 간격 출력
#
# 시작 시 'stats reset'으로 창을 열고, DUR 초 뒤 최종 요약을 찍는다.
# 비용: 초당 stats 1회 — 10M ops/s 대비 1e-7 수준이라 성능 영향 없음
# (모든 기록 런에서 동일한 1초 샘플러가 함께 돌았다).
set -u
DUR=${DUR:-300}; INT=${INT:-1}; PORT=${PORT:-11411}; HOST=${HOST:-127.0.0.1}

st() { printf 'stats\r\nquit\r\n' | timeout 3 nc "$HOST" "$PORT" 2>/dev/null | tr -d '\r'; }
f()  { echo "$1" | awk -v k="$2" '$1=="STAT" && $2==k {print $3; exit}'; }

command -v nc >/dev/null || { echo "nc 필요"; exit 1; }
[ -n "$(st)" ] || { echo "memcached ($HOST:$PORT) 응답 없음"; exit 1; }

printf 'stats reset\r\nquit\r\n' | timeout 3 nc "$HOST" "$PORT" >/dev/null
T0=$(date -u +%s)
echo "extstore watch — window ${DUR}s, opened $(date -u +%H:%M:%SZ)"
echo
printf '%6s %11s %11s %8s %10s %10s %10s %9s %5s\n' \
  t get/s set/s hit% span_avg span_p50 span_p99 wait_enq/s err
printf '%6s %11s %11s %8s %10s %10s %10s %9s %5s\n' \
  ------ ----------- ----------- -------- ---------- ---------- ---------- --------- -----

# 기준선 선점: ext_worker_wait_enq 등 일부 카운터는 stats reset 대상이 아니라
# 누적값이므로, 초기화하지 않으면 첫 행의 델타가 전체 누적치로 튄다.
B=$(st)
PG=$(f "$B" cmd_get); PS=$(f "$B" cmd_set); PW=$(f "$B" ext_worker_wait_enq)
PG=${PG:-0}; PS=${PS:-0}; PW=${PW:-0}; PT=$(date -u +%s)
while :; do
  sleep "$INT"
  NOW=$(date -u +%s); EL=$((NOW-T0))
  S=$(st); [ -n "$S" ] || continue
  G=$(f "$S" cmd_get); SE=$(f "$S" cmd_set); H=$(f "$S" get_hits)
  RA=$(f "$S" extstore_prof_read_avg_ns);  R5=$(f "$S" extstore_prof_read_p50_ns)
  R9=$(f "$S" extstore_prof_read_p99_ns);  WE=$(f "$S" ext_worker_wait_enq)
  ERR=$(echo "$S" | awk '$1=="STAT" && ($2=="get_misses"||$2=="badcrc_from_extstore"||$2=="extstore_read_failures"||$2=="extstore_write_failures"||$2=="extstore_engine_dead"||$2=="ext_slot_acct_leak"){s+=$3}END{print s+0}')
  DT=$((NOW-PT)); [ "$DT" -lt 1 ] && DT=1
  awk -v el="$EL" -v g=$(( ${G:-0} - PG )) -v se=$(( ${SE:-0} - PS )) -v dt="$DT" \
      -v hit="${H:-0}" -v tg="${G:-0}" -v ra="${RA:-0}" -v r5="${R5:-0}" -v r9="${R9:-0}" \
      -v we=$(( ${WE:-0} - PW )) -v err="${ERR:-0}" 'BEGIN{
    printf "%5ds %9.3fM %9.3fM %7.2f %8.2fus %8.2fus %8.1fus %7.1fM %5d\n",
      el, g/dt/1e6, se/dt/1e6, (tg>0)?hit/tg*100:0, ra/1000, r5/1000, r9/1000, we/dt/1e6, err }'
  PG=${G:-0}; PS=${SE:-0}; PW=${WE:-0}; PT=$NOW
  [ "$EL" -ge "$DUR" ] && break
done

T1=$(date -u +%s); S=$(st)
echo
echo "$S" | awk -v t=$((T1-T0)) '
$1=="STAT"{v[$2]=$3}
END{
  g=v["cmd_get"]+0; s=v["cmd_set"]+0; h=v["get_hits"]+0
  ra=v["extstore_prof_read_avg_ns"]+0;  r5=v["extstore_prof_read_p50_ns"]+0
  r9=v["extstore_prof_read_p99_ns"]+0;  rc=v["extstore_prof_read_count"]+0
  wa=v["extstore_prof_write_avg_ns"]+0; w5=v["extstore_prof_write_p50_ns"]+0
  w9=v["extstore_prof_write_p99_ns"]+0; wc=v["extstore_prof_write_count"]+0
  printf "===== SERVER STATS (%ds window) =====\n", t
  printf "%-10s %13s %13s %12s %12s %12s\n","Type","Ops/sec","Hits/sec","Span Avg","Span p50","Span p99"
  printf "%s\n","------------------------------------------------------------------------------------"
  if (s>0) printf "%-10s %13.2f %13s %10.3fus %10.3fus %10.3fus\n","Sets",s/t,"---",wa/1000,w5/1000,w9/1000
  if (g>0) printf "%-10s %13.2f %13.2f %10.3fus %10.3fus %10.3fus\n","Gets",g/t,h/t,ra/1000,r5/1000,r9/1000
  printf "%-10s %13.2f %13.2f\n","Totals",(g+s)/t,h/t
  printf "\n%-28s %s\n","gate span avg < 30us",(g==0)?"n/a (GET 없음)":((ra/1000<30)?sprintf("PASS  (%.2fus, 여유 %.2fus)",ra/1000,30-ra/1000):sprintf("*** FAIL (%.2fus) ***",ra/1000))
  printf "%-28s %.2f %%\n","hit rate",(g>0)?h/g*100:0
  printf "\n--- correctness (전부 0이어야 정상) ---\n"
  printf "get_misses=%d badcrc=%d read_fail=%d write_fail=%d engine_dead=%d leak=%d\n",
    v["get_misses"]+0, v["badcrc_from_extstore"]+0, v["extstore_read_failures"]+0,
    v["extstore_write_failures"]+0, v["extstore_engine_dead"]+0, v["ext_slot_acct_leak"]+0
  if (g>0) { d=(g-rc)/g*100
    printf "read span 표본 커버리지 : %+.4f%%  %s\n", d, (d>=-1.0&&d<0.2)?"OK":"*** 확인 필요 ***"
    printf "   (양수=리셋 경계 누락, 음수=재시도로 표본 증가 — 혼합 워크로드에서 정상)\n" }
  if (s>0) { d=(s-wc)/s*100
    printf "write span 표본 커버리지: %.4f%% 누락  %s\n", d, (d>=-0.05&&d<0.2)?"OK":"*** 확인 필요 ***" }
}'
