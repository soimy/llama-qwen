# 本地部署 Qwen3.8-27B（RTX 3090 + llama.cpp + 视觉 + 本地联网搜索）

本仓库用 Docker Compose 在 **RTX 3090（24 GB）** 上以 llama.cpp 运行 Qwen3.8-27B：
权重 `Q4_K_M` 全量上 GPU（`-ngl 99`），KV 缓存 `q4_0`（`-ctk/-ctv q4_0`）以最大化上下文，
叠加 **视觉**（`--mmproj`）与 **本地联网搜索**（SearXNG + Open WebUI Web Search，无第三方 Key）。

## 0. 前置：NVIDIA 驱动（已确认可用 ✅）
2026-08-21 已在宿主机实机验证：`nvidia-smi` 显示 **RTX 3090 / 24576 MiB**（驱动 610.57.04，
CUDA 13.3），`/dev/nvidia*` 与 `/dev/dri/*` 节点齐全，Docker `--gpus all` 容器内同样可见 3090。
本环境驱动**无需再修**（注意：若之前在 dsh-tui 沙箱里 `nvidia-smi` 报「无法通信」是沙箱 CapEff=0
+ 只读 `/dev` 所致，非真实宿主机状态）。
若换真实环境后 `nvidia-smi` 报错、节点缺失，以 root 跑固化脚本（详见 `HANDOFF.md` 第 3 节）：
```bash
sudo bash scripts/fix-driver-manual.sh            # 全流程
sudo bash scripts/fix-driver-manual.sh --nodes    # 仅重建 /dev/nvidia* 节点
# 或宿主机 TTY 手动执行（A）后验证：
udevadm trigger --action=add --subsystem-match=drm --subsystem-match=platform
udevadm trigger --type=devices --action=add --subsystem-match=char
udevadm settle && nvidia-smi
```
随后安装 Docker + GPU 接入：
```bash
pacman -S --noconfirm docker nvidia-container-toolkit
nvidia-ctk runtime configure --runtime=docker
systemctl enable --now docker
docker run --rm --gpus all nvidia/cuda:12.6.3-base-ubuntu24.04 nvidia-smi   # 容器内可见 3090
```
> 注：`udevadm trigger -p 'nvidia*'` 非法（-p 需 `PROPERTY=VALUE`）；冥号 `nvidia/cuda:12.4.0-base-ubuntu24.04`
> 不存在（24.04 自 12.4.1 起才有），用 `12.6.3-base-ubuntu24.04`（实测通过）。

## 0.5 在 dsh-tui 里以 root 提权（sudd）

dsh-tui 里每条 bash 都在**无 TTY、无 stdin、全新 shell**中执行，裸 `sudo` 会报
`sudo: a password is required`（无法输入密码）。仓库提供 `sudd` 系列工具，把密码
问询弹到你的桌面或终端上：

| 工具 | 场景 | 说明 |
|------|------|------|
| `sudd <cmd>` | **默认（本机 GUI）** | 桌面上弹 zenity 对话框输入 sudo 密码；15 分钟内再 `sudd` 不再弹框 |
| `sudd-text <cmd>` | SSH / 无 GUI 终端 | 用 systemd-ask-password 把问询交给终端里的密码代理 |
| `sudd-noninteractive <cmd>` | 脚本化自动执行 | 从 `SUDO_PASS`/`SUDO_PASS_FILE` 读取密码（`sudo -S`） |
| `sudd -k` | 管理 | 立即清除 sudo 凭据缓存，下次再弹框 |

示例（在 dsh-tui 中直接执行）：
```bash
# 方式一：图形弹框（推荐，桌面会弹出密码框）
sudd pacman -S --noconfirm docker nvidia-container-toolkit
sudd systemctl enable --now docker
sudd docker run --rm --gpus all nvidia/cuda:12.6.3-base-ubuntu24.04 nvidia-smi

# 方式二：整段以 root 跑
sudd bash scripts/setup-docker.sh
```
脚本位于 `scripts/`（`sudo-askpass.sh` / `sudd` / `sudo-askpass-text.sh` / `sudd-text` /
`sudd-noninteractive`），`sudd*` 已符号链接到 `~/.local/bin`（在 `PATH` 上）。
依赖 GUI 弹框需 `zenity`（CachyOS：`pacman -S zenity`）。

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
