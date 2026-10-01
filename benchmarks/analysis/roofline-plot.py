#!/usr/bin/env python3
"""
roofline-plot.py - Generate Roofline Model Plots for LLM Inference

Visualizes the roofline model showing where prefill and decode operations
land relative to the compute and memory bandwidth ceilings for different GPUs.

The roofline model plots:
  - X-axis: Arithmetic Intensity (FLOPs/byte)
  - Y-axis: Attainable Performance (TFLOPS)
  - Memory bandwidth ceiling (diagonal line)
  - Compute ceiling (horizontal line)
  - Operating points for prefill and decode at various batch sizes

Usage:
  python3 roofline-plot.py --gpu H100-SXM-80GB --model llama-70b
  python3 roofline-plot.py --all-gpus --model llama-70b --output results/roofline.png
"""

import argparse
import os
import sys

try:
    import matplotlib
    matplotlib.use("Agg")  # Non-interactive backend
    import matplotlib.pyplot as plt
    import matplotlib.ticker as ticker
    import numpy as np
except ImportError:
    print("Error: matplotlib and numpy are required.")
    print("Install: pip install matplotlib numpy")
    sys.exit(1)

# ─── GPU Specifications ──────────────────────────────────────────────────────

GPU_SPECS = {
    "A100-SXM-80GB": {
        "name": "A100 SXM 80GB",
        "peak_tflops": 312,
        "hbm_gbps": 2039,
        "color": "#76B900",  # NVIDIA green
    },
    "H100-SXM-80GB": {
        "name": "H100 SXM 80GB",
        "peak_tflops": 989,
        "hbm_gbps": 3350,
        "color": "#1A73E8",  # Blue
    },
    "H200-SXM-141GB": {
        "name": "H200 SXM 141GB",
        "peak_tflops": 989,
        "hbm_gbps": 4800,
        "color": "#E8710A",  # Orange
    },
    "B200-SXM-192GB": {
        "name": "B200 SXM 192GB",
        "peak_tflops": 2250,
        "hbm_gbps": 8000,
        "color": "#D93025",  # Red
    },
}

MODEL_PRESETS = {
    "llama-8b": {"name": "Llama 3.1 8B", "params_b": 8.03},
    "llama-70b": {"name": "Llama 3.1 70B", "params_b": 70.6},
    "llama-405b": {"name": "Llama 3.1 405B", "params_b": 405.0},
}


def ridge_point(peak_tflops, hbm_gbps):
    """Compute ridge point in FLOP/byte."""
    return (peak_tflops * 1e12) / (hbm_gbps * 1e9)


def plot_roofline_single(ax, gpu_id, gpu, batch_sizes, seq_lengths):
    """Plot roofline for a single GPU on the given axes."""
    peak = gpu["peak_tflops"]
    bw = gpu["hbm_gbps"]
    ridge = ridge_point(peak, bw)
    color = gpu["color"]

    # Arithmetic intensity range (log scale)
    ai_range = np.logspace(-1, 4, 500)

    # Memory ceiling: performance = AI * bandwidth (in TFLOPS)
    mem_ceiling = ai_range * bw / 1000  # GB/s * FLOP/byte = GFLOP/s -> TFLOPS

    # Compute ceiling: flat at peak TFLOPS
    compute_ceiling = np.full_like(ai_range, peak)

    # Roofline = min(memory_ceiling, compute_ceiling)
    roofline = np.minimum(mem_ceiling, compute_ceiling)

    ax.loglog(ai_range, roofline, color=color, linewidth=2.5, label=gpu["name"])

    # Mark ridge point
    ax.axvline(x=ridge, color=color, linestyle=":", alpha=0.4, linewidth=1)
    ax.annotate(
        f"Ridge={ridge:.0f}",
        xy=(ridge, peak * 0.7),
        fontsize=7,
        color=color,
        alpha=0.7,
        rotation=90,
        va="bottom",
        ha="right",
    )

    return ridge


def plot_operating_points(ax, batch_sizes, seq_lengths, gpus_to_plot):
    """Plot decode and prefill operating points."""
    markers_decode = ["o", "s", "D", "^", "v"]
    markers_prefill = ["o", "s", "D", "^", "v"]

    # Decode operating points (AI = 2*B)
    for i, b in enumerate(batch_sizes):
        ai = 2.0 * b
        marker = markers_decode[i % len(markers_decode)]
        ax.axvline(x=ai, color="gray", linestyle="--", alpha=0.15)
        # Place a marker at an appropriate y position
        ax.plot(
            ai, 0.5,  # Bottom of plot
            marker=marker,
            color="black",
            markersize=8,
            zorder=5,
            label=f"Decode B={b}" if i < len(batch_sizes) else None,
        )
        ax.annotate(
            f"Dec B={b}\nAI={ai:.0f}",
            xy=(ai, 0.3),
            fontsize=6,
            ha="center",
            color="black",
            alpha=0.8,
        )

    # Prefill operating points (AI = 2*S*B)
    for i, s in enumerate(seq_lengths):
        for j, b in enumerate(batch_sizes[:2]):  # Only plot first 2 batch sizes for clarity
            ai = 2.0 * s * b
            if ai > 1e4:  # Skip if off chart
                continue
            ax.axvline(x=ai, color="purple", linestyle="--", alpha=0.1)
            ax.annotate(
                f"Pre S={s},B={b}\nAI={ai:.0f}",
                xy=(ai, 0.15),
                fontsize=5,
                ha="center",
                color="purple",
                alpha=0.7,
            )


def main():
    parser = argparse.ArgumentParser(
        description="Generate roofline model plots for LLM inference",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument(
        "--gpu",
        choices=list(GPU_SPECS.keys()),
        nargs="+",
        help="GPU type(s) to plot",
    )
    parser.add_argument(
        "--all-gpus",
        action="store_true",
        help="Plot all GPU types",
    )
    parser.add_argument(
        "--model",
        choices=list(MODEL_PRESETS.keys()),
        default="llama-70b",
        help="Model preset for annotations (default: llama-70b)",
    )
    parser.add_argument(
        "--batch",
        type=int,
        nargs="+",
        default=[1, 8, 32, 64],
        help="Batch sizes to mark (default: 1 8 32 64)",
    )
    parser.add_argument(
        "--seq",
        type=int,
        nargs="+",
        default=[128, 512, 2048],
        help="Sequence lengths for prefill points (default: 128 512 2048)",
    )
    parser.add_argument(
        "--output",
        default=None,
        help="Output PNG path (default: results/roofline-<gpu>.png)",
    )
    parser.add_argument(
        "--dpi",
        type=int,
        default=150,
        help="Output DPI (default: 150)",
    )

    args = parser.parse_args()

    if args.all_gpus:
        gpu_ids = list(GPU_SPECS.keys())
    elif args.gpu:
        gpu_ids = args.gpu
    else:
        parser.error("--gpu or --all-gpus is required")
        return

    model = MODEL_PRESETS[args.model]

    # Create figure
    fig, ax = plt.subplots(1, 1, figsize=(14, 8))

    # Plot roofline for each GPU
    for gpu_id in gpu_ids:
        gpu = GPU_SPECS[gpu_id]
        plot_roofline_single(ax, gpu_id, gpu, args.batch, args.seq)

    # Plot operating points
    plot_operating_points(ax, args.batch, args.seq, gpu_ids)

    # Formatting
    ax.set_xlabel("Arithmetic Intensity (FLOPs/byte)", fontsize=12)
    ax.set_ylabel("Attainable Performance (TFLOPS)", fontsize=12)
    ax.set_title(
        f"Roofline Model - LLM Inference ({model['name']})\n"
        f"Showing Prefill & Decode Operating Points",
        fontsize=13,
    )
    ax.set_xlim(0.1, 1e4)
    ax.set_ylim(0.1, 5000)
    ax.grid(True, which="both", alpha=0.2)
    ax.legend(loc="upper left", fontsize=9)

    # Add annotation box explaining regions
    textstr = (
        "Left of ridge: MEMORY-BOUND\n"
        "Right of ridge: COMPUTE-BOUND\n"
        "Decode at B=1 is always memory-bound"
    )
    props = dict(boxstyle="round", facecolor="wheat", alpha=0.5)
    ax.text(
        0.98, 0.02, textstr,
        transform=ax.transAxes, fontsize=8,
        verticalalignment="bottom", horizontalalignment="right",
        bbox=props,
    )

    plt.tight_layout()

    # Determine output path
    if args.output:
        output_path = args.output
    else:
        script_dir = os.path.dirname(os.path.abspath(__file__))
        results_dir = os.path.join(script_dir, "..", "results")
        os.makedirs(results_dir, exist_ok=True)
        gpu_suffix = "-".join(gpu_ids).lower()
        output_path = os.path.join(results_dir, f"roofline-{gpu_suffix}.png")

    fig.savefig(output_path, dpi=args.dpi, bbox_inches="tight")
    print(f"Roofline plot saved to: {output_path}")
    plt.close(fig)


if __name__ == "__main__":
    main()
