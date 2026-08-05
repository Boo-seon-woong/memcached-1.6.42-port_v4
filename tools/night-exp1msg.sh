#!/usr/bin/env bash
# exp1 (블록 7 port / 블록 8 stock) GO 메시지 생성. 24 셀이 한 왕복이다 —
# 서버 구성이 셀마다 안 바뀌므로 나눌 이유가 없다.
#
#   SIDE=PT FP="$(...)" tools/night-exp1msg.sh > msg.md
set -eu
: "${SIDE:?PT|ST}" "${FP:?}"
case $SIDE in
  PT) what="port (원격 메모리, EXT_RDMA_PROF=0)" ;;
  ST) what="stock memcached (로컬 메모리, 97ceee04)" ;;
  *)  echo "SIDE must be PT or ST" >&2; exit 2 ;;
esac

printf '\n---\n\n## [%s KST] ariel — 블록 %s: exp1 %s 무장, 24 셀\n\n' \
  "$(TZ=Asia/Seoul date +%Y-%m-%d)" "$([ "$SIDE" = PT ] && echo 7 || echo 8)" "$what"
cat <<EOF
DPA-Store Fig.15 형태(워크로드별 latency-throughput)라 **세 워크로드 각각
pipeline 스윕**이다. GET-only 만 스윕하고 나머지를 단일점으로 두면 A/B 곡선이
안 나온다.

### 서버 지문

\`\`\`text
$FP
\`\`\`

### 요청 — 24 셀, 각 30초 (사이 20초)

\`\`\`text
곡선 (uniform, R:R)      ratio        pipe
${SIDE}-A-P{1,8,32,64,128,256,384}    1:1     ← YCSB A (50 read / 50 update)
${SIDE}-B-P{1,8,32,64,128,256,384}    1:19    ← YCSB B (95/5)
${SIDE}-C-P{1,8,32,64,128,256,384}    0:1     ← YCSB C (100 read)
보조 (zipf θ=0.99, Z:Z)
${SIDE}-A-Z256  1:1  /  ${SIDE}-B-Z256  1:19  /  ${SIDE}-C-Z256  0:1   pipe=256

memtier -s 10.99.0.3 -p 11411 -P memcache_text -d 64 \\
  --key-prefix=m- --key-minimum=1 --key-maximum=1000000 \\
  --key-pattern=R:R --distinct-client-seed --hide-histogram \\
  -t 30 -c 4 --pipeline=<pipe> --test-time=30 --ratio=<ratio>

zipf 셀만:  --key-pattern=Z:Z --key-zipf-exp=0.99
\`\`\`

\`--ratio\` 는 **SET:GET** 순서다 — B 의 update 5% 가 \`1:19\` 인 이유다.
EOF

if [ "$SIDE" = PT ]; then
cat <<'EOF'

### genie CPU 증거 2회 (XSTORE 의 CPU 주장 대응)

```sh
awk '{print $14, $15}' /proc/$(pgrep genie_memd)/stat
```

`PT-C-P256` 과 `PT-A-P256` **각각 직전·직후**로 부탁한다. one-sided READ 라
**genie CPU 가 0** 이어야 하고, 그 0 이 disaggregation 주장의 직접 증거다.
`MANUAL_TEST_PROCEDURE §F-3` 에 절차가 있다.
EOF
else
cat <<'EOF'

### stock 측 주의

RDMA 를 안 쓰므로 HCA 점유가 없어야 정상이다. co-located 13셀(60초, 기측정)
과 대조하는데 램프 편향이 +0.10%p 라 **보정 없이 직접 비교**한다.
`ST-C-P256` 의 앵커는 off-box 기측정 **16.417 M** 이다 — ±3% 밖이면 bed 가
다른 것이니 보고에 적어달라.
EOF
fi

printf '\n셀마다 avg/p50/p99/p99.9. raw `experiments/night-20260806/genie/<cell>.txt`.\n\n'
printf 'NEXT: genie (exp1 %s 24셀)\n' "$SIDE"
