#!/usr/bin/env bash
set -euo pipefail

# bench-vllm.sh - Automated vLLM benchmark runner
#
# Runs vLLM's built-in benchmark client against a deployed model endpoint
# using the ShareGPT dataset. Supports multiple deployment profiles.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESULTS_DIR="${SCRIPT_DIR}/../results"
DATA_DIR="${SCRIPT_DIR}/../data"
DATASET_FILE="${DATA_DIR}/ShareGPT_V3_unfiltered_cleaned_split.json"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"

# Default configuration
NUM_PROMPTS="${NUM_PROMPTS:-1000}"
REQUEST_RATE="${REQUEST_RATE:-10}"
MAX_TOKENS="${MAX_TOKENS:-512}"

# Profile-to-endpoint mapping
declare -A PROFILE_ENDPOINTS=(
    ["8b-mig"]="http://llama-8b-mig.inference.svc.cluster.local:8000"
    ["70b-tp4"]="http://llama-70b-tp4.inference.svc.cluster.local:8000"
    ["70b-fp8"]="http://llama-70b-fp8.inference.svc.cluster.local:8000"
    ["70b-eagle3"]="http://llama-70b-eagle3.inference.svc.cluster.local:8000"
    ["70b-disagg"]="http://llama-70b-disagg.inference.svc.cluster.local:8000"
)

declare -A PROFILE_MODELS=(
    ["8b-mig"]="meta-llama/Llama-3.1-8B-Instruct"
    ["70b-tp4"]="meta-llama/Llama-3.1-70B-Instruct"
    ["70b-fp8"]="meta-llama/Llama-3.1-70B-Instruct"
    ["70b-eagle3"]="meta-llama/Llama-3.1-70B-Instruct"
    ["70b-disagg"]="meta-llama/Llama-3.1-70B-Instruct"
)

print_usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS] PROFILE

Run vLLM benchmark for a given deployment profile.

Profiles:
  8b-mig       Llama 8B on MIG slices
  70b-tp4      Llama 70B with TP=4
  70b-fp8      Llama 70B FP8 with TP=2
  70b-eagle3   Llama 70B with EAGLE3 speculative decoding
  70b-disagg   Llama 70B disaggregated prefill/decode

Options:
  -n, --num-prompts NUM    Number of prompts to send (default: ${NUM_PROMPTS})
  -r, --request-rate RATE  Requests per second (default: ${REQUEST_RATE})
  -m, --max-tokens NUM     Maximum output tokens (default: ${MAX_TOKENS})
  -e, --endpoint URL       Override endpoint URL
  -o, --output-dir DIR     Override results directory
  -h, --help               Show this help message

Environment Variables:
  NUM_PROMPTS    Same as --num-prompts
  REQUEST_RATE   Same as --request-rate
  MAX_TOKENS     Same as --max-tokens
EOF
}

ENDPOINT_OVERRIDE=""
PROFILE=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        -n|--num-prompts)
            NUM_PROMPTS="$2"; shift 2 ;;
        -r|--request-rate)
            REQUEST_RATE="$2"; shift 2 ;;
        -m|--max-tokens)
            MAX_TOKENS="$2"; shift 2 ;;
        -e|--endpoint)
            ENDPOINT_OVERRIDE="$2"; shift 2 ;;
        -o|--output-dir)
            RESULTS_DIR="$2"; shift 2 ;;
        -h|--help)
            print_usage; exit 0 ;;
        -*)
            echo "Error: Unknown option: $1"; print_usage; exit 1 ;;
        *)
            if [[ -z "${PROFILE}" ]]; then
                PROFILE="$1"
            else
                echo "Error: Multiple profiles specified"; print_usage; exit 1
            fi
            shift
            ;;
    esac
done

if [[ -z "${PROFILE}" ]]; then
    echo "Error: Profile name is required."
    print_usage
    exit 1
fi

# Validate profile
if [[ -z "${PROFILE_ENDPOINTS[${PROFILE}]+x}" ]]; then
    echo "Error: Unknown profile '${PROFILE}'."
    echo "Valid profiles: ${!PROFILE_ENDPOINTS[*]}"
    exit 1
fi

# Resolve endpoint
ENDPOINT="${ENDPOINT_OVERRIDE:-${PROFILE_ENDPOINTS[${PROFILE}]}}"
MODEL="${PROFILE_MODELS[${PROFILE}]}"

# Check prerequisites
if [[ ! -f "${DATASET_FILE}" ]]; then
    echo "Error: ShareGPT dataset not found at: ${DATASET_FILE}"
    echo "Run: benchmarks/scripts/download-sharegpt.sh"
    exit 1
fi

if ! command -v python3 &>/dev/null; then
    echo "Error: python3 is required but not found in PATH."
    exit 1
fi

# Create results directory
RESULT_PREFIX="${RESULTS_DIR}/vllm-${PROFILE}-${TIMESTAMP}"
mkdir -p "${RESULTS_DIR}"

echo "============================================="
echo "  vLLM Benchmark: ${PROFILE}"
echo "============================================="
echo "  Endpoint:      ${ENDPOINT}"
echo "  Model:         ${MODEL}"
echo "  Dataset:       ${DATASET_FILE}"
echo "  Num Prompts:   ${NUM_PROMPTS}"
echo "  Request Rate:  ${REQUEST_RATE} req/s"
echo "  Max Tokens:    ${MAX_TOKENS}"
echo "  Output:        ${RESULT_PREFIX}.json"
echo "============================================="
echo ""

# Run the vLLM benchmark using the built-in benchmark_serving tool
python3 -m vllm.entrypoints.openai.api_server 2>/dev/null || true  # ensure vllm is importable

python3 -m vllm.entrypoints.openai.run_bench \
    --backend vllm \
    --base-url "${ENDPOINT}" \
    --model "${MODEL}" \
    --dataset-name sharegpt \
    --dataset-path "${DATASET_FILE}" \
    --num-prompts "${NUM_PROMPTS}" \
    --request-rate "${REQUEST_RATE}" \
    --max-tokens "${MAX_TOKENS}" \
    --save-result \
    --result-dir "${RESULTS_DIR}" \
    --result-filename "vllm-${PROFILE}-${TIMESTAMP}.json" \
    2>&1 | tee "${RESULT_PREFIX}.log"

BENCH_EXIT=$?

if [[ ${BENCH_EXIT} -ne 0 ]]; then
    echo ""
    echo "Warning: vllm.entrypoints.openai.run_bench failed (exit ${BENCH_EXIT})."
    echo "Falling back to vllm bench serve..."
    echo ""

    vllm bench serve \
        --backend vllm \
        --base-url "${ENDPOINT}" \
        --model "${MODEL}" \
        --dataset-name sharegpt \
        --dataset-path "${DATASET_FILE}" \
        --num-prompts "${NUM_PROMPTS}" \
        --request-rate "${REQUEST_RATE}" \
        --save-result \
        --result-dir "${RESULTS_DIR}" \
        --result-filename "vllm-${PROFILE}-${TIMESTAMP}.json" \
        2>&1 | tee "${RESULT_PREFIX}.log"
fi

# Print summary if result file exists
RESULT_FILE="${RESULTS_DIR}/vllm-${PROFILE}-${TIMESTAMP}.json"
if [[ -f "${RESULT_FILE}" ]]; then
    echo ""
    echo "============================================="
    echo "  Benchmark Results Summary: ${PROFILE}"
    echo "============================================="
    python3 - "${RESULT_FILE}" <<'PYEOF'
import json
import sys

with open(sys.argv[1], "r") as f:
    results = json.load(f)

def get_metric(data, key, default="N/A"):
    val = data.get(key, default)
    if isinstance(val, float):
        return f"{val:.2f}"
    return str(val)

# Handle both flat and nested result formats
if "metrics" in results:
    m = results["metrics"]
else:
    m = results

print(f"  TTFT P50:          {get_metric(m, 'ttft_p50_ms', get_metric(m, 'median_ttft_ms'))} ms")
print(f"  TTFT P99:          {get_metric(m, 'ttft_p99_ms', get_metric(m, 'p99_ttft_ms'))} ms")
print(f"  TPOT P50:          {get_metric(m, 'tpot_p50_ms', get_metric(m, 'median_tpot_ms'))} ms")
print(f"  TPOT P99:          {get_metric(m, 'tpot_p99_ms', get_metric(m, 'p99_tpot_ms'))} ms")
print(f"  Throughput:        {get_metric(m, 'output_throughput', get_metric(m, 'request_throughput'))} tok/s")
print(f"  Total Duration:    {get_metric(m, 'total_time', get_metric(m, 'duration'))} s")
print(f"  Completed:         {get_metric(m, 'completed')}")
print(f"  Errors:            {get_metric(m, 'errors', '0')}")
PYEOF
    echo "============================================="
    echo ""
    echo "Full results saved to: ${RESULT_FILE}"
else
    echo ""
    echo "Warning: Result file not found. Check logs at: ${RESULT_PREFIX}.log"
fi
