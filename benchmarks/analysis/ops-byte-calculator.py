#!/usr/bin/env python3
"""
ops-byte-calculator.py - Arithmetic Intensity & Roofline Analysis for LLM Inference

Calculates whether LLM inference operations are memory-bound or compute-bound
by comparing arithmetic intensity against the hardware ridge point.

This implements the ops:byte (operational intensity) model:
  - Prefill phase:  AI = S * B  (compute-intensive for large S)
  - Decode phase:   AI = B      (almost always memory-bound)

Where:
  AI = Arithmetic Intensity (FLOPs per byte of memory accessed)
  S  = Sequence length (input tokens)
  B  = Batch size
  P  = Model parameters

The ridge point is where compute and memory bandwidth limits intersect:
  Ridge = Peak FLOPS / Peak Memory Bandwidth

If AI > Ridge: compute-bound (GPU ALUs are the bottleneck)
If AI < Ridge: memory-bound (HBM bandwidth is the bottleneck)
"""

import argparse
import sys

# ─── GPU Specifications ──────────────────────────────────────────────────────

GPU_SPECS = {
    "A100-SXM-80GB": {
        "name": "NVIDIA A100 SXM 80GB",
        "peak_flops_tflops": 312,        # FP16 Tensor Core
        "hbm_bandwidth_gbps": 2039,      # HBM2e
        "vram_gb": 80,
    },
    "H100-SXM-80GB": {
        "name": "NVIDIA H100 SXM 80GB",
        "peak_flops_tflops": 989,        # FP16 Tensor Core
        "hbm_bandwidth_gbps": 3350,      # HBM3
        "vram_gb": 80,
    },
    "H200-SXM-141GB": {
        "name": "NVIDIA H200 SXM 141GB",
        "peak_flops_tflops": 989,        # FP16 Tensor Core (same as H100)
        "hbm_bandwidth_gbps": 4800,      # HBM3e
        "vram_gb": 141,
    },
    "B200-SXM-192GB": {
        "name": "NVIDIA B200 SXM 192GB",
        "peak_flops_tflops": 2250,       # FP16 Tensor Core
        "hbm_bandwidth_gbps": 8000,      # HBM3e
        "vram_gb": 192,
    },
}

# ─── Model Presets ────────────────────────────────────────────────────────────

MODEL_PRESETS = {
    "llama-8b": {
        "name": "Llama 3.1 8B",
        "params_billions": 8.03,
        "hidden_dim": 4096,
        "num_layers": 32,
        "num_heads": 32,
        "bytes_per_param": 2,  # FP16
    },
    "llama-70b": {
        "name": "Llama 3.1 70B",
        "params_billions": 70.6,
        "hidden_dim": 8192,
        "num_layers": 80,
        "num_heads": 64,
        "bytes_per_param": 2,  # FP16
    },
    "llama-405b": {
        "name": "Llama 3.1 405B",
        "params_billions": 405.0,
        "hidden_dim": 16384,
        "num_layers": 126,
        "num_heads": 128,
        "bytes_per_param": 2,  # FP16
    },
}


def compute_ridge_point(peak_flops_tflops, hbm_bandwidth_gbps):
    """Compute the ridge point (FLOP/byte) where compute meets memory ceiling.

    Ridge = Peak FLOPS / Peak Bandwidth
    Both converted to base units first: TFLOPS -> FLOPS, GB/s -> B/s
    Result in FLOP/byte.
    """
    peak_flops = peak_flops_tflops * 1e12
    bandwidth = hbm_bandwidth_gbps * 1e9
    return peak_flops / bandwidth


def compute_prefill_ai(batch_size, seq_length):
    """Arithmetic intensity for prefill phase.

    During prefill, we process all S tokens in parallel.
    Each token requires reading model weights once, but performs S * B
    multiply-accumulate operations per weight element.

    AI_prefill = S * B (FLOPs per byte)

    The multiply-accumulate factor of 2 appears in the numerator (2*P*S*B FLOPs)
    but cancels against the 2 bytes per FP16 parameter in the denominator:
        AI = (2 * P * S * B) / (2 * P) = S * B
    """
    return float(seq_length * batch_size)


def compute_decode_ai(batch_size):
    """Arithmetic intensity for decode phase.

    During decode, we generate one token at a time per sequence.
    Model weights are read once per step, performing B operations per element.

    AI_decode = B (FLOPs per byte)

    Same cancellation as prefill: (2 * P * B) / (2 * P) = B.
    """
    return float(batch_size)


def compute_theoretical_max_tps(gpu, model, batch_size, seq_length, tp_degree=1):
    """Compute theoretical maximum tokens per second.

    Memory-bound: limited by how fast we can stream weights through
      tokens/s = bandwidth / (model_bytes / tp) * batch_size

    Compute-bound: limited by peak FLOPS
      tokens/s = peak_flops / (2 * params / tp) * batch_size
    """
    model_bytes = model["params_billions"] * 1e9 * model["bytes_per_param"]
    model_bytes_per_gpu = model_bytes / tp_degree

    bandwidth = gpu["hbm_bandwidth_gbps"] * 1e9
    peak_flops = gpu["peak_flops_tflops"] * 1e12

    # Memory-bound decode: each token requires one full weight read
    mem_bound_tps = (bandwidth / model_bytes_per_gpu) * batch_size

    # Compute-bound decode: each token requires 2P FLOPs
    flops_per_token = 2 * model["params_billions"] * 1e9 / tp_degree
    compute_bound_tps = (peak_flops / flops_per_token) * batch_size

    # Actual throughput is min of the two ceilings
    return min(mem_bound_tps, compute_bound_tps), mem_bound_tps, compute_bound_tps


def classify_regime(ai, ridge):
    """Classify operation as memory-bound or compute-bound."""
    if ai < ridge:
        return "MEMORY-BOUND"
    elif ai > ridge * 1.1:  # 10% margin
        return "COMPUTE-BOUND"
    else:
        return "NEAR RIDGE (transitional)"


def format_table(headers, rows, col_widths=None):
    """Format a list of rows as an aligned ASCII table."""
    if col_widths is None:
        col_widths = []
        for i, h in enumerate(headers):
            max_w = len(str(h))
            for row in rows:
                max_w = max(max_w, len(str(row[i])))
            col_widths.append(max_w + 2)

    header_line = "".join(str(h).ljust(w) for h, w in zip(headers, col_widths))
    sep = "-" * sum(col_widths)

    lines = [sep, header_line, sep]
    for row in rows:
        lines.append("".join(str(v).ljust(w) for v, w in zip(row, col_widths)))
    lines.append(sep)
    return "\n".join(lines)


def main():
    parser = argparse.ArgumentParser(
        description="Calculate arithmetic intensity and roofline classification for LLM inference",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  %(prog)s --model llama-70b --gpu H100-SXM-80GB --batch 1 --seq 2048
  %(prog)s --model llama-8b --gpu A100-SXM-80GB --batch 1 8 16 32 --seq 512
  %(prog)s --all-gpus --model llama-70b --batch 1 --seq 1024
  %(prog)s --params 70 --gpu H100-SXM-80GB --batch 1 --seq 512
""",
    )

    model_group = parser.add_mutually_exclusive_group(required=True)
    model_group.add_argument(
        "--model",
        choices=list(MODEL_PRESETS.keys()),
        help="Model preset name",
    )
    model_group.add_argument(
        "--params",
        type=float,
        help="Custom model size in billions of parameters",
    )

    parser.add_argument(
        "--gpu",
        choices=list(GPU_SPECS.keys()),
        help="GPU type (required unless --all-gpus)",
    )
    parser.add_argument(
        "--all-gpus",
        action="store_true",
        help="Compare across all GPU types",
    )
    parser.add_argument(
        "--batch",
        type=int,
        nargs="+",
        default=[1],
        help="Batch size(s) to evaluate (default: 1)",
    )
    parser.add_argument(
        "--seq",
        type=int,
        nargs="+",
        default=[512],
        help="Sequence length(s) to evaluate (default: 512)",
    )
    parser.add_argument(
        "--tp",
        type=int,
        default=1,
        help="Tensor parallelism degree (default: 1)",
    )
    parser.add_argument(
        "--bytes-per-param",
        type=int,
        default=2,
        choices=[1, 2, 4],
        help="Bytes per parameter: 1=FP8, 2=FP16, 4=FP32 (default: 2)",
    )

    args = parser.parse_args()

    # Resolve model
    if args.model:
        model = MODEL_PRESETS[args.model].copy()
    else:
        model = {
            "name": f"Custom {args.params}B",
            "params_billions": args.params,
            "hidden_dim": 0,
            "num_layers": 0,
            "num_heads": 0,
            "bytes_per_param": args.bytes_per_param,
        }
    model["bytes_per_param"] = args.bytes_per_param

    # Resolve GPUs
    if args.all_gpus:
        gpus = list(GPU_SPECS.items())
    elif args.gpu:
        gpus = [(args.gpu, GPU_SPECS[args.gpu])]
    else:
        parser.error("--gpu or --all-gpus is required")
        return

    # Print header
    model_size_gb = model["params_billions"] * 1e9 * model["bytes_per_param"] / 1e9
    print(f"\n{'='*80}")
    print(f"  Ops:Byte Arithmetic Intensity Analysis")
    print(f"{'='*80}")
    print(f"  Model:           {model['name']}")
    print(f"  Parameters:      {model['params_billions']:.1f}B")
    print(f"  Precision:       {'FP8' if model['bytes_per_param']==1 else 'FP16' if model['bytes_per_param']==2 else 'FP32'}")
    print(f"  Model Size:      {model_size_gb:.1f} GB")
    print(f"  TP Degree:       {args.tp}")
    print(f"  Batch Sizes:     {args.batch}")
    print(f"  Sequence Lengths: {args.seq}")
    print(f"{'='*80}\n")

    # GPU ridge points
    print("GPU Ridge Points (FP16 Tensor Core):")
    headers = ["GPU", "Peak TFLOPS", "HBM BW (GB/s)", "Ridge (FLOP/byte)"]
    rows = []
    for gpu_id, gpu in gpus:
        ridge = compute_ridge_point(gpu["peak_flops_tflops"], gpu["hbm_bandwidth_gbps"])
        rows.append([gpu["name"], f"{gpu['peak_flops_tflops']}", f"{gpu['hbm_bandwidth_gbps']}", f"{ridge:.0f}"])
    print(format_table(headers, rows))

    # Prefill analysis
    print(f"\n{'─'*80}")
    print("PREFILL Phase Analysis (AI = seq_len * batch_size):")
    print(f"{'─'*80}")

    headers = ["GPU", "Batch", "SeqLen", "AI (FLOP/byte)", "Ridge", "Regime"]
    rows = []
    for gpu_id, gpu in gpus:
        ridge = compute_ridge_point(gpu["peak_flops_tflops"], gpu["hbm_bandwidth_gbps"])
        for b in args.batch:
            for s in args.seq:
                ai = compute_prefill_ai(b, s)
                regime = classify_regime(ai, ridge)
                rows.append([
                    gpu_id, str(b), str(s),
                    f"{ai:.0f}", f"{ridge:.0f}", regime,
                ])
    print(format_table(headers, rows))

    # Decode analysis
    print(f"\n{'─'*80}")
    print("DECODE Phase Analysis (AI = batch_size):")
    print(f"{'─'*80}")

    headers = ["GPU", "Batch", "AI (FLOP/byte)", "Ridge", "Regime", "Theo. Max tok/s"]
    rows = []
    for gpu_id, gpu in gpus:
        ridge = compute_ridge_point(gpu["peak_flops_tflops"], gpu["hbm_bandwidth_gbps"])
        for b in args.batch:
            ai = compute_decode_ai(b)
            regime = classify_regime(ai, ridge)
            max_tps, mem_tps, comp_tps = compute_theoretical_max_tps(
                gpu, model, b, args.seq[0], args.tp
            )
            rows.append([
                gpu_id, str(b),
                f"{ai:.0f}", f"{ridge:.0f}", regime,
                f"{max_tps:.0f}",
            ])
    print(format_table(headers, rows))

    # Decode throughput comparison
    print(f"\n{'─'*80}")
    print("Theoretical Max Decode Throughput (tokens/sec):")
    print(f"{'─'*80}")

    headers = ["GPU", "Batch"] + [f"B={b}" for b in args.batch]
    rows = []
    for gpu_id, gpu in gpus:
        row = [gpu_id, ""]
        for b in args.batch:
            max_tps, _, _ = compute_theoretical_max_tps(gpu, model, b, args.seq[0], args.tp)
            row.append(f"{max_tps:.0f}")
        rows.append(row)
    # Reformat: one row per GPU showing throughput at each batch size
    headers2 = ["GPU"] + [f"Batch={b}" for b in args.batch]
    rows2 = []
    for gpu_id, gpu in gpus:
        row = [gpu_id]
        for b in args.batch:
            max_tps, _, _ = compute_theoretical_max_tps(gpu, model, b, args.seq[0], args.tp)
            row.append(f"{max_tps:,.0f}")
        rows2.append(row)
    print(format_table(headers2, rows2))

    # Key insight
    print(f"\n{'='*80}")
    print("  KEY INSIGHT")
    print(f"{'='*80}")
    print(f"  Decode is almost ALWAYS memory-bound at batch=1.")
    print(f"  To become compute-bound at decode, you need batch >= ridge/2.")
    for gpu_id, gpu in gpus:
        ridge = compute_ridge_point(gpu["peak_flops_tflops"], gpu["hbm_bandwidth_gbps"])
        min_batch = int(ridge / 2) + 1
        print(f"    {gpu_id}: batch >= {min_batch}")
    print(f"\n  Prefill becomes compute-bound at seq_len >= ridge/2 (for batch=1).")
    print(f"{'='*80}\n")


if __name__ == "__main__":
    main()
