.PHONY: download up down logs fix-driver setup-docker
download:
	bash scripts/download-model.sh

up:
	docker compose up -d

down:
	docker compose down

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
