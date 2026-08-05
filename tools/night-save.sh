#!/usr/bin/env bash
# 창 데이터를 저장소에 남긴다. 채널에 요약만 올리고 원본을 /tmp 에 두면
# 게스트 재기동 한 번에 사라진다 — 오늘 밤 데이터는 전부 여기로 온다.
#
#   tools/night-save.sh            # 추적기 원본 + 전 셀 절단 결과
#
# 절단은 결정적이라(실시간 판단 없음) 다시 돌려도 같은 값이다. 원본을
# 남기는 이유가 그것이다 — 절단기를 고치면 과거 셀까지 다시 계산된다.
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd); cd "$ROOT"
D=experiments/night-20260806; mkdir -p "$D/ariel"
G="ssh -n -i $HOME/.ssh/snp_guest -p 2222 -o BatchMode=yes -o ConnectTimeout=8 ubuntu@localhost"

scp -q -i "$HOME/.ssh/snp_guest" -P 2222 ubuntu@localhost:/tmp/night/trace.csv "$D/ariel/trace.csv"
$G 'test -f /tmp/night/trace-e0dem0.csv' 2>/dev/null &&
  scp -q -i "$HOME/.ssh/snp_guest" -P 2222 ubuntu@localhost:/tmp/night/trace-e0dem0.csv "$D/ariel/trace-e0dem0.csv" || true

# E0-DEM0 은 추적기 확장 전(26열) 파일에 있다. 두 원본을 각각 잘라 합친다.
{
  if [ -f "$D/ariel/trace-e0dem0.csv" ]; then
    printf 'E0-DEM0\t1785949686\n' > /tmp/night-m0.tsv
    python3 tools/night-slice.py "$D/ariel/trace-e0dem0.csv" /tmp/night-m0.tsv
  fi
  python3 tools/night-slice.py "$D/ariel/trace.csv" "$D/manifest.tsv" | tail -n +2
} > "$D/rows.tsv"

# 무장 지문도 셀별로 남긴다 — 어떤 구성으로 잰 행인지가 행 자체에는 없다.
mkdir -p "$D/ariel/arm"
for f in /tmp/night-arm-*.txt; do [ -f "$f" ] && cp -f "$f" "$D/ariel/arm/" || true; done

n=$(( $(wc -l < "$D/rows.tsv") - 1 ))
echo "saved: rows=$n  trace=$(wc -l < "$D/ariel/trace.csv") 줄  arm=$(ls "$D/ariel/arm" | wc -l) 개"
