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
