#!/usr/bin/env python3
"""
benchmark-report.py - Generate Comparison Reports from Benchmark Results

Reads benchmark results (CSV/JSON) from the results/ directory and generates
comparison tables, speedup ratios, and markdown reports.

Usage:
  python3 benchmark-report.py
  python3 benchmark-report.py --results-dir ../results --baseline 70b-tp4
  python3 benchmark-report.py --format markdown --output report.md
"""

import argparse
import csv
import glob
import json
import os
import sys
from datetime import datetime


def load_json_results(results_dir):
    """Load all JSON result files from the results directory."""
    results = []
    pattern = os.path.join(results_dir, "vllm-*.json")
    for filepath in sorted(glob.glob(pattern)):
        basename = os.path.basename(filepath)
        # Parse profile from filename: vllm-PROFILE-TIMESTAMP.json
        parts = basename.replace(".json", "").split("-")
        if len(parts) >= 3:
            # Handle profiles with hyphens (e.g., "8b-mig")
            timestamp = parts[-1]
            profile = "-".join(parts[1:-2]) if len(parts) > 3 else parts[1]
        else:
            continue

        try:
            with open(filepath, "r") as f:
                data = json.load(f)
        except (json.JSONDecodeError, FileNotFoundError):
            print(f"  Warning: Could not parse {filepath}", file=sys.stderr)
            continue

        metrics = data.get("metrics", data)
        results.append({
            "profile": profile,
            "timestamp": timestamp,
            "filepath": filepath,
            "metrics": metrics,
        })

    return results


def load_csv_results(filepath):
    """Load results from a comparison CSV file."""
    results = []
    with open(filepath, "r") as f:
        reader = csv.DictReader(f)
        for row in reader:
            results.append({
                "profile": row.get("profile", "unknown"),
                "timestamp": "",
                "filepath": filepath,
                "metrics": row,
            })
    return results


def get_metric(metrics, key, *alt_keys):
    """Extract a metric value, trying alternative key names."""
    val = metrics.get(key)
    if val is None or val == "":
        for k in alt_keys:
            val = metrics.get(k)
            if val is not None and val != "":
                break
    if val is None or val == "":
        return None
    try:
        return float(val)
    except (ValueError, TypeError):
        return None


def extract_standard_metrics(result):
    """Extract a standard set of metrics from a result entry."""
    m = result["metrics"]
    return {
        "profile": result["profile"],
        "ttft_p50": get_metric(m, "ttft_p50_ms", "median_ttft_ms"),
        "ttft_p99": get_metric(m, "ttft_p99_ms", "p99_ttft_ms"),
        "tpot_p50": get_metric(m, "tpot_p50_ms", "median_tpot_ms"),
        "tpot_p99": get_metric(m, "tpot_p99_ms", "p99_tpot_ms"),
        "throughput": get_metric(m, "output_throughput", "request_throughput", "throughput_tps"),
        "completed": get_metric(m, "completed"),
        "errors": get_metric(m, "errors"),
    }


def compute_speedups(results_std, baseline_profile):
    """Compute speedup ratios relative to a baseline profile."""
    baseline = None
    for r in results_std:
        if r["profile"] == baseline_profile:
            baseline = r
            break

    if baseline is None:
        return None

    speedups = []
    for r in results_std:
        s = {"profile": r["profile"]}

        # For latency: speedup = baseline / current (lower is better)
        for key in ["ttft_p50", "ttft_p99", "tpot_p50", "tpot_p99"]:
            bv = baseline.get(key)
            cv = r.get(key)
            if bv and cv and cv > 0:
                s[f"{key}_speedup"] = bv / cv
            else:
                s[f"{key}_speedup"] = None

        # For throughput: speedup = current / baseline (higher is better)
        bt = baseline.get("throughput")
        ct = r.get("throughput")
        if bt and ct and bt > 0:
            s["throughput_speedup"] = ct / bt
        else:
            s["throughput_speedup"] = None

        speedups.append(s)

    return speedups


def format_value(val, decimals=2):
    """Format a numeric value or return N/A."""
    if val is None:
        return "N/A"
    if isinstance(val, float):
        return f"{val:.{decimals}f}"
    return str(val)


def format_speedup(val):
    """Format speedup as 1.23x or N/A."""
    if val is None:
        return "N/A"
    return f"{val:.2f}x"


def generate_markdown_report(results_std, speedups, baseline_profile):
    """Generate a markdown comparison report."""
    lines = []
    lines.append(f"# LLM Inference Benchmark Report")
    lines.append(f"")
    lines.append(f"Generated: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")
    lines.append(f"Baseline: **{baseline_profile}**")
    lines.append(f"")

    # Summary table
    lines.append("## Results Summary")
    lines.append("")
    lines.append("| Profile | TTFT P50 (ms) | TTFT P99 (ms) | TPOT P50 (ms) | TPOT P99 (ms) | Throughput (tok/s) | Completed | Errors |")
    lines.append("|---------|--------------|--------------|--------------|--------------|-------------------|-----------|--------|")

    for r in results_std:
        lines.append(
            f"| {r['profile']} "
            f"| {format_value(r['ttft_p50'])} "
            f"| {format_value(r['ttft_p99'])} "
            f"| {format_value(r['tpot_p50'])} "
            f"| {format_value(r['tpot_p99'])} "
            f"| {format_value(r['throughput'])} "
            f"| {format_value(r['completed'], 0)} "
            f"| {format_value(r['errors'], 0)} |"
        )

    lines.append("")

    # Speedup table
    if speedups:
        lines.append(f"## Speedup vs Baseline ({baseline_profile})")
        lines.append("")
        lines.append("| Profile | TTFT P50 | TTFT P99 | TPOT P50 | TPOT P99 | Throughput |")
        lines.append("|---------|----------|----------|----------|----------|------------|")

        for s in speedups:
            lines.append(
                f"| {s['profile']} "
                f"| {format_speedup(s.get('ttft_p50_speedup'))} "
                f"| {format_speedup(s.get('ttft_p99_speedup'))} "
                f"| {format_speedup(s.get('tpot_p50_speedup'))} "
                f"| {format_speedup(s.get('tpot_p99_speedup'))} "
                f"| {format_speedup(s.get('throughput_speedup'))} |"
            )

        lines.append("")
        lines.append("> For latency metrics, speedup > 1.0 means faster than baseline.")
        lines.append("> For throughput, speedup > 1.0 means higher throughput than baseline.")

    lines.append("")

    # Key findings
    lines.append("## Key Findings")
    lines.append("")

    # Find best profile for each metric
    best = {}
    for metric_key, label, lower_better in [
        ("ttft_p50", "TTFT P50", True),
        ("ttft_p99", "TTFT P99", True),
        ("tpot_p50", "TPOT P50", True),
        ("tpot_p99", "TPOT P99", True),
        ("throughput", "Throughput", False),
    ]:
        valid = [(r["profile"], r[metric_key]) for r in results_std if r[metric_key] is not None]
        if valid:
            if lower_better:
                best_profile, best_val = min(valid, key=lambda x: x[1])
            else:
                best_profile, best_val = max(valid, key=lambda x: x[1])
            lines.append(f"- **Best {label}**: {best_profile} ({format_value(best_val)}{'ms' if 'tp' in metric_key.lower() or 'ttft' in metric_key.lower() else ' tok/s'})")

    lines.append("")
    return "\n".join(lines)


def generate_text_report(results_std, speedups, baseline_profile):
    """Generate a plain-text comparison report."""
    lines = []
    lines.append("=" * 90)
    lines.append("  LLM Inference Benchmark Report")
    lines.append(f"  Generated: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")
    lines.append(f"  Baseline:  {baseline_profile}")
    lines.append("=" * 90)
    lines.append("")

    # Results table
    header = f"{'Profile':<15} {'TTFT P50':>10} {'TTFT P99':>10} {'TPOT P50':>10} {'TPOT P99':>10} {'Tput(t/s)':>12} {'Done':>6} {'Err':>5}"
    lines.append(header)
    lines.append("-" * len(header))

    for r in results_std:
        lines.append(
            f"{r['profile']:<15} "
            f"{format_value(r['ttft_p50']):>10} "
            f"{format_value(r['ttft_p99']):>10} "
            f"{format_value(r['tpot_p50']):>10} "
            f"{format_value(r['tpot_p99']):>10} "
            f"{format_value(r['throughput']):>12} "
            f"{format_value(r['completed'], 0):>6} "
            f"{format_value(r['errors'], 0):>5}"
        )

    lines.append("")

    # Speedup table
    if speedups:
        lines.append(f"Speedup vs {baseline_profile}:")
        header2 = f"{'Profile':<15} {'TTFT P50':>10} {'TTFT P99':>10} {'TPOT P50':>10} {'TPOT P99':>10} {'Throughput':>12}"
        lines.append(header2)
        lines.append("-" * len(header2))
        for s in speedups:
            lines.append(
                f"{s['profile']:<15} "
                f"{format_speedup(s.get('ttft_p50_speedup')):>10} "
                f"{format_speedup(s.get('ttft_p99_speedup')):>10} "
                f"{format_speedup(s.get('tpot_p50_speedup')):>10} "
                f"{format_speedup(s.get('tpot_p99_speedup')):>10} "
                f"{format_speedup(s.get('throughput_speedup')):>12}"
            )

    lines.append("")
    return "\n".join(lines)


def generate_chart(results_std, output_path):
    """Generate comparison bar chart if matplotlib is available."""
    try:
        import matplotlib
        matplotlib.use("Agg")
        import matplotlib.pyplot as plt
        import numpy as np
    except ImportError:
        print("  matplotlib not available, skipping chart generation.", file=sys.stderr)
        return

    profiles = [r["profile"] for r in results_std]
    metrics = {
        "TTFT P50 (ms)": [r.get("ttft_p50") or 0 for r in results_std],
        "TTFT P99 (ms)": [r.get("ttft_p99") or 0 for r in results_std],
        "TPOT P50 (ms)": [r.get("tpot_p50") or 0 for r in results_std],
        "TPOT P99 (ms)": [r.get("tpot_p99") or 0 for r in results_std],
    }

    fig, axes = plt.subplots(2, 2, figsize=(14, 10))
    fig.suptitle("LLM Inference Benchmark Comparison", fontsize=14)

    colors = ["#1f77b4", "#ff7f0e", "#2ca02c", "#d62728", "#9467bd"]

    for ax, (title, values) in zip(axes.flat, metrics.items()):
        bars = ax.bar(profiles, values, color=colors[:len(profiles)])
        ax.set_title(title)
        ax.set_ylabel("milliseconds")
        ax.tick_params(axis="x", rotation=45)
        # Add value labels
        for bar, val in zip(bars, values):
            if val > 0:
                ax.text(
                    bar.get_x() + bar.get_width() / 2,
                    bar.get_height(),
                    f"{val:.1f}",
                    ha="center", va="bottom", fontsize=8,
                )

    plt.tight_layout()
    fig.savefig(output_path, dpi=150, bbox_inches="tight")
    print(f"  Chart saved to: {output_path}")
    plt.close(fig)


def main():
    parser = argparse.ArgumentParser(
        description="Generate benchmark comparison reports",
    )
    parser.add_argument(
        "--results-dir",
        default=None,
        help="Directory containing result files (default: benchmarks/results/)",
    )
    parser.add_argument(
        "--csv",
        default=None,
        help="Load from a specific CSV file instead of JSON results",
    )
    parser.add_argument(
        "--baseline",
        default="70b-tp4",
        help="Baseline profile for speedup comparison (default: 70b-tp4)",
    )
    parser.add_argument(
        "--format",
        choices=["text", "markdown", "both"],
        default="both",
        help="Output format (default: both)",
    )
    parser.add_argument(
        "--output",
        default=None,
        help="Output file path (default: results/benchmark-report.*)",
    )
    parser.add_argument(
        "--chart",
        action="store_true",
        help="Generate comparison bar chart",
    )

    args = parser.parse_args()

    # Resolve results directory
    if args.results_dir:
        results_dir = args.results_dir
    else:
        script_dir = os.path.dirname(os.path.abspath(__file__))
        results_dir = os.path.join(script_dir, "..", "results")

    # Load results
    if args.csv:
        print(f"Loading results from CSV: {args.csv}")
        raw_results = load_csv_results(args.csv)
    else:
        print(f"Loading results from: {results_dir}")
        raw_results = load_json_results(results_dir)

    if not raw_results:
        print("No benchmark results found.")
        print(f"  Searched: {results_dir}")
        print("  Run benchmarks first: benchmarks/scripts/run-all-benchmarks.sh")
        sys.exit(1)

    # Deduplicate: keep latest result per profile
    latest_by_profile = {}
    for r in raw_results:
        p = r["profile"]
        if p not in latest_by_profile or r["timestamp"] > latest_by_profile[p]["timestamp"]:
            latest_by_profile[p] = r

    results = list(latest_by_profile.values())
    print(f"Found results for {len(results)} profiles: {[r['profile'] for r in results]}")

    # Extract standardized metrics
    results_std = [extract_standard_metrics(r) for r in results]

    # Compute speedups
    speedups = compute_speedups(results_std, args.baseline)
    if speedups is None:
        print(f"Warning: Baseline profile '{args.baseline}' not found in results.")
        print(f"  Available profiles: {[r['profile'] for r in results]}")
        speedups = []

    # Generate reports
    if args.format in ("text", "both"):
        text_report = generate_text_report(results_std, speedups, args.baseline)
        print("")
        print(text_report)

        if args.output or args.format == "both":
            text_path = args.output or os.path.join(results_dir, "benchmark-report.txt")
            with open(text_path, "w") as f:
                f.write(text_report)
            print(f"Text report saved to: {text_path}")

    if args.format in ("markdown", "both"):
        md_report = generate_markdown_report(results_std, speedups, args.baseline)

        if args.format == "markdown":
            print("")
            print(md_report)

        md_path = args.output if (args.output and args.format == "markdown") else os.path.join(results_dir, "benchmark-report.md")
        with open(md_path, "w") as f:
            f.write(md_report)
        print(f"Markdown report saved to: {md_path}")

    # Generate chart
    if args.chart:
        chart_path = os.path.join(results_dir, "benchmark-comparison.png")
        generate_chart(results_std, chart_path)

    print("\nReport generation complete.")


if __name__ == "__main__":
    main()
