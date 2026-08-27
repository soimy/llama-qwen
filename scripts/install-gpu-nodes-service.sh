#!/usr/bin/env bash
# 以 root 运行：安装一个 oneshot systemd 服务，在每次开机后检查并重建
# /dev/nvidia* 设备节点（udev 陈旧 workaround，本机反复出现的现象）。
# 幂等：节点齐全时直接跳过，不重复触发；仅当任一节点缺失时才重建。
# 确保后续手动 `make up` / `make up-uncensored` 时容器能拿到 GPU。
#
# 用法（dsh-tui）：sudd bash scripts/install-gpu-nodes-service.sh
# 用法（终端）：  sudo  bash scripts/install-gpu-nodes-service.sh
set -euo pipefail

HELPER=/usr/local/sbin/recreate-gpu-nodes.sh
UNIT=/etc/systemd/system/gpu-nodes.service

echo "==> 写入 $HELPER（检查式重建 helper）"
cat > "$HELPER" <<'EOF'
#!/usr/bin/env bash
# udev 陈旧 workaround：仅在 /dev/nvidia* 节点缺失时重建（幂等）。
# 节点齐全 -> 直接跳过；有缺失 -> udevadm trigger + settle + 重启 nvidia-persistenced。
set -uo pipefail

NEEDED=(
  /dev/nvidia0
  /dev/nvidiactl
  /dev/nvidia-uvm
  /dev/nvidia-modeset
)

missing=0
for f in "${NEEDED[@]}"; do
  if [ ! -e "$f" ]; then
    missing=1
    echo "缺失节点: $f"
  fi
done

if [ "$missing" -eq 0 ]; then
  echo "所有 /dev/nvidia* 节点已存在，跳过重建。"
  exit 0
fi

echo "==> 重建 /dev/nvidia* 节点 (udevadm trigger)..."
udevadm trigger --action=add --subsystem-match=drm --subsystem-match=platform
udevadm trigger --type=devices --action=add --subsystem-match=char
udevadm settle
systemctl try-restart nvidia-persistenced || true

echo "==> 核对："
ls -l /dev/nvidia* 2>/dev/null \
  || { echo "!! 仍有节点缺失，请手动执行: sudo bash scripts/fix-driver-manual.sh"; exit 1; }
EOF
chmod 755 "$HELPER"

echo "==> 写入 $UNIT"
cat > "$UNIT" <<'EOF'
[Unit]
Description=Recreate NVIDIA GPU device nodes at boot if missing (udev stale workaround)
After=systemd-udevd.service local-fs.target
Before=docker.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/recreate-gpu-nodes.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

echo "==> 注册并立即执行一次"
systemctl daemon-reload
systemctl enable --now gpu-nodes.service

echo "==> 本次执行结果："
systemctl status gpu-nodes.service --no-pager || true

echo "==> 完成。开机时仅当节点缺失才重建；手动 make up / make up-uncensored 即可用 GPU"
