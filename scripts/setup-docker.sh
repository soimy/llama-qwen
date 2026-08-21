#!/usr/bin/env bash
# 以 root 运行：安装 Docker + NVIDIA Container Toolkit 并启用 GPU 接入。
# 在 dsh-tui 里执行（会弹 root 密码框）：sudd bash scripts/setup-docker.sh
# 传统终端里则：sudo bash scripts/setup-docker.sh
set -euo pipefail

echo "==> 安装 docker + nvidia-container-toolkit"
pacman -S --noconfirm docker nvidia-container-toolkit

echo "==> 为 docker 配置 nvidia runtime（写入 /etc/docker/daemon.json）"
nvidia-ctk runtime configure --runtime=docker

echo "==> 启用并启动 docker"
systemctl enable --now docker

echo "==> 验证容器内可见 GPU"
# 注意：12.4.0 无 ubuntu24.04 标签（24.04 自 12.4.1 起），此处用实测可用的 12.6.3
docker run --rm --gpus all nvidia/cuda:12.6.3-base-ubuntu24.04 nvidia-smi

echo "==> 完成。随后：cp .env.example .env && make download && make up"
