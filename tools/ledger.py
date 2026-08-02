#!/usr/bin/env python3
"""전 캠페인 셀 원장. 추가·요약·블록별 표를 한 곳에서 낸다.

86 셀을 산문으로 추적하면 옮겨 적다가 틀린다. 슬라이스 출력에서 바로
붙여넣고, 판정은 이 파일에서만 읽는다.

  ledger.py add <block> <cell> <workload> <ops> [span adm v2 [sspan sadm sv2 sret]] [-n 메모]
  ledger.py show [block]
  ledger.py cmp <cell> [<cell> ...]      기준(BASE-gate) 대비 σ 로 비교
"""
import argparse
import csv
import statistics as st
from pathlib import Path

CSV = Path(__file__).resolve().parent.parent / "experiments/full-20260803/cells.csv"
COLS = ["block", "cell", "workload", "ops_M", "span", "adm", "v2",
        "set_span", "set_adm", "set_v2", "set_ret", "note"]
# 이 세션에서 측정한 재현성 — 델타 판정의 자
SIGMA = {"get": 1.01, "mix": 1.04}          # %
SIGMA_SPAN = 0.60                            # %


def rows():
    if not CSV.exists():
        return []
    with CSV.open(encoding="utf-8") as f:
        return [r for r in csv.DictReader(f) if r.get("cell")]


def write(rs):
    CSV.parent.mkdir(parents=True, exist_ok=True)
    with CSV.open("w", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, fieldnames=COLS)
        w.writeheader()
        w.writerows(rs)


def add(a):
    rs = rows()
    # span·adm·v2·set_span·set_adm·set_v2·set_ret 일곱 자리다. 여덟로 채우면
    # zip 이 COLS 를 넘겨 note 가 잘린다.
    vals = (a.values + [""] * 7)[:7]
    rs.append(dict(zip(COLS, [a.block, a.cell, a.workload, a.ops] + vals + [a.note or ""])))
    write(rs)
    print(f"+ {a.block} {a.cell} {a.workload} {a.ops}")


def fnum(r, k):
    try:
        return float(r[k])
    except (TypeError, ValueError):
        return None


def show(block=None):
    rs = [r for r in rows() if block is None or r["block"] == block]
    if not rs:
        print("없음")
        return
    print(f"{'blk':>3s} {'cell':16s} {'wl':4s} {'ops M':>8s} {'span':>7s} "
          f"{'adm':>6s} {'v2':>6s} {'SET':>6s}  메모")
    for r in rs:
        g = lambda k: (f"{fnum(r,k):.2f}" if fnum(r, k) is not None else "")
        print(f"{r['block']:>3s} {r['cell']:16s} {r['workload']:4s} "
              f"{fnum(r,'ops_M') or 0:8.3f} {g('span'):>7s} {g('adm'):>6s} "
              f"{g('v2'):>6s} {g('set_span'):>6s}  {r['note']}")


def cmp_(cells):
    rs = rows()
    base = {w: [fnum(r, "ops_M") for r in rs
                if r["cell"] == "BASE-gate" and r["workload"] == w]
            for w in ("get", "mix")}
    for w in ("get", "mix"):
        b = base[w]
        if not b:
            continue
        bm = st.mean(b)
        print(f"\n[{w}] 기준 {bm:.3f} M   (σ {SIGMA[w]}%)")
        for c in cells:
            v = [fnum(r, "ops_M") for r in rs
                 if r["cell"] == c and r["workload"] == w]
            if not v:
                continue
            m = st.mean(v)
            d = (m - bm) / bm * 100
            print(f"  {c:16s} n={len(v)} {m:8.3f} {d:+6.2f}%  {d/SIGMA[w]:+5.2f}σ")


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("add")
    p.add_argument("block"); p.add_argument("cell"); p.add_argument("workload")
    p.add_argument("ops", type=float)
    p.add_argument("values", nargs="*")
    p.add_argument("-n", "--note", default="")
    s = sub.add_parser("show"); s.add_argument("block", nargs="?")
    c = sub.add_parser("cmp"); c.add_argument("cells", nargs="+")
    a = ap.parse_args()
    if a.cmd == "add":
        add(a)
    elif a.cmd == "show":
        show(a.block)
    else:
        cmp_(a.cells)
