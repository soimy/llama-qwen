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
