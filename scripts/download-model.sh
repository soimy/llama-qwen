#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
MODEL_REPO="${MODEL_REPO:-unsloth/Qwen3.8-27B-GGUF}"
MODEL_PREFIX="${MODEL_PREFIX:-Qwen3.8-27B-UD}"
MMPROJ_FILE="${MMPROJ_FILE:-mmproj-F16.gguf}"
QUANT="${QUANT:-Q4_K_M}"
DEST="./models"
mkdir -p "$DEST"
echo "Downloading ${MODEL_PREFIX}-${QUANT}.gguf + ${MMPROJ_FILE} from ${MODEL_REPO} into ${DEST}"
# 用位置参数传文件名（绝不能拆进 --include）：hf 的 --include 是单值，
# 若再跟一个文件名会把它当 positional FILENAME、并覆盖 --include，导致只下一个文件。
hf download "$MODEL_REPO" \
  "${MODEL_PREFIX}-${QUANT}.gguf" "${MMPROJ_FILE}" \
  --local-dir "$DEST" ${HF_TOKEN:+--token "$HF_TOKEN"}
echo "Done. Contents of ${DEST}:"
ls -lh "$DEST"
