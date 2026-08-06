#!/usr/bin/env bash
# 무인 체인: 라운드2 종료 → ATTR-A/B(귀속 2셀) → 라운드3 전체 캠페인.
# 관리자 부재(내일 아침까지) — 실패해도 다음 단계로 가되 전부 기록한다.
# ATTR 은 귀속 기록용이라 실패해도 라운드 3 규칙(W·slots=wire 용량)은 불변.
set -u
ROOT=${ROOT:-/home/seonung/2026/memcached-1.6.42-port_v4}; cd "$ROOT"
SF=experiments/semi_final
G="ssh -n -i $HOME/.ssh/snp_guest -p 2222 -o BatchMode=yes -o ConnectTimeout=8 ubuntu@localhost"
export MAN="$ROOT/$SF/manifest.tsv"
say(){ echo "### $* $(date -u +%H:%M:%S)"; }

# ── 0: 라운드 2 구동기 종료 대기(최대 35분) 후 강제 정리 ──────────────────
t=0
while pgrep -f 'bash /tmp/sfd2.sh' >/dev/null && [ $t -lt 2100 ]; do sleep 30; t=$((t+30)); done
for p in $(pgrep -f 'bash /tmp/sfd2.sh'); do kill -9 $p 2>/dev/null; done
pkill -9 -f 'night-cell.sh post /tmp/sf-msgs' 2>/dev/null
say "라운드 2 정리 완료"

# 라운드 2 아카이브
mv -f "$MAN" "$SF/manifest-r2.tsv" 2>/dev/null
$G 'kill $(cat /tmp/semifinal/trace.pid) 2>/dev/null; sleep 2
    mv -f /tmp/semifinal/trace.csv /tmp/semifinal/trace-r2.csv
    OUT=/tmp/semifinal/trace.csv PIDF=/tmp/semifinal/trace.pid RESET_ON_LOAD=1 \
      setsid bash /tmp/shape-trace.sh >>/tmp/semifinal/trace.out 2>&1 </dev/null & sleep 3
    cat /tmp/semifinal/trace.pid' >/dev/null 2>&1
scp -q -i "$HOME/.ssh/snp_guest" -P 2222 ubuntu@localhost:/tmp/semifinal/trace-r2.csv "$SF/ariel/trace-r2.csv" 2>/dev/null

# ── 1: ATTR 2셀 (귀속 기록 — 각 GET 180초) ────────────────────────────────
attr(){ # attr <label> <W> <slots> <설명>
  local lbl=$1 w=$2 ss=$3 desc=$4
  SLOT=256 INLINE=1 AD=64 WW=$w SS=$ss RE=8 PC=8 SQ=1 DEM=0 DVAL=64 \
    tools/night-arm.sh 20 "$w" 4 "$ss" > "/tmp/sf-arm-$lbl.txt" 2>&1 || { say "$lbl 무장 실패"; return 1; }
  grep -v '^──' "/tmp/sf-arm-$lbl.txt" > /tmp/sf-fp.txt
  cp -f "/tmp/sf-arm-$lbl.txt" "$SF/ariel/arm/$lbl.txt"
  cat > "/tmp/sf-msgs/$lbl.md" <<EOF

---

## [$(TZ=Asia/Seoul date +%Y-%m-%d) KST] ariel — 귀속 셀 \`$lbl\` GO ($desc)

SERVER: port_v4 c11ede3e slot=256 W=$w slots=$ss admit=64 — 2×2 의 남은 칸

\`\`\`text
$(cat /tmp/sf-fp.txt)
\`\`\`

\`\`\`text
$lbl   --ratio=0:1   1부하 180초

memtier_benchmark -s 10.99.0.3 -p 11411 -P memcache_text \\
  --key-prefix=m- --key-minimum=1 --key-maximum=1000000 --key-pattern=R:R \\
  --distinct-client-seed --hide-histogram -t 30 -c 4 --pipeline=256 -d 64 \\
  --test-time=180 --ratio=0:1
\`\`\`

raw \`experiments/semi_final/genie/$lbl.txt\`

NEXT: genie ($lbl 1부하)
EOF
  MATCH=$lbl TIMEOUT=900 tools/night-cell.sh post "/tmp/sf-msgs/$lbl.md" "$lbl" || say "$lbl 대기 실패"
}
mkdir -p /tmp/sf-msgs
attr ATTR-A 24 1280 "W=24 에 slots=1280 — slots 단독 효과"
attr ATTR-B 1280 64 "W=1280 에 slots=64 — W 단독 효과"

# 귀속 요약을 채널에
python3 - <<'PY' > /tmp/sf-attr.txt 2>/dev/null
import subprocess
out=subprocess.run(['python3','tools/parse-client.py'],capture_output=True,text=True).stdout
r={l.split('\t')[0]: l.split('\t')[1] for l in out.strip().split('\n')[1:]}
a=r.get('ATTR-A','NA'); b=r.get('ATTR-B','NA')
print(f"""```text
                 slots=64            slots=1280
W=24        13.159 (8/5 OP)      ATTR-A {a} M
W=1280      ATTR-B {b} M         6.873 (SF-OP r2)
```""")
PY
{ echo; echo "---"; echo
  echo "## [$(TZ=Asia/Seoul date +%Y-%m-%d) KST] ariel — 2×2 완성. 라운드 3 발사"
  echo; cat /tmp/sf-attr.txt
  echo
  echo "규칙은 이미 확정이다(W·slots = wire 용량, admit=0) — 이 표는 귀속 기록이다."
  echo "지금부터 라운드 3 전체 캠페인(72구성 216부하)이 무인으로 돈다."
  echo; echo "NEXT: genie (SF-OP 부터, 구동기 GO 를 따라)"
} >> conversation.md
git add -A conversation.md "$SF" >/dev/null 2>&1
git commit -q -m "[ariel] ATTR 2x2 recorded; launching round 3" 2>/dev/null
git fetch -q origin main 2>/dev/null; git rebase -q origin/main >/dev/null 2>&1; git push -q 2>/dev/null

# ── 2: 라운드 3 준비 — ATTR 흔적 아카이브 후 깨끗한 트레이스로 ────────────
mv -f "$MAN" "$SF/manifest-attr.tsv" 2>/dev/null
$G 'kill $(cat /tmp/semifinal/trace.pid) 2>/dev/null; sleep 2
    mv -f /tmp/semifinal/trace.csv /tmp/semifinal/trace-attr.csv
    OUT=/tmp/semifinal/trace.csv PIDF=/tmp/semifinal/trace.pid RESET_ON_LOAD=1 \
      setsid bash /tmp/shape-trace.sh >>/tmp/semifinal/trace.out 2>&1 </dev/null & sleep 3
    cat /tmp/semifinal/trace.pid' >/dev/null 2>&1
scp -q -i "$HOME/.ssh/snp_guest" -P 2222 ubuntu@localhost:/tmp/semifinal/trace-attr.csv "$SF/ariel/trace-attr.csv" 2>/dev/null

# ── 3: 라운드 3 발사 ──────────────────────────────────────────────────────
say "라운드 3 발사"
cp "$ROOT/tools/sf-driver.sh" /tmp/sfd3.sh
ROOT="$ROOT" bash /tmp/sfd3.sh
say "체인 종료"
