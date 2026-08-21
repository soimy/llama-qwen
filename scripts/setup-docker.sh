#!/usr/bin/env bash
# 以 root 运行：安装 Docker + NVIDIA Container Toolkit 并启用 GPU 接入。
# 用法（需密码）：sudo bash scripts/setup-docker.sh
set -euo pipefail

echo "==> 安装 docker + nvidia-container-toolkit"
pacman -S --noconfirm docker nvidia-container-toolkit

echo "==> 为 docker 配置 nvidia runtime（写入 /etc/docker/daemon.json）"
nvidia-ctk runtime configure --runtime=docker

echo "==> 启用并启动 docker"
systemctl enable --now docker

echo "==> 验证容器内可见 GPU"
docker run --rm --gpus all nvidia/cuda:12.4.0-base-ubuntu24.04 nvidia-smi

echo "==> 完成。随后：cp .env.example .env && make download && make up"
