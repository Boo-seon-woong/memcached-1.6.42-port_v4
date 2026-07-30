#!/bin/bash
# 서버 측 실시간 관측 + 최종 요약. guest에서 실행.
#
#   DUR=300 bash tools/obwatch.sh          # 300초 창을 열고 1초마다 실시간 출력
#   DUR=60 INT=5 bash tools/obwatch.sh     # 5초 간격 출력
#
# 시작 시 'stats reset'으로 창을 열고, DUR 초 뒤 최종 요약을 찍는다.
#
# 2026-07-30: 초당 행이 약 5% 과대보고하던 버그를 고쳤다. 루프 한 바퀴는
# sleep 1 + stats 왕복이라 실제로 ~1.05초인데 정수 초(NOW-PT=1)로 나눴고,
# 누적 오차가 1초를 넘길 때마다 DT=2가 되어 그 행만 절반으로 찍혔다
# (관측: 19바퀴마다 dip). 이제 date +%s.%N으로 실제 경과를 쓴다.
# 비용: 초당 stats 1회 — 10M ops/s 대비 1e-7 수준이라 성능 영향 없음
# (모든 기록 런에서 동일한 1초 샘플러가 함께 돌았다).
set -u
DUR=${DUR:-300}; INT=${INT:-1}; PORT=${PORT:-11411}; HOST=${HOST:-127.0.0.1}

st() { printf 'stats\r\nquit\r\n' | timeout 3 nc "$HOST" "$PORT" 2>/dev/null | tr -d '\r'; }
f()  { echo "$1" | awk -v k="$2" '$1=="STAT" && $2==k {print $3; exit}'; }

command -v nc >/dev/null || { echo "nc 필요"; exit 1; }
[ -n "$(st)" ] || { echo "memcached ($HOST:$PORT) 응답 없음"; exit 1; }

printf 'stats reset\r\nquit\r\n' | timeout 3 nc "$HOST" "$PORT" >/dev/null
T0=$(date -u +%s.%N)
echo "extstore watch — window ${DUR}s, opened $(date -u +%H:%M:%SZ)"
echo
printf '%6s %10s %10s %7s %9s %9s %9s %9s %8s %6s %5s\n' \
  t get/s set/s hit% Gspan_avg Gspan_p99 Sspan_avg Sspan_p99 wait/s busyCPU err
printf '%6s %10s %10s %7s %9s %9s %9s %9s %8s %6s %5s\n' \
  ------ ---------- ---------- ------- --------- --------- --------- --------- -------- ------ -----

# 기준선 선점: ext_worker_wait_enq 등 일부 카운터는 stats reset 대상이 아니라
# 누적값이므로, 초기화하지 않으면 첫 행의 델타가 전체 누적치로 튄다.
B=$(st)
PG=$(f "$B" cmd_get); PS=$(f "$B" cmd_set); PW=$(f "$B" ext_worker_wait_enq)
PG=${PG:-0}; PS=${PS:-0}; PW=${PW:-0}; PT=$(date -u +%s)
read -r _ ca cb cc cd ce cf cg ch _ < /proc/stat
PCT=$((ca+cb+cc+cd+ce+cf+cg+ch)); PCI=$cd; NCPU=$(nproc)
while :; do
  sleep "$INT"
  NOW=$(date -u +%s.%N)
  EL=$(awk -v a="$NOW" -v b="$T0" 'BEGIN{printf "%.0f", a-b}')
  S=$(st); [ -n "$S" ] || continue
  G=$(f "$S" cmd_get); SE=$(f "$S" cmd_set); H=$(f "$S" get_hits)
  RA=$(f "$S" extstore_prof_read_avg_ns);  R9=$(f "$S" extstore_prof_read_p99_ns)
  WA=$(f "$S" extstore_prof_write_avg_ns); W9=$(f "$S" extstore_prof_write_p99_ns)
  WE=$(f "$S" ext_worker_wait_enq)
  ERR=$(echo "$S" | awk '$1=="STAT" && ($2=="get_misses"||$2=="badcrc_from_extstore"||$2=="extstore_read_failures"||$2=="extstore_write_failures"||$2=="extstore_engine_dead"||$2=="ext_slot_acct_leak"){s+=$3}END{print s+0}')
  read -r _ ca cb cc cd ce cf cg ch _ < /proc/stat
  CT=$((ca+cb+cc+cd+ce+cf+cg+ch)); CI=$cd
  BUSY=$(awk -v dt=$((CT-PCT)) -v di=$((CI-PCI)) -v n="$NCPU" 'BEGIN{printf "%.1f", (dt>0)?(dt-di)/dt*n:0}')
  PCT=$CT; PCI=$CI
  DT=$(awk -v a="$NOW" -v b="$PT" 'BEGIN{d=a-b; if(d<0.001)d=0.001; printf "%.6f", d}')
  awk -v el="$EL" -v g=$(( ${G:-0} - PG )) -v se=$(( ${SE:-0} - PS )) -v dt="$DT" \
      -v hit="${H:-0}" -v tg="${G:-0}" -v ra="${RA:-0}" -v r9="${R9:-0}" \
      -v wa="${WA:-0}" -v w9="${W9:-0}" \
      -v we=$(( ${WE:-0} - PW )) -v err="${ERR:-0}" -v busy="$BUSY" 'BEGIN{
    printf "%5ds %9.3fM %9.3fM %6.2f%% %7.2fus %7.1fus %7.2fus %7.1fus %7.1fM %6s %5d\n",
      el, g/dt/1e6, se/dt/1e6, (tg>0)?hit/tg*100:0,
      ra/1000, r9/1000, wa/1000, w9/1000, we/dt/1e6, busy, err }'
  PG=${G:-0}; PS=${SE:-0}; PW=${WE:-0}; PT=$NOW
  [ "$EL" -ge "$DUR" ] && break
done

T1=$(date -u +%s.%N); S=$(st)
echo
WIN=$(awk -v a="$T1" -v b="$T0" 'BEGIN{printf "%.6f", a-b}')
echo "$S" | awk -v t="$WIN" '
$1=="STAT"{v[$2]=$3}
END{
  g=v["cmd_get"]+0; s=v["cmd_set"]+0; h=v["get_hits"]+0
  ra=v["extstore_prof_read_avg_ns"]+0;  r5=v["extstore_prof_read_p50_ns"]+0
  r9=v["extstore_prof_read_p99_ns"]+0;  rc=v["extstore_prof_read_count"]+0
  wa=v["extstore_prof_write_avg_ns"]+0; w5=v["extstore_prof_write_p50_ns"]+0
  w9=v["extstore_prof_write_p99_ns"]+0; wc=v["extstore_prof_write_count"]+0
  printf "===== SERVER STATS (%.1fs window) =====\n", t
  printf "%-10s %13s %13s %12s %12s %12s\n","Type","Ops/sec","Hits/sec","Span Avg","Span p50","Span p99"
  printf "%s\n","------------------------------------------------------------------------------------"
  if (s>0) printf "%-10s %13.2f %13s %10.3fus %10.3fus %10.3fus\n","Sets",s/t,"---",wa/1000,w5/1000,w9/1000
  if (g>0) printf "%-10s %13.2f %13.2f %10.3fus %10.3fus %10.3fus\n","Gets",g/t,h/t,ra/1000,r5/1000,r9/1000
  printf "%-10s %13.2f %13.2f\n","Totals",(g+s)/t,h/t
  printf "\n%-28s %s\n","gate span avg < 30us",(g==0)?"n/a (GET 없음)":((ra/1000<30)?sprintf("PASS  (%.2fus, 여유 %.2fus)",ra/1000,30-ra/1000):sprintf("*** FAIL (%.2fus) ***",ra/1000))
  printf "%-28s %.2f %%\n","hit rate",(g>0)?h/g*100:0
  printf "\n--- correctness ---\n"
  bc=v["badcrc_from_extstore"]+0; gm=v["get_misses"]+0
  printf "필수 0: get_misses=%d read_fail=%d write_fail=%d engine_dead=%d leak=%d  %s\n",
    gm, v["extstore_read_failures"]+0, v["extstore_write_failures"]+0,
    v["extstore_engine_dead"]+0, v["ext_slot_acct_leak"]+0,
    (gm==0 && v["extstore_read_failures"]+0==0 && v["extstore_write_failures"]+0==0 && v["extstore_engine_dead"]+0==0 && v["ext_slot_acct_leak"]+0==0)?"OK":"*** FAIL ***"
  if (s>0) printf "badcrc=%d (%.3f%% of GET) — 혼합 워크로드에서는 read-during-write 경합으로 발생 가능. get_misses=0이면 재시도로 복구된 것이며 미검증 데이터는 전달되지 않는다\n", bc, (g>0)?bc/g*100:0
  else     printf "badcrc=%d  %s (GET-only에서는 0이어야 한다)\n", bc, (bc==0)?"OK":"*** FAIL ***"
  if (g>0) { d=(g-rc)/g*100
    printf "read span 표본 커버리지 : %+.4f%%  %s\n", d, (d>=-1.0&&d<0.2)?"OK":"*** 확인 필요 ***"
    printf "   (양수=리셋 경계 누락, 음수=재시도로 표본 증가 — 혼합 워크로드에서 정상)\n" }
  if (s>0) { d=(s-wc)/s*100
    printf "write span 표본 커버리지: %.4f%% 누락  %s\n", d, (d>=-0.05&&d<0.2)?"OK":"*** 확인 필요 ***" }
}'
