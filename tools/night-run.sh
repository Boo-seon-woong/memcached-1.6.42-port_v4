#!/usr/bin/env bash
# 야간 잔여 블록 연쇄 구동: 5 → 6 → 10 → 7 → 8 → 9.
# 블록 4 가 끝나기를 기다린 뒤 순서대로 돈다. 한 블록이 실패하면 거기서
# 멈추지 않고 **다음 블록으로 넘어간다** — 밤에 한 곳이 막혔다고 나머지
# 여섯을 잃을 이유가 없다. 실패는 로그에 남고 아침에 판단한다.
set -u
ROOT=${ROOT:-$(cd "$(dirname "$0")/.." && pwd)}; cd "$ROOT"
S=/tmp/night-msgs; mkdir -p $S
G="ssh -n -i $HOME/.ssh/snp_guest -p 2222 -o BatchMode=yes -o ConnectTimeout=8 ubuntu@localhost"
say() { echo "### $* $(date -u +%H:%M:%S)"; }

B4LOG=${B4LOG:-/tmp/night-b4b.log}
while ! grep -q "BLOCK4 DONE" "$B4LOG" 2>/dev/null; do
  pgrep -f night-block4.sh >/dev/null || { say "블록4 구동기가 사라졌다 — 그대로 진행"; break; }
  sleep 60
done
bash tools/night-save.sh || true

say "블록 5 시작"; BUILD=v4 bash tools/night-block5.sh || say "블록 5 실패"
bash tools/night-save.sh || true

say "블록 6 시작"; bash tools/night-block6.sh || say "블록 6 실패"
bash tools/night-save.sh || true

# ── 블록 10: 원인 A 검증. batch=3 은 스레드당 4 연결에서 발화 가능한 유일한 값
say "블록 10 시작"
for b in 3 20; do
  id="V-A-B$b"
  INLINE= AD=64 RE=8 PC=8 SQ=1 DEM=0 tools/night-arm.sh "$b" 24 4 64 \
    > /tmp/night-arm-$id.txt 2>&1 || { say "블록10 무장 실패 b=$b"; continue; }
  fp=$(grep -v '^──' /tmp/night-arm-$id.txt)
  cat > $S/$id.md <<EOF

---

## [$(TZ=Asia/Seoul date +%Y-%m-%d) KST] ariel — 블록 10: 원인 A 검증 \`submit_batch=$b\` (**inline 끄고** io_queue 경로)

\`V3_TO_V4_CHANGES.md §2\` 가 v3 GET admit 폭증의 원인으로 지목한 것은
"제출 조건 \`conns_tosubmit >= 20\` 이 스레드당 4 연결에서 **발화 불능**"이다.
근거가 구조 논증뿐이라 실측으로 가른다. **\`batch=3\` 은 4 연결에서 발화
가능한 유일한 값**이고, \`batch=20\` 이 같은 경로의 대조군이다.

\`\`\`text
$fp
\`\`\`

\`\`\`text
셀            ratio   pipe   test-time
${id}-W1       0:1     256    30s
${id}-W2       1:9     256    30s
\`\`\`

예측: \`batch=3\` 의 admit 이 \`batch=20\` 보다 크게 낮다(제출이 pass 끝을
안 기다린다). 안 갈리면 원인 지목을 문서에서 내려야 한다 — 그것도 결과다.

NEXT: genie ($id 2 부하)
EOF
  TIMEOUT=1800 tools/night-cell.sh post $S/$id.md "$id" || say "블록10 대기 실패 $id"
done
bash tools/night-save.sh || true

# ── 블록 7: exp1 port, PROF 끄고 24 셀
say "블록 7 시작"
PROF= INLINE=1 AD=64 RE=8 PC=8 SQ=1 DEM=0 tools/night-arm.sh 20 24 4 64 \
  > /tmp/night-arm-PT.txt 2>&1 && {
  SIDE=PT FP="$(grep -v '^──' /tmp/night-arm-PT.txt)
EXT_RDMA_PROF 미설정 — 계측 없음 (exp1 은 클라 지표만 쓴다)" \
    bash tools/night-exp1msg.sh > $S/PT.md
  TIMEOUT=3600 tools/night-cell.sh post $S/PT.md "PT" || say "블록7 대기 실패"
} || say "블록 7 무장 실패"

# ── 블록 8: stock. RDMA 를 안 쓰므로 서버 라인이 통째로 다르다
say "블록 8 시작"
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
RDMA 미사용(로컬 메모리). ext_submit_inline 응답 없음 = stock 확인. curr_items $it" \
    bash tools/night-exp1msg.sh > $S/ST.md
  TIMEOUT=3600 tools/night-cell.sh post $S/ST.md "ST" || say "블록8 대기 실패"
else
  say "블록 8 무장 실패 — 포트를 쥔 것이 stock 이 아니다"; cat /tmp/stock-arm.txt
fi
bash tools/night-save.sh || true

# ── 블록 9: v3 기준선 + 계층 3. 블록 5 와 같은 격자
say "블록 9 시작"
$G 'cp -f /tmp/mc.v3l3 ~/coherent-mr-v2/bin/memcached.v3l3 2>/dev/null; chmod +x ~/coherent-mr-v2/bin/memcached.v3l3; sha256sum ~/coherent-mr-v2/bin/memcached.v3l3|cut -c1-24'
BIN='$HOME/coherent-mr-v2/bin/memcached.v3l3' BUILD=v3 bash tools/night-block5.sh || say "블록 9 실패"
bash tools/night-save.sh || true

say "야간 잔여 블록 종료"
