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
         'SF3-OP' if l.startswith('SF3-OP') else
         'SF3-O' if l.startswith('SF3-O') else
         'SF3-P' if l.startswith('SF3-P') else
         'SF3-E' if l.startswith('SF3-E') else
         'SF3-D' if l.startswith('SF3-D') else
         'SF3-C' if l.startswith('SF3-C') else
         'SF3-Q' if l.startswith('SF3-Q') else
         'SF3-S' if l.startswith('SF3-S') else
         'SF3-T' if l.startswith('SF3-T') else
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
  post "$MSG/$lbl.md" "$lbl" "${lbl}-SET" "${TMO:-2700}"
}

go_batch(){ # go_batch <axis-label> <match-cell> <timeout> <본문파일>
  post "$4" "$1" "$2" "$3"
}
# 왜: 캠페인의 CQ 가 2×W×nqp 라 nqp² 로 커졌다. nqp·ORD 가 변한 축(Q·O·S)은
# 셀마다 큐가 달라 교란됐고, 쓰기 경로는 그 비용을 크게 물었다(SET +12.3%).
# P·E·D·C 는 큐가 전 셀 동일했으므로 재측정하지 않는다.
# T 는 워커마다 큐가 붙어 총량이 mcT 에 비례하므로 2점만 찍어 판정한다.
export BIN='$HOME/coherent-mr-v2/bin/memcached.wfix'
say "라운드 4 재측정 시작 (15구성)"

cell(){ # cell <label> <nqp> <ord> <mcT> <설명>
  local lbl=$1 nqp=$2 o=$3 m=$4 desc=$5
  local ow=$o; [ "$o" = 0 ] && ow=16
  local WIRE=$((nqp*ow)); local SS=$((WIRE*2>64 ? WIRE*2 : 64))
  local CPU="0-$((m-1))"
  SLOT=256 INLINE=1 AD=0 SS=$SS RE=8 PC=8 SQ=1 DEM=0 DVAL=64 \
    NQP=$nqp ORD=$o MCT=$m CPUSET=$CPU arm "$lbl" || { say "무장 실패 $lbl"; return 0; }
  go_trio "$lbl" "$m" 4 256 64 \
    "port_v4 c33d13f9 (W·ORD 수정) slot=256 nqp=$nqp ORD=${o/0/협상16} W=파생$WIRE slots=$SS mcT=$m — $desc" \
    "$([ "$m" != 30 ] && echo "**mtT=$m 로 맞춰라.**")"
  sfsave
}

cell R4-OP    4  0 30 "가드: 캠페인 운영점과 동일 조건"
for q in 1 2 4 8 16; do cell "R4-Q$q" "$q" 0 30 "Q 축 재측정"; done
for o in 1 2 4 8 0; do
  lbl="R4-O$o"; [ "$o" = 0 ] && lbl="R4-O16"
  cell "$lbl" 4 "$o" 30 "O 축 재측정"
done
cell R4-S16x16 16 16 30 "형태 쌍 높은 쪽 (Q16 과 동일 구성 — 라운드 4 재현성 점)"
cell R4-S32x8  32  8 30 "형태 쌍 낮은 쪽"
cell R4-T8     4  0  8 "T 진단: 큐 과할당 부담이 mcT 에 비례하는지"
cell R4-T30    4  0 30 "T 진단 대조 (= R4-OP 조건)"
say "라운드 4 종료"
