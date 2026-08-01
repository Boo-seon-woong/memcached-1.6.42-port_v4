#!/usr/bin/env python3
"""연속 추적(trace.csv)을 셀·워크로드별 창으로 사후 절단한다.

  python3 tools/shape-slice.py trace.csv manifest.tsv > rows.tsv

실시간 판단이 없으므로 다시 돌려도 같은 결과가 나온다. 창 국소 span은
누적 평균을 `(avg×count)` 차분으로 되돌려 계산한다 — 리셋에 의존하지 않는다.

manifest.tsv 는 구동기가 셀마다 남기는 `cell<TAB>epoch`다. 그 시각은
**프리로드가 끝나고 GO를 올리기 직전**이라, 그 이후의 부하 평탄부만 보면
프리로드가 섞이지 않는다. 초판은 세그먼트 순서로 이름을 붙였다가 프리로드를
첫 워크로드로 세어 전부 한 칸씩 밀렸다.
"""
import sys, csv, os

WIN = float(os.environ.get("WIN", 30))   # 창 길이(초)
THRESH = 100_000    # 부하로 인정할 ops/s
NCPU = 30

def load(path):
    rows = []
    with open(path) as fh:
        for r in csv.DictReader(fh):
            try:
                rows.append({k: (float(v) if k == "ts" else int(v)) for k, v in r.items()})
            except (ValueError, TypeError):
                continue          # 잘린 마지막 줄 등
    return rows

def plateaus(rows):
    """부하가 THRESH를 넘는 연속 구간들. 카운터가 되돌아가면(재기동) 끊는다."""
    out, run = [], []
    for a, b in zip(rows, rows[1:]):
        dt = b["ts"] - a["ts"]
        if dt <= 0 or b["cmd_get"] < a["cmd_get"]:
            if run:
                out.append(run); run = []
            continue
        ops = ((b["cmd_get"] - a["cmd_get"]) + (b["cmd_set"] - a["cmd_set"])) / dt
        if ops >= THRESH:
            run.append(b)
        elif run:
            out.append(run); run = []
    if run:
        out.append(run)
    return [p for p in out if p[-1]["ts"] - p[0]["ts"] >= WIN * 0.6]

def window(run):
    """평탄부 가운데에서 WIN초를 잘라 (시작, 끝) 표본을 돌려준다."""
    span = run[-1]["ts"] - run[0]["ts"]
    pad = max(2.0, (span - WIN) / 2)
    lo = run[0]["ts"] + pad
    a = min(run, key=lambda r: abs(r["ts"] - lo))
    b = min(run, key=lambda r: abs(r["ts"] - (a["ts"] + WIN)))
    return (a, b) if b["ts"] - a["ts"] >= WIN * 0.5 else (run[0], run[-1])

def davg(a, b, avg_key, cnt_key):
    """누적 평균을 창 국소 평균으로 되돌린다."""
    dn = b[cnt_key] - a[cnt_key]
    if dn <= 0:
        return 0.0
    return (b[avg_key] * b[cnt_key] - a[avg_key] * a[cnt_key]) / dn / 1000.0

def main():
    rows = load(sys.argv[1])
    marks = []
    with open(sys.argv[2]) as fh:
        for line in fh:
            parts = line.split("\t")
            if len(parts) >= 2 and parts[1].strip().isdigit():
                marks.append((parts[0].strip(), float(parts[1])))

    # avg 는 (avg×count) 차분이라 창 국소값이다. p99 는 히스토그램에서 나오고
    # stats reset 으로만 초기화되므로 **기동 이후 누적**이다 — 차분할 수 없다.
    # 열 이름에 그대로 적어 둔다(GET-only 행의 Sspan_p99 가 수백 µs로 보이는
    # 것은 프리로드 SET 이 누적에 남아서다. 그 행에는 SET 자체가 없다).
    print("cell\tworkload\twindow_s\tget_s\tset_s\tGspan_avg\tGspan_p99_cum\t"
          "Sspan_avg\tSspan_p99_cum\tbusyCPU\ttotal_Mops\terr5\tbadcrc\thit_pct")

    for i, (cell, t0) in enumerate(marks):
        t1 = marks[i + 1][1] if i + 1 < len(marks) else float("inf")
        # manifest 시각은 프리로드 직후이므로, 그 뒤의 평탄부만이 genie 부하다.
        seg = [r for r in rows if t0 <= r["ts"] < t1]
        # 워크로드는 **순서가 아니라 구성으로** 판별한다. 중단된 실행의 GO가
        # 남아 genie가 한 칸 앞선 채로 시작하면 순서 기준은 전부 어긋난다.
        # get/set 비율은 그런 위상과 무관하다.
        by_kind = {}
        for run in plateaus(seg):
            a, b = window(run)
            dt = b["ts"] - a["ts"]
            if dt <= 0:
                continue
            g = (b["cmd_get"] - a["cmd_get"]) / dt
            s = (b["cmd_set"] - a["cmd_set"]) / dt
            tot = g + s
            if tot <= 0:
                continue
            kind = "W1" if s / tot < 0.01 else ("W3" if g / tot < 0.01 else "W2")
            by_kind[kind] = (a, b)      # 같은 종류가 둘이면 나중 것을 쓴다

        for kind in ("W1", "W2", "W3"):
            if kind not in by_kind:
                print(f"{cell}\t{kind}\tNOLOAD")
                continue
            a, b = by_kind[kind]
            dt = b["ts"] - a["ts"]
            g = (b["cmd_get"] - a["cmd_get"]) / dt
            s = (b["cmd_set"] - a["cmd_set"]) / dt
            dct = b["cpu_total"] - a["cpu_total"]
            dci = b["cpu_idle"] - a["cpu_idle"]
            busy = (dct - dci) / dct * NCPU if dct > 0 else 0
            dh = b["get_hits"] - a["get_hits"]
            dg = b["cmd_get"] - a["cmd_get"]
            print("\t".join([
                cell, kind, f"{dt:.3f}", f"{g:.0f}", f"{s:.0f}",
                f"{davg(a,b,'ravg','rcount'):.2f}", f"{b['rp99']/1000:.1f}",
                f"{davg(a,b,'wavg','wcount'):.2f}", f"{b['wp99']/1000:.1f}",
                f"{busy:.1f}", f"{(g+s)/1e6:.3f}",
                str(b["err5"] - a["err5"]), str(b["badcrc"] - a["badcrc"]),
                f"{(dh/dg*100) if dg else 0:.2f}"]))

if __name__ == "__main__":
    main()
