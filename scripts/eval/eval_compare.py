#!/usr/bin/env python3
"""Compare two or more eval score.json files and generate a report.

Usage:
    python3 scripts/eval/eval_compare.py --baseline results/a/score.json --variant results/b/score.json
    python3 scripts/eval/eval_compare.py --baseline a.json --variant b.json --output comparison.md
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path

BOLD = "\033[1m"
DIM = "\033[2m"
RED = "\033[31m"
GREEN = "\033[32m"
YELLOW = "\033[33m"
NC = "\033[0m"

COMPARE_METRICS = [
    ("look_before_act", "higher", "Tool Usage"),
    ("consecutive_actions", "lower", "Tool Usage"),
    ("error_recovery", "higher", "Tool Usage"),
    ("pepper_tool_diversity", "higher", "Tool Usage"),
    ("tool_call_count", "lower", "Efficiency"),
    ("wasted_calls", "lower", "Efficiency"),
    ("reread_ratio", "lower", "Efficiency"),
    ("cost_usd", "lower", "Efficiency"),
    ("composite_score", "higher", "Overall"),
]


def compare(baseline_path: str, variant_path: str) -> dict:
    base = json.loads(Path(baseline_path).read_text())
    var = json.loads(Path(variant_path).read_text())

    rows = []
    for metric, direction, category in COMPARE_METRICS:
        b_val = base.get(metric, 0)
        v_val = var.get(metric, 0)
        if isinstance(b_val, (int, float)) and isinstance(v_val, (int, float)):
            delta = v_val - b_val
            pct = ((delta / abs(b_val)) * 100) if b_val != 0 else (0 if delta == 0 else float("inf"))
            is_improvement = (delta > 0 and direction == "higher") or (delta < 0 and direction == "lower")
            rows.append({
                "metric": metric,
                "category": category,
                "baseline": b_val,
                "variant": v_val,
                "delta": delta,
                "delta_pct": pct,
                "direction": direction,
                "improved": is_improvement,
            })

    return {
        "baseline_path": baseline_path,
        "variant_path": variant_path,
        "metrics": rows,
        "baseline_self_report": base.get("self_report"),
        "variant_self_report": var.get("self_report"),
        "baseline_composite": base.get("composite_score", 0),
        "variant_composite": var.get("composite_score", 0),
    }


def print_comparison(comp: dict) -> None:
    print(f"\n{BOLD}=== Eval Comparison ==={NC}\n")
    print(f"  Baseline: {comp['baseline_path']}")
    print(f"  Variant:  {comp['variant_path']}\n")

    current_cat = ""
    for row in comp["metrics"]:
        if row["category"] != current_cat:
            current_cat = row["category"]
            print(f"  {BOLD}{current_cat}{NC}")

        b = row["baseline"]
        v = row["variant"]
        delta_pct = row["delta_pct"]

        if abs(delta_pct) == float("inf"):
            delta_str = "new"
        else:
            sign = "+" if delta_pct >= 0 else ""
            delta_str = f"{sign}{delta_pct:.0f}%"

        color = GREEN if row["improved"] else (RED if abs(delta_pct) > 5 else DIM)
        fmt_b = f"{b:.2f}" if isinstance(b, float) else str(b)
        fmt_v = f"{v:.2f}" if isinstance(v, float) else str(v)
        print(f"    {row['metric']:<24} {fmt_b:>8} -> {fmt_v:>8}  {color}{delta_str:>8}{NC}")

    bc = comp["baseline_composite"]
    vc = comp["variant_composite"]
    delta = vc - bc
    color = GREEN if delta > 0 else RED if delta < 0 else DIM
    print(f"\n  {BOLD}Composite: {bc:.0f} -> {color}{vc:.0f}{NC} ({'+' if delta >= 0 else ''}{delta:.0f})\n")

    if comp["baseline_self_report"] or comp["variant_self_report"]:
        print(f"  {BOLD}Self-Reports{NC}")
        if comp["baseline_self_report"]:
            suggestions = comp["baseline_self_report"].get("suggestions", [])
            if suggestions:
                print(f"    Baseline: {'; '.join(suggestions)}")
        if comp["variant_self_report"]:
            suggestions = comp["variant_self_report"].get("suggestions", [])
            if suggestions:
                print(f"    Variant:  {'; '.join(suggestions)}")
        print()


def write_markdown(comp: dict, output_path: str) -> None:
    lines = [
        "## Eval Comparison",
        "",
        f"**Baseline**: `{comp['baseline_path']}`",
        f"**Variant**: `{comp['variant_path']}`",
        "",
        "| Metric | Baseline | Variant | Delta |",
        "|--------|----------|---------|-------|",
    ]

    for row in comp["metrics"]:
        b = f"{row['baseline']:.2f}" if isinstance(row["baseline"], float) else str(row["baseline"])
        v = f"{row['variant']:.2f}" if isinstance(row["variant"], float) else str(row["variant"])
        pct = row["delta_pct"]
        if abs(pct) == float("inf"):
            d = "new"
        else:
            sign = "+" if pct >= 0 else ""
            d = f"{sign}{pct:.0f}%"
        lines.append(f"| {row['metric']} | {b} | {v} | {d} |")

    bc = comp["baseline_composite"]
    vc = comp["variant_composite"]
    delta = vc - bc
    lines.extend([
        "",
        f"**Composite: {bc:.0f} -> {vc:.0f} ({'+' if delta >= 0 else ''}{delta:.0f})**",
    ])

    if comp["baseline_self_report"] or comp["variant_self_report"]:
        lines.extend(["", "### Self-Reports"])
        if comp["baseline_self_report"]:
            lines.append(f"**Baseline**: {json.dumps(comp['baseline_self_report'], indent=2)}")
        if comp["variant_self_report"]:
            lines.append(f"**Variant**: {json.dumps(comp['variant_self_report'], indent=2)}")

    lines.append("")
    Path(output_path).write_text("\n".join(lines))
    print(f"Report written to {output_path}")


def main() -> None:
    parser = argparse.ArgumentParser(description="Compare eval scores.")
    parser.add_argument("--baseline", required=True, help="Baseline score.json")
    parser.add_argument("--variant", required=True, help="Variant score.json")
    parser.add_argument("--output", help="Output markdown file")
    args = parser.parse_args()

    comp = compare(args.baseline, args.variant)
    print_comparison(comp)
    if args.output:
        write_markdown(comp, args.output)


if __name__ == "__main__":
    main()
