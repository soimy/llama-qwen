#!/usr/bin/env bash
# 启动前/后的 CUDA 预检：堵住「容器起来了，但 llama.cpp 悄悄跑 CPU」这类静默失败。
#
# 为什么需要（2026-09-16 实机踩坑）：容器 Up (healthy)、端口正常、容器内 nvidia-smi 也能看到
# 3090，但 llama.cpp 启动时 CUDA 初始化失败，日志里只有两行：
#     E ggml_cuda_init: failed to initialize CUDA: unknown error
#     warning: no usable GPU found, --gpu-layers option will be ignored
# 于是 -ngl 99 被忽略、27B 全在系统内存里跑，用户侧唯一表征就是「显存没涨」，极易误判。
#
# 根因：/etc/cdi/nvidia.yaml（nvidia-container-toolkit 的 CDI 规格）里写死了 nvidia-uvm 的
# 主设备号，而该主设备号由内核在每次加载 nvidia_uvm 时动态分配（本机实测上一 boot 237、
# 本 boot 238）。规格过期后，容器里拿到的 /dev/nvidia-uvm 指向别的设备（237 是 nvme），
# cuInit 直接失败；宿主机的 /dev/nvidia* 反而是好的。
# 修法：sudo nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml
#       （仓库脚本：sudo bash scripts/fix-driver-manual.sh --cdi）
#
# 判定依据（重要，别只看日志）：本镜像里的 llama.cpp b10853 **成功时不留任何 CUDA 日志行**，
# 失败时才打 "no usable GPU found"。所以「成功」只认显存/进程事实：
#   docker exec <c> nvidia-smi --query-compute-apps=... 里有没有 llama-server 的占用。
# 也别在宿主机裸跑 nvidia-smi 做判断——dsh-tui 沙箱里 /dev 被屏蔽，会假报「无法与驱动通信」。
#
# 用法：
#   bash scripts/require-gpu.sh pre              # 起容器前：一次性容器实测 CUDA
#   bash scripts/require-gpu.sh verify <容器名>   # 起容器后：验显存，失败则停掉容器
# 环境变量：
#   REQUIRE_GPU_IMAGE    覆盖镜像（默认取 docker-compose.yml 里第一个 image:）
#   REQUIRE_GPU_TIMEOUT  等模型加载完成的秒数（默认 180）
#   REQUIRE_GPU_WAIT     0 = 不验显存，只看启动早期有没有 CUDA 失败标志
#   REQUIRE_GPU_KEEP     1 = 预检失败时不自动停容器（默认会停，免得 27B 常驻内存）
set -euo pipefail
cd "$(dirname "$0")/.."

IMAGE="${REQUIRE_GPU_IMAGE:-$(sed -n 's/^[[:space:]]*image:[[:space:]]*\(.*[^[:space:]]\)[[:space:]]*$/\1/p' docker-compose.yml | head -n1)}"
TIMEOUT="${REQUIRE_GPU_TIMEOUT:-180}"
WAIT_LOAD="${REQUIRE_GPU_WAIT:-1}"
KEEP="${REQUIRE_GPU_KEEP:-0}"

LEDGER_FAIL='no usable GPU found|failed to initialize CUDA'
MIN_VRAM_MB=256   # 显存里至少有这么大一块才算「上卡」；CPU 回落时根本没有本进程

hint() {
  cat >&2 <<'EOF'

  容器内 CUDA 不可用 —— llama.cpp 会**静默回落到 CPU**（-ngl 被忽略），所以显存不会涨。
  按顺序查：

    1) 容器里看到的是不是「假 uvm 设备」：
         docker run --rm --gpus all --entrypoint sh <镜像> -c 'ls -l /dev/nvidia-uvm'
       正常应是 238,0（内核 /proc/devices 里 "nvidia-uvm" 的主设备号）；若是别的号（如 237），
       说明 CDI 规格过期 —— 这是本机 2026-09-16 踩到的根因。

    2) 重新生成 CDI 规格（root）：
         sudo nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml
         # 或用仓库脚本：sudo bash scripts/fix-driver-manual.sh --cdi

    3) 节点本身也缺（宿主机真实 TTY 上看 /dev/nvidia*）：
         sudo bash scripts/fix-driver-manual.sh --nodes
         make install-gpu-nodes     # 装开机自愈服务，防复发

  自查日志：docker logs <容器名> 2>&1 | grep -E 'CUDA|no usable GPU'
EOF
}

need_docker() {
  command -v docker >/dev/null 2>&1 || { echo "✗ 未找到 docker" >&2; exit 1; }
  docker info >/dev/null 2>&1 || { echo "✗ docker 未运行（systemctl status docker）" >&2; exit 1; }
  [[ -n "$IMAGE" ]] || { echo "✗ 无法从 docker-compose.yml 解析镜像名" >&2; exit 1; }
}

stop_broken() {
  local name="$1" reason="$2"
  echo >&2
  echo "✗ GPU 预检失败：$reason" >&2
  echo "  容器 $name 正在 CPU 上跑 27B（吃内存、很慢），预检的意义就是不让它悄悄留着。" >&2
  if [[ "$KEEP" == "1" ]]; then
    echo "  REQUIRE_GPU_KEEP=1，保留容器：docker logs -f $name" >&2
  else
    docker stop "$name" >/dev/null 2>&1 && echo "  已自动停掉 $name（用 REQUIRE_GPU_KEEP=1 可保留）" >&2
  fi
}

cmd_pre() {
  need_docker
  if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
    echo "==> 镜像 $IMAGE 尚未拉取，跳过 CUDA 预检（compose 会自行 pull）"
    return 0
  fi
  echo "==> CUDA 预检：一次性容器实测（$IMAGE）"
  local out
  out="$(docker run --rm --gpus all --entrypoint /app/llama-server "$IMAGE" --list-devices 2>&1 || true)"
  if grep -q 'CUDA0' <<<"$out"; then
    sed -n 's/^[[:space:]]*\(CUDA0.*\)/    ✓ \1/p' <<<"$out"
    echo "    OK：容器内 CUDA 可用"
    return 0
  fi
  sed 's/^/    /' <<<"$out" >&2
  hint
  return 1
}

cmd_verify() {
  local name="${1:-}"
  [[ -n "$name" ]] || { echo "用法: bash scripts/require-gpu.sh verify <容器名>" >&2; exit 2; }
  need_docker
  docker inspect "$name" >/dev/null 2>&1 || { echo "✗ 找不到容器 $name" >&2; exit 1; }

  local deadline=$(( SECONDS + TIMEOUT )) log
  echo "==> GPU 预检：盯 $name 的启动日志（最多 ${TIMEOUT}s）"
  while :; do
    log="$(docker logs "$name" 2>&1 || true)"
    if grep -qE "$LEDGER_FAIL" <<<"$log"; then
      grep -E "$LEDGER_FAIL" <<<"$log" | sed 's/^/    /' >&2
      stop_broken "$name" "日志里出现 CUDA 初始化失败"
      hint
      return 1
    fi
    if [[ "$WAIT_LOAD" == "0" ]]; then
      # 只做早期把关：CUDA 失败信息在启动 1s 内就会打出来
      if (( SECONDS >= deadline )); then
        echo "    OK：未见 CUDA 失败标志（REQUIRE_GPU_WAIT=0，未验显存）"
        return 0
      fi
      sleep 2
      continue
    fi
    if grep -qE 'model loaded|listening on' <<<"$log"; then break; fi
    if (( SECONDS >= deadline )); then
      docker logs --tail 20 "$name" 2>&1 | sed 's/^/    /' >&2
      stop_broken "$name" "等了 ${TIMEOUT}s 模型都没加载完（服务没起来？）"
      hint
      return 1
    fi
    sleep 2
  done

  # 成功路径不能靠日志（llama.cpp 成功时不打 CUDA 行），直接看显存里有没有这个进程。
  echo "==> 核对显存：$name 是否真的在 GPU 上"
  local apps vram mb ok=0
  apps="$(docker exec "$name" nvidia-smi --query-compute-apps=pid,process_name,used_memory --format=csv,noheader 2>/dev/null || true)"
  vram="$(docker exec "$name" nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits 2>/dev/null | tr -d ' \r' || true)"
  [[ "$vram" =~ ^[0-9]+$ ]] || vram="?"   # 容器里没有 nvidia-smi 时 exec 会把报错当输出返回
  if [[ -n "$apps" ]]; then sed 's/^/    /' <<<"$apps"; fi
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    mb="${line##*,}"; mb="${mb//[^0-9]/}"
    [[ -n "$mb" ]] && (( mb >= MIN_VRAM_MB )) && ok=1
  done <<<"$apps"

  if (( ok )); then
    echo "    ✓ 显存占用 ${vram:-?} MiB，llama-server 已在 GPU 上"
    return 0
  fi
  echo "    ✗ 显存里没有本容器的进程（总占用 ${vram} MiB；CPU 回落时通常 ≈1GB 桌面基线）" >&2
  grep -q 'executable file not found' <<<"$apps" \
    && echo "    （容器里连 nvidia-smi 都没有 —— GPU 根本没注入这个容器）" >&2
  docker logs --tail 20 "$name" 2>&1 | sed 's/^/    /' >&2
  stop_broken "$name" "模型跑在 CPU 上，显存里没有 llama-server"
  hint
  return 1
}

case "${1:-}" in
  pre)    cmd_pre ;;
  verify) shift; cmd_verify "$@" ;;
  *)      echo "用法: bash scripts/require-gpu.sh [pre|verify <容器名>]" >&2; exit 2 ;;
esac
