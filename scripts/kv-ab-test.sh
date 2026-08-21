#!/usr/bin/env bash
# KV-cache offloading A/B 冒烟测试（宿主机 docker 执行）
#
# 目标：比较三种配置的运行效率，供决定是否开 KV offload 及上下文大小。
#   A   = KV 在 GPU（默认 -kvo）, ctx 128k (131072)
#   B1  = KV offload（-nkvo）, ctx 128k (131072)
#   B2  = KV offload（-nkvo）, ctx 256k (262144)
#
# 方法：每档用一个独立容器 (llama.abtest) + 独立端口 (8091/8092/8093) 启动，
#       等待 /health ok 后，用固定长度 prompt 做一次 warmup + 一次实测，
#       抓取 /v1/chat/completions 返回的 timings（tokens_per_second 等）。
#       同时记录加载后 nvidia-smi 显存占用。
#
# 用法：bash scripts/kv-ab-test.sh          （非 docker 组用户会自动用 sudo）
set -euo pipefail
cd "$(dirname "$0")/.."

# ---------- 参数 ----------
MODEL_FILE="${MODEL_FILE:-Qwen3.8-27B-UD-Q4_K_M.gguf}"
MODEL_PATH="/models/${MODEL_FILE}"
MMPROJ="/models/mmproj-F16.gguf"
IMAGE="ghcr.io/ggml-org/llama.cpp:server-cuda"
NGPU="${NGPU_LAYERS:-99}"
THREADS="${THREADS:-12}"
CTX128=131072
CTX256=262144
KV=q4_0
ROLLOUT=256          # 每轮生成的 max_tokens（冒烟）
PROMPT_LEN=512       # prompt 大致 token 目标（脚本用重复文本近似）

# docker 前缀（自动 sudo）
if [ "$(id -u)" -eq 0 ] || id -nG | grep -qw docker; then DOCKER="docker"; else DOCKER="sudo docker"; fi

# 造一份长度可控的英文 prompt 文本（~PROMPT_LEN token，qwen 词表英文本约 4 chars/token）
SENT="The quick brown fox jumps over the lazy dog, and the sun rises in the east over a calm river valley."
_prompt=""
while [ ${#_prompt} -lt $((PROMPT_LEN*5)) ]; do _prompt+="$SENT "; done

# 记录一组结果
declare -a NAME PROMPT_TPS GEN_TPS VRAM

run_case () {
  local label="$1" ct="$2" offload="$3" port="$4"
  echo
  echo "=============================================="
  echo " 用例 $label : ctx=${ct}  KV_offload=${offload:-GPU}"
  echo "=============================================="
  local extra=()
  [ -n "$offload" ] && extra=("-nkvo")
  $DOCKER rm -f llama.abtest >/dev/null 2>&1 || true
  echo "  >> 启动容器 (localhost:${port}) ..."
  $DOCKER run -d --name llama.abtest --gpus all \
    -v "$PWD/models:/models" -p "127.0.0.1:${port}:8080" \
    "$IMAGE" -m "$MODEL_PATH" --mmproj "$MMPROJ" \
    -c "$ct" -ctk "$KV" -ctv "$KV" -ngl "$NGPU" -t "$THREADS" \
    "${extra[@]}" --host 0.0.0.0 --port 8080 >/dev/null
  # 等待就绪
  local ok=0
  for i in $(seq 1 40); do
    if curl -s --max-time 3 "http://127.0.0.1:${port}/health" | grep -q '"ok"'; then ok=1; break; fi
    sleep 3
  done
  if [ "$ok" -ne 1 ]; then
    echo "  !! 等待 ${label} 就绪超时，跳过"
    $DOCKER logs --tail 20 llama.abtest 2>&1 | tail -20
    NAME+=("$label"); PROMPT_TPS+=("-"); GEN_TPS+=("-"); VRAM+=("-")
    return 1
  fi
  echo "  >> 已就绪，记录显存："
  local vram=$($DOCKER run --rm --gpus all nvidia/cuda:12.6.3-base-ubuntu24.04 nvidia-smi --query-gpu=memory.used --format=csv,noheader 2>/dev/null | head -1)
  echo "      GPU used = ${vram}"
  # warmup（较短，确保缓存/内核已热）
  curl -s --max-time 120 "http://127.0.0.1:${port}/v1/chat/completions" \
    -H 'Content-Type: application/json' \
    -d "{\"model\":\"${MODEL_PATH}\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}],\"max_tokens\":8}" >/dev/null
  # 实测：固定 prompt，测量 timings
  local resp
  resp=$(curl -s --max-time 300 "http://127.0.0.1:${port}/v1/chat/completions" \
    -H 'Content-Type: application/json' \
    -d "{\"model\":\"${MODEL_PATH}\",\"messages\":[{\"role\":\"user\",\"content\":\"$_prompt\"}],\"max_tokens\":${ROLLOUT},\"temperature\":0}")
  local ptps gtps
  ptps=$(echo "$resp" | python3 -c "import sys,json;d=json.load(sys.stdin);print(round(d['timings']['prompt_per_second'],2))" 2>/dev/null || echo "-")
  gtps=$(echo "$resp" | python3 -c "import sys,json;d=json.load(sys.stdin);print(round(d['timings']['predicted_per_second'],2))" 2>/dev/null || echo "-")
  echo "      prompt t/s = ${ptps}   gen t/s = ${gtps}"
  NAME+=("$label"); PROMPT_TPS+=("$ptps"); GEN_TPS+=("$gtps"); VRAM+=("$vram")
  $DOCKER rm -f llama.abtest >/dev/null 2>&1 || true
}

run_case "A  (GPU KV,  128k)" "$CTX128" ""       8091
run_case "B1 (offload,128k)" "$CTX128" "off"    8092
run_case "B2 (offload,256k)" "$CTX256" "off"    8093

echo
echo "=============================================="
echo "  A/B 对比简报"
echo "=============================================="
printf "%-22s %-14s %-12s %-12s %s\n" "用例" "prompt t/s" "gen t/s" "GPU used" "结论"
for i in "${!NAME[@]}"; do
  printf "%-22s %-14s %-12s %-12s\n" "${NAME[$i]}" "${PROMPT_TPS[$i]}" "${GEN_TPS[$i]}" "${VRAM[$i]}"
done
echo
echo "参考：本机默认(GPU KV, 256k, 无ffload) 实测 gen ≈ 36.5 tok/s，GPU used ≈ 23.9GB"
