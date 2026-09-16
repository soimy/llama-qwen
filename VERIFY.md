# 部署验证记录

## GGUF 元数据核验（2026-08-21, 沙箱内解析）
- 文件: models/Qwen3.8-27B-UD-Q4_K_M.gguf (16,464,440,224 B, 与 HF API 一致)
- 魔数: GGUF v3, tensors=866
- **架构键 = `qwen35`**（llama.cpp 内部名；HANDOFF 文档写 `qwen3_5` 为架构族名，GGUF 实际键为 `qwen35`）
- block_count=65 (64 层 + 1?), full_attention_interval=4, context_length=262144
- head_count=24, head_count_kv=4, key/value length=256, ssm state_size=128
- base_model=Qwen3.8-27B (unsloth)
- mmproj-F16.gguf: GGUF v3, 有效

## 架构可加载性实测（2026-08-21, 沙箱 CPU 构建 + 加载）
- 浅克隆上游 llama.cpp master (head `1719747`)，CPU 构建 llama-cli/llama-server 成功（gcc 16.2 / cmake 4.4 / 12 线程）。
- 源码确认：`src/llama-arch.h` 含 `LLM_ARCH_QWEN35`，`src/models/qwen35.cpp` 含完整实现（含 `build_layer_attn_linear` 线性注意力）。
- 实测加载 `Q4_K_M.gguf`（`-ngl 0` 纯 CPU，`-c 512`）成功：
  ```
  build      : b1-1719747
  model      : models/Qwen3.8-27B-UD-Q4_K_M.gguf
  ftype      : Q4_K - Medium
  modalities : text
  ```
  → `qwen35` 架构被识别、866 张量加载、可生成（Prompt 4.8 t/s / Gen 2.0 t/s，CPU 慢属正常）。
- **结论：排除「未知架构」风险**——只要官方 `ghcr.io/ggml-org/llama.cpp:server-cuda` 镜像打包的 llama.cpp 不低于 b1-1719747（含 qwen35），即可加载。
- 注：无 TTY 下 llama-cli 交互渲染会刷大量 `>` 行，属显示噪声非故障。

## 待宿主执行的最后一步
`bash scripts/deploy-host.sh` → docker compose up + /v1/models 验证 (沙箱无 docker daemon 访问权)

## KV offload A/B 实测（2026-08-21, 宿主 docker `scripts/kv-ab-test.sh`）
| 用例 | 配置 | prompt t/s | gen t/s | GPU used (MiB) |
|---|---|---|---|---|
| A | KV在GPU, 128k | 1093.0 | **42.24** | 21027 |
| B1 | offload, 128k | 652.1 | 13.87 | 18277 |
| B2 | offload, 256k | 648.9 | 13.77 | 19063 |
| (参考) | KV在GPU, 256k | — | 36.5 | ~23900 |

**结论（已采纳）：方案 A —— KV 留 GPU（不用 `-nkvo`）+ 上下文 128k（`CTX_SIZE=131072`）**
- offload 使本机生成吞吐 -67%（42→13.8 tok/s），仅省 ~2.7G 显存，性价比低 → 不开。
- 崩溃根因是「KV在GPU+256k」把显存顶到 23.9G、只剩 0.1G；改 A 后显存 21.0G、桌面留 ~3.5G，不崩且最快。
- 若必须 256k 上下文 → 只能 B2（offload, 256k, 13.8 tok/s, 留 5.5G）。

## 视觉 + 联网搜索验证（2026-08-21, 实机）
**视觉 ✅**（mmproj 挂载, OpenAI 兼容多模态接口）：
- 生成 256x64 测试图（左红块 + 右蓝块 + 文字）→ 模型正确回答「Left: Red / Right: Blue / 文字 RED LEFT, BLUE RIGHT」，gen ≈ 37.9 t/s。

**联网搜索 ✅**：
- SearXNG（compose 内网 172.18.0.2:8080, 未发布宿主端口）JSON 接口实测 `?q=RTX 3090 24GB&format=json` 返回 **20 条真实结果**（amazon/ebay/nvidia/techpowerup）。
- 出站连通：DuckDuckGo / Google / Brave 均 HTTP 200。
- Open WebUI（3000, v0.11.0）+ llama（8080）+ searxng（内网）三容器运行正常互达；`WEBUI_SEARCH_ENGINE=searxng` / `SEARXNG_QUERY_URL=http://searxng:8080/search?...` env 已在 compose 配置（受鉴权 API 未深查，但链路已通）。
- 注：SearXNG 未发布宿主端口（HANDOFF 设计如此防滥用），Open WebUI 经容器内网 `searxng:8080` 访问。

## dsh 接入本机 Qwen（2026-08-21 建立；2026-09-14 改为短别名 + responses 协议）
- **供应商**：`~/.dsh/settings.yaml → llm-pi-ai.providers` 下两个 route
  - `local` → `http://localhost:8080/v1`（主模型）；`local-uncensored` → `http://localhost:8081/v1`（uncensored）
  - 两者均为 `api: openai-responses`、`apiKeyEnv: LOCAL_API_KEY`
  - **模型 id 统一为 `qwen3.8-27b`**（llama-server `--alias` 提供，见 README 第 5 节）：两个模型共用
    同一短名，切换模型时 dsh 配置无需改动。此前填的是权重全名（`Qwen3.8-27B-UD-Q4_K_M.gguf` /
    `Qwen3.8-27B-Uncensored-Q4_K_M.gguf`），过于冗长。
  - `contextWindow/maxTokens: 131072`；reasoningEfforts：`off: none / low: low / medium: medium / high: xhigh`（见下方值域陷阱）
- **凭据**：`~/.dsh/.credentials.yaml`（0600）加 `LOCAL_API_KEY: <你的 LLAMA_API_KEY，与 .env 同值>`
- **端到端验证**（2026-09-14）：把 `agent-default-model` 临时指向 `local-uncensored` 后
  `dsh --profile headless "只回答两个字：收到"` 成功返回（reasoning 走 stderr、正文正确），
  证明 `openai-responses` 协议 + `qwen3.8-27b` 别名链路通畅；测试后 `agent-default-model`
  已还原为 `deepseek-official / deepseek-v4.1-flash-expires-on-0910`。
- **dsh 推理强度（reasoningEfforts）值域陷阱**：
  - llm-pi-ai 要求键（档位）∈ THINKING_LEVELS（off/minimal/low/medium/high/xhigh/max），值（wire）= 非空字符串（`off` 可用 null/空）。
  - wire 值会透传为 llama 的 `reasoning_effort`；**当前两个 GGUF（UD 与 Uncensored）的 qwen35 模板实测只支持 none / low / medium / xhigh，`high` 会返回 HTTP 500**（jinja `Unexpected reasoning effort high. Supported types are xhigh (default), medium, and low.`）。故 `local` 供应商把 `high`、`max` 两档 wire 值都映射为 `xhigh`（2026-08-26 修正；早先 8-21 记录的值域以当时的模板为准）。

## 容器 CUDA 静默回落排查（2026-09-16，`make up-uncensored` 显存不涨）

**现象**：`qwen-llama-uncensored` Up (healthy)、8081 可访问，但显存只有 ~1.1 GB（桌面基线）、
生成 ~10 tok/s。日志头两行是唯一线索：
`E ggml_cuda_init: failed to initialize CUDA: unknown error` +
`warning: no usable GPU found, --gpu-layers option will be ignored`（`-ngl 99` 被丢弃，27B 跑在系统内存里）。

**根因**：`/etc/cdi/nvidia.yaml`（生成于 2026-09-09 12:26）把 `/dev/nvidia-uvm` 写死 `major: 237`
且不含任何 `/dev/nvidia-caps/*`；而本次开机内核给 nvidia-uvm 分配的是 **238**（237 现在是 nvme）。
容器因此拿到假 uvm 设备（`--gpus all` 实测容器内为 `crw-rw-rw- 237, 0 /dev/nvidia-uvm`，strace：
`openat("/dev/nvidia-uvm", O_RDWR|O_CLOEXEC) = -1 EPERM`）→ cuInit 失败 → CPU 回落。
**宿主机 `/dev` 本身是好的**：`-v /dev:/hostdev` 实测 195:0 / 195:255 / 195:254 / 238:0 / 238:1 /
241:1,2 全齐。教训：dsh-tui 沙箱屏蔽 `/dev`，裸跑宿主机 `nvidia-smi` 会假报「无法与驱动通信」，
判断 GPU 一律进容器判断。

**修复与验证（实机通过）**：
1. `nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml`（旧规格备份为 `nvidia.yaml.stale-20260916-*`），
   新规格 `/dev/nvidia-uvm` = `major: 238` / `nvidia-uvm-tools` = `238:1`。
2. stock 容器（不加任何额外挂载）两条路径都能列出 GPU：
   `docker run --rm --gpus all … --list-devices` 与 `docker run --rm --runtime=nvidia …` → `CUDA0: RTX 3090 (24089 MiB, ~22.7 GB free)`。
3. `make down && make up-uncensored` → 预检打印 `1, /app/llama-server, 20976 MiB` / `✓ 显存占用 22205 MiB`；
   `curl localhost:8081/v1/chat/completions` 正常出 token（reasoning 走 reasoning_content）。
4. 反证：把旧规格装回后，非特权容器里 CUDA 必失败（`--privileged` 才通），说明与驱动无关、就是注入的设备错。

**防复发**：新增 `scripts/require-gpu.sh`（`make up` / `make up-uncensored` 起容器前后自动跑，
失败即停容器并打印修法）；`fix-driver-manual.sh --cdi`；`install-gpu-nodes-service.sh` 的开机
oneshot 服务现在同时校验 CDI 规格的 uvm 主设备号，不一致就重生成。
注：llama.cpp b10853 **成功时不打任何 CUDA 日志行**，所以「有没有上卡」只能看显存/进程，不能 grep 日志。
