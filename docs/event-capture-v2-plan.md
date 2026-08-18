# 事件驱动采集 v2 计划

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
- **截图独立节流**：事件可触发，≥10s 间隔；一张截图被其后窗口内的多个 AX 捕获共享（`screenshot_id?`）。**无截图的 AX 时刻不可出图级引用，此事实写进 T2 prompt。**
- 配对不变量方向不变：截图必有 AX；AX 可无截图。
- 节流/抑制计数（shim 已有 `dropped`）进 segment metadata 并最终进卡片。

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
- 预算：废除 `PROMPT_LINES_BUDGET_CHARS` 固定常量，改由 `resolve_context_budget()`（真实模型窗口 × 机器可负担）推导，保守 2.5 B/token，下限 12k 字符，上限先设 4× 现值的天花板待语料评测放开。`more_chars` 留作如实告知，删除取用邀请与 `get_run_text` 依赖。
- 工具目录按证据裁剪：无音频的 slot 不出现 `get_transcript`（实测 35b 为此浪费整轮）。

### 6. 元素级引用

- `afterray://moment/<id>#el<N>`，N 按**该帧**树文本的编号解析（编号跨帧漂移，实测确认）。
- 渲染：展开高亮节点；有配对截图按节点 rect 裁局部截图；纯 AX 时刻退化为文本节点展示。
- 行内 = 可点链接，独立成行 = 渲染帧（复用聊天的既有语义）。

### 7. OCR 窗口裁剪（此前已批，并入本计划）

- OCR 区块按前台窗口 frame 裁剪（实测一帧 47% 的区块来自窗口外：菜单栏、天气组件、背景窗口残段）；<8 字符或纯符号碎片丢弃（实测 370 条）。
- 这是 AX 空白 app（WeChat/Zed/Office，实测 WeChat 196 节点 0 文本）唯一的降噪手段。

## 实施工作流

| WS | 内容 | 落点 |
|---|---|---|
| 1 | 树文本化 + 折叠 + 人话角色 + diff 引擎 + keyframe 策略（纯函数，XCTest） | `AfterRayCapturePolicy` |
| 2 | 事件词汇表 v2：text_input(text+value) / drag 两端 / secure 护栏 / 停顿合并 | shim `InputEventMonitor` |
| 3 | submit value + 截图节流 + `screenshot_id`/citable 标记 + 心跳降兜底 | shim 主循环 |
| 4 | 链存储（keyframe+diff artifact 类型）、保留期统一、`INPUT_EVENT_RETENTION_MS` 废除 | afterray-store |
| 5 | T1/T2 契约 v3：frontmatter+MD 解析、五段指导、`#el` 引用、预算窗口化、工具目录裁剪、prev-card 注入 | store slot.rs + afterrayd |
| 6 | OCR 窗口裁剪 + 碎片过滤 | afterrayd 导入路径 |
| 7 | 语料回归（复用 phase 5 计划：≥20 slot 盲评） | scripts/t2-eval.py |

依赖：WS1 → WS2/WS3 → WS4 → WS5；WS6 独立可先行；WS7 收尾。

## 明确不抄

- 无心跳纯事件驱动（我们保心跳兜底：深读场景 + 采集空洞）。
- 无 scroll 事件（我们保留：阅读行为的主信号）。
- 文件级 Citations（我们的行内 moment/元素引用更强）。

## 开放 PoC

- diff 树对齐在 Electron 大树上的稳定性与性能（20k 节点上限内）。
- `#el` 编号在"同帧存储→渲染"往返中的一致性。
- 截图节流与 `capture_paused`（overlay 前台）的交互。
