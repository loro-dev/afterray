# 搜索呈现

搜索原本是召回体验里的二等公民：结果是右上角一列文字摘要，用户要读文字、猜哪条是自己要的、点一下才跳过去；跳过去之后画面上没有任何东西告诉他"命中的字在这里"。底部时间轴按 App 涂色，浏览一天很好用，但和结果集完全脱节。

这次把搜索做成一条完整的动线：

**输入 → 回车 → 落在最新的一次命中 → 渐变结束后高亮闪烁命中的字 → 底部缩略图胶片条在所有命中之间来回滚动**

方向上对齐 `afterray-v1-spec.md` §5.3（可切换的 OCR 证据层）和 §11（结果是 Moment 而不是散文本）。

---

## 1. 窗口标题进入搜索范围

标题一直在采集（AX API，CGWindowList 兜底）并存进 `moments.window_title`，但 `evidence_fts` 只索引 `text_evidence.text`，所以搜不到。

做法是在 `Vault::attach_accessibility_snapshot` 里补写一条 `source = 'window'` 的合成证据行（`crates/afterray-store/src/lib.rs`）。这样标题直接复用现有的 FTS、RRF 融合排序、`openMoment` 全套管线，没有第二套索引要维护。有 URL 时换行追加 —— 浏览器地址栏经常是隐藏的，URL 是屏幕上根本不存在的高信号文本。

**去重是必需的，不是优化。** 采集每 10s 一帧，而一个窗口通常一待就是几分钟。不去重的话一天会写进 8640 条相同标题，把索引彻底淹掉。判据是"本 session 最近 10 分钟内是否已记录过同样的文本"（`WINDOW_TITLE_DEDUPE_MS`），这同时也收敛了 A↔B 窗口反复横跳的情况。schema 11 为此加了 `text_evidence(session_id, source, started_at_ms)` 索引，否则这个每 10s 一次的查询是全表扫描。

左上角的 `AppIdentity` 胶囊相应变成两行：App 名在上，窗口标题在下。一天泡在同一个编辑器里，App 名什么都区分不了，标题才是。

---

## 2. 缩略图层

### 为什么必须在打包前生成

**`afterray-codec` 能编码 AV1，不能解码**（解码在 Swift 的 `RecallAV1Decoder` 里，走 VideoToolbox）。一旦 `drop_unpinned_stills` 把 JPEG 删掉、帧只活在冷 GOP 里，Rust 侧就再也拿不回像素了。

所以缩略图不能纯做成"按需惰性生成"。三条路径按优先级：

1. **已缓存** → 直接返回 `image/jpeg`
2. **热帧还有 JPEG** → `still_thumbnail` 生成、存下、返回
3. **本功能上线前就已打包的历史冷帧** → 回落到 `read_gop_frame(…, Exact)`，原样返回 IVF，由客户端解码降采样

第 3 条是纯粹的存量数据补丁。`gop_packer::encode_run` 在 JPEG 还解密在手时就顺手生成缩略图（失败只记日志，绝不让打包失败），所以新数据永远走不到那里，这条回落路径会随存量老化而自然枯竭。

**用 `Exact` 而不是 `Poster`。** Poster 是 GOP 关键帧，内容不是命中的那一帧 —— 在搜索结果里给错图是误导，值得付客户端最多解 30 帧的代价，而且只付一次（之后进客户端缓存）。

### 存储

`moments.thumbnail_artifact_id`（schema 12），走和其他 artifact 一样的加密路径 —— 缩略图是屏幕内容，不能明文落盘。长边 360px（约 Retina 截图的 10%），JPEG 质量 62，体积远低于原图 1%。

`drop_unpinned_stills` **不碰**这一列，这正是整个设计的支点。删除路径（`delete_moment_and_artifacts`、`enforce_retention`）都要回收它。

### 客户端缓存

`RecallThumbnailCache` 和 `RecallDecodedImageCache` **刻意分开**：一条二十几格的胶片条绝不能把召回视图马上要用的全分辨率帧挤出那个 48 帧 / 1.5GB 的缓存。

---

## 3. 结果集是帧，不是证据行

daemon 返回的是排过序的散证据行，一帧可能命中好几次（OCR 文本 + 窗口标题 + 转写）。`RecallSearchSession.make` 按 `moment_id` 折叠成 `SearchFrame`，**按时间从新到老排**，默认选中第 0 个。

从新到老是刻意的：召回几乎总是"我刚才在看的那个东西"，最新的命中就是最有用的默认值。

计数器因此要报两个数：`3/24` 是帧位置，`31 matches · 24 frames` 是总量。二者不等就是折叠发生了。

`moment_id` 为空的 hit 直接丢弃 —— 那是没有前序帧的转写证据，打不开，就不算结果。

---

## 4. 高亮时机

OCR bounding box 早就随 `text_evidence.layout_json` 持久化了，`evidence_ocr` 接口也一直在，只是 Swift 侧连类型都没有。这部分零 Rust 改动。

两处几何必须做对，否则框会落在错误的字上（`OcrHighlight`，有单测）：

1. 画面是 `.resizeAspect`，所以先算 letterbox 内容矩形 —— 框是相对**图片**的，不是相对视图的
2. Vision 的单位方框**原点在左下**，SwiftUI 在左上，y 轴要翻转

**门控在 `RecallStillPlayer.settled`。** 这个 `@Published` 在 `installBase` 和 `promoteIncomingToBase` 赋值 —— 正是一帧变成满不透明 base 的两个时刻。覆盖层只在 `settled.id == selectedMoment.displayCacheKey` 时渲染，所以框永远不会画在渐变到一半的画面上（那会指向错误的像素）。

匹配不上任何 region 时**不画框**。规范 §5.3 的原话是不要画出看起来很确定但其实不确定的框 —— 高亮的全部意义就是指出命中在**哪里**，指错了比不指更糟。

节奏：3 次脉冲后停在持续可见状态。框是查询的答案，不是一闪而过的通知。`accessibilityDisplayShouldReduceMotion` 为真时跳过脉冲直接进入持续态。

---

## 5. 胶片条

只在搜索态替换底部时间轴，`searchSession` 为 nil 时 `RecallView` 照常渲染 `AppUsageTimeline`。

**布局照抄 `AppUsageTimeline` 的成熟做法**：固定居中的 playhead + 把内容整体 offset。这样 timestamp 胶囊（绝对时间）直接复用，也不用和 `ScrollWheelMonitor` 抢事件。

**等宽格子，刻意不按时间比例。** 搜索结果是离散列表 —— 三秒前的命中和上周二的命中同样值得看一眼，凭什么后者只配一个像素。时间信息交给格子下方的相对时间戳（`NOW` / `5M` / `3H` / `2D` / `6W`）承担，一排完整时间戳是没人会读的数字墙。

**联动是白拿的。** 选中格子 → 改 `playheadMs` → `ImmersiveArtifactImage` 重新请求 → `RecallStillGate` 跑它本来的交叉渐变 → settle 后高亮层重新武装并闪烁。计数器因为读的是 `searchSession.selectedIndex` 也自动同步。为需求"滚动时同样触发渐变和高亮"写的新代码是零行。

顶层的拖拽、滚轮、方向键在搜索态全部改道走整格步进，让整个画面都在结果之间擦洗而不是在墙钟上擦洗。触控板精确滚动要累积到整格（`searchScrollPointsPerCell`），否则一次轻扫会直接飞过十几条结果。

---

## 破坏性变更

`PROTOCOL_VERSION` 5 → 6。daemon、app、`afterray-cli` 必须一起重建，否则 `DaemonClientError.protocolMismatch`。`scripts/run-v0.sh` 会全量构建。

Schema 10 → 12（11 = 窗口标题索引，12 = 缩略图列），两步都是纯增量，不重建表。

## 验证

- `cargo test --workspace` / `swift test` / `scripts/verify-gop-e2e.sh`
- Visual Lab 的 `Search` 场景（`make dev-ui`）：交互式检查
- **`make snapshots`**：离屏渲染 PNG，不启 daemon、不申请权限、不在屏幕上开窗

### 为什么需要离屏快照

单测能覆盖 `OcrHighlight`、`SearchFilmstripLayout`、`RecallSearchSession` 的数学，但覆盖不了 SwiftUI 的渲染语义。这一轮快照抓到了两个纯逻辑测试不可能发现的问题：

1. **`.mask()` 用在 `.offset()` 之后，会锚定到偏移前的布局 frame。** 边缘渐隐因此遮住的是空白区域，把真正的格子抹掉了 —— 结果少时整条胶片条完全消失，结果多时右侧被静默截断。修法是把渐隐作用在一个视口尺寸的容器上，而不是作用在被偏移的那一行上。
2. **时间戳文本没有显式前景色。** 依赖继承的配色方案，在任何没有把 dark appearance 传下来的宿主里都会渲染成黑底黑字。覆盖层永远画在深色内容上，所以直接写死 `RecallPalette.textPrimary`。

已知盲区：全分辨率画面由 `AVSampleBufferDisplayLayer` 绘制，不走 `cacheDisplay(in:to:)`，所以 chrome 快照里画面是空的。`highlight-*` 那几张场景专门补这个洞 —— 它们画真实的 mock 帧，并用**同一套** `OcrHighlight` 数学摆放框，覆盖 letterbox 的三个分支（上下黑边、左右黑边、精确贴合）。
