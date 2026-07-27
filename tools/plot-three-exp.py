#!/usr/bin/env python3
"""Render the 2026-07-27 three-experiment sweep as dependency-free SVG.

Same house style as plot-config-matrix.py: one metric family per panel
(never a dual axis), fixed metric colors, amber dashed 30us objective.
"""

import argparse
import csv
import html
from pathlib import Path

W = 960
# p50 is teal (not the matrix plotter's green): red/green adjacency fails the
# deutan CVD check. Palette validated: #2563eb,#dc2626,#0d9488,#9333ea all-pass.
COLORS = {"throughput": "#2563eb", "avg": "#dc2626", "p50": "#0d9488", "p99": "#9333ea",
          "memtier avg": "#64748b"}


def text(x, y, value, size=13, anchor="middle", weight="normal"):
    return (
        f'<text x="{x}" y="{y}" font-size="{size}" text-anchor="{anchor}" '
        f'font-weight="{weight}" fill="#111827">{html.escape(str(value))}</text>'
    )


def scale(value, maximum, low, high):
    return high - value / maximum * (high - low)


def panel(out, labels, series, top, bottom, y_title, threshold=None):
    left, right = 90, W - 35
    maximum = max(max(values) for values in series.values())
    if threshold is not None:
        maximum = max(maximum, threshold)
    maximum *= 1.12
    out.append(text(left, top - 18, y_title, 13, "start", "bold"))
    out.append(f'<line x1="{left}" y1="{top}" x2="{left}" y2="{bottom}" stroke="#374151"/>')
    out.append(f'<line x1="{left}" y1="{bottom}" x2="{right}" y2="{bottom}" stroke="#374151"/>')
    for i in range(5):
        value = maximum * i / 4
        y = scale(value, maximum, top, bottom)
        out.append(f'<line x1="{left}" y1="{y:.1f}" x2="{right}" y2="{y:.1f}" stroke="#e5e7eb"/>')
        out.append(text(left - 8, y + 4, f"{value:.1f}", 11, "end"))
    if threshold is not None:
        y = scale(threshold, maximum, top, bottom)
        out.append(f'<line x1="{left}" y1="{y:.1f}" x2="{right}" y2="{y:.1f}" '
                   f'stroke="#f59e0b" stroke-dasharray="6 5"/>')
        out.append(text(right - 4, y - 5, f"{threshold:g} us objective", 11, "end"))
    step = (right - left) / max(1, len(labels) - 1)
    xs = [left + i * step for i in range(len(labels))]
    for x, label in zip(xs, labels):
        out.append(text(x, bottom + 20, label, 11))
    for index, (name, values) in enumerate(series.items()):
        color = COLORS[name]
        points = " ".join(f"{x:.1f},{scale(v, maximum, top, bottom):.1f}"
                          for x, v in zip(xs, values))
        out.append(f'<polyline points="{points}" fill="none" stroke="{color}" stroke-width="3"/>')
        for x, value in zip(xs, values):
            y = scale(value, maximum, top, bottom)
            out.append(f'<circle cx="{x:.1f}" cy="{y:.1f}" r="4" fill="{color}"/>')
        out.append(f'<rect x="{left + 150 * index}" y="{top - 37}" width="13" height="4" fill="{color}"/>')
        out.append(text(left + 18 + 150 * index, top - 30, name, 12, "start"))


def figure(path, title, panels):
    height = 90 + len(panels) * 260
    out = [f'<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{height}" '
           f'viewBox="0 0 {W} {height}" font-family="Helvetica, Arial, sans-serif">',
           f'<rect width="{W}" height="{height}" fill="white"/>',
           text(W / 2, 26, title, 18, "middle", "bold")]
    top = 90
    for labels, series, y_title, threshold in panels:
        panel(out, labels, series, top, top + 200, y_title, threshold)
        top += 260
    out.append("</svg>")
    path.write_text("\n".join(out))
    print(path)


def rows_for(rows, phase):
    return [r for r in rows if r["phase"] == phase and r["status"] == "ok"]


def col(rows, key, div=1.0):
    return [float(r[key]) / div for r in rows]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("csv", type=Path)
    parser.add_argument("outdir", type=Path)
    args = parser.parse_args()
    args.outdir.mkdir(parents=True, exist_ok=True)
    with args.csv.open() as f:
        rows = list(csv.DictReader(f))

    r = rows_for(rows, "qpxdepth")
    labels = [f'{x["qp"]}x{x["depth"]}' for x in r]
    figure(args.outdir / "qpxdepth.svg",
           "QP x depth = 128 fixed window, pipeline=8 (2026-07-27)",
           [(labels, {"throughput": col(r, "remote_get_s", 1e6)}, "remote GET M/s", None),
            (labels, {"avg": col(r, "remote_avg_us"), "p50": col(r, "remote_p50_us"),
                      "p99": col(r, "remote_p99_us")}, "remote span us", 30)])

    r = rows_for(rows, "qpd1")
    labels = [x["qp"] for x in r]
    figure(args.outdir / "qpd1.svg",
           "depth=1 QP scaling, pipeline=8 (2026-07-27)",
           [(labels, {"throughput": col(r, "remote_get_s", 1e6)}, "remote GET M/s", None),
            (labels, {"avg": col(r, "remote_avg_us"), "p50": col(r, "remote_p50_us"),
                      "p99": col(r, "remote_p99_us")}, "remote span us", 30)])

    r = rows_for(rows, "plateau")
    labels = [x["pipeline"] for x in r]
    figure(args.outdir / "plateau.svg",
           "Pipeline ladder at mcT=8 QP=8 depth=16 (2026-07-27)",
           [(labels, {"throughput": col(r, "remote_get_s", 1e6)}, "remote GET M/s", None),
            (labels, {"avg": col(r, "remote_avg_us"), "p50": col(r, "remote_p50_us"),
                      "p99": col(r, "remote_p99_us")}, "remote span us", 30),
            (labels, {"memtier avg": col(r, "memtier_avg_us")}, "memtier end-to-end avg us", None)])

    r = rows_for(rows, "plateau_threads")
    labels = [x["mt_threads"] for x in r]
    figure(args.outdir / "plateau-threads.svg",
           "mtT=mcT scaling at pipeline=48 depth=16 (2026-07-27)",
           [(labels, {"throughput": col(r, "remote_get_s", 1e6)}, "remote GET M/s", None),
            (labels, {"avg": col(r, "remote_avg_us"), "p50": col(r, "remote_p50_us"),
                      "p99": col(r, "remote_p99_us")}, "remote span us", 30)])


if __name__ == "__main__":
    main()
