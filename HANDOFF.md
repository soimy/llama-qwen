# Handoff: 本地 Docker + llama.cpp 部署 Qwen3.8-27B（RTX 3090，KV Q4，含视觉与本地联网搜索）

> 本文件是本会话的产物。本会话早期环境为 **只读文件系统 + 无 sudo（no-new-privileges）**，无法写盘或修复系统；现已切到 full-access，将完整方案沉淀为 handoff，供新会话（具 root 与可写 FS）直接实现。

## 0. 本机事实（已勘察，权威）
- 系统：CachyOS（Arch 系 rolling），内核 `7.1.8-1-cachyos`，x86_64。
- CPU：AMD Ryzen 5 5600，6 核 / 12 线程，AVX2（无 AVX-512）。
- 内存：31 GB（约 20 GB 可用）+ Swap 31 GB。
- **GPU：RTX 3090 24 GB GDDR6X（PCI `10de:2204`，Compute Capability 8.6）**，`lspci` 确认。
- 驱动：内核模块 `nvidia`/`nvidia_modeset`/`nvidia_drm`/`nvidia_uvm` 已加载，版本 `610.57.04`（open 变体，包 `linux-cachyos-nvidia-open 7.1.8-1`，与运行内核匹配）。
- **异常**：`/dev/nvidia*` 与 `/dev/dri/*` 均不存在；udev 规则（`60-nvidia.rules`/`71-nvidia.rules`）与 `systemd-udevd` 均在；`nvidia-persistenced` 未运行 → `nvidia-smi` 报「无法与驱动通信」。**根因：udev 陈旧，设备节点未创建**，非配置缺失、非版本不匹配。
- Docker 未装；`nvidia-container-toolkit` 未装；磁盘 431 GB 空闲；网络出站可达 HuggingFace。

## 1. 模型事实（来自 `Qwen/Qwen3.8-27B` config.json + HF API）
- 名称：Qwen3.8-27B（架构 `qwen3_5`，`Qwen3_5ForConditionalGeneration`）。
- **混合线性注意力**：64 层中仅每 4 层（共 16 层）为 full attention，其余 48 层为 linear attention（常驻循环状态，不随上下文线性膨胀）→ KV 缓存只计 16 层。
- 全注意力 KV：4 头 × head_dim 256；原生上下文 **262144（256K）**，YaRN 可扩 **1,000,000（1M）**。
- 多模态（`language_model_only:false`，含 `mmproj-BF16.gguf` / `mmproj-F16.gguf`）→ 视觉可选启用。
- 权重 GGUF 仓库：`unsloth/Qwen3.8-27B-GGUF`（Unsloth 动态量化，已确认存在）。可选量化：`UD-Q4_K_M`(~16–17GB,默认) / `UD-IQ4_XS`(~14–15GB) / `UD-Q3_K_M`(~13–14GB)。视觉塔：`mmproj-F16.gguf`（同仓库）。
- 上游 llama.cpp 已支持 qwen3_5 线性注意力（PR #21897、issue #21385 在主线）；官方镜像 `ghcr.io/ggml-org/llama.cpp:server-cuda`（CUDA 12）可用。

## 2. 量化 / KV / 显存决策（RTX 3090 = 24 GB VRAM）
KV 缓存只计 16 个全注意力层，每 token = 2×4×256 = 2048 元素：
- f16：64 KB/token（256K≈16GB；1M≈64GB）。`q4_0`：16 KB/token（256K≈4GB；1M≈16GB）。
- **组合显存（权重+KV，全在 GPU）：**
  - 默认 `Q4_K_M(16.5GB) + KV q4_0 + 262144` ≈ **20.5 GB < 24 GB**，舒适（留 ~3.5GB）。
  - 激进 `IQ4_XS(14.5GB) + KV q4_0 + 524288` ≈ 22.5 GB，仍 < 24 GB。
  - 极限 `Q4_K_M + KV q4_0 + 1M(YaRN)` ≈ **32.5 GB > 24 GB** → KV 溢写到 31 GB 系统内存（llama.cpp 自动落 RAM，变慢）。
- **KV 量化选 `q4_0`**（`-ctk q4_0 -ctv q4_0`）：上游 issue #21385 表明混合/线性注意力模型上 Q4 KV 近乎无损，且最省显存，直接服务「最大化上下文」目标。
- 权重选 `UD-Q4_K_M`（质量最好的 Q4，完美适配 24GB）；`Q6_K`(~23GB) 余量过小、`Q8_0`(~29GB) 溢出，均不推荐。
- 结论：GPU 下 **256K–512K 为甜点**；系统内存作 KV 溢出与 CPU 兜底。

## 3. 系统修复 Runbook（新会话以 root 执行）
```bash
# (A) 实时创建设备节点（首选，免重启）
systemctl start nvidia-persistenced
udevadm trigger --action=add --subsystem-match=drm --subsystem-match=platform
udevadm trigger --action=add -p "nvidia*"
udevadm settle
ls -l /dev/nvidia0 /dev/nvidiactl /dev/dri          # 应出现
nvidia-smi                                          # 应显示 3090 / 24GB

# (B) 若仍缺节点：重装 open 驱动并重启（最干净）
pacman -S --noconfirm linux-cachyos-nvidia-open nvidia-utils opencl-nvidia
mkinitcpio -P
reboot

# (C) Docker + GPU 接入（驱动修好后）
pacman -S --noconfirm docker nvidia-container-toolkit
nvidia-ctk runtime configure --runtime=docker       # 写入 /etc/docker/daemon.json 的 nvidia runtime
systemctl enable --now docker
docker run --rm --gpus all nvidia/cuda:12.4.0-base-ubuntu24.04 nvidia-smi   # 容器内可见 3090 即通过
```
> 风险点：若 `nvidia-smi` 仍失败，回到 (B) 重启；`--gpus all` 必须等 (C) 完成（nvidia-container-toolkit + nvidia-ctk）才可用。

## 4. 仓库文件（在 `/home/sym/Repo/llama-qwen` 新建）
目录结构：
```
llama-qwen/
├── .gitignore
├── .env.example
├── Makefile
├── README.md
├── docker-compose.yml
├── searxng/settings.yml
└── scripts/download-model.sh
```

### 4.1 `.gitignore`
```
models/
*.gguf
.env
```

### 4.2 `.env.example`
```
MODEL_FILE=Qwen3.8-27B-UD-Q4_K_M.gguf
CTX_SIZE=262144
KV_TYPE=q4_0
NGPU_LAYERS=99
THREADS=12
OPEN_WEBUI_PORT=3000
WEBUI_SECRET_KEY=change-me-to-random
# 仅当模型仓库需授权时填写：
# HF_TOKEN=
```

### 4.3 `docker-compose.yml`
```yaml
services:
  llama:
    image: ghcr.io/ggml-org/llama.cpp:server-cuda
    container_name: qwen-llama
    volumes:
      - ./models:/models
    ports:
      - "8080:8080"
    deploy:
      resources:
        reservations:
          devices:
            - driver: nvidia
              count: 1
              capabilities: [gpu]
    command:
      - "-m";        - "/models/${MODEL_FILE}"
      - "--mmproj";  - "/models/mmproj-F16.gguf"
      - "-c";        - "${CTX_SIZE}"
      - "-ctk";      - "${KV_TYPE}"
      - "-ctv";      - "${KV_TYPE}"
      - "-ngl";      - "${NGPU_LAYERS}"
      - "-t";        - "${THREADS}"
      - "--host";    - "0.0.0.0"
      - "--port";    - "8080"
    restart: unless-stopped

  openwebui:
    image: ghcr.io/open-webui/open-webui:main
    container_name: qwen-openwebui
    ports:
      - "${OPEN_WEBUI_PORT}:8080"
    volumes:
      - openwebui:/app/backend/data
    environment:
      - OPENAI_API_BASE_URL=http://llama:8080/v1
      - OLLAMA_BASE_URL=
      - ENABLE_OPENAI_API=true
      - WEBUI_SEARCH_ENGINE=searxng
      - SEARXNG_QUERY_URL=http://searxng:8080/search?q=%s&format=json
      - WEBUI_SECRET_KEY=${WEBUI_SECRET_KEY}
    depends_on:
      - llama
      - searxng
    restart: unless-stopped

  searxng:
    image: searxng/searxng:latest
    container_name: qwen-searxng
    volumes:
      - ./searxng/settings.yml:/etc/searxng/settings.yml:ro
    environment:
      - SEARXNG_PORT=8080
      - SEARXNG_BIND_ADDRESS=0.0.0.0
    restart: unless-stopped

volumes:
  openwebui: {}
```
> 说明：SearXNG 仅留在 compose 内网（不发布主机端口），避免被公网滥用。Open WebUI 的 `WEBUI_SEARCH_ENGINE` / `SEARXNG_QUERY_URL` / `OPENAI_API_BASE_URL` 等 env 名跨版本会变动，实施时以运行版 `.env.example` 校正；若 Web Search 不生效，可在 Open WebUI UI 的 Settings → Web Search 手动选 SearXNG 并填 `http://searxng:8080/search?q=%s&format=json`。

### 4.4 `searxng/settings.yml`
```yaml
use_default_settings: true
server:
  limiter: false
  bind_address: "0.0.0.0"
  port: 8080
  secret_key: "change-me"
search:
  formats:
    - json
```

### 4.5 `scripts/download-model.sh`
```bash
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
```
依赖：`pipx install huggingface_hub[cli]`（提供 `hf` CLI）。若仓库需授权，设 `HF_TOKEN=...` 后运行。

### 4.6 `Makefile`
```make
.PHONY: download up down logs fix-driver
download:
	bash scripts/download-model.sh
up:
	docker compose up -d
down:
	docker compose down
logs:
	docker compose logs -f
fix-driver:
	@echo "以 root 在可写系统执行："; \
	 echo "systemctl start nvidia-persistenced"; \
	 echo "udevadm trigger --action=add --subsystem-match=drm --subsystem-match=platform"; \
	 echo "udevadm trigger --action=add -p 'nvidia*'"; \
	 echo "udevadm settle"; \
	 echo "nvidia-smi"
```

### 4.7 `README.md`（要点）
- 硬件适配：RTX 3090 24GB，权重 Q4_K_M 全量上 GPU（`-ngl 99`），KV `q4_0`，上下文 256K。
- 快速开始：先按第 3 节修复驱动 → `cp .env.example .env` → `make download` → `make up` → 浏览器开 `http://localhost:3000` 注册管理员 → Settings → Connections 确认 `http://llama:8080/v1` → 开 Web Search。
- 视觉：上传图片即可（依赖 `mmproj-F16.gguf` 与 `--mmproj`）。
- 性能：27B Q4 全 GPU 解码约 40–70 tok/s；显存常驻 ~20.5GB（256K）。
- 故障排查：见第 3、5 节。

## 5. 验证 / 验收
1. `nvidia-smi` 显示 3090 / 24 GB（驱动修复）。
2. `docker run --rm --gpus all ... nvidia-smi` 容器内可见 3090（Docker GPU）。
3. `curl localhost:8080/v1/models` 返回 `Qwen3.8-27B`；`nvidia-smi` 显存 ~20 GB。
4. Open WebUI 上传图片可描述（视觉）；开 Web Search 问实时问题有引用（搜索）。
5. 压测 ~50K token 长输入下 KV Q4 不 OOM、可生成。

## 6. 风险与失败模式
- 驱动节点缺失：回到第 3 节 (B) 重启/重装；Docker 必须 (C) 完成才能 `--gpus all`。
- 架构支持：若官方 `:server-cuda` 加载 GGUF 报未知架构，回退自构建最新 master CUDA 镜像，或参考 fork `VeroFess/llama.cpp_3090x2_qwen3.8_q8_opt`（TCQ/MTP 为性能增强，非必需）。
- mmproj 不匹配：统一用 `unsloth/Qwen3.8-27B-GGUF` 的 `mmproj-F16.gguf`；不符则换 `mmproj-BF16.gguf` 或官方 `Qwen/Qwen3.8-27B` 的 mmproj。
- SearXNG 出站：联网搜索依赖本机出站访问公开引擎；受限时 Web Search 返回空，但模型与视觉不受影响。
- 1M 上下文超显存：KV 溢写系统内存、变慢；默认 256K–512K。

## 7. 假设
- 默认全 GPU 推理（驱动修复后）；CPU 兜底配置（`:server` 镜像 + `-ngl 0`）保留但非首选。
- 权重取 Unsloth 动态 Q4 家族；可换官方/Qwen 原生 GGUF。
- 新会话具 root 权限与可写 FS；远程 git 仓库如需绑定可后续 `git remote add`。
