#!/bin/bash
# off-box 샘플 로그에서 임의 구간을 잘라 서버 측 지표를 낸다.
#
# 사용: bash tools/obslice.sh <start_utc> <end_utc> [label]
#   시각은 'YYYY-MM-DDTHH:MM:SSZ' 또는 unix epoch.
# genie가 보고한 런 창을 그대로 넣으면 그 구간의 throughput과 CPU/op가 나온다.
set -u
LOG=${LOG:-/tmp/ob_samples.tsv}
to_epoch() { case "$1" in ''|*[!0-9]*) date -u -d "$1" +%s;; *) echo "$1";; esac; }
S=$(to_epoch "$1"); E=$(to_epoch "$2"); LABEL=${3:-window}

awk -v s="$S" -v e="$E" -v lab="$LABEL" -F'\t' '
NR==1 { next }
$1 >= s && $1 <= e {
  if (n == 0) { g0=$4; h0=$5; c0=$3; t0=$1; we0=$9 }
  g1=$4; h1=$5; c1=$3; t1=$1; we1=$9
  busy += $2; ra += $7; rp += $8; n++
}
END {
  if (n < 2) { printf "%s: 구간에 샘플 %d개 — 부족\n", lab, n; exit 1 }
  dt = t1 - t0; dg = g1 - g0; dh = h1 - h0; dc = c1 - c0
  printf "%-14s  %6.3fM/s  hit %5.1f%%  span avg %6.2fus p99 %6.1fus  mc_cpu %.3f us/op  guest busy %.1f cpu  wait_enq +%.1fM  (%ds, %d샘플)\n", \
    lab, dg/dt/1e6, (dg>0)?dh/dg*100:0, ra/n/1000, rp/n/1000, (dg>0)?dc/dg*1e6:0, busy/n, (we1-we0)/1e6, dt, n
}' "$LOG"
