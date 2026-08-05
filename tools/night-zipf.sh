#!/usr/bin/env bash
# exp1 의 zipf 3 셀 재시행. 오늘 밤 그 셀들이 사실상 uniform 으로 돌았다 —
# 내 GO 의 memtier 템플릿 줄이 `--key-pattern=R:R` 이고 zipf 는 그 아래
# 산문으로만 적혀 있었다. 이번엔 셀마다 전체 명령줄을 그대로 준다.
set -u
ROOT=${ROOT:-/home/seonung/2026/memcached-1.6.42-port_v4}; cd "$ROOT"
S=/tmp/night-msgs; mkdir -p $S
while pgrep -f '/tmp/nt.sh' >/dev/null; do sleep 60; done
echo "### zipf 재시행 $(date -u +%H:%M:%S)"

PROF= INLINE=1 AD=64 RE=8 PC=8 SQ=1 DEM=0 tools/night-arm.sh 20 24 4 64 \
  > /tmp/night-arm-PTZ.txt 2>&1 || { echo "PTZ 무장 실패"; exit 1; }
fp=$(grep -v '^──' /tmp/night-arm-PTZ.txt)

cat > $S/PTZ.md <<EOF

---

## [$(TZ=Asia/Seoul date +%Y-%m-%d) KST] ariel — exp1 zipf 3 셀 **재시행**. 앞 셀들은 skew 가 서버에 도달하지 않았다

당신 의심이 맞다. 내 창의 \`badcrc\` 가 그것을 확정한다.

\`\`\`text
                       처리량        badcrc      비고
오늘 A-Z256 (1:1)      7.162 M          3        SET 이 50% 인데 3 건
오늘 B-Z256 (1:19)    12.357 M          2
오늘 C-Z256 (0:1)     13.714 M          0        uniform(13.654) 보다 오히려 높다
08-03 KD-Z-MIX (1:9)   7.446 M    251,856        SET 10% 인데 25 만 건
08-03 KD-Z-GET (0:1)  12.671 M          0        uniform 13.792 대비 −8.1%
\`\`\`

**SET 비중이 5 배 큰데 badcrc 가 8 만분의 1 이다.** 그리고 GET-only 는
badcrc 없이도 08-03 에 −8.1% 가 나왔는데 오늘은 +0.4% 다. 두 지표 모두
**skew 가 없었다**고 말한다.

### 원인은 내 GO 다

내 exp1 메시지의 memtier 템플릿 줄이 \`--key-pattern=R:R\` 이었고, zipf 는
그 아래 산문으로만 적어뒀다("zipf 셀만: …"). 템플릿을 그대로 쓰면 R:R 이
이긴다. **이번엔 셀마다 전체 명령줄을 준다.**

\`\`\`text
$fp
\`\`\`

### 요청 — 3 셀, 각 30초. 명령줄 전문

\`\`\`sh
# PTZ-C-Z256  (YCSB C, zipf)
memtier_benchmark -s 10.99.0.3 -p 11411 -P memcache_text -d 64 \\
  --key-prefix=m- --key-minimum=1 --key-maximum=1000000 \\
  --key-pattern=Z:Z --key-zipf-exp=0.99 \\
  --distinct-client-seed --hide-histogram \\
  -t 30 -c 4 --pipeline=256 --test-time=30 --ratio=0:1

# PTZ-B-Z256  — 위와 동일, --ratio=1:19
# PTZ-A-Z256  — 위와 동일, --ratio=1:1
\`\`\`

**셀마다 memtier 가 실제로 받은 인자 줄을 그대로 붙여달라.** 오늘 이 축을
두 번 잃지 않으려면 그것이 제일 싼 확인이다.

\`\`\`text
기대  A-Z256 의 badcrc 가 수만~수십만 건 (08-03 의 25 만과 같은 자릿수)
      C-Z256 이 uniform 대비 −5~−10%
반증  다시 badcrc 0 이고 −0% 면 memtier 의 Z 가 이 키공간에서 skew 를
      못 만드는 것이고, exp1 의 zipf 축은 다른 방법이 필요하다
\`\`\`

NEXT: genie (PTZ 3 셀)
EOF
MATCH=PTZ TIMEOUT=1800 tools/night-cell.sh post $S/PTZ.md "PTZ" || echo "PTZ 대기 실패"
bash tools/night-save.sh || true
echo "### zipf 재시행 종료 $(date -u +%H:%M:%S)"
