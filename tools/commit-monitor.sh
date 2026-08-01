#!/usr/bin/env bash
# Channel event watcher, run by both sides. Polls origin/main and prints one
# stdout line per non-[$SELF] commit (the other side's report, an admin question,
# a work request). It does NOT exit on an event — one watcher covers the whole
# session, so nothing is missed while the agent is busy handling the previous
# entry. Stdout is the event stream; diagnostics go to stderr.
#
#   SELF=genie POLL_SECONDS=30 ./tools/commit-monitor.sh
#
# The Claude session arms this under the Monitor tool (persistent: true), so
# each stdout line becomes a notification. Full trigger text also lands in
# .monitor/pending_summary.txt and accumulates in .monitor/events.log.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
STATE="$ROOT/.monitor"; mkdir -p "$STATE"
SELF=${SELF:-ariel}
POLL=${POLL_SECONDS:-30}
log(){ printf '[%s] %s\n' "$(date -u '+%F %T UTC')" "$*" | tee -a "$STATE/monitor.log" >&2; }

FAIL_ALERT=${FAIL_ALERT:-5}          # 연속 fetch 실패 몇 회에 이벤트를 낼지

handled=$(cat "$STATE/handled" 2>/dev/null || git -C "$ROOT" rev-parse origin/main)
echo "$handled" > "$STATE/handled"
log "watch start SELF=$SELF poll=${POLL}s handled=$handled"
printf 'CHANNEL armed SELF=%s poll=%ss from=%s\n' "$SELF" "$POLL" "${handled:0:12}"

fails=0; alerted=0
while true; do
  if git -C "$ROOT" fetch -q origin main 2>/dev/null; then
    if [ "$alerted" -eq 1 ]; then
      printf 'CHANNEL fetch recovered after %d failures\n' "$fails"
      log "fetch recovered after $fails failures"
    fi
    fails=0; alerted=0
    tip=$(git -C "$ROOT" rev-parse origin/main)
    if [ "$tip" != "$handled" ]; then
      subj=$(git -C "$ROOT" log --format='%h %s' "$handled..$tip")
      if printf '%s\n' "$subj" | grep -qvE "^[0-9a-f]+ \[$SELF\]"; then
        printf '%s\n' "$tip"  > "$STATE/pending_wake"
        printf '%s\n' "$subj" > "$STATE/pending_summary.txt"
        { date -u '+%F %T UTC'; printf '%s\n\n' "$subj"; } >> "$STATE/events.log"
        echo $(( $(cat "$STATE/eventcount" 2>/dev/null || echo 0) + 1 )) > "$STATE/eventcount"
        log "EVENT: non-$SELF commit(s):"
        # stdout = the event stream the agent is notified on. Keep polling:
        # exiting here would blind the channel until someone re-arms it.
        printf 'CHANNEL %s\n' "$subj"
      fi
      handled=$tip; echo "$handled" > "$STATE/handled"
    fi
  else
    # 조용한 채널과 눈먼 채널은 구별돼야 한다. fetch가 계속 실패하면
    # 이벤트가 안 오는 것이 "새 소식 없음"으로 읽히는데, 그게 바로 이
    # 스크립트가 막으려는 상황(2026-07-30 genie monitor 사망)이다.
    fails=$((fails + 1))
    log "fetch failed ($fails)"
    if [ "$fails" -ge "$FAIL_ALERT" ] && [ "$alerted" -eq 0 ]; then
      printf 'CHANNEL fetch failing %d times in a row — channel may be blind\n' "$fails"
      alerted=1
    fi
  fi
  sleep "$POLL"
done
