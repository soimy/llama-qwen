# MTP（Multi-Token Prediction）优化落地 + A/B 实测

- 日期：2026-08-26
- 机型：RTX 3090 24GB（build 10548 镜像，`ghcr.io/ggml-org/llama.cpp:server-cuda`）
- 模型：`Qwen3.8-27B-UD-Q4_K_M.gguf` + `mmproj-F16.gguf`，`-c 131072 -ctk/-ctv q4_0 -ngl 99`
- 结论：**开启 MTP 自举投机解码后，解码吞吐 +68%~+74%，显存仅多 ~0.7GB，无需新文件、不改权重**

---

## 1. 背景：MTP 是什么、为什么本项目适用

- **MTP = Multi-Token Prediction（多 token 预测）**：模型训练时同时预测未来 N 个 token（Qwen 官方称 nextn head）。
- 推理期用法 = **自举投机解码（self-speculative decoding）**：模型自带的 MTP 头廉价“草稿”出后面几个 token，主模型并行一次校验；接受率高则一次前向多吐 token。
- 不需要外部小语言模型（传统投机解码要另下载 draft GGUF）；**Qwen3.8 的 unsloth GGUF 里本来就带 `blk.*.nextn.*` 张量**，llama.cpp 默认加载但不开 flag 就忽略（当前镜像 `--spec-type` 支持 `draft-mtp`，版本 build 10548）。
- 本仓库两个 GGUF（主模型 + uncensored）都实测含 `mtp`/`mtph` 张量，故两个服务都可开启。

## 2. 改动

`docker-compose.yml`：`llama` 与 `llama-uncensored` 两个服务的 command 在 `-ngl` 后追加：

```yaml
      # MTP self-speculative decoding（Qwen3.8 GGUF 自带 nextn head，n-max 2 为 24GB 卡甜点）
      - "--spec-type"
      - "draft-mtp"
      - "--spec-draft-n-max"
      - "2"
      - "--parallel"
      - "1"
```

参数依据（社区在 3090 上的实测）：
- `n-max 2` 是 24GB 卡的甜点（社区规则 1）；更深草稿在带宽更高的卡上才划算。
- 不加 `--spec-draft-p-min`：置信度门槛帮带宽吃紧的卡、伤快速卡，3090 属于后者。
- `--parallel 1`：投机解码是单流优化，多并发优势消失；本仓库为单人 WebUI 使用，天然单流。

另新增两个工具脚本：
- `scripts/probe-mtp.py`：来自社区仓库的流式测速脚本（定了官方方法：3 prompt × 3 轮、关 thinking），本机加了 `Authorization: Bearer $LLAMA_API_KEY` 支持。
- `scripts/dg.sh`：以 docker 组上下文在 bash 下跑命令的小工具（因用户刚加入 docker 组、当前会话组未刷新，用 `newgrp` 且规避其默认 fish shell）。

## 3. A/B 实测（同镜像、同配置，仅增减上述 spec flags）

方法：官方 `probe-mtp.py`（warmup + 3 prompts × 3 runs，每 run 400 token，thinking off）。

| 指标 | A：baseline（无 MTP） | B：MTP on | 提升 |
|---|---|---|---|
| 总体 median（tok/s） | 39.5 | **68.8** | **+74%** |
| 总体 mean（tok/s） | 39.6 | **66.7** | **+68%** |
| Python prompt | 39.5 | 76.6 | +94% |
| Prose prompt | 39.9 | 55.2 | +38% |
| Bash prompt | 39.4 | 68.8 | +75% |
| 显存占用 | 21,340 MiB | 22,022 MiB | +682 MiB（24 GB 预留充裕） |
| draft acceptance | — | **0.795**（1677/2109） | 与社区 3090 的 0.78 一致 |

分 prompt 的形态也符合社区规律：**代码类收益最大，散文类最小**（但本机仍为正）。服务端自身 `eval time` 报 67–71 tok/s，与外部 probe 一致，排除测量假象。

## 4. 注意与回退

- **短输出收益小**：生成显著低于 ~400 token 时草稿开销可能反噬；本仓库是长文/agent/联网搜索场景，恰好吃满收益。
- **单流假设**：`--parallel` 升至 2 起收益递减、到 4 基本消失；若日后频繁多并发，需重测取舍。
- **先拉新镜像再评估**：upstream 持续优化，新 build 本身也有收益；若要更激进可顺带加 `-fa 1`（flash attention，本项目当前未开）。
- 想关掉：从 compose 里删掉上面 3 组 flag，`docker compose up -d llama` 即可。
- uncensored 服务本次为让位显存处于停止态；需要时 `make up-uncensored`（会先要停主栈）。

## 5. 参考

- llama.cpp draft-mtp 支持: https://github.com/ggml-org/llama.cpp/pull/22673
- Qwen3.8-27B MTP 社区实测（含多档 3090 数据）: https://github.com/sudoingX/qwen38-mtp
- 单卡 24GB 同款模型先例: https://github.com/hanxiao/Qwen3.8-27B-UD-Q4_K_XL-L4
- 模型: https://huggingface.co/unsloth/Qwen3.8-27B-GGUF

原始输出：`docs/mtp-ab/MTP-AB-baseline.txt`、`docs/mtp-ab/MTP-AB-mtp.txt`。
