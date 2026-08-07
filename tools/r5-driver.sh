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
  --distinct-client-seed --hide-histogram --test-time=60'

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
${lbl}-GET   --ratio=0:1     각 60초, 사이 20초
${lbl}-MIX   --ratio=1:9
${lbl}-SET   --ratio=1:0

$MEMTIER \\
  -t $mtT -c $c --pipeline=$pipe -d $d --ratio=<위>
\`\`\`
$extra
raw \`experiments/semi_final/genie/<cell>.txt\` (memtier 표준출력 전문 필수)

NEXT: genie ($lbl 3부하)
EOF
  post "$MSG/$lbl.md" "$lbl" "${lbl}-SET" "${TMO:-1800}"
}

go_batch(){ # go_batch <axis-label> <match-cell> <timeout> <본문파일>
  post "$4" "$1" "$2" "$3"
}

# ═══════════════ 라운드 5 — 수정 빌드 전면 재측정 (60초) ═══════════════
export BIN='$HOME/coherent-mr-v2/bin/memcached.permr'
say "라운드 5 시작 (68구성 · 60초)"

cell(){ # cell <label> <nqp> <ord> <mcT> <chain> <slots> <설명>
  local lbl=$1 nqp=$2 o=$3 m=$4 pc=$5 ss=$6 desc=$7
  SLOT=256 INLINE=1 AD=0 SS=$ss RE=8 PC=$pc SQ=1 DEM=0 DVAL=64 \
    NQP=$nqp ORD=$o MCT=$m CPUSET="0-$((m-1))" arm "$lbl" \
    || { say "무장 실패 $lbl"; echo "$lbl ARM-FAIL" >> "$SF/ariel/listen.log"; return 0; }
  go_trio "$lbl" "$m" 4 256 64 \
    "port_v4 b7fe2984 slot=256 nqp=$nqp ORD=${o/0/협상16} W=파생 slots=$ss chain=$pc mcT=$m — $desc" \
    "$([ "$m" != 30 ] && echo "**mtT=$m 로 맞춰라.**")"
  sfsave
}
wire(){ local ow=$2; [ "$2" = 0 ] && ow=16; echo $(( $1 * ow )); }
slots(){ local w; w=$(wire "$1" "$2"); [ $((w*2)) -gt 64 ] && echo $((w*2)) || echo 64; }

# 1 · 가드 시작점 (≥10M 게이트)
cell R5-OP 4 0 30 8 128 "가드 시작점"
# ≥10M 게이트 — 시작점이 10M 을 못 넘으면 격자 전체가 의미를 잃는다.
G0=$(ops_of R5-OP-GET 2>/dev/null || true)
if [ -n "$G0" ] && awk -v v="$G0" 'BEGIN{exit !(v+0 < 10)}'; then
  say "게이트 실패: R5-OP-GET=$G0 M (<10M) — 중단"
  { echo; echo "## [$(TZ=Asia/Seoul date +%F) KST] ariel — 라운드 5 중단"; echo;
    echo "\`R5-OP-GET\` 이 ${G0} M 으로 10M 게이트를 못 넘었다. 격자를 돌리지 않는다.";
    echo; echo "NEXT: 관리자"; } >> conversation.md
  git add -A conversation.md >/dev/null 2>&1; git commit -q -m "[ariel] round 5 halted at the 10M gate" 2>/dev/null
  git fetch -q origin main 2>/dev/null; git rebase -q origin/main >/dev/null 2>&1; git push -q 2>/dev/null
  exit 1
fi
say "게이트 통과: R5-OP-GET=${G0:-미확인} M"

# 2 · P 축 (클라만)
for p in 1 8 32 64 128 256 384 512; do
  go_trio "R5-P$p" 30 4 "$p" 64 \
    "port_v4 b7fe2984 운영점 서버 고정 — 클라 pipeline=$p" ; sfsave
done

# 3 · E 축 (클라만, c×pipe = 1024)
for cp in 1:1024 2:512 4:256 8:128 16:64 32:32 64:16 128:8; do
  c=${cp%%:*}; pp=${cp##*:}
  go_trio "R5-E${c}x${pp}" 30 "$c" "$pp" 64 \
    "port_v4 b7fe2984 운영점 서버 고정 — 클라 -c $c --pipeline $pp (곱 1024)"; sfsave
done

# 4 · D 축 (flush + 재프리로드)
for d in 4 8 16 24 32 48 64 96 128; do
  if flush_preload "$d"; then
    go_trio "R5-D$d" 30 4 256 "$d" \
      "port_v4 b7fe2984 운영점 서버 고정 — flush 후 d=$d 재프리로드" \
      "프리로드도 -d $d 다. 부하 -d 를 맞출 것."
  else say "R5-D$d 프리로드 실패"; fi
  sfsave
done
flush_preload 64 >/dev/null 2>&1 || say "d=64 복귀 실패"

# 5 · C 축 (span 분해 대상)
for c in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16; do
  cell "R5-C$c" 4 0 30 "$c" 128 "chain=$c (reap=8) — span 분해 대상"
done

# 6 · Q 축
for q in 1 2 4 8 16 64; do
  cell "R5-Q$q" "$q" 0 30 8 "$(slots "$q" 0)" "nqp=$q"
done

# 7 · O 축
for o in 1 2 4 8 0; do
  lbl="R5-O$o"; [ "$o" = 0 ] && lbl="R5-O16"
  cell "$lbl" 4 "$o" 30 8 "$(slots 4 "$o")" "ORD=$o"
done

# 8 · S 축 (wire 곱 256, nqp 상향 방향 — 발자국 동일)
for qo in 16:16 32:8 64:4 128:2 256:1; do
  q=${qo%%:*}; o=${qo##*:}
  cell "R5-S${q}x${o}" "$q" "$o" 30 8 512 "형태 ${q}×${o} (wire 256, slots 512 고정)"
done

# 9 · T 축
for m in 1 2 4 8 12 16 24 28 30; do
  cell "R5-T$m" 4 0 "$m" 8 128 "mcT=$m"
done

# 10 · 가드 끝점
cell R5-OP-r2 4 0 30 8 128 "가드 끝점 — R5-OP 와 동일 조건"
say "라운드 5 종료"
