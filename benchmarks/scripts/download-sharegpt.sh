#!/usr/bin/env bash
set -euo pipefail

# download-sharegpt.sh - Download ShareGPT V3 dataset for LLM benchmarking
#
# Downloads the ShareGPT_Vicuna_unfiltered dataset from HuggingFace,
# saves it to benchmarks/data/, verifies integrity, and prints stats.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DATA_DIR="${SCRIPT_DIR}/../data"
DATASET_URL="https://huggingface.co/datasets/anon8231489123/ShareGPT_Vicuna_unfiltered/resolve/main/ShareGPT_V3_unfiltered_cleaned_split.json"
DATASET_FILE="${DATA_DIR}/ShareGPT_V3_unfiltered_cleaned_split.json"

print_usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Download ShareGPT V3 dataset for LLM benchmarking.

Options:
  -d, --data-dir DIR   Override data directory (default: benchmarks/data/)
  -f, --force          Force re-download even if file exists
  -h, --help           Show this help message
EOF
}

FORCE=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        -d|--data-dir)
            DATA_DIR="$2"
            DATASET_FILE="${DATA_DIR}/ShareGPT_V3_unfiltered_cleaned_split.json"
            shift 2
            ;;
        -f|--force)
            FORCE=true
            shift
            ;;
        -h|--help)
            print_usage
            exit 0
            ;;
        *)
            echo "Error: Unknown option: $1"
            print_usage
            exit 1
            ;;
    esac
done

# Check for required tools
for cmd in curl python3; do
    if ! command -v "$cmd" &>/dev/null; then
        echo "Error: '$cmd' is required but not found in PATH."
        exit 1
    fi
done

# Create data directory
mkdir -p "${DATA_DIR}"

# Download dataset
if [[ -f "${DATASET_FILE}" && "${FORCE}" == "false" ]]; then
    echo "Dataset already exists at: ${DATASET_FILE}"
    echo "Use --force to re-download."
else
    echo "Downloading ShareGPT V3 dataset..."
    echo "  URL: ${DATASET_URL}"
    echo "  Destination: ${DATASET_FILE}"

    curl -L --progress-bar \
        --retry 3 \
        --retry-delay 5 \
        -o "${DATASET_FILE}.tmp" \
        "${DATASET_URL}"

    mv "${DATASET_FILE}.tmp" "${DATASET_FILE}"
    echo "Download complete."
fi

# Verify file integrity - must be valid JSON array
echo ""
echo "Verifying dataset integrity..."

if ! python3 -c "
import json, sys, os
fp = os.environ['DATASET_FILE']
try:
    with open(fp, 'r') as f:
        data = json.load(f)
    if not isinstance(data, list):
        print('Error: Expected JSON array at top level', file=sys.stderr)
        sys.exit(1)
    if len(data) == 0:
        print('Error: Dataset is empty', file=sys.stderr)
        sys.exit(1)
    print(f'Integrity check passed: valid JSON array with {len(data)} entries')
except json.JSONDecodeError as e:
    print(f'Error: Invalid JSON - {e}', file=sys.stderr)
    sys.exit(1)
"; then
    echo "Error: Dataset integrity check failed."
    echo "The file may be corrupted. Try re-downloading with --force."
    exit 1
fi

# Print dataset statistics
echo ""
echo "=== Dataset Statistics ==="
python3 - "${DATASET_FILE}" <<'PYEOF'
import json
import os
import sys

dataset_file = sys.argv[1]

with open(dataset_file, "r") as f:
    data = json.load(f)

total_conversations = len(data)
total_turns = 0
human_turns = 0
assistant_turns = 0
max_turns = 0
total_chars = 0

for conv in data:
    turns = conv.get("conversations", [])
    num_turns = len(turns)
    total_turns += num_turns
    max_turns = max(max_turns, num_turns)
    for turn in turns:
        role = turn.get("from", "")
        value = turn.get("value", "")
        total_chars += len(value)
        if role == "human":
            human_turns += 1
        elif role == "gpt":
            assistant_turns += 1

avg_turns = total_turns / total_conversations if total_conversations > 0 else 0
avg_chars = total_chars / total_turns if total_turns > 0 else 0
file_size = os.path.getsize(dataset_file) / (1024 * 1024)

print(f"  Total conversations: {total_conversations:,}")
print(f"  Total turns:         {total_turns:,}")
print(f"  Human turns:         {human_turns:,}")
print(f"  Assistant turns:     {assistant_turns:,}")
print(f"  Avg turns/conv:      {avg_turns:.1f}")
print(f"  Max turns in conv:   {max_turns}")
print(f"  Total characters:    {total_chars:,}")
print(f"  Avg chars/turn:      {avg_chars:.0f}")
print(f"  File size:           {file_size:.1f} MB")
PYEOF

echo ""
echo "Dataset ready at: ${DATASET_FILE}"
