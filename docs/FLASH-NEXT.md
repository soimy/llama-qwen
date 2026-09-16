# 本机部署 Qwen3.8-Flash-Next 可行性分析（RTX 3090 24GB + 31GB RAM）

- 日期：2026-09-08
- 机型：本机（RTX 3090 24GB / Ryzen 5 5600 6C12T AVX2 / DDR4 31.2GB / LUKS NVMe 386GB 空闲）
- 参照：本仓库已跑通的 Qwen3.8-27B 部署经验（[`README.md`](../README.md) / [`HANDOFF.md`](../HANDOFF.md) / [`docs/MTP.md`](./MTP.md)）
- 一句话结论：**技术上可行（能跑起来，预计 15~25 tok/s），但不建议直接替代现有 27B 主力**——需要把 30~40GB 权重交给 SSD mmap、把桌面内存让出来，主线暂无 MTP、量化档质量有取舍。

---

## 1. 结论速览

| 维度 | 结论 |
|---|---|
| 运行支持 | ✅ **官方 llama.cpp 已支持，无需自编译**。PR [#27742](https://github.com/ggml-org/llama.cpp/pull/27742)（`qwen4exp`）于 2026-08-27 合并；当前 `ghcr.io/ggml-org/llama.cpp:server-cuda` = build **b10853**（2026-09-08）已含该架构 |
| 权重体积 | 最小 70.1GB（bartowski IQ1_S）/ 72.5GB（unsloth UD-IQ1_S）；推荐质量档 IQ4_XS 约 85~94GB |
| 关键结构 | 总权重中 **28.8GB 是 n-gram/PLE 查表**，按行随机访问 → 可 mmap 在 SSD 上，**不需要常驻**。真正需常驻的是「总量 − 28.8GB」 |
| 本机内存 | 24GB VRAM + 31.2GB RAM = 55.2GB（当前 MemAvailable 仅 12.3GB） |
| 磁盘 | 386GB 空闲，装得下 85GB 权重 + 余量 |
| 实测对标 | 单卡 3090 24G + 32G RAM 跑 85GB 的 IQ4_XS → **27 tok/s**、128K 上下文（45.8GB 常驻 + 39.1GB SSD） |
| 本机预期 | **15~25 tok/s**（DDR4 + 6 核弱于对标机；桌面占内存会进一步拉低）。现有 27B 为 40~70 tok/s |
| 主要代价 | ① 需腾出 ~10~20GB 系统内存（或 headless 运行）；② SSD 承载 30~40GB 权重；③ 主线无 MTP，只能靠 `ngram-mod` 投机解码；④ KV 建议 f16（该架构 KV 便宜，q4_0 有 assert 风险） |
| 建议 | 尝鲜/实验可以；生产主力建议 27B 继续本地 + Flash-Next 走 Qwen Cloud API，或先加内存到 64GB |

---

## 2. 模型事实（官方模型卡 + config.json）

| 项 | 值 |
|---|---|
| 架构 | `qwen4_exp` / `Qwen4ExpForConditionalGeneration`（Qwen4 预览） |
| 参数 | **125B 总参 / 6B 激活**，另有 **51B n-gram embedding** 与 **4B MTP** |
| 层结构 | 48 层 = 12 ×（3 × Gated DeltaNet → MoE，1 × Qwen Sparse Attention → MoE） |
| MoE | 512 experts，top-10 路由 + 1 shared，expert 中间维 640 |
| 注意力 | QSA 稀疏注意力：24 Q heads / 2 KV heads / head_dim 256，预算 2048 token |
| 上下文 | 原生 262,144，YaRN 可扩至 1,000,000 |
| 视觉 | 有（Qwen3-VL ViT，`mmproj-F16.gguf` 约 904MB） |
| License | Qwen Community License 1.0（`other`，非 Apache） |
| 官方托管版 | Qwen3.8-Flash（Qwen Cloud），默认 1M 上下文 + 内置工具 |

> 架构细节以 [Qwen/Qwen3.8-Flash-Next](https://huggingface.co/Qwen/Qwen3.8-Flash-Next) 模型卡为准。

---

## 3. 权重构成：70GB 里只有约 41GB 需要常驻

用 HTTP Range 直接解析远端 GGUF 头部（bartowski `IQ1_S`，实测），逐张量归类：

| 组成 | 体积 | 说明 |
|---|---:|---|
| n-gram / PLE 表（`per_layer_token_embd`，51.2B 参数） | **28.81 GB** | 所有量化档都保持 4-bit（Q4_0 / IQ4_NL）；**按行查表**，可 mmap 到 SSD，热行由 page cache 兜底 |
| MoE 路由专家（512 experts，top-10） | **38.63 GB** | 真正吃内存的部分，每 token 需流式读取 |
| attention / Gated DeltaNet | 1.56 GB | 每 token 都要读 |
| shared FFN | 0.39 GB | |
| token_embd + lm_head | 0.65 GB | lm_head 每 token 读一次 |
| 其他 | 0.05 GB | |
| **合计** | **70.09 GB** | 与 HF 文件总大小 70.10GB 吻合 |

**关键推论：常驻需求 = 总量 − 28.8GB。** 这被两个独立来源验证：
- llama.cpp PR #27742 明确 PLE 是 host 侧行索引 + `ggml_get_rows`（不是 matmul），张量用 `TENSOR_READ_LAZY`；
- 4×3090 部署报告实测：82GB 的 UD-IQ3_XXS 只占 ~54GB 显存（82 − 28.8 ≈ 53.2GB）。

### 各量化档的常驻需求

| 量化档 | 总大小 | 需常驻 | 本机（24G VRAM + 31G RAM）判定 |
|---|---:|---:|---|
| REAP-320 Q2（剪枝到 320 experts） | 61.5 GB | 32.7 GB | ✅ 宽松（但知识损失，见 §7） |
| bartowski IQ1_S | 70.1 GB | 41.3 GB | ✅ 需腾内存（当前仅 12.3GB 可用） |
| unsloth UD-IQ1_S | 72.6 GB | 43.8 GB | ⚠️ 紧 |
| IQ2_XXS / UD-Q2_K_XL | 75.2 / 78.9 GB | 46.4 / 50.1 GB | ⚠️ 很紧，RAM 几乎全给模型 |
| **AtomicChat AD-3.84bpw-IQ4_XS-M64** | **84.9 GB** | **56.1 GB** | ⚠️ 超出 ~1~10GB → 部分专家走 SSD（对标机实测 27 tok/s） |
| unsloth UD-IQ4_XS | 93.7 GB | 64.9 GB | ❌ 需 ~10GB 以上走 SSD |
| UD-Q4_K_XL / Q8_0 / BF16 | 111 / 188 / 354 GB | 82.5+ GB | ❌ |

> 常驻容量估算：VRAM 可用 ~21GB（24GB 扣掉 KV/缓冲/桌面合成器）+ RAM 可用（31.2GB − 桌面占用）。当前桌面已占约 19GB（MemAvailable 12.3GB），合计仅 ~33GB；**把桌面内存压到 6GB 以内可换来 ~46GB 常驻容量**，才够 IQ1_S 档。

### KV 缓存不是瓶颈（与 27B 相反）

- 只有 12 层是 full attention（每 4 层 1 层）：2 KV heads × 256 head_dim × K/V × 2 bytes ≈ **24.6 KB/token（f16）**。
  - 128K 上下文 ≈ 3.2GB，256K ≈ 6.3GB；q4_0 则约 0.8 / 1.6GB。
- 36 层 Gated DeltaNet 是常驻循环状态，不随上下文线性增长。
- 结论：**上下文可以放心开到 128K~256K**，显存压力主要来自专家权重而不是 KV（这与 27B 需要 `-ctk/-ctv q4_0` 才敢开 256K 的情况不同）。

---

## 4. 本机资源盘点

| 资源 | 现状 | 对 Flash-Next 的影响 |
|---|---|---|
| GPU | RTX 3090 24GB（SM86，936GB/s） | 全量放不下，必须 VRAM+RAM+SSD 三级 |
| RAM | 31.2GB 总量，当前可用 **12.3GB** | 最大瓶颈：需腾到 ~20GB+ 可用 |
| Swap | 31.2GB swapfile + 31.2GB zram | ⚠️ zram 是内存压缩，模型页被压缩会严重掉速，需禁 swap |
| 磁盘 | LUKS 加密 NVMe（970 EVO Plus 500GB），**386GB 空闲** | 够下载 85GB 权重；LUKS 会略增随机读延迟 |
| CPU | Ryzen 5 5600 6C12T，AVX2（无 AVX-512） | CPU 侧专家计算/带宽弱于对标机（对标机多为 DDR5 + 8 核） |
| 现有服务 | 27B 常驻 ~20GB 显存 | **两套模型不能同时跑**，需先 `make down` |
| 驱动 | 文档记录已修复（610.57.04），但当前内核已变为 7.1.9-arch1-2 | 部署前必须在宿主机 TTY 重新确认 `nvidia-smi` |

---

## 5. 社区实测对标

| 机器 | 量化 | 关键配置 | 解码速度 | 来源 |
|---|---|---|---|---|
| **1×3090 24G + DDR5 32G** | AtomicChat AD-3.84bpw-IQ4_XS-M64（85GB） | 45.8GB 常驻 + 39.1GB SSD mmap，128K，`-ngl 99 -ncmoe 32 -fit off` | **27 tok/s**（GPU 仅 40% 利用率 → 带宽瓶颈） | [linux.do](https://linux.do/t/topic/2818800) |
| 2×3090 + 64GB | UD-IQ4_XS / UD-Q2_K_XL | `-ot per_layer_token_embd=CPU` + 分带专家 offload | 38~40 / **~53 tok/s**，prefill 892 t/s | [ruashots/flashnext-2x3090](https://github.com/ruashots/flashnext-2x3090) |
| 4×3090（96GB） | UD-IQ3_XXS | 全显存，131K 上下文 | ~43 tok/s | [Fleet-Deploy](https://github.com/tonyd2wild/Qwen3.8-Flash-Next-Fleet-Deploy) |
| DGX Spark 128GB | UD-IQ1_S | 统一内存全常驻 | 23~27 tok/s；32K 输入冷启动 TTFT 86s | [DGX 配方](https://github.com/sxuff/qwen38-flash-next-dgx-spark) |
| 1×4090 + 110GB DDR4 | UD-Q4_K_XL（111GB） | 250K 上下文 | ~21 tok/s | [thakicloud](https://thakicloud.com/tech-blog/en/llmops/125b-moe-on-one-4090-what-actually-happened/) |
| REAP-320 Q2 | 61.5GB | 1×RTX 5090 32GB，`--n-cpu-moe 3` | 86.9 tok/s（32GB 卡全常驻） | [REAP-320 模型卡](https://huggingface.co/AnonimousA/Qwen3.8-Flash-Next-REAP-320-GGUF) |
| **本机（推算）** | IQ1_S 或 IQ4_XS-M64 | 24G + 31G，SSD mmap | **15~25 tok/s** | 按上表折算 |

> ⚠️ 时效性：day-0 的 4×3090 报告称「官方镜像不认识 `qwen4exp`，必须自编译」——那是 2026-08-26 的情况，**PR 合并后已过时**；本机用官方镜像即可。

---

## 6. 推荐落地方案（方案 A：先尝鲜）

**量化选择：** `AtomicChat/Qwen3.8-Flash-Next-GGUF` 的 `AD-3.84bpw-IQ4_XS-M64`（28 shards，84.9GB）+ 同仓 `mmproj-Qwen3.8-Flash-Next-F16.gguf`（904MB）。理由：与单卡 3090 成功案例完全一致，质量（IQ4_XS 级）远好于 IQ1_S。

**Compose 新服务**（与现有 `llama` 二选一运行，端口 8082）：

```yaml
  llama-flashnext:
    image: ghcr.io/ggml-org/llama.cpp:server-cuda
    container_name: qwen-flashnext
    runtime: nvidia
    profiles: ["flashnext"]
    volumes:
      - ./models:/models
    ports:
      - "8082:8080"
    deploy:
      resources:
        reservations:
          devices:
            - driver: nvidia
              count: 1
              capabilities: [gpu]
    command:
      - "-m"
      - "/models/flashnext/Qwen3.8-Flash-Next-AD-3.84bpw-IQ4_XS-M64-00001-of-00028.gguf"
      - "--mmproj"
      - "/models/flashnext/mmproj-Qwen3.8-Flash-Next-F16.gguf"
      - "-ngl"
      - "99"
      - "-ncmoe"
      - "32"                      # 前 32 层专家放 CPU（对标机同款）
      - "-ot"
      - "^per_layer_token_embd\\.weight$=CPU"   # n-gram 表留 CPU/SSD
      - "-c"
      - "131072"
      - "-np"
      - "1"
      - "-b"
      - "1024"
      - "-ub"
      - "256"
      - "-fa"
      - "on"
      - "-ctk"
      - "f16"
      - "-ctv"
      - "f16"                     # 该架构 KV 便宜；q4_0 有 assert 风险
      - "--jinja"
      - "-fit"
      - "off"                     # 3090 上 -fit on 会崩（主线默认也是 off）
      - "-lzm"
      - "on"                      # 懒加载，加载时间 45s → 20s
      # 无 MTP（主线未支持 qwen4exp），用无草稿 ngram 投机解码
      - "--spec-type"
      - "ngram-mod"
      - "--spec-ngram-mod-n-match"
      - "24"
      - "--spec-ngram-mod-n-min"
      - "48"
      - "--spec-ngram-mod-n-max"
      - "64"
      - "-t"
      - "12"
      - "--host"
      - "0.0.0.0"
      - "--port"
      - "8080"
      - "--api-key"
      - "${LLAMA_API_KEY}"
    restart: "no"
```

> 参数名以主线 `common/arg.cpp` 为准：`-fit/--fit`、`-lzm/--lazy-mode`（2×3090 仓库里的 `--tensor-read-lazy` 来自 PR 分支，主线已改名）、`-fa/--flash-attn`、`-ncmoe/--n-cpu-moe`、`-ot/--override-tensor`。

**上线前必须做的三件事：**
1. `make down` 停掉 27B（显存二选一）。
2. 腾内存：关掉浏览器/IDE 等，目标 `MemAvailable ≥ 20GB`；并**禁用该容器的 swap**（`--memory-swap` 或 systemd `MemorySwapMax=0`），避免 zram 压缩模型页。
3. 宿主机 TTY 确认 `nvidia-smi` 正常（历史 udev 节点问题；当前内核已更新）。

**下载：**
```bash
hf download AtomicChat/Qwen3.8-Flash-Next-GGUF \
  --include "Qwen3.8-Flash-Next-AD-3.84bpw-IQ4_XS-M64/*" \
             "mmproj-Qwen3.8-Flash-Next-F16.gguf" \
  --local-dir ./models/flashnext
```

**Open WebUI：** Settings → Connections 新增 `http://llama-flashnext:8080/v1`（compose 服务名），key 用 `LLAMA_API_KEY`。
⚠️ 别填 `http://localhost:8082/v1`——WebUI 的请求发自它自己的容器内，容器里的 `localhost` 是容器自身，必然连不上；`localhost:8082` 只适用于**从宿主机**直连（浏览器/`curl`）。

---

## 7. 其他方案对比

| 方案 | 做法 | 预期 | 代价 |
|---|---|---|---|
| **A. IQ4_XS-M64** | 见 §6 | 15~25 tok/s | 需腾内存；~40GB 走 SSD |
| **B. 更小量化** | UD-Q2_K_XL（78.9GB）或 IQ2_XXS（75.2GB） | 稍快，质量降（KLD 0.225 vs 0.084） | 1~2bit 专家质量 |
| **C. REAP-320 Q2** | 剪枝版 61.5GB，常驻仅 32.7GB | 本机内存压力最小 | 官方卡片自述：12 题捏造率 **25%**（未剪枝 0%）；社区剪枝版，需自行验证 |
| **D. 加内存到 64GB** | 2×32GB DDR4（AM4 支持） | 常驻容量 ~85GB，IQ4_XS 基本全常驻，预计 25~35 tok/s | 约 ¥600~1500；是唯一能让它「好用」的本地升级 |
| **E. 走 API** | Qwen Cloud 的 Qwen3.8-Flash（1M 上下文 + 工具） | 质量/速度最好 | 按量计费（2026-08-27 降价后输入约 ¥0.8/百万 token）；数据出本机 |
| **F. 本地蒸馏版** | Qwen3.8-9B-Distill Q4_K_M（5.8GB） | 3090 上 40~80 tok/s | 不是 Flash-Next 能力，只是同代蒸馏 |

> 一句话：**IQ4_XS-M64 + 腾内存**是本机「能跑且质量可接受」的最优组合；想省心就用 API；想长期本地跑就加内存。

---

## 8. 与现有 Qwen3.8-27B 的取舍

| 维度 | Qwen3.8-27B（现有，已实测） | Flash-Next（本机预计） |
|---|---|---|
| 权重 | 16.5GB，全显存（`-ngl 99`） | 85GB，约 40GB 在 SSD mmap |
| 速度 | 40~70 tok/s（`draft-mtp` 开启，+68~74%） | 15~25 tok/s（无 MTP；`ngram-mod` 对 copy/code 有 2~3× 加成） |
| 上下文 | 256K（KV q4_0 ≈ 4GB） | 128K~256K（KV f16 3~6GB，更宽裕） |
| 能力定位 | 27B 级，通用/视觉 | 125B-A6B，agent/coding/长上下文更强 |
| 视觉 | ✅ | ✅ |
| 稳定性 | 已实机验证 | 新架构 + 低比特量化，需重新验证 |

---

## 9. 风险清单

1. **GPU 设备节点**：本机历史上 udev 陈旧导致 `/dev/nvidia*` 缺失（见 [`HANDOFF.md`](../HANDOFF.md) 第 3 节），且当前内核已从 `7.1.8-cachyos` 变为 `7.1.9-arch1-2` —— 部署前先在宿主机 TTY 确认 `nvidia-smi`，必要时跑 `scripts/fix-driver-manual.sh`。
2. **桌面合成器显存 OOM**：24GB 卡上模型要吃 ~21GB，本仓库 27B 就踩过这个坑（用 `-nkvo` 解决）。Flash-Next 建议 headless 或降低 GPU 占用层数。
3. **量化质量**：Unsloth KLD 实测 top-1% / mean KLD：IQ1_S 77.3 / 0.396，Q2_K_XL 82.7 / 0.225，IQ3_XXS 85.4 / 0.165，**IQ4_XS 89.6 / 0.084**，Q8_0 94.1 / 0.027。1-bit 档质量损失明显，建议 IQ4_XS 起步。
4. **KV 量化**：PR 讨论中 `-ctk q8_0` 曾在 `qwen4exp.cpp:544` 触发 assert（后续修复）；本仓库惯用 q4_0，建议先用 f16 KV 验证稳定，再考虑 q4_0。
5. **`-fit on` 崩溃**：3090 上需 `-fit off`。
6. **无 MTP**：主线尚未支持 `qwen4exp` 的 MTP（[PR #28104](https://github.com/ggml-org/llama.cpp/pull/28104) open），unsloth 的 `MTP/*.gguf` 暂时用不上；`ngram-mod` 是无草稿的替代（DGX 实测 copy/JSON 场景 2.5×）。
7. **swap/zram**：zram 会压缩模型页导致严重掉速，务必给容器禁 swap。
8. **磁盘加密**：根分区 LUKS，随机读延迟略增；85GB 下载 + 后续重定量化需预留空间。

---

## 10. 上线验证清单

1. 宿主机 `nvidia-smi`；容器内 `docker run --rm --gpus all nvidia/cuda:12.6.3-base-ubuntu24.04 nvidia-smi`。
2. 确认镜像 build ≥ b10660：`docker run --rm ghcr.io/ggml-org/llama.cpp:server-cuda --version`。
3. 启动后看日志里的 `CPU_Mapped model buffer` / `CUDA0 model buffer` 大小是否符合预期（约 20GB 显存 + 其余 mmap）。
4. `curl localhost:8082/v1/models` 返回模型名；`nvidia-smi` 显存 ~21GB。
5. 短 prompt 测速（可复用 `scripts/probe-mtp.py`，改端口/模型名），再测 32K 长输入（对标机 TTFT ~150ms 温启动）。
6. 视觉：上传图片验证 `mmproj` 生效。
7. 稳定性：连续跑 30 分钟，观察是否出现 KV assert / 合成器 OOM / zram 增长。

---

## 11. 参考

- 模型卡：<https://huggingface.co/Qwen/Qwen3.8-Flash-Next>
- llama.cpp 架构支持 PR：<https://github.com/ggml-org/llama.cpp/pull/27742>（2026-08-27 合并）
- 单卡 3090 24G + 32G RAM 实测 27 tok/s：<https://linux.do/t/topic/2818800>
- 2×3090 + 64GB 仓库：<https://github.com/ruashots/flashnext-2x3090>
- 4×3090 部署报告：<https://github.com/tonyd2wild/Qwen3.8-Flash-Next-Fleet-Deploy>
- DGX Spark 配方：<https://github.com/sxuff/qwen38-flash-next-dgx-spark>
- Unsloth GGUF + KLD 表：<https://huggingface.co/unsloth/Qwen3.8-Flash-Next-GGUF>、<https://unsloth.ai/docs/models/qwen3.8-next>
- AtomicChat GGUF（推荐量化）：<https://huggingface.co/AtomicChat/Qwen3.8-Flash-Next-GGUF>
- REAP-320 剪枝版：<https://huggingface.co/AnonimousA/Qwen3.8-Flash-Next-REAP-320-GGUF>
- Qwen Cloud 定价（2026-08-27 降价）：<https://developer.aliyun.com/article/1761526>
