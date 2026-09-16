#!/usr/bin/env bash
# 以 root 运行：安装一个 oneshot systemd 服务，每次开机自愈「容器拿不到 GPU」的两大根因：
#   1) /dev/nvidia* 设备节点缺失（udev 陈旧，本机反复出现的现象）
#   2) /etc/cdi/nvidia.yaml 里的 nvidia-uvm 主设备号过期（内核每次开机动态分配，实测 237 → 238）
# 两者都会让 llama.cpp 静默回落 CPU（容器却 healthy、显存不涨），详见 scripts/require-gpu.sh 注释。
# 幂等：节点齐全、CDI 规格一致时什么都不做。
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
else
  echo "==> 重建 /dev/nvidia* 节点 (udevadm trigger)..."
  udevadm trigger --action=add --subsystem-match=drm --subsystem-match=platform
  udevadm trigger --type=devices --action=add --subsystem-match=char
  udevadm settle
  systemctl try-restart nvidia-persistenced || true

  echo "==> 核对："
  ls -l /dev/nvidia* 2>/dev/null \
    || { echo "!! 仍有节点缺失，请手动执行: sudo bash scripts/fix-driver-manual.sh"; exit 1; }
fi

# --- CDI 规格校验（2026-09-16 实机根因，节点齐全也可能中招）------------------------
# nvidia-container-toolkit 靠 /etc/cdi/nvidia.yaml 决定往容器注入哪些设备，规格里写死了
# major:minor；而 nvidia-uvm 的主设备号是内核每次加载模块时动态分配的（实测 237 → 238）。
# 规格过期时的表现极具迷惑性：容器 healthy、容器内 nvidia-smi 正常，但 llama.cpp 静默回落
# CPU、显存不涨。所以每次开机都比对一次，不一致就重新生成。
SPEC=/etc/cdi/nvidia.yaml
want="$(awk '$2=="nvidia-uvm"{print $1}' /proc/devices)"
have="$(sed -n '/path: \/dev\/nvidia-uvm$/{n;s/.*major: *//p;q}' "$SPEC" 2>/dev/null)"
if [ -z "$want" ]; then
  echo "内核未注册 nvidia-uvm（驱动没加载？），跳过 CDI 规格校验。"
elif [ "$want" = "$have" ]; then
  echo "CDI 规格 uvm 主设备号一致（$have），无需刷新。"
else
  echo "==> CDI 规格过期：规格里 uvm major=${have:-缺失}，内核当前 $want → 重新生成..."
  nvidia-ctk cdi generate --output="$SPEC" \
    || { echo "!! CDI 规格生成失败，容器可能拿不到 GPU（make up-uncensored 的预检会拦下）"; exit 1; }
fi
EOF
chmod 755 "$HELPER"

echo "==> 写入 $UNIT"
cat > "$UNIT" <<'EOF'
[Unit]
Description=Self-heal NVIDIA GPU access for containers at boot (device nodes + CDI spec)
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

echo "==> 完成。开机自动：节点缺失就重建、CDI 规格过期就重生成；手动 make up / make up-uncensored 即可用 GPU"
