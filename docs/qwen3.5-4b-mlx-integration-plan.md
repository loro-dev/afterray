# Qwen3.5-4B 本地 MLX 接入计划

状态：提案，待真实设备验证后实施  
日期：2026-08-15  
负责人：AfterRay 本地模型链路

## 决策

将 **Qwen3.5-4B 的标准 MLX 4-bit 权重**作为 AfterRay 下一代本地模型候选：
[`mlx-community/Qwen3.5-4B-MLX-4bit`](https://huggingface.co/mlx-community/Qwen3.5-4B-MLX-4bit)。

- 它是一个支持文本和图片的 4B 多模态模型；标准 MLX 快照约 **3.06 GB**、包含一份权重、tokenizer
  和图像/视频处理配置。[模型文件清单](https://huggingface.co/mlx-community/Qwen3.5-4B-MLX-4bit/tree/main)
- 用 Apple 的 `mlx-swift-lm` / `MLXVLM` 直接运行，做成 App 内签名、常驻的 Swift worker。用户只点下载，
  不安装 Ollama、Unsloth、Python、Node 或模型。
- 当前 App 的 llama.cpp/GGUF 内置模型继续保留作低内存回退；Ollama 继续是用户自选的外部提供方，
  不成为内置实现依赖。

模型许可为 Apache 2.0，消除了 LFM 的商业收入授权门槛；仍须在发行 notices 中包含上游归属和许可证。

## MLX 方案选择

| 方案 | 结论 | 原因 |
| --- | --- | --- |
| 标准 `Qwen3.5-4B-MLX-4bit` | **首发基线** | 上游 MLX Community 已提供完整 VLM 快照；常规 MLX 运行时可以直接加载；约 3.06 GB |
| `Qwen3.5-4B-OptiQ-4bit` | **Phase 0 性能候选，不首发依赖** | 混合 4/8-bit 量化，模型卡称能力接近/略高于均匀 4-bit；但其 MTP ~1.4× 加速由独立 `optiq serve --mtp` 运行时实现，不能假定原生 Swift worker 能直接取得该加速；其页面所示体积也大于标准版，需实测 |
| Ollama `qwen3.5:4b-mlx` | **仅用来对照测试** | Ollama 已提供 4.0 GB MLX tag，适合人工快速试用，但嵌入它会重新引入额外运行时、升级和模型管理责任 |
| `mlx-vlm` Python server | **开发验证工具，不进入产品** | 模型卡提供 `mlx_vlm` 用法，便于迅速验证权重；生产版不应要求用户安装 Python 或 `mlx-vlm` |

OptiQ 的公开说明称其对敏感层使用 8-bit、其余层 4-bit，并带 MTP head；但这是提供方自述的基准。
我们只在 AfterRay 自己的检索、工具调用和中文任务上决定是否采用，不能仅凭通用 benchmark 选它。

## 与现有代码的关系

| 现有部分 | 现状 | 本期变化 |
| --- | --- | --- |
| `crates/afterray-models/src/process.rs` | `ProcessAdapter` 每次请求启动一个进程、读一次 JSON 后退出 | 保留给 OCR；新增持久的 `PersistentMlxAdapter` |
| `crates/afterray-models/src/catalog.rs` | 已有 Hugging Face snapshot 多文件下载 | 新增 MLX/VLM 运行时类型、固定 revision、manifest/hash 校验 |
| `crates/afterray-models/src/remote.rs` | 内置、Ollama、OpenAI-compatible 路由 | 新增明确的 `mlx_local` 提供方和健康状态 |
| `Package.swift` | 有原生 OCR worker，未依赖 MLX | 新增 `afterray-mlx-vlm-worker` executable 和 `MLXVLM` 依赖 |
| `swift/AfterRayRecall` | 设置页列出 built-in/Ollama/OpenAI-compatible | 新增“AfterRay 本地（MLX）”下载和生命周期 UI |
| Agent | 当前只解析 `TOOL <name>\nARGS <json>` | 先维持此协议，之后单独验证 Qwen 的原生工具格式 |

## 架构

```text
AfterRay.app
  └─ afterrayd (Rust)
       ├─ 模型目录 / Hugging Face snapshot 下载与校验
       ├─ PersistentMlxAdapter ── NDJSON stdin/stdout ──► afterray-mlx-vlm-worker
       │                                                   └─ MLXVLM + Qwen3.5-4B MLX files
       ├─ 现有 llama.cpp 内置模型
       ├─ Ollama（外部可选）
       └─ OpenAI-compatible（外部可选）
```

worker 只由 daemon 启动，不监听本地 TCP 端口。首次加载模型后保持进程存活；连续提问复用同一个
模型容器，不能复用现有一次性 `ProcessAdapter`，否则会每次重载约 3 GB 权重。

### Worker 协议

新增独立协议版本，使用带 `request_id` 的 NDJSON：

```text
daemon → worker  {"v":1,"kind":"load","model_dir":"…","request_id":"startup"}
worker → daemon  {"v":1,"kind":"ready","request_id":"startup","runtime":"mlx-swift-lm@…"}

daemon → worker  {"v":1,"kind":"generate","request_id":"r1","messages":[…],"images":[],"max_tokens":512}
worker → daemon  {"v":1,"kind":"delta","request_id":"r1","text":"…"}
worker → daemon  {"v":1,"kind":"final","request_id":"r1","text":"…","usage":{…}}

daemon → worker  {"v":1,"kind":"cancel","request_id":"r1"}
worker → daemon  {"v":1,"kind":"cancelled","request_id":"r1"}
```

- 一次只允许一个 `generate`，现有 `ModelQueue` 在 worker 外排队。
- stdout 只能写协议 JSON；日志写 stderr。
- `load` 在全部模型文件、tokenizer 和 processor 配置校验通过后才发 `ready`。
- Qwen3.5-4B 是 VLM：worker 用 `VLMModelFactory`/`MLXVLM`，即使 Phase 1 只传文本也不能误用纯
  `MLXLLM` loader。
- Qwen3.5 VLM 的手工 KV-prefix cache 复用曾有连续请求崩溃，但已由
  [#283](https://github.com/ml-explore/mlx-swift-lm/pull/283) 修复，并进入
  [`mlx-swift-lm` 3.31.4](https://github.com/ml-explore/mlx-swift-lm/releases/tag/3.31.4)。
  首版 pin `3.31.4` 或更高的经回归验证版本；对“相同前缀、不同图片、无图片、取消后新请求”建立真实
  回归测试，通过后启用 KV cache，失败则对该请求安全降级为完整 prefill，而非重载模型容器。

## 实现工作

### 1. 受管模型包

1. 在 catalog 加入 `llm_qwen35_4b_mlx4`，固定准确 Hugging Face revision，不能指向 `main`。
2. 利用已有 `HuggingFaceSnapshot` 下载单一 safetensors 及 tokenizer、chat template、processor、图像/视频
   配置；新增每文件 size/sha256 manifest。
3. 下载目录先写临时位置，全部验证后原子标记 `ready`。状态至少包含 `not_downloaded`、`downloading`、
   `verifying`、`ready`、`in_use`、`failed`、`incompatible`。
4. 下载前计算：权重下载 + 校验临时空间 + 模型运行余量。M2 的 8/16/24 GB 统一内存实际支持界线由 Phase 0
   测量确定；8 GB 仅实验，不承诺产品支持。

### 2. Swift MLX VLM worker

1. 在 `Package.swift` 新增 `afterray-mlx-vlm-worker` target，pin 一个明确支持 Qwen3.5 文本与视觉的
   `mlx-swift-lm` release，而不依赖 `main`。其发行说明已经包含 Qwen3.5/Qwen3.5 MoE 的文本和视觉支持。
2. 接入 `MLXVLM`、`MLXLMCommon`、本地 tokenizer/downloader 接口；权重由 Rust downloader 提供，worker
   不应自行联网。
3. 从模型目录的 tokenizer/chat template 生成请求，不能复用 Qwen3/Qwen2.5 模板，也不能手写 image token。
4. 支持文本流式生成、取消、模型加载时间/峰值内存/token 速率诊断。首版 `images: []`，保留协议字段；
   Phase 3 再把 AfterRay 的截图帧作为受控图片输入接入。
5. 普通 UI 不显示或持久化模型的控制 token、思考标记或未分类的原始输出；仅显示归一化后的最终回答。
6. 将 worker、MLX 运行时及动态库纳入 App 资源、codesign 和 notarization；必须在干净 Mac 测试。

### 3. Rust 持久连接与路由

1. 新增 `PersistentMlxAdapter`：持有子进程、stdin 写端、stdout 读取任务、request-id 等待表和重启退避。
2. 保留 `ProcessAdapter` 原语义，避免影响 OCR 以及它的测试。
3. 扩展 `LlmProvider` 为 `mlx_local`。`builtin` 仍代表现有 llama.cpp/GGUF；两者状态、日志与设置不混淆。
4. 在 `LlmRouter` 为 `mlx_local` 增加模型就绪、worker 加载、被取消、进程异常、系统不兼容等可展示状态；
   绝不因为本地失败而暗中发到云端。
5. 从 App bundle 明确解析签名 worker 路径。开发态与发行态共享解析接口，不能依赖 `PATH`。

### 4. Agent 和 UI

1. 首版为 Qwen3.5 写专属 system prompt，继续让模型输出当前的 `TOOL/ARGS` 文本协议；通过后才评估原生
   工具调用 parser。任何模型输出都要先经过 allowlist 和 JSON schema 校验，绝不能 `eval`。
2. 设置页新增“AfterRay 本地（MLX）”：模型来源、Apache 2.0、约 3.1 GB 下载、设备要求、下载/校验/加载进度、
   重试和卸载。
3. 选中 `mlx_local` 时隐藏 Ollama URL / OpenAI key；加载期间给出明确等待状态和回退到当前内置模型的入口。
4. 首发只显示为“推荐本地模型”，验收通过后再决定是否替换默认选择。

## 分阶段与退出条件

### Phase 0：可行性和量化选择

- 在 M2 的 8/16/24 GB Apple Silicon macOS 14+ 机器上加载标准 4-bit、完成文本和一张图片的推理，并覆盖
  #283 修复的连续 KV-cache 请求场景。8 GB 只记录实验结果；16 GB 起才作为可支持档位候选。
- 验证原生 Swift worker 可签名打包，并量测下载大小、冷加载、稳态 token/s、峰值内存、长上下文、取消。
- 用同一批 AfterRay T2 样本对比标准 4-bit 与 OptiQ。若要选择 OptiQ，同时证明：不依赖用户 Python、无需
  `optiq serve` 才能跑、质量提升可复现、大小/速度收益足以抵消新依赖；否则固定标准版。

退出条件：标准 4-bit 在 M2 16 GB+ 能由 `MLXVLM` 稳定运行，连续请求不重载模型，且无用户外部安装步骤。

### Phase 1：常驻 worker 和现有 Agent

- 实现 worker、`PersistentMlxAdapter`、feature flag 路由。
- 覆盖 load / delta / final / cancel / crash-restart / 非 JSON stdout；证明两次请求同一 worker PID 处理。
- 使用 `crates/afterrayd/examples/t2_eval.rs` 及现有 local-model 评测记录中文检索、时间范围、工具调用与回答质量。

退出条件：流式、取消、连续请求、崩溃恢复和已有 `TOOL/ARGS` 回合均通过；没有控制/思考文本进入历史记录。

### Phase 2：下载、设置和发行

- 完成 snapshot manifest、断点恢复、空间检查、校验、卸载和设置页。
- 完成 codesign/notarization、App 升级与干净机安装验证。

退出条件：全新用户只通过 AfterRay UI 就能下载并使用模型；断网、空间不足、校验失败和 worker 启动失败均可恢复。

### Phase 3：受控视觉输入与高级优化

- 将 AfterRay 截图帧以显式用户可见的方式提供给模型；限制图片数量、尺寸、上下文与隐私边界。
- 上游确认后评估 VLM KV cache；比较 OptiQ/MTP 或其他 MLX 优化，不改变首发稳定路径。

## 验收标准

| 类别 | 可验证结果 |
| --- | --- |
| 无外部依赖 | 干净 M2 Apple Silicon Mac 上只安装 AfterRay，并从 UI 下载模型即可问答和使用图片输入 |
| 下载完整性 | 文件遗漏、大小或 hash 不符时 worker 不启动；中断可恢复，错误可读且能重试 |
| 常驻性 | 连续两次请求同一 worker PID 完成；第二次没有完整模型加载事件 |
| VLM 正确性 | 文本和单图片请求均使用模型原始 chat template/processor；连续 KV-cache 请求通过 #283 对应回归用例 |
| 安全性 | 工具只能经过 allowlist 和 schema 校验执行；默认不显示/存储控制标记、thinking 或原始隐式推理 |
| 兼容性 | Built-in llama.cpp、Ollama、OpenAI-compatible 配置和现有测试保持通过 |
| 发行 | worker 和 MLX 依赖随签名/notarized App 工作；Apache 2.0 notice 可访问 |
| 质量 | T2 评测输出可解析，人工复核检索、时间范围和工具调用；结论写入 `docs/evals/` |

## 风险

| 风险 | 处理 |
| --- | --- |
| 4B VLM 在低配 M2 的内存超过可接受范围 | Phase 0 建立 8/16/24 GB 矩阵；8 GB 不承诺支持，UI 只向通过档位提供下载，保留 llama.cpp 回退 |
| MLX Swift 上游回归 | 固定 release、保留真实模型回归；不使用未经验证的 main |
| VLM cache 回归 | pin 含 #283 的 3.31.4+ 版本并在真实 Qwen3.5-4B 上回归；出现回归时只对该请求退为完整 prefill，不重载模型 |
| OptiQ 吞吐优势绑定独立运行时 | 不作为发版基础；只有原生可复现的收益才纳入 worker |
| 图片带来额外隐私和上下文成本 | 视觉功能独立灰度，明确用户可见来源与尺寸上限，不把截图隐式上传/转发 |

## 参考

- [标准 Qwen3.5-4B MLX 4-bit 权重与文件清单](https://huggingface.co/mlx-community/Qwen3.5-4B-MLX-4bit/tree/main)
- [OptiQ 混合精度 4-bit 量化说明、MTP 与公开基准](https://huggingface.co/mlx-community/Qwen3.5-4B-OptiQ-4bit)
- [MLX Swift LM：Qwen3.5 文本/视觉支持的发行说明](https://github.com/ml-explore/mlx-swift-lm/releases)
- [Qwen3.5 VLM 连续请求的 KV cache 已知问题](https://github.com/ml-explore/mlx-swift-lm/issues/157)
- [Ollama Qwen3.5 MLX tags（仅作为对照）](https://ollama.com/library/qwen3.5/tags)
