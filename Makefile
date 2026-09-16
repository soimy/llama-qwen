.PHONY: download download-uncensored up up-uncensored down down-uncensored logs fix-driver setup-docker autostart-off install-gpu-nodes
download:
	bash scripts/download-model.sh

# 备用模型：orcarouter/Qwen3.8-27B-Uncensored-GGUF（abliterated，自带视觉塔）
download-uncensored:
	MODEL_REPO=orcarouter/Qwen3.8-27B-Uncensored-GGUF \
	MODEL_PREFIX=Qwen3.8-27B-Uncensored \
	MMPROJ_FILE=mmproj-Qwen3.8-27B-Uncensored-f16.gguf \
	QUANT=Q4_K_M \
	bash scripts/download-model.sh

# require-gpu.sh pre/verify：容器 healthy ≠ 用了 GPU。CUDA 初始化失败时 llama.cpp 会静默
# 回落 CPU（显存不涨），所以启动前后各验一次；失败会停掉容器并给出修法。
up:
	bash scripts/require-models.sh main
	bash scripts/require-gpu.sh pre
	docker compose up -d
	bash scripts/require-gpu.sh verify qwen-llama

# 备用模型单独启动（profile 隔离，避免误拉两个 27B 占满 3090 显存）；先 make down 停掉旧模型
up-uncensored:
	bash scripts/require-models.sh uncensored
	bash scripts/require-gpu.sh pre
	docker compose --profile uncensored up -d llama-uncensored openwebui searxng
	bash scripts/require-gpu.sh verify qwen-llama-uncensored

down:
	docker compose --profile uncensored down

down-uncensored:
	docker compose --profile uncensored stop llama-uncensored

logs:
	docker compose logs -f

fix-driver:
	@echo "以 root 修驱动：见 scripts/fix-driver-manual.sh；"
	@echo "  sudo bash scripts/fix-driver-manual.sh      # 全流程"
	@echo "  sudo bash scripts/fix-driver-manual.sh --nodes  # 仅重建设备节点"
	@echo "  bash scripts/fix-driver-manual.sh --help    # 纯命令清单"
	@echo "（dsh-tui 中可用 sudd；宿主机 TTY 可用 sudo）"

setup-docker:
	sudd bash scripts/setup-docker.sh

# 把已存在容器的重启策略全部改为 no（配合 compose 的 restart:"no"），开机不再自启
autostart-off:
	bash scripts/disable-autostart.sh

# 安装开机自动重建 /dev/nvidia* 节点的 oneshot 服务（udev 陈旧 workaround，需 root）
install-gpu-nodes:
	sudd bash scripts/install-gpu-nodes-service.sh
