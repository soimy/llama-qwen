#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
MODEL_REPO="${MODEL_REPO:-unsloth/Qwen3.8-27B-GGUF}"
MODEL_PREFIX="${MODEL_PREFIX:-Qwen3.8-27B-UD}"
MMPROJ_FILE="${MMPROJ_FILE:-mmproj-F16.gguf}"
QUANT="${QUANT:-Q4_K_M}"
DEST="./models"
mkdir -p "$DEST"

# .env 只有 docker compose 会自动加载，shell 脚本不会——而 gated 仓库（如 orcarouter 的
# uncensored）必须带 token 才能下载。故这里显式把 .env 里的 HF_TOKEN 读进来。
# 只取 HF_TOKEN 一项、不整体 source：既不会执行 .env 里的其它内容，也不会覆盖 Makefile
# 通过环境变量传入的 MODEL_REPO / MODEL_PREFIX / MMPROJ_FILE / QUANT。
# 已存在的环境变量优先（显式传入的值不被 .env 覆盖）。
if [[ -z "${HF_TOKEN:-}" && -f .env ]]; then
  HF_TOKEN="$(sed -n 's/^[[:space:]]*HF_TOKEN[[:space:]]*=[[:space:]]*//p' .env | tail -n1)"
  HF_TOKEN="${HF_TOKEN//[[:space:]]/}"   # 去掉空白与行尾 \r
  HF_TOKEN="${HF_TOKEN%\"}"; HF_TOKEN="${HF_TOKEN#\"}"
  HF_TOKEN="${HF_TOKEN%\'}"; HF_TOKEN="${HF_TOKEN#\'}"
  if [[ -n "$HF_TOKEN" ]]; then
    export HF_TOKEN
    echo "Using HF_TOKEN from .env"
  else
    unset HF_TOKEN
  fi
fi

echo "Downloading ${MODEL_PREFIX}-${QUANT}.gguf + ${MMPROJ_FILE} from ${MODEL_REPO} into ${DEST}"
# 用位置参数传文件名（绝不能拆进 --include）：hf 的 --include 是单值，
# 若再跟一个文件名会把它当 positional FILENAME、并覆盖 --include，导致只下一个文件。
if ! hf download "$MODEL_REPO" \
  "${MODEL_PREFIX}-${QUANT}.gguf" "${MMPROJ_FILE}" \
  --local-dir "$DEST" ${HF_TOKEN:+--token "$HF_TOKEN"}; then
  cat >&2 <<'EOF'

下载失败。若报 "Access denied. This repository requires approval."，说明该仓库是 gated，
按顺序检查（注意：gated 仓库的模型页与文件列表是公开的，「网页能打开」≠「有下载权限」，
真正被拦的只有权重文件本身）：
  1. 本机是否已登录： hf auth whoami        （未登录则 hf auth login）
  2. 网页端是否已同意条款： https://huggingface.co/<owner>/<repo> 点 Agree
     （审批绑在你的账号上，但下载请求必须带上该账号的凭据；匿名请求一定会被拒）
  3. 或在 .env 里填 HF_TOKEN=hf_xxx（read 权限即可），本脚本会自动读取
EOF
  exit 1
fi
echo "Done. Contents of ${DEST}:"
ls -lh "$DEST"
