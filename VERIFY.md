# 部署验证记录

## GGUF 元数据核验（2026-08-21, 沙箱内解析）
- 文件: models/Qwen3.8-27B-UD-Q4_K_M.gguf (16,464,440,224 B, 与 HF API 一致)
- 魔数: GGUF v3, tensors=866
- **架构键 = `qwen35`**（llama.cpp 内部名；HANDOFF 文档写 `qwen3_5` 为架构族名，GGUF 实际键为 `qwen35`）
- block_count=65 (64 层 + 1?), full_attention_interval=4, context_length=262144
- head_count=24, head_count_kv=4, key/value length=256, ssm state_size=128
- base_model=Qwen3.8-27B (unsloth)
- mmproj-F16.gguf: GGUF v3, 有效

## 待宿主执行的最后一步
`bash scripts/deploy-host.sh` → docker compose up + /v1/models 验证 (沙箱无 docker daemon 访问权)
