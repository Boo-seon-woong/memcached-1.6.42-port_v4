#!/usr/bin/env bash
# semi_final 캠페인 구동기 — PLAN.md §2 를 위에서 아래로 그대로 실행한다.
#
#   cp tools/sf-driver.sh /tmp/sfd.sh
#   ROOT=<repo> nohup bash /tmp/sfd.sh > /tmp/sf-driver.log 2>&1 &
#
# 규칙 (야간 캠페인의 사고 다섯에서 나온 것):
#   · 구동기는 이 하나뿐이다. 실행 중 원본 편집 금지 — /tmp 사본으로 돈다
#   · GO 응답 매칭은 그 묶음의 마지막 셀 이름 전체로만 한다
#   · 무장 게이트 실패 = 그 구성 건너뛰고 기록. 대기 실패 = 저장 후 다음
#   · 서버 상태를 바꾸기 전에 반드시 채널에 적는다 (GO 가 그 기록이다)
set -u
ROOT=${ROOT:-/home/seonung/2026/memcached-1.6.42-port_v4}; cd "$ROOT"
SF=experiments/semi_final
G="ssh -n -i $HOME/.ssh/snp_guest -p 2222 -o BatchMode=yes -o ConnectTimeout=8 ubuntu@localhost"
MSG=/tmp/sf-msgs; mkdir -p $MSG "$SF/ariel/arm" "$SF/genie" "$SF/csv"
MAN="$ROOT/$SF/manifest.tsv"
export MAN
say(){ echo "### $* $(date -u +%H:%M:%S)"; }

MEMTIER='memtier_benchmark -s 10.99.0.3 -p 11411 -P memcache_text \
  --key-prefix=m- --key-minimum=1 --key-maximum=1000000 --key-pattern=R:R \
  --distinct-client-seed --hide-histogram --test-time=180'

# ── 무장. 성공 시 지문을 /tmp/sf-fp.txt 에 남긴다 ─────────────────────────
arm(){ # arm <label> — 호출자가 env(SLOT/PC/RE/ORD/MCT/CPUSET/DVAL…)를 세팅
  local lbl=$1
  if tools/night-arm.sh 20 "${WW:-64}" "${NQP:-4}" "${SS:-128}" > "/tmp/sf-arm-$lbl.txt" 2>&1; then
    grep -v '^──' "/tmp/sf-arm-$lbl.txt" > /tmp/sf-fp.txt
    $G 'printf "stats\r\nquit\r\n"|timeout 5 nc -q1 127.0.0.1 11411|tr -d "\r"|grep -E "listen_disabled_num|curr_items|ext_pac_fallback"' \
      >> "/tmp/sf-arm-$lbl.txt" 2>/dev/null
    cp -f "/tmp/sf-arm-$lbl.txt" "$SF/ariel/arm/$lbl.txt"
    return 0
  fi
  cp -f "/tmp/sf-arm-$lbl.txt" "$SF/ariel/arm/$lbl.FAILED.txt"
  say "무장 실패 $lbl (건너뜀)"; return 1
}

listen_log(){ # listen_log <label>
  local v; v=$($G 'printf "stats\r\nquit\r\n"|timeout 5 nc -q1 127.0.0.1 11411|tr -d "\r"|awk "/listen_disabled_num/{print \$3}"' 2>/dev/null)
  echo "$1	${v:-NA}	$(date -u +%s)" >> "$SF/ariel/listen.log"
}

flush_preload(){ # flush_preload <d>
  local out
  out=$($G "printf 'flush_all\r\nquit\r\n' | timeout 5 nc -q1 127.0.0.1 11411 >/dev/null; sleep 1
    LD_LIBRARY_PATH=\$HOME/memtier:\$HOME/kvs-port taskset -c 0-29 \$HOME/memtier/memtier_benchmark \
      -s 127.0.0.1 -p 11411 -P memcache_text -d $1 --key-prefix=m- --key-minimum=1 \
      --key-maximum=1000000 --threads=8 --clients=16 --pipeline=8 --key-pattern=P:P \
      --ratio=1:0 -n 7813 --hide-histogram >/dev/null 2>&1
    printf 'stats\r\nquit\r\n' | timeout 5 nc -q1 127.0.0.1 11411 | tr -d '\r' |
      awk '/^STAT (curr_items|ext_pac_fallback) /{printf \"%s=%s \", \$2, \$3}'" 2>/dev/null)
  echo "$out" | grep -q "curr_items=1000000" && echo "$out" | grep -q "ext_pac_fallback=0"
}

sfsave(){
  # 게스트 디스크 가드 — 150MB 아래로 내려가면 저널·syslog 를 걷는다
  $G 'a=$(df --output=avail /|tail -1); if [ "$a" -lt 153600 ]; then
        sudo journalctl --vacuum-size=30M >/dev/null 2>&1
        sudo truncate -s 0 /var/log/syslog /var/log/auth.log 2>/dev/null; fi' 2>/dev/null
  scp -q -i "$HOME/.ssh/snp_guest" -P 2222 ubuntu@localhost:/tmp/semifinal/trace.csv "$SF/ariel/trace.csv" 2>/dev/null
  python3 tools/night-slice.py "$SF/ariel/trace.csv" "$MAN" > "$SF/rows.tsv" 2>/dev/null
  python3 tools/parse-client.py > "$SF/client.tsv" 2>/dev/null
  python3 - <<'PY' 2>/dev/null
rows=open('experiments/semi_final/rows.tsv').read().strip().split('\n')
hdr=rows[0]; buckets={}
for r in rows[1:]:
    l=r.split('\t')[0]
    key=('SLOTAB' if l.startswith('SLOTAB') else
         'SF-OP' if l.startswith('SF-OP') else
         'SF-P' if l.startswith('SF-P') else
         'SF-E' if l.startswith('SF-E') else
         'SF-D' if l.startswith('SF-D') else
         'SF-C' if l.startswith('SF-C') else
         'SF-Q' if l.startswith('SF-Q') else
         'SF-S' if l.startswith('SF-S') else
         'SF-T' if l.startswith('SF-T') else
         'SF-O' if l.startswith('SF-O') else 'etc')
    buckets.setdefault(key,[]).append(r)
for k,v in buckets.items():
    open(f'experiments/semi_final/csv/{k}.csv','w').write(hdr+'\n'+'\n'.join(v)+'\n')
PY
  git add -A "$SF" >/dev/null 2>&1
  git commit -q -m "[ariel] semi_final data save" 2>/dev/null
  git fetch -q origin main 2>/dev/null; git rebase -q origin/main >/dev/null 2>&1
  git push -q 2>/dev/null || true
}

post(){ # post <msgfile> <label> <match> <timeout>
  MATCH=$3 TIMEOUT=$4 tools/night-cell.sh post "$1" "$2" || { say "대기 실패 $2"; listen_log "$2"; sfsave; return 1; }
  listen_log "$2"; return 0
}

ops_of(){ # ops_of <cell> — client.tsv 에서 처리량(M)
  python3 tools/parse-client.py 2>/dev/null > /tmp/sf-client.tsv
  awk -F'\t' -v c="$1" '$1==c{print $2}' /tmp/sf-client.tsv | tail -1
}

go_trio(){ # go_trio <label> <mtT> <c> <pipe> <d> <서버줄> [추가주의]
  local lbl=$1 mtT=$2 c=$3 pipe=$4 d=$5 srv=$6 extra=${7:-}
  cat > "$MSG/$lbl.md" <<EOF

---

## [$(TZ=Asia/Seoul date +%Y-%m-%d) KST] ariel — semi_final \`$lbl\` GO

SERVER: $srv

\`\`\`text
$(cat /tmp/sf-fp.txt)
\`\`\`

\`\`\`text
${lbl}-GET   --ratio=0:1     각 180초, 사이 20초
${lbl}-MIX   --ratio=1:9
${lbl}-SET   --ratio=1:0

$MEMTIER \\
  -t $mtT -c $c --pipeline=$pipe -d $d --ratio=<위>
\`\`\`
$extra
raw \`experiments/semi_final/genie/<cell>.txt\` (memtier 표준출력 전문 필수)

NEXT: genie ($lbl 3부하)
EOF
  post "$MSG/$lbl.md" "$lbl" "${lbl}-SET" 1800
}

go_batch(){ # go_batch <axis-label> <match-cell> <timeout> <본문파일>
  post "$4" "$1" "$2" "$3"
}

# ═════════════════════════ 실행 ═════════════════════════
say "semi_final 시작"

# ── 1: SF-OP (slot=256, admit=64) + ≥10M 게이트 ─────────
SLOT=256 INLINE=1 AD=0 WW=64 RE=8 PC=8 SQ=1 DEM=0 DVAL=64 arm SF-OP || { say "OP 무장 실패 — 중단"; exit 1; }
go_trio SF-OP 30 4 256 64 "port_v4 c11ede3e slot=256 W=64(=wire곱) admit=0 (라운드 3 — 드리프트 가드 시작점)"

OPS=$(ops_of SF-OP-GET)
say "SF-OP-GET = ${OPS:-NA} M (게이트: ≥10M)"
if [ -n "${OPS:-}" ] && python3 -c "exit(0 if float('${OPS}')<10.0 else 1)"; then
  cat >> conversation.md <<EOF

---

## [$(TZ=Asia/Seoul date +%Y-%m-%d) KST] ariel — **캠페인 중단: SF-OP ${OPS} M < 10 M 게이트**

admit=64 복원으로 13M대 복귀를 예상했는데 미달이다. 관리자 판단 대기.

NEXT: (중단)
EOF
  git add -A conversation.md && git commit -q -m "[ariel] STOP: SF-OP ${OPS}M under the 10M gate" && git push -q
  exit 1
fi
sfsave

# ── 2: P 축 (클라만, 한 GO) ─────────────────────────────
{
  echo; echo "---"; echo
  echo "## [$(TZ=Asia/Seoul date +%Y-%m-%d) KST] ariel — semi_final P 축 GO (pipeline 8구성 × 3부하, 서버 불변)"
  echo; echo "SERVER: port_v4 c11ede3e slot=256 W=64 (SF-OP 와 동일 — 재기동 없음)"
  echo; echo '```text'
  for p in 1 8 32 64 128 256 384 512; do
    echo "SF-P${p}-{GET,MIX,SET}    --pipeline=$p    ratio 0:1 / 1:9 / 1:0    각 180초"
  done
  echo; echo "$MEMTIER \\"; echo '  -t 30 -c 4 --pipeline=<p> -d 64 --ratio=<r>'
  echo '```'; echo
  echo "구성 순서 고정(P1→P512), 구성 안에서 GET→MIX→SET. raw \`experiments/semi_final/genie/<cell>.txt\`"
  echo; echo "NEXT: genie (24부하)"
} > "$MSG/P.md"
go_batch "SF-P" "SF-P512-SET" 7200 "$MSG/P.md"; sfsave

# ── 3: E 축 (클라만, 한 GO) ─────────────────────────────
{
  echo; echo "---"; echo
  echo "## [$(TZ=Asia/Seoul date +%Y-%m-%d) KST] ariel — semi_final E 축 GO (client×pipeline 곱 1,024 고정, 8구성 × 3부하, 서버 불변)"
  echo; echo "SERVER: port_v4 c11ede3e slot=256 W=64 (변경 없음)"
  echo; echo '```text'
  for cp in 1:1024 2:512 4:256 8:128 16:64 32:32 64:16 128:8; do
    c=${cp%%:*}; p=${cp##*:}
    echo "SF-E${c}x${p}-{GET,MIX,SET}    -c $c --pipeline=$p    각 180초"
  done
  echo; echo "$MEMTIER \\"; echo '  -t 30 -c <c> --pipeline=<p> -d 64 --ratio=<r>'
  echo '```'; echo
  echo "총 N = 30×c×pipe = 30,720 전 구성 동일. c=128 은 3,840 커넥션 — fd 걸리면 축소 말고 보고."
  echo "판정은 memtier 실측으로만 한다(계획 §1). raw \`experiments/semi_final/genie/<cell>.txt\`"
  echo; echo "NEXT: genie (24부하)"
} > "$MSG/E.md"
go_batch "SF-E" "SF-E128x8-SET" 7200 "$MSG/E.md"; sfsave

# ── 4: D 축 (flush+프리로드, 크기별 GO) ──────────────────
for d in 4 8 16 24 32 48 64 96 128; do
  if flush_preload "$d"; then
    go_trio "SF-D$d" 30 4 256 "$d" "port_v4 c11ede3e slot=256 W=64 (재기동 없음 — flush 후 d=$d 재프리로드)" \
      "프리로드도 -d $d 다. 부하 -d 를 반드시 맞출 것."
  else
    say "SF-D$d 프리로드/게이트 실패 — 건너뜀"
    echo "SF-D$d PRELOAD-FAIL $(date -u +%s)" >> "$SF/ariel/listen.log"
  fi
done
sfsave

# ── 5: C 축 (재기동 16회) ───────────────────────────────
for c in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16; do
  SLOT=256 INLINE=1 AD=0 WW=64 RE=8 PC=$c SQ=1 DEM=0 DVAL=64 arm "SF-C$c" || continue
  go_trio "SF-C$c" 30 4 256 64 "port_v4 c11ede3e slot=256 W=64 ext_post_chain=$c (reap=8)"
done
sfsave

# ── 6: Q 축 (재기동 6회) ────────────────────────────────
for q in 1 2 4 8 16 64; do
  WIRE=$((q*16)); SS=$((WIRE*2>64 ? WIRE*2 : 64))
  SLOT=256 INLINE=1 AD=0 WW=$WIRE SS=$SS RE=8 PC=8 SQ=1 DEM=0 DVAL=64 NQP=$q arm "SF-Q$q" || continue
  go_trio "SF-Q$q" 30 4 256 64 "port_v4 c11ede3e slot=256 nqp=$q ORD=협상16 W=$WIRE (=wire 곱)"
done
sfsave

# ── 7: O 축 (재기동 7회) ────────────────────────────────
for o in 1 2 4 8 0 32 64; do
  lbl="SF-O$o"; [ "$o" = 0 ] && lbl="SF-O16"
  ow=$o; [ "$o" = 0 ] && ow=16; [ "$ow" -gt 16 ] && ow=16
  WIRE=$((4*ow)); SS=$((WIRE*2>64 ? WIRE*2 : 64))
  SLOT=256 INLINE=1 AD=0 WW=$WIRE SS=$SS RE=8 PC=8 SQ=1 DEM=0 DVAL=64 ORD=$o arm "$lbl" || continue
  note="port_v4 c11ede3e slot=256 nqp=4 ORD=$o W=$WIRE (=wire 곱)"
  [ "$o" = 0 ] && note="port_v4 c11ede3e slot=256 nqp=4 ORD=협상16 W=64"
  go_trio "$lbl" 30 4 256 64 "$note"
done
sfsave

# ── 8: S 축 (곱 256, 재기동 7회) ─────────────────────────
for qo in 1:256 2:128 4:64 8:32 16:16 32:8 64:4; do
  q=${qo%%:*}; o=${qo##*:}
  lbl="SF-S${q}x${o}"
  WIRE=$((q*(o<16?o:16))); SS=$((WIRE*2>64 ? WIRE*2 : 64))
  SLOT=256 INLINE=1 AD=0 WW=$WIRE SS=$SS RE=8 PC=8 SQ=1 DEM=0 DVAL=64 NQP=$q ORD=$o arm "$lbl" || continue
  go_trio "$lbl" 30 4 256 64 "port_v4 c11ede3e slot=256 nqp=$q ORD=$o핀 W=$WIRE (soft곱 256, wire곱 $WIRE)"
done
sfsave

# ── 9: T 축 (재기동 9회) ────────────────────────────────
for m in 1 2 4 8 12 16 24 28 30; do
  SLOT=256 INLINE=1 AD=0 WW=64 RE=8 PC=8 SQ=1 DEM=0 DVAL=64 MCT=$m CPUSET="0-$((m-1))" arm "SF-T$m" || continue
  go_trio "SF-T$m" "$m" 4 256 64 "port_v4 c11ede3e slot=256 W=64 mcT=$m taskset 0-$((m-1)) — genie 도 -t $m" \
    "**mtT=$m 로 맞춰라** (mcT=mtT 동시 스케일)."
done
sfsave

# ── 10: OP 재시행 ───────────────────────────────────────
SLOT=256 INLINE=1 AD=0 WW=64 RE=8 PC=8 SQ=1 DEM=0 DVAL=64 arm SF-OP-r2 && \
  go_trio SF-OP-r2 30 4 256 64 "port_v4 c11ede3e slot=256 W=64 (드리프트 가드 끝점 — SF-OP 와 동일 조건)"
sfsave
say "semi_final 종료"
