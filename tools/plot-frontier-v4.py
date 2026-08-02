#!/usr/bin/env python3
"""v4 프론티어: 측정한 모든 (처리량, span) 점을 계약선과 함께 하나에 그린다.

v2 의 frontier-7point 는 계약을 만족하는 점이 없어서 "어디까지 갔나" 를
그렸다. v4 는 만족하는 점이 있으므로 **여유가 얼마나 되나** 를 그린다.
새로 잰 셀은 없다 — B-1b(pipeline)와 B-2(mcT)가 이미 9 점을 준다.

의존성 없음. SVG 를 직접 쓴다(v2 plot-config-matrix.py 와 같은 방식).
"""
import argparse
from pathlib import Path

W, H = 900, 560
L, R, T, B = 78, 34, 58, 62          # 여백
GATE_OPS, GATE_SPAN = 10.0, 30.0     # 계약선

# (라벨, 축, 처리량 M/s, GET span µs) — 혼합은 GET span 이 SET 보다 크므로 그것을 쓴다
# pipe=256 과 mcT=30 은 같은 운영점이다. 한 번만 그리고 그렇게 표시한다.
MIX = [
    ("p32",  "pipe",  6.590, 21.47), ("p64",  "pipe",  8.217, 22.24),
    ("p128", "pipe", 10.194, 20.65), ("p384", "pipe", 10.109, 21.44),
    ("t20",  "mcT",   8.365, 17.55), ("t24",  "mcT",   9.504, 18.36),
    ("t28",  "mcT",  10.376, 19.37),
    ("운영점 p256=t30", "op", 10.770, 19.85),
]
GET = [
    ("p32",  "pipe",  7.619, 25.06), ("p64",  "pipe",  9.772, 25.94),
    ("p128", "pipe", 12.378, 26.79), ("p384", "pipe", 13.266, 25.98),
    ("t20",  "mcT",  10.457, 21.95), ("t24",  "mcT",  11.651, 24.48),
    ("t28",  "mcT",  12.774, 25.48),
    ("운영점 p256=t30", "op", 13.303, 26.03),
]
COLOR = {"pipe": "#1f77b4", "mcT": "#d62728", "op": "#111111"}
# 선을 이을 때는 운영점을 두 축 모두의 끝점으로 취급한다
SEQ = {"pipe": ["p32", "p64", "p128", "운영점 p256=t30", "p384"],
       "mcT": ["t20", "t24", "t28", "운영점 p256=t30"]}


def esc(s):
    return s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def place(labels):
    """겹치는 라벨을 위/아래로 밀어낸다. 붐비는 구간이 하필 운영점 근처라
    회피가 없으면 판정에 필요한 이름이 서로 가려진다."""
    out, used = [], []
    for x, y, name in sorted(labels, key=lambda t: t[0]):
        half = 3.6 * len(name) + 8
        for dy in (-13, 15, -27, 29, -41, 43):
            if all(abs(x - ux) > half + uw or abs(y + dy - uy) > 12
                   for ux, uy, uw in used):
                break
        used.append((x, y + dy, half))
        out.append((x, y + dy, name))
    return out


def render(points, title, xlo, xhi, ylo, yhi, out):
    px = lambda v: L + (v - xlo) / (xhi - xlo) * (W - L - R)
    py = lambda v: H - B - (v - ylo) / (yhi - ylo) * (H - T - B)
    by = {n: (o, s) for n, _, o, s in points}

    o = [f'<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}" '
         f'viewBox="0 0 {W} {H}" font-family="DejaVu Sans,sans-serif">',
         f'<rect width="{W}" height="{H}" fill="#fff"/>',
         f'<text x="{L}" y="30" font-size="17" font-weight="bold">{esc(title)}</text>',
         f'<text x="{L}" y="48" font-size="12" fill="#666">'
         f'초록 영역이 계약(≥10 M, span ≤30 µs). 새 셀 없음 — B-1b·B-2 에서 이미 잰 점이다.</text>']

    # 계약 만족 영역
    x0 = max(px(GATE_OPS), L)
    y0 = max(py(GATE_SPAN), T)
    o.append(f'<rect x="{x0:.1f}" y="{y0:.1f}" width="{W-R-x0:.1f}" '
             f'height="{H-B-y0:.1f}" fill="#2ca02c" opacity="0.09"/>')

    for v in range(int(ylo), int(yhi) + 1, 2):
        o.append(f'<line x1="{L}" y1="{py(v):.1f}" x2="{W-R}" y2="{py(v):.1f}" '
                 f'stroke="#ececec"/>')
        o.append(f'<text x="{L-8}" y="{py(v)+4:.1f}" font-size="11" fill="#555" '
                 f'text-anchor="end">{v}</text>')
    for i in range(int(xlo), int(xhi) + 1):
        o.append(f'<line x1="{px(i):.1f}" y1="{T}" x2="{px(i):.1f}" y2="{H-B}" '
                 f'stroke="#ececec"/>')
        o.append(f'<text x="{px(i):.1f}" y="{H-B+18}" font-size="11" fill="#555" '
                 f'text-anchor="middle">{i}</text>')

    o.append(f'<line x1="{px(GATE_OPS):.1f}" y1="{T}" x2="{px(GATE_OPS):.1f}" '
             f'y2="{H-B}" stroke="#2ca02c" stroke-width="2" stroke-dasharray="6,4"/>')
    o.append(f'<text x="{px(GATE_OPS)-6:.1f}" y="{H-B-8}" font-size="11" '
             f'fill="#2ca02c" text-anchor="end">10 M</text>')
    if ylo <= GATE_SPAN <= yhi:
        o.append(f'<line x1="{L}" y1="{py(GATE_SPAN):.1f}" x2="{W-R}" '
                 f'y2="{py(GATE_SPAN):.1f}" stroke="#2ca02c" stroke-width="2" '
                 f'stroke-dasharray="6,4"/>')
        o.append(f'<text x="{W-R-6}" y="{py(GATE_SPAN)-6:.1f}" font-size="11" '
                 f'fill="#2ca02c" text-anchor="end">span 30 µs</text>')
    else:
        o.append(f'<text x="{W-R-6}" y="{T+15}" font-size="11" fill="#2ca02c" '
                 f'text-anchor="end">span 상한 30 µs — 축 밖(전 점 통과)</text>')

    o.append(f'<text x="{(L+W-R)/2:.0f}" y="{H-16}" font-size="13" '
             f'text-anchor="middle">처리량 (M ops/s)</text>')
    o.append(f'<text x="18" y="{(T+H-B)/2:.0f}" font-size="13" text-anchor="middle" '
             f'transform="rotate(-90 18 {(T+H-B)/2:.0f})">GET span v3 (µs)</text>')

    for axis, names in SEQ.items():
        pts = [by[n] for n in names if n in by]
        d = " ".join(f"{'M' if i == 0 else 'L'}{px(a):.1f},{py(b):.1f}"
                     for i, (a, b) in enumerate(pts))
        o.append(f'<path d="{d}" fill="none" stroke="{COLOR[axis]}" '
                 f'stroke-width="1.6" opacity="0.4"/>')

    for name, axis, ops, span in points:
        r = 7 if axis == "op" else 5.5
        if ops >= GATE_OPS and span <= GATE_SPAN:
            o.append(f'<circle cx="{px(ops):.1f}" cy="{py(span):.1f}" r="{r+3.5}" '
                     f'fill="none" stroke="#2ca02c" stroke-width="1.8"/>')
        o.append(f'<circle cx="{px(ops):.1f}" cy="{py(span):.1f}" r="{r}" '
                 f'fill="{COLOR[axis]}" stroke="#fff" stroke-width="1.5"/>')

    for x, y, name in place([(px(o_), py(s), n) for n, _, o_, s in points]):
        o.append(f'<text x="{x:.1f}" y="{y:.1f}" font-size="10.5" fill="#333" '
                 f'text-anchor="middle">{esc(name)}</text>')

    lx, ly = L + 14, H - B - 66
    for i, (axis, label) in enumerate((("pipe", "pipeline 축 (mcT=30)"),
                                       ("mcT", "mcT 축 (pipe=256)"),
                                       ("op", "운영점 — 두 축의 만나는 점"))):
        o.append(f'<circle cx="{lx}" cy="{ly + i*17}" r="5" fill="{COLOR[axis]}"/>')
        o.append(f'<text x="{lx+11}" y="{ly + i*17 + 4}" font-size="11">{esc(label)}</text>')

    o.append("</svg>")
    Path(out).write_text("\n".join(o), encoding="utf-8")
    n = sum(1 for _, _, x, y in points if x >= GATE_OPS and y <= GATE_SPAN)
    print(f"{out}  {len(points)} 점, 계약 통과 {n}")


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("outdir")
    a = ap.parse_args()
    d = Path(a.outdir)
    d.mkdir(parents=True, exist_ok=True)
    render(MIX, "v4 프론티어 — 1:9 혼합 (구속 워크로드)", 6, 12, 16, 24,
           d / "frontier-mix.svg")
    render(GET, "v4 프론티어 — GET-only", 7, 14, 20, 28,
           d / "frontier-get.svg")
