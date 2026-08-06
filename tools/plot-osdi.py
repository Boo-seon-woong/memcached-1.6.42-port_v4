#!/usr/bin/env python3
"""osdi 그림 생성 — 명세는 experiments/osdi-0804/FIGURES.md.

  python3 tools/plot-osdi.py [--rows ...] [--out img/osdi-20260806]

의존성 없음. SVG 를 직접 쓴다(tools/plot-frontier-v4.py 와 같은 방식 —
게스트·CI 어디서든 돌아야 해서 matplotlib 을 안 쓴다).

축은 전부 **선형**이다 — 로그 축 금지(관리자 지시 2026-08-06).
입력은 rows.tsv(서버측)와 client.tsv(genie 보고 파싱).
"""
import argparse
from pathlib import Path

W, H = 820, 500
PAD = dict(l=80, r=60, t=132, b=58)   # t 가 큰 이유: 상단 주석 상자 자리
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


def legend(s, lines, x=None, y=None, w=None):
    """좌상단 주석 상자. **무엇을 달리했고 값이 무엇인지**를 그림 안에 적는다 —
    캡션은 붙어 다니지 않지만 그림은 혼자 돌아다닌다."""
    x = PAD["l"] + 8 if x is None else x
    y = 36 if y is None else y   # 제목 아래, 축 위
    w = (s.w - PAD["l"] - PAD["r"] - 16) if w is None else w
    h = 13 * len(lines) + 10
    s.p.append(f'<rect x="{x:.1f}" y="{y:.1f}" width="{w:.1f}" height="{h}" '
               f'fill="#f8fafc" stroke="#cbd5e1" stroke-width="1" rx="3"/>')
    for i, ln in enumerate(lines):
        s.txt(x + 8, y + 15 + i * 13, ln, 9.5, C["ink"] if i == 0 else C["mute"],
              weight=600 if i == 0 else 400)
    return y + h


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


# 로그 축은 쓰지 않는다 (관리자 지시 2026-08-06). 값 폭이 큰 그림(F1b 의
# 0.00006 대 29.9)은 선형에서 막대가 안 보이는데, **그 안 보이는 것이 곧
# 주장**이라 라벨로 값을 적는다.


def linmap(v, lo, hi, a, b):
    return a + (b - a) * (v - lo) / (hi - lo) if hi > lo else a


# ── F2b: 분해 스택 ────────────────────────────────────────────────────────
def f2b(rows, out):
    pipes = [1, 8, 32, 64, 128, 256, 384]
    for tag, sl, title in (("get", slice(2, 9), "GET-only"), ("mix", slice(9, 16), "1:9 혼합")):
        bd = [r for r in rows if r["label"] == "BD2-b"][sl]
        if len(bd) < 7:
            continue
        s = Svg(title=f"F2b  서버 체류 분해 — {title}")
        l, r, t, b = axes(s, "pipeline", "서버 체류 (µs)")
        lo = 0.0
        hi = max(num(r_, "srv") for r_ in bd) * 1.12
        step = 100 if hi <= 900 else 200
        gv = 0
        while gv <= hi:
            y = linmap(gv, lo, hi, b, t)
            s.line(l, y, r, y, C["grid"])
            s.txt(l - 8, y + 4, str(gv), 10, C["mute"], "end")
            gv += step
        bw = (r - l) / len(pipes) * 0.52
        for i, (p, row) in enumerate(zip(pipes, bd)):
            x = l + (r - l) * (i + 0.5) / len(pipes) - bw / 2
            srv, que, bk = num(row, "srv"), num(row, "que"), num(row, "bk")
            span = num(row, "Gv3_avg")
            pre, post = srv - que - bk, bk - span
            acc = 0.0
            for val, col, _ in ((que, C["que"], "que"), (max(pre, 0.01), C["pre"], "pre"),
                                (span, C["span"], "span v3"), (max(post, 0), C["post"], "post")):
                y0 = linmap(acc, lo, hi, b, t)
                acc += val
                y1 = linmap(acc, lo, hi, b, t)
                s.rect(x, y1, bw, y0 - y1, col)
            s.txt(x + bw / 2, linmap(acc, lo, hi, b, t) - 6, f"{srv:.0f}", 9,
                  C["ink"], "middle", 600)
            s.txt(x + bw / 2, b + 16, str(p), 10, C["ink"], "middle")
        yb = legend(s, ["달리한 것: pipeline 깊이만 (1~384). 서버 구성은 운영값 고정",
                        "막대 = 서버 체류 srv 를 네 구간으로 나눈 것. 막대 위 숫자 = srv 합(µs)",
                        "que 소켓read→명령시작 · pre 파싱 · span v3 계약구간 · post 복호→송신",
                        "port_v4 c11ede3e, PROF=1, 셀당 60초"])
        for i, (nm, col) in enumerate((("que", C["que"]), ("pre", C["pre"]),
                                       ("span v3 (계약)", C["span"]), ("post", C["post"]))):
            s.rect(l + 10 + i * 118, yb + 6, 11, 11, col)
            s.txt(l + 26 + i * 118, yb + 15, nm, 9.5, C["ink"])
        s.save(f"{out}/f2b-{tag}.svg")


# ── F2c: v3 ↔ v4 ─────────────────────────────────────────────────────────
def f2c(rows, out):
    pipes = [1, 8, 32, 64, 128, 256, 384]
    v4 = [r for r in rows if r["label"] == "BD2-b"][2:9]
    v3 = [r for r in rows if r["label"] == "BD3"][0:7]
    if len(v3) < 7 or len(v4) < 7:
        return
    s = Svg(title="F2c  span·srv 대 pipeline — v3 vs v4")
    l, r, t, b = axes(s, "pipeline", "µs")
    lo = 0.0
    hi = max(max(num(x, "srv") for x in v3), max(num(x, "srv") for x in v4)) * 1.1
    gv = 0
    while gv <= hi:
        y = linmap(gv, lo, hi, b, t)
        s.line(l, y, r, y, C["grid"])
        s.txt(l - 8, y + 4, str(gv), 10, C["mute"], "end")
        gv += 200
    xs = [l + (r - l) * (i + 0.5) / len(pipes) for i in range(len(pipes))]
    for rowset, col, nm in ((v3, C["v3"], "v3 span"), (v4, C["v4"], "v4 span")):
        pts = [(x, linmap(num(rw, "Gv3_avg"), lo, hi, b, t)) for x, rw in zip(xs, rowset)]
        s.path(pts, col, 2.2)
        for (x, y) in pts:
            s.dot(x, y, col)
    for rowset, col, dash in ((v3, C["v3"], "4 3"), (v4, C["v4"], "4 3")):
        pts = [(x, linmap(num(rw, "srv"), lo, hi, b, t)) for x, rw in zip(xs, rowset)]
        s.path(pts, col, 1.4, dash)
    for x, p in zip(xs, pipes):
        s.txt(x, b + 16, str(p), 10, C["ink"], "middle")
    legend(s, ["달리한 것: 포트 버전(v3/v4)만. 격자·부하·창 길이는 동일",
               "실선 = span v3 (계약이 재는 구간) · 파선 = srv (서버 체류 전체)",
               "빨강 port_v3 86da4222 (W=40 nqp=4) · 파랑 port_v4 c11ede3e (W=24 reap=8 chain=8)",
               "pipe=256 에서 span −91% 인데 srv 는 −4.2% — 시간이 span 밖으로 옮겨갔다"])
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
    s = Svg(title="F3  값 크기 대 CPU/op")
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
    legend(s, ["달리한 것: 값 크기만 (16·32·64·152 B). 크기마다 재프리로드, 서버 구성 고정",
               "점 = CPU/op = busyCPU ÷ 처리량 (busy 는 네 셀 다 29.8~29.9 로 포화)",
               "파선 = 최소제곱 2.00 µs + 4.05 ns/B (네 점 잔차 2% 안)",
               f"xfer {pts[0][3]:.2f}→{pts[-1][3]:.2f} µs · crypto {pts[0][4]:.2f}→{pts[-1][4]:.2f} µs "
               "— 바이트 비용은 전송이지 암복호가 아니다",
               "점 아래 숫자 = GET-only 처리량. 152 B 는 수용 상한(pac_fallback 0)"])
    s.save(f"{out}/f3-value-size.svg")


# ── F3b: exp3 throughput–latency ─────────────────────────────────────────
def f3b(rows, out):
    """값 크기가 운영점을 어디로 옮기는지. 셀이 pipe=256 한 점씩이라
    곡선이 아니라 **크기로 이어붙인 궤적**이다 — 그 사실을 상자에 적는다."""
    cl = load_client()
    sizes = [16, 32, 64, 152]
    series = {}
    for wtag, wnm, col in (("W1", "GET-only", C["get"]), ("W2", "1:9 혼합", C["mix"]),
                           ("W3", "SET-only", C["set"])):
        pts = []
        for d in sizes:
            c = cl.get(f"V{d}-{wtag}")
            if c and c["avg_ms"]:
                pts.append((float(c["ops_M"]), float(c["avg_ms"]), d))
        if pts:
            series[wnm] = (pts, col)
    if not series:
        print("  F3b 건너뜀"); return
    s2 = Svg(title="F3b  값 크기별 처리량–지연")
    l, r, t, b = axes(s2, "처리량 (M ops/s)", "클라이언트 지연 avg (ms)")
    xhi, yhi = 16.0, 6.5
    for gx in (0, 4, 8, 12, 16):
        x = linmap(gx, 0, xhi, l, r)
        s2.line(x, t, x, b, C["grid"])
        s2.txt(x, b + 16, str(gx), 10, C["mute"], "middle")
    for gy in (0, 1, 2, 3, 4, 5, 6):
        y = linmap(gy, 0, yhi, b, t)
        s2.line(l, y, r, y, C["grid"])
        s2.txt(l - 8, y + 4, str(gy), 10, C["mute"], "end")
    for wnm, (pts, col) in series.items():
        xy = [(linmap(x, 0, xhi, l, r), linmap(y, 0, yhi, b, t), d) for x, y, d in pts]
        s2.path([(x, y) for x, y, _ in xy], col, 2.0)
        for x, y, d in xy:
            s2.dot(x, y, col, 4.0)
            s2.txt(x, y - 9, f"{d}B", 8.5, C["mute"], "middle")
        s2.txt(xy[-1][0] - 8, xy[-1][1] + 16, wnm, 10, col, "end", 600)
    legend(s2, ["달리한 것: 값 크기만 (16·32·64·152 B). pipeline=256 고정, 서버 구성 고정",
                "점 = 셀 하나(30초). 점 옆 = 값 크기.  x 처리량 · y memtier avg 지연",
                "선은 크기 순으로 이은 궤적이지 부하 곡선이 아니다 — 셀마다 부하가 같다",
                "색 = 워크로드. 152 B 는 수용 상한(pac_fallback 0), port_v4 c11ede3e PROF=1"])
    s2.save(f"{out}/f3b-size-throughput-latency.svg")


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
        s = Svg(title="F4a  chain 축 — span 과 srv")
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
        legend(s, ["달리한 것: ext_post_chain 만 (1~16). reap=8 고정, 그 외 운영값",
                   "실선(왼쪽 축) span v3 — 오른다 · 파선(오른쪽 축) srv 서버 체류 — 내린다",
                   "x 축 아래 숫자 = 그 셀의 GET-only 처리량",
                   "c8 은 재시행값이다 (첫 셀이 −2.8% 낮게 나왔다)"])
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
        s = Svg(title="F4b  유효 배치 대 admit·v2")
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
        legend(s, ["달리한 것: 같은 유효 배치를 chain 으로 만들 것이냐 reap 으로 만들 것이냐",
                   "x = min(chain, reap).  실선·채운 점 = chain 축 (reap=8 고정)",
                   "파선·빈 점 = reap 축 (chain=8 고정)",
                   "파랑 admit — 두 축이 포개진다(대칭) · 주황 v2 — 갈라진다(reap 전용)"])
        s.save(f"{out}/f4b-two-knobs.svg")

    # F4c: 계약 회랑
    if len(cs) >= 5:
        s = Svg(title="F4c  chain 축 처리량과 계약선")
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
        legend(s, ["달리한 것: ext_post_chain 만 (1~16). reap=8 고정",
                   "y = 처리량. 초록 파선 = 계약선 10 M ops/s",
                   "파랑 GET-only · 주황 1:9 혼합 — 혼합만 chain=1 에서 미달(9.653 M)",
                   "chain 노브가 존재하는 이유가 혼합 조항이라는 뜻이다"])
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
        # genie 는 재시행분도 PT-*-Z256 이름으로 보고했다(파서가 나중 것을
        # 취하므로 그 값이 정본이다). PTZ- 로 찾으면 하나도 안 걸린다.
        zp = {side: cl.get(f"{side}-{wl}-Z256") for side in ("ST", "PT")}
        s2 = Svg(title=f"F1  {nm} — stock vs port")
        l, r, t, b = axes(s2, "처리량 (M ops/s)", "클라이언트 지연 avg (ms)")
        xhi = max(max(x for x, _, _ in v) for v in series.values()) * 1.12
        ylo = 0.0
        yhi = max(max(y for _, y, _ in v) for v in series.values()) * 1.15
        nice = 1 if yhi <= 8 else (5 if yhi <= 45 else 10)
        gv = 0.0
        while gv <= yhi:
            y = linmap(gv, ylo, yhi, b, t)
            s2.line(l, y, r, y, C["grid"])
            s2.txt(l - 8, y + 4, f"{gv:g}", 10, C["mute"], "end")
            gv += nice
        step = 2 if xhi <= 9 else 4
        gx = 0
        while gx <= xhi:
            x = linmap(gx, 0, xhi, l, r)
            s2.line(x, t, x, b, C["grid"])
            s2.txt(x, b + 16, str(gx), 10, C["mute"], "middle")
            gx += step
        for side, col in (("ST", C["v3"]), ("PT", C["v4"])):
            pts = [(linmap(x, 0, xhi, l, r), linmap(y, ylo, yhi, b, t), p_)
                   for x, y, p_ in series[side]]
            s2.path([(x, y) for x, y, _ in pts], col, 2.2)
            for x, y, p_ in pts:
                s2.dot(x, y, col)
                if p_ in (1, 32, 256, 384):
                    s2.txt(x + 6, y - 5, str(p_), 8, C["mute"])
            z = zp[side]
            if z and z["avg_ms"]:
                s2.dot(linmap(float(z["ops_M"]), 0, xhi, l, r),
                       linmap(float(z["avg_ms"]), ylo, yhi, b, t), col, 4.6, True)
        ps = max(x for x, _, _ in series["ST"]); pp = max(x for x, _, _ in series["PT"])
        note = ["달리한 것: 서버 종류(stock/port) × pipeline 깊이 1~384",
                f"점 = 셀 하나(30초). 점 옆 숫자 = pipeline.  x 처리량 · y memtier avg 지연",
                "빨강 stock(로컬 메모리) · 파랑 port(원격 RDMA) · 속 빈 마커 = zipf θ=0.99",
                f"정점 {ps:.2f} → {pp:.2f} M ({(pp/ps-1)*100:+.0f}%)   그 외 모든 조건 동일"]
        if wl == "A":
            note.append("주의: 이 워크로드는 메모리 배치와 쓰기 경로 직렬화가 겹쳐 있다")
        legend(s2, note)
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
    s = Svg(title="F1b  구성 요소별 CPU 점유")
    l, r, t, b = axes(s, "", "CPU (코어)")
    lo, hi = 0.0, 32
    for gv in (0, 5, 10, 15, 20, 25, 30):
        y = linmap(gv, lo, hi, b, t)
        s.line(l, y, r, y, C["grid"])
        s.txt(l - 8, y + 4, str(gv), 10, C["mute"], "end")
    bw = (r - l) / len(bars) * 0.42
    for i, (nm, v, col, note) in enumerate(bars):
        x = l + (r - l) * (i + 0.5) / len(bars) - bw / 2
        y = linmap(v, lo, hi, b, t)
        s.rect(x, y, bw, max(b - y, 1.5), col)
        s.txt(x + bw / 2, y - 8, (f"{v:g}" if v >= 1 else f"{v:.5f}") + " 코어",
              11, C["ink"], "middle", 600)
        for j, ln in enumerate(nm.split("\n")):
            s.txt(x + bw / 2, b + 18 + j * 13, ln, 10, C["ink"], "middle")
        s.txt(x + bw / 2, b + 46, note, 8.5, C["mute"], "middle")
    legend(s, ["달리한 것: CPU 를 재는 대상 (같은 시스템의 세 구성 요소)",
               "값 = 점유 코어 수. genie_memd 는 utime+stime 누적 15.3 s / 66.6 h",
               "첫 막대는 선형 축에서 보이지 않는다 (서버의 50 만분의 1)"])
    s.save(f"{out}/f1b-memory-node-cpu.svg")


# ── F2a: pipeline 곡선, 클라이언트 지연 vs span 이중축 ────────────────────
def f2a(rows, out):
    cl = load_client()
    pipes = [1, 8, 32, 64, 128, 256, 384]
    v4 = [r for r in rows if r["label"] == "BD2-b"]
    if not cl or len(v4) < 16:
        print("  F2a 건너뜀"); return
    s = Svg(title="F2a  pipeline 축 — 클라이언트 지연과 span")
    l, r, t, b = axes(s, "처리량 (M ops/s)", "클라이언트 지연 avg (ms)", "span v3 (µs)")
    xhi = 14.5
    ylo, yhi = 0.0, 4.0
    for gv in (0, 1, 2, 3, 4):
        y = linmap(gv, ylo, yhi, b, t)
        s.line(l, y, r, y, C["grid"])
        s.txt(l - 8, y + 4, str(gv), 10, C["mute"], "end")
    for gx in (0, 4, 8, 12):
        x = linmap(gx, 0, xhi, l, r)
        s.line(x, t, x, b, C["grid"])
        s.txt(x, b + 16, str(gx), 10, C["mute"], "middle")
    y30 = linmap(30, 0, 40, b, t)  # 오른쪽 축(span)은 원래 선형이다
    s.line(l, y30, r, y30, C["set"], 1.4, "6 4")
    s.txt(r - 4, y30 - 6, "계약 span 30 µs", 10, C["set"], "end")
    for tag, sl, col in (("GET-only", slice(2, 9), C["get"]), ("1:9 혼합", slice(9, 16), C["mix"])):
        rowset = v4[sl]
        lat, spn = [], []
        for p_, rw in zip(pipes, rowset):
            c = cl.get(f"BD2-GET-P{p_}") if "GET" in tag else cl.get(f"BD2-MIX-P{p_}")
            x = linmap(num(rw, "Mops"), 0, xhi, l, r)
            if c and c["avg_ms"]:
                lat.append((x, linmap(float(c["avg_ms"]), ylo, yhi, b, t)))
            spn.append((x, linmap(num(rw, "Gv3_avg"), 0, 40, b, t)))
        s.path(lat, col, 2.2)
        for pt in lat:
            s.dot(pt[0], pt[1], col)
        s.path(spn, col, 1.4, "4 3")
        for pt in spn:
            s.dot(pt[0], pt[1], col, 3.0, True)
    legend(s, ["달리한 것: pipeline 깊이만 (1~384). 점 하나가 셀 하나(60초)",
               "실선·채운 점(왼쪽 축) = memtier 클라이언트 지연 — 부하와 함께 오른다",
               "파선·빈 점(오른쪽 축) = span v3 — 평평하다. 초록 파선 = 계약 30 µs",
               "파랑 GET-only · 주황 1:9 혼합.  port_v4 c11ede3e, PROF=1"])
    s.save(f"{out}/f2a-pipeline-curve.svg")


def f4d(rows, out):
    """exp4 의 처리량–지연: chain 을 파라미터로 놓은 산점.
    F4a 는 x 가 chain 이라 "노브를 얼마로 둘까" 를 보고, 이 그림은
    x 가 처리량이라 "그 노브가 운영점을 어디로 옮기나" 를 본다."""
    cl = load_client()
    if not cl:
        print("  F4d 건너뜀"); return
    chains = [1, 2, 4, 8, 12, 16]
    reaps = [1, 2, 4, 12]
    s2 = Svg(title="F4d  chain·reap 별 처리량–지연")
    l, r, t, b = axes(s2, "처리량 (M ops/s)", "클라이언트 지연 avg (ms)")
    xhi, yhi = 14.5, 4.0
    for gx in (0, 4, 8, 12):
        x = linmap(gx, 0, xhi, l, r)
        s2.line(x, t, x, b, C["grid"])
        s2.txt(x, b + 16, str(gx), 10, C["mute"], "middle")
    for gy in (0, 1, 2, 3, 4):
        y = linmap(gy, 0, yhi, b, t)
        s2.line(l, y, r, y, C["grid"])
        s2.txt(l - 8, y + 4, str(gy), 10, C["mute"], "end")
    def draw(cells, labels, col, dash, tag):
        pts = []
        for cid, lab in zip(cells, labels):
            c = cl.get(cid)
            if c and c["avg_ms"]:
                pts.append((linmap(float(c["ops_M"]), 0, xhi, l, r),
                            linmap(float(c["avg_ms"]), 0, yhi, b, t), lab))
        if not pts:
            return
        s2.path([(x, y) for x, y, _ in pts], col, 2.0, dash)
        for x, y, lab in pts:
            s2.dot(x, y, col, 3.8, dash is not None)
            s2.txt(x, y - 9, lab, 8.5, C["mute"], "middle")
        s2.txt(pts[-1][0] + 8, pts[-1][1] + 4, tag, 9.5, col, "start", 600)
    for wl, col in (("GET", C["get"]), ("MIX", C["mix"])):
        draw([f"E4-C{c}R8-{wl}" for c in chains], [f"c{c}" for c in chains],
             col, None, f"{wl} · chain 축")
        draw([f"E4-C8R{r_}-{wl}" for r_ in reaps], [f"r{r_}" for r_ in reaps],
             col, "4 3", f"{wl} · reap 축")
    legend(s2, ["달리한 것: 배칭 노브 두 개. 실선 = chain 1~16 (reap=8 고정),",
                "           파선 = reap 1~12 (chain=8 고정). 그 외 운영값 고정",
                "점 = 셀 하나(30초, pipe=256). 점 옆 = 그 셀의 노브 값",
                "파랑 GET-only · 주황 1:9 혼합.  x 처리량 · y memtier avg 지연",
                "두 축이 같은 점(c8=r8)에서 만난다 — 거기가 현 운영값이다"])
    s2.save(f"{out}/f4d-batching-throughput-latency.svg")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--rows", default="experiments/night-20260806/rows.tsv")
    ap.add_argument("--out", default="img/osdi-20260806")
    a = ap.parse_args()
    Path(a.out).mkdir(parents=True, exist_ok=True)
    rows = load(a.rows)
    print(f"rows={len(rows)} → {a.out}")
    f1(rows, a.out); f1b(rows, a.out); f3b(rows, a.out); f2a(rows, a.out); f2b(rows, a.out); f2c(rows, a.out); f3(rows, a.out); f4(rows, a.out); f4d(rows, a.out)


main()
