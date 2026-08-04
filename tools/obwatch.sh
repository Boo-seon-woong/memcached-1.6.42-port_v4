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
printf '%6s %10s %10s %7s %8s %8s %8s %8s %8s %8s %8s %6s %5s\n' \
  t get/s set/s hit% Gv3_avg Gv3_p50 Gv3_p99 Sv3_avg Sv3_p50 Sv3_p99 wait/s busyCPU err
printf '%6s %10s %10s %7s %8s %8s %8s %8s %8s %8s %8s %6s %5s\n' \
  ------ ---------- ---------- ------- -------- -------- -------- -------- -------- -------- -------- ------ -----
# span v3 = backend 진입 → 응용 가시 완료. 계약 판정 대상이며 이제 이것만 낸다.
# v2(post→복호)는 2026-08-04 에 뺐다 — 두 정의가 섞여 인용되는 사고가 반복됐다.

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
  R3=$(f "$S" extstore_prof_read_e2e_avg_ns)
  R5=$(f "$S" extstore_prof_read_e2e_p50_ns);  R9=$(f "$S" extstore_prof_read_e2e_p99_ns)
  W3=$(f "$S" extstore_prof_write_e2e_avg_ns)
  W5=$(f "$S" extstore_prof_write_e2e_p50_ns); W9=$(f "$S" extstore_prof_write_e2e_p99_ns)
  WE=$(f "$S" ext_worker_wait_enq)
  ERR=$(echo "$S" | awk '$1=="STAT" && ($2=="get_misses"||$2=="badcrc_from_extstore"||$2=="extstore_read_failures"||$2=="extstore_write_failures"||$2=="extstore_engine_dead"||$2=="ext_slot_acct_leak"){s+=$3}END{print s+0}')
  read -r _ ca cb cc cd ce cf cg ch _ < /proc/stat
  CT=$((ca+cb+cc+cd+ce+cf+cg+ch)); CI=$cd
  BUSY=$(awk -v dt=$((CT-PCT)) -v di=$((CI-PCI)) -v n="$NCPU" 'BEGIN{printf "%.1f", (dt>0)?(dt-di)/dt*n:0}')
  PCT=$CT; PCI=$CI
  DT=$(awk -v a="$NOW" -v b="$PT" 'BEGIN{d=a-b; if(d<0.001)d=0.001; printf "%.6f", d}')
  awk -v el="$EL" -v g=$(( ${G:-0} - PG )) -v se=$(( ${SE:-0} - PS )) -v dt="$DT" \
      -v hit="${H:-0}" -v tg="${G:-0}" \
      -v ga="${R3:-0}" -v g5="${R5:-0}" -v g9="${R9:-0}" \
      -v sa="${W3:-0}" -v s5="${W5:-0}" -v s9="${W9:-0}" \
      -v we=$(( ${WE:-0} - PW )) -v err="${ERR:-0}" -v busy="$BUSY" 'BEGIN{
    printf "%5ds %9.3fM %9.3fM %6.2f%% %6.2fus %6.2fus %6.2fus %6.2fus %6.2fus %6.2fus %7.1fM %6s %5d\n",
      el, g/dt/1e6, se/dt/1e6, (tg>0)?hit/tg*100:0,
      ga/1000, g5/1000, g9/1000, sa/1000, s5/1000, s9/1000, we/dt/1e6, busy, err }'
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
  r3=v["extstore_prof_read_e2e_avg_ns"]+0; w3=v["extstore_prof_write_e2e_avg_ns"]+0
  r3c=v["extstore_prof_read_e2e_count"]+0; w3c=v["extstore_prof_write_e2e_count"]+0
  r5=v["extstore_prof_read_e2e_p50_ns"]+0;  r9=v["extstore_prof_read_e2e_p99_ns"]+0
  w5=v["extstore_prof_write_e2e_p50_ns"]+0; w9=v["extstore_prof_write_e2e_p99_ns"]+0
  rc=v["extstore_prof_read_count"]+0;  wc=v["extstore_prof_write_count"]+0
  printf "===== SERVER STATS (%.1fs window) =====\n", t
  # p99 == UINT64_MAX 는 히스토그램 최상단 버킷 포화다(실제 값이 3.2768ms 밖).
  # 그 자리에 숫자를 적으면 측정값으로 읽히므로 CLIP 으로 낸다.
  printf "%-10s %13s %13s %12s %12s %12s\n","Type","Ops/sec","Hits/sec","v3 avg","v3 p50","v3 p99"
  printf "%s\n","------------------------------------------------------------------------------------"
  wc9=(w9>=1e18)?"      CLIP":sprintf("%10.3fus",w9/1000)
  rc9=(r9>=1e18)?"      CLIP":sprintf("%10.3fus",r9/1000)
  if (s>0) printf "%-10s %13.2f %13s %10.3fus %10.3fus %12s\n","Sets",s/t,"---",w3/1000,w5/1000,wc9
  if (g>0) printf "%-10s %13.2f %13.2f %10.3fus %10.3fus %12s\n","Gets",g/t,h/t,r3/1000,r5/1000,rc9
  printf "%-10s %13.2f %13.2f\n","Totals",(g+s)/t,h/t
  printf "\n  span v3 = backend 진입→응용 가시 완료 (계약 판정 대상)\n"

  # v4 지연 분해 전체 트리. srv = 소켓 read→sendmsg.
  # srv = que + pre + bk,  bk = span_v3 + post
  sv=v["extstore_prof_srv_avg_ns"]+0; s5v=v["extstore_prof_srv_p50_ns"]+0; s9v=v["extstore_prof_srv_p99_ns"]+0
  qv=v["extstore_prof_que_avg_ns"]+0; q5v=v["extstore_prof_que_p50_ns"]+0; q9v=v["extstore_prof_que_p99_ns"]+0
  bv=v["extstore_prof_bk_avg_ns"]+0;  b5v=v["extstore_prof_bk_p50_ns"]+0;  b9v=v["extstore_prof_bk_p99_ns"]+0
  if (sv>0) {
    printf "\n--- latency breakdown (avg / p50 / p99, us) ---\n"
    printf "%-30s %8s %8s %8s\n","구간","avg","p50","p99"
    printf "%s\n","---------------------------------------------------------------"
    sc9=(s9v>=1e18)?"    CLIP":sprintf("%8.2f",s9v/1000)
    qc9=(q9v>=1e18)?"    CLIP":sprintf("%8.2f",q9v/1000)
    bc9=(b9v>=1e18)?"    CLIP":sprintf("%8.2f",b9v/1000)
    printf "%-30s %8.2f %8.2f %8s\n","srv  소켓read→sendmsg", sv/1000, s5v/1000, sc9
    printf "%-30s %8.2f %8.2f %8s\n","├ que  read→명령시작", qv/1000, q5v/1000, qc9
    printf "%-30s %8.2f %8s %8s\n","├ pre  명령→backend진입", (sv-qv-bv)/1000, "-", "-"
    printf "%-30s %8.2f %8.2f %8s\n","└ bk   backend진입→send", bv/1000, b5v/1000, bc9
    if (g>0) {
      ad=v["extstore_prof_read_admit_avg_ns"]+0; xf=v["extstore_prof_read_xfer_avg_ns"]+0
      cr=v["extstore_prof_read_crypto_avg_ns"]+0; sy=v["extstore_prof_read_sync_avg_ns"]+0
      printf "%-30s %8.2f %8.2f %8s\n","  ├ span v3 GET [계약]", r3/1000, r5/1000, rc9
      printf "%-30s %8.2f %8s %8s\n","  │   ├ admit 진입→post", ad/1000, "-", "-"
      printf "%-30s %8.2f %8s %8s\n","  │   ├ xfer  RDMA 왕복", xf/1000, "-", "-"
      printf "%-30s %8.2f %8s %8s\n","  │   ├ crypto AES-GCM", cr/1000, "-", "-"
      printf "%-30s %8.2f %8s %8s\n","  │   ├ sync  DMA advise", sy/1000, "-", "-"
      printf "%-30s %8.2f %8s %8s\n","  │   └ 나머지", (r3-ad-xf-cr-sy)/1000, "-", "-"
      printf "%-30s %8.2f %8s %8s\n","  └ post v3완료→send", (bv-r3)/1000, "-", "-"
    }
    if (s>0) {
      ad=v["extstore_prof_write_admit_avg_ns"]+0; xf=v["extstore_prof_write_xfer_avg_ns"]+0
      cr=v["extstore_prof_write_crypto_avg_ns"]+0; sy=v["extstore_prof_write_sync_avg_ns"]+0
      rt=v["extstore_prof_write_ret_avg_ns"]+0
      printf "%-30s %8.2f %8.2f %8s\n","  ├ span v3 SET [계약]", w3/1000, w5/1000, wc9
      printf "%-30s %8.2f %8s %8s\n","  │   ├ admit 진입→seal", ad/1000, "-", "-"
      printf "%-30s %8.2f %8s %8s\n","  │   ├ xfer  RDMA 왕복", xf/1000, "-", "-"
      printf "%-30s %8.2f %8s %8s\n","  │   ├ crypto AES-GCM", cr/1000, "-", "-"
      printf "%-30s %8.2f %8s %8s\n","  │   ├ sync  DMA advise", sy/1000, "-", "-"
      printf "%-30s %8.2f %8s %8s\n","  │   └ ret   CQE→가시", rt/1000, "-", "-"
    }
    printf "\n  e2e(memtier) - srv = 네트워크 + 클라이언트 큐잉 (pipeline 스윕으로 분리)\n"
    printf "  pre 는 차분(srv-que-bk)이라 백분위가 없다. post 도 bk-span 차분이다.\n"
  }

  gp=(g>0)?(r3/1000<30):1; sp=(s>0)?(w3/1000<30):1
  printf "\n%-28s %s\n","gate span v3 avg < 30us", \
    (g==0 && s==0)?"n/a":( (gp&&sp)?sprintf("PASS  (GET %.2fus / SET %.2fus)", r3/1000, w3/1000) \
                                   :sprintf("*** FAIL (GET %.2fus / SET %.2fus) ***", r3/1000, w3/1000) )
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
    ok=(d>=-1.0&&d<0.2)
    printf "read span 표본 커버리지 : %+.4f%%  %s\n", d, ok?"OK":"*** 확인 필요 ***"
    printf "   (양수=리셋 경계 누락, 음수=재시도로 표본 증가 — 혼합 워크로드에서 정상)\n"
    if (!ok) {
      printf "\n*** 이 창의 Ops/sec 총계를 쓰지 말 것 ***\n"
      printf "    커버리지가 밴드 밖이면 총계가 그 크기만큼 부풀어 있다. 실측 확인:\n"
      printf "    BD-PROF-ON-MIX-r1 총계 11.865M / 커버리지 +8.45%% / 안정구간 행 10.961M\n"
      printf "    (클라이언트 10.926M 과 맞은 쪽은 행이다)\n"
      printf "    → 위 초당 행에서 10s 이후 구간의 평균을 채택하라.\n"
    } }
  if (s>0) { d=(s-wc)/s*100
    printf "write span 표본 커버리지: %.4f%% 누락  %s\n", d, (d>=-0.05&&d<0.2)?"OK":"*** 확인 필요 ***" }
}'
