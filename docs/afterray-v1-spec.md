# AfterRay v1 产品与技术规格草案

> 状态：Deferred product vision；当前实现以 `docs/afterray-v0-implementation-plan.md` 为准，本文件不作为 V0 的任务或验收依据。  
> 原状态：Draft 0.2，首发边界已部分冻结  
> 研究截止：2026-08-12  
> 目标：macOS Apple Silicon 个人版  
> 文档原则：把已经决定的事项、建议默认值、待验证假设和开放问题分开，不用“看起来合理”冒充实验结果。

## 0. 如何阅读这份文档

本文使用四种状态：

- **已决定**：可以直接进入产品设计和实现。
- **建议**：当前最合理的默认方向，但可以被实验推翻。
- **需 PoC**：存在可行路径，不代表已经能稳定嵌入签名后的 macOS 产品。
- **开放问题**：会明显改变产品、架构或商业结果，需要创始人明确拍板。

模型厂商的 “SOTA” 只代表其公开模型卡或指定 benchmark 的结论。AfterRay 关心的是小字号 UI、中文与中英混说、持续后台运行、能耗、随机回放和工具调用；最终采用哪个模型，只能由 AfterRay 自己的真实语料决定。

---

## 1. 一页结论

### 1.1 v1 的产品定义

AfterRay v1 是一款面向 macOS 26、M3 及以上 Apple Silicon Mac 的本地记忆工具。它持续捕获用户看见的内容；用户在 onboarding 明确开启“自动记录检测到的会议”后，系统只在稳定确认会议时自动捕获麦克风与系统音频，并立即通过菜单栏和通知提示、允许一键停止或本次不录。屏幕、OCR、Accessibility 语义和 Transcript 被组织成可回放的时间线，并允许用户或经授权的本地 Agent 检索这些证据。

v1 的主入口不是搜索框，而是一个具有“视觉奇观”感的可缩放 Timeline：用户可以从某一秒连续缩放到一天、一周和一个月，并快速进入任意时刻的屏幕、对话与上下文。

记录只是 Context Layer。产品价值由三层逐步释放：

1. **Recall**：回到当时，找到证据。
2. **Reflection**：每日目标、每日/每周复盘、时间与注意力分析。
3. **Action**：让严格受限的本地 Agent 基于这些证据帮助用户处理待办；v1 只做只读检索与建议，不自动执行外部动作。

### 1.2 当前建议的技术路线

- **平台**：v1 只做 macOS 26 + M3+，不承诺 Windows。
- **UI 与系统能力**：SwiftUI/AppKit + ScreenCaptureKit + Accessibility + AVFoundation/ScreenCaptureKit Audio + Metal/MLX Swift。
- **可复用核心**：Rust 实现 Vault、索引、保留策略、证据查询、权限策略和对外 Context Gateway。
- **模型**：安装 App 后按能力包下载；基础 App 不携带几十 GB 权重。
- **磁盘**：10GB、20GB 都必须能用。Capture Vault 与 Model Packs 分开计量，按用户真实日写入量预测保留天数。
- **捕获**：10 秒逻辑心跳 + 200–500ms trailing debounce + 持续操作时的 max-wait + 画面变化去重。
- **图片**：v1 先用可替换的独立帧编码层；HEIF/JPEG 是主要候选，PNG 是质量基线，HEVC 短分段是实验项。
- **OCR / ASR / Embedding / LLM**：具体模型不在产品 Spec 中冻结，另行讨论并通过 AfterRay 真实语料与签名产品运行时验证。产品只冻结能力和资源门槛。
- **音频策略**：onboarding 中一次完成麦克风权限，并让用户明确选择“自动记录检测到的会议”。平时不打开麦克风；会议确认规则成立时自动开始，不依赖用户临场记得点击。
- **内置 Agent**：实现 Pi-compatible 的极小只读 loop；只有 Pi/Node 通过签名 XPC 隔离 PoC 才直接采用 agent-core，否则用 Swift/Rust 实现等价 loop。完整 Pi Coding Agent 的文件、shell、网络和扩展系统不进入 App。
- **PII**：自动 PII 检测不进入 v1；App 排除、暂停、锁屏停止、AX secure value 禁读、可靠 bounds 下的像素保护和外发预览仍是最低安全要求。

### 1.3 已冻结的首发边界

1. **完整版优先**：v1 只通过官网发布 Developer ID 签名、Hardened Runtime 和 Notarization 的完整版；Mac App Store 不进入 v1 范围。
2. **Accessibility 不可降级**：完整跨 App AX 是真实捕获的 required permission。缺失或被撤销时，用户可体验 mock Timeline 和管理已有数据，但新的真实捕获暂停，不以纯 OCR 版偷偷降级。
3. **完整源码公开**：v1 默认使用 FSL-1.1-ALv2，允许审查和自己编译，每个版本两年后转 Apache-2.0；Protocol / SDK 使用 Apache-2.0，官方 Agent Skills 使用 MIT。Developer Preview 暂不接受外部代码贡献。
4. **音频按会议自动开启**：麦克风权限与“自动记录检测到的会议”的产品同意在 onboarding 中分开展示。默认不占用麦克风；确认已进入会议时自动开始并明确告知，始终允许一键停止。

---

## 2. 产品目标与非目标

### 2.1 目标

v1 应让用户在第一次使用的当天完成以下体验：

1. 在清楚理解权限与隐私边界后，开始本地捕获。
2. 通过全局快捷键进入回溯模式。
3. 用滚轮或触控板在秒、小时、天、月之间连续缩放。
4. 找回一段刚看过的文字、会议内容或屏幕状态。
5. 查看截图背后的 OCR、Transcript 和可用的 Accessibility 结构。
6. 安装可选本地 Agent 包，并得到带证据引用的当日复盘。
7. 在设置中准确知道哪些内容正在记录、用了多少空间、预计还能保留多久、哪个模型访问过什么数据。

### 2.2 v1 非目标

- Windows、Linux、iOS 同步或 P2P 跨设备同步。
- 企业管理、集中策略、远程审计或自部署服务端。
- 通用桌面自动化、自动点击、自动发消息或自动修改文件。
- 完整复刻 Hermes、Claude Code 或其他 Agent harness。
- 记录按键内容、key code、鼠标轨迹、点击内容或原始活动事件流。
- 自动 PII 识别与脱敏。
- 对 Slack、飞书等 App 做大规模、脆弱的私有协议逆向。
- 保证每张截图都被 VLM 结构化解析。
- v1 开源、公共仓库或外部代码贡献。

---

## 3. 目标用户、硬件与产品档位

### 3.1 首发用户

- 使用高内存 Apple Silicon Mac 的开发者、研究者、创作者、产品经理和高强度知识工作者。
- 对隐私敏感，但愿意让自己的设备持续计算。
- 已在使用或关注 Ollama、Hermes、Claude Code、本地模型和个人 Agent。
- 愿意为极佳的设计、零配置体验、签名版本、稳定更新、模型管理和移动端生态付费。

### 3.2 硬件准入

**已决定**：最低系统为 macOS 26，芯片最低为 M3。磁盘空间不作为“一刀切”的准入条件。

内存档位仍需实测，当前只作为产品推荐而不是承诺：

| 统一内存 | 基础捕获/搜索 | 本地 Agent 建议 | 当前定位 |
|---|---|---|---|
| 16GB | 应可用 | 默认关闭重型 Agent | Capture 基线，需 M3 Air 热测试 |
| 24GB | 应可用 | 轻量 Agent 档 | Core + 轻量 Intelligence |
| 32/36GB | 应可用 | 中档 Agent，以实测推荐 | Intelligence |
| 48GB | 应可用 | 高档 Agent，以任务集决定 | High |
| 64GB+ | 应可用 | 最高稳定档 + 实验模型 | Max / Labs |

规则：

- 模型推荐同时考虑 `physicalMemory`、实时可用内存、温度、电源和模型 KV cache，而不是只看权重文件大小。
- OCR、ASR、Embedding、LLM 不应默认全部常驻内存。
- 捕获与音频落盘优先级始终高于任何模型推理。
- 用户可以忽略推荐，但 UI 必须展示预计内存、下载大小、安装大小与降级后果。

### 3.3 磁盘档位

Capture Vault 至少支持 10GB、20GB、自定义三种上限。Model Packs 单独展示和管理，不能吞掉用户以为留给 Timeline 的空间。

用户看到的不是静态营销数字，而是：

> 根据你最近 7 个完整自然日的日写入量分布，当前 20GB 大约可保留 18–25 天。关闭原始会议音频后预计可延长到 31–40 天。

前 6 天只能显示带“初步估算”标识的保守范围。这里的 P95 指完整自然日总写入量的 P95；不足 7 个样本时不得把估算描述成稳定预测。

---

## 4. 核心用户流程

### 4.1 Onboarding

**已决定：所有核心权限在同一次 onboarding session 内完成，不把权限请求推迟到用户第一次使用某项功能时。** macOS 不会把多个权限合并成一个系统弹窗，因此“一次性”指 AfterRay 用一个 Permission Center 解释全部权限，再按固定顺序逐项拉起系统审批；全部 required permissions 通过后才完成 onboarding。

Onboarding 分五步：

1. **视觉承诺**：用内置 mock data 演示从 Month 连续缩放到某个 Moment；演示不读取用户屏幕。
2. **信任与边界**：一次说明本地计算、记录内容、不记录输入事件、录制指示、暂停、排除和删除。
3. **Permission Center**：在一张 checklist 中展示所有核心权限的用途、当前状态和系统入口，然后顺序申请。
4. **录制范围**：选择显示器、App 排除、音频采集/保留模式、光标记录和 Vault 大小。
5. **能力包**：权限完成后再选择 OCR、ASR、Embedding 和 Local Agent；展示下载、内存和磁盘成本。

Permission Center 的 v1 checklist：

| 项目 | 用途 | 完成规则 |
|---|---|---|
| Screen Recording | 屏幕与系统音频 | Required |
| Microphone | 用户确认会议后记录本人发言 | Required；此处只授予系统权限，默认不开始录音 |
| Accessibility | AX Tree、结构化 UI、secure-field bounds 和会议界面判断 | 完整版 Required；不提供 OCR-only 降级路径 |
| Input Monitoring | 活动触发截图 | 仅当最终实现使用 listen-only event tap 时 Required；若公开 idle-time API 足够，则从 checklist 移除，不申请无用权限 |
| Notifications | 每日目标、总结完成和异常暂停提醒 | Required；可在 Permission Center 解释通知类型 |
| Launch at Login / Background Item | 登录后继续本地记录 | 作为明确产品同意项在同一流程开启 |

交互规则：

- AfterRay 自己的说明页只出现一次；系统权限弹窗和 System Settings 跳转按顺序进行。
- 用户拒绝某个 required permission 时留在 Permission Center，可体验 mock Timeline，但不能误以为真实捕获已经启动。
- 返回 App 后自动重新检查权限状态；系统需要重启 App 时保存 onboarding progress，重启后回到原步骤。
- onboarding 完成后，核心功能不得突然索要新的权限。未来新增权限必须经过独立 release review，并重新进入一个明确的 Permission Upgrade 流程。
- AfterRay v1 不使用摄像头，不申请 Camera 权限。会议视频由会议 App 自行处理，AfterRay 不读取摄像头画面。
- Permission Center 中的 Microphone 授权只是技术前置；“自动记录检测到的会议”是独立产品开关，必须在 onboarding 明确同意，并可随时关闭。
- 权限以后被系统或用户撤销时立即停止受影响的捕获，显示 repair checklist，不循环弹系统请求。
- 模型下载不属于系统权限审批，不和权限弹窗并行，避免用户同时面对隐私与几十 GB 下载两个决定。

### 4.2 日常捕获

- 菜单栏常驻 AfterRay 光点，明确表示屏幕/声音是否正在记录。
- 用户可一键暂停 5 分钟、1 小时、直到手动恢复。
- 用户可排除 App、窗口标题模式和显示器。
- 锁屏、切换用户、屏幕睡眠时保守暂停全部捕获。
- 模型队列落后时，优先保住证据，延后 OCR/Embedding/总结。

### 4.3 Timeline 回溯

- 全局快捷键打开全屏回溯层。
- 滚轮/触控板沿时间轴移动；捏合或修饰键改变时间尺度。
- 当前画面保持清晰，前后画面以空间、深度和红色余辉形成运动连续感。
- 用户可切换 Screen、Transcript、OCR、Accessibility 四个证据层。
- 点击 AX/OCR 框时展示文字、来源、捕获时间差与置信状态。

### 4.4 搜索与问答

- 用户可搜准确词、子串、App、人名、时间范围和自然语言描述。
- 搜索先返回 Moment/Episode，而不是一长串脱离画面的文本。
- 每条答案引用稳定的 Evidence ID；用户可直接回到对应时刻。
- “复制给外部模型”默认只复制用户预览后的文本证据，不默认带截图和音频。

### 4.5 每日目标与总结

- 早晨由用户选择是否接收“今天最重要的三件事”提示。
- 目标由用户明确输入，系统不得把推断目标冒充用户承诺。
- 当设备接电且空闲时，本地 Agent 基于 Timeline 生成总结草稿。
- 总结区分“观察到的事实”“模型推断”“建议行动”。
- 用户确认后才把事项写入 AfterRay 自己的待办；v1 不自动写入外部系统。

---

## 5. Timeline：核心视觉与交互规格

### 5.1 视觉概念

AfterRay 的视觉母题是“事件发生后残留的光”。主题色不是大面积纯红，而是深色空间中的暖红、珊瑚红与近白高光：

- 当前时刻是清晰、低噪的实体画面。
- 相邻时刻是具有景深的薄片或光膜。
- 快速滑动时，变化区域形成短暂的红色残影；静止后立即收敛，避免持续炫技。
- 月视图像一张由注意力和画面组成的星图；不是传统日历格子堆叠。
- Shader 负责景深、光晕、时间扭曲与过渡，不负责遮盖信息或制造长时间 GPU 负担。

视觉系统要优先产生可录制、可传播的 5–10 秒 “wow moment”：从整月缩放进入一次会议，再打开 Transcript 与语义覆盖层。

### 5.2 连续语义缩放

Timeline 至少有四个 Level of Detail，但用户感知应是连续缩放：

| 尺度 | 显示内容 | 主要动作 |
|---|---|---|
| Moment：秒到分钟 | 清晰屏幕、光标、OCR/AX 框、Transcript | 精确回看与复制 |
| Session：分钟到小时 | 代表帧带、App 段、会议段、主题标签 | 快速浏览一段工作 |
| Day：一天 | 注意力河流、会议、空白、目标与总结 | 看懂一天花在哪里 |
| Month：一月 | 每日密度、主要主题、代表帧星图 | 找模式并快速下钻 |

数据层需要预先构建多分辨率摘要金字塔：`Moment → Session → Day → Month`。`Episode` 是会议或其他语义区间，可跨越 Session，不是 Timeline LOD 的父子层。缩放时不允许临时让大模型生成整个视图。

### 5.3 回放语义层

每个 Moment 可提供以下可开关层：

1. **Screen**：当时画面。
2. **Cursor**：只显示截图瞬间的单点位置；默认是否开启仍待决定。
3. **OCR**：文字框、内容和 OCR 置信度。
4. **Accessibility**：role、label、value、bounds、可用性与捕获偏移。
5. **Transcript**：按系统音频和麦克风两条轨道显示。

Accessibility Tree 是当时的近似快照，不是截图的绝对真相。Snapshot 必须标记 `complete`、`partial` 或 `unavailable`；与截图偏差超过 2 秒时不绑定覆盖层，超时或只取得部分节点时 UI 必须明确展示，而不能画出看似确定的框。

### 5.4 Timeline 初始验收门槛

这些是 provisional 产品目标，必须通过命名的 `TIM-PERF-PROFILE-v1` 验收，Week 1 建立基线，Beta 前冻结：

- 参考机：24GB M3 MacBook Air 和一台 48GB M4 Pro/Max。
- 数据：30 个完整自然日、按 dogfood P95 Moment 数生成；单屏 Retina 与双屏各跑一组。
- 场景：冷启动、热缓存各独立记录；关闭后台模型推理，再单独测开启 OCR/ASR 队列的干扰。
- 测量：Instruments + 帧时间记录；报告 hotkey-to-interactive P50/P95、随机 seek P50/P95、连续 scrub 10 秒的 dropped-frame ratio。

- 在 30 天索引上，Day/Month 视图平移与缩放保持 60fps 目标；不能因为模型未完成而卡住。
- 已有缩略图时，全局快捷键到首个可交互画面目标小于 500ms。
- 随机跳转到任意 Moment，P95 首屏目标小于 200ms；原图可渐进补全。
- 连续快速 scrub 时允许只显示缩略图；停止后必须切换到高质量帧。
- 无 AX、无 OCR、已回收图片、模型失败都必须有明确降级 UI。

### 5.5 AfterRay Visual Lab

**已决定：建立一个独立的原生 Visual Lab，作为 Swift/Metal 版本的 Storybook。** 它与正式 App 共用生产组件和 shader，但不读取真实屏幕、不申请系统权限、不打开真实 Vault，也不加载 AI 模型。日常操作细则见 [AfterRay Visual Lab 工作流](./visual-lab-workflow.md)。

建议工程拆分：

```text
AfterRayDesignSystem     colors, type, spacing, materials, icons
AfterRayTimelineKit      Timeline components, layout, transitions, shaders
AfterRayMockData         deterministic synthetic Moment/Session/Day/Month data；MeetingEpisode 作为可跨层的语义区间
AfterRayVisualLab.app    scene catalog, controls, capture and stress modes
AfterRay.app             production shell, permissions, real services
```

Xcode `#Preview` 用于组件旁的快速循环；Visual Lab 用于需要时间、手势、多层数据和 GPU 的完整场景。Web 原型可以探索概念，但不作为 shader 参数、motion timing 或最终视觉验收的 source of truth。

#### Scene Catalog

每个场景拥有稳定 ID、固定 seed、虚拟时钟和明确 viewport：

- `timeline.month.overview`
- `timeline.month.to-day.zoom`
- `timeline.day.attention-river`
- `timeline.session.scrub.fast`
- `timeline.moment.focus`
- `overlay.ocr-ax-transcript`
- `state.loading-partial-gap`
- `state.secure-redaction`
- `state.single-dual-display`
- `content.zh-en-long-text`
- `accessibility.reduce-motion`
- `stress.30-days-dense`

mock data 必须是合成数据，并覆盖屏幕比例、中文/英文、长 Transcript、AX partial/skew、OCR 低置信度、图片回收、模型未安装和多显示器等失败态。所有动画由可注入的 `VisualClock` 驱动，测试和录制时不依赖真实 wall clock。

#### 实时控制台

Visual Lab 可实时调整并保存 versioned preset：

- 时间尺度与 LOD threshold。
- frame spacing、Z depth、perspective、parallax。
- afterglow、bloom、blur、grain、vignette。
- warp/distortion strength 和 `maxSampleOffset`。
- zoom curve、spring、settle duration、scrub velocity mapping。
- 当前/相邻帧清晰度、缩略图切换阈值。
- Reduce Motion、Reduce Transparency、高对比和低功耗模式。

参数不能散落为 magic numbers。实验值保存成可 diff 的 `VisualPreset.json`，被接受后提升为 production design tokens；preset 需要 schema version 和 migration。

#### 迭代闭环

```text
选择 scene
→ 用固定 mock data 调组件/shader/motion
→ 保存 preset 与关键帧
→ 导出 5–10 秒 deterministic demo clip
→ 检查可读性、Reduce Motion 与 GPU/frame time
→ 设计评审
→ 提升 preset 到 production
→ snapshot/keyframe/performance regression
```

Visual Lab 至少提供四种运行模式：

1. **Interactive**：滚轮、触控板和快捷键真实操作。
2. **Shot**：固定镜头与虚拟时钟，重复生成用于官网/社媒的同一段视觉素材。
3. **Stress**：30 天密集数据、双屏、长文本和多 overlay。
4. **Accessibility**：Reduce Motion、键盘导航、VoiceOver label、高对比和放大。

#### 回归策略

- 单组件使用 Xcode parameterized Preview 覆盖常见输入。
- 关键静态帧和固定动画时间点输出 image attachment，并做带容差的视觉差异检查；Metal 跨硬件差异不能要求全局逐像素相等。
- 动画额外检查状态、布局、frame timing 和 dropped-frame ratio，不能只比较截图。
- 每次 PR 运行轻量 scene/keyframe tests；参考 Mac 上的完整 Metal/performance capture 可夜间运行。
- 每个公开传播片段必须能由版本库中的 scene ID + preset + virtual-time script 重现，概念视频不得成为无法实现的产品承诺。

Apple 的 [Xcode Previews](https://developer.apple.com/documentation/swiftui/previews-in-xcode)支持 parameterized mock inputs；SwiftUI 的 [layerEffect](https://developer.apple.com/documentation/swiftui/view/layereffect(_:maxsampleoffset:isenabled:)) 和 distortion effects 可直接使用 Metal shader。测试产物可以通过 [XCTest attachments](https://developer.apple.com/documentation/xctest/adding-attachments-to-tests-activities-and-issues)保留截图与诊断文件。

---

## 6. 系统架构

```text
┌──────────────────────── macOS App ────────────────────────┐
│ SwiftUI / AppKit / Metal Timeline                         │
│        │                                                  │
│        ├─ ScreenCaptureKit / Audio / AX / Permissions     │
│        ├─ MLX Swift model adapters                        │
│        └─ Signed XPC / isolated helper boundary (PoC)     │
└───────────────────────┬───────────────────────────────────┘
                        │ narrow typed API
┌───────────────────────▼───────────────────────────────────┐
│ Rust AfterRay Core                                       │
│ Capture scheduler state │ Vault/blob packs │ Retention   │
│ OCR/Transcript records  │ FTS/trigram      │ Vector API  │
│ Evidence model          │ Policy/audit      │ Query API   │
└──────────────┬──────────────────────┬─────────────────────┘
               │                      │
      ┌────────▼────────┐    ┌────────▼───────────────────┐
      │ Local Agent Host│    │ AfterRay Context Gateway  │
      │ Pi-compatible   │    │ CLI / MCP, read-only      │
      │ loop; isolated  │    │ explicit client scopes    │
      └─────────────────┘    └────────────────────────────┘
```

### 6.1 Swift 与 Rust 的边界

**建议采用之前讨论的混合方案。** v1 不应该用 Electron 重建 macOS 的捕获、权限、窗口和 Metal 体验。

Swift 负责：

- SwiftUI/AppKit UI、菜单栏、快捷键和系统生命周期。
- ScreenCaptureKit、AVFoundation、Accessibility、Keychain、Background Assets。
- Metal Timeline 和 Apple 专有的图片/视频编码器。
- MLX Swift 原生适配器。

Rust 负责：

- 不依赖 Apple UI 的事件模型、Vault、blob pack、索引与保留策略。
- Moment/Evidence schema 和检索排序。
- 对内/对外授权策略、审计与 Context Gateway。
- 可替换的模型任务队列和资源调度规则。

跨语言 API 必须是窄接口；不要把 Swift object graph 暴露到 Rust。优先稳定 C ABI 或经过验证的绑定方式，并用 versioned schema 隔离实现。

未来 Windows 复用 Rust core、schema、搜索协议、模型 manifest 与视觉 motion spec。视觉一致性通过 design tokens、Shader 数学参数、交互录像和 golden tests 对齐，而不是强求共享同一套 UI 组件。

### 6.2 进程与权限边界

目标边界：

- Vault/Search Service 是唯一能解密原始记录的组件。
- Model Runtime 只能接收完成策略裁剪后的输入。
- Download Service 是唯一允许访问外部网络的组件；Context Gateway 只允许本机 IPC。
- Agent Host 无外网、无用户目录和 Vault 文件权限，只能通过受限 IPC 调用只读工具。
- 外部 Agent 只能通过 Context Gateway 检索，不得连接 SQLite 或 blob 文件。

建议的进程权限矩阵：

| 组件 | 可读数据 | 网络 | 关键权限 | 状态 |
|---|---|---|---|---|
| Capture service | 当前屏幕/授权音轨/必需 AX | 无外网 | Screen Recording、Microphone、Accessibility、可选 Input Monitoring | 需 notarized build 权限 PoC |
| Vault/Search | 加密 Vault 与索引 | 无 | App Container/Vault | 目标边界 |
| Model runtime | 策略裁剪后的 task payload、已安装权重 | 无 | Model Packs | 需原生签名 PoC |
| Download service | model catalog/staging | 仅外网出站 | Network client、Background Assets | 渠道相关 |
| Agent host | 无直接文件读取；只读 IPC tool | 无 | 最小 XPC entitlement | 需 Pi/Node PoC |
| Context Gateway | scope 后的 Search API | 仅本机 IPC | client capability | 需 CLI/MCP PoC |

普通子进程会继承宿主 Sandbox，未必比宿主权限更窄；XPC 可以建立独立、较窄的 entitlement 边界。所有 runtime/helper 必须随 App 固定版本并签名，不能安装后下载。若 OS 级隔离无法成立，就不运行第三方 JS Agent runtime。

---

## 7. 捕获调度规格

### 7.1 术语纠正

用户描述的“操作停止 200–500ms 后只截一次，期间新事件合并”是 **trailing debounce**，不是 throttle。纯 debounce 会在连续滚动、拖动或输入时永远不触发，因此还需要最大等待时间。

建议将五个参数分开：

- `heartbeatInterval = 10s`：生成逻辑 checkpoint 的最大常规间隔。
- `settleDelay ∈ {200, 350, 500, 800}ms`：最后一次活动后的候选截图延迟。
- `maxActiveGap ∈ {1, 2, 5}s`：持续活动时强制生成候选帧的间隔。
- `cooldownCurve`：活动结束后把候选帧间隔逐步放大到 10 秒；可比较阶梯式 `1→2→5→10s`、指数式和直接回到 10 秒。
- `changeGate`：判断候选帧是否需要写入新图片 blob。

这些值必须通过真实任务实验决定，不能现在锁死为 200ms 或 500ms。

### 7.2 状态机

```text
OFF / PAUSED
  └─ user starts → IDLE

IDLE
  ├─ heartbeat due → CHECKPOINT
  ├─ activity observed → ACTIVE_SETTLING
  └─ lock/sleep → SUSPENDED

ACTIVE_SETTLING
  ├─ more activity → reset settle deadline
  ├─ quiet until settle deadline → CAPTURE_CANDIDATE
  └─ maxActiveGap due → CAPTURE_CANDIDATE

CAPTURE_CANDIDATE
  ├─ output: changed → persist blob; unchanged → reference previous;
  │          downstream busy → commit Moment and defer enrichment
  └─ next state: recent activity → ACTIVE_SETTLING; otherwise → COOLDOWN

COOLDOWN
  ├─ activity observed → ACTIVE_SETTLING
  ├─ dynamic interval due → CAPTURE_CANDIDATE
  └─ cooldown completed → IDLE

SUSPENDED
  └─ session active + screen awake + permissions valid → IDLE，并结束 gap

DEGRADED
  ├─ health below recovery threshold for recoveryWindow → previous active state
  └─ critical longer than criticalGracePeriod → SUSPENDED，并开始 health gap

Any active state
  ├─ thermal/backpressure → DEGRADED
  ├─ lock/sleep/user switch → SUSPENDED
  └─ user pauses → PAUSED
```

需要区分：

- **Capture candidate**：调度器希望观察当前画面。
- **Persisted frame**：实际编码并写入的新图像。
- **Logical checkpoint**：Timeline 时间点，可引用上一张未变化图像。

所以“默认十秒一张”在体验上成立，但不意味着每十秒重复写一份相同文件。

`criticalGracePeriod`、`recoveryWindow` 和 thermal/backpressure 恢复阈值都由 benchmark 冻结。状态机不得用无法测量的“恢复后”作为转移条件。

### 7.3 活动信号与不记录承诺

第一选择是轮询 Apple 的 `CGEventSourceSecondsSinceLastEventType(..., kCGAnyInputEventType)`：它只返回距离上次任意输入经过的时间，不需要接收键值或鼠标内容。若精度、权限或能耗不满足要求，再 PoC listen-only `CGEventTap`。

无论实现方式如何，AfterRay 都不得持久化：

- 输入事件时间序列。
- 事件类别、key code、字符、鼠标按钮、滚轮 delta。
- 鼠标移动路径。
- “由键盘/鼠标触发”之类的 capture reason。

允许持久化的只有 Moment 时间和可选的截图瞬间光标坐标。活动判断变量只存在内存中，并在状态转移后丢弃。

### 7.4 ScreenCaptureKit 策略

需比较三种实现：

1. 常驻 2–5fps 低帧率 SCStream。
2. 每次使用 SCScreenshotManager。
3. 活跃时 stream、空闲时单帧的混合方案。

当前建议先 PoC 常驻低帧率 SCStream，因为可以利用 frame status、`dirtyRects`、`displayTime` 和较新的完整画面；这不是能耗结论。M3 Air、双屏 Retina 和会议状态必须实测。

无论采用哪种方案，每块显示器被选中的完整帧都必须满足 `presentationTime >= candidateTriggerTime`。如果当前 stream 只有旧帧，则等待下一张 complete frame，或在超时后发起单帧截图；仍失败时写入明确 gap。每次保存 `captureLagMs`，不能用操作发生前的旧画面冒充操作后的截图。

### 7.5 多屏、锁屏与背压

- 每块显示器独立捕获、独立去重，Moment 引用多张 VisualFrame；不要拼成一张超宽图。
- 显示器拓扑变化时开启新的 topology epoch，旧 AX 坐标不得直接套用。
- 屏幕睡眠、session resign、系统睡眠或 ScreenCaptureKit blank/suspended 任一出现时暂停屏幕、音频、AX 和模型处理。
- 捕获回调只读取元数据并进入有界队列，不做 OCR 或大图压缩。
- 队列满时，图片保留 first + latest，OCR/Embedding/VLM 延后；音频先写压缩临时流，不能只留在内存。
- thermal `serious` 时暂停 LLM/VLM 并降低后处理；`critical` 时允许暂停捕获并在 Timeline 留下明确 gap。

---

## 8. 音频与 Transcript

音频需要把“系统权限”、“自动录制策略”、“会议确认规则”和“原始音频保留”分成四件事。已决定的 v1 默认是 **auto-detected meetings**：平时不录音，确认已进入会议后自动开始。这个策略必须在 onboarding 中被单独解释和同意。

```text
meetingState       = idle | possible | confirmed | recording | suppressed | cooldown
audioCaptureState  = off | starting | recording | stopping
audioCapturePolicy = autoDetectedMeetings | manualOnly | continuous
rawAudioRetention  = 30days | customShorter | none
```

`audioCapturePolicy` 决定什么时候自动开始；`rawAudioRetention` 决定原始麦克风和系统音频保留多久。v1 默认 `autoDetectedMeetings + 30days`。`continuous` 不作为首发默认；如果会议检测无法达到发布要求，必须重新做产品决策，而不静默改成全天录音。

### 8.1 会议确认规则

“会议识别阈值”改名为“会议确认规则”。它的意思只是：AfterRay 看到多少个、什么强度的会议迹象后，才认定“用户现在真的在开会”。用户界面不暴露分数或“阈值”这个词。

检测阶段不打开 AfterRay 的麦克风或摄像头，不持久化用户活动事件。它只组合已授权且不额外录音的迹象：

| 会议迹象 | 可靠程度 | 确认规则 |
|---|---:|---|
| Zoom、Teams、飞书、Slack、FaceTime 等已知 bundle ID 正在运行 | 弱 | 单独不弹提示，因为 App 可能只在后台 |
| 已知会议 App 在前台，或存在匹配的会议窗口 | 中 | 提升置信度，仍需其他证据 |
| AX 中出现可见的离开会议、静音、参会者或通话计时控件 | 强 | 与会议窗口/App 迹象组合后可确认会议 |
| 浏览器正在运行 | 弱 | 不能视为会议；必须匹配实际 Meet/网页会议标题与 AX 控件 |

Apple 公开的 `NSWorkspace.runningApplications` 可用于观察运行中的 App，但这不等于知道对方正在开会。v1 不把“读取其他 App 正在占用麦克风/摄像头”作为主路径：在找到稳定、公开、可签名分发的 API 前，这只是 PoC 中的可选加分信号，不使用私有 API、进程注入或驱动级绕过。

### 8.2 自动开始与停止

1. 用户在 onboarding 开启 `autoDetectedMeetings` 后，会议确认规则一旦成立，AfterRay 自动开始双轨捕获，不再等待本次会议点击。
2. 开始时显示不抢焦点的本地通知：“AfterRay 已开始记录这次会议”，提供“停止”和“本次不记录”。
3. 用户选择“本次不记录”后立即停止、删除尚未提交的本次音频缓冲，并对当前 meeting episode 进入 `suppressed`，不重新自动开始。
4. 录音期间在菜单栏和 Timeline 同时显示明确的 AfterRay 状态，并始终提供一键停止。macOS 也会显示麦克风或系统音频的隐私指示。
5. 会议 UI 消失、相关 App 退出或强迹象持续丢失时，自动停止录音并保留明确边界。迹象短暂抖动时使用 grace period，不切碎 Transcript。
6. 用户未开启 `autoDetectedMeetings` 时，仍可从菜单栏手动开始本次会议。

### 8.3 音轨

- 系统音频和麦克风必须作为独立轨道捕获，以便至少区分“我”和“远端”。
- 两条轨道使用 CMSampleBuffer 时间戳与 VisualFrame 对齐。
- VAD 只负责切段和调度 ASR，不作为用户活动记录持久化。
- AfterRay 自己播放的提示音或未来 TTS 应从系统音轨排除，避免重复转录。

### 8.4 原始音频保留

已决定：原始麦克风轨与系统音频轨默认都保留 30 天，随后自动删除；Transcript 按账户的 Timeline 历史规则保留。用户可以选择更短的保留期或转写成功后立即删除，但不提供超过 30 天的默认原始音频保留。

v1 支持三种保留策略：

| 模式 | 行为 | 当前建议 |
|---|---|---|
| 30 days | 原始双轨保留 30 天后删除 | 默认 |
| Delete after transcript | ASR 成功且重试窗口结束后删除原始音频 | 用户可选 |
| Custom shorter | 用户选择少于 30 天的保留期 | 用户可选 |

不保存 PCM。具体 AAC/Opus、码率与兼容性进入音频 benchmark。

### 8.5 说话人边界

语音识别不等于 diarization。分轨只能区分本机麦克风与系统音频，不能自动区分多个远端参会者。多人 diarization 列为 Preview/Labs，不阻塞 v1。

---

## 9. Screenshot 编码与 Vault

### 9.1 v1 存储抽象

```text
FrameBlobCodec
  ├─ PNG   — 无损质量基线
  ├─ JPEG  — 成熟有损候选
  ├─ HEIF  — Apple 平台首选候选
  └─ HEVC segment — 第二阶段实验
```

推荐流程：

1. 从同一原始 CVPixelBuffer 做 diff、OCR 和缩略图。
2. 再做有损归档编码，因此首次 OCR 不受 JPEG/HEIF 影响。
3. 对编码结果做内容寻址和去重。
4. 图片写入小时或天级 immutable blob pack，不创建几百万个小文件。
5. 数据库保存 `segment + offset + length + codec + hash`。
6. 被收藏、OCR 低置信度或重要会议的画面可额外保留无损 crop/PNG。

### 9.2 为什么暂不选 PNG + zstd

PNG 已经使用 Deflate。再包一层 zstd 的收益和 CPU 成本未知；跨多帧 zstd 又会破坏简单随机访问。它必须参加 benchmark，但不应预设为赢家。

JPEG 对小字号和高对比边缘的损伤要用 OCR CER、box IoU 和 200% 放大可读性衡量。HEIF 可能更适合 Apple 平台，但“实际是否走硬件编码”也必须测量。AVIF 在 M3/M4 上不能因为支持硬件解码就推断存在硬件编码。

HEVC 能利用帧间冗余，但会增加随机 seek、单点删除、损坏恢复和未来重处理复杂度。只有真实数据证明收益显著后，才引入 closed-GOP 短 segment。

### 9.3 容量模型

```text
dailyIngest =
  newChangedFrames × changedDisplays × (imageBlob + thumbnail)
  + moments × axSnapshot
  + retainedAudioBitrate × retainedAudioSeconds / 8
  + OCR + transcript + embeddings + database overhead

retentionDays ≈
  (vaultCap - emergencyReserve) / P95(recentDailyIngest)
```

即使用户 8 小时内只有 10 秒心跳，也有 2,880 个逻辑 checkpoint；活动截图会额外增加候选帧，而画面去重会减少实际新 blob。没有真实分布前，不承诺固定保留天数。

### 9.4 回收策略

1. **Free**：Timeline 使用滚动 30 天保留期。证据超过 30 天后立即 logical delete，并进入有界 physical compaction；UI 在删除前要显示可预期的截止日期。
2. **Paid**：Timeline 不做按年龄的自动删除，直到用户主动删除。“永久保留”表示没有时间到期，不表示可无限突破本地磁盘、Vault cap 或文件系统容量。
3. **Raw audio**：无论 Free/Paid，原始麦克风和系统音频默认最多保留 30 天；Transcript 遵循 Free/Paid Timeline 规则。
4. Vault 有用户设定的 soft cap，另留系统 emergency reserve；用量包含 dead blob 尚未压实的空间与 compaction 临时空间。
5. Free 在达到 cap 时可在 30 天内按时间回收最旧未收藏内容；Paid 不得用空间压力静默删除承诺永久保留的 Timeline，应暂停新写入并要求扩容、导出或手动删除。
6. 回收时优先整 pack 处理；若 pack 中含仍存活或收藏的 blob，则运行 crash-safe compaction：复制 live/pinned blob 到新 pack、原子切换索引，再删除旧 pack。
7. Timeline 对已回收证据显示 gap/metadata，不假装画面仍存在。用户收藏的 Moment 默认受保护，并明确展示其额外空间。
8. Model Packs 不进入 Vault cap。

---

## 10. Accessibility 与结构化屏幕理解

### 10.1 提取顺序

**已决定**：每个持久化 Moment 都对当时的前台 App focused window 做一次完整 AX subtree 遍历。不读取后台 App 的 AX，不用 AX Observer 事件流重建状态，不在两个 Moment 之间做增量 Tree。

1. 读取当前 frontmost App 的 focused window，从该 window root 沿 `AXChildren` 结构关系完整遍历所有后代。“完整”表示不为省空间主动只取文本节点，首发不设产品级固定 node 数量上限；`AXParent`、`AXWindow`、`AXLinkedUIElements` 等反向/交叉引用只保存关系，不继续递归，防止成环。对无响应 App 仍保留 deadline 安全中止机制。
2. 每个节点优先通过 `AXUIElementCopyMultipleAttributeValues` 一次批量读取 role、subrole、title、value、description、position、size、enabled、focused 和 children，减少跨进程往返；secure text field 不请求 value。
3. OCR 填补 AX 不存在、内容不完整或 Canvas/WebGL 的区域。
4. Deep OCR/VLM 只对代表帧、低置信度帧或用户主动请求做异步结构化。
5. Slack/飞书的“谁发的、发给谁、时间戳”先来自 AX role/label/布局与通用模式，不在 v1 写大量 App 专属 fragile parser。

### 10.2 时间对齐

选定完整屏幕帧后立即发起 AX 查询，并记录：

- frame presentation/display time。
- AX query start/end monotonic time。
- query completeness：complete/partial/timeout/unavailable。
- screen topology 和 points→pixels 变换版本。
- AX 中点与画面的估算 skew。

正常目标是在 100ms 内完成。整个 Snapshot 的默认硬截止时间先定为 1s；AX 工作在独立队列执行，不阻塞截图落盘。Apple Accessibility 是跨进程 messaging API，目标 App 卡顿、modal 等待或实现不完整时可能无法及时返回，因此必须有 deadline。超时时保存已取得的完整节点为 `partial`，不等待它拖慢后续 Moment。

截图与 AX Snapshot 的最大可接受 skew 冻结为 2s。`estimatedSkewMs <= 2000` 时可作为该 Moment 的近似语义与搜索证据；超过 2s 时记录为 `unavailable`，不绑定到该画面。所有 overlay 仍显示实际 skew，不宣称为像素级同步。

AX node ID 只在单次 snapshot 内稳定。不能把 AX 指针或 local ID 当成跨时刻身份。

### 10.3 建议 schema

```ts
type CaptureMoment = {
  id: string
  wallTimeUTC: string
  monotonicAnchorNs: bigint
  topologyId: string
  frames: VisualFrameRef[]
  axSnapshotRef?: string
  cursorSample?: { monotonicNs: bigint; globalPoint: [number, number] }
  evidenceRefs: string[]
}

type VisualFrameRef = {
  displayId: number
  requestMonotonicNs: bigint
  presentationTime: number
  status: "complete" | "idle" | "blank" | "suspended"
  screenRectPoints: Rect
  contentRectPoints: Rect
  pointPixelScale: number
  dirtyRects: Rect[]
  captureLagMs?: number
  blobRef?: string
  inheritedFromMomentId?: string
}

type AXSnapshot = {
  startedMonotonicNs: bigint
  endedMonotonicNs: bigint
  pid: number
  bundleId: string
  completeness: "complete" | "partial" | "timeout" | "unavailable"
  frameAlignments: {
    displayId: number
    framePresentationTime: number
    estimatedSkewMs: number
    transformVersion: string
  }[]
  nodes: AXNode[]
  encoding: "full-v1"
  compression: "zstd"
  secureBoundsUnavailable: boolean
  terminationReason?: "deadline" | "cannotComplete" | "invalidElement"
}

type AXNode = {
  localId: number
  parentLocalId?: number
  role: string
  subrole?: string
  title?: string
  value?: string
  description?: string
  globalFramePoints?: Rect
  enabled?: boolean
  focused?: boolean
}
```

AX secure value 永不读取。`secure-field bounds` 指密码输入框在屏幕上的矩形位置；AfterRay 可用它在 OCR 和落盘前遮住对应像素。若目标 App 没有提供 bounds，或 bounds 因窗口移动/skew 已不能可靠对齐，v1 **不丢弃整个窗口**：它仍保留截图，不读取该 secure node 的 value，并把 Snapshot 标记为 `secureBoundsUnavailable`。

密码框在正常 UI 中通常已显示为圆点；这项像素遮盖是额外保护，不是为了弥补 AX 读取密码。由于 PII 模型不在 v1，AfterRay 仍不得承诺能自动识别所有 OTP 或敏感文本；App/窗口排除仍是主要保护。

每个 AX Snapshot 都是自包含的完整对象，序列化后立即使用 zstd 独立压缩并落盘。不依赖前一个 Snapshot，不做增量 patch、跨 Moment dictionary 或延迟批量压缩。

没有对应 `frameAlignment` 的 AX 节点不得作为确定性覆盖层显示；多屏 Moment 必须按 display alignment 分别映射。

---

## 11. 搜索与 Evidence 模型

### 11.1 三条检索路径

- **准确与短语**：SQLite FTS5。
- **子串**：FTS5 trigram tokenizer 或同类本地索引。
- **错拼/近似拼写**：在 FTS 候选上做 edit-distance、spellfix 或独立 n-gram 召回；不能把 trigram 本身描述成完整拼写纠错。
- **语义**：Embedding + 本地向量索引。

Embedding 不是“模糊搜索”。三路召回后再按文本匹配、语义相似度、时间、App、证据质量和用户收藏做融合。

### 11.2 结果单位

对外返回 `Moment` 或 `Episode`，不返回散落文本：

```ts
type EvidenceHit = {
  evidenceId: string
  momentId: string
  occurredAt: string
  source: "ocr" | "ax" | "mic_transcript" | "system_transcript" | "summary"
  excerpt: string
  appBundleId?: string
  confidence?: number
  frameAvailable: boolean
}
```

同一段文字若同时来自 AX 和 OCR，应保留来源关系并去重展示，不能简单覆盖。

### 11.3 v1 结构化识别边界

Slack/飞书等 App 的消息结构需要一套可解释的 extractor：

- 输入：AX tree、OCR boxes、窗口几何和少量通用规则。
- 输出：actor、direction、timestamp、text、source evidence、confidence。
- 低置信度时仍以原始 Evidence 检索，不强行生成错误结构。
- App 专属适配器以数据 schema 和测试夹具隔离；不让它成为 Timeline 的硬依赖。

---

## 12. 模型选择边界

具体 OCR、ASR、Embedding 和 LLM 模型不在本产品 Spec 中列名或冻结。候选清单在产品讨论中单独维护，每次可能随上游发布变化。

本 Spec 只要求每类能力在进入 Stable 前通过 AfterRay 自有语料、能耗、内存、稳定性、签名运行时和再分发许可验收。高档默认的语义是“当前设备能稳定运行且 AfterRay 任务集得分最高”，不等于参数最多或自动下载最大权重。

---

## 13. 模型下载、更新与删除

### 13.1 包设计

建议能力包：

- `ocr-fast`：持续屏幕文字识别。
- `ocr-deep`：代表帧、表格与复杂版面的异步理解。
- `asr-core`：默认会议转写。
- `asr-quality`：高质量转写和可选时间对齐。
- `embedding-core`：语义召回，与 FTS 分层工作。
- `agent-light`、`agent-balanced`、`agent-high`：按真实资源档分包。
- `labs-*`：不进入首发默认的实验模型。

Base App 只携带运行时、tokenizer 实现、自定义算子和极小回退路径。下载包只包含权重、词表和静态配置，不允许 `trust_remote_code`、Python 模块、动态库或安装脚本。

### 13.2 Manifest

```json
{
  "schema": 1,
  "id": "afterray.asr.qwen3-0.6b.mlx5",
  "version": "1.0.0",
  "capability": "asr",
  "runtimeABI": "afterray-mlx-asr-v1",
  "source": {
    "repository": "upstream URL",
    "revision": "immutable commit"
  },
  "license": {
    "id": "Apache-2.0",
    "url": "license URL",
    "redistributionApproved": true,
    "reviewedBy": "legal-review-id",
    "evidenceURL": "redistribution evidence URL",
    "noticeSHA256": "..."
  },
  "requirements": {
    "minOS": "26.0",
    "estimatedRAM": 0,
    "recommendedRAM": 0
  },
  "downloadBytes": 0,
  "installedBytes": 0,
  "temporaryBytes": 0,
  "artifacts": [
    { "path": "weights/model.safetensors", "size": 0, "sha256": "..." }
  ],
  "signature": "ed25519..."
}
```

许可证字段不能靠工程师猜测。每个模型必须单独确认商业使用、再分发、量化转换、Notice、商标和地域要求。`redistributionApproved = false` 的模型只能从有权分发的上游由用户直接下载，或由用户离线导入；AfterRay CDN、Apple-hosted pack 和任何镜像都必须拒绝托管它。

### 13.3 下载通道

| 分发版本 | 建议方式 | 说明 |
|---|---|---|
| v1 官网 Notarized，macOS 26+ | 自有 CDN + 系统后台下载能力 | 唯一首发渠道；分片、断点续传、签名 manifest、原子切换和回滚为 required |
| 中国大陆 | 先测 Apple/CDN 真实表现，再决定镜像 | 不提前维护两套未经证明必要的基础设施 |
| 离线/内网 | 签名 `.afterraymodel` 导入包 | 同样验证 manifest 与每个 shard |

macOS 26 的 Background Assets 可作为下载实现候选，但 v1 不依赖 Mac App Store 专属的 Apple-hosted asset pack。官网版使用 AfterRay 有权分发的自有 CDN；若模型不允许再分发，只允许上游直下或本地导入。

### 13.4 完整性与回滚

1. 下载到 `.staging/<transaction>`。
2. 固定在 App 内的 root 公钥验证签名 catalog 与 manifest；catalog 包含单调递增 `generation`、`issuedAt`、`expiresAt`、`keyId`、撤销 digest 和最低 runtime ABI，并持久化已接受的最高 generation，防止镜像重放旧版本。
3. 每个 shard 校验 size + SHA-256。
4. 做一次最小模型加载和固定输入 sanity check。
5. 同卷原子切换 active pointer。
6. 新版成功运行若干次前保留旧版；低磁盘时允许删旧版，但明确回滚需要重下。
7. v1 不做权重二进制 diff；用 immutable shard/content addressing 复用相同文件。
8. 用户可以逐包删除，基础 Timeline 不因没有模型而不可打开。

需要可靠回滚的模型包使用不可变版本 ID，例如 `llm.gemma4.31b.mlx4.r3`。CDN 至少保留当前版和上一个已验证版；用户主动降级必须是单独、可审计的操作，并在 catalog 中显式允许。

下载前准确展示传输大小、安装大小、临时空间和当前可用空间。10GB 可用空间的用户可以装小包并使用，而不是被整套模型总大小挡住。

---

## 14. 本地 Agent 与外部生态

### 14.1 内置轻量 Agent

[Pi](https://github.com/earendil-works/pi) 的优势是小而可组合；风险是官方明确没有内置 filesystem/process/network/credential 权限系统，默认继承宿主权限。当前 `pi-agent-core` 是要求 Node runtime 的 JavaScript 包，因此“只禁用工具”不是 OS 级隔离。

v1 先做二选一 PoC：

1. 锁定 Pi commit 与 Node 版本，把 runtime 随 App 签名并放入无网络、无 Vault 文件权限的最小 XPC/隔离进程。
2. 用 Swift/Rust 实现等价的极小 agent loop，只复用 Pi 的设计思路和协议；这种实现不宣称“嵌入 Pi”。

只有第一条通过签名、Sandbox、崩溃和权限测试时，才采用 Pi agent-core：

```text
Pi agent-core
  → AfterRay model stream adapter
  → server-enforced read-only tools
  → evidence-cited response
```

明确禁用：

- read/bash/edit/write/grep/find/ls。
- 自动读取 `~/.pi`、项目 AGENTS.md、用户 Skills 和 extensions。
- npm 包安装和动态脚本。
- 网络 provider。
- 直接读取 Vault/SQLite/blob 文件。

内置工具先限制为：

```text
search_moments(query, from, to, apps, limit)
get_moment(moment_id)
get_transcript(moment_id, range)
get_day_summary(date)
```

预算在 Rust/Search 服务端强制执行：初始最多 8 个 Moment、单工具结果约 4K tokens、单轮总注入约 12K、最多 6 次 lookup round，并始终保留回答空间。数值是初始建议，需要模型测试校准。

### 14.2 外部 Agent

Hermes、Claude Code 等不复用内部 Pi session，只连接稳定的 AfterRay Context Gateway：

```text
External Agent → CLI/MCP → scope + approval + audit → Search/Vault
```

- 官网版优先 stdio CLI/MCP 或受限 Unix socket。
- 商店版不能默认向 `/usr/local/bin` 安装 CLI。优先验证 app-bundle 内 stdio helper 或受限 Unix socket；若必须使用 `127.0.0.1` HTTP，需要 incoming-network entitlement 和 App Review PoC。
- HTTP client 首次配对后获得独立 bearer capability，保存在 Keychain，通过 Header 传递而不是 URL/日志；token 可过期、轮换、撤销，每次工具调用重新校验 scope。Host/Origin 校验只是额外防护，不能代替 client capability。
- 默认 text-only、read-only，不提供资源全量枚举，不实现 MCP sampling。
- 每个 client 独立授权日期范围、App、内容类型、最大结果、有效期和最近访问。
- 截图和音频以后作为独立高敏感工具、独立审批。

### 14.3 用户审批

外部 Agent 第一次调用时展示：

> Claude Code 想检索 2026-08-01 至今天的 OCR 与 Transcript，最多返回 8 个结果，不包含截图和原始音频。

用户可以允许一次、允许 15 分钟或建立持久 scope。查询完成后可在访问记录中看到 client、时间、查询范围、返回 Evidence ID 数量；默认不记录完整查询文本的长期日志，是否保留需单独决定。

---

## 15. 隐私、安全与信任

### 15.1 v1 必须有的安全能力

即使不做 PII 模型，以下也不能延后：

- App/窗口排除列表。
- 随时暂停和明确录制指示。
- 锁屏、睡眠、用户切换时停止。
- AX secure value 永不读取；能可靠取得 bounds 时按用户选择的保护策略遮盖像素。无法可靠定位时不承诺自动敏感信息屏蔽，并依赖 App/窗口排除。
- 外部 Agent 默认 text-only + 预览 + scope。
- 一键删除某一天、某个 App、某次会议和全部 Vault。
- 所有后台计算默认无外网；只有 Model Download Service 能访问外部网络。Context Gateway 若启用 HTTP，只监听本机并仍视为本地 IPC 边界。
- 无遥测或极小、显式 opt-in 的产品遥测；绝不上传用户内容。

Apple App Review 2.5.14 要求记录屏幕、声音或用户活动时取得明确同意并提供清楚的视觉/听觉指示。菜单栏红色光点和一键暂停是产品核心，不是审核装饰。

### 15.2 Vault 加密建议

需做安全设计评审，当前建议：

- 每个 Vault 使用随机 Key Encryption Key（KEK）；Keychain 保存或包裹 KEK，并选择与“用户解锁后后台持续捕获”相容的 accessibility class。
- 每个图片、音频和文本 blob/segment 使用独立随机 DEK，DEK 由 Vault KEK 包裹；blob 使用经过验证的 AEAD（如 AES-GCM）并绑定 immutable metadata。这使选择性 crypto-shred 成为可能，但具体 key store 与 WAL 行为必须 PoC。
- 搜索索引同样是敏感数据，不能只加密截图而把 OCR/Transcript 明文留在 SQLite。
- 锁屏暂停后尽快清理可清理的明文缓存和模型上下文。
- FileVault 可以作为额外保护，但不能假设所有用户都已开启，也不能代替应用级 threat model。

如何兼顾加密索引、随机搜索、崩溃恢复和性能，是独立 PoC，不在本草案中假装已经解决。

选择性删除有两个状态：

1. **Logical deletion**：立即 tombstone、撤销 wrapped DEK、从 FTS/向量索引和所有可见查询中移除，并清理 Agent context/export cache。
2. **Physical deletion**：在有界后台 compaction 中重写仍存活的 immutable pack，原子切换索引，再删除旧 pack；同时覆盖 SQLite WAL、缩略图、派生摘要、临时音频和导出文件的删除范围。

UI 需要分别报告逻辑删除和物理空间回收是否完成。若无法证明 crypto-shred 和 WAL 清理正确，就不能把逻辑删除描述成“物理字节已清除”。

### 15.3 威胁边界

v1 明确防护：

- 电脑磁盘被离线读取。
- 外部 Agent 越权读取日期/App/内容类型。
- 被篡改模型包或镜像。
- Agent prompt injection 试图调用未授权工具。
- App 崩溃留下明文临时文件。

v1 不承诺防护：

- 用户已登录且拥有同等权限的恶意进程。
- 系统被 root/内核级攻破。
- 用户主动复制并发送给云模型后的数据使用。

---

## 16. 可执行需求（EARS）

下面的需求 ID 在实现和测试中保持稳定。

### 16.1 Onboarding 与 Visual Lab

- **ONB-001**：当用户首次进入 onboarding 时，系统应在单一 Permission Center 展示当前 build 所需的全部核心权限、用途、状态和系统设置入口。
- **ONB-002**：当用户开始权限审批时，系统应按固定顺序逐项请求 required permissions，并在每次返回 App 后重新读取真实系统状态。
- **ONB-003**：当任一 required permission 未通过时，系统应允许用户使用 mock Timeline，但不得启动或暗示真实捕获已启动。
- **ONB-004**：当全部 required permissions 通过时，系统才应把 onboarding 标记为完成，并进入录制范围与模型包设置。
- **ONB-005**：当系统要求重启 App 才能应用权限时，系统应保存 onboarding progress，并在重启后恢复到未完成步骤。
- **ONB-006**：当已授予权限之后被撤销时，系统应立即停止受影响的捕获并显示 repair checklist，不得循环触发系统请求。
- **ONB-007**：核心 onboarding 完成后，系统不得在普通 Timeline、搜索或总结流程中首次请求另一个未披露的核心权限。
- **VIS-001**：Visual Lab 应使用与正式 App 相同的 Timeline components、design tokens 和 shader 实现，但不得访问真实 Capture、Vault 或模型服务。
- **VIS-002**：每个 Visual Lab scene 应具有稳定 ID、固定 mock seed、可注入虚拟时钟、viewport 和可版本化 preset。
- **VIS-003**：当 Shot mode 使用相同 scene、preset 和 virtual-time script 时，系统应在同一参考硬件与 OS profile 上生成可重复比较的关键帧和 demo clip。
- **VIS-004**：每个核心 Timeline 场景应覆盖 normal、loading、partial、gap、redaction、Reduce Motion 和 stress 中适用的状态。
- **VIS-005**：当视觉 preset 被提升到 production 时，CI 应验证 preset schema、关键状态输出与轻量性能门槛；完整 Metal 性能测试在参考 Mac 上运行。

### 16.2 捕获

- **CAP-001**：当 Capture 已启用且未处于 PAUSED/SUSPENDED 时，若距上一个逻辑 checkpoint 已满 10 秒，系统应创建 heartbeat checkpoint；活动产生的 checkpoint 不受这个频率限制。
- **CAP-002**：当检测到用户输入活动时，系统应在最后一次活动后的 `settleDelay` 生成一次 capture candidate，并合并等待期内的其他活动。
- **CAP-003**：当活动持续超过 `maxActiveGap` 时，系统应生成 capture candidate，即使尚未出现完整 quiet window。
- **CAP-004**：当候选帧与上一持久化画面无有效变化时，系统应复用上一 blob，而不是重复写入图片。
- **CAP-005**：系统不得持久化按键、key code、输入字符、按钮、滚动量、鼠标路径、输入事件时间线或捕获触发原因。
- **CAP-006**：若用户开启 Cursor annotation，系统只应保存截图瞬间的单点位置。
- **CAP-007**：当显示器拓扑变化时，系统应创建新的 topology epoch，并阻止旧坐标映射到新拓扑。
- **CAP-008**：当锁屏、屏幕睡眠、用户 session 失活或捕获画面 blank/suspended 时，系统应暂停屏幕、音频和 AX 捕获。
- **CAP-009**：当捕获队列背压时，系统应优先提交 Moment 和音频临时落盘，并允许延迟或跳过 enrichment。
- **CAP-010**：当 thermal state 连续处于 critical 超过 `criticalGracePeriod` 时，系统可以暂停捕获，但必须在 Timeline 写入可见 health gap。
- **CAP-011**：当一次活动触发的候选帧完成且没有新活动时，系统应按可配置 cooldown curve 逐步恢复到 10 秒 checkpoint 间隔。
- **CAP-012**：当系统为某块显示器提交活动候选帧时，该帧 presentation time 应不早于 candidate trigger time；若超时无法取得新帧，应写入 gap 和 capture lag，而不是复用旧帧作为新证据。
- **CAP-013**：当 session 恢复 active、屏幕唤醒且所需权限仍有效时，系统应从 SUSPENDED 回到 IDLE，并结束对应 gap。
- **CAP-014**：当 thermal/backpressure 指标连续低于恢复阈值达到 `recoveryWindow` 时，系统应从 DEGRADED 回到进入降级前的活动状态。

### 16.2A Accessibility Snapshot

- **AXS-001**：当一个 Moment 需要持久化时，系统应对当时 frontmost App 的 focused window 完整遍历 AX subtree，不读取后台 App Tree。
- **AXS-002**：每个 AX Snapshot 应自包含全部节点，序列化后立即使用 zstd 独立压缩；解码不得依赖前一个 Moment。
- **AXS-003**：当 AX 遍历超过 1s 或目标 App 返回 `kAXErrorCannotComplete` 时，系统应保存已完整取得的节点为 `partial`，不阻塞截图落盘或后续 Moment。
- **AXS-004**：当 AX Snapshot 与截图的估算偏差不超过 2s 时，系统可将它绑定为该 Moment 的近似语义证据；超过 2s 时应标记 `unavailable`。
- **AXS-005**：当节点 subrole 为 secure text field 时，系统不得读取或持久化 value；若无法可靠取得其 bounds，应保留截图并标记 `secureBoundsUnavailable`，不丢弃整个窗口。

### 16.3 音频

- **AUD-001**：当用户已开启 `autoDetectedMeetings`、会议确认规则成立且权限有效时，系统应自动分别捕获系统音频与麦克风轨道。
- **AUD-002**：当原始音频年龄达到 30 天时，系统应立即将麦克风和系统音频轨 logical delete，并进入有界 physical deletion；Transcript 不应因此一同删除。
- **AUD-003**：当 ASR 队列落后时，系统应先把压缩音频写入受保护临时存储，不得只依赖内存缓冲。
- **AUD-004**：当权限未授予或输入源不可用时，Timeline 应明确显示该轨道缺失，不得生成推测 Transcript。
- **AUD-005**：当会议确认规则未成立时，系统不应开始音频捕获；仅“会议 App 正在运行”不得单独确认会议。
- **AUD-006**：当会议确认规则成立但用户未开启 `autoDetectedMeetings` 时，系统应保持音频关闭，仅提供手动开始入口。
- **AUD-007**：当自动录制开始时，系统应立即显示不抢焦点的“已开始记录”通知与一键停止入口。
- **AUD-008**：当用户选择“本次不记录”时，系统应立即停止并对当前 meeting episode 进入 `suppressed`，不得重新自动开始。
- **AUD-009**：当录音开始或停止时，系统应在 Timeline 记录明确范围边界，但不得把音频强度、VAD 结果或会议检测事件保存为通用用户活动日志。
- **AUD-010**：系统不应请求 Camera 权限或捕获摄像头画面。
- **AUD-011**：当会议结束强信号在 `meetingEndGracePeriod` 内持续成立时，系统应停止双轨采集并进入 `cooldown`；短暂的 UI 抖动不应切碎会议。

### 16.4 Timeline 与搜索

- **TIM-001**：当用户使用全局快捷键时，系统应打开最近时刻的可交互 Timeline。
- **TIM-002**：当用户改变缩放尺度时，系统应在 Moment、Session、Day、Month 数据层之间渐进切换，保持时间位置连续。
- **TIM-003**：当高质量画面尚未解码时，系统应先显示缩略图，完成后无跳位替换。
- **TIM-004**：当某个证据被回收、捕获失败或权限缺失时，系统应显示明确 gap/source state。
- **TIM-005**：当 AX snapshot 为 partial/timeout 或与画面存在偏移时，覆盖层应显示 completeness 和 skew。
- **TIM-006**：在 `TIM-PERF-PROFILE-v1` 规定的数据、设备、屏幕与缓存条件下，Timeline 应满足被冻结的 hotkey、seek 和 scrub 性能门槛。
- **SEA-001**：当用户发起搜索时，系统应融合精确/短语、子串、错拼候选和语义召回，并返回 Moment/Episode。
- **SEA-002**：每个搜索和 Agent 回答结果应包含可解析到原始时刻的稳定 Evidence ID。
- **SEA-003**：当结构化 App extractor 置信度不足时，系统应退回原始 OCR/AX Evidence，不得伪造 actor 或 direction。

### 16.5 存储与模型

- **STO-001**：当用户设置 10GB 或 20GB Vault cap 时，系统应允许启动捕获，不得因为未安装大模型而拒绝使用。
- **STO-002**：系统应分别展示 Capture Vault 与 Model Packs 的用量。
- **STO-003**：当 Vault 接近 cap 时，系统应通过整 pack 淘汰或 crash-safe compaction 回收物理空间，并保护用户明确收藏的 Moment。
- **STO-004**：使用满 7 个完整自然日后，系统应基于每日总写入量的 P95 预测保留范围；此前只显示带“初步估算”的保守范围，不使用固定宣传天数。
- **STO-005**：当 Free Timeline 证据年龄超过 30 天时，系统应自动进行 logical deletion 和有界 physical deletion。
- **STO-006**：当 Paid Timeline 证据年龄超过 30 天时，系统不应因年龄自动删除；达到 Vault cap 时应暂停新写入并请求用户处理空间，不得静默淘汰旧证据。
- **MOD-001**：当用户选择模型包时，系统应在下载前展示下载、安装、临时空间、最低/推荐内存和许可证。
- **MOD-002**：系统应只激活通过签名、hash、runtime ABI 和最小加载检查的模型版本。
- **MOD-003**：当新模型未通过激活检查时，系统应继续使用旧版本或无模型降级路径。
- **MOD-004**：当模型推理影响捕获、温度或内存时，系统应卸载/暂停模型而不是丢失核心证据。
- **MOD-005**：当 model catalog 的 generation 低于设备已接受的最高 generation、已过期或命中撤销 digest 时，系统应拒绝自动激活；用户主动降级必须经过独立确认和审计。

### 16.6 Agent 与隐私

- **AGT-001**：内置 Agent 只能调用 AfterRay 明确注册的只读工具，不得获得 shell、网络、用户目录或 Vault 文件权限。
- **AGT-002**：所有工具的结果数量、时间范围、内容类型和 token 预算应在服务端执行，不能只依赖 prompt。
- **AGT-003**：外部 client 第一次访问或扩大 scope 时，系统应展示具体权限并取得用户批准。
- **AGT-004**：Agent 生成的总结应区分证据事实、模型推断与建议。
- **AGT-005**：当本机 HTTP client 调用 Context Gateway 时，系统应在每次工具调用验证该 client 独立、可撤销的 bearer capability 与当前 scope；Host/Origin 不得作为唯一认证。
- **PRV-001**：当捕获正在运行时，系统应持续提供清晰可见的状态与一键暂停入口。
- **PRV-002**：当用户删除日期、App、会议或全部 Vault 时，系统应立即完成 logical deletion，并在有界后台任务中完成 physical deletion；UI 应分别报告 blob pack、FTS/向量索引、WAL、缓存、派生摘要、临时文件和导出的完成/失败状态。
- **PRV-003**：系统不得在默认状态下把截图、音频、OCR、Transcript 或 AX 内容发送到网络。
- **PRV-004**：当用户选择“复制给外部模型”时，系统应先展示即将导出的文本与范围；截图和音频不得默认加入。

### 16.7 边界场景

| 场景 | 应接受 | 应拒绝/降级 |
|---|---|---|
| 用户连续拖动 30 秒 | 每到 `maxActiveGap` 产生候选帧，最终 quiet window 再产生一帧 | 因 debounce 一直重置而 30 秒没有任何候选帧 |
| 用户在 Permission Center 拒绝 Microphone | 保留已通过状态，停在 checklist，并允许 mock Timeline | 跳进真实产品后在第一次会议时再次突然请求 |
| 会议 App 只在后台运行 | 保持 `idle`，等待前台窗口或 AX 会议控件等更强证据 | 一启动 Zoom/Teams 就弹窗 |
| 用户已开启自动会议记录，确认规则成立 | 自动开始双轨录音，立即显示“已开始记录”和停止入口 | 仍要求用户在会议中手动点击才开始 |
| 用户对当前会议选择“本次不记录” | 立即停止，删除未提交缓冲，本次 episode 不再自动开始 | 因窗口切换或 AX 抖动重复开始 |
| 会议 UI 短暂消失后恢复 | grace period 内继续同一次录音 | 立即停止并生成多个碎片 Transcript |
| Accessibility 被撤销 | 暂停新的真实捕获并打开 repair checklist | 静默降级为 screenshot/OCR-only |
| Visual Lab 运行 hero shot | 只使用生产 UI + deterministic mock data + virtual clock | 为了录制方便读取真实 Vault 或维护另一套假的 UI 实现 |
| 10 秒 heartbeat 到期但画面未变 | 创建 checkpoint 并引用上一 blob | 重复写入完全相同的图片文件 |
| 活动结束 300ms 后 stream 仍只有旧帧 | 等待下一张 `presentationTime >= trigger` 的完整帧或写 gap | 把操作前画面标成操作后证据 |
| 用户只有 10GB Vault 且不装模型 | Timeline capture/search 基础路径仍可启动 | 因所有可选模型总大小不足而拒绝使用 |
| 模型推理造成 thermal serious | 延后/卸载模型，保住证据路径 | 为完成总结而持续丢帧或丢音频 |
| AX partial 且 secure bounds 不可靠 | 保留截图、禁读 secure value，并标记 `secureBoundsUnavailable` | 丢弃整个窗口，或宣称 Secure Field 已经安全遮盖 |
| 外部 Agent 只获最近 7 天 OCR scope | 只返回范围内 text Evidence | 返回更早 Transcript、截图或 raw audio |
| 镜像返回签名正确但 generation 更旧的 catalog | 拒绝自动回退 | 因签名仍有效而静默降级 |
| 用户删除某次会议 | 立即不可搜索，并展示物理回收进度 | 只删 Timeline 行，仍可由向量索引或缓存查到 |
| Free 历史达到 30 天 | 删除超龄证据并明确展示截止日期 | 仍可搜索或由 Agent 读取超龄数据 |
| Paid Vault 达到磁盘上限 | 暂停新写入并要求用户扩容、导出或删除 | 为继续捕获而静默删除旧 Timeline |
| 原始音频达到 30 天 | 删除 mic/system raw audio，保留未超龄 Transcript | 因 Paid 身份永久保留 raw audio |
| 收藏内容已占满 Vault cap | 暂停新写入并要求扩容/取消保护 | 无限突破 cap 或静默删除收藏 |

当前 EARS 已做文字歧义审阅，但尚未转换成可执行有限状态模型。Week 1 在参数名与状态冻结后，应为 capture scheduler、model activation/rollback、授权 scope 和 logical/physical deletion 建立 TypeScript finite model；其反例进入回归测试。开放的商业与模型选择不适合用 solver 假装消除。

---

## 17. 必须跑的基准与验收门槛

### 17.1 AfterRay Screen Corpus

至少收集 2,000–5,000 张经明确授权的真实画面：

- IDE、Terminal、小字号代码、暗色/亮色。
- Slack、飞书、网页、PDF、表格、Figma。
- 视频会议、共享屏幕、动画和快速滚动。
- Retina、1x 外接屏、单屏/双屏、不同缩放。
- 中文、英文、中英混排和 emoji。

语料必须有人工文字框/文本真值子集，不把某个现有 OCR 的输出当 ground truth。

### 17.2 Capture 实验

变量：

- settle：200/350/500/800ms。
- max active gap：1/2/5s。
- cooldown：直接回到 10 秒、阶梯式和指数式。
- SCStream 2/5fps vs SCScreenshotManager。
- ScreenCaptureKit dirtyRects/idle gate vs 低分辨率视觉 diff。

指标：最终 UI 状态遗漏率、动画中间态比例、输入停止到最终帧 p50/p95、候选帧/小时、新 blob/小时、CPU/GPU/WindowServer、能耗与热状态。

### 17.3 编码实验

所有格式从相同 PixelBuffer 生成：

- PNG。
- PNG + zstd（逐帧与分块）。
- JPEG 多档质量。
- HEIF 多档质量。
- HEVC 硬件短分段，多档 keyframe duration。
- AVIF 只作能耗对照。

指标：平均/P95 bytes、编码/解码 p50/p95、峰值内存、Energy Impact、OCR CER/WER、box IoU、200% 小字可读性、1000 次随机 seek、崩溃和单块损坏的恢复范围。

### 17.4 ASR 实验

对所有 ASR 候选使用同一语料。若某候选需要独立 aligner 才能返回时间戳，aligner 的单段最长能力、切块边界和额外资源成本必须单独记录；不把 chunk 级范围与词级时间戳直接比较。

- 普通话、中英混说、粤语/常见方言。
- 本机麦克风、耳机、远场、系统会议音频。
- 回声、键盘噪声、多人重叠和音乐。

指标：中文 CER、英文 WER、混语错误、timestamp MAE、ASR 与 aligner 各自的实时因子、组合峰值内存、每小时能耗、长音频切块边界误差、稳定性与崩溃恢复。

### 17.5 Agent eval

至少覆盖：

- 找到某天某人说过的具体内容。
- 区分“我看到”与“模型推断”。
- 对一天目标完成情况给出证据。
- 遵循 JSON schema 和工具参数。
- 遇到屏幕 prompt injection 时不越权。
- 证据不足时明确说不知道。

每个候选模型记录成功率、引用准确率、tool-call schema adherence、响应时间、峰值内存、20–30 分钟会话稳定性。Week 0 先以无模型规则基线与系统框架基线为参照，冻结相对质量要求、资源上限和 Recommended 判定公式；在门槛冻结前只允许标为 Candidate/Preview。

### 17.6 低磁盘 Dogfood

在至少 16GB、24GB、36/48GB、64GB 四档设备上连续 7 天，覆盖 M3 Air、M3/M4 Pro/Max，分别测试 10GB/20GB、单/双屏、原始音频 30 天保留/转写后删除。输出真实 P50/P95 日写入量、保留天数、空间构成和预测误差。

---

## 18. 4–6 周验证计划

### Week 0：四项生死验证

1. **Notarized 完整版 + AX**：最小 Developer ID、Hardened Runtime 和 Notarization build 读取 Safari、Slack、飞书、Electron App 的可见 AX tree，验证首次授权、撤销、升级和重启恢复。
2. **签名模型运行时**：在无 Python、无 remote code 条件下，从签名 App 跑通 OCR、ASR、Embedding 固定输入 smoke test 和一个 Local Agent tool loop。Embedding 失败时，FTS/子串检索仍可上线。
3. **许可证/直发合规**：审核第三方库与模型的商业使用、再分发、Notice、签名更新、隐私文案和软件付费合规；不设计外部贡献流程。
4. **Permission Center**：在签名 build 中顺序验证 Screen Recording、Microphone、Accessibility、可选 Input Monitoring、Notifications 和 Launch at Login；覆盖首次允许、拒绝、System Settings 返回、重启恢复和权限撤销。

其中 AX 或 ASR 主路径失败时不发布所谓“精简 v1”，而是修正方案或推迟首发。FTS、编码和具体模型仍可在不改变产品承诺的前提下替换实现。

### Week 1：Capture + Timeline Skeleton

- 跑通多屏 ScreenCaptureKit、10 秒 checkpoint、activity signal、debounce/max-wait、锁屏暂停。
- 建立 Moment/VisualFrame/AX schema 和不可变 blob pack。
- 建立 `AfterRayDesignSystem`、`AfterRayTimelineKit`、`AfterRayMockData` 和 `AfterRayVisualLab.app` 的工程边界。
- 用确定性 mock data 做 Moment→Day→Month 金字塔、第一版连续 zoom 和可重放 hero shot。

### Week 2：编码、容量和回放

- 完成编码 benchmark harness。
- 对 2,000+ 截图跑 PNG/JPEG/HEIF 等对比。
- Timeline 支持缩略图优先、随机 seek、已回收 gap。
- 开始 10GB/20GB dogfood。

### Week 3：OCR、AX 与 Search

- 快速 OCR、Deep OCR 与系统基线在真实屏幕语料上对比。
- AX snapshot 的 complete/partial/unavailable 状态、1 秒截止、2 秒对齐规则和覆盖层正确性；不再安排 AX 耗时基准。
- SQLite FTS/trigram + Embedding 原型；建立 100–300 条真实查询集。

### Week 4：Audio/ASR

- 建立 meeting detector：已知 bundle ID、frontmost/window 和 AX 会议控件的确认规则。
- 实现 `possible → confirmed → recording/suppressed → cooldown` 状态机、反误启动与会议结束 grace period。
- 系统/麦克风双轨、VAD、压缩临时流。
- ASR 候选在同一 Audio Corpus 的基准。
- 原始音频 30 天删除流程和崩溃恢复。

### Week 5：Local Agent 与外部接口

- Pi agent-core 或等价极小 loop，只给四个 lookup tools。
- Local Agent 候选按硬件档位跑 AfterRay eval。
- CLI/MCP scope、审批、Evidence ID 和访问记录。

### Week 6：整体验收与发布决策

- 7 天 dogfood 结果、能耗、热状态、保留预测。
- 模型包 2GB/20GB 的断网、睡眠、退出、低磁盘、升级、回滚、删除测试。
- 冻结 Stable/Preview/Labs 矩阵。
- 验收官网直发版的签名、Notarization、更新、模型 CDN 和许可证清单。

这 6 周是技术与产品验证，不应包装成“6 周即可完成正式 v1”。验证完成后再估算可发布版本的工程周期。

---

## 19. 开放问题与建议方向

### 19.1 已关闭的开放问题

| 决策 | 结论 |
|---|---|
| Permission onboarding | 所有核心权限在同一次 onboarding session 中顺序完成；不在日后功能使用时制造意外弹窗 |
| 视觉迭代工具 | 原生 `AfterRayVisualLab.app` 是视觉 source of truth；Xcode Preview 做单组件，Web 只做概念探索 |
| 10 秒语义 | 10 秒创建逻辑 checkpoint；画面未变时复用上一 blob |
| 磁盘门槛 | 10GB/20GB 均可使用；Capture Vault 与 Model Packs 分账 |
| 模型交付 | App 安装后按能力包下载，不把大模型权重塞进基础安装包 |
| 首发渠道 | 只发布 Developer ID + Hardened Runtime + Notarization 的官网完整版；MAS 不进入 v1 |
| 最低系统 | macOS 26 |
| Accessibility | 真实捕获的 Required 能力，不提供 OCR-only 降级版 |
| 源码与贡献 | v1 完整源码公开，默认 FSL-1.1-ALv2；Developer Preview 暂不接受外部贡献 |
| 免费/付费主边界 | Free Timeline 滚动保留 30 天；Paid Timeline 不按年龄自动删除 |
| 原始音频 | mic/system 双轨默认保留 30 天，Transcript 按 Timeline 权益保留 |
| 默认音频范围 | 用户在 onboarding 同意后，自动记录稳定检测到的会议；平时不录音 |
| AX Snapshot | 每个 Moment 完整遍历前台 focused window；2s 最大对齐偏差；每份独立 zstd 压缩；不做增量 Tree |

### 19.2 需要创始人尽快决定

这些问题无法靠 benchmark 自动回答，会改变产品承诺、仓库或渠道：

| 编号 | 问题 | 当前建议 | 最晚决定 |
|---|---|---|---|
| F-09 | Paid 到期或退订后，30 天以前的历史怎么处理？ | 不立即删除；先进入不少于 30 天的宽限/导出期，详细规则在定价时冻结 | 定价前 |

### 19.3 由产品/设计实验决定

| 编号 | 问题 | 当前假设 | 决策证据 |
|---|---|---|---|
| X-01 | Month 视图的主视觉是星图、密度河流还是二维日历？ | 星图/密度场优先，传统日历只作定位层 | Visual Lab 的找回速度与传播素材测试 |
| X-02 | Zoom anchor 跟随鼠标、当前选中 Moment 还是屏幕中心？ | 鼠标/触控点为 anchor，键盘操作使用选中 Moment | 手势可控性和迷失率测试 |
| X-03 | Month/Day 远景是否显示可识别截图？ | 默认抽象化/模糊，进入 Session 后再清晰，降低旁观泄露 | 可读性、隐私与 wow moment 测试 |
| X-04 | 默认捕获所有显示器还是焦点显示器？ | 所有显示器逐屏去重 | 双屏能耗、空间与找回成功率 |
| X-05 | 光标单点默认记录吗？ | 默认关闭或明确 opt-in | 找回价值与隐私感受测试 |
| X-06 | 200–500ms 的最终 settle、max-wait 和 cooldown curve？ | 350ms + 2s max-wait + `1→2→5→10s` 作为首组 | Capture corpus 的遗漏率、动画中间态和能耗 |
| X-07 | 独立帧最终使用 HEIF 还是 JPEG？ | 两者都不预设赢家，PNG 只作无损基线 | bytes、OCR 重跑质量、seek、能耗 |

### 19.4 由技术 PoC/eval 决定

| 编号 | 问题 | 当前建议 | 最晚决定 |
|---|---|---|---|
| T-01 | 16GB 是否支持，还是最低 24GB？ | 16GB Capture Lite；24GB 为完整推荐 | Week 2 dogfood 后 |
| T-02 | 常驻低帧率 SCStream 还是单次截图？ | 先测低帧率 SCStream | Week 1 |
| T-07 | 直接运行 Pi/Node，还是 Swift/Rust 小 loop？ | 只有 Node/XPC 隔离 PoC 通过才直接采用 agent-core | Week 5 |
| T-08 | Vault 加密索引与选择性删除如何实现？ | wrapped per-blob DEK + logical delete + bounded compaction 候选 | Week 3 |
| T-09 | 外部 Agent 查询日志保存多少？ | 默认只存 client、scope、时间与 Evidence 数量，不存完整 query | 安全评审后 |
| T-10 | 会议确认规则和 adapter 覆盖是什么？ | 先支持 Zoom、Teams、飞书、腾讯会议、企业微信、Slack Huddle、FaceTime 与主流浏览器会议；进程迹象不可单独确认会议 | Week 4 |
| T-11 | 会议结束 grace period 多长，哪些信号可以自动停止？ | 以 AX 结束控件/窗口消失 + App 状态组合，先测 10/30/60s | Week 4 |

### 19.5 可以明确推迟到 v1 之后

- 实验模型从 Labs 晋升 Stable。
- 多远端说话人 diarization。
- PII 模型与自动跨截图脱敏。
- iOS/P2P、多平台 UI、Enterprise 和自动外部动作执行。

---

## 20. 商业、源码与分发约束

**已决定（2026-08-14）**：v1 公开完整产品源码。除目录或文件另有声明外，使用
FSL-1.1-ALv2：允许审查、自己编译、内部使用、修改和许可范围内的再分发；限制把当前源码作为面向他人的商业竞争产品或服务提供。每个公开版本在首次提供满两年后自动获得 Apache-2.0 许可。当前阶段应准确称为 **source-available / Fair Source**，不能称为 OSI Open Source。

协议与公共 SDK 使用 Apache-2.0；官方 Agent Skills 使用 MIT，并在各自目录放置独立许可证。AfterRay 名称、Logo 和官方构建身份不随源码许可授权。开发者预览阶段暂不接受外部贡献；开放 contribution 前需先确定贡献者协议和商业授权所需的再许可边界。

更可持续的付费理由应是：

- 官网版的 Developer ID 签名、Notarization、自有支付与安全更新。
- 零配置权限引导、稳定捕获和精致 Timeline。
- 经评测、可回滚、许可证清楚的模型包。
- iOS companion、端到端加密 P2P 和多设备体验。
- 长期兼容 macOS、模型与外部 Agent 生态。
- 优先支持、Labs 入口和可信品牌。

创始人 IP 很适合做分发引擎：公开构建过程、真实能耗/隐私取舍、视觉 demo 和模型 benchmark 会建立信任。但创始人 IP 不是产品护城河，也不能替代一个值得每天打开的复盘闭环。

公开源码是信任证据之一，但不能替代可验证的产品边界：默认无网络数据外发、公开 threat model、签名模型 catalog、可审计的 Agent scope、可验证删除、真实 benchmark、明确的隐私指示，以及官方二进制到源码 commit 的构建来源证明。

用户自己编译和运行源码是许可允许的正常路径，不按盗版处理。商业模式不能依赖阻止本地自编译，而应主要依赖官方签名构建、安全更新、可选服务、支持、企业能力和商业/OEM 授权。FSL 只限制面向他人的商业竞争使用；它不应被描述成能够阻止所有免费 fork。

### 20.1 v1 直发渠道

| 项目 | v1 决策 |
|---|---|
| 二进制 | Developer ID + Hardened Runtime + Notarization |
| 更新 | 自有签名更新渠道，支持验签、回滚和强制最低安全版本 |
| 数字功能付费 | 官网支付与自有 license；Free 30 天、Paid 无时间到期已冻结，价格与买断/订阅后定 |
| 模型权重 | 有再分发权时使用自有 CDN；否则上游直下/签名导入 |
| Accessibility | Required；在 notarized build 中做完整权限与恢复测试 |
| CLI/MCP | stdio CLI、Unix socket 或受控 localhost，所有 scope 可撤销 |
| 源码 | 公开；默认 FSL-1.1-ALv2，每个版本两年后转 Apache-2.0 |
| 开放接口 | Protocol / SDK 为 Apache-2.0；官方 Agent Skills 为 MIT |
| 外部贡献 | Developer Preview 暂不接受；开放前确定 contribution/CLA 规则 |

每次 release 至少检查：

1. 代码签名、Notarization、自动更新签名与安全回滚。
2. 所有第三方许可证、NOTICE、模型许可与修改声明。
3. 默认无外发网络路径、Agent scope 和本地 IPC 边界的回归测试。
4. 权限申请、隐私文案、录音指示和删除行为与当期实现一致。

### 20.2 信任与分发漏斗

视觉、GitHub 和创始人内容应形成一个漏斗：

```text
10 秒 Timeline zoom 视觉片段 → 想试
公开架构、隐私承诺、benchmark → 相信
官方签名零配置版本 → 安装与付费
每日/每周复盘产生真实价值 → 留存与口碑
```

- 社媒首发资产：Month→Moment 连续缩放、一次会议的 Screen/Transcript/AX 三层展开、10GB 仍可用的实时容量预测。
- GitHub 发布完整源码、threat model、模型/编码 benchmark、可复现能耗结果、公开 roadmap 和与 commit 对应的官方构建。Developer Preview 可以暂不开放 contribution 入口，但 issue、构建说明和许可证边界必须清楚。
- 创始人内容：持续解释真实技术取舍和 dogfood 结果，不把隐私承诺做成抽象口号。
- 每个公开视觉 demo 都要能在实际产品中复现，避免只做无法交付的概念视频。

Alpha 期间至少观察：首日完成权限与第一次回拉的比例、Timeline/复盘每周主动打开次数、首次找回成功率、模型包安装完成率、暂停/排除/删除使用情况、D7/D30 留存和付费意愿。数值目标应在首批 20–50 名设计伙伴数据后冻结，不能现在拍脑袋填写。

---

## 21. 研究依据与置信边界

核心一手资料：

- Apple ScreenCaptureKit：[Capturing screen content](https://developer.apple.com/documentation/screencapturekit/capturing-screen-content-in-macos)、[dirtyRects](https://developer.apple.com/documentation/screencapturekit/scstreamframeinfo/dirtyrects)
- Apple 隐私指示：[Use Control Center on Mac](https://support.apple.com/guide/mac-help/use-control-center-mchl50f94f8f/mac)
- Apple App 运行状态：[NSWorkspace runningApplications](https://developer.apple.com/documentation/appkit/nsworkspace/runningapplications)、[didLaunchApplicationNotification](https://developer.apple.com/documentation/appkit/nsworkspace/didlaunchapplicationnotification)
- Apple 活动时间 API：[CGEventSourceSecondsSinceLastEventType](https://developer.apple.com/documentation/coregraphics/cgeventsource/secondssincelasteventtype(_:eventtype:))
- Apple 签名与公证：[Notarizing macOS software before distribution](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)
- Apple 模型资产分发：[Creating managed asset packs](https://developer.apple.com/documentation/backgroundassets/creating-managed-asset-packs)、[Apple-hosted asset limits](https://developer.apple.com/help/app-store-connect/reference/app-uploads/apple-hosted-asset-pack-size-limits/)
- Pi Agent：[official repository](https://github.com/earendil-works/pi)
- SQLite FTS5：[official documentation](https://www.sqlite.org/fts5.html)

模型研究与候选列表按用户要求在产品讨论中单独维护，不进入本 Spec。任何时效性事实仍优先以模型作者的官方模型卡、官方仓库与 AfterRay 自有测试交叉核验。

---

## 22. 下一步决策建议

首发渠道、系统、AX、源码和音频触发边界已经冻结。下一轮不要先定“最终模型清单”，而是完成三件事：

1. 用一周完成 Week-0 notarized AX、签名模型、Permission Center 和直发许可证四项 spike。
2. 同时做一个只使用假数据的 Timeline 视觉原型，验证从 Month 到 Moment 的核心 wow moment。
3. 用 mock scene 和小型真实 dogfood 跑通 meeting possible → confirmed → 自动录音 → 自动停止，同时建立 AfterRay 自有 Screen/Audio/Agent eval。

v1 的实现顺序应是：

```text
Timeline visual prototype
→ reliable capture + Vault
→ OCR/Transcript/Search
→ Daily Reflection
→ restricted Local Agent
→ external Agent ecosystem
```

这是一个 Context Layer 产品，但用户首先感知到的必须是 Timeline；Agent 是让这份长期记录每天产生价值的第二个闭环。
