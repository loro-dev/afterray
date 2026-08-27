# AfterRay V0 实现计划

> **状态（2026-08-20 更新）：历史计划。代码是唯一权威。**
> 下面的正文仍然记录着当初的意图，没有改写；被代码推翻的部分逐条列在这里。
>
> **本文正文自相矛盾，读者无法从中判断 Accessibility Tree 到底是不是需求。** §1 的闭环要求「本地记录……前台 Accessibility Tree」，§2 V0-R001 重复了这条；§3「明确不做」第一行却写着「Accessibility Tree。」；§8「V0 Done」又把它列成完成标准。三处互相冲突，任何一处都不能单独当作需求读。代码给出的答案是：AX 一直在采，而且是主内容通道之一 —— `crates/afterray-platform-macos/src/lib.rs:244`（`ArtifactKind::Accessibility`）。
>
> **OPEN：收藏是一条仍然对用户成立的虚假承诺 —— 本文件里最严重的一条。**
> - `Request::FavoriteSet` 直接失败返回 `"favorites are disabled"`，`crates/afterrayd/src/main.rs:947`
> - 出货 App 构造 `RecallView` 时根本不接 `onToggleFavorite`，`apps/AfterRay/Sources/AfterRayApp.swift:1063`；这个回调声明在 `swift/AfterRayRecall/Sources/RecallView.swift:32`，只有 Visual Lab 接（`apps/AfterRayVisualLab/Sources/AfterRayVisualLabApp.swift:173`）
> - 保留策略里的豁免条款还在 —— `WHERE m.is_favorite = 0`，`crates/afterray-store/src/lib.rs:4781` —— 但没有任何一行数据能满足它
> - 设置页仍然告诉用户「Favorites … may exceed this limit」，`swift/AfterRayRecall/Sources/AfterRaySettingsChrome.swift:816`
> - 官网仍然承诺 "favorites never expire" / 「收藏永不过期」，`site/src/i18n.tsx:284` 与 `site/src/i18n.tsx:561`
>
> 其余推翻项：
> - V0-R001「V0 使用固定采样策略，不做键鼠活动触发」→ 输入事件现在会把截图拉到前面来，节流下限 `EVENT_CAPTURE_MIN_INTERVAL_MS`，`crates/afterrayd/src/main.rs:1447`；调用点 `crates/afterrayd/src/main.rs:2424`
> - V0-R003 的按 Moment 数量删除（`maxUnstarredMoments`）→ 改为按字节：`enforce_retention`，`crates/afterray-store/src/lib.rs:4724`，上限默认 100 GB（`DEFAULT_STORAGE_LIMIT_BYTES`，`crates/afterray-protocol/src/lib.rs:14`）。`maxUnstarredMoments` 这个符号在代码里任何地方都不存在。当前规则见 [tiered evidence retention](decisions/active/architecture/2026-08-27-tiered-evidence-retention.md)
> - V0-R002 / §5「V0 不实现 blob pack」「V0 不做 pack」→ 冷帧的闭合 GOP AV1 打包已上线，`commit_gop`，`crates/afterray-store/src/gop.rs:386`
> - §5「schema 只支持 V0……不承诺 migration」→ `migrate` 串了 20 个编号迁移步骤（`crates/afterray-store/src/lib.rs:5126`），`SCHEMA_VERSION = 26`（`crates/afterray-store/src/lib.rs:97`）
> - §3「明确不做」中实际已经上线的：Accessibility Tree（同上）；Developer ID / Notarization / 自动更新（`scripts/build-release.sh:118` 起的发布链路，Sparkle 配置在 `apps/AfterRay/Resources/Info.plist:37`）；第三方 Agent 集成（`crates/afterray-cli/src/main.rs:15` 的只读 CLI + `skills/afterray/SKILL.md`）；内置 Agent harness（`crates/afterray-harness/`、`crates/afterray-agent/`）；多模型选择（LLM 路由 `crates/afterray-models/src/remote.rs:502`）；Settings UI（`swift/AfterRayRecall/Sources/AfterRaySettingsChrome.swift:816` 所在的设置页）
> - §4.4 建议 7 个 crate → 实际 11 个（`crates/`：afterray-agent、afterray-cli、afterray-codec、afterray-core、afterray-harness、afterray-infer、afterray-models、afterray-platform-macos、afterray-protocol、afterray-store、afterrayd）
> - §6 Phase 3 的 `V0-304`「scale/opacity/red glow 过渡」从未落地 —— `RecallView`（`swift/AfterRayRecall/Sources/RecallView.swift:24`）里没有任何红色余辉过渡
> - §4.5 列出的 CLI 动词（`daemon start`、`record start/stop`、`favorite add/remove`）一个都不存在。真实命令面见 `crates/afterray-cli/src/main.rs:27` 的 `Command`（只读查询与证据读取），且 `--json` 是全局 flag（`crates/afterray-cli/src/main.rs:20`），不是每条命令各自的参数

> 原状态：Active  
> 目标用户：开发者本人  
> 目标：先在一台本机上跑通完整闭环，不按可公开发布产品的标准建设  
> 原则：产品功能最小化，但把可跨平台的后台核心放进 Rust；Swift 只负责 macOS UI 和确实不适合由 Rust 直接调用的系统边界。

## 1. V0 的唯一目标

V0 只回答一个问题：

> AfterRay 能否在本机持续记录屏幕和声音，用本地模型理解这些内容，并提供一个有感觉的左右拖拽回溯体验？

V0 完成时，应能跑通：

```text
启动 AfterRay
→ 首次启动连续申请屏幕、麦克风和 Accessibility 权限
→ 权限齐备后自动开始 Recording Session
→ 本地记录屏幕、系统音频、麦克风和前台 Accessibility Tree
→ 保存截图与音频片段
→ OCR、ASR、Embedding 和 LLM 各跑通一条真实路径
→ 打开 Recall View
→ 左右拖拽回到任意已记录时刻
→ 查看当时截图并播放对应音频
→ 收藏某个时刻
→ 达到内部保留阈值时，删除最旧的未收藏内容
→ 退出并重新启动后仍能继续回放和检索
```

V0 不是 Alpha，也不是给普通用户安装的正式版本。它可以依赖开发者运行模型下载脚本，但权限由 App 统一引导，录制不要求手动开始。

## 2. 冻结需求

### V0-R001：本地录制

WHEN App 首次启动，AfterRay SHALL 依次请求屏幕录制、麦克风和 Accessibility 权限。

WHEN 三项权限全部可用，AfterRay SHALL 自动在本机开始记录当前显示器、系统音频、麦克风和前台 App 的 Accessibility Tree。

WHEN 开发者点击 Stop Recording，AfterRay SHALL 结束当前 Session，并让已提交内容可以立即回放。

V0 使用固定采样策略，不做键鼠活动触发、会议检测或自适应 throttle。 **[已推翻 → `crates/afterrayd/src/main.rs:2424`]**

### V0-R002：本地保存与恢复

WHEN 一个画面或音频片段产生，`afterrayd` SHALL 将它加密保存到本地数据目录，并在由 Rust 独占的 SQLite 中记录时间、文件位置和处理状态。

WHEN App 重启，AfterRay SHALL 重新打开已有数据库，并展示之前的 Session。

V0 不实现 blob pack、key rotation、recovery key、复杂 migration 或故障注入框架；但加密边界从第一天属于 Rust Vault，Swift 不直接读写数据库或媒体文件。

### V0-R003：删除最旧内容

**[整节已推翻 → `crates/afterray-store/src/lib.rs:4724`；`maxUnstarredMoments` 从未存在于代码]**

WHEN 未收藏 Moment 数量超过开发配置中的 `maxUnstarredMoments`，AfterRay SHALL 删除最旧的未收藏 Moment 及其派生数据，直到未收藏数量回到阈值以内。

IF 最旧 Moment 已收藏，AfterRay SHALL 跳过它，继续寻找下一条最旧的未收藏内容。

收藏 Moment 不计入 `maxUnstarredMoments`，因此收藏可以无限越过这个开发阈值，且不会阻止继续录制。

V0 只实现按 Moment 数量删除的策略，不读取磁盘占用，不做空间设置页、容量预测、Free/Paid 差异或动态扩容。

### V0-R004：模型基础链路

V0 SHALL 为以下能力各接通一个真实本地实现：

1. OCR：从截图得到文字。
2. ASR：从录音片段得到 Transcript。
3. Embedding：为 OCR 和 Transcript 生成向量，并完成一次语义检索。
4. LLM：读取选定时间范围的 OCR/Transcript，生成一段本地回答或摘要。

模型由开发者通过脚本手动下载到固定目录。Rust daemon 负责任务队列、并发、重试、取消和结果提交；具体推理 Adapter 可以是 Rust、MLX Swift worker 或开发期本地子进程。V0 不做模型商店、CDN、签名 catalog、断点续传、多版本回滚或硬件档位推荐。

### V0-R005：初始回溯

WHEN Recall View 打开，AfterRay SHALL 按时间顺序展示已经记录的 Moment。

WHEN 用户左右拖拽，AfterRay SHALL 连续改变当前时间，并显示离该时间最近的截图。

WHEN 当前 Moment 有音频，用户 SHALL 能从对应时间播放或暂停。

V0 只做一个水平时间轴，不做 Month/Day/Session 多层缩放。

### V0-R006：收藏

**[整节已推翻 → `crates/afterrayd/src/main.rs:947`（RPC 直接失败）。但设置页 `swift/AfterRayRecall/Sources/AfterRaySettingsChrome.swift:816` 与官网 `site/src/i18n.tsx:284` 仍在向用户承诺这条 —— 见顶部状态块的 OPEN 项]**

WHEN 用户收藏当前 Moment，AfterRay SHALL 持久化收藏状态。

WHILE Moment 被收藏，自动保留任务 SHALL 跳过该 Moment 及回放它所需的文件。

WHEN 用户取消收藏，该 Moment SHALL 重新成为可删除内容。

## 3. 明确不做

以下内容全部移出 V0，不为它们提前建设抽象：

- Accessibility Tree。 **[已推翻 → `crates/afterray-platform-macos/src/lib.rs:244`；且与本文 §1、§2 V0-R001、§8 直接冲突]**
- 键盘、鼠标活动触发截图。 **[已推翻 → `crates/afterrayd/src/main.rs:2424`]**
- 自动会议检测与会议 App adapters。
- 自动开始录音；V0 只允许手动 Start/Stop。
- 正式 onboarding 和一次完成所有权限的流程。
- App Store、Developer ID、Notarization、自动更新和安装包。
- Free/Paid、订阅、退订、退款、宽限期和历史迁移。
- 面向用户的空间限制、空间预测和容量设置。
- 生产级加密能力：key rotation、recovery key、安全导出和复杂 pack compaction。V0 仍实现 Rust 持有的最小本地加密。
- 面向外部用户的 Context Gateway、MCP 和第三方 Agent 集成；内部 Rust CLI 是 V0 的正式控制面。
- 内置 Agent harness、Daily Goal、Daily/Weekly Reflection。
- PII 检测和外部模型审批。
- Month/Day/Session 缩放、复杂 shader 和完整视觉语言。
- Windows、iOS、P2P、Enterprise 和开源流程。
- 模型自动下载、模型升级、多模型选择和热状态智能调度；基础 job queue 与并发控制仍由 Rust 实现。
- 遥测、崩溃上报和普通用户支持工具。

这些项目在 V0 证明核心体验成立后重新排序；当前不建立占位代码。

## 4. 架构：Rust daemon 是产品核心

```text
AfterRay.app (SwiftUI/AppKit)       afterray CLI (Rust)
             │                           │
             └──── Unix domain socket ───┘
                              │
                       afterrayd (Rust)
        ┌─────────────────────┼──────────────────────┐
        │                     │                      │
  Session/Capture       Vault/Search          Model Scheduler
    Orchestrator       Encryption/SQLite       OCR/ASR/Emb/LLM
        │                                            │
  CaptureBackend                               ModelAdapter
        │                                            │
 macOS Rust backend                       Rust / MLX Swift worker /
 or thin Swift helper                     local development process
```

`afterrayd` 是登录用户会话中的后台进程，不是 system LaunchDaemon。V0 可以通过开发脚本手动启动；未来再包装为 App 内嵌的签名 Login Item。

### 4.1 Rust 必须拥有

- Recording Session 状态机和 Start/Stop 命令。
- 截图/音频采样计划、pipeline backpressure 和工作队列。
- SQLite schema、读写、收藏和删除最旧内容。
- 媒体加密、密钥访问和解密读取。
- OCR、ASR、Embedding、LLM job 的调度、重试、取消与状态。
- TextEvidence、Embedding、搜索和 Recall read model。
- daemon IPC 和 `afterray` CLI。

### 4.2 macOS 能力的实现顺序

1. **Accessibility：Rust first。** Apple AX 是 C/Core Foundation API，先使用 Rust bindings；未来加入时无需默认经过 Swift。
2. **ScreenCaptureKit：Rust first, time-boxed。** 先用 Rust bindings 跑通 `SCStream` 的 screen/audio/microphone 输出。
3. **如果 direct Rust 路径不稳定：** 创建独立的薄 Swift Capture Helper，实现 Rust 定义的 `CaptureBackend` 协议。Helper 只把已经编码的帧/音频 segment 和时间戳交给 daemon，不拥有 Session、队列、模型或数据库。
4. **UI 永远不是 capture provider。** 关闭 AfterRay 窗口不能结束 daemon 的录制和处理。

不要跨 Unix socket 逐帧复制原始 `CMSampleBuffer`。如果使用 Swift Helper，它先完成最薄的 Apple callback 与编码，只把低频截图和有界音频 segment 的编码 bytes/共享内存句柄交给 daemon；落盘前仍由 Rust 加密。

Accessibility Tree 不进入 V0 的用户闭环，但技术边界已确定：未来先在 `afterray-platform-macos` 中用 Rust 获取；只有具体属性或 API bindings 缺失时，才为那一小段增加 Swift provider。

### 4.3 模型边界

Rust 负责“何时运行什么任务”，Adapter 负责“如何执行一次推理”：

```text
Rust durable job
→ acquire model/concurrency slot
→ invoke ModelAdapter
→ validate typed result
→ commit Evidence
```

这允许 V0 使用 AfterRay 自己管理的本地 worker，同时保持调度、数据和未来 CLI 接口跨平台。以后替换推理实现不影响 UI、Store 或队列。

### 4.4 建议目录

```text
apps/
  AfterRay/                   Swift UI client
  AfterRayVisualLab/          Recall component lab
  AfterRayCaptureShim/        只有 Rust direct capture 失败时才创建

crates/
  afterrayd/                  composition root + socket server
  afterray-cli/               CLI client
  afterray-core/              Session、Moment、jobs、retention、ports
  afterray-store/             SQLite + encrypted artifacts
  afterray-platform-macos/    AX/ScreenCaptureKit/CoreMedia bindings
  afterray-models/            scheduler + adapters
  afterray-protocol/          IPC request/response types

swift/
  AfterRayRecall/             production Recall component
  AfterRayMockData/

scripts/
  download-models/
  run-v0/
```

V0 只拆这些稳定边界，不继续细分 crate。

### 4.5 V0 IPC 与 CLI

V0 使用 Unix domain socket 和版本化 request/response。CLI 是第一个完整客户端，Swift UI 使用同一套 API。

下面这份动词表 **[已推翻 → `crates/afterray-cli/src/main.rs:27`]**：`daemon start`、`record start/stop`、`favorite add/remove` 从未实现；真实 CLI 是只读的查询/证据面，`--json` 是全局 flag（`crates/afterray-cli/src/main.rs:20`）。

```text
afterray daemon start
afterray status --json
afterray record start
afterray record stop
afterray sessions list --json
afterray moments list --session <id> --json
afterray search <query> --json
afterray favorite add <moment-id>
afterray favorite remove <moment-id>
afterray models status --json
afterray jobs list --json
```

CLI 不直接打开 SQLite 或媒体文件。`--json` 输出是 V0 的集成测试接口；交互式输出可以很简单。Recall UI 通过 daemon 的 `get_recall_window` 和 `read_artifact` 请求获取 read model 与解密后的媒体 bytes，不接触 Vault path 或 key。

## 5. 最小数据模型

```text
RecordingSession
  id
  startedAt
  endedAt?

Moment
  id
  sessionId
  capturedAt
  imageArtifactId
  isFavorite

AudioSegment
  id
  sessionId
  track            system | microphone
  startedAt
  endedAt
  audioArtifactId

TextEvidence
  id
  sessionId
  momentId?
  audioSegmentId?
  source           ocr | transcript
  text
  startedAt
  endedAt?
  modelVersion

Embedding
  evidenceId
  vector
  modelVersion
```

约束：

- Rust Store 是唯一数据入口；Swift 和 CLI 不直接打开 SQLite。
- SQLite 是 metadata source of truth；V0 使用最小加密数据库方案，具体 driver 在 Phase 0 固定。
- 图片和音频使用 Rust Vault 的 encrypted artifact 文件；V0 不做 pack。
- root key 由 `afterrayd` 的 macOS KeyProvider 获取；V0 不做恢复、轮换或多设备共享。
- 对外 schema 只暴露 `artifactId`；Rust daemon 负责按需解密并返回 bytes，不暴露真实路径和密钥。
- 删除 Moment 时同步删除图片、OCR 和 Embedding。AudioSegment 只有在不再与任何存活 Moment 时间范围重叠时才删除，避免破坏收藏内容的回放。
- 时间统一保存 wall-clock timestamp；音频同步可额外保存 monotonic offset。
- schema 只支持 V0；自用阶段允许删除本地数据后重建，不承诺 migration。

## 6. 实现阶段

### Phase 0：Rust Core 与两个客户端，2–3 天

目标：daemon、CLI 和两个 App target 能启动，并使用同一协议。

- `V0-001`：创建 Cargo workspace、`afterrayd`、`afterray-cli`、core/store/protocol/platform crates。
- `V0-002`：创建 AfterRay.app、AfterRayVisualLab.app 和 Recall Swift module。
- `V0-003`：建立 Unix socket、protocol version、health/status request。
- `V0-004`：建立 SQLite schema、encrypted artifact API 和 macOS KeyProvider。
- `V0-005`：生成 20 个 mock Moments 和两条 mock 音轨；daemon 返回 Recall read model。
- `V0-006`：Visual Lab 显示最小水平 Recall View。
- `V0-007`：增加一条本地 build/test/run 命令，不做云 CI。

出口：

- `run-v0` 可以启动 daemon 和主 App。
- `afterray status --json` 返回 daemon/schema/protocol 状态。
- Visual Lab 可以用 mock 数据左右拖拽。
- daemon 重启后仍能读取 fixture；Swift 和 CLI 均未直接访问 SQLite。

### Phase 1：Rust 主导的录制与保存，4–6 天

目标：先得到不含模型的真实本地 recorder。

- `V0-101`：Rust Session/Recorder state machine，App 自动 Start，CLI 与 Swift 均可 Pause/Resume。
- `V0-102`：定义 `CaptureBackend`、Frame/Audio artifact contract 和 fake backend。
- `V0-103`：用 Rust bindings 跑通 ScreenCaptureKit screen/audio/microphone；限定 2 个工程日。
- `V0-104`：若 `V0-103` 未达到稳定出口，使用薄 Swift Capture Helper 实现同一 contract；不保留两套生产 backend。
- `V0-105`：Rust 固定频率采样、artifact 加密、Moment/AudioSegment 提交。
- `V0-106`：主 App 与 CLI 列出 Session/Moment，并可结束/重启 daemon 后重新打开。

出口：

- 权限齐备后能自动开始真实录制。
- 重启后截图和两条音轨仍可打开。
- Stop 后不继续写入新文件。
- 关闭 Swift UI 不会停止 daemon 中已经开始的录制。
- 最终只有一个 capture backend；选择结果记录在代码注释和短说明中，不扩展为长期 PoC。

### Phase 2：Rust 模型调度与真实 Adapter，4–6 天

目标：四类模型各跑通一次，不做模型产品化。

- `V0-201`：Rust job queue：pending/running/done/failed、并发上限、retry/cancel。
- `V0-202`：模型下载脚本、固定目录和 `ModelAdapter` process contract。
- `V0-203`：截图 → OCR Adapter → typed TextEvidence。
- `V0-204`：AudioSegment → ASR Adapter → typed TextEvidence。
- `V0-205`：TextEvidence → Embedding Adapter → Rust 语义搜索。
- `V0-206`：选定时间范围 → LLM Adapter → 回答/摘要。
- `V0-207`：CLI 展示 models/jobs 状态，并可重试失败 job。

出口：

- 一张真实截图能产生可见 OCR。
- 一段真实双轨录音能产生 Transcript。
- 自然语言查询能返回至少一个相关 Moment。
- 本地 LLM 能根据选定内容生成结果。
- 模型失败不会让录制数据消失。
- Swift UI 没有模型调度状态机；关闭 UI 后 daemon 继续处理队列。

### Phase 3：初始 Recall 效果，3–5 天

目标：做出第一个可以感受到产品方向的回溯界面。

- `V0-301`：水平时间轴和当前 playhead。
- `V0-302`：左右拖拽改变当前时间。
- `V0-303`：离 playhead 最近截图的 thumbnail-first 加载。
- `V0-304`：截图切换的第一版 scale/opacity/red glow 过渡。
- `V0-305`：播放/暂停对应系统音频和麦克风音轨。
- `V0-306`：显示当前 OCR/Transcript。
- `V0-307`：收藏/取消收藏。
- `V0-308`：Visual Lab 加入空数据、短/长 Session、模型处理中和收藏场景。

出口：

- 用鼠标或触控板左右拖拽，可以从 Session 开头回到结尾。
- 拖拽不触发模型推理。
- 当前截图、时间和 Transcript 保持一致。
- Visual Lab 和主 App 使用同一个 Recall component。

### Phase 4：Rust retention 与本机闭环，2–3 天

目标：让 V0 可以反复自用，而不是一次性 demo。

- `V0-401`：Rust daemon 配置加入 `maxUnstarredMoments`。
- `V0-402`：Rust Store 超过阈值后按时间删除最旧未收藏 Moment。
- `V0-403`：事务更新 metadata，并清理 encrypted image、文本、Embedding 和无引用音频。
- `V0-404`：验证收藏不计入阈值，全部历史被收藏时仍可继续新增未收藏 Moment。
- `V0-405`：完成一次录制、停止、处理、回放、搜索、收藏和清理闭环。

出口：

- 小阈值测试证明删除顺序正确。
- 收藏 Moment 不会被自动删除。
- 删除内容不再出现在 Recall 或搜索里。
- 完整流程只依赖主 App、模型目录和本地数据目录。

## 7. 并行方式

Phase 0 的 protocol、Store API 和 Capture/Model ports 冻结后，使用 3 个实现 Agent：

| Agent | 所有权 | 第一批任务 |
|---|---|---|
| A — Rust Core/Platform | daemon、CLI、CaptureBackend、加密 Store、retention | Phase 0/1，随后 Phase 4 |
| B — Rust Models/Search | job queue、ModelAdapter、OCR/ASR/Embedding/LLM、搜索 | Phase 2 |
| C — Swift Recall/Visual | Swift client、Recall View、播放、Visual Lab | Phase 3 |

Lead 只负责：

1. 冻结 Rust domain、IPC schema、Store/Capture/Model ports。
2. 每天把三个短分支合到可运行的 `main`。
3. 在同一台 Mac 上运行当前闭环。
4. 删除任何不属于 V0 的提前设计。

```text
Phase 0
  ├─ A: daemon captures and stores Moment/AudioSegment
  ├─ B: scheduler consumes fixture jobs through the same daemon API
  └─ C: Recall consumes mock/real read models through the same protocol
          ↓
     每日合入同一真实 Session
          ↓
     Phase 4 retention + final self-run
```

模型和 UI Agent 在真实录制完成前使用同一组 fixtures，不等待 Recorder。

## 8. V0 Done

- 在开发机上可以从源码构建并启动 `afterrayd`、`afterray` CLI 和 AfterRay.app。
- Rust CLI 和 Swift UI 通过同一个 daemon API 完成 status、Pause/Resume、查询与收藏。
- 首次启动会引导全部必需权限，权限齐备后自动开始本地 Recording Session。
- Session 同时包含屏幕、系统音频、麦克风和前台 Accessibility Tree。
- OCR、ASR、Embedding、LLM 各有一条真实本地路径成功运行。
- 可以通过左右拖拽回到 Session 中任意已记录时刻。
- 可以播放该时刻对应音频，并查看 OCR/Transcript。
- 可以收藏 Moment，重启后收藏状态仍存在。 **[已推翻 → `crates/afterrayd/src/main.rs:947`]**
- 未收藏内容达到内部数量阈值后，最旧未收藏内容被删除；收藏内容不计入阈值。 **[已推翻 → `crates/afterray-store/src/lib.rs:4724`，改为按字节]**
- Swift UI 关闭时 daemon 可以继续录制和处理；daemon 重启后已有内容仍可回放和搜索。
- SQLite 与加密 artifact 只由 Rust Vault 访问，Swift UI 和 CLI 不直接碰文件。
- 完成一次本机自用闭环。

V0 不要求生产签名分发、长期稳定运行、正式安全保证、商业逻辑或自动会议检测。

## 9. V0 后的第一轮迭代：只优化 Recall

V0 跑通后，第一个独立迭代周期只处理回溯效果，不并行加入其他产品功能。

```text
Visual Lab 制作 3–5 个 Recall 方向
→ 用同一份真实 Session 录制对比视频
→ 选择一个方向
→ 调整拖拽手感、画面层次、过渡和红色光线
→ 放回主 App 自用
→ 记录哪里迷失、哪里卡顿、哪里产生 wow moment
→ 继续下一轮
```

可以研究：

- 截图薄片、景深和遮挡关系。
- 拖拽速度与时间移动比例。
- 惯性、吸附和停止时的画面稳定。
- 当前画面和前后画面的清晰度层级。
- 红色余辉、光线和 shader。
- 长 Session 的缩略与快速跳转。

这一阶段仍不加入 Month/Day 多层视图、会议检测、Agent、支付或正式分发。

## 10. 仅保留的开发参数

以下参数放在开发配置中，不制作 Settings UI：

- 截图采样间隔。
- 图片 codec/quality。
- 音频 segment 长度与 codec。
- 内部保留阈值。
- 模型目录。
- Recall 拖拽灵敏度和 thumbnail cache 大小。
- daemon socket 路径和 worker command。

参数变化只要不改变本计划的可观察行为，就不需要 ADR。
