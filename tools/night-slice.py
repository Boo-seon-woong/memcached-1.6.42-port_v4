#!/usr/bin/env python3
"""야간 캠페인 절단기 — 평탄부 하나 = 행 하나, 세 계층 전부.

  python3 tools/night-slice.py trace.csv manifest.tsv > rows.tsv

shape-slice.py 와 다른 점 셋:
  ① W1/W2/W3 로 묶지 않는다. 같은 워크로드를 pipe 만 바꿔 여러 번 도는
     셀(E0, exp1 스윕)이 있어 종류로 묶으면 마지막 것만 남는다.
  ② span 은 v3(e2e)가 기본이다. v2 는 성분으로만 낸다.
  ③ 계층 2(xfer/crypto/sync)·3(srv/que/bk)을 같이 낸다.
p50/p99 는 히스토그램이라 차분이 안 된다 — 추적기가 부하 시작마다 stats reset
을 내므로 창 국소값이고, 리셋이 없었으면 그 값은 앞 셀이 섞인 누적이다.
"""
import sys, csv, os

THRESH = float(os.environ.get("THRESH", 100_000))
MINSPAN = float(os.environ.get("MINSPAN", 8))   # 평탄부 최소 길이(초)
NCPU = int(os.environ.get("NCPU", 30))

def load(path):
    rows = []
    for r in csv.DictReader(open(path)):
        try:
            rows.append({k: (float(v) if k == "ts" else int(v)) for k, v in r.items()})
        except (ValueError, TypeError):
            continue
    return rows

def plateaus(rows):
    out, run = [], []
    for a, b in zip(rows, rows[1:]):
        dt = b["ts"] - a["ts"]
        back = b["cmd_get"] < a["cmd_get"] or b["cmd_set"] < a["cmd_set"]
        if dt <= 0 or back:
            if run: out.append(run)
            run = []
            continue
        ops = ((b["cmd_get"] - a["cmd_get"]) + (b["cmd_set"] - a["cmd_set"])) / dt
        if ops >= THRESH: run.append(b)
        elif run: out.append(run); run = []
    if run: out.append(run)
    return [p for p in out if p[-1]["ts"] - p[0]["ts"] >= MINSPAN]

def davg(a, b, avg, cnt):
    """옛 26열 추적기 파일도 읽을 수 있게 없는 열은 0 으로 본다."""
    if avg not in b or cnt not in b: return 0.0
    dn = b[cnt] - a[cnt]
    return (b[avg] * b[cnt] - a[avg] * a[cnt]) / dn / 1000.0 if dn > 0 else 0.0

def dsimple(a, b, key, cnt):
    """count 가 따로 없는 avg 열(admit/ret/xfer/…). e2e count 로 가중 차분."""
    if key not in b or cnt not in b: return 0.0
    dn = b[cnt] - a[cnt]
    return (b[key] * b[cnt] - a[key] * a[cnt]) / dn / 1000.0 if dn > 0 else 0.0

COLS = ("label seq secs Mops get_s set_s busy "
        "Gv3_avg Gv3_p50 Gv3_p99 Gadmit Gv2 Gxfer Gcrypto Gsync "
        "Sv3_avg Sv3_p50 Sv3_p99 Sadmit Sv2 Sret Sxfer Scrypto "
        "srv srv_p50 srv_p99 que bk err5 badcrc hit_pct").split()

def main():
    rows = load(sys.argv[1])
    marks = []
    for line in open(sys.argv[2]):
        p = line.split("\t")
        if len(p) >= 2 and p[1].strip().isdigit():
            marks.append((p[0].strip(), float(p[1])))
    print("\t".join(COLS))
    for i, (label, t0) in enumerate(marks):
        t1 = marks[i + 1][1] if i + 1 < len(marks) else float("inf")
        seg = [r for r in rows if t0 <= r["ts"] < t1]
        for n, run in enumerate(plateaus(seg), 1):
            a, b = run[0], run[-1]
            dt = b["ts"] - a["ts"]
            if dt <= 0: continue
            g = (b["cmd_get"] - a["cmd_get"]) / dt
            s = (b["cmd_set"] - a["cmd_set"]) / dt
            dct, dci = b["cpu_total"] - a["cpu_total"], b["cpu_idle"] - a["cpu_idle"]
            busy = (dct - dci) / dct * NCPU if dct > 0 else 0
            dg, dh = b["cmd_get"] - a["cmd_get"], b["get_hits"] - a["get_hits"]
            out = [label, str(n), f"{dt:.1f}", f"{(g+s)/1e6:.3f}", f"{g:.0f}", f"{s:.0f}", f"{busy:.1f}",
                   f"{davg(a,b,'re2ea','re2ec'):.2f}", f"{b['re2ep99'] and b['re2ec'] and 0 or 0:.0f}", "",
                   f"{dsimple(a,b,'radmit','re2ec'):.2f}", f"{davg(a,b,'ravg','rcount'):.2f}",
                   f"{dsimple(a,b,'rxfer','rcount'):.2f}", f"{dsimple(a,b,'rcrypto','rcount'):.2f}",
                   f"{dsimple(a,b,'rsync','rcount'):.2f}",
                   f"{davg(a,b,'we2ea','we2ec'):.2f}", "", "",
                   f"{dsimple(a,b,'wadmit','we2ec'):.2f}", f"{davg(a,b,'wavg','wcount'):.2f}",
                   f"{dsimple(a,b,'wret','we2ec'):.2f}",
                   f"{dsimple(a,b,'wxfer','wcount'):.2f}", f"{dsimple(a,b,'wcrypto','wcount'):.2f}",
                   f"{davg(a,b,'srva','srvc'):.2f}", f"{b.get('srvp50',0)/1000:.1f}", f"{b.get('srvp99',0)/1000:.1f}",
                   f"{davg(a,b,'quea','quec'):.2f}", f"{davg(a,b,'bka','bkc'):.2f}",
                   str(b["err5"] - a["err5"]), str(b["badcrc"] - a["badcrc"]),
                   f"{(dh/dg*100) if dg else 0:.2f}"]
            # p50/p99 는 누적(리셋 이후)이라 창 끝 값을 그대로 쓴다.
            g50 = b.get('re2ep50', 0); s50 = b.get('we2ep50', 0)
            out[8] = f"{g50/1000:.1f}"; out[9] = f"{b.get('re2ep99',0)/1000:.1f}"
            out[16] = f"{s50/1000:.1f}"; out[17] = f"{b.get('we2ep99',0)/1000:.1f}"
            print("\t".join(out))

main()
