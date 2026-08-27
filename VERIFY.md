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

## dsh 接入本机 Qwen（2026-08-21, 已完成并验证）
- **供应商**：`~/.dsh/settings.yaml → llm-pi-ai.providers.local`（route=`local`）
  - `baseURL: http://localhost:8080/v1`、`api: openai-completions`、`apiKeyEnv: LOCAL_API_KEY`
  - 模型：`Qwen3.8-27B-UD-Q4_K_M.gguf`，`contextWindow/maxTokens: 131072`
  - reasoningEfforts：`off: none / low: low / medium: medium / high: xhigh`（见下方值域陷阱）
- **凭据**：`~/.dsh/.credentials.yaml`（0600）加 `LOCAL_API_KEY: <你的 LLAMA_API_KEY，与 .env 同值>`
- **端到端验证**：`dsh --profile headless "..."` 走 local 供应商成功返回（reasoningEffort=medium），`Config` schema 校验通过；测试后 `agent-default-model` 已恢复为 shanhe 默认。
- **dsh 推理强度（reasoningEfforts）值域陷阱**：
  - llm-pi-ai 要求键（档位）∈ THINKING_LEVELS（off/minimal/low/medium/high/xhigh/max），值（wire）= 非空字符串（`off` 可用 null/空）。
  - wire 值会透传为 llama 的 `reasoning_effort`；**当前两个 GGUF（UD 与 Uncensored）的 qwen35 模板实测只支持 none / low / medium / xhigh，`high` 会返回 HTTP 500**（jinja `Unexpected reasoning effort high. Supported types are xhigh (default), medium, and low.`）。故 `local` 供应商把 `high`、`max` 两档 wire 值都映射为 `xhigh`（2026-08-26 修正；早先 8-21 记录的值域以当时的模板为准）。
