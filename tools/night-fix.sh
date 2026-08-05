#!/usr/bin/env bash
# 야간 잔여 둘: 블록 8(stock) 재발행 + 블록 9(v3 지연 분해).
#
# 블록 8 은 MATCH="ST" 가 너무 헐거워 genie 의 무관한 커밋("...SET...")에
# 걸려 대기가 조기 종료됐다 — 셀은 안 돌았다. MATCH 를 셀 이름으로 좁힌다.
# 블록 9 는 v3 기준선이 v4 서브옵션을 모른다("Illegal suboption
# ext_submit_batch") — v3 전용 기동 줄을 따로 쓴다.
set -u
ROOT=${ROOT:-/home/seonung/2026/memcached-1.6.42-port_v4}; cd "$ROOT"
S=/tmp/night-msgs; mkdir -p $S
G="ssh -n -i $HOME/.ssh/snp_guest -p 2222 -o BatchMode=yes -o ConnectTimeout=8 ubuntu@localhost"
say(){ echo "### $* $(date -u +%H:%M:%S)"; }

while pgrep -f '/tmp/n[tz].sh' >/dev/null; do sleep 60; done
say "잔여 둘 시작"

# ── 블록 8: stock
$G 'tmux kill-session -t mc 2>/dev/null; for p in $(pgrep -x "memcached[.a-z]*"); do kill -9 $p; done
    pkill -f "^/tmp/mc_" 2>/dev/null; sleep 3
    for i in $(seq 1 30); do ss -ltn | grep -q ":11411 " || break; sleep 1; done
    cp -f /tmp/mc-stock /tmp/mc_stock_run && chmod +x /tmp/mc_stock_run
    tmux new-session -d -s mc "LD_LIBRARY_PATH=$HOME/memtier taskset -c 0-29 /tmp/mc_stock_run -p 11411 -U 0 -t 30 -m 1024 -c 16384 -R 1024 > /tmp/mc.log 2>&1"
    sleep 5
    printf "stats settings\r\nquit\r\n" | nc -q1 127.0.0.1 11411 | tr -d "\r" | grep -c ext_submit_inline' > /tmp/stock-arm.txt 2>&1
if [ "$(tail -1 /tmp/stock-arm.txt)" = "0" ]; then
  $G 'LD_LIBRARY_PATH=$HOME/memtier taskset -c 0-29 $HOME/memtier/memtier_benchmark \
      -s 127.0.0.1 -p 11411 -P memcache_text -d 64 --key-prefix=m- --key-minimum=1 \
      --key-maximum=1000000 --threads=8 --clients=16 --pipeline=8 --key-pattern=P:P \
      --ratio=1:0 -n 7813 --hide-histogram >/dev/null 2>&1'
  it=$($G 'printf "stats\r\nquit\r\n"|nc -q1 127.0.0.1 11411|tr -d "\r"|awk "/^STAT curr_items/{print \$3}"')
  SIDE=ST FP="stock memcached 97ceee04, -t 30 -m 1024 -c 16384 -R 1024, taskset 0-29
RDMA 미사용(로컬 메모리). ext_submit_inline 응답 없음 = stock 확인. curr_items $it
(앞서 이 블록의 GO 가 나갔다가 내 응답 매칭이 헐거워 조기 종료됐다 — 셀은 안 돌았다)" \
    bash tools/night-exp1msg.sh > $S/ST.md
  MATCH="ST-C-P" TIMEOUT=3600 tools/night-cell.sh post $S/ST.md "ST" || say "블록8 대기 실패"
else
  say "블록 8 무장 실패"; cat /tmp/stock-arm.txt
fi
bash tools/night-save.sh || true

# ── 블록 9: v3 기준선 + 계층 3. v4 서브옵션을 빼고 띄운다
say "블록 9 (v3) 시작"
$G 'tmux kill-session -t mc 2>/dev/null; for p in $(pgrep -x "memcached[.a-z]*"); do kill -9 $p; done
    pkill -f "^/tmp/mc_" 2>/dev/null; sleep 3
    for i in $(seq 1 30); do ss -ltn | grep -q ":11411 " || break; sleep 1; done
    : > /tmp/mc.log
    tmux new-session -d -s mc "cd \$HOME/kvs-port && exec taskset -c 0-29 env \
LD_LIBRARY_PATH=\$HOME/coherent-mr-v2/lib:\$HOME/kvs-port \
MLX5_COHERENT_QP=1 MLX5_COHERENT_CQ=1 EXT_RDMA_PROF=1 EXT_SELFTEST=1 \
EXT_CRYPTO_KEY=\$HOME/kvs-port/ext.key EXT_SLOT_SIZE=256 EXT_READ_SLOTS=64 \
\$HOME/coherent-mr-v2/bin/memcached.v3l3 -p 11411 -U 0 -t 30 -m 2048 -c 16384 -R 1024 \
-o ext_path=10.99.0.2:11212:4g,ext_worker_window=40,ext_qp_per_worker=4,ext_drain_spin=1024,hashpower=22,ext_pac_set \
> /tmp/mc.log 2>&1"
    sleep 10
    grep -icE "coherent MR [0-9]+B" /tmp/mc.log' > /tmp/v3-arm.txt 2>&1
if [ "$(tail -1 /tmp/v3-arm.txt)" = "2" ]; then
  $G 'LD_LIBRARY_PATH=$HOME/memtier:$HOME/kvs-port taskset -c 0-29 $HOME/memtier/memtier_benchmark \
      -s 127.0.0.1 -p 11411 -P memcache_text -d 64 --key-prefix=m- --key-minimum=1 \
      --key-maximum=1000000 --threads=8 --clients=16 --pipeline=8 --key-pattern=P:P \
      --ratio=1:0 -n 7813 --hide-histogram >/dev/null 2>&1'
  fp=$($G 'printf "stats settings\r\nquit\r\n"|nc -q1 127.0.0.1 11411|tr -d "\r"|grep -E "ext_drain_spin|ext_pac_set|reqs_per_event"|sed "s/^STAT //"|tr "\n" " "; echo
            printf "stats\r\nquit\r\n"|nc -q1 127.0.0.1 11411|tr -d "\r"|grep -E "ext_qp_per_worker|ext_read_slots|curr_items|span_ver"|sed "s/^STAT //"|tr "\n" " "')
  cat > $S/BD3.md <<EOF

---

## [$(TZ=Asia/Seoul date +%Y-%m-%d) KST] ariel — 블록 9: **port_v3 지연 분해** — 블록 5 와 같은 격자

관리자 지시(port_v3 ↔ port_v4 를 같은 세분도로)의 v3 쪽이다. **블록 5 와
셀·창·워크로드가 전부 같아야** 겹쳐 읽힌다.

\`\`\`text
빌드  86da4222ba5825d9d84b19bd
      = v3 측정 기준선 6b150c9 (admit/ret 성분 분해 있음, v4 수정 둘 없음
        — EXP-0 이 잰 그 코드) + 계층 3 계측 이식 + 백분위 결함 수정
      v4 서브옵션(submit_batch/admit_max/inline/reap/chain)은 이 빌드에
      존재하지 않는다 — 그래서 기동 줄이 다르다. W=40 nqp=4 는 v3 운영값
$fp
\`\`\`

### 요청 — 14 부하 × 60초 (블록 5 와 동일)

\`\`\`text
BD3-GET-P{1,8,32,64,128,256,384}    --ratio=0:1
BD3-MIX-P{1,8,32,64,128,256,384}    --ratio=1:9

memtier -s 10.99.0.3 -p 11411 -P memcache_text -d 64 \\
  --key-prefix=m- --key-minimum=1 --key-maximum=1000000 --key-pattern=R:R \\
  --distinct-client-seed --hide-histogram -t 30 -c 4 \\
  --pipeline=<pipe> --test-time=60 --ratio=<ratio>
\`\`\`

**GET 7 점 먼저, 그다음 MIX 7 점.** 셀마다 avg/p50/p99/p99.9.

v3 는 span 이 크다(EXP-0 pipe=256 에서 GET 242 µs). **클라이언트 timeout 을
넉넉히** 잡아달라. 처리량도 v4 보다 낮게 나오는 것이 정상이다.

NEXT: genie (BD3 14 부하)
EOF
  MATCH="BD3-" TIMEOUT=4200 tools/night-cell.sh post $S/BD3.md "BD3" || say "블록9 대기 실패"
else
  say "블록 9 무장 실패"; $G 'tail -6 /tmp/mc.log'
fi
bash tools/night-save.sh || true
say "잔여 둘 종료"
