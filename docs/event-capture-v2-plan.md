# 事件驱动采集 v2 计划

> **Status (updated 2026-08-20): historical plan. The code is the authority.**
> Current behavior: [context/event-capture-v2.md](../context/event-capture-v2.md)（tree_text、diff 链、输入词汇表、secure 护栏、截图落点）与 [context/acts-join.md](../context/acts-join.md)（两条事实流如何 join）；保留期见 [tiered evidence retention](decisions/active/architecture/2026-08-27-tiered-evidence-retention.md)。
>
> Superseded by the code on these points — the body below still states the original intent:
> - §5「废除 `PROMPT_LINES_BUDGET_CHARS` 固定常量」→ 常量健在，且是时长缩放的基线与下限；模型窗口只作上限，`crates/afterray-store/src/slot.rs:153`
> - §1「一张截图被其后窗口内的多个 AX 捕获共享（`screenshot_id?`）」→ 全仓无 `screenshot_id`；无截图的 moment 因此不存在，可引性落成按 run 的 `unframed_lines` 计数，`crates/afterray-store/src/slot.rs:404`
> - §1「节流/抑制计数（shim 已有 `dropped`）进 segment metadata 并最终进卡片」→ shim 报的 `dropped` 止于 daemon 的一行 stderr 日志，不入库、不进 metadata、不进卡片，`crates/afterrayd/src/main.rs:2395`
> - §6 元素级引用只落了 prompt 半边（`crates/afterray-store/src/slot.rs:2851`）；渲染半边不存在 —— moment id 的字符类不含 `#`，`![…](afterray://moment/<id>#el33)` 匹配不上引用正则，转而被判为「没写完的引用」原样输出，`swift/AfterRayRecall/Sources/StreamingMarkdown.swift:183`
> - §2/§3 的 `drag` 与 `window_changed`：shim 发这两种 kind（`apps/AfterRayCaptureShim/Sources/AfterRayCaptureShim/main.swift:1923`、`:2071`），acts join 无对应分支，两者落到 `ActKind::Other` 后被 `fold_acts` 丢弃，`crates/afterray-store/src/acts.rs:570`
> - WS7（语料回归）未建：`scripts/t2-eval.py` 按 v2 卡片的 `threads` / `entities` 形状打分，认不出 v3 正文，`scripts/t2-eval.py:105`
>
> 代码侧一处尚未对齐（不是本文的主张）：`captureEdgeSnapshot` 仍以「事件 48h 删、帧长存」论证它绝不触发截图，`apps/AfterRayCaptureShim/Sources/AfterRayCaptureShim/main.swift:2120`。shim 确实不拍（截图是纯拉取式），但那个理由所依赖的 48h 事件寿命已不存在，且事件驱动截图由 daemon 提供（`crates/afterrayd/src/main.rs:1463`）。

> 状态：已批准（2026-08-18 拍板），实施中。
> 依据：对同类产品 Skysight 的实测逆向 —— 144 个 10 分钟 segment（~24h、1,355+ 事件抽样统计）与 207 份产出文档。每个数字都来自实测，不是设想。
> 关系：部分取代 [`input-events-and-t1-acts-plan.md`](./input-events-and-t1-acts-plan.md)（R3 边沿快照被 keyframe 策略吸收；acts 的 `typing` 布尔方案被 `text_input.value` 取代）；修订 [`slot-summaries-and-ax-pipeline.md`](./slot-summaries-and-ax-pipeline.md) §7.1 的 CAP-005（见下）。

## 信任模型变更（2026-08-18 拍板）

**CAP-005 的击键内容禁令取消。** 理由：全部处理在本地模型完成，vault 端到端加密，数据不出机器，出境需用户显式批准 —— 原禁令针对的"内容离开信任边界"场景不存在。随之：

- `text_input` 事件可存键流原文与输入框 value；
- 事件触发的截图记录真实时间戳（时序暴露在本地信任模型内可接受，节流网格已把它降为相位信息）；
- 事件/diff/keyframe 的保留期与 vault 现有策略统一，48h 特殊通道只留给运行标记（tap 活性 gap）。
- **唯一保留的护栏：焦点在 `AXSecureTextField` 时键流与 value 皆不采**（密码本地也不存）。凭据检测（CAP-011）不变。

## 实测依据（逐条对应设计决定）

| 实测 | 数字 | 导出的决定 |
|---|---|---|
| 附树按事件分级 | submit 31/31、click 149/157、window.changed 130/135 附树；text_input 0/195、selection 0/86 不附；shortcut 17% | §3 附树分级照抄 |
| fullTree 几乎只在窗口切换 | 130/140 挂在 window.changed，120/140 伴随 app 切换 | keyframe=窗口切换，即原 R3 的"scope 切换"，R3 由此泛化 |
| diff 极小 | ax 文本中位数 913 B、p90 21 KB（对比我们整树 ~200 KB/帧） | 增量编码是存储与 prompt 双重胜利 |
| 中文键流是拼音碎片 | 1,796 个 text_input 零中文（`'wsm tongyini'`） | **内容主通道 = 事件时刻的 target.value**（451 处含中文）与 AX diff（789 处）；键流仅辅助 |
| text_input 按停顿合并 | 相邻中位 3.0s，每块中位 5 字符 | 词级合并（~2s 停顿切块） |
| drag 带两端 | source+destination 各含 app+element+window | 拖拽 = 跨元素因果边，与 ⌘C→⌘V 链同构 |
| 抑制是常态且声明 | 108/144 segment 有 suppressedEventCount（24h 共 688） | 节流计数进 metadata 与卡片 |
| 编号跨快照漂移 | 966/2,073 label 编号不稳定 | 元素引用必须锚定单帧 |
| 产出五段骨架 207/207 一致 | 中位 6.4 KB，p90 8.2 KB；最短 1.7 KB（登录窗时段，如实写两个事件） | §5 输出契约；叙事/编年分离是防硬凑的结构机制 |

## 设计

### 1. 节奏：事件驱动为主，心跳兜底

- 触发源 = tap 事件（click / submit / shortcut / text_input / drag / 窗口切换 / scroll〔我们保留，它无此项〕）。
- 无事件时心跳 10s 一拍（深读场景兜底）。
- **截图独立节流**：事件可触发，≥10s 间隔；一张截图被其后窗口内的多个 AX 捕获共享（`screenshot_id?`）。**无截图的 AX 时刻不可出图级引用，此事实写进 T2 prompt。** **[已推翻 → `crates/afterray-store/src/slot.rs:404`]**
- 配对不变量方向不变：截图必有 AX；AX 可无截图。
- 节流/抑制计数（shim 已有 `dropped`）进 segment metadata 并最终进卡片。 **[已推翻 → `crates/afterrayd/src/main.rs:2395`]**

### 2. 事件词汇表 v2

`window.changed / mouse.click / mouse.drag / keyboard.text_input / keyboard.submit / keyboard.shortcut / selection.changed / scroll`

- **text_input**：按 ~2s 停顿合并成词级块；载荷 `{text: 键流原文, target:{role,label,value}}`。value 是主内容通道（中文唯一可靠来源）；secure 焦点时两者皆不采。
- **submit**：Return/⌘Return 等提交键时刻读 focused element 的 value（截可见区并内联标注 `[truncated to visible range]`）。语音/粘贴/AI 补全的内容归因由此一次解决。
- **drag**：记录 source 与 destination 两端的 app+element。
- 现有 burst 计数保留为聚合统计；`typing:true` 方案作废。

### 3. 附树分级（照抄实测）

| 附树 | 不附树 |
|---|---|
| submit、click、drag、context_menu、window.changed | text_input（value 已在事件里）、selection、scroll |
| shortcut：节流附树（~17%） | |

### 4. AX 文本表示与 diff

- 走树仍限窗口 + 菜单跳过 + 时间盒（已有），输出改为**带编号缩进文本**：`33 button (collapsed) 更多操作 归档会话`。
- 人话角色词（standard window / container / button / tab / HTML content…）；属性内联（`URL:` `Description:` `Value:`）。
- 折叠：无文本后代的容器链缩成一行 `(collapsed)` 保留 label。
- **keyframe 策略**：窗口切换发全树；其余附树事件发 `diffFromPrevious`。
- diff 表示：`+` 新增、`~` 变更（带祖先上下文行）、删除合并为 `Removed element IDs: 97-100, 103-137`。
- 计算：对前帧行序列做树对齐（role+label 匹配，兄弟序 tie-break）。
- `digest_fingerprint` 判静止则不发；keyframe 间链长封顶 30 步，超限强制 keyframe。

### 5. 输出契约（T2 卡片 v3）

- 载体：**frontmatter + Markdown**，不是 JSON —— 实测长 Markdown 塞 JSON 字符串时 4b 跑飞、9b 转义炸卡、35b 烧穿轮数；换载体后 4/4 模型格式有效。
- frontmatter：`title` / `description`；`applications` 由 facts 直接填，模型不写。
- `threads/entities/decisions/category/confidence` 全部废除。
- details 内部按五段骨架给 **prompt 级指导**（非 schema）：叙事结论 → 上文延续（prev-card 的 title+description 直接注入，废除 `get_prev_cards` 工具）→ 标识符词汇表（带定义的 prose 行：`` `session/458abe37` ``: PR #3428 的 head 分支）→ 编年证据段（带时间戳）。
- 深度跟证据走：无目标小节数；安静时段骨架不变、如实写短（实测范本：登录窗时段 1.7 KB）。
- 预算：废除 `PROMPT_LINES_BUDGET_CHARS` 固定常量 **[已推翻 → `crates/afterray-store/src/slot.rs:153`]**，改由 `resolve_context_budget()`（真实模型窗口 × 机器可负担）推导，保守 2.5 B/token，下限 12k 字符，上限先设 4× 现值的天花板待语料评测放开。`more_chars` 留作如实告知，删除取用邀请与 `get_run_text` 依赖。
- 工具目录按证据裁剪：无音频的 slot 不出现 `get_transcript`（实测 35b 为此浪费整轮）。

### 6. 元素级引用

- `afterray://moment/<id>#el<N>`，N 按**该帧**树文本的编号解析（编号跨帧漂移，实测确认）。
- 渲染：展开高亮节点；有配对截图按节点 rect 裁局部截图；纯 AX 时刻退化为文本节点展示。 **[已推翻 → `swift/AfterRayRecall/Sources/StreamingMarkdown.swift:183`]**
- 行内 = 可点链接，独立成行 = 渲染帧（复用聊天的既有语义）。

### 7. OCR 窗口裁剪（此前已批，并入本计划）

- OCR 区块按前台窗口 frame 裁剪（实测一帧 47% 的区块来自窗口外：菜单栏、天气组件、背景窗口残段）；碎片再过一道过滤（实测 370 条）。
- 这是 AX 空白 app（WeChat/Zed/Office，实测 WeChat 196 节点 0 文本）唯一的降噪手段。

已实现（WS6，`crates/afterrayd/src/ocr_crop.rs`），落在 afterrayd 导入路径上、`insert_text_evidence` 之前。实现规则逐条如下：

- **几何映射**：Vision 归一化框是左下原点，按 shim `Ready` 上报的显示器逻辑尺寸（点，非像素）展开并翻转 Y，得到全局左上原点的屏幕矩形；取该矩形的**中心**判定，中心落在窗口 frame 外的区块丢弃。窗口 frame 取自该 moment 配对的 AX 快照中第一个 window 角色节点（快照本就只覆盖前台 app），复用 `accessibility_scope_tree` + `acts::window_node`，不另写解析。
- **碎片过滤**，只作用于裁剪判定成功后保留下来的区块：
  - (a) 既无字母、无数字、也无常用 CJK／假名／谚文字符的区块丢弃 —— `• `、分隔线，以及 Vision 对糊成一团的像素吐出的生僻字（`㗊`，扩展区汉字不计作内容字符）。**数字算内容**：角标、价格、时钟都是证据。
  - (b) 少于 8 字符**且**贴住窗口边界（2pt 容差）的区块丢弃 —— 被前台窗口切掉的邻窗残段（`Conversatio`、`ter`、`• Gi`）。窗口内部的短文本（`Issues`、`19`）保留：长度本身不是证据，长度加位置才是。
- **一律 fail open**：没有 AX 快照（AX 是截图之后才附上的）、快照无窗口节点、窗口 frame 不可测、没有显示器尺寸、或窗口 frame 与所设显示器边界（假定该显示器位于全局原点）无交集（多屏歧义）—— 全部区块原样保留，行为与裁剪前完全一致。几何上的不确定绝不吃掉证据。
- `text` 与 `layout_json` 从保留区块一起重建（`\n` 连接，与 Vision worker 的拼法一致），且**只在确实丢弃了区块时**改写；同时打一行 debug 日志记录 kept/总数与 moment id。
- 已知限制：显示器尺寸只有被采集的那一块，且假定它在全局原点；副屏上的前台窗口因此落进 fail-open 分支而不裁剪。

## 实施工作流

| WS | 内容 | 落点 | 状态 |
|---|---|---|---|
| 1 | 树文本化 + 折叠 + 人话角色 + diff 引擎 + keyframe 策略（纯函数，XCTest） | `AfterRayCapturePolicy` | ✅ 2026-08-18 `e871ca3` |
| 2 | 事件词汇表 v2：text_input(text+value) / drag 两端 / secure 护栏 / 停顿合并 | shim `InputEventMonitor` | ✅ 2026-08-18 `11c401e`（+ 解析 `cf5e01d`） |
| 3 | submit value + 截图节流 + `screenshot_id`/citable 标记 + 心跳降兜底 | shim 主循环 + daemon | 🟡 submit value + 附树分级（`11c401e`）、`tree_text` 落盘（`21246e3`）、**截图节流 + 心跳降兜底**（daemon 侧，见下）已落；**`screenshot_id` / citable 标记推迟到 WS5** —— 标记的唯一消费者是 T2 prompt（"无截图的 AX 时刻不可出图级引用"），在写 prompt 的同一个工作流里落地才能被验证，否则只是没人读的字段 |
| 4 | 链存储（keyframe+diff artifact 类型）、保留期统一、`INPUT_EVENT_RETENTION_MS` 废除 | afterray-store | ✅ 2026-08-18 schema 25（`text` + `extra_json` 列）+ 保留期统一（`prune_input_events_before` / `prune_edge_snapshots_before`，48h 只剩 `signal_gap`）。链的 keyframe/diff **不另立 artifact 类型**：`tree_text` 是 AX 快照信封里的字段，另存一份会让同一棵树有两个真相 |
| 5 | T1/T2 契约 v3：frontmatter+MD 解析、五段指导、`#el` 引用、预算窗口化、工具目录裁剪、prev-card 注入 | store slot.rs + afterrayd | ✅ 2026-08-18（schema 26 / 卡片 v3；见下方「WS5 实现偏差」） |
| 6 | OCR 窗口裁剪 + 碎片过滤 | afterrayd 导入路径 `ocr_crop.rs` | ✅ 2026-08-18 `1a7ed62` |
| 7 | 语料回归（复用 phase 5 计划：≥20 slot 盲评） | scripts/t2-eval.py | ⬜ |

依赖：WS1 → WS2/WS3 → WS4 → WS5；WS6 独立可先行；WS7 收尾。

### WS2/3 实现偏差（2026-08-18）

代码即事实，与上文设计的出入逐条记在这里。实现说明见 [context/event-capture-v2.md](../context/event-capture-v2.md)。

1. **`tree_text` 信封多带 `chain` + `seq`**（设计只写 `{mode, text}`）。diff 链按窗口分组，所以一条 `diffFromPrevious` 的基帧不是"时间上的前一个 artifact"，而是"同链的前一次发射"。不给出链标识，消费方根本无法定位基帧 —— 不可解码的 diff 不如不发。
2. **链的 key 含"走树根"**（`.application` / `.window`）。心跳走 app 元素、附树走单窗口，同一窗口两种根互 diff 会把 `AXApplication` 对齐到 `AXWindow`，退化成"全删全加"，比它想省下的 keyframe 还大。
3. **`windowChanged` = 该 scope 尚无链**。按窗口分链后，切回一个仍在缓存里的窗口不再强制 keyframe（比设计更省），LRU 只保 6 条链（每条持有整棵渲染树，是常驻进程的内存上限），被淘汰的窗口回来时付一个 keyframe。
4. **事件 kind 名沿用 `burst` / `command`**，未改名为 `text_input` / `submit`。`afterray-store` 的 acts join 按这些字符串匹配（`acts.rs parse_event`），本工作流按契约只做加法；`text` / `target.value` 作为新字段挂在原 kind 上。改名留给 WS4/WS5 一并处理。
5. **secure 护栏比设计更严**：除 `AXSecureTextField`（本体或祖先 subrole）外，还看"像密码的 label"（Electron/Web 常把密码框渲染成普通 `AXTextField`），且**焦点解析失败一律按 secure 处理**（fail closed）。误判的代价只是丢一个字段的文本。
6. **value 取"光标附近 500 字符窗口"**而非前 500 字符（`kAXSelectedTextRange`）。长文档的前 500 字符与"刚刚输入的那句话"无关。AX 给的是 UTF-16 偏移、裁剪按字符计，CJK 下窗口可能偏几个字符 —— 它是窗口不是索引。
7. **drag 的 mouse-down 仍照旧产生一条 `click`**。它确实是一次点击，且老消费方依赖它；drag 记录是额外的一条。
8. **`window_changed` 只由 bundle 轮询触发**：同一 app 内换窗口（改标题）暂不产生事件。
9. **截图节流 / 心跳降兜底已在 WS4 落于 daemon**（`fire_capture_tick` / `event_capture_is_due`），`screenshot_id` 仍未做。截图依旧是纯拉取式 —— 事件只是把下一次拉取提前，shim 侧一行未改，配对不变量原样保留。
10. **`captureEdgeSnapshot` 未改名**，尽管它已泛化为 §3 的附树分级入口（新的统一入口是 `requestTreeWalk`）。产物 kind 仍是 `accessibility_edge`，改名会牵动 daemon 与文档锚点。

## 明确不抄

- 无心跳纯事件驱动（我们保心跳兜底：深读场景 + 采集空洞）。
- 无 scroll 事件（我们保留：阅读行为的主信号）。
- 文件级 Citations（我们的行内 moment/元素引用更强）。

### WS4 实现偏差（2026-08-18）

1. **保留期的"统一"落成了随帧过期**，不是第二个时钟。vault 的通用保留本就只有容量驱动的最旧优先淘汰，所以事件与 R3 树按**保留水位线**（仍在库里的最旧一帧）清理：一段时间里"用户做了什么"与"屏幕上有什么"同生共死。容量之内什么都不过期 —— 与帧一致。
2. **没有帧就不扫**。"比空更旧"会把一台从未采集过帧的机器上的实时事件删掉，所以水位线未知时跳过而不猜。代价：无帧 vault 上的 R3 artifact 回收不了（`delete_history` 仍能删）。
3. **`INPUT_EVENT_RETENTION_MS` 改名为 `SIGNAL_MARKER_RETENTION_MS`（48h）而非删除**：`signal_gap` 是"录制器自己的记账"，它的全部含义就是一个期限，仍需独立于容量按时钟过期。
4. **不新增 keyframe/diff artifact 类型**：`tree_text` 是 AX 快照信封内的字段，另存一份会让同一棵树有两个真相。
5. **事件驱动截图的节流取 `max(10s, 用户配置的间隔)`**。配 60s 心跳的用户想要的是更少的帧，不是"一打字就 10s 一张"。
6. **心跳改为"从 `last_capture_ms` 起睡"**而不是固定 interval：这才是"降为兜底" —— 任何一次采集（心跳的或事件拉起的）都重置相位，两个任务之间不需要通道。

### WS5 实现偏差（2026-08-18）

1. **卡片版本常量一分为二**：`SLOT_SUMMARY_SCHEMA_VERSION` 变 3，新增
   `V2_SLOT_SUMMARY_SCHEMA_VERSION = 2`。vault 里有三处 `>= 常量` 的判断表达的是
   「至少 v2」而非「是 v2」，其中 `find_slot_mentions` 是 `WHERE` 闸门 —— 只改一个
   常量会在 v3 上线当天悄悄把库里所有 v2 卡片踢出检索。行的形状一律由
   `schema_version` 判定，绝不由「哪些列为 NULL」推断（三种形状的写入路径互相清空对方的列）。
2. **v3 正文进检索靠 `details_sections`**：Markdown 正文按 `#` 小节切成 v2 的
   `T2Thread` 形状喂给既有匹配器，命中返回的是那一节（并裁到 300 字符），不是整篇。
   不这么做，v3 之后的卡片只剩标题可搜。
3. **`applications` 未落库也未进 prompt**：按设计由 facts 在渲染期派生，模型不写。
   `derived_bullets()` 由正文小标题派生，v1 读者（旧 CLI、旧客户端）照旧能用。
4. **acts 的内容通道做成 `Acts` 的兄弟而非扩展**（`acts::ActContent`）。
   `acts_json` 是事件过期后唯一剩下的东西，保持 counts/labels 原形状就无需版本化，
   老读者一行不改；内容只在事件还在时存在，**从不冻结** —— 过期的 slot 说的是
   「不知道写了什么」，不是「什么都没写」。value 优先于键流；写完又发出去的同一句只出现一次；
   shim 标了 secure 的字段即使带着 value 也一律不读（源头之外的第二道锁）。
5. **citable 标记落成 `unframed_lines` 计数**：`screenshot_id` 共享仍未实现，所以库里
   不存在「没有截图的 moment」，一个恒为 true 的布尔字段没有消费者。真正无帧可引的证据是
   R3 边沿树贡献的行，按 run 计数写进 prompt（「可以据此写，但不要为它出引用」）。
   等 `screenshot_id` 落地，这个计数只是变大，不需要新字段。
6. **fail-open pin 未重生成**。v3 新增的字段（`wrote`、`unframed`、邻卡 description）
   在无事件、无边沿树的 slot 上一律**省略而非空值输出**，因此零事件卡片与 prompt 逐字节不变；
   变的是**模型侧**的输出契约，而 pin 钉的是输入侧。保持原样比重生成是更强的陈述。
7. **预算取 `opening_allowance()` 而非整个 transcript**：T2 的 prompt 就是 opening，
   这样每一轮仍放得下一个完整的工具结果。上限 48k 是「已评测范围」的边界，不是模型能力边界 ——
   放开它的是 WS7 的语料回归。
8. **`get_transcript` 仍留在 ToolHost 上（只是无音频时不写进 prompt）**：模型若凭空调用它，
   得到的是「本时段没有录到语音」，比「未知工具」更接近事实。
9. **Swift 侧是最小渲染**：日面板是一个 AppKit 文本视图，v3 正文用 `StreamingMarkdown`
   解析后按小节展开，行内语法与引用渲染成它们说的话（`[label](afterray://moment/id)` → `label`）。
   加载帧本身与 `#el<N>` 元素高亮仍是聊天面板的能力，日面板留待后续。

## 运行时验证（2026-08-18 晚，真实生产 vault）

- schema 21→26 迁移无损，protocol 15 握手正常，录制持续。
- OCR 窗口裁剪：天气组件文本最后进库 21:02:13，新 daemon 21:05:30 启动后零命中——精确到重启时刻。
- tree_text 链：三种模式齐全，链按窗口分、seq 递增、LRU 驱逐回归付 keyframe；**安静帧 diff ~1KB vs 整树 260–380KB（250–350×）**，与逆向预测吻合。`root` 仍每帧照发（过渡契约），减重收益待消费切换后兑现。
- 输入事件端到端（tap→daemon→vault→join→卡片）：submit value 逐字捕获用户消息（含时刻）；IME 行为与设计一致（typed=拼音/中间态，submitted=组合整句）；点击带元素身份；run 正确切分；`no_input_ratio` 合理。
- **原始 bug 修复实证**：用户只读未碰的 226 行聊天输出被正确标为 `not_engaged`，而非冒充用户活动。
- listen-only tap **不在输入监控面板留痕**（§7.3 PoC 落定；意义随 CAP-005 取消反转——透明义务在应用自身，见 input-events 计划的 PoC 节）。
- 待验：首张真实 v3 T2 卡（degraded 队列等空闲闸门）；WS7 语料回归。
- 小毛刺（不阻塞）：无标签元素点击 label 退化为角色名；边界 ⌘C 归属到相邻 run；地址栏 URL 进 typed。

## 开放 PoC

- diff 树对齐在 Electron 大树上的稳定性与性能（20k 节点上限内）。
- `#el` 编号在"同帧存储→渲染"往返中的一致性。
- 截图节流与 `capture_paused`（overlay 前台）的交互：代码上走同一道 `fire_capture_tick` 闸门（paused 时事件也拉不起截图），但**未经实机验证** —— 需要活的 shim。
