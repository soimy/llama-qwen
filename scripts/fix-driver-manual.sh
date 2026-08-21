#!/usr/bin/env bash
# 手动修复 NVIDIA RTX 3090 驱动设备节点 —— 宿主机 TTY（可输 root 密码）执行。
#
# 背景（2026-08-21 实测闭环）：内核驱动模块健康（610.57.04 / 7.1.8-1），
# 但 /dev/nvidia* 与 /dev/dri/* 缺失 → nvidia-smi 报「无法与驱动通信」。
# 根因：udev 陈旧、设备节点未创建（非配置缺失、非版本不匹配）。
# 本文档流程在真实宿主机 TTY 下已成功：trigger 重建节点 → 宿主机 nvidia-smi 通
# → Docker --gpus all 容器内可见 3090。
#
# 用法：
#   sudo bash scripts/fix-driver-manual.sh          # 全流程
#   bash scripts/fix-driver-manual.sh --help        # 只看命令清单，不执行
#   sudo bash scripts/fix-driver-manual.sh --nodes  # 只做第 1 步（重建节点）
set -euo pipefail

STEP1='systemctl enable --now nvidia-persistenced
udevadm trigger --action=add --subsystem-match=drm --subsystem-match=platform
udevadm trigger --type=devices --action=add --subsystem-match=char
udevadm settle
ls -l /dev/nvidia0 /dev/nvidiactl /dev/nvidia-uvm /dev/nvidia-modeset /dev/dri
nvidia-smi'

STEP2='# 若 STEP1 后仍缺 /dev/nvidia*（如 char 主设备 195 未建），rebind 驱动重建节点：
echo 0000:07:00.0 > /sys/bus/pci/drivers/nvidia/unbind
echo 0000:07:00.0 > /sys/bus/pci/drivers/nvidia/bind
udevadm settle
ls -l /dev/nvidia* /dev/dri
nvidia-smi'

STEP3='# 兜底：重装 open 驱动并重启（最干净）
pacman -S --noconfirm linux-cachyos-nvidia-open nvidia-utils opencl-nvidia
mkinitcpio -P
reboot'

STEP4='# Docker + GPU 接入（驱动修好后）
pacman -S --noconfirm docker nvidia-container-toolkit
nvidia-ctk runtime configure --runtime=docker
systemctl enable --now docker
docker run --rm --gpus all nvidia/cuda:12.6.3-base-ubuntu24.04 nvidia-smi   # 容器内可见 3090 即通过'

help() {
  cat <<'EOF'
━━━ NVIDIA RTX 3090 驱动修复命令清单（宿主机 TTY / root 执行）━━━

第 1 步（首选，免重启）实时创建设备节点：
$ STEP1

第 2 步 若 ST1 后仍缺节点 → driver rebind 重建：
$ STEP2

第 3 步 兜底重装驱动并重启：
$ STEP3

第 4 步 Docker GPU 接入（驱动通后）：
$ STEP4

通过判定：
  - 宿主机 nvidia-smi 显示 "RTX 3090 … 24576 MiB"
  - docker run --gpus all ... nvidia-smi 容器内同样可见 3090
EOF
}

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
  help
  exit 0
fi

if [ "${1:-}" = "--nodes" ]; then
  echo "==> 第 1 步：重建设备节点"
  echo "$STEP1" | sed 's/^/    /'
  echo "---- 执行 ----"
  bash -c "$STEP1"
  exit 0
fi

if [ "$(id -u)" -ne 0 ]; then
  echo "错误：请以 root 运行（sudo bash $(basename "$0")）" >&2
  exit 1
fi

echo "==> 第 1 步：实时创建设备节点"
bash -c "$STEP1"
echo

if ls /dev/nvidia0 /dev/nvidiactl >/dev/null 2>&1 && nvidia-smi >/dev/null 2>&1; then
  echo "==> 第 1 步成功：设备节点就绪，nvidia-smi 可通信。"
else
  echo "==> 第 1 步未达预期，尝试第 2 步 driver rebind ..."
  bash -c "$STEP2"
  if ! (ls /dev/nvidia0 >/dev/null 2>&1 && nvidia-smi >/dev/null 2>&1); then
    echo "==> 仍未就绪：执行第 3 步重装驱动并重启。"
    bash -c "$STEP3"
    exit 0
  fi
fi

echo
echo "==> 第 4 步：Docker + GPU 接入"
if command -v nvidia-ctk >/dev/null 2>&1 && systemctl is-active docker >/dev/null 2>&1; then
  bash -c "$STEP4"
else
  echo "nvidia-container-toolkit/docker 未就绪，手动执行："
  echo "$STEP4" | sed 's/^/    /'
fi

echo "==> 完成。验证主机与容器内 nvidia-smi 均显示 RTX 3090 / 24576 MiB。"
