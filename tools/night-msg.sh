#!/usr/bin/env bash
# 야간 캠페인 GO 메시지 생성기. 셀 목록만 바꿔가며 같은 골격을 찍는다.
#
#   TITLE=... FP=... CELLS=$'id\tratio\tpipe\tdur\n...' tools/night-msg.sh > msg.md
#
# 손으로 매번 쓰면 memtier 줄 한 글자가 어긋나도 모른다 — 캠페인 내내 같은
# 골격을 쓰는 이유다(exp1-arm.sh 와 같은 취지).
set -eu
: "${TITLE:?}" "${FP:?}" "${CELLS:?}"
NOTE=${NOTE:-}

printf '\n---\n\n## [%s KST] ariel — %s\n\n' "$(TZ=Asia/Seoul date +%Y-%m-%d)" "$TITLE"
[ -n "$NOTE" ] && printf '%s\n\n' "$NOTE"

printf '### 서버 지문 (무장 완료)\n\n```text\n%s\n```\n\n' "$FP"
printf '### 요청 — 셀 %s개\n\n```text\n' "$(printf '%s' "$CELLS" | grep -c .)"
printf '%-22s %-10s %-6s %s\n' "셀" "ratio" "pipe" "test-time"
printf '%s\n' "$CELLS" | while IFS=$'\t' read -r id ratio pipe dur; do
  [ -n "$id" ] && printf '%-22s %-10s %-6s %ss\n' "$id" "$ratio" "$pipe" "$dur"
done
printf '\nmemtier -s 10.99.0.3 -p 11411 -P memcache_text -d %s \\\n' "${DVAL:-64}"
printf '  --key-prefix=m- --key-minimum=1 --key-maximum=1000000 --key-pattern=%s \\\n' "${KP:-R:R}"
printf '  --distinct-client-seed --hide-histogram -t %s -c %s \\\n' "${MTT:-30}" "${CONN:-4}"
printf '  --pipeline=<pipe> --test-time=<dur> --ratio=<ratio>\n```\n\n'
printf '셀마다 avg/p50/p99/p99.9 전부. raw `experiments/night-20260806/genie/<cell>.txt`.\n\n'
printf 'NEXT: genie (%s개 부하)\n' "$(printf '%s' "$CELLS" | grep -c .)"
