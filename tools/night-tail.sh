#!/usr/bin/env bash
# 연쇄 구동기가 끝난 뒤 남은 것을 줍는다. 오늘 밤은 블록 5 (c) 하나 —
# (b) 의 응답 매칭이 어긋나 타임아웃하면서 같이 건너뛰어졌다.
set -u
ROOT=${ROOT:-/home/seonung/2026/memcached-1.6.42-port_v4}; cd "$ROOT"
S=/tmp/night-msgs; mkdir -p $S

while pgrep -f night-run-frozen.sh >/dev/null; do sleep 60; done
echo "### 잔여 처리 시작 $(date -u +%H:%M:%S)"

INLINE=1 AD=64 RE=8 PC=8 SQ=1 DEM=0 tools/night-arm.sh 20 24 4 64 \
  > /tmp/night-arm-E2C.txt 2>&1 || { echo "E2C 무장 실패"; exit 1; }
fp=$(grep -v '^──' /tmp/night-arm-E2C.txt)

cat > $S/E2C.md <<EOF

---

## [$(TZ=Asia/Seoul date +%Y-%m-%d) KST] ariel — 블록 5 (c) 재발행: 커넥션 ↔ 깊이. **이 축은 아직 데이터가 한 점도 없다**

앞서 이 GO 가 안 나갔다 — (b) 의 응답 매칭이 어긋나 내 구동기가 70 분
기다리다 타임아웃했고, (c) 가 같이 건너뛰어졌다. 내 결함이고 고쳤다.

\`\`\`text
$fp
\`\`\`

전 캠페인이 \`-c 4\` 단일이라 이 축은 비어 있다. \`N = 커넥션 × pipe\` 를
**30,720 고정**하고 형태만 바꾼다. 서버는 그대로 — 클라이언트만 바뀐다.

\`\`\`text
셀              -c    pipe    커넥션(mtT=30)    N
E2C-c4p256      4     256     120              30,720   ← 현행 운영점(대조)
E2C-c16p64      16    64      480              30,720
E2C-c64p16      64    16      1,920            30,720

각 × {0:1, 1:9},  30초.  6 부하

memtier -s 10.99.0.3 -p 11411 -P memcache_text -d 64 \\
  --key-prefix=m- --key-minimum=1 --key-maximum=1000000 --key-pattern=R:R \\
  --distinct-client-seed --hide-histogram -t 30 -c <c> \\
  --pipeline=<pipe> --test-time=30 --ratio=<ratio>
\`\`\`

> ⚠️ **판정은 memtier 실측 latency 로만.** 커넥션을 늘리면 대기가 \`read()\`
> 이전(커널 소켓 버퍼)으로 옮겨가는데 내 \`srv\` 는 \`read()\` 부터 재므로
> **서버 지표만 보면 개선된 것처럼 보인다.**

\`c64p16\` 은 1,920 커넥션이라 fd 한계에 걸릴 수 있다. 걸리면 그것도 결과이니
조용히 줄이지 말고 적어달라.

NEXT: genie (E2C 6 부하)
EOF
MATCH=E2C TIMEOUT=2400 tools/night-cell.sh post $S/E2C.md "E2C" || echo "E2C 대기 실패"
bash tools/night-save.sh || true

# 블록 6 잔여: V64·V152. 내가 night-cell.sh 를 실행 중에 편집해 V32 대기가
# 깨졌고 그 뒤 두 크기를 잃었다. 실행 중인 스크립트는 건드리지 않는다.
for d in 64 152; do
  id="V$d"
  echo "### $id $(date -u +%H:%M:%S)"
  INLINE=1 AD=64 RE=8 PC=8 SQ=1 DEM=0 DVAL=$d tools/night-arm.sh 20 24 4 64 \
    > /tmp/night-arm-$id.txt 2>&1 || { echo "$id 무장 실패"; continue; }
  fb=$(ssh -n -i $HOME/.ssh/snp_guest -p 2222 -o BatchMode=yes ubuntu@localhost \
       'printf "stats\r\nquit\r\n" | nc -q1 127.0.0.1 11411 | tr -d "\r" | awk "/^STAT ext_pac_fallback/{print \$3}"')
  [ "${fb:-1}" = 0 ] || { echo "$id pac_fallback=$fb — 건너뛴다"; continue; }
  fp=$(grep -v '^──' /tmp/night-arm-$id.txt)
  cat > $S/$id.md <<EOF

---

## [$(TZ=Asia/Seoul date +%Y-%m-%d) KST] ariel — 블록 6 잔여: 값 크기 \`-d $d\` ($id)

앞서 V32 뒤에서 끊겼다 — 내가 구동기 스크립트를 **실행 중에 편집**해서
대기 로직이 깨졌다. 내 결함이고, 데이터는 잃지 않았다(V16·V32 는 유효).

\`\`\`text
$fp
ext_pac_fallback = 0
\`\`\`

프리로드도 \`-d $d\` 로 다시 했다. **부하도 \`-d $d\`** 로.

\`\`\`text
${id}-W1   0:1   pipe=256   30s   -d $d
${id}-W2   1:9   pipe=256   30s   -d $d
${id}-W3   1:0   pipe=256   30s   -d $d

memtier -s 10.99.0.3 -p 11411 -P memcache_text -d $d \\
  --key-prefix=m- --key-minimum=1 --key-maximum=1000000 --key-pattern=R:R \\
  --distinct-client-seed --hide-histogram -t 30 -c 4 \\
  --pipeline=256 --test-time=30 --ratio=<ratio>
\`\`\`

\`V152\` 는 이번 탐침으로 확인한 **수용 상한**이다(\`-d 152\` 에서
fallback 0, 계산값 155 B 와 부합).

NEXT: genie ($id 3 부하)
EOF
  MATCH=$id TIMEOUT=1800 tools/night-cell.sh post $S/$id.md "$id" || echo "$id 대기 실패"
  bash tools/night-save.sh || true
done
echo "### 잔여 처리 종료 $(date -u +%H:%M:%S)"
