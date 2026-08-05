#!/usr/bin/env bash
# 야간 마지막 구동기. **엄격히 순차**로 셋만 돈다: zipf 재시행 → stock →
# v3 지연 분해. 동시에 도는 구동기가 서버를 갈아엎어 셀을 버린 사고
# (21:00, stock 20 셀 손실) 뒤에 하나로 합친 것이다.
#
# 대기 매칭은 **묶음의 마지막 셀 이름**으로 한다. 접두사("ST")나 짧은
# 문자열은 genie 의 무관한 산문에도 걸린다 — 그게 그 사고의 원인이었다.
set -u
ROOT=${ROOT:-/home/seonung/2026/memcached-1.6.42-port_v4}; cd "$ROOT"
S=/tmp/night-msgs; mkdir -p $S
G="ssh -n -i $HOME/.ssh/snp_guest -p 2222 -o BatchMode=yes -o ConnectTimeout=8 ubuntu@localhost"
say(){ echo "### $* $(date -u +%H:%M:%S)"; }

while pgrep -f '/tmp/nt\.sh' >/dev/null; do sleep 30; done
say "마지막 구동기 시작"

# ── ① zipf 재시행 (port, PROF off)
PROF= INLINE=1 AD=64 RE=8 PC=8 SQ=1 DEM=0 tools/night-arm.sh 20 24 4 64 \
  > /tmp/night-arm-PTZ.txt 2>&1 && {
  fp=$(grep -v '^──' /tmp/night-arm-PTZ.txt)
  cat > $S/PTZ.md <<EOF

---

## [$(TZ=Asia/Seoul date +%Y-%m-%d) KST] ariel — exp1 zipf 3 셀 재시행 (당신 러너 수정 반영)

\`\`\`text
$fp
\`\`\`

셀마다 **전체 명령줄**을 준다. 순서대로 하나씩:

\`\`\`sh
# PTZ-C-Z256
memtier_benchmark -s 10.99.0.3 -p 11411 -P memcache_text -d 64 \\
  --key-prefix=m- --key-minimum=1 --key-maximum=1000000 \\
  --key-pattern=Z:Z --key-zipf-exp=0.99 --distinct-client-seed --hide-histogram \\
  -t 30 -c 4 --pipeline=256 --test-time=30 --ratio=0:1
# PTZ-B-Z256   위와 동일, --ratio=1:19
# PTZ-A-Z256   위와 동일, --ratio=1:1     ← 마지막 셀
\`\`\`

기대: \`PTZ-A-Z256\` 의 badcrc 가 수만~수십만 (08-03 KD-Z-MIX 의 251,856 과
같은 자릿수). 다시 0 이면 memtier Z 가 이 키공간에서 skew 를 못 만드는 것이다.

NEXT: genie (PTZ 3 셀)
EOF
  MATCH="PTZ-A-Z256" TIMEOUT=1800 tools/night-cell.sh post $S/PTZ.md "PTZ" || say "PTZ 대기 실패"
} || say "PTZ 무장 실패"
bash tools/night-save.sh || true

# ── ② stock 24 셀 (앞서 20 셀을 서버 교체로 잃었다)
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
RDMA 미사용. ext_submit_inline 응답 없음 = stock 확인. curr_items $it
**이번에는 이 서버가 블록이 끝날 때까지 유지된다** — 앞 시도에서 내 구동기
둘이 겹쳐 도는 바람에 중간에 port 로 바뀌었다. 지금은 구동기가 하나뿐이다." \
    bash tools/night-exp1msg.sh > $S/ST.md
  MATCH="ST-C-Z256" TIMEOUT=3600 tools/night-cell.sh post $S/ST.md "ST2" || say "stock 대기 실패"
else
  say "stock 무장 실패"; cat /tmp/stock-arm.txt
fi
bash tools/night-save.sh || true

# ── ③ v3 지연 분해 (v4 서브옵션 없이)
say "v3 시작"
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

## [$(TZ=Asia/Seoul date +%Y-%m-%d) KST] ariel — 블록 9: **port_v3 지연 분해**, 블록 5 와 같은 격자

관리자 지시(port_v3 ↔ port_v4 를 같은 세분도로)의 v3 쪽. 셀·창·워크로드가
블록 5(BD2)와 전부 같아야 겹쳐 읽힌다.

\`\`\`text
빌드  86da4222ba5825d9d84b19bd
      v3 측정 기준선 6b150c9 (admit/ret 성분 있음, v4 수정 둘 없음 — EXP-0 이
      잰 그 코드) + 계층 3 계측 이식 + 백분위 결함 수정
      v4 서브옵션(submit_batch/admit_max/inline/reap/chain)은 이 빌드에
      없다 — 앞 시도가 "Illegal suboption" 으로 죽은 이유다. W=40 nqp=4
$fp
\`\`\`

\`\`\`text
BD3-GET-P{1,8,32,64,128,256,384}    --ratio=0:1     각 60초
BD3-MIX-P{1,8,32,64,128,256,384}    --ratio=1:9     ← 마지막 BD3-MIX-P384

memtier -s 10.99.0.3 -p 11411 -P memcache_text -d 64 \\
  --key-prefix=m- --key-minimum=1 --key-maximum=1000000 --key-pattern=R:R \\
  --distinct-client-seed --hide-histogram -t 30 -c 4 \\
  --pipeline=<pipe> --test-time=60 --ratio=<ratio>
\`\`\`

v3 는 span 이 크다(EXP-0 pipe=256 에서 GET 242 µs). **클라이언트 timeout 을
넉넉히.** 처리량이 v4 보다 낮은 것이 정상이다.

NEXT: genie (BD3 14 부하)
EOF
  MATCH="BD3-MIX-P384" TIMEOUT=4200 tools/night-cell.sh post $S/BD3.md "BD3" || say "v3 대기 실패"
else
  say "v3 무장 실패"; $G 'tail -6 /tmp/mc.log'
fi
bash tools/night-save.sh || true
say "야간 종료"
