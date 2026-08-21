#!/usr/bin/env bash
# 宿主机 TTY 部署：启动 llama.cpp server + Open WebUI + SearXNG（GPU 接入，需 docker + compose v2 + nvidia-container-toolkit）。
# 前置（沙箱/本会话已完成，无需重复）：
#   - scripts/fix-driver-manual.sh 已打通宿主机与容器内 GPU（docker run --gpus all 可见 3090）
#   - .env 已生成、docker-compose.yml 已修正 command 语法、镜像已确认存在
#   - models/Qwen3.8-27B-UD-Q4_K_M.gguf + models/mmproj-F16.gguf 已下载就位
#
# 用法：bash scripts/deploy-host.sh
set -euo pipefail
cd "$(dirname "$0")/.."

echo "==> [1/3] 确保 docker compose v2 可用（含 GPU deploy 语法）"
if ! docker compose version >/dev/null 2>&1; then
  echo "    未检测到 compose v2 插件，尝试安装 docker-compose 包..."
  sudo pacman -S --noconfirm docker-compose
fi
docker compose version

echo "==> [2/3] 校验模型文件就位"
ls -lh models/Qwen3.8-27B-UD-Q4_K_M.gguf models/mmproj-F16.gguf

echo "==> [3/3] 启动 compose 服务（后台）"
docker compose up -d

echo "==> 等待 llama server 就绪（最长 120s）"
for i in $(seq 1 24); do
  if curl -s --max-time 3 http://localhost:8080/health >/dev/null 2>&1; then
    echo "    llama server 已就绪"
    break
  fi
  sleep 5
done

echo
echo "==> 服务状态"
docker compose ps
echo
echo "==> llama 模型列表："
curl -s http://localhost:8080/v1/models || echo "(等待模型装载完成后再试)"
echo
echo "访问入口：Open WebUI http://localhost:3000 （首次注册管理员 → Settings→Connections 确认 http://llama:8080/v1 → 开 Web Search）"
