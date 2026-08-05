#!/usr/bin/env bash
# 무인 야간 캠페인 구동기. 메시지 파일을 채널에 올리고 genie 의 응답 커밋을
# 기다린다. 셀 경계(epoch)는 manifest 에 남긴다 — 창은 사후 절단한다.
#
#   tools/night-cell.sh post <msgfile> <manifest-label>...   # GO 올리고 대기
#   tools/night-cell.sh wait                                 # 응답만 대기
#
# 대기는 origin/main 에 [genie] 커밋이 새로 붙을 때까지. 타임아웃(기본 40분)
# 이면 1 을 반환하고 호출자가 판단한다 — 스스로 재시도하지 않는다.
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
MAN=${MAN:-$ROOT/experiments/night-20260806/manifest.tsv}
TIMEOUT=${TIMEOUT:-2400}
cd "$ROOT"

wait_genie() {
  local base=$1 t=0
  while [ "$t" -lt "$TIMEOUT" ]; do
    sleep 20; t=$((t + 20))
    git fetch -q origin main 2>/dev/null || continue
    local tip; tip=$(git rev-parse origin/main)
    [ "$tip" = "$base" ] && continue
    # 라벨을 넘겼으면 그 셀의 보고인지까지 본다. 앞 블록의 보고가 늦게
    # 올라오면 그것을 이번 GO 의 응답으로 오인해 다음 무장을 걸고, 그러면
    # 아직 돌고 있는 부하 한가운데서 서버를 재기동한다.
    if git log --format='%s' "$base..$tip" | grep -q '^\[genie\]'; then
      if [ -n "${MATCH:-}" ] && ! git log -p "$base..$tip" -- conversation.md | grep -q "$MATCH"; then
        base=$tip; continue
      fi
      git rebase -q origin/main >/dev/null 2>&1 || true
      git log --format='%h %s' "$base..$(git rev-parse origin/main)" | head -5
      return 0
    fi
    base=$tip
  done
  echo "TIMEOUT after ${TIMEOUT}s" >&2; return 1
}

case ${1:?usage} in
  post)
    msg=${2:?msgfile}; shift 2
    MATCH=${MATCH:-${1:-}}      # 첫 라벨을 기본 매치 문자열로 쓴다
    mkdir -p "$(dirname "$MAN")"
    for label in "$@"; do printf '%s\t%s\n' "$label" "$(date -u +%s)" >> "$MAN"; done
    cat "$msg" >> conversation.md
    git add -A conversation.md "$MAN" >/dev/null
    subj=$(grep -m1 '^## ' "$msg" | sed 's/^## *//; s/^\[[^]]*\] *//; s/^ariel — *//' | cut -c1-90)
    git commit -q -m "[ariel] ${subj:-cell}" || true
    for i in 1 2 3; do
      git stash -q -u 2>/dev/null || true; git fetch -q origin main && git rebase -q origin/main >/dev/null 2>&1 || true
      git stash pop -q 2>/dev/null || true
      git push -q 2>/dev/null && break; sleep 5
    done
    wait_genie "$(git rev-parse origin/main)"
    ;;
  wait) wait_genie "$(git rev-parse origin/main)" ;;
  *) echo "usage: $0 {post <msgfile> <label>...|wait}" >&2; exit 2 ;;
esac
