#!/usr/bin/env bash
set -euo pipefail

# run-all-benchmarks.sh - Sequential benchmark suite across all profiles
#
# Runs bench-vllm.sh for each deployment profile, collects results,
# generates a comparison CSV, and prints a summary table.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESULTS_DIR="${SCRIPT_DIR}/../results"
DATA_DIR="${SCRIPT_DIR}/../data"
DATASET_FILE="${DATA_DIR}/ShareGPT_V3_unfiltered_cleaned_split.json"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
COMPARISON_CSV="${RESULTS_DIR}/comparison-${TIMESTAMP}.csv"

# All benchmark profiles
PROFILES=("8b-mig" "70b-tp4" "70b-fp8" "70b-eagle3" "70b-disagg")

# Configuration (can override via env)
NUM_PROMPTS="${NUM_PROMPTS:-1000}"
REQUEST_RATE="${REQUEST_RATE:-10}"

print_usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Run the full benchmark suite across all deployment profiles.

Options:
  -p, --profiles LIST   Comma-separated list of profiles to test
                        (default: 8b-mig,70b-tp4,70b-fp8,70b-eagle3,70b-disagg)
  -n, --num-prompts N   Number of prompts per profile (default: ${NUM_PROMPTS})
  -r, --request-rate R  Requests per second (default: ${REQUEST_RATE})
  --skip-prereq         Skip prerequisite checks
  -h, --help            Show this help message
EOF
}

SKIP_PREREQ=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        -p|--profiles)
            IFS=',' read -ra PROFILES <<< "$2"; shift 2 ;;
        -n|--num-prompts)
            NUM_PROMPTS="$2"; shift 2 ;;
        -r|--request-rate)
            REQUEST_RATE="$2"; shift 2 ;;
        --skip-prereq)
            SKIP_PREREQ=true; shift ;;
        -h|--help)
            print_usage; exit 0 ;;
        *)
            echo "Error: Unknown option: $1"; print_usage; exit 1 ;;
    esac
done

echo "================================================================"
echo "  LLM Inference Benchmark Suite"
echo "  Timestamp: ${TIMESTAMP}"
echo "================================================================"
echo "  Profiles:      ${PROFILES[*]}"
echo "  Num Prompts:   ${NUM_PROMPTS}"
echo "  Request Rate:  ${REQUEST_RATE} req/s"
echo "================================================================"
echo ""

# ── Step 1: Check prerequisites ──────────────────────────────────────

if [[ "${SKIP_PREREQ}" == "false" ]]; then
    echo "[1/5] Checking prerequisites..."

    # Check dataset
    if [[ ! -f "${DATASET_FILE}" ]]; then
        echo "  ShareGPT dataset not found. Downloading..."
        bash "${SCRIPT_DIR}/download-sharegpt.sh"
    else
        echo "  ShareGPT dataset: OK"
    fi

    # Check python3
    if ! command -v python3 &>/dev/null; then
        echo "Error: python3 is required."
        exit 1
    fi
    echo "  python3: OK"

    # Check endpoints (best-effort, don't fail if cluster not reachable)
    for profile in "${PROFILES[@]}"; do
        echo -n "  Endpoint for ${profile}: "
        # We just report, don't block - endpoints are validated by bench-vllm.sh
        echo "will be tested at benchmark time"
    done
    echo ""
else
    echo "[1/5] Skipping prerequisite checks."
    echo ""
fi

# ── Step 2: Run benchmarks for each profile ──────────────────────────

echo "[2/5] Running benchmarks..."
echo ""

declare -A RESULT_FILES
FAILED_PROFILES=()

for profile in "${PROFILES[@]}"; do
    echo "────────────────────────────────────────"
    echo "  Benchmarking: ${profile}"
    echo "────────────────────────────────────────"

    RESULT_FILE="${RESULTS_DIR}/vllm-${profile}-${TIMESTAMP}.json"

    if NUM_PROMPTS="${NUM_PROMPTS}" REQUEST_RATE="${REQUEST_RATE}" \
        bash "${SCRIPT_DIR}/bench-vllm.sh" \
            -n "${NUM_PROMPTS}" \
            -r "${REQUEST_RATE}" \
            "${profile}" 2>&1; then
        RESULT_FILES["${profile}"]="${RESULT_FILE}"
        echo "  Result: PASS"
    else
        echo "  Result: FAIL (exit code $?)"
        FAILED_PROFILES+=("${profile}")
    fi
    echo ""
done

# ── Step 3: Collect results ──────────────────────────────────────────

echo "[3/5] Collecting results..."

COLLECTED_FILES=()
for profile in "${PROFILES[@]}"; do
    # Find the most recent result file for this profile
    LATEST=$(find "${RESULTS_DIR}" -name "vllm-${profile}-*.json" -type f 2>/dev/null | sort -r | head -1)
    if [[ -n "${LATEST}" ]]; then
        COLLECTED_FILES+=("${LATEST}")
        echo "  ${profile}: ${LATEST}"
    else
        echo "  ${profile}: no results found"
    fi
done
echo ""

# ── Step 4: Generate comparison CSV ──────────────────────────────────

echo "[4/5] Generating comparison CSV..."

if [[ ${#COLLECTED_FILES[@]} -gt 0 ]]; then
    python3 - "${COMPARISON_CSV}" "${COLLECTED_FILES[@]}" <<'PYEOF'
import json
import csv
import sys
import os

output_csv = sys.argv[1]
result_files = sys.argv[2:]

rows = []
for filepath in result_files:
    basename = os.path.basename(filepath)
    # Extract profile from filename: vllm-PROFILE-TIMESTAMP.json
    parts = basename.replace(".json", "").split("-")
    profile = "-".join(parts[1:-2]) if len(parts) > 3 else parts[1] if len(parts) > 1 else basename

    try:
        with open(filepath, "r") as f:
            data = json.load(f)
    except (json.JSONDecodeError, FileNotFoundError):
        continue

    m = data.get("metrics", data)

    def g(key, *alt_keys):
        val = m.get(key)
        if val is None:
            for k in alt_keys:
                val = m.get(k)
                if val is not None:
                    break
        if val is None:
            return ""
        if isinstance(val, float):
            return f"{val:.2f}"
        return str(val)

    rows.append({
        "profile": profile,
        "ttft_p50_ms": g("ttft_p50_ms", "median_ttft_ms"),
        "ttft_p99_ms": g("ttft_p99_ms", "p99_ttft_ms"),
        "tpot_p50_ms": g("tpot_p50_ms", "median_tpot_ms"),
        "tpot_p99_ms": g("tpot_p99_ms", "p99_tpot_ms"),
        "throughput_tps": g("output_throughput", "request_throughput"),
        "completed": g("completed"),
        "errors": g("errors"),
        "duration_s": g("total_time", "duration"),
    })

if rows:
    fieldnames = ["profile", "ttft_p50_ms", "ttft_p99_ms", "tpot_p50_ms",
                  "tpot_p99_ms", "throughput_tps", "completed", "errors", "duration_s"]
    with open(output_csv, "w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=fieldnames)
        writer.writeheader()
        writer.writerows(rows)
    print(f"  CSV written to: {output_csv}")
    print(f"  Profiles included: {len(rows)}")
else:
    print("  No valid results to write.")
PYEOF
else
    echo "  No results collected. Skipping CSV generation."
fi
echo ""

# ── Step 5: Print summary table ──────────────────────────────────────

echo "[5/5] Summary"
echo ""

if [[ -f "${COMPARISON_CSV}" ]]; then
    python3 - "${COMPARISON_CSV}" <<'PYEOF'
import csv
import sys

with open(sys.argv[1], "r") as f:
    reader = csv.DictReader(f)
    rows = list(reader)

if not rows:
    print("  No results to display.")
    sys.exit(0)

# Print formatted table
header = f"{'Profile':<15} {'TTFT P50':>10} {'TTFT P99':>10} {'TPOT P50':>10} {'TPOT P99':>10} {'Tput(t/s)':>10} {'Done':>6} {'Err':>5}"
sep = "=" * len(header)

print(sep)
print(header)
print(sep)

for row in rows:
    print(f"{row['profile']:<15} "
          f"{row.get('ttft_p50_ms', 'N/A'):>10} "
          f"{row.get('ttft_p99_ms', 'N/A'):>10} "
          f"{row.get('tpot_p50_ms', 'N/A'):>10} "
          f"{row.get('tpot_p99_ms', 'N/A'):>10} "
          f"{row.get('throughput_tps', 'N/A'):>10} "
          f"{row.get('completed', 'N/A'):>6} "
          f"{row.get('errors', '0'):>5}")

print(sep)
PYEOF
fi

echo ""
if [[ ${#FAILED_PROFILES[@]} -gt 0 ]]; then
    echo "FAILED profiles: ${FAILED_PROFILES[*]}"
    echo ""
fi

echo "Results directory: ${RESULTS_DIR}/"
echo "Comparison CSV:   ${COMPARISON_CSV}"
echo ""
echo "Benchmark suite complete."
