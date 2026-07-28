#!/usr/bin/env python3
"""Render v2 results.csv into one dependency-free SVG per phase."""

import argparse
import csv
import html
from pathlib import Path

WIDTH, HEIGHT = 960, 560
X_FIELDS = {
    "threads": "mc_threads",
    "pipeline": "pipeline",
    "window": "worker_window",
    "nqp": "qp_per_worker",
}


def esc(value):
    return html.escape(str(value))


def text(x, y, value, size=12, anchor="middle", weight="normal"):
    return (
        f'<text x="{x}" y="{y}" font-size="{size}" text-anchor="{anchor}" '
        f'font-weight="{weight}" fill="#111827">{esc(value)}</text>'
    )


def chart(path, phase, rows):
    rows = [r for r in rows if r["phase"] == phase and r["status"] == "ok"]
    if not rows:
        return
    xfield = X_FIELDS[phase]
    labels = [r[xfield] for r in rows]
    throughput = [float(r["server_get_s"]) / 1_000_000 for r in rows]
    avg = [float(r["remote_avg_us"]) for r in rows]
    p99 = [float(r["remote_p99_us"]) for r in rows]

    left, right = 80, WIDTH - 35
    top1, bottom1 = 70, 245
    top2, bottom2 = 330, 505
    xs = [left + i * (right - left) / max(1, len(rows) - 1)
          for i in range(len(rows))]
    out = [
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{WIDTH}" '
        f'height="{HEIGHT}" viewBox="0 0 {WIDTH} {HEIGHT}">',
        '<rect width="100%" height="100%" fill="white"/>',
        text(WIDTH / 2, 30, f"v2 {phase} sweep", 18, weight="bold"),
    ]

    def panel(values, top, bottom, color, ylabel, threshold=None):
        maximum = max(values + ([threshold] if threshold is not None else [0]))
        maximum = max(maximum * 1.12, 1)
        out.extend([
            text(left, top - 12, ylabel, 12, "start", "bold"),
            f'<line x1="{left}" y1="{top}" x2="{left}" y2="{bottom}" stroke="#374151"/>',
            f'<line x1="{left}" y1="{bottom}" x2="{right}" y2="{bottom}" stroke="#374151"/>',
        ])
        for i in range(5):
            value = maximum * i / 4
            y = bottom - value / maximum * (bottom - top)
            out.append(f'<line x1="{left}" y1="{y:.1f}" x2="{right}" y2="{y:.1f}" stroke="#e5e7eb"/>')
            out.append(text(left - 8, y + 4, f"{value:.1f}", 10, "end"))
        if threshold is not None:
            y = bottom - threshold / maximum * (bottom - top)
            out.append(f'<line x1="{left}" y1="{y:.1f}" x2="{right}" y2="{y:.1f}" stroke="#f59e0b" stroke-dasharray="6 5"/>')
        points = []
        for x, value, label in zip(xs, values, labels):
            y = bottom - value / maximum * (bottom - top)
            points.append(f"{x:.1f},{y:.1f}")
            out.append(f'<circle cx="{x:.1f}" cy="{y:.1f}" r="4" fill="{color}"/>')
            out.append(text(x, bottom + 18, label, 10))
        out.append(f'<polyline points="{" ".join(points)}" fill="none" stroke="{color}" stroke-width="3"/>')

    panel(throughput, top1, bottom1, "#2563eb", "server GET (M/s)")
    panel(avg, top2, bottom2, "#16a34a", "avg span-v2 (us)", 30)

    maximum = max(max(p99) * 1.12, 30)
    points = []
    for x, value in zip(xs, p99):
        y = bottom2 - value / maximum * (bottom2 - top2)
        points.append(f"{x:.1f},{y:.1f}")
        out.append(f'<circle cx="{x:.1f}" cy="{y:.1f}" r="4" fill="#9333ea"/>')
    out.append(f'<polyline points="{" ".join(points)}" fill="none" stroke="#9333ea" stroke-width="3"/>')
    out.append(text(right, top2 - 12, "green=avg, purple=p99", 11, "end"))
    out.append("</svg>")
    path.write_text("\n".join(out) + "\n")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("csv", type=Path)
    parser.add_argument("--out", type=Path)
    args = parser.parse_args()
    outdir = args.out or args.csv.parent
    outdir.mkdir(parents=True, exist_ok=True)
    with args.csv.open(newline="") as handle:
        rows = list(csv.DictReader(handle))
    for phase in X_FIELDS:
        chart(outdir / f"{phase}.svg", phase, rows)


if __name__ == "__main__":
    main()
