#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
MODEL_REPO="${MODEL_REPO:-unsloth/Qwen3.8-27B-GGUF}"
QUANT="${QUANT:-Q4_K_M}"
DEST="./models"
mkdir -p "$DEST"
echo "Downloading ${QUANT} weights + mmproj from ${MODEL_REPO} into ${DEST}"
hf download "$MODEL_REPO" \
  --include "Qwen3.8-27B-UD-${QUANT}.gguf" "mmproj-F16.gguf" \
  --local-dir "$DEST" ${HF_TOKEN:+--token "$HF_TOKEN"}
echo "Done. Contents of ${DEST}:"
ls -lh "$DEST"
