#!/usr/bin/env python3
"""osdi 그림 생성 — 명세는 experiments/osdi-0804/FIGURES.md.

  python3 tools/plot-osdi.py [--rows ...] [--out img/osdi-20260806]

의존성 없음. SVG 를 직접 쓴다(tools/plot-frontier-v4.py 와 같은 방식 —
게스트·CI 어디서든 돌아야 해서 matplotlib 을 안 쓴다).

지금 데이터가 있는 것만 그린다: F2b(분해 스택), F2c(v3↔v4), F3(값 크기),
F4a/F4b/F4c(배칭). F1 은 stock 계열이 들어온 뒤에 추가한다.
"""
import argparse, math
from pathlib import Path

W, H = 760, 420
PAD = dict(l=78, r=58, t=46, b=54)
C = dict(v4="#2563eb", v3="#dc2626", get="#2563eb", mix="#ea580c", set="#16a34a",
         que="#cbd5e1", pre="#94a3b8", span="#1d4ed8", post="#fca5a5", grid="#e5e7eb",
         ink="#0f172a", mute="#64748b")


def load(path):
    rows = [l.rstrip("\n").split("\t") for l in open(path) if l.strip()]
    head, body = rows[0], rows[1:]
    return [dict(zip(head, r)) for r in body]


def load_client(path="experiments/night-20260806/client.tsv"):
    """genie 보고에서 뽑은 셀별 클라이언트 지연. 없으면 빈 dict."""
    try:
        rows = load(path)
    except OSError:
        return {}
    return {r["cell"]: r for r in rows}


def num(r, k, d=0.0):
    try:
        return float(r[k])
    except (KeyError, ValueError):
        return d


class Svg:
    def __init__(self, w=W, h=H, title=""):
        self.w, self.h, self.p = w, h, []
        self.p.append(f'<svg xmlns="http://www.w3.org/2000/svg" width="{w}" height="{h}" '
                      f'viewBox="0 0 {w} {h}" font-family="Helvetica,Arial,sans-serif">')
        self.p.append(f'<rect width="{w}" height="{h}" fill="white"/>')
        if title:
            self.txt(w / 2, 24, title, 15, C["ink"], "middle", 600)

    def txt(self, x, y, s, size=11, fill=None, anchor="start", weight=400):
        self.p.append(f'<text x="{x:.1f}" y="{y:.1f}" font-size="{size}" '
                      f'fill="{fill or C["ink"]}" text-anchor="{anchor}" '
                      f'font-weight="{weight}">{s}</text>')

    def line(self, x1, y1, x2, y2, stroke=None, w=1, dash=None):
        d = f' stroke-dasharray="{dash}"' if dash else ""
        self.p.append(f'<line x1="{x1:.1f}" y1="{y1:.1f}" x2="{x2:.1f}" y2="{y2:.1f}" '
                      f'stroke="{stroke or C["grid"]}" stroke-width="{w}"{d}/>')

    def path(self, pts, stroke, w=2, dash=None):
        if len(pts) < 2:
            return
        d = "M " + " L ".join(f"{x:.1f},{y:.1f}" for x, y in pts)
        da = f' stroke-dasharray="{dash}"' if dash else ""
        self.p.append(f'<path d="{d}" fill="none" stroke="{stroke}" stroke-width="{w}"{da}/>')

    def dot(self, x, y, fill, r=3.6, hollow=False):
        f = "white" if hollow else fill
        self.p.append(f'<circle cx="{x:.1f}" cy="{y:.1f}" r="{r}" fill="{f}" '
                      f'stroke="{fill}" stroke-width="1.6"/>')

    def rect(self, x, y, w, h, fill):
        if h <= 0:
            return
        self.p.append(f'<rect x="{x:.1f}" y="{y:.1f}" width="{w:.1f}" height="{h:.1f}" '
                      f'fill="{fill}"/>')

    def save(self, p):
        self.p.append("</svg>")
        Path(p).write_text("\n".join(self.p))
        print(f"  {p}")


def axes(s, xlab, ylab, y2lab=None):
    l, r, t, b = PAD["l"], s.w - PAD["r"], PAD["t"], s.h - PAD["b"]
    s.line(l, b, r, b, C["ink"])
    s.line(l, t, l, b, C["ink"])
    s.txt((l + r) / 2, s.h - 14, xlab, 12, C["ink"], "middle")
    s.p.append(f'<text x="18" y="{(t+b)/2:.1f}" font-size="12" fill="{C["ink"]}" '
               f'text-anchor="middle" transform="rotate(-90 18 {(t+b)/2:.1f})">{ylab}</text>')
    if y2lab:
        s.p.append(f'<text x="{s.w-14}" y="{(t+b)/2:.1f}" font-size="12" fill="{C["mute"]}" '
                   f'text-anchor="middle" transform="rotate(90 {s.w-14} {(t+b)/2:.1f})">{y2lab}</text>')
    return l, r, t, b


def logmap(v, lo, hi, a, b):
    v = max(v, lo)
    return a + (b - a) * (math.log10(v) - math.log10(lo)) / (math.log10(hi) - math.log10(lo))


def linmap(v, lo, hi, a, b):
    return a + (b - a) * (v - lo) / (hi - lo) if hi > lo else a


# ── F2b: 분해 스택 ────────────────────────────────────────────────────────
def f2b(rows, out):
    pipes = [1, 8, 32, 64, 128, 256, 384]
    for tag, sl, title in (("get", slice(2, 9), "GET-only"), ("mix", slice(9, 16), "1:9 혼합")):
        bd = [r for r in rows if r["label"] == "BD2-b"][sl]
        if len(bd) < 7:
            continue
        s = Svg(title=f"F2b — 서버 체류 분해, {title} (v4, 60초 셀)")
        l, r, t, b = axes(s, "pipeline", "µs (로그)")
        lo, hi = 0.2, 2000
        for gv in (1, 10, 100, 1000):
            y = logmap(gv, lo, hi, b, t)
            s.line(l, y, r, y, C["grid"])
            s.txt(l - 8, y + 4, str(gv), 10, C["mute"], "end")
        bw = (r - l) / len(pipes) * 0.52
        for i, (p, row) in enumerate(zip(pipes, bd)):
            x = l + (r - l) * (i + 0.5) / len(pipes) - bw / 2
            srv, que, bk = num(row, "srv"), num(row, "que"), num(row, "bk")
            span = num(row, "Gv3_avg")
            pre, post = srv - que - bk, bk - span
            acc = 0.0
            for val, col, _ in ((que, C["que"], "que"), (max(pre, 0.01), C["pre"], "pre"),
                                (span, C["span"], "span v3"), (max(post, 0), C["post"], "post")):
                y0 = logmap(max(acc, lo), lo, hi, b, t)
                acc += val
                y1 = logmap(max(acc, lo), lo, hi, b, t)
                s.rect(x, y1, bw, y0 - y1, col)
            s.txt(x + bw / 2, logmap(max(acc, lo), lo, hi, b, t) - 6, f"{srv:.0f}", 9,
                  C["ink"], "middle", 600)
            s.txt(x + bw / 2, b + 16, str(p), 10, C["ink"], "middle")
        for i, (nm, col) in enumerate((("que", C["que"]), ("pre", C["pre"]),
                                       ("span v3 (계약)", C["span"]), ("post", C["post"]))):
            s.rect(l + 10 + i * 108, t - 22, 11, 11, col)
            s.txt(l + 26 + i * 108, t - 12, nm, 10, C["ink"])
        s.save(f"{out}/f2b-{tag}.svg")


# ── F2c: v3 ↔ v4 ─────────────────────────────────────────────────────────
def f2c(rows, out):
    pipes = [1, 8, 32, 64, 128, 256, 384]
    v4 = [r for r in rows if r["label"] == "BD2-b"][2:9]
    v3 = [r for r in rows if r["label"] == "BD3"][0:7]
    if len(v3) < 7 or len(v4) < 7:
        return
    s = Svg(title="F2c — port_v3 ↔ port_v4, 같은 격자 (GET-only, 60초)")
    l, r, t, b = axes(s, "pipeline", "span v3 (µs, 로그)", "srv (µs)")
    lo, hi = 8, 1200
    for gv in (10, 100, 1000):
        y = logmap(gv, lo, hi, b, t)
        s.line(l, y, r, y, C["grid"])
        s.txt(l - 8, y + 4, str(gv), 10, C["mute"], "end")
    xs = [l + (r - l) * (i + 0.5) / len(pipes) for i in range(len(pipes))]
    for rowset, col, nm in ((v3, C["v3"], "v3 span"), (v4, C["v4"], "v4 span")):
        pts = [(x, logmap(num(rw, "Gv3_avg"), lo, hi, b, t)) for x, rw in zip(xs, rowset)]
        s.path(pts, col, 2.2)
        for (x, y) in pts:
            s.dot(x, y, col)
    for rowset, col, dash in ((v3, C["v3"], "4 3"), (v4, C["v4"], "4 3")):
        pts = [(x, logmap(num(rw, "srv"), lo, hi, b, t)) for x, rw in zip(xs, rowset)]
        s.path(pts, col, 1.4, dash)
    for x, p in zip(xs, pipes):
        s.txt(x, b + 16, str(p), 10, C["ink"], "middle")
    s.txt(l + 10, t - 12, "실선 = span v3   파선 = srv(서버 체류)", 10, C["mute"])
    s.txt(l + 10, t + 4, "빨강 v3 · 파랑 v4", 10, C["mute"])
    s.save(f"{out}/f2c-v3-v4.svg")


# ── F3: 값 크기 ──────────────────────────────────────────────────────────
def f3(rows, out):
    sizes = [16, 32, 64, 152]
    pts = []
    for d in sizes:
        rw = [r for r in rows if r["label"] == f"V{d}" and r["seq"] == "1"]
        if rw:
            m, busy = num(rw[0], "Mops"), num(rw[0], "busy")
            pts.append((d, busy / m if m else 0, m, num(rw[0], "Gxfer"), num(rw[0], "Gcrypto")))
    if len(pts) < 3:
        return
    s = Svg(title="F3 — 값 크기: CPU/op 는 아핀이다 (2.00 µs + 4.05 ns/B)")
    l, r, t, b = axes(s, "값 크기 (B)", "CPU/op (µs)", "성분 (µs)")
    ylo, yhi = 1.9, 2.8
    for gv in (2.0, 2.2, 2.4, 2.6, 2.8):
        y = linmap(gv, ylo, yhi, b, t)
        s.line(l, y, r, y, C["grid"])
        s.txt(l - 8, y + 4, f"{gv:.1f}", 10, C["mute"], "end")
    fx = lambda d: linmap(d, 0, 160, l, r)
    s.path([(fx(0), linmap(2.00, ylo, yhi, b, t)),
            (fx(160), linmap(2.00 + 0.00405 * 160, ylo, yhi, b, t))], C["mute"], 1.4, "5 4")
    for d, cpo, m, xf, cr in pts:
        x, y = fx(d), linmap(cpo, ylo, yhi, b, t)
        s.dot(x, y, C["get"], 4.2)
        s.txt(x, y - 10, f"{cpo:.3f}", 9, C["ink"], "middle")
        s.txt(x, b + 16, str(d), 10, C["ink"], "middle")
        s.txt(x, b + 30, f"{m:.2f}M", 9, C["mute"], "middle")
    x0 = fx(pts[0][0])
    s.txt(x0, t + 6, "파선 = 최소제곱 2.00 + 0.00405·B (잔차 2% 안)", 10, C["mute"])
    s.txt(x0, t + 22, f"xfer {pts[0][3]:.2f}→{pts[-1][3]:.2f}   "
                      f"crypto {pts[0][4]:.2f}→{pts[-1][4]:.2f}  ← 바이트 비용은 전송이다",
          10, C["mute"])
    s.save(f"{out}/f3-value-size.svg")


# ── F4a/b/c: 배칭 ────────────────────────────────────────────────────────
def cell(rows, label, seq="1"):
    rw = [r for r in rows if r["label"] == label and r["seq"] == seq]
    return rw[0] if rw else None


def f4(rows, out):
    chain = [1, 2, 4, 8, 12, 16]
    # c8 은 재시행값(BD2-b seq1)을 쓴다 — 첫 셀이 낮았다
    rep = cell(rows, "BD2-b", "1")
    cs = []
    for c in chain:
        rw = cell(rows, f"E4-C{c}R8")
        if c == 8 and rep:
            rw = rep
        if rw:
            cs.append((c, rw))
    if len(cs) >= 5:
        s = Svg(title="F4a — 같은 노브, 반대 부호 (chain 축, reap=8)")
        l, r, t, b = axes(s, "ext_post_chain", "span v3 (µs)", "srv (µs)")
        for gv in (5, 10, 15, 20, 25):
            y = linmap(gv, 0, 26, b, t)
            s.line(l, y, r, y, C["grid"])
            s.txt(l - 8, y + 4, str(gv), 10, C["mute"], "end")
        xs = [l + (r - l) * (i + 0.5) / len(cs) for i in range(len(cs))]
        sp = [(x, linmap(num(rw, "Gv3_avg"), 0, 26, b, t)) for x, (_, rw) in zip(xs, cs)]
        s.path(sp, C["v4"], 2.2)
        for p in sp:
            s.dot(p[0], p[1], C["v4"])
        sv = [(x, linmap(num(rw, "srv"), 480, 700, b, t)) for x, (_, rw) in zip(xs, cs)]
        s.path(sv, C["mix"], 2.2, "5 4")
        for p in sv:
            s.dot(p[0], p[1], C["mix"], 3.2, True)
        for x, (c, rw) in zip(xs, cs):
            s.txt(x, b + 16, str(c), 10, C["ink"], "middle")
            s.txt(x, b + 30, f"{num(rw,'Mops'):.2f}M", 9, C["mute"], "middle")
        s.txt(l + 10, t - 12, "실선(왼쪽 축) span v3 ↑   파선(오른쪽) srv ↓  — 같은 노브에 반대 부호",
              10, C["mute"])
        s.save(f"{out}/f4a-chain-opposite.svg")

    # F4b: admit 대칭 / v2 비대칭
    mins, ca, ra, cv, rv = [], [], [], [], []
    for k in (1, 2, 4, 8):
        a = cell(rows, f"E4-C{k}R8") if k != 8 else rep
        bq = cell(rows, f"E4-C8R{k}") if k != 8 else rep
        if a and bq:
            mins.append(k)
            ca.append(num(a, "Gadmit")); ra.append(num(bq, "Gadmit"))
            cv.append(num(a, "Gv2"));    rv.append(num(bq, "Gv2"))
    if len(mins) >= 3:
        s = Svg(title="F4b — admit 은 대칭, v2 는 비대칭")
        l, r, t, b = axes(s, "유효 배치 min(chain, reap)", "µs")
        for gv in (0, 5, 10, 15, 20):
            y = linmap(gv, 0, 20, b, t)
            s.line(l, y, r, y, C["grid"])
            s.txt(l - 8, y + 4, str(gv), 10, C["mute"], "end")
        xs = [l + (r - l) * (i + 0.5) / len(mins) for i in range(len(mins))]
        for vals, col, dash, nm in ((ca, C["v4"], None, "admit · chain 축"),
                                    (ra, C["v4"], "4 3", "admit · reap 축"),
                                    (cv, C["mix"], None, "v2 · chain 축"),
                                    (rv, C["mix"], "4 3", "v2 · reap 축")):
            pts = [(x, linmap(v, 0, 20, b, t)) for x, v in zip(xs, vals)]
            s.path(pts, col, 2.0, dash)
            for p in pts:
                s.dot(p[0], p[1], col, 3.2, dash is not None)
        for x, k in zip(xs, mins):
            s.txt(x, b + 16, str(k), 10, C["ink"], "middle")
        s.txt(l + 10, t - 12, "파랑 admit — 두 축이 포개진다(트리거 B)   주황 v2 — 갈라진다(reap 전용)",
              10, C["mute"])
        s.save(f"{out}/f4b-two-knobs.svg")

    # F4c: 계약 회랑
    if len(cs) >= 5:
        s = Svg(title="F4c — 계약 회랑의 아래 끝은 chain 1~2 사이")
        l, r, t, b = axes(s, "ext_post_chain", "처리량 (M ops/s)")
        for gv in (8, 10, 12, 14):
            y = linmap(gv, 8, 14, b, t)
            s.line(l, y, r, y, C["grid"])
            s.txt(l - 8, y + 4, str(gv), 10, C["mute"], "end")
        y10 = linmap(10, 8, 14, b, t)
        s.line(l, y10, r, y10, C["set"], 1.6, "6 4")
        s.txt(r - 4, y10 - 6, "계약 10 M", 10, C["set"], "end")
        xs = [l + (r - l) * (i + 0.5) / len(cs) for i in range(len(cs))]
        for key, col, nm in (("Mops", C["get"], "GET-only"),):
            pts = [(x, linmap(num(rw, key), 8, 14, b, t)) for x, (_, rw) in zip(xs, cs)]
            s.path(pts, col, 2.2)
            for p in pts:
                s.dot(p[0], p[1], col)
        mixv = []
        for c, _ in cs:
            rw = cell(rows, f"E4-C{c}R8", "2") if c != 8 else cell(rows, "BD2-b", "2")
            mixv.append(num(rw, "Mops") if rw else 0)
        pts = [(x, linmap(v, 8, 14, b, t)) for x, v in zip(xs, mixv) if v]
        s.path(pts, C["mix"], 2.2)
        for p in pts:
            s.dot(p[0], p[1], C["mix"])
        for x, (c, _) in zip(xs, cs):
            s.txt(x, b + 16, str(c), 10, C["ink"], "middle")
        s.txt(l + 10, t - 12, "파랑 GET-only · 주황 1:9 혼합 — 혼합만 chain=1 에서 미달", 10, C["mute"])
        s.save(f"{out}/f4c-corridor.svg")


# ── F1: exp1 local vs remote (명세: x=처리량, y=클라이언트 지연) ──────────
def f1(rows, out):
    cl = load_client()
    if not cl:
        print("  F1 건너뜀 (client.tsv 없음 — tools/parse-client.py 먼저)")
        return
    pipes = [1, 8, 32, 64, 128, 256, 384]
    for wl, nm in (("A", "YCSB A (1:1, 쓰기 50%)"), ("B", "YCSB B (1:19, 쓰기 5%)"),
                   ("C", "YCSB C (0:1, 읽기 100%)")):
        series = {}
        for side, tag in (("ST", "stock (로컬)"), ("PT", "port (원격)")):
            pts = []
            for p_ in pipes:
                c = cl.get(f"{side}-{wl}-P{p_}")
                if c and c["avg_ms"]:
                    pts.append((float(c["ops_M"]), float(c["avg_ms"]), p_))
            if pts:
                series[side] = pts
        if len(series) < 2:
            continue
        zp = {side: cl.get(f"{'PTZ' if side=='PT' else 'ST'}-{wl}-Z256")
              for side in ("ST", "PT")}
        s2 = Svg(title=f"F1 — local(stock) vs remote(port), {nm}")
        l, r, t, b = axes(s2, "처리량 (M ops/s)", "클라이언트 지연 avg (ms, 로그)")
        xhi = max(max(x for x, _, _ in v) for v in series.values()) * 1.12
        ylo = min(min(y for _, y, _ in v) for v in series.values()) * 0.7
        yhi = max(max(y for _, y, _ in v) for v in series.values()) * 1.5
        for gv in (0.1, 0.3, 1, 3, 10, 30, 100):
            if ylo <= gv <= yhi:
                y = logmap(gv, ylo, yhi, b, t)
                s2.line(l, y, r, y, C["grid"])
                s2.txt(l - 8, y + 4, str(gv), 10, C["mute"], "end")
        step = 2 if xhi <= 9 else 4
        gx = 0
        while gx <= xhi:
            x = linmap(gx, 0, xhi, l, r)
            s2.line(x, t, x, b, C["grid"])
            s2.txt(x, b + 16, str(gx), 10, C["mute"], "middle")
            gx += step
        for side, col in (("ST", C["v3"]), ("PT", C["v4"])):
            pts = [(linmap(x, 0, xhi, l, r), logmap(y, ylo, yhi, b, t), p_)
                   for x, y, p_ in series[side]]
            s2.path([(x, y) for x, y, _ in pts], col, 2.2)
            for x, y, p_ in pts:
                s2.dot(x, y, col)
                if p_ in (1, 32, 256, 384):
                    s2.txt(x + 6, y - 5, str(p_), 8, C["mute"])
            z = zp[side]
            if z and z["avg_ms"]:
                s2.dot(linmap(float(z["ops_M"]), 0, xhi, l, r),
                       logmap(float(z["avg_ms"]), ylo, yhi, b, t), col, 4.6, True)
        ps = max(x for x, _, _ in series["ST"]); pp = max(x for x, _, _ in series["PT"])
        s2.txt(l + 10, t - 12, f"빨강 stock · 파랑 port · 속 빈 마커 = zipf θ=0.99    "
                               f"정점 {ps:.2f} → {pp:.2f} M ({(pp/ps-1)*100:+.0f}%)",
               11, C["ink"], "start", 600)
        if wl == "A":
            s2.txt(l + 10, t + 6, "주의: 메모리 배치와 item_lock 경합이 겹친 워크로드다", 10, C["mute"])
        s2.save(f"{out}/f1-{wl}.svg")


# ── F1b: 메모리 노드 CPU = 0 ─────────────────────────────────────────────
def f1b(rows, out):
    """세 막대를 로그 축에 세운다. 0.00006 과 29.9 를 한 그림에 놓는 것이
    이 그림의 전부다 — 선형 축이면 왼쪽 막대가 보이지 않는다."""
    bars = [("genie_memd\n(메모리 노드)", 0.00006, C["set"],
             "66.6 h 동안 CPU 15.3 s · op 당 0.40 ns · prefill 포함"),
            ("genie 박스 전체\n(memtier 부하 생성기)", 27.9, C["mute"],
             "48 코어 중 58.2% — 부하를 만드는 비용"),
            ("guest memcached\n(port 서버)", 29.9, C["v4"],
             "30 코어 중 99.7% — 일을 하는 쪽")]
    s = Svg(h=400, title="F1b — one-sided READ: 메모리 노드는 CPU 를 쓰지 않는다")
    l, r, t, b = axes(s, "", "CPU (코어, 로그)")
    lo, hi = 1e-5, 60
    for gv in (1e-5, 1e-4, 1e-3, 1e-2, 1e-1, 1, 10):
        y = logmap(gv, lo, hi, b, t)
        s.line(l, y, r, y, C["grid"])
        lab = f"{gv:g}" if gv >= 0.01 else f"{gv:.0e}"
        s.txt(l - 8, y + 4, lab, 10, C["mute"], "end")
    bw = (r - l) / len(bars) * 0.42
    for i, (nm, v, col, note) in enumerate(bars):
        x = l + (r - l) * (i + 0.5) / len(bars) - bw / 2
        y = logmap(v, lo, hi, b, t)
        s.rect(x, y, bw, b - y, col)
        s.txt(x + bw / 2, y - 8, (f"{v:g}" if v >= 1 else f"{v:.5f}") + " 코어",
              11, C["ink"], "middle", 600)
        for j, ln in enumerate(nm.split("\n")):
            s.txt(x + bw / 2, b + 18 + j * 13, ln, 10, C["ink"], "middle")
        s.txt(x + bw / 2, b + 46, note, 8.5, C["mute"], "middle")
    s.txt(l + 10, t - 12, "메모리 노드가 서버보다 50 만 배 적게 쓴다 — 이것이 disaggregation 주장의 직접 증거다",
          10, C["mute"])
    s.save(f"{out}/f1b-memory-node-cpu.svg")


# ── F2a: pipeline 곡선, 클라이언트 지연 vs span 이중축 ────────────────────
def f2a(rows, out):
    cl = load_client()
    pipes = [1, 8, 32, 64, 128, 256, 384]
    v4 = [r for r in rows if r["label"] == "BD2-b"]
    if not cl or len(v4) < 16:
        print("  F2a 건너뜀"); return
    s = Svg(title="F2a — 같은 부하 축에서 두 지표가 반대로 간다 (port_v4)")
    l, r, t, b = axes(s, "처리량 (M ops/s)", "클라이언트 지연 avg (ms, 로그)", "span v3 (µs)")
    xhi = 14.5
    ylo, yhi = 0.1, 40
    for gv in (0.1, 1, 10):
        y = logmap(gv, ylo, yhi, b, t)
        s.line(l, y, r, y, C["grid"])
        s.txt(l - 8, y + 4, str(gv), 10, C["mute"], "end")
    for gx in (0, 4, 8, 12):
        x = linmap(gx, 0, xhi, l, r)
        s.line(x, t, x, b, C["grid"])
        s.txt(x, b + 16, str(gx), 10, C["mute"], "middle")
    y30 = linmap(30, 0, 40, b, t)
    s.line(l, y30, r, y30, C["set"], 1.4, "6 4")
    s.txt(r - 4, y30 - 6, "계약 span 30 µs", 10, C["set"], "end")
    for tag, sl, col in (("GET-only", slice(2, 9), C["get"]), ("1:9 혼합", slice(9, 16), C["mix"])):
        rowset = v4[sl]
        lat, spn = [], []
        for p_, rw in zip(pipes, rowset):
            c = cl.get(f"BD2-GET-P{p_}") if "GET" in tag else cl.get(f"BD2-MIX-P{p_}")
            x = linmap(num(rw, "Mops"), 0, xhi, l, r)
            if c and c["avg_ms"]:
                lat.append((x, logmap(float(c["avg_ms"]), ylo, yhi, b, t)))
            spn.append((x, linmap(num(rw, "Gv3_avg"), 0, 40, b, t)))
        s.path(lat, col, 2.2)
        for pt in lat:
            s.dot(pt[0], pt[1], col)
        s.path(spn, col, 1.4, "4 3")
        for pt in spn:
            s.dot(pt[0], pt[1], col, 3.0, True)
    s.txt(l + 10, t - 12, "실선(왼쪽) 클라이언트 지연 ↑    파선(오른쪽) span v3 — 평평하다",
          10, C["mute"])
    s.txt(l + 10, t + 4, "파랑 GET-only · 주황 1:9 혼합", 10, C["mute"])
    s.save(f"{out}/f2a-pipeline-curve.svg")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--rows", default="experiments/night-20260806/rows.tsv")
    ap.add_argument("--out", default="img/osdi-20260806")
    a = ap.parse_args()
    Path(a.out).mkdir(parents=True, exist_ok=True)
    rows = load(a.rows)
    print(f"rows={len(rows)} → {a.out}")
    f1(rows, a.out); f1b(rows, a.out); f2a(rows, a.out); f2b(rows, a.out); f2c(rows, a.out); f3(rows, a.out); f4(rows, a.out)


main()
