#!/usr/bin/env bash
# 블록 5 — 지연 분해 정밀(b) + 커넥션↔깊이(c). 서버는 운영점 하나로 고정이라
# 무장은 한 번이고, GO 는 둘로 나눈다(부하가 24분이라 한 덩어리는 너무 길다).
#
#   BUILD=v4 nohup bash tools/night-block5.sh > /tmp/night-b5.log 2>&1 &
#   BUILD=v3 ...   # 블록 9: /tmp/mc.v3l3 로 갈아끼운 뒤 같은 격자를 돈다
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd); cd "$ROOT"
S=/tmp/night-msgs; mkdir -p $S
B=${BUILD:-v4}; P=$([ "$B" = v3 ] && echo BD3 || echo BD2)

echo "=== $P 무장 $(date -u +%H:%M:%S) ==="
INLINE=1 AD=64 RE=8 PC=8 SQ=1 DEM=0 tools/night-arm.sh 20 24 4 64 \
  > /tmp/night-arm-$P.txt 2>&1 || { echo "ARM FAILED"; cat /tmp/night-arm-$P.txt; exit 1; }
fp=$(grep -v '^──' /tmp/night-arm-$P.txt)

cat > $S/$P-b.md <<EOF

---

## [$(TZ=Asia/Seoul date +%Y-%m-%d) KST] ariel — 블록 $([ "$B" = v3 ] && echo 9 || echo 5): **지연 분해 정밀** ($([ "$B" = v3 ] && echo 'port_v3 + 계층 3 이식' || echo port_v4)), pipeline 전 축

관리자 지시: **port_v3 와 port_v4 의 지연 분해를 같은 세분도로.** 그래서 두
빌드에서 **같은 격자**를 돈다 — 셀 대 셀로 겹쳐 읽을 수 있어야 한다.

\`\`\`text
$fp
\`\`\`

### 먼저 — genie 요청한 \`c8\` 재시행 2 셀 (같은 무장이라 공짜다)

블록 4 의 \`E4-C8R8\` 이 낮게 나왔다는 당신 의심에 내 데이터도 같은 방향이다:
**c12 의 admit(4.54)이 c8(4.71)보다 낮다** — chain 이 늘면 admit 은 늘어야
하니 순서가 뒤집혔다. 그리고 같은 chain=8 을 120초로 잰 게이트가 13.307 M 인데
블록 4 의 c8 은 12.675 M 이다(−4.7%). 이 무장이 정확히 \`chain=8 reap=8\` 이라
재시행이 공짜다.

\`\`\`text
E4-C8R8-r2-W1     0:1     256    **30초** (블록 4 셀과 같은 창)
E4-C8R8-r2-W2     1:9     256    30초
\`\`\`

### 본 요청 — 14 부하 × **60초** (30초 아니다. 백분위 표본을 두 배로)

\`\`\`text
셀                 ratio   pipe
$P-GET-P{1,8,32,64,128,256,384}    0:1     1/8/32/64/128/256/384
$P-MIX-P{1,8,32,64,128,256,384}    1:9     〃

memtier -s 10.99.0.3 -p 11411 -P memcache_text -d 64 \\
  --key-prefix=m- --key-minimum=1 --key-maximum=1000000 --key-pattern=R:R \\
  --distinct-client-seed --hide-histogram -t 30 -c 4 \\
  --pipeline=<pipe> --test-time=60 --ratio=<ratio>
\`\`\`

**GET 7 점을 먼저, 그다음 MIX 7 점**으로 부탁한다(순서 효과 방지).
셀마다 avg/p50/p99/p99.9 — 그게 분해 트리의 꼭대기다.

내 쪽에서 같은 창에 잡는 것:

\`\`\`text
srv ─┬ que      소켓 read → 명령 시작
     ├ pre      파싱·해시
     ├ span v3  = admit + v2 (+ret),  v2 = xfer + crypto + sync + 잔차
     └ post     복호 → sendmsg
\`\`\`

원본은 \`experiments/night-20260806/\` 에 남긴다(추적기 CSV·절단 결과·무장 지문).

NEXT: genie ($P 14 부하)
EOF
TIMEOUT=4200 tools/night-cell.sh post $S/$P-b.md "$P-b" || { echo "WAIT FAILED $P-b"; exit 1; }

[ "$B" = v3 ] && { echo "=== $P DONE (v3 는 (c) 없음) ==="; exit 0; }

cat > $S/$P-c.md <<EOF

---

## [$(TZ=Asia/Seoul date +%Y-%m-%d) KST] ariel — 블록 5 (c): 커넥션 ↔ 깊이 교환. **이 축은 데이터가 한 점도 없다**

전 캠페인이 \`-c 4\` 단일이었다. \`N = 커넥션 × pipe\` 를 **30,720 고정**하고
형태만 바꾼다. 서버는 그대로(재기동 없음) — 클라이언트만 바뀐다.

\`\`\`text
셀              -c    pipe    커넥션(mtT=30)    N
E2C-c4p256      4     256     120              30,720   ← 현행 운영점(대조)
E2C-c16p64      16    64      480              30,720
E2C-c64p16      64    16      1,920            30,720

각 × {0:1, 1:9},  30초.  6 부하
\`\`\`

> ⚠️ **판정은 memtier 실측 latency 로만.** 커넥션을 늘리면 대기가 \`read()\`
> 이전(커널 소켓 버퍼)으로 옮겨가는데 내 \`srv\` 는 \`read()\` 부터 재므로
> **서버 지표만 보면 개선된 것처럼 보인다.**

예측은 세우지 않는다 — 직렬화 큐 감소(지연↓)와 syscall 상각 감소(처리량↓)가
반대로 작용하고 **어느 쪽이 큰지 모른다.** \`c64p16\` 은 1,920 커넥션이라
fd 한계에 걸릴 수 있는데, 걸리면 그것도 결과이니 조용히 줄이지 말고 적어달라.

NEXT: genie (E2C 6 부하)
EOF
TIMEOUT=1800 tools/night-cell.sh post $S/$P-c.md "E2C" || { echo "WAIT FAILED E2C"; exit 1; }
echo "=== BLOCK5 DONE $(date -u +%H:%M:%S) ==="
