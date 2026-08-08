#!/usr/bin/env python3
"""Plot the semi-final R6 tables directly from RESULTS2.md.

The markdown is the published data source.  Parsing it here avoids a second,
manually maintained copy of the measurements in the plotting code.
"""

import argparse
import math
from pathlib import Path

import matplotlib.pyplot as plt
from matplotlib.lines import Line2D
from matplotlib.patches import Patch
from matplotlib.ticker import FuncFormatter, MaxNLocator


plt.rcParams.update({"font.family": "NanumGothic", "axes.unicode_minus": False})


WORKLOADS = ("YCSB-C", "YCSB-B", "YCSB-A")
DISTRIBUTIONS = ("uniform", "zipfian")

EXPERIMENTS = (
    (1, "P 파이프라인", "pipeline", "Pipeline", ("1", "8", "32", "64", "128", "256", "384", "512"), "256"),
    (2, "T 스레드", "mcT", "memcached threads", ("1", "2", "4", "8", "12", "16", "24", "28", "30"), "30"),
    (3, "D 값 크기", "d(B)", "Value size (B)", ("4", "8", "16", "24", "32", "48", "64", "96", "128"), "64"),
    (4, "C 체인", "chain", "ext_post_chain", tuple(str(v) for v in range(1, 17)), "8"),
    (5, "Q nqp", "nqp", "QP count", ("1", "2", "4", "8", "16", "64"), "4"),
    (6, "O ORD", "ORD", "RDMA read depth", ("1", "2", "4", "8", "협상16"), "협상16"),
    (7, "S 형태(wire 256)", "형태", "nqp x ORD (wire window = 256)",
     ("16×16", "32×8", "64×4", "128×2", "256×1"), None),
    (8, "E 클라×파이프", "c×pipe", "Clients x pipeline (product = 1,024)",
     ("1×1024", "2×512", "4×256", "8×128", "16×64", "32×32", "64×16", "128×8"), "4×256"),
)

FILE_STEMS = {
    1: "exp1-pipeline",
    2: "exp2-threads",
    3: "exp3-value-size",
    4: "exp4-ext-post-chain",
    5: "exp5-nqp",
    6: "exp6-ord",
    7: "exp7-wire-shape",
    8: "exp8-client-pipeline",
    9: "exp9-key-distribution",
}

COLORS = {
    "uniform": "#2563eb",
    "zipfian": "#dc2626",
    "throughput": "#111827",
    "admit": "#e76f51",
    "sync": "#6d597a",
    "xfer": "#2a9d8f",
    "crypto": "#e9c46a",
    "residual": "#8d99ae",
    "return": "#457b9d",
}

WORKLOAD_COLORS = {
    "YCSB-C": "#2563eb",
    "YCSB-B": "#9333ea",
    "YCSB-A": "#dc2626",
}


def cells(line):
    return [cell.strip() for cell in line.strip().strip("|").split("|")]


def parse_tables(path):
    """Return {section title: [{column: value, ...}, ...] tables}."""
    lines = path.read_text(encoding="utf-8").splitlines()
    sections = {}
    section = None
    i = 0
    while i < len(lines):
        line = lines[i]
        if line.startswith("### "):
            section = line[4:].strip()
            sections.setdefault(section, [])
        if (section is not None and line.startswith("|") and i + 1 < len(lines)
                and lines[i + 1].startswith("|---")):
            header = cells(line)
            rows = []
            i += 2
            while i < len(lines) and lines[i].startswith("|"):
                values = cells(lines[i])
                if len(values) == len(header):
                    rows.append(dict(zip(header, values)))
                i += 1
            sections[section].append(rows)
            continue
        i += 1
    return sections


def find_table(tables, section, required):
    for table in tables.get(section, []):
        if table and required.issubset(table[0]):
            return table
    raise ValueError(f"{section}: no table with columns {sorted(required)}")


def number(row, key):
    try:
        value = float(row[key])
    except (KeyError, ValueError) as exc:
        raise ValueError(f"invalid {key!r} in row {row}") from exc
    if not math.isfinite(value):
        raise ValueError(f"non-finite {key!r} in row {row}")
    return value


def index_rows(rows, variable):
    return {(row[variable], row["분포"], row["워크로드"]): row for row in rows}


def ordered_rows(index, values, distribution, workload):
    result = []
    for value in values:
        key = (value, distribution, workload)
        if key not in index:
            raise ValueError(f"missing table row: {key}")
        result.append(index[key])
    return result


def padded_limits(values, fraction=0.13):
    low, high = min(values), max(values)
    span = high - low
    if span == 0:
        span = max(abs(low), 1.0) * 0.15
    return max(0.0, low - span * fraction), high + span * fraction


def metric_formatter(value, _position):
    if abs(value) >= 1000:
        return f"{value / 1000:g}k"
    return f"{value:g}"


def display_label(value):
    return "16" if value == "협상16" else value


def annotate_points(ax, xs, ys, labels, color):
    offsets = ((3, 3), (3, -4), (-3, 3), (-3, -4))
    xlow, xhigh = ax.get_xlim()
    ylow, yhigh = ax.get_ylim()
    for i, (x, y, label) in enumerate(zip(xs, ys, labels)):
        dx, dy = offsets[i % len(offsets)]
        if x < xlow + (xhigh - xlow) * 0.16:
            dx = abs(dx)
        elif x > xhigh - (xhigh - xlow) * 0.16:
            dx = -abs(dx)
        if y < ylow + (yhigh - ylow) * 0.16:
            dy = abs(dy)
        elif y > yhigh - (yhigh - ylow) * 0.16:
            dy = -abs(dy)
        ax.annotate(
            label,
            (x, y),
            xytext=(dx, dy),
            textcoords="offset points",
            ha="left" if dx > 0 else "right",
            va="bottom" if dy > 0 else "top",
            fontsize=7.0,
            color=color,
            bbox={"boxstyle": "square,pad=0.04", "facecolor": "white", "edgecolor": "none", "alpha": 0.62},
            clip_on=True,
        )


def style_axis(ax):
    ax.grid(True, color="#e5e7eb", linewidth=0.7)
    ax.set_axisbelow(True)
    ax.spines[["top", "right"]].set_visible(False)
    ax.xaxis.set_major_locator(MaxNLocator(5))
    ax.yaxis.set_major_locator(MaxNLocator(5))
    ax.yaxis.set_major_formatter(FuncFormatter(metric_formatter))
    ax.tick_params(labelsize=8)


def save_figure(fig, outdir, distribution, stem):
    svg_dir = outdir / distribution / "svg"
    png_dir = outdir / distribution / "png"
    svg_dir.mkdir(parents=True, exist_ok=True)
    png_dir.mkdir(parents=True, exist_ok=True)
    svg = svg_dir / f"{stem}.svg"
    png = png_dir / f"{stem}.png"
    fig.savefig(svg, bbox_inches="tight", facecolor="white")
    fig.savefig(png, dpi=180, bbox_inches="tight", facecolor="white")
    plt.close(fig)
    print(svg)
    print(png)


def throughput_latency_figure(tables, experiment, outdir, distribution):
    number_id, section, variable, title, values, _operating_value = experiment
    read_rows = find_table(tables, section, {variable, "분포", "워크로드", "Mops"})
    client_rows = find_table(tables, section, {variable, "분포", "워크로드", "srv"})
    read_index = index_rows(read_rows, variable)
    client_index = index_rows(client_rows, variable)

    fig, axes = plt.subplots(1, 3, figsize=(13.2, 4.2))
    for column_index, workload in enumerate(WORKLOADS):
        ax = axes[column_index]
        throughput = ordered_rows(read_index, values, distribution, workload)
        latency = ordered_rows(client_index, values, distribution, workload)
        xs = [number(row, "Mops") for row in throughput]
        ys = [number(row, "srv") for row in latency]
        color = COLORS[distribution]
        ax.plot(xs, ys, color=color, linewidth=1.4, alpha=0.65, zorder=2)
        ax.scatter(xs, ys, s=28, color=color, edgecolors="white", linewidths=0.7, zorder=3)
        ax.set_xlim(*padded_limits(xs))
        ax.set_ylim(*padded_limits(ys))
        annotate_points(ax, xs, ys, [display_label(value) for value in values], color)
        style_axis(ax)
        ax.set_title(workload, fontsize=10, fontweight="bold")
        ax.set_xlabel("Throughput (M ops/s)", fontsize=9)
        if column_index == 0:
            ax.set_ylabel("Client latency, srv avg (us)", fontsize=9)

    fig.suptitle(f"Experiment {number_id}: {title} - throughput vs. client latency ({distribution})",
                 fontsize=15, fontweight="bold", y=0.98)
    fig.text(0.5, 0.91,
             "Each panel is autoscaled; labels are the swept variable. Lines connect values in PLAN.md order.",
             ha="center", va="top", fontsize=9, color="#4b5563")
    fig.subplots_adjust(left=0.07, right=0.98, bottom=0.15, top=0.80, wspace=0.24)
    save_figure(fig, outdir, distribution, f"{FILE_STEMS[number_id]}-throughput-latency")


def distribution_figure(tables, outdir):
    section = "분포 (9번 축 전용 대조)"
    variable = "셀"
    read_rows = find_table(tables, section, {variable, "분포", "워크로드", "Mops"})
    client_rows = find_table(tables, section, {variable, "분포", "워크로드", "srv"})
    throughput = {(row["분포"], row["워크로드"]): row for row in read_rows}
    latency = {(row["분포"], row["워크로드"]): row for row in client_rows}

    fig, ax = plt.subplots(figsize=(8.2, 5.8))
    all_latency = []
    all_throughput = []
    marker_by_distribution = {"uniform": "o", "zipfian": "s"}
    short_label = {"uniform": "U", "zipfian": "Z"}

    for workload in WORKLOADS:
        xs = [number(latency[(distribution, workload)], "srv") for distribution in DISTRIBUTIONS]
        ys = [number(throughput[(distribution, workload)], "Mops") for distribution in DISTRIBUTIONS]
        color = WORKLOAD_COLORS[workload]
        ax.plot(xs, ys, color=color, linewidth=1.4, alpha=0.5, zorder=2)
        for x, y, distribution in zip(xs, ys, DISTRIBUTIONS):
            ax.scatter([x], [y], s=58, marker=marker_by_distribution[distribution],
                       color=color, edgecolors="white", linewidths=0.8, zorder=3)
            ax.annotate(short_label[distribution], (x, y), xytext=(3, 3),
                        textcoords="offset points", fontsize=8, color=color)
        all_latency.extend(xs)
        all_throughput.extend(ys)

    ax.set_xlim(*padded_limits(all_latency, 0.13))
    ax.set_ylim(*padded_limits(all_throughput, 0.16))
    style_axis(ax)
    ax.xaxis.set_major_formatter(FuncFormatter(metric_formatter))
    ax.set_xlabel("Client latency, srv avg (us)", fontsize=10)
    ax.set_ylabel("Throughput (M ops/s)", fontsize=10)

    workload_handles = [
        Line2D([0], [0], color=WORKLOAD_COLORS[workload], marker="o", linewidth=1.4,
               markersize=5, label=workload)
        for workload in WORKLOADS
    ]
    distribution_handles = [
        Line2D([0], [0], color="#374151", marker=marker_by_distribution[distribution],
               linestyle="none", markersize=6, label=distribution)
        for distribution in DISTRIBUTIONS
    ]
    ax.legend(handles=workload_handles + distribution_handles, loc="upper center",
              bbox_to_anchor=(0.5, 1.02), ncol=5, frameon=False, fontsize=8.5)
    fig.suptitle("Experiment 9: key distribution - throughput vs. client latency",
                 fontsize=15, fontweight="bold", y=0.98)
    fig.text(0.5, 0.91,
             "Color = YCSB workload; marker = key distribution; lines connect the U/Z pair.",
             ha="center", fontsize=9, color="#4b5563")
    fig.subplots_adjust(left=0.12, right=0.98, bottom=0.13, top=0.78)
    save_figure(fig, outdir, "comparison", f"{FILE_STEMS[9]}-throughput-latency")


def derived_get_components(row):
    admit = number(row, "Gadmit")
    sync = number(row, "Gsync")
    xfer = number(row, "Gxfer")
    crypto = number(row, "Gcrypto")
    v2 = number(row, "Gv2")
    total = number(row, "Gv3_avg")
    residual = max(0.0, v2 - sync - xfer - crypto)
    returned = max(0.0, total - admit - v2)
    return admit, sync, xfer, crypto, residual, returned


def derived_set_components(row):
    admit = number(row, "Sadmit")
    xfer = number(row, "Sxfer")
    crypto = number(row, "Scrypto")
    v2 = number(row, "Sv2")
    returned = number(row, "Sret")
    residual = max(0.0, v2 - xfer - crypto)
    return admit, 0.0, xfer, crypto, residual, returned


def experiment4_figure(tables, outdir, distribution, workload):
    """Reference-like curve + horizontal breakdown for one distribution/workload."""
    section = "C 체인"
    values = tuple(str(v) for v in range(1, 17))
    throughput_rows = find_table(tables, section, {"chain", "분포", "워크로드", "Mops"})
    client_rows = find_table(tables, section, {"chain", "분포", "워크로드", "srv"})
    get_rows = find_table(tables, section,
                          {"chain", "분포", "워크로드", "Gv3_avg", "Gv2"})
    set_rows = find_table(tables, section,
                          {"chain", "분포", "워크로드", "Sv3_avg", "Sv2"})
    throughput_index = index_rows(throughput_rows, "chain")
    client_index = index_rows(client_rows, "chain")
    get_index = index_rows(get_rows, "chain")
    set_index = index_rows(set_rows, "chain")

    throughput = ordered_rows(throughput_index, values, distribution, workload)
    client = ordered_rows(client_index, values, distribution, workload)
    get_span = ordered_rows(get_index, values, distribution, workload)
    set_span = ordered_rows(set_index, values, distribution, workload)
    xs = [number(row, "Mops") for row in throughput]
    ys = [number(row, "srv") for row in client]
    has_set = workload != "YCSB-C"

    if has_set:
        fig, (curve_ax, get_ax, set_ax) = plt.subplots(
            1, 3, figsize=(18.0, 8.2),
            gridspec_kw={"width_ratios": (0.90, 1.15, 1.15)},
        )
    else:
        fig, (curve_ax, get_ax) = plt.subplots(
            1, 2, figsize=(14.2, 8.2),
            gridspec_kw={"width_ratios": (0.92, 1.35)},
        )
        set_ax = None

    color = COLORS[distribution]
    curve_ax.plot(xs, ys, color=color, linewidth=1.7, alpha=0.68, zorder=2)
    curve_ax.scatter(xs, ys, s=34, color=color, edgecolors="white", linewidths=0.7, zorder=3)
    curve_ax.set_xlim(*padded_limits(xs, 0.16))
    curve_ax.set_ylim(*padded_limits(ys, 0.16))
    annotate_points(curve_ax, xs, ys, values, color)
    style_axis(curve_ax)
    curve_ax.set_box_aspect(1)
    curve_ax.set_title("(a) Throughput-latency", fontsize=11, fontweight="bold")
    curve_ax.set_xlabel("Throughput (M ops/s)", fontsize=10)
    curve_ax.set_ylabel("Client latency, srv avg (us)", fontsize=10)

    component_names = ("admit (batch wait)", "sync", "xfer", "crypto", "other v2", "return")
    component_colors = (COLORS["admit"], COLORS["sync"], COLORS["xfer"],
                        COLORS["crypto"], COLORS["residual"], COLORS["return"])
    get_components = list(zip(*(derived_get_components(row) for row in get_span)))
    set_components = list(zip(*(derived_set_components(row) for row in set_span)))

    def horizontal_stack(ax, components):
        y_positions = list(range(len(values)))
        left = [0.0] * len(values)
        for values_by_component, component_color in zip(components, component_colors):
            ax.barh(
                y_positions,
                values_by_component,
                left=left,
                height=0.58,
                color=component_color,
                alpha=0.92,
                edgecolor="white",
                linewidth=0.25,
            )
            left = [a + b for a, b in zip(left, values_by_component)]

    def style_breakdown(ax, title, operation):
        positions = list(range(len(values)))
        ax.set_yticks(positions, values)
        ax.invert_yaxis()
        ax.set_axisbelow(True)
        ax.grid(True, axis="x", color="#e5e7eb", linewidth=0.7)
        ax.spines[["top", "right"]].set_visible(False)
        ax.xaxis.set_major_locator(MaxNLocator(5))
        ax.xaxis.set_major_formatter(FuncFormatter(metric_formatter))
        ax.tick_params(labelsize=8)
        ax.set_title(title, fontsize=11, fontweight="bold")
        ax.set_xlabel(f"{operation} span v3 avg (us)", fontsize=10)
        ax.set_ylabel("ext_post_chain", fontsize=10)

    horizontal_stack(get_ax, get_components)
    style_breakdown(get_ax, "(b) GET latency breakdown", "GET")
    if has_set:
        horizontal_stack(set_ax, set_components)
        style_breakdown(set_ax, "(c) SET latency breakdown", "SET")

    legend_handles = [Patch(facecolor=color, label=name) for color, name
                      in zip(component_colors, component_names)]
    fig.suptitle(
        f"Experiment 4: ext_post_chain - {workload} ({distribution})",
        fontsize=15,
        fontweight="bold",
        y=0.985,
    )
    fig.text(
        0.5,
        0.94,
        "Each point/bar is one chain value; breakdown colors encode latency components only.",
        ha="center",
        fontsize=9,
        color="#4b5563",
    )
    fig.legend(legend_handles, component_names, loc="upper center", bbox_to_anchor=(0.5, 0.91),
               ncol=6, frameon=False, fontsize=8.4)
    left = 0.055 if has_set else 0.07
    spacing = 0.27 if has_set else 0.24
    fig.subplots_adjust(left=left, right=0.985, bottom=0.10, top=0.83, wspace=spacing)
    stem = f"{FILE_STEMS[4]}-{workload.lower()}"
    save_figure(fig, outdir, distribution, stem)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("results", nargs="?", type=Path,
                        default=Path("experiments/semi_final/RESULTS2.md"))
    parser.add_argument("outdir", nargs="?", type=Path,
                        default=Path("img/semi-final-r6"))
    args = parser.parse_args()

    tables = parse_tables(args.results)
    for distribution in DISTRIBUTIONS:
        for experiment in EXPERIMENTS:
            if experiment[0] != 4:
                throughput_latency_figure(tables, experiment, args.outdir, distribution)
        for workload in WORKLOADS:
            experiment4_figure(tables, args.outdir, distribution, workload)
    distribution_figure(tables, args.outdir)


if __name__ == "__main__":
    main()
