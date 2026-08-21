# 本地部署 Qwen3.8-27B（RTX 3090 + llama.cpp + 视觉 + 本地联网搜索）

本仓库用 Docker Compose 在 **RTX 3090（24 GB）** 上以 llama.cpp 运行 Qwen3.8-27B：
权重 `Q4_K_M` 全量上 GPU（`-ngl 99`），KV 缓存 `q4_0`（`-ctk/-ctv q4_0`）以最大化上下文，
叠加 **视觉**（`--mmproj`）与 **本地联网搜索**（SearXNG + Open WebUI Web Search，无第三方 Key）。

## 0. 前置：NVIDIA 驱动（已确认可用）
截至 2026-08-21，`nvidia-smi` 已正常显示 RTX 3090（24 GB，驱动 610.57.04，CUDA 13.3），
`/dev/nvidia*` 设备节点齐全，**无需再修驱动**。若换环境后 `nvidia-smi` 报错、节点缺失，
以 root 执行（详见 `HANDOFF.md` 第 3 节）：
```bash
systemctl start nvidia-persistenced
udevadm trigger --action=add --subsystem-match=drm --subsystem-match=platform
udevadm trigger --action=add -p "nvidia*"
udevadm settle
nvidia-smi            # 应显示 3090 / 24GB
# 若仍缺节点：pacman -S --noconfirm linux-cachyos-nvidia-open nvidia-utils opencl-nvidia && mkinitcpio -P && reboot
```
随后安装 Docker + GPU 接入：
```bash
pacman -S --noconfirm docker nvidia-container-toolkit
nvidia-ctk runtime configure --runtime=docker
systemctl enable --now docker
docker run --rm --gpus all nvidia/cuda:12.4.0-base-ubuntu24.04 nvidia-smi   # 容器内可见 3090
```

## 1. 快速开始
```bash
cp .env.example .env
make download        # 拉取 unsloth Qwen3.8-27B-GGUF 的 Q4_K_M 权重 + mmproj-F16.gguf 到 ./models
make up              # 启动 llama.cpp(CUDA) + Open WebUI + SearXNG
```
浏览器打开 `http://localhost:3000` → 注册管理员 → Settings → Connections 确认
`http://llama:8080/v1` 已连 → 聊天框开启「Web Search」即可联网。上传图片即触发视觉。

## 2. 量化 / 显存要点（RTX 3090 = 24 GB）
- 默认 `Q4_K_M(~16.5GB) + KV q4_0 + 262144` ≈ **20.5 GB < 24 GB**，舒适。
- 激进 `IQ4_XS + KV q4_0 + 524288` ≈ 22.5 GB，仍 < 24 GB。
- 1M 上下文（YaRN）KV 溢写系统内存，变慢；默认 256K–512K。

## 3. 验证
1. `nvidia-smi` 显示 3090 / 24 GB。
2. `curl localhost:8080/v1/models` 返回 `Qwen3.8-27B`；显存 ~20 GB。
3. Open WebUI 上传图片可描述；开 Web Search 问实时问题有引用。

详见 [`HANDOFF.md`](./HANDOFF.md)（完整决策、风险与回退方案）。
