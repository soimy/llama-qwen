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
sudo bash scripts/fix-driver-manual.sh --cdi      # 仅刷新 CDI 规格（容器里 CUDA 失败时先试这个，见 §3.5）
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

## 3.5 排查：容器 healthy 但显存不涨（llama.cpp 静默回落 CPU）

2026-09-16 实机案例：`make up-uncensored` 后容器 `Up (healthy)`、端口正常、容器内 `nvidia-smi`
也能看到 3090，但**显存纹丝不动**（只剩 ~1 GB 桌面基线），生成速度 ~10 tok/s（CPU 速度）。

**看日志**（这是唯一的表征，极易漏）：
```bash
docker logs qwen-llama-uncensored 2>&1 | head -3
#   E ggml_cuda_init: failed to initialize CUDA: unknown error
#   warning: no usable GPU found, --gpu-layers option will be ignored   ← -ngl 99 被丢弃
```

**根因**：`/etc/cdi/nvidia.yaml`（nvidia-container-toolkit 的 CDI 规格）里写死了
`/dev/nvidia-uvm` 的 `major`，而该主设备号由内核**每次加载 nvidia_uvm 时动态分配**——本次开机
从 237 变成 238（237 现在是 nvme）。容器因此拿到「假 uvm 设备」，`cuInit` 失败 → 回落 CPU。
宿主机的 `/dev/nvidia*` 反而是好的。
> 别在 dsh-tui 沙箱里用宿主机 `nvidia-smi` 做判断：沙箱屏蔽 `/dev`，会假报「无法与驱动通信」
> （见 §0 注）；要判断就进容器判断。

**修**：
```bash
sudo nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml   # 等价：sudo bash scripts/fix-driver-manual.sh --cdi
make down && make up-uncensored                              # 新预检会核对显存，不再靠肉眼
```

**防复发**：`make install-gpu-nodes` 装的开机 oneshot 服务现在做两件事——节点缺失就
`udevadm trigger` 重建；CDI 规格里 uvm 主设备号与 `/proc/devices` 不一致就重新生成。

**自查三步**：
```bash
docker run --rm --gpus all --entrypoint sh <镜像> -c 'ls -l /dev/nvidia-uvm'   # 应 == /proc/devices 里 nvidia-uvm 的主设备号
docker exec <容器> nvidia-smi --query-compute-apps=pid,process_name,used_memory --format=csv  # 应有 llama-server 的大块占用
docker logs <容器> 2>&1 | grep -E 'no usable GPU|CUDA'
```
`make up` / `make up-uncensored` 现在自动跑 `scripts/require-gpu.sh`：起容器前用一次性容器实测
CUDA，起容器后核对显存里有没有 llama-server，失败就直接停掉容器并打印修法。
（`REQUIRE_GPU_WAIT=0` 只做早期把关；`REQUIRE_GPU_KEEP=1` 失败时保留容器。）
> 注意：llama.cpp 这个 build **成功时不打任何 CUDA 日志行**，所以「有没有上卡」只能看显存/进程，
> 不能靠 grep 日志。

## 4. 备用模型：orcarouter/Qwen3.8-27B-Uncensored-GGUF（uncensored / abliterated）

本仓库参照现有 `llama` 服务，另加了 `llama-uncensored` 服务：同一 llama.cpp CUDA 镜像，
权重用 orcarouter 的 `Qwen3.8-27B-Uncensored-Q4_K_M.gguf`（~15.6 GB）+ 自带视觉塔
`mmproj-Qwen3.8-27B-Uncensored-f16.gguf`，监听 **8081**。默认量化档同主模型为 Q4_K_M，
KV 策略（`q4_0`）、`-ngl 99`、线程数均与主模型一致（变量名带 `_UNCENSORED` 后缀，可单独调）。

- ⚠️ RTX 3090 只有 24 GB，**两套 27B Q4 权重不能同时常驻**，二选一运行。该服务用 compose
  `profile: uncensored` 隔离——平时的 `make up` / `scripts/deploy-host.sh` **不会**把它拉起，
  也不会误占显存。
- 下载权重：
  ```bash
  make download-uncensored      # 拉 orcarouter Q4_K_M + 其 mmproj 到 ./models
  ```
- 切换运行（先停旧、再启新）：
  ```bash
  make down && make up-uncensored
  # 等价：docker compose --profile uncensored up -d llama-uncensored openwebui searxng
  make down-uncensored          # 只停 uncensored（保留主模型栈）
  ```
- 在 Open WebUI 使用：Settings → Connections → 「+」新增连接
  `URL: http://llama-uncensored:8080/v1`，`API Key` 填 `LLAMA_API_KEY`，然后聊天框模型下拉选
  `qwen3.8-27b`（别名，见第 5 节；注意**两个模型共用这个名字**，所以下拉里看到的不再是
  `...Uncensored...`，要确认跑的是哪个请看 `make ps` 或 `nvidia-smi`。默认主连接
  `http://llama:8080/v1` 在主模型停掉时会显示 offline，可忽略或删除）。
- ⚠️ **连接地址必须用 compose 服务名 `llama-uncensored:8080`，不能填 `localhost:8081`。**
  Open WebUI 的请求是**从它自己的容器里**发出的，容器内的 `localhost` 指的是它自己，
  填 `localhost:8081` 必然连不上（实测：容器内访问 `http://llama-uncensored:8080/v1/models`
  返回 `HTTP 200`，`http://localhost:8081/v1/models` 返回 `HTTP 000`）。
  `http://localhost:8081/v1` 只适用于**从宿主机**直连（浏览器、`curl`、其他本地客户端）。
- 想更省显存/更快可把 `MODEL_FILE_UNCENSORED` 换成 `Qwen3.8-27B-Uncensored-IQ4_XS.gguf`（~14.3 GB）。

## 5. 对外模型名与 API 协议（外部 harness 接入）

llama-server 默认拿**权重文件路径**当模型名对外暴露（`/models/Qwen3.8-27B-UD-Q4_K_M.gguf`），
外部 harness 每次都要填这一长串。compose 里已加 `-a/--alias`，把它收敛成短名：

| 服务 | 对外模型名（`.env` 变量） | 宿主端口 |
|---|---|---|
| `llama`（主模型） | `qwen3.8-27b`（`MODEL_ALIAS`） | 8080 |
| `llama-uncensored` | `qwen3.8-27b` + `qwen3.8-27b-uncensored`（`MODEL_ALIAS_UNCENSORED`） | 8081 |

- **两个模型故意共用 `qwen3.8-27b`**：24 GB 只能同时跑一个，共用短名后切换模型时外部 harness
  配置一个字都不用改（照旧 `make down && make up-uncensored`）；uncensored 额外挂一个区分用别名。
- `--alias` 支持**逗号分隔的多个别名**，在 `.env` 里一行可改，改完重新 `make up(-uncensored)` 生效。
- ⚠️ 实测 llama.cpp 的单模型服务**完全忽略请求体里的 `model` 字段**（填旧全路径、甚至乱填都返回
  `200`），所以别名只影响 `/v1/models` 的对外可读性、不影响路由——旧名字继续可用，改配置无中断风险。

**OpenAI Responses 协议**：本 build（`b10853`）已内建 `POST /v1/responses`，无需任何开关，
chat 与 responses 两种协议同时可用：

```bash
curl -s localhost:8081/v1/responses -H "Authorization: Bearer $LLAMA_API_KEY" \
  -H 'Content-Type: application/json' \
  -d '{"model":"qwen3.8-27b","input":"你好","max_output_tokens":64}'
```

返回标准 `object: "response"` 结构（`output` 里区分 `reasoning` / `message`，并带 `usage` 计数）。
dsh 侧把 provider 的 `api:` 由 `openai-completions` 换成 `openai-responses` 已实测跑通
（dsh 支持的协议取值：`openai-completions` / `openai-responses` / `anthropic-messages`）。

## 6. Qwen3.8-Flash-Next 可行性（2026-09-08 评估）

官方 llama.cpp 镜像（build ≥ b10660）已支持 `qwen4exp`，本机**能跑但不算舒适**：最小权重 70 GB，其中 28.8 GB 的 n-gram 表可 mmap 在 SSD 上不常驻；真正需常驻的约 41~56 GB，超出 24 GB 显存 + 31 GB 内存的舒适区，需要把 30~40 GB 权重交给 SSD、并把系统内存腾出来。对标单卡 3090 + 32 GB 内存实测 27 tok/s，本机预计 15~25 tok/s（现有 27B 为 40~70 tok/s）。完整数据、推荐量化与 compose 配置见 [`docs/FLASH-NEXT.md`](./docs/FLASH-NEXT.md)。
