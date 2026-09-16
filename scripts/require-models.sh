#!/usr/bin/env bash
# 启动前校验：compose 所需的 GGUF 权重是否都在 ./models 下。
#
# 为什么需要：缺权重时容器依然会被正常拉起，llama.cpp 加载失败后约 1 秒即 Exited (1)，
# 表征只有「显存没涨」+ 日志里一行 No such file or directory，很容易被误判成显存/参数问题
# （见 README 的排查记录）。这里前置拦截，并直接给出该跑哪条下载命令。
#
# 用法：bash scripts/require-models.sh [main|uncensored]    默认 main
set -euo pipefail
cd "$(dirname "$0")/.."

DEST="./models"
MODE="${1:-main}"

# 只取 .env 里某个键的值（不整体 source，避免执行任意内容/覆盖调用方环境变量）
env_val() {
  [[ -f .env ]] || return 0
  sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*//p" .env \
    | tail -n1 | tr -d '\r' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//'
}

case "$MODE" in
  main)
    # 注意：主服务的 --mmproj 在 docker-compose.yml 里是硬编码的 /models/mmproj-F16.gguf
    specs=(
      "${MODEL_FILE:-$(env_val MODEL_FILE)}|MODEL_FILE"
      "mmproj-F16.gguf|docker-compose.yml 硬编码"
    )
    hint="make download"
    ;;
  uncensored)
    specs=(
      "${MODEL_FILE_UNCENSORED:-$(env_val MODEL_FILE_UNCENSORED)}|MODEL_FILE_UNCENSORED"
      "${MMPROJ_FILE_UNCENSORED:-$(env_val MMPROJ_FILE_UNCENSORED)}|MMPROJ_FILE_UNCENSORED"
    )
    hint="make download-uncensored"
    ;;
  *)
    echo "用法: bash scripts/require-models.sh [main|uncensored]" >&2
    exit 2
    ;;
esac

echo "==> 校验 $MODE 所需权重（$DEST/）"
missing=0
for spec in "${specs[@]}"; do
  file="${spec%%|*}"; src="${spec##*|}"
  if [[ -z "$file" ]]; then
    printf '    ✗ 未配置（%s 为空）\n' "$src"
    missing=1
  elif [[ -f "$DEST/$file" ]]; then
    printf '    ✓ %s  (%s)\n' "$file" "$(du -h "$DEST/$file" | cut -f1)"
  else
    printf '    ✗ %s  缺失\n' "$file"
    missing=1
  fi
done

if (( missing )); then
  cat >&2 <<EOF

缺少权重文件，已中止启动——否则容器会照常起来、llama.cpp 加载失败后秒退，
表现为「显存没涨」，排查时容易误判成显存或参数问题。

  → 下载权重：$hint
  → 若该仓库是 gated（如 orcarouter 的 uncensored）：
      1) hf auth login        # 本机登录，之后 hf download 会自动使用该凭据
      2) 到模型页点 Agree      # 审批绑账号，但请求必须带上该账号的凭据；匿名必被拒
      3) 或在 .env 里填 HF_TOKEN=hf_xxx（read 权限即可）
     提示：gated 仓库的模型页/文件列表是公开的，「网页能打开」≠「有下载权限」。
EOF
  exit 1
fi
echo "    OK：权重齐全"
