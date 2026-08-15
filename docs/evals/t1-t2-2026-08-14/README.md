# T1 → T2 实跑记录 · 2026-08-14

三个真实槽，真实 vault（`.afterray/v0-data`），真实 agent 执行总结。
每次 agent 拿到的只有 T1 卡片 + 工具，没有预先喂任何证据。

| 槽 | 特征 | moments | 切换 | 错误线程 | agent 工具调用 |
|---|---|---|---|---|---|
| 16:30–17:00 | 多线程并行（调试 + PR review + 设计） | 122 | 23 | 4 | 7 |
| 15:30–16:00 | 长设计对话 + 零散跳转 | 167 | 20 | 0 | 7 |
| 13:00–13:30 | 单应用深度专注 | 149 | 1 | 0 | 5 |

**重要**：`as-run/` 是 agent 当时实际看到的 T1（修复前）。`after-fixes/` 是根据
agent 批评修复后重新生成的同一批槽。T2 卡片是在**修复前**的 T1 上产出的。

文件：
- `system-prompt.txt` — T2 系统提示词（三次共用）
- `as-run/t1-*.txt` — agent 实际收到的 T1 卡片
- `after-fixes/t1-*.txt` — 修复后的同槽 T1
- `after-fixes/card-*.json` — 修复后的 T1 结构化输出（完整 SlotCard）

---

## 槽 A · 16:30–17:00 — 多线程并行

### T1 卡片（agent 实际看到的，节选）

```
[facts] apps and time
  Lody                     21m
  Google Chrome            4m
  SecurityAgent            59s
  unknown                  31s
  WeChat                   30s
  Ghostty                  30s
  23 switches · longest unbroken 7m · idle 6%

[seen] what was open
  file  about:blank
  file  chat
  file  lody
  file  %E8%82%96%E4%BD%B3%E6%85%A7_%E4%BD%93%E6%A3%80%E6%8A%A5%E5%91%8A_2026-08-09_...pdf
  web   blob:file:///449f5d02-77b3-4358-8e32-a8e9037ccbb1
  web   127.0.0.1:5175
  web   main.lody.pages.dev/temp-lody/chat
  web   main.lody.pages.dev/temp-lody/sessions/2786e718-435a-46b8-9e12-53ddf87697f4?pr=…
                                                                                  ↑ PR 号被截掉了

[map] returned to
  Lody · cdbd4e32-8147-4d34-94dd-12ca692d121f — 5 visits, 15m total (16:30 16:37 16:37 16:41 16:56)
  Lody · blob:file:///449f5d02-... — 5 visits, 3m total (16:35 16:37 16:49 16:50 16:53)
  ...

[map] sustained on one thing
  16:30–16:33 Lody · cdbd4e32-8147-4d34-94dd-12ca692d121f
  16:41–16:48 Lody · cdbd4e32-8147-4d34-94dd-12ca692d121f
  16:56–16:59 Lody · cdbd4e32-8147-4d34-94dd-12ca692d121f

[map] recurring errors (candidate work threads)
  5 × at 16:54 16:55 16:56 16:56 16:56 — "app.tsx:426 Uncaught TypeError: Cannot read properties of"
  4 × at 16:51 16:52 16:52 16:52 — "Error: Agent 启动前失败"
  1 × at 16:52 — "Error: Agemt /以」刖天火"          ← OCR 噪声变体没聚类
  1 × at 16:52 — "Error:Agent启动前失败"

[map] entry-point moment ids (one per stretch)
  019fff69-6f09-7f81-be4b-5db67bea7f95        ← 无时间、无上下文
  019fff6a-f5d3-7522-96b7-3e9ec5408a8a
  ...
```

完整版见 `as-run/t1-1630.txt`。

### T2 卡片（agent 产出）

```json
{
  "artifacts": ["ENOENT: no such file or directory", "app.tsx:426", "#3407", "127.0.0.1:5175"],
  "title": "Designed the recurring work-summary feature, chased a worktree ENOENT, and reviewed PR #3407",
  "bullets": [
    "Kept coming back to one Lody chat thread across three separate stretches (16:30-16:33, 16:41-16:48, 16:56-16:59) refining a design for a system that produces an automatic summary every 30 minutes.",
    "Hit a repeating \"Agent 启动前失败\" failure — ENOENT on a worktree path — when enabling a local project worktree in Electron, and pasted the stack trace into chat to ask why (~16:51-16:52).",
    "Reviewed PR #3407 (arch-linux-kde-logo fix) on the Lody session page: branch has merge conflicts pending, and a bot comment flags that a dependent OSS Electron PR must land first.",
    "Checked the local product landing page at 127.0.0.1:5175, where the console threw a repeated \"app.tsx:426 Uncaught TypeError: Cannot read properties of\" error around 16:54-16:56."
  ],
  "category": "coding",
  "confidence": 0.7
}
```

### agent 的工具调用

| # | 命令 | 得到了什么 |
|---|---|---|
| 1 | `evidence ocr --at-ms 1786697520000`（16:52） | ENOENT / "Agent 启动前失败" 的完整报错文本 |
| 2 | `evidence ocr --at-ms 1786697760000`（16:56） | 浏览器其实在本地 landing page，**不是** episode 笔记说的会话列表 |
| 3 | `evidence ocr --at-ms 1786696860000`（16:41） | PR #3407 页面：merge conflict + bot 依赖说明 |
| 4 | `evidence ocr --at-ms 1786697700000`（16:55） | app.tsx:426 报错片段 |
| 5 | `evidence ax --at-ms 1786697760000`（16:56） | 结构化确认焦点窗口 URL 是 `127.0.0.1:5175` |

### agent 对 T1 的批评

> - fragment notes 大体可靠，每条省了一次调用。
> - **16:56 那条 fragment note 是错的** —— OCR 和 AX 都显示是 landing page 浏览，不是会话列表；该内容从卡片里剔除了。
> - **地图完全没提到 PR review 这条线**（#3407、merge conflict、bot 依赖）—— 只能靠 "returned to" 里那个 `?pr=` URL 自己去追。这是地图漏掉的一条真实工作线。
> - recurring-errors 块有线索价值，但**完全没说这个报错属于哪个 app / 页面**，得交叉比对 URL 列表才能归属。
> - `[map] sustained on one thing` 正确标出了三次回访，是**整张地图里最吃重的一块**。
> - `[avoid]` 列表对避免措辞重复有用。

---

## 槽 B · 15:30–16:00 — 长设计对话

### T2 卡片（agent 产出）

```json
{
  "artifacts": ["screenpipe", "ax_events", "loro-dev/afterray", "afterray-accessibility.json"],
  "title": "Deep-dived AfterRay's auto-summary design in Lody, benchmarking against screenpipe's source",
  "bullets": [
    "Spent nearly the whole block in one continuing Lody conversation designing AfterRay's automatic 30-minute work-summary pipeline, pulling in screenpipe's source (frames/elements schema, OCR and AX text unified via a `source` column) to argue for folding ax_events into the slot summary at close instead of retaining raw event history.",
    "Within the same thread, worked out product-positioning wording contrasting AfterRay's local encrypted vault and second-level replay against History-style cloud tools, and noted a PO decision to split CAP-005 into two parts and settle its public wording before shipping an activity event stream.",
    "Made brief side-trips to two loro-dev/lody-oss pull requests, a Ghostty terminal session named lody, and Activity Monitor, each under a minute, with no evidence of what was actually checked there."
  ],
  "category": "coding",
  "confidence": 0.8
}
```

第三条 bullet 值得注意：agent **主动声明了证据不足**（"no evidence of what was
actually checked there"），而不是编造。这是系统提示词里"给不知道一个合法出口"那条在起作用。

### agent 对 T1 的批评

> - **有用**：`sustained on one thing`（15:34–15:37、15:56–16:00）直接指向两段最富文本的时段，两次 OCR 都验证了确有实质内容。
> - **有用**：fragment notes 的高层标签方向正确，是个不错的索引，但不能替代内容。
> - **噪声**：12 个 entry-point moment id **没有任何时间戳** —— 无法知道哪个 id 对应哪一段，预算内根本用不了，只能退回去猜 `--at-ms`。
> - **噪声**：`blob:file:///…`、`native-resource://sdk/avatar?...` 是 Lody 的内部 chrome，不是真实导航目标，纯干扰。
> - **缺失**：地图从没传达出这 26 分钟是**一整段连续的设计对话且有具体技术产出**（screenpipe schema 对比、ax_events 保留策略、CAP-005 措辞决定）—— fragment notes 停留在"reviewing/discussing X"，从没说清到底决定了什么，只有全量 OCR 才揭示出来。
> - **误导**：`returned to` 把本质上同一段进行中的对话**按窗口标题变体拆成了三条**，读起来像三个不同话题，实际是一个线程在 UI 重绘时被反复计数。

---

## 槽 C · 13:00–13:30 — 单应用深度专注

这是最容易产出"通用废话"的场景：一个 app、1 次切换、19 分钟不间断。

### T2 卡片（agent 产出）

```json
{
  "artifacts": [
    "AfterRay 本地化屏幕与音频日志系统的开发规划",
    "moment get / evidence ocr",
    "afterray evidence ocr <id> --json",
    "AfterRayCliInstall.swift"
  ],
  "title": "Building AfterRay's read-only CLI contract: PATH install and onboarding/Settings wiring",
  "bullets": [
    "Planned a CLI slice inside Lody's 'AfterRay 本地化屏幕与音频日志系统的开发规划' task — moment get / evidence ocr, evidence ax, and activity read over a Unix socket — then had it implemented.",
    "On-screen agent log shows the Rust side passing, then PATH install plus onboarding/Settings CLI UI landing in AfterRayCliInstall.swift, AfterRayOnboarding.swift, and AfterRaySettings.swift, with a daemon tools module shared by Ask and Memory.",
    "Session closed on a 16-file, +5452/-682 diff and a macOS prompt asking whether Lody could access data from other apps."
  ],
  "category": "coding",
  "confidence": 0.75
}
```

三次调用（其中一次浪费在无文本帧上）就从"在 Lody 里看了 25 分钟"变成了具体的
文件名、CLI 命令面和 diff 规模。

### agent 对 T1 的批评（最尖锐的一次）

> - `sustained on one thing` 和 `entry-point moment ids` 是真正有用的部分 —— 指向了承载整个故事的两次 OCR。
> - **四条 fragment notes 近乎无价值**：模糊的转述（"reviewing model prompts... design specifications"、"scrolled through lists"）能描述任何一个 Lody 会话，从未点名具体工作（CLI contract、PATH install、onboarding UI），而一次 OCR 立刻就揭示了。
> - 任务标题 `AfterRay 本地化屏幕与音频日志系统的开发规划` —— **整张卡片最好的锚点** —— 被埋在 13:24 那条 fragment note 里，而不是作为一等事实呈现。
> - 地图对回报细节零指示（文件名、CLI 命令面、16 文件 +5452/-682 diff、系统权限弹窗）—— "text, dense (~1600 chars/frame)" 告诉我去哪看，但没说那里有什么。
> - **四个 entry-point 里有一个（~13:00 那个）取回来没有可用证据**；地图没有任何信号提示这个 id 会失败，白费一次调用。
> - 每张 OCR 快照里都有其它无关 Lody 任务的侧边栏噪声（"Checkout性能分析"、"Loro 2.0设计评审"），地图没标注这是应忽略的样板内容，只能手动过滤。

---

## 根据批评做的修复

| 批评 | 修复 | 回归测试 |
|---|---|---|
| 覆盖图 170 帧各成一窗 | 按容差合并同类窗口（采集抖动导致端点判等永远不成立） | `coverage_survives_capture_jitter` |
| 设计文档里的"失败/报错"产生 64 条假错误 | 只认机器格式标记；CJK 散文无代码 token 拒绝；出现率过高判为页面常驻内容 | `prose_about_failure_is_not_an_error_signature`、`saturated_signature_is_dropped_as_page_furniture` |
| UUID / `blob:` 占满 facts | `is_opaque_id` + `is_chrome_noise` | `opaque_identifiers_are_kept_out_of_the_facts` |
| `?pr=3407` 被右截断 | 折叠 URL 中的不透明路径段，保留查询串 | `url_keeps_its_query_and_collapses_opaque_segments` |
| entry-point 无时间、指向空帧 | 带时刻 + OCR 字数 + 目标；无文本的不列；按目标去重 | `entry_points_carry_time_and_skip_textless_stretches` |
| 错误线程无归属 | 渲染时带 `target` | `threads_name_the_surface_they_appeared_on` |
| 窗口标题埋在 episode 笔记里 | `top_windows` 升为一等事实 | `window_titles_are_first_class_facts` |

### 同一个槽（16:30）修复后的样子

```
[seen] what was open
  window  请分析这个项目如何为它设计自动的工作总结，每三十分钟一轮，每一轮有它那一次的总结（如果30分钟内有操 - Lody
  window  启动 site 预览并迭代官网设计 - Lody
  window  AfterRay 本地化屏幕与音频日志系统的开发规划 - Lody
  window  AfterRay — Total recall. Zero upload. - Google Chrome - Zixuan (loro.dev)

[map] recurring errors (candidate work threads)
  5 × at 16:51 … in Google Chrome · main.lody.pages.dev/temp-lody/chat — "Error: Agent 启动前失败"
  5 × at 16:54 … in Lody · 启动 site 预览并迭代官网设计 - Lody — "app.tsx:426 Uncaught TypeError: Cannot read properties of"
                    ↑ 现在知道报错属于哪个页面

[map] probe here (one frame per stretch, all carry text)
  16:39  1891 chars  019fff6d-…  Lody · 有的时候会遇到说这个文件打不开，但是实际是存在的，而且在工作区内 …
  16:40  1770 chars  019fff6e-…  Google Chrome · github.com/loro-dev/lody-oss/pull/57/changes
  16:40  2465 chars  019fff6e-…  Google Chrome · main.lody.pages.dev/temp-lody/sessions/…?pr=3407
  16:48  1934 chars  019fff75-…  Lody · AfterRay 本地化屏幕与音频日志系统的开发规划 - Lody
  16:51  1736 chars  019fff77-…  Ghostty · lody
  16:54  2262 chars  019fff7a-…  Lody · 启动 site 预览并迭代官网设计 - Lody
  16:59  2937 chars  019fff7f-…  Lody · 请分析这个项目如何为它设计自动的工作总结 …
```

之前 agent 要自己去挖的 `pull/57/changes` 和 `?pr=3407`，现在直接躺在探针列表里。

---

## 还没解决的两件事

1. **`returned to` 会把同一段连续对话按窗口标题变体拆成多条**（槽 B 的批评）。
   需要更稳的会话 key，不是一行改动。

2. **episode 笔记本身偏泛**（槽 C 的批评最狠）。这是 T1 之外的问题 —— episode 层
   目前走最多 5 轮工具循环却产出"reviewing / scrolled through"级别的转述。
   对应 `../../slot-summaries-and-ax-pipeline.md` §5.7 的抽取式改造。

## 复现

```sh
cargo build -p afterray-store --example slot_cards
./target/debug/examples/slot_cards --data-dir .afterray/v0-data --at-ms <ms> --slots 1
./target/debug/examples/slot_cards --data-dir .afterray/v0-data --slots 3 --json
```

或经 daemon：

```sh
export AFTERRAY_SOCKET=$PWD/.afterray-dev/afterray.sock
./target/debug/afterray slot card   --at-ms <ms>
./target/debug/afterray slot prompt --at-ms <ms> --user-only
```
