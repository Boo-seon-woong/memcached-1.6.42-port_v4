#!/usr/bin/env python3
"""EXP-0 트레이스에서 부하 창을 찾아 v3 span 3성분을 창 국소값으로 복원한다.

prof 평균은 누적이라 그대로 읽으면 이전 창이 섞인다. `(avg×count)` 를 차분해
창 안에서만 발생한 합을 얻는다. admit/ret 은 자기 count 가 없고 같은 op 가
e2e 도 기록하므로 e2e count 를 나눗수로 쓴다.

    python3 exp0-slice.py trace.csv
"""
import sys, csv

COLS = "ts cmd_get cmd_set get_hits get_misses rcount ravg rp99 wcount wavg wp99 badcrc err5 cpu_total cpu_idle re2ec re2ea re2ep99 we2ec we2ea we2ep99 radmit wadmit wret".split()

rows = []
with open(sys.argv[1]) as f:
    for r in csv.DictReader(f):
        if not r.get("re2ec"):        # v3 열이 없는 옛 행은 버린다
            continue
        rows.append({k: float(r[k]) for k in COLS})

# 초당 op 로 부하 구간을 찾는다. 유휴는 0 에 가깝다.
IDLE = 100_000
segs, cur = [], []
for a, b in zip(rows, rows[1:]):
    dt = b["ts"] - a["ts"]
    ops = ((b["cmd_get"] - a["cmd_get"]) + (b["cmd_set"] - a["cmd_set"])) / dt if dt > 0 else 0
    if ops > IDLE:
        cur.append((a, b))
    elif cur:
        segs.append(cur); cur = []
if cur:
    segs.append(cur)


def local(a, b, sum_key, cnt_key):
    """누적 평균 두 점에서 창 국소 평균(µs). 관측이 없으면 None."""
    dn = b[cnt_key] - a[cnt_key]
    if dn <= 0:
        return None
    ds = b[sum_key] * b[cnt_key] - a[sum_key] * a[cnt_key]
    return ds / dn / 1000.0


print(f"{'#':>2} {'초':>4} {'ops/s':>9} {'GET%':>5} "
      f"{'Gv3':>8} {'=adm':>7} {'+v2':>7}   "
      f"{'Sv3':>9} {'=adm':>6} {'+v2':>6} {'+ret':>9}  {'busy':>5}")

for i, seg in enumerate(segs, 1):
    if len(seg) < 5:
        continue
    # 양 끝 2초는 상승·하강이 섞이므로 버린다
    a, b = seg[2][0], seg[-3][1]
    dt = b["ts"] - a["ts"]
    dg, ds = b["cmd_get"] - a["cmd_get"], b["cmd_set"] - a["cmd_set"]
    ops = (dg + ds) / dt
    getpct = 100 * dg / (dg + ds) if dg + ds else 0

    gv3 = local(a, b, "re2ea", "re2ec")
    gadm = local(a, b, "radmit", "re2ec")
    gv2 = local(a, b, "ravg", "rcount")
    sv3 = local(a, b, "we2ea", "we2ec")
    sadm = local(a, b, "wadmit", "we2ec")
    sv2 = local(a, b, "wavg", "wcount")
    sret = local(a, b, "wret", "we2ec")

    dct, di = b["cpu_total"] - a["cpu_total"], b["cpu_idle"] - a["cpu_idle"]
    busy = (dct - di) / dct * 30 if dct else 0

    def f(x, w=8, p=2):
        return f"{x:>{w}.{p}f}" if x is not None else " " * (w - 1) + "-"

    print(f"{i:>2} {dt:>4.0f} {ops/1e6:>8.3f}M {getpct:>4.0f}% "
          f"{f(gv3)} {f(gadm,7)} {f(gv2,7)}   "
          f"{f(sv3,9)} {f(sadm,6)} {f(sv2,6)} {f(sret,9)}  {busy:>5.1f}")
