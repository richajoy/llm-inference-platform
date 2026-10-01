#!/usr/bin/env bash
set -euo pipefail

# bench-genai-perf.sh - GenAI-Perf benchmark runner
#
# Uses Triton's GenAI-Perf analyzer to benchmark LLM inference endpoints.
# Measures TTFT, TPOT, throughput with configurable concurrency.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESULTS_DIR="${SCRIPT_DIR}/../results"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"

# Default configuration
MODEL="${MODEL:-meta-llama/Llama-3.1-70B-Instruct}"
ENDPOINT="${ENDPOINT:-http://llama-70b-tp4.inference.svc.cluster.local:8000}"
CONCURRENCY="${CONCURRENCY:-10}"
INPUT_LENGTH="${INPUT_LENGTH:-128}"
OUTPUT_LENGTH="${OUTPUT_LENGTH:-256}"
NUM_REQUESTS="${NUM_REQUESTS:-500}"
PROFILE_NAME="${PROFILE_NAME:-genai-perf}"

print_usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Run GenAI-Perf benchmark against an LLM inference endpoint.

Options:
  -m, --model MODEL          Model name (default: ${MODEL})
  -e, --endpoint URL         Endpoint URL (default: ${ENDPOINT})
  -c, --concurrency NUM      Concurrent requests (default: ${CONCURRENCY})
  -i, --input-length NUM     Input token length (default: ${INPUT_LENGTH})
  -o, --output-length NUM    Output token length (default: ${OUTPUT_LENGTH})
  -n, --num-requests NUM     Total requests (default: ${NUM_REQUESTS})
  -p, --profile-name NAME    Profile name for results (default: ${PROFILE_NAME})
  --output-dir DIR           Override results directory
  -h, --help                 Show this help message

Environment Variables:
  MODEL, ENDPOINT, CONCURRENCY, INPUT_LENGTH, OUTPUT_LENGTH, NUM_REQUESTS
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -m|--model)         MODEL="$2"; shift 2 ;;
        -e|--endpoint)      ENDPOINT="$2"; shift 2 ;;
        -c|--concurrency)   CONCURRENCY="$2"; shift 2 ;;
        -i|--input-length)  INPUT_LENGTH="$2"; shift 2 ;;
        -o|--output-length) OUTPUT_LENGTH="$2"; shift 2 ;;
        -n|--num-requests)  NUM_REQUESTS="$2"; shift 2 ;;
        -p|--profile-name)  PROFILE_NAME="$2"; shift 2 ;;
        --output-dir)       RESULTS_DIR="$2"; shift 2 ;;
        -h|--help)          print_usage; exit 0 ;;
        *)                  echo "Error: Unknown option: $1"; print_usage; exit 1 ;;
    esac
done

# Check prerequisites
if ! command -v genai-perf &>/dev/null; then
    echo "Error: genai-perf is not installed."
    echo ""
    echo "Install via:"
    echo "  pip install genai-perf"
    echo ""
    echo "Or use the Triton SDK container:"
    echo "  docker run -it --rm nvcr.io/nvidia/tritonserver:24.12-py3-sdk"
    exit 1
fi

# Create results directory
RESULT_DIR="${RESULTS_DIR}/genai-perf-${PROFILE_NAME}-${TIMESTAMP}"
mkdir -p "${RESULT_DIR}"

echo "============================================="
echo "  GenAI-Perf Benchmark"
echo "============================================="
echo "  Model:         ${MODEL}"
echo "  Endpoint:      ${ENDPOINT}"
echo "  Concurrency:   ${CONCURRENCY}"
echo "  Input Length:   ${INPUT_LENGTH} tokens"
echo "  Output Length:  ${OUTPUT_LENGTH} tokens"
echo "  Num Requests:   ${NUM_REQUESTS}"
echo "  Output:        ${RESULT_DIR}/"
echo "============================================="
echo ""

# Extract host and port from endpoint URL
ENDPOINT_HOST="${ENDPOINT#http://}"
ENDPOINT_HOST="${ENDPOINT_HOST#https://}"

# Run GenAI-Perf
genai-perf profile \
    --model "${MODEL}" \
    --endpoint-type chat \
    --service-kind openai \
    --url "${ENDPOINT_HOST}" \
    --streaming \
    --concurrency "${CONCURRENCY}" \
    --synthetic-input-tokens-mean "${INPUT_LENGTH}" \
    --synthetic-input-tokens-stddev "$((INPUT_LENGTH / 4))" \
    --output-tokens-mean "${OUTPUT_LENGTH}" \
    --output-tokens-stddev "$((OUTPUT_LENGTH / 4))" \
    --num-requests "${NUM_REQUESTS}" \
    --artifact-dir "${RESULT_DIR}" \
    --generate-plots \
    2>&1 | tee "${RESULT_DIR}/genai-perf.log"

BENCH_EXIT=${PIPESTATUS[0]}

echo ""
if [[ ${BENCH_EXIT} -eq 0 ]]; then
    echo "Benchmark complete. Results saved to: ${RESULT_DIR}/"
    echo ""
    echo "Generated artifacts:"
    ls -la "${RESULT_DIR}/" 2>/dev/null || true
else
    echo "Error: GenAI-Perf exited with code ${BENCH_EXIT}."
    echo "Check logs at: ${RESULT_DIR}/genai-perf.log"
    exit ${BENCH_EXIT}
fi
